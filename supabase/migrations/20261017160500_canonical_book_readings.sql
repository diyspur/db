-- M05: Canonical book reading state (user_book_readings), conservative backfill, and goal/overview reconciliation.
-- Immutable additive migration.

CREATE TABLE IF NOT EXISTS public.user_book_readings (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  book_id uuid NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('want_to_read', 'reading', 'read', 'dnf')),
  source text NOT NULL CHECK (source IN ('manual', 'verified_book_completion', 'legacy')),
  first_started_at timestamptz,
  first_completed_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  version bigint NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, book_id),
  CHECK ((status = 'read') = (completed_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS user_book_readings_book_idx
  ON public.user_book_readings(book_id, status);

CREATE INDEX IF NOT EXISTS user_book_readings_started_idx
  ON public.user_book_readings(first_started_at, book_id)
  WHERE first_started_at IS NOT NULL;

ALTER TABLE public.user_book_readings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_book_readings FROM anon, authenticated;
GRANT SELECT ON public.user_book_readings TO authenticated;

DROP POLICY IF EXISTS user_book_readings_own ON public.user_book_readings;
CREATE POLICY user_book_readings_own ON public.user_book_readings
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Private request log for idempotent reading mutations.
CREATE TABLE IF NOT EXISTS private.book_reading_requests (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  request_id uuid NOT NULL,
  book_id uuid NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  status text NOT NULL,
  resulting_version bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, request_id)
);

REVOKE ALL ON private.book_reading_requests FROM PUBLIC, anon, authenticated;

-- Conservative backfill: never mark books as 'read' from partial seasons (SDD 8.2 & 8.3).
INSERT INTO public.user_book_readings (
  user_id, book_id, status, source, first_started_at, updated_at, version
)
SELECT
  up.user_id,
  s.book_id,
  'reading',
  'legacy',
  MIN(COALESCE(up.started_at, up.updated_at, now())),
  MAX(COALESCE(up.updated_at, now())),
  1
FROM public.user_progress up
JOIN public.chapters c ON c.id = up.chapter_id
JOIN public.seasons s ON s.id = c.season_id
WHERE up.percent > 0
   OR up.status IN ('reading'::public.shelf_status, 'read'::public.shelf_status)
GROUP BY up.user_id, s.book_id
ON CONFLICT (user_id, book_id) DO NOTHING;

CREATE OR REPLACE FUNCTION private.set_my_book_reading(
  p_book uuid,
  p_status text,
  p_version bigint,
  p_request_id uuid
) RETURNS TABLE (
  book_id uuid,
  status text,
  source text,
  first_started_at timestamptz,
  first_completed_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz,
  version bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_user uuid := auth.uid();
  v_req private.book_reading_requests%ROWTYPE;
  v_cur public.user_book_readings%ROWTYPE;
  v_now timestamptz := now();
  v_started timestamptz;
  v_first_completed timestamptz;
  v_completed timestamptz;
  v_next_version bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_book IS NULL
     OR p_request_id IS NULL
     OR p_version IS NULL
     OR p_version < 0
     OR p_status NOT IN ('want_to_read', 'reading', 'read', 'dnf') THEN
    RAISE EXCEPTION 'invalid_reading_state' USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.books b WHERE b.id = p_book) THEN
    RAISE EXCEPTION 'book_not_found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('book-reading:' || v_user::text || ':' || p_book::text, 0)
  );

  SELECT * INTO v_req
    FROM private.book_reading_requests r
   WHERE r.user_id = v_user
     AND r.request_id = p_request_id;

  IF FOUND THEN
    IF v_req.book_id IS DISTINCT FROM p_book
       OR v_req.status IS DISTINCT FROM p_status THEN
      RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
    END IF;

    RETURN QUERY
    SELECT
      ubr.book_id,
      ubr.status,
      ubr.source,
      ubr.first_started_at,
      ubr.first_completed_at,
      ubr.completed_at,
      ubr.updated_at,
      ubr.version
    FROM public.user_book_readings ubr
    WHERE ubr.user_id = v_user
      AND ubr.book_id = p_book;
    RETURN;
  END IF;

  SELECT * INTO v_cur
    FROM public.user_book_readings ubr
   WHERE ubr.user_id = v_user
     AND ubr.book_id = p_book
   FOR UPDATE;

  IF NOT FOUND THEN
    IF p_version <> 0 THEN
      RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
    END IF;
    v_started := CASE WHEN p_status IN ('reading', 'read', 'dnf') THEN v_now ELSE NULL END;
    v_completed := CASE WHEN p_status = 'read' THEN v_now ELSE NULL END;
    v_first_completed := v_completed;
    v_next_version := 1;

    INSERT INTO public.user_book_readings (
      user_id, book_id, status, source, first_started_at, first_completed_at, completed_at, updated_at, version
    ) VALUES (
      v_user, p_book, p_status, 'manual', v_started, v_first_completed, v_completed, v_now, v_next_version
    )
    RETURNING * INTO v_cur;
  ELSE
    IF v_cur.version <> p_version THEN
      RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
    END IF;
    v_started := COALESCE(
      v_cur.first_started_at,
      CASE WHEN p_status IN ('reading', 'read', 'dnf') THEN v_now ELSE NULL END
    );
    v_completed := CASE WHEN p_status = 'read' THEN COALESCE(v_cur.completed_at, v_now) ELSE NULL END;
    v_first_completed := COALESCE(v_cur.first_completed_at, v_completed);
    v_next_version := v_cur.version + 1;

    UPDATE public.user_book_readings
       SET status = p_status,
           source = 'manual',
           first_started_at = v_started,
           first_completed_at = v_first_completed,
           completed_at = v_completed,
           updated_at = v_now,
           version = v_next_version
     WHERE user_id = v_user
       AND book_id = p_book
    RETURNING * INTO v_cur;
  END IF;

  INSERT INTO private.book_reading_requests (
    user_id, request_id, book_id, status, resulting_version
  ) VALUES (
    v_user, p_request_id, p_book, p_status, v_cur.version
  );

  RETURN QUERY
  SELECT
    v_cur.book_id,
    v_cur.status,
    v_cur.source,
    v_cur.first_started_at,
    v_cur.first_completed_at,
    v_cur.completed_at,
    v_cur.updated_at,
    v_cur.version;
