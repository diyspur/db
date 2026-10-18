-- Migration: 20261018001100_reading_goals_crud_and_progress.sql
-- Description: Multi-goal recalculation and optimistic CRUD RPCs (QA-03, QA-04)

-- 1. Helper function to recalculate all active goals for a user in a specific calendar year
CREATE OR REPLACE FUNCTION private.recalculate_reading_goals_for_user_year(p_user uuid, p_year int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_books int;
  v_pages int;
  v_minutes int;
  v_start_date date := pg_catalog.make_date(p_year, 1, 1);
  v_end_date date := pg_catalog.make_date(p_year + 1, 1, 1);
BEGIN
  IF p_user IS NULL OR p_year IS NULL THEN
    RETURN;
  END IF;

  -- Contagem de livros canônicos distintos concluídos no ano
  SELECT COUNT(*) INTO v_books
  FROM (
    SELECT ubr.book_id
    FROM public.user_book_readings ubr
    WHERE ubr.user_id = p_user
      AND ubr.status = 'read'
      AND ubr.completed_at >= v_start_date
      AND ubr.completed_at < v_end_date
    UNION
    SELECT DISTINCT s.book_id
    FROM public.user_progress up
    JOIN public.chapters c ON c.id = up.chapter_id
    JOIN public.seasons s ON s.id = c.season_id
    WHERE up.user_id = p_user
      AND up.status = 'read'::public.shelf_status
      AND up.finished_at >= v_start_date
      AND up.finished_at < v_end_date
      AND private.is_book_complete(p_user, s.book_id)
      AND NOT EXISTS (
        SELECT 1
        FROM public.user_book_readings ubr2
        WHERE ubr2.user_id = p_user
          AND ubr2.book_id = s.book_id
          AND ubr2.status <> 'read'
      )
  ) books;

  -- Soma de páginas e minutos lidos a partir de registros ativos do diário no ano
  SELECT
    COALESCE(SUM(
      CASE
        WHEN rje.page_to IS NOT NULL AND rje.page_from IS NOT NULL AND rje.page_to >= rje.page_from THEN rje.page_to - rje.page_from + 1
        WHEN rje.page_to IS NOT NULL THEN rje.page_to
        ELSE 0
      END
    ), 0),
    COALESCE(SUM(rje.minutes_read), 0)
  INTO v_pages, v_minutes
  FROM public.reading_journal_entries rje
  WHERE rje.user_id = p_user
    AND rje.entry_date >= v_start_date
    AND rje.entry_date < v_end_date
    AND rje.archived_at IS NULL;

  -- Atualiza todas as metas ativas do usuário naquele ano
  INSERT INTO public.reading_goal_progress
    (goal_id, books_done, pages_done, minutes_done, updated_at)
  SELECT g.id, v_books, v_pages, v_minutes, pg_catalog.clock_timestamp()
  FROM public.reading_goals g
  WHERE g.user_id = p_user
    AND g.year = p_year
    AND g.archived_at IS NULL
  ON CONFLICT (goal_id) DO UPDATE
  SET books_done = EXCLUDED.books_done,
      pages_done = EXCLUDED.pages_done,
      minutes_done = EXCLUDED.minutes_done,
      updated_at = EXCLUDED.updated_at;
END;
$$;

-- 2. Trigger function ajustada para despachar recálculo em todas as metas ativas
CREATE OR REPLACE FUNCTION private.refresh_reading_goal_progress()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := COALESCE(NEW.user_id, OLD.user_id);
  v_year int;
  v_old_year int;
  v_event_date timestamptz;
BEGIN
  IF TG_TABLE_NAME = 'reading_journal_entries' THEN
    v_event_date := COALESCE(NEW.entry_date::timestamptz, OLD.entry_date::timestamptz);
  ELSIF TG_TABLE_NAME = 'user_book_readings' THEN
    v_event_date := COALESCE(NEW.completed_at, OLD.completed_at, NEW.updated_at, OLD.updated_at);
  ELSIF TG_TABLE_NAME = 'user_progress' THEN
    v_event_date := COALESCE(NEW.finished_at, OLD.finished_at, NEW.updated_at, OLD.updated_at);
  END IF;

  v_year := COALESCE(EXTRACT(YEAR FROM v_event_date)::int, EXTRACT(YEAR FROM pg_catalog.current_date)::int);

  -- Se houve mudança de data entre anos, recalcula ambos
  IF TG_OP = 'UPDATE' THEN
    IF TG_TABLE_NAME = 'reading_journal_entries' AND OLD.entry_date IS NOT NULL THEN
      v_old_year := EXTRACT(YEAR FROM OLD.entry_date)::int;
      IF v_old_year IS DISTINCT FROM v_year THEN
        PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_old_year);
      END IF;
    ELSIF TG_TABLE_NAME = 'user_book_readings' AND OLD.completed_at IS NOT NULL THEN
      v_old_year := EXTRACT(YEAR FROM OLD.completed_at)::int;
      IF v_old_year IS DISTINCT FROM v_year THEN
        PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_old_year);
      END IF;
    END IF;
  END IF;

  PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_year);

  RETURN NULL;
