-- Migration: 20261018001600_up_next_reorder_rpc.sql
-- Description: RPC to safely and atomically reorder continuous up_next reading queue (QA-22)

CREATE OR REPLACE FUNCTION public.reorder_up_next(p_book_ids uuid[])
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  i integer;
  v_count integer;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING errcode = '42501';
  END IF;

  -- Bloqueio transacional por usuário para serializar alterações na fila
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user::text, 0)
  );

  IF p_book_ids IS NULL OR array_length(p_book_ids, 1) = 0 THEN
    RETURN true;
  END IF;

  -- Valida se existem duplicatas no array de entrada
  SELECT count(DISTINCT id) INTO v_count
  FROM unnest(p_book_ids) AS id;

  IF v_count <> array_length(p_book_ids, 1) THEN
    RAISE EXCEPTION 'duplicate_books_in_order' USING errcode = '22023';
  END IF;

  -- Desloca todas as posições atuais para uma faixa temporária > 1.000.000
  -- evitando violações da restrição UNIQUE (user_id, position)
  UPDATE public.user_up_next
     SET position = position + 1000000
   WHERE user_id = v_user;

  -- Atualiza na nova ordem sequencial (1..N)
  FOR i IN 1 .. array_length(p_book_ids, 1) LOOP
    UPDATE public.user_up_next
       SET position = i
     WHERE user_id = v_user
       AND book_id = p_book_ids[i];
  END LOOP;

  -- Renumera quaisquer livros restantes que não constavam em p_book_ids
  WITH leftovers AS (
    SELECT book_id, row_number() OVER (ORDER BY position ASC) AS rn
      FROM public.user_up_next
     WHERE user_id = v_user AND position > 1000000
  )
  UPDATE public.user_up_next u
     SET position = array_length(p_book_ids, 1) + l.rn
    FROM leftovers l
   WHERE u.user_id = v_user AND u.book_id = l.book_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.reorder_up_next(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reorder_up_next(uuid[]) TO authenticated, service_role;
