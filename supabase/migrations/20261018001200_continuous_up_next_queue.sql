-- Migration: 20261018001200_continuous_up_next_queue.sql
-- Description: Continuous reading queue without 5-book cap (QA-06)

DO $$
DECLARE v_constraint text;
BEGIN
  FOR v_constraint IN
    SELECT c.conname
    FROM pg_catalog.pg_constraint c
    WHERE c.conrelid = 'public.user_up_next'::regclass
      AND c.contype = 'c'
  LOOP
    EXECUTE format('ALTER TABLE public.user_up_next DROP CONSTRAINT %I', v_constraint);
  END LOOP;
END;
$$;

ALTER TABLE public.user_up_next
  ADD CONSTRAINT user_up_next_position_check CHECK (position > 0);

CREATE OR REPLACE FUNCTION public.add_to_up_next_atomic(p_book uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_position integer;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING errcode = '42501';
  END IF;

  -- Bloqueio transacional por usuário para evitar condição de corrida
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user::text, 0)
  );

  -- Se o livro já estiver na fila do usuário, retorna a posição atual sem duplicar
  SELECT q.position INTO v_position
  FROM public.user_up_next q
  WHERE q.user_id = v_user AND q.book_id = p_book;

  IF FOUND THEN
    RETURN v_position;
  END IF;

  -- Aloca próxima posição sequencial na playlist contínua
  SELECT COALESCE(MAX(q.position), 0) + 1 INTO v_position
  FROM public.user_up_next q
  WHERE q.user_id = v_user;

  INSERT INTO public.user_up_next(user_id, book_id, position)
  VALUES (v_user, p_book, v_position);

  RETURN v_position;
END;
$$;

REVOKE ALL ON FUNCTION public.add_to_up_next_atomic(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_to_up_next_atomic(uuid) TO authenticated, service_role;
