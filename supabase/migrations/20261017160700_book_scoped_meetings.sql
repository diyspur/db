-- M07: Book-scoped and club-scoped meetings with optional chapter and versioned management RPCs.
-- Immutable additive migration.

ALTER TABLE public.meetings
  ADD COLUMN IF NOT EXISTS book_id uuid REFERENCES public.books(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS club_id uuid REFERENCES public.user_clubs(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS spoiler_policy text NOT NULL DEFAULT 'none'
    CHECK (spoiler_policy IN ('none', 'whole_book', 'chapter')),
  ADD COLUMN IF NOT EXISTS version bigint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE public.meetings m
   SET book_id = s.book_id
  FROM public.chapters c
  JOIN public.seasons s ON s.id = c.season_id
 WHERE c.id = m.chapter_id
   AND m.book_id IS NULL;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.meetings WHERE book_id IS NULL) THEN
    RAISE EXCEPTION 'meeting_book_backfill_incomplete';
  END IF;
END $$;

ALTER TABLE public.meetings
  ALTER COLUMN book_id SET NOT NULL,
  ALTER COLUMN chapter_id DROP NOT NULL;

-- Replace chapter_id ON DELETE CASCADE with ON DELETE RESTRICT so chapter removal never wipes meetings/RSVPs silently.
DO $$
DECLARE
  v_conname text;
BEGIN
  FOR v_conname IN
    SELECT c.conname
      FROM pg_catalog.pg_constraint c
      JOIN pg_catalog.pg_attribute a
        ON a.attrelid = c.conrelid
       AND a.attnum = ANY(c.conkey)
     WHERE c.conrelid = 'public.meetings'::regclass
       AND c.contype = 'f'
       AND a.attname = 'chapter_id'
  LOOP
    EXECUTE format('ALTER TABLE public.meetings DROP CONSTRAINT %I', v_conname);
  END LOOP;

  ALTER TABLE public.meetings
    ADD CONSTRAINT meetings_chapter_id_fkey
    FOREIGN KEY (chapter_id) REFERENCES public.chapters(id) ON DELETE RESTRICT;
END $$;

CREATE INDEX IF NOT EXISTS meetings_book_schedule_idx
  ON public.meetings(book_id, scheduled_at, id);

CREATE INDEX IF NOT EXISTS meetings_club_schedule_idx
  ON public.meetings(club_id, scheduled_at, id);

CREATE INDEX IF NOT EXISTS meetings_chapter_idx
  ON public.meetings(chapter_id);

CREATE INDEX IF NOT EXISTS meetings_created_by_idx
  ON public.meetings(created_by);

CREATE TABLE IF NOT EXISTS private.meeting_operation_requests (
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  operation text NOT NULL,
  request_id uuid NOT NULL,
  payload_hash text NOT NULL,
  meeting_id uuid NOT NULL REFERENCES public.meetings(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_id, operation, request_id)
);

REVOKE ALL ON private.meeting_operation_requests FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.validate_meeting_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_chapter_book uuid;
  v_club_kind text;
  v_official_book uuid;
  v_current_book uuid;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (OLD.book_id IS DISTINCT FROM NEW.book_id OR OLD.club_id IS DISTINCT FROM NEW.club_id)
       AND NOT COALESCE((SELECT public.is_admin()), false)
       AND current_user NOT IN ('postgres', 'service_role') THEN
      RAISE EXCEPTION 'cannot_change_meeting_scope' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NEW.chapter_id IS NOT NULL THEN
    SELECT s.book_id INTO v_chapter_book
      FROM public.chapters c
      JOIN public.seasons s ON s.id = c.season_id
     WHERE c.id = NEW.chapter_id;

    IF NOT FOUND OR v_chapter_book IS DISTINCT FROM NEW.book_id THEN
      RAISE EXCEPTION 'meeting_chapter_book_mismatch' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.club_id IS NOT NULL THEN
    SELECT kind, official_book_id, current_book_id
      INTO v_club_kind, v_official_book, v_current_book
      FROM public.user_clubs
     WHERE id = NEW.club_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'club_not_found' USING ERRCODE = '23503';
    END IF;

    IF v_club_kind = 'official' AND v_official_book IS DISTINCT FROM NEW.book_id THEN
      RAISE EXCEPTION 'meeting_club_book_mismatch' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.duration_min IS NOT NULL AND NEW.duration_min NOT BETWEEN 15 AND 480 THEN
    RAISE EXCEPTION 'invalid_meeting_duration' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.validate_meeting_context() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_meetings_validate_context ON public.meetings;
CREATE TRIGGER trg_meetings_validate_context
  BEFORE INSERT OR UPDATE ON public.meetings
  FOR EACH ROW EXECUTE FUNCTION private.validate_meeting_context();

CREATE OR REPLACE FUNCTION private.can_view_meeting(p_meeting uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((SELECT public.is_admin()), false) OR EXISTS (
    SELECT 1
      FROM public.meetings m
      JOIN public.books b ON b.id = m.book_id
      LEFT JOIN public.user_clubs cl ON cl.id = m.club_id
     WHERE m.id = p_meeting
       AND (
         m.club_id IS NULL
         OR private.can_view_user_club(m.club_id)
       )
       AND (
         m.chapter_id IS NULL
         OR private.can_view_chapter(m.chapter_id)
       )
  );
$$;

REVOKE ALL ON FUNCTION private.can_view_meeting(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_view_meeting(uuid) TO anon, authenticated;

DROP POLICY IF EXISTS meetings_read ON public.meetings;
CREATE POLICY meetings_read ON public.meetings
  FOR SELECT TO anon, authenticated
  USING (private.can_view_meeting(id));

DROP POLICY IF EXISTS meeting_rsvps_insert_owner ON public.meeting_rsvps;
CREATE POLICY meeting_rsvps_insert_owner ON public.meeting_rsvps
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND private.can_view_meeting(meeting_id)
  );

DROP POLICY IF EXISTS meeting_rsvps_update_owner ON public.meeting_rsvps;
CREATE POLICY meeting_rsvps_update_owner ON public.meeting_rsvps
  FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND private.can_view_meeting(meeting_id)
  );

-- Club meeting creation, update, and cancellation RPCs.
CREATE OR REPLACE FUNCTION private.create_club_meeting(
  p_club uuid,
  p_book uuid,
  p_chapter uuid,
  p_title text,
  p_kind public.meeting_kind,
  p_scheduled_at timestamptz,
  p_duration_min integer,
  p_meeting_url text,
  p_location text,
  p_agenda text,
  p_spoiler_policy text,
  p_request_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_club_kind text;
  v_official_book uuid;
  v_effective_book uuid;
  v_hash text;
  v_req private.meeting_operation_requests%ROWTYPE;
  v_id uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_club IS NULL OR p_request_id IS NULL THEN
    RAISE EXCEPTION 'invalid_meeting' USING ERRCODE = '23514';
  END IF;

  IF NOT private.can_manage_club(p_club, v_user) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT kind, official_book_id
    INTO v_club_kind, v_official_book
    FROM public.user_clubs
   WHERE id = p_club
     AND archived_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'club_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_effective_book := CASE WHEN v_club_kind = 'official' THEN v_official_book ELSE p_book END;
  IF v_effective_book IS NULL OR (v_club_kind = 'official' AND p_book IS NOT NULL AND p_book <> v_official_book) THEN
    RAISE EXCEPTION 'meeting_club_book_mismatch' USING ERRCODE = '23514';
  END IF;

  IF length(btrim(coalesce(p_title, ''))) NOT BETWEEN 3 AND 120
     OR p_scheduled_at IS NULL
     OR COALESCE(p_duration_min, 90) NOT BETWEEN 15 AND 480
     OR length(coalesce(p_agenda, '')) > 4000
     OR COALESCE(p_spoiler_policy, 'none') NOT IN ('none', 'whole_book', 'chapter') THEN
    RAISE EXCEPTION 'invalid_meeting' USING ERRCODE = '23514';
  END IF;

  IF p_kind IN ('online'::public.meeting_kind, 'hybrid'::public.meeting_kind)
     AND (p_meeting_url IS NULL OR p_meeting_url !~* '^https://') THEN
    RAISE EXCEPTION 'invalid_meeting_url' USING ERRCODE = '23514';
  END IF;

  IF p_kind IN ('in_person'::public.meeting_kind, 'hybrid'::public.meeting_kind)
     AND length(btrim(coalesce(p_location, ''))) < 3 THEN
    RAISE EXCEPTION 'invalid_meeting_location' USING ERRCODE = '23514';
  END IF;

  v_hash := md5(
    concat_ws(
      '|',
      p_club::text,
      v_effective_book::text,
      coalesce(p_chapter::text, ''),
      btrim(p_title),
      p_kind::text,
      p_scheduled_at::text,
      coalesce(p_duration_min, 90)::text,
      btrim(coalesce(p_meeting_url, '')),
      btrim(coalesce(p_location, '')),
      btrim(coalesce(p_agenda, '')),
      coalesce(p_spoiler_policy, 'none')
    )
  );

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('meeting-req:' || v_user::text || ':' || p_request_id::text, 0)
  );

  SELECT * INTO v_req
    FROM private.meeting_operation_requests
   WHERE actor_id = v_user
     AND operation = 'create_meeting'
     AND request_id = p_request_id;

  IF FOUND THEN
    IF v_req.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
    END IF;
    RETURN v_req.meeting_id;
  END IF;

  INSERT INTO public.meetings (
    book_id,
    club_id,
    chapter_id,
    title,
    kind,
    status,
    scheduled_at,
    duration_min,
    meeting_url,
    location,
    agenda,
    spoiler_policy,
    created_by,
    version,
    updated_at
  ) VALUES (
    v_effective_book,
    p_club,
    p_chapter,
    btrim(p_title),
    p_kind,
    'scheduled'::public.meeting_status,
    p_scheduled_at,
    COALESCE(p_duration_min, 90),
    nullif(btrim(coalesce(p_meeting_url, '')), ''),
    nullif(btrim(coalesce(p_location, '')), ''),
    nullif(btrim(coalesce(p_agenda, '')), ''),
    COALESCE(p_spoiler_policy, 'none'),
    v_user,
    1,
    now()
  )
  RETURNING id INTO v_id;

  INSERT INTO private.meeting_operation_requests (
    actor_id, operation, request_id, payload_hash, meeting_id
  ) VALUES (
    v_user, 'create_meeting', p_request_id, v_hash, v_id
  );

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION private.create_club_meeting(uuid, uuid, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.create_club_meeting(uuid, uuid, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_club_meeting(
  p_club uuid,
  p_book uuid,
  p_chapter uuid,
  p_title text,
  p_kind public.meeting_kind,
  p_scheduled_at timestamptz,
  p_duration_min integer,
  p_meeting_url text,
  p_location text,
  p_agenda text,
  p_spoiler_policy text,
  p_request_id uuid
) RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.create_club_meeting(
    p_club, p_book, p_chapter, p_title, p_kind, p_scheduled_at,
    p_duration_min, p_meeting_url, p_location, p_agenda, p_spoiler_policy, p_request_id
  );
$$;

REVOKE ALL ON FUNCTION public.create_club_meeting(uuid, uuid, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_club_meeting(uuid, uuid, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.update_club_meeting(
  p_meeting uuid,
  p_version bigint,
  p_chapter uuid,
  p_title text,
  p_kind public.meeting_kind,
  p_scheduled_at timestamptz,
  p_duration_min integer,
  p_meeting_url text,
  p_location text,
  p_agenda text,
  p_spoiler_policy text
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_row public.meetings%ROWTYPE;
  v_version bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
    FROM public.meetings
   WHERE id = p_meeting
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'meeting_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE((SELECT public.is_admin()), false)
    OR (v_row.club_id IS NOT NULL AND private.can_manage_club(v_row.club_id, v_user))
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_row.status = 'cancelled'::public.meeting_status THEN
    RAISE EXCEPTION 'meeting_cancelled' USING ERRCODE = '23514';
  END IF;

  IF v_row.version IS DISTINCT FROM p_version THEN
    RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
  END IF;

  IF length(btrim(coalesce(p_title, ''))) NOT BETWEEN 3 AND 120
     OR p_scheduled_at IS NULL
     OR COALESCE(p_duration_min, 90) NOT BETWEEN 15 AND 480
     OR length(coalesce(p_agenda, '')) > 4000
     OR COALESCE(p_spoiler_policy, 'none') NOT IN ('none', 'whole_book', 'chapter') THEN
    RAISE EXCEPTION 'invalid_meeting' USING ERRCODE = '23514';
  END IF;

  IF p_kind IN ('online'::public.meeting_kind, 'hybrid'::public.meeting_kind)
     AND (p_meeting_url IS NULL OR p_meeting_url !~* '^https://') THEN
    RAISE EXCEPTION 'invalid_meeting_url' USING ERRCODE = '23514';
  END IF;

  IF p_kind IN ('in_person'::public.meeting_kind, 'hybrid'::public.meeting_kind)
     AND length(btrim(coalesce(p_location, ''))) < 3 THEN
    RAISE EXCEPTION 'invalid_meeting_location' USING ERRCODE = '23514';
  END IF;

  UPDATE public.meetings
     SET chapter_id = p_chapter,
         title = btrim(p_title),
         kind = p_kind,
         scheduled_at = p_scheduled_at,
         duration_min = COALESCE(p_duration_min, 90),
         meeting_url = nullif(btrim(coalesce(p_meeting_url, '')), ''),
         location = nullif(btrim(coalesce(p_location, '')), ''),
         agenda = nullif(btrim(coalesce(p_agenda, '')), ''),
         spoiler_policy = COALESCE(p_spoiler_policy, 'none'),
         version = version + 1,
         updated_at = now()
   WHERE id = p_meeting
  RETURNING version INTO v_version;

  RETURN v_version;
END;
$$;

REVOKE ALL ON FUNCTION private.update_club_meeting(uuid, bigint, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.update_club_meeting(uuid, bigint, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_club_meeting(
  p_meeting uuid,
  p_version bigint,
  p_chapter uuid,
  p_title text,
  p_kind public.meeting_kind,
  p_scheduled_at timestamptz,
  p_duration_min integer,
  p_meeting_url text,
  p_location text,
  p_agenda text,
  p_spoiler_policy text
) RETURNS bigint
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.update_club_meeting(
    p_meeting, p_version, p_chapter, p_title, p_kind, p_scheduled_at,
    p_duration_min, p_meeting_url, p_location, p_agenda, p_spoiler_policy
  );
$$;

REVOKE ALL ON FUNCTION public.update_club_meeting(uuid, bigint, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_club_meeting(uuid, bigint, uuid, text, public.meeting_kind, timestamptz, integer, text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION private.cancel_club_meeting(
  p_meeting uuid,
  p_version bigint
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_row public.meetings%ROWTYPE;
  v_version bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
    FROM public.meetings
   WHERE id = p_meeting
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'meeting_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE((SELECT public.is_admin()), false)
    OR (v_row.club_id IS NOT NULL AND private.can_manage_club(v_row.club_id, v_user))
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_row.status = 'cancelled'::public.meeting_status THEN
    RETURN v_row.version;
  END IF;

  IF p_version IS NOT NULL AND v_row.version <> p_version THEN
    RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
  END IF;

  UPDATE public.meetings
     SET status = 'cancelled'::public.meeting_status,
         version = version + 1,
         updated_at = now()
   WHERE id = p_meeting
  RETURNING version INTO v_version;

  RETURN v_version;
END;
$$;

REVOKE ALL ON FUNCTION private.cancel_club_meeting(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.cancel_club_meeting(uuid, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_club_meeting(
  p_meeting uuid,
  p_version bigint
) RETURNS bigint
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.cancel_club_meeting(p_meeting, p_version);
$$;

REVOKE ALL ON FUNCTION public.cancel_club_meeting(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_club_meeting(uuid, bigint) TO authenticated;