END;
$$;

-- 3. RPC para criação / edição de metas com versão e bloqueio otimista
CREATE OR REPLACE FUNCTION public.set_personal_reading_goal(
  p_id uuid,
  p_title text,
  p_year integer,
  p_books integer,
  p_pages integer,
  p_minutes integer,
  p_version bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_goal public.reading_goals%ROWTYPE;
  v_title text := btrim(COALESCE(p_title, 'Minha meta de leitura'));
  v_target_id uuid;
  v_target_version bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '42501';
  END IF;

  IF p_year IS NULL OR p_year < 2020 OR p_year > 2050 THEN
    RAISE EXCEPTION 'invalid_year' USING errcode = '22023';
  END IF;

  IF (p_books IS NOT NULL AND p_books < 0)
     OR (p_pages IS NOT NULL AND p_pages < 0)
     OR (p_minutes IS NOT NULL AND p_minutes < 0) THEN
    RAISE EXCEPTION 'invalid_target' USING errcode = '22023';
  END IF;

  IF (p_books IS NULL OR p_books <= 0)
     AND (p_pages IS NULL OR p_pages <= 0)
     AND (p_minutes IS NULL OR p_minutes <= 0) THEN
    RAISE EXCEPTION 'at_least_one_target_required' USING errcode = '22023';
  END IF;

  IF length(v_title) < 1 OR length(v_title) > 120 THEN
    RAISE EXCEPTION 'invalid_title' USING errcode = '22023';
  END IF;

  -- Se p_id foi fornecido, verifica existência e propriedade
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_goal
    FROM public.reading_goals
    WHERE id = p_id;

    IF FOUND THEN
      IF v_goal.user_id <> v_user THEN
        RAISE EXCEPTION 'forbidden' USING errcode = '42501';
      END IF;

      IF p_version IS NOT NULL AND v_goal.version <> p_version THEN
        RAISE EXCEPTION 'conflict' USING errcode = '40900';
      END IF;

      UPDATE public.reading_goals
      SET title = v_title,
          year = p_year,
          target_books = p_books,
          target_pages = p_pages,
          target_minutes = p_minutes,
          version = v_goal.version + 1,
          updated_at = pg_catalog.clock_timestamp()
      WHERE id = p_id
      RETURNING * INTO v_goal;

      v_target_id := v_goal.id;
    END IF;
  END IF;

  -- Se for nova meta
  IF v_target_id IS NULL THEN
    v_target_id := COALESCE(p_id, pg_catalog.gen_random_uuid());
    INSERT INTO public.reading_goals (
      id, user_id, title, year, target_books, target_pages, target_minutes, version, created_at, updated_at
    ) VALUES (
      v_target_id, v_user, v_title, p_year, p_books, p_pages, p_minutes, 1, pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_goal;
  END IF;

  -- Recalcula progresso imediatamente
  PERFORM private.recalculate_reading_goals_for_user_year(v_user, p_year);

  RETURN pg_catalog.jsonb_build_object(
    'id', v_goal.id,
    'user_id', v_goal.user_id,
    'title', v_goal.title,
    'year', v_goal.year,
    'target_books', v_goal.target_books,
    'target_pages', v_goal.target_pages,
    'target_minutes', v_goal.target_minutes,
    'version', v_goal.version,
    'created_at', v_goal.created_at,
    'updated_at', v_goal.updated_at
  );
END;
$$;

-- 4. RPC para arquivamento de metas
CREATE OR REPLACE FUNCTION public.archive_personal_reading_goal(
  p_id uuid,
  p_version bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_goal public.reading_goals%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_goal
  FROM public.reading_goals
  WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING errcode = 'P0002';
  END IF;

  IF v_goal.user_id <> v_user THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF p_version IS NOT NULL AND v_goal.version <> p_version THEN
    RAISE EXCEPTION 'conflict' USING errcode = '40900';
  END IF;

  UPDATE public.reading_goals
  SET archived_at = pg_catalog.clock_timestamp(),
      version = v_goal.version + 1,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_id;

  -- Remove registro de progresso da meta arquivada
  DELETE FROM public.reading_goal_progress WHERE goal_id = p_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.archive_personal_reading_goal(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.archive_personal_reading_goal(uuid, bigint) TO authenticated, service_role;