END;
$$;

REVOKE ALL ON FUNCTION private.set_my_book_reading(uuid, text, bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.set_my_book_reading(uuid, text, bigint, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_my_book_reading(
  p_book uuid,
  p_status text,
  p_version bigint,
  p_request_id uuid
) RETURNS TABLE (
  book_id uuid,
  status text,
  source text,
  first_started_at timestamptz,
  first_completed_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz,
  version bigint
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.set_my_book_reading(p_book, p_status, p_version, p_request_id);
$$;

REVOKE ALL ON FUNCTION public.set_my_book_reading(uuid, text, bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_my_book_reading(uuid, text, bigint, uuid) TO authenticated;

-- Reconcile annual reading goal progress to include canonical book completions while preserving legacy verified completion.
CREATE OR REPLACE FUNCTION private.refresh_reading_goal_progress()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := COALESCE(NEW.user_id, OLD.user_id);
  v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
  v_goal uuid;
  v_books int;
BEGIN
  SELECT id INTO v_goal
    FROM public.reading_goals
   WHERE user_id = v_user
     AND year = v_year;

  IF v_goal IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COUNT(*) INTO v_books
    FROM (
      SELECT ubr.book_id
        FROM public.user_book_readings ubr
       WHERE ubr.user_id = v_user
         AND ubr.status = 'read'
         AND ubr.completed_at >= make_date(v_year, 1, 1)
      UNION
      SELECT DISTINCT s.book_id
        FROM public.user_progress up
        JOIN public.chapters c ON c.id = up.chapter_id
        JOIN public.seasons s ON s.id = c.season_id
       WHERE up.user_id = v_user
         AND up.status = 'read'::public.shelf_status
         AND up.finished_at >= make_date(v_year, 1, 1)
         AND private.is_book_complete(v_user, s.book_id)
         AND NOT EXISTS (
           SELECT 1
             FROM public.user_book_readings ubr2
            WHERE ubr2.user_id = v_user
              AND ubr2.book_id = s.book_id
              AND ubr2.status <> 'read'
         )
    ) books;

  INSERT INTO public.reading_goal_progress(goal_id, books_done, pages_done, minutes_done, updated_at)
  SELECT
    v_goal,
    v_books,
    (
      SELECT COALESCE(
        SUM(
          CASE
            WHEN page_from IS NOT NULL AND page_to IS NOT NULL AND page_to >= page_from
              THEN page_to - page_from + 1
            ELSE 0
          END
        ),
        0
      )
      FROM public.reading_journal_entries
      WHERE user_id = v_user
        AND entry_date >= make_date(v_year, 1, 1)
    ),
    (
      SELECT COALESCE(SUM(minutes_read), 0)
        FROM public.reading_journal_entries
       WHERE user_id = v_user
         AND entry_date >= make_date(v_year, 1, 1)
    ),
    statement_timestamp()
  ON CONFLICT (goal_id) DO UPDATE
    SET books_done = EXCLUDED.books_done,
        pages_done = EXCLUDED.pages_done,
        minutes_done = EXCLUDED.minutes_done,
        updated_at = statement_timestamp();

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_book_readings_goal_refresh ON public.user_book_readings;
CREATE TRIGGER trg_user_book_readings_goal_refresh
  AFTER INSERT OR UPDATE OR DELETE ON public.user_book_readings
  FOR EACH ROW EXECUTE FUNCTION private.refresh_reading_goal_progress();

-- Reconcile v_user_reading_overview to prefer canonical user_book_readings per book.
CREATE OR REPLACE VIEW public.v_user_reading_overview
WITH (security_invoker = true)
AS
WITH chapter_book_progress AS (
  SELECT
    up.user_id,
    b.id AS book_id,
    COALESCE(NULLIF(b.total_chapters, 0), COUNT(DISTINCT c.id)) AS required_chapters,
    COUNT(DISTINCT c.id) FILTER (WHERE up.status = 'read') AS completed_chapters,
    BOOL_OR(up.status = 'reading') AS has_reading,
    BOOL_OR(up.status = 'want_to_read') AS has_want,
    BOOL_OR(up.status = 'dnf') AS has_dnf
  FROM public.user_progress AS up
  JOIN public.chapters AS c ON c.id = up.chapter_id
  JOIN public.seasons AS s ON s.id = c.season_id
  JOIN public.books AS b ON b.id = s.book_id
  GROUP BY up.user_id, b.id, b.total_chapters
), unified_books AS (
  SELECT
    COALESCE(ubr.user_id, cbp.user_id) AS user_id,
    COALESCE(ubr.book_id, cbp.book_id) AS book_id,
    COALESCE(
      ubr.status,
      CASE
        WHEN cbp.completed_chapters >= cbp.required_chapters AND cbp.required_chapters > 0 THEN 'read'
        WHEN cbp.has_reading OR cbp.completed_chapters > 0 THEN 'reading'
        WHEN cbp.has_dnf THEN 'dnf'
        WHEN cbp.has_want THEN 'want_to_read'
        ELSE NULL
      END
    ) AS effective_status
  FROM public.user_book_readings ubr
  FULL OUTER JOIN chapter_book_progress cbp
    ON cbp.user_id = ubr.user_id
   AND cbp.book_id = ubr.book_id
), progress_summary AS (
  SELECT
    user_id,
    COUNT(*) FILTER (WHERE effective_status = 'read') AS books_read,
    COUNT(*) FILTER (WHERE effective_status = 'reading') AS books_reading,
    COUNT(*) FILTER (WHERE effective_status = 'want_to_read') AS books_want,
    COUNT(*) FILTER (WHERE effective_status = 'dnf') AS books_dnf
  FROM unified_books
  WHERE user_id IS NOT NULL
  GROUP BY user_id
), journal_summary AS (
  SELECT
    user_id,
    COALESCE(SUM(minutes_read), 0) AS total_minutes,
    COUNT(DISTINCT entry_date) AS reading_days,
    COUNT(*) FILTER (WHERE entry_date = CURRENT_DATE) AS read_today
  FROM public.reading_journal_entries
  GROUP BY user_id
)
SELECT
  p.id AS user_id,
  COALESCE(ps.books_read, 0) AS books_read,
  COALESCE(ps.books_reading, 0) AS books_reading,
  COALESCE(ps.books_want, 0) AS books_want,
  COALESCE(ps.books_dnf, 0) AS books_dnf,
  COALESCE(js.total_minutes, 0) AS total_minutes,
  COALESCE(js.reading_days, 0) AS reading_days,
  COALESCE(js.read_today, 0) AS read_today
FROM public.profiles AS p
LEFT JOIN progress_summary AS ps ON ps.user_id = p.id
LEFT JOIN journal_summary AS js ON js.user_id = p.id;

GRANT SELECT ON public.v_user_reading_overview TO anon, authenticated, service_role;
