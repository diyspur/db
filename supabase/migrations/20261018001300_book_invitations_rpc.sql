-- Migration: 20261018001300_book_invitations_rpc.sql
-- Description: RPC for creating and managing book share invitations (QA-09, QA-10)

CREATE OR REPLACE FUNCTION public.create_book_share_invitation(
  p_book uuid,
  p_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sender uuid := (SELECT auth.uid());
  v_clean_email text := lower(btrim(p_email));
  v_book_title text;
  v_token text := pg_catalog.encode(pg_catalog.gen_random_bytes(32), 'hex');
  v_hash text;
  v_id uuid;
BEGIN
  IF v_sender IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '42501';
  END IF;

  IF p_book IS NULL THEN
    RAISE EXCEPTION 'invalid_book' USING errcode = '22023';
  END IF;

  SELECT title INTO v_book_title
  FROM public.books
  WHERE id = p_book;

  IF v_book_title IS NULL THEN
    RAISE EXCEPTION 'book_not_found' USING errcode = 'P0002';
  END IF;

  IF v_clean_email IS NULL OR v_clean_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_clean_email) > 255 THEN
    RAISE EXCEPTION 'invalid_email' USING errcode = '22023';
  END IF;

  -- Computa hash do token usando sha256 (via sha256 function ou digest)
  v_hash := pg_catalog.encode(pg_catalog.sha256(v_token::bytea), 'hex');

  -- Insere convite na tabela privada
  INSERT INTO private.book_share_invitations (
    book_id,
    sender_user_id,
    recipient_email,
    token_hash,
    status,
    expires_at,
    created_at
  ) VALUES (
    p_book,
    v_sender,
    v_clean_email,
    v_hash,
    'pending',
    pg_catalog.clock_timestamp() + interval '7 days',
    pg_catalog.clock_timestamp()
  )
  RETURNING id INTO v_id;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'invitation_id', v_id,
    'message', 'Convite enviado com sucesso para o leitor.'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_book_share_invitation(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_book_share_invitation(uuid, text) TO authenticated, service_role;
