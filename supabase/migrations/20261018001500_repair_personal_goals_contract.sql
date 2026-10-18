-- Migration: 20261018001500_repair_personal_goals_contract.sql
-- Description: Repair reading_goals contract, add updated_at column, fix trigger dispatch and enforce validated limits (QA-01, QA-02, QA-23)

-- 1. Garantir que a coluna updated_at existe em public.reading_goals (QA-01)
ALTER TABLE public.reading_goals
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- 2. Recalcular metas garantindo limpeza de progresso de metas arquivadas
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

  -- Remove progresso de metas que foram arquivadas
  DELETE FROM public.reading_goal_progress
  WHERE goal_id IN (
    SELECT g.id
    FROM public.reading_goals g
    WHERE g.user_id = p_user
      AND g.year = p_year
      AND g.archived_at IS NOT NULL
  );

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

REVOKE ALL ON FUNCTION private.recalculate_reading_goals_for_user_year(uuid, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.recalculate_reading_goals_for_user_year(uuid, int) TO authenticated, service_role;

-- 3. Corrigir private.refresh_reading_goal_progress() com dispatch estrito por tabela (QA-02)
CREATE OR REPLACE FUNCTION private.refresh_reading_goal_progress()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid;
  v_old_year integer;
  v_new_year integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_user := OLD.user_id;
  ELSE
    v_user := NEW.user_id;
  END IF;

  IF TG_TABLE_NAME = 'reading_goals' THEN
    IF TG_OP <> 'INSERT' THEN v_old_year := OLD.year; END IF;
    IF TG_OP <> 'DELETE' THEN v_new_year := NEW.year; END IF;
  ELSIF TG_TABLE_NAME = 'reading_journal_entries' THEN
    IF TG_OP <> 'INSERT' THEN v_old_year := EXTRACT(YEAR FROM OLD.entry_date)::int; END IF;
    IF TG_OP <> 'DELETE' THEN v_new_year := EXTRACT(YEAR FROM NEW.entry_date)::int; END IF;
  ELSIF TG_TABLE_NAME = 'user_book_readings' THEN
    IF TG_OP <> 'INSERT' THEN
      v_old_year := EXTRACT(YEAR FROM COALESCE(OLD.completed_at, OLD.updated_at))::int;
    END IF;
    IF TG_OP <> 'DELETE' THEN
      v_new_year := EXTRACT(YEAR FROM COALESCE(NEW.completed_at, NEW.updated_at))::int;
    END IF;
  ELSIF TG_TABLE_NAME = 'user_progress' THEN
    IF TG_OP <> 'INSERT' THEN
      v_old_year := EXTRACT(YEAR FROM COALESCE(OLD.finished_at, OLD.updated_at))::int;
    END IF;
    IF TG_OP <> 'DELETE' THEN
      v_new_year := EXTRACT(YEAR FROM COALESCE(NEW.finished_at, NEW.updated_at))::int;
    END IF;
  ELSE
    RAISE EXCEPTION 'unsupported_goal_progress_source';
  END IF;

  IF v_old_year IS NOT NULL THEN
    PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_old_year);
  END IF;
  IF v_new_year IS NOT NULL AND v_new_year IS DISTINCT FROM v_old_year THEN
    PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_new_year);
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.refresh_reading_goal_progress() FROM PUBLIC, anon, authenticated;

-- Garantir que o trigger está anexado a public.reading_goals
DROP TRIGGER IF EXISTS trg_goal_progress_refresh_goal ON public.reading_goals;
CREATE TRIGGER trg_goal_progress_refresh_goal
  AFTER INSERT OR UPDATE OR DELETE
  ON public.reading_goals
  FOR EACH ROW
  EXECUTE FUNCTION private.refresh_reading_goal_progress();

-- 4. Atualizar RPC set_personal_reading_goal com limites alinhados e SELECT FOR UPDATE (QA-23)
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

  IF (p_books IS NOT NULL AND (p_books < 0 OR p_books > 365))
     OR (p_pages IS NOT NULL AND (p_pages < 0 OR p_pages > 50000))
     OR (p_minutes IS NOT NULL AND (p_minutes < 0 OR p_minutes > 500000)) THEN
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

  -- Se p_id foi fornecido, verifica existência e propriedade com bloqueio para update
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_goal
    FROM public.reading_goals
    WHERE id = p_id
    FOR UPDATE;

    IF FOUND THEN
      IF v_goal.user_id <> v_user THEN
        RAISE EXCEPTION 'forbidden' USING errcode = '42501';
      END IF;

      -- Verificação de versão para controle de concorrência otimista
      IF p_version IS NOT NULL AND v_goal.version <> p_version THEN
        RAISE EXCEPTION 'conflict' USING errcode = '40900';
      END IF;

      UPDATE public.reading_goals
      SET title = v_title,
          target_books = p_books,
          target_pages = p_pages,
          target_minutes = p_minutes,
          version = v_goal.version + 1,
          updated_at = now()
      WHERE id = v_goal.id
      RETURNING id, version INTO v_target_id, v_target_version;
    ELSE
      -- ID especificado mas não encontrado
      v_target_id := p_id;
      v_target_version := 1;
      INSERT INTO public.reading_goals (
        id, user_id, title, year, target_books, target_pages, target_minutes, version, created_at, updated_at
      ) VALUES (
        v_target_id, v_user, v_title, p_year, p_books, p_pages, p_minutes, v_target_version, now(), now()
      );
    END IF;
  ELSE
    v_target_id := gen_random_uuid();
    v_target_version := 1;
    INSERT INTO public.reading_goals (
      id, user_id, title, year, target_books, target_pages, target_minutes, version, created_at, updated_at
    ) VALUES (
      v_target_id, v_user, v_title, p_year, p_books, p_pages, p_minutes, v_target_version, now(), now()
    );
  END IF;

  PERFORM private.recalculate_reading_goals_for_user_year(v_user, p_year);

  RETURN jsonb_build_object(
    'id', v_target_id,
    'title', v_title,
    'year', p_year,
    'target_books', p_books,
    'target_pages', p_pages,
    'target_minutes', p_minutes,
    'version', v_target_version
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) TO authenticated;

-- 5. Atualizar archive_personal_reading_goal com SELECT FOR UPDATE e limpeza atômica
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
  WHERE id = p_id
  FOR UPDATE;

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
  SET archived_at = now(),
      version = v_goal.version + 1,
      updated_at = now()
  WHERE id = v_goal.id;

  DELETE FROM public.reading_goal_progress
  WHERE goal_id = v_goal.id;

  PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_goal.year);

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.archive_personal_reading_goal(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.archive_personal_reading_goal(uuid, bigint) TO authenticated;
