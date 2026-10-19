-- Migration: 20261018001700_strict_up_next_and_goals.sql
-- Description: Strict transactional contracts for reading queue reorder/removal and goals concurrency (QA-19, QA-20)

-- 1. Reordenação exata de fila com validação estrita de conjunto (QA-19)
CREATE OR REPLACE FUNCTION public.reorder_up_next(p_book_ids uuid[])
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_count integer;
  v_max bigint;
  v_offset bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF p_book_ids IS NULL THEN
    RAISE EXCEPTION 'invalid_order' USING ERRCODE = '22023';
  END IF;
  IF cardinality(p_book_ids) > 0 AND array_ndims(p_book_ids) <> 1 THEN
    RAISE EXCEPTION 'invalid_order_dimension' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text, 0));

  SELECT count(*), coalesce(max(position), 0)
    INTO v_count, v_max FROM public.user_up_next WHERE user_id = v_user;

  IF cardinality(p_book_ids) <> v_count
     OR (SELECT count(DISTINCT x) FROM unnest(p_book_ids) AS x) <> v_count
     OR EXISTS (
       SELECT 1 FROM unnest(p_book_ids) AS ids(book_id)
       WHERE ids.book_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM public.user_up_next q
         WHERE q.user_id = v_user AND q.book_id = ids.book_id
       )
     ) THEN
    RAISE EXCEPTION 'queue_changed_or_invalid_order' USING ERRCODE = '40900';
  END IF;
  IF v_count = 0 THEN RETURN true; END IF;

  v_offset := v_max + v_count + 1;
  IF v_max + v_offset > 2147483647 THEN
    RAISE EXCEPTION 'queue_position_capacity' USING ERRCODE = '22003';
  END IF;
  UPDATE public.user_up_next SET position = position + v_offset::integer
   WHERE user_id = v_user;

  UPDATE public.user_up_next AS q SET position = ordered.pos::integer
    FROM unnest(p_book_ids) WITH ORDINALITY AS ordered(book_id, pos)
   WHERE q.user_id = v_user AND q.book_id = ordered.book_id;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.reorder_up_next(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reorder_up_next(uuid[]) TO authenticated, service_role;

-- 2. Remoção atômica de fila sob o mesmo lock
CREATE OR REPLACE FUNCTION public.remove_from_up_next_atomic(p_book uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_old_pos integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '42501'; END IF;
  IF p_book IS NULL THEN RAISE EXCEPTION 'invalid_book' USING errcode = '22023'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text, 0));

  DELETE FROM public.user_up_next
   WHERE user_id = v_user AND book_id = p_book
  RETURNING position INTO v_old_pos;

  IF FOUND THEN
    UPDATE public.user_up_next
       SET position = position - 1
     WHERE user_id = v_user AND position > v_old_pos;
    RETURN true;
  END IF;
  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_from_up_next_atomic(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_from_up_next_atomic(uuid) TO authenticated, service_role;

-- 3. Atualização estrita de metas com bloqueio FOR UPDATE e validação de versão (QA-20)
CREATE OR REPLACE FUNCTION public.set_personal_reading_goal(
  p_id uuid,
  p_title text,
  p_year integer,
  p_books integer,
  p_pages integer,
  p_minutes integer,
  p_version bigint
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_goal public.reading_goals%ROWTYPE;
  v_title text := btrim(COALESCE(p_title, 'Minha meta de leitura'));
  v_target_id uuid;
  v_target_version bigint;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '42501'; END IF;
  IF p_year IS NULL OR p_year < 2020 OR p_year > 2050 THEN RAISE EXCEPTION 'invalid_year' USING errcode = '22023'; END IF;
  IF length(v_title) < 1 OR length(v_title) > 120 THEN RAISE EXCEPTION 'invalid_title' USING errcode = '22023'; END IF;

  IF (p_books IS NOT NULL AND (p_books < 1 OR p_books > 365))
     OR (p_pages IS NOT NULL AND (p_pages < 1 OR p_pages > 50000))
     OR (p_minutes IS NOT NULL AND (p_minutes < 1 OR p_minutes > 500000)) THEN
    RAISE EXCEPTION 'invalid_target' USING errcode = '22023';
  END IF;
  IF p_books IS NULL AND p_pages IS NULL AND p_minutes IS NULL THEN
    RAISE EXCEPTION 'at_least_one_target_required' USING errcode = '22023';
  END IF;

  IF p_id IS NOT NULL THEN
    SELECT * INTO v_goal FROM public.reading_goals WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING errcode = 'P0002'; END IF;
    IF v_goal.user_id <> v_user THEN RAISE EXCEPTION 'forbidden' USING errcode = '42501'; END IF;
    IF v_goal.archived_at IS NOT NULL THEN RAISE EXCEPTION 'goal_archived' USING errcode = '40900'; END IF;
    IF p_version IS NULL OR v_goal.version <> p_version THEN RAISE EXCEPTION 'conflict' USING errcode = '40900'; END IF;
    IF p_year <> v_goal.year THEN RAISE EXCEPTION 'goal_year_is_immutable' USING errcode = '22023'; END IF;

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
    'targetBooks', p_books,
    'targetPages', p_pages,
    'targetMinutes', p_minutes,
    'target_books', p_books,
    'target_pages', p_pages,
    'target_minutes', p_minutes,
    'version', v_target_version
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) TO authenticated, service_role;
