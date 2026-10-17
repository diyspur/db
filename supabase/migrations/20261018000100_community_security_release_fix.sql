-- Migration: 20261018000100_community_security_release_fix.sql
-- Description: Revoke unlinked club creation, enforce canonical official groups, and harden attendance confirmation

-- 1. Revogar execucao da criacao legada de clubes avulsos sem livro
REVOKE EXECUTE ON FUNCTION public.create_user_club(text, text, boolean, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.create_user_club(text, text, boolean, uuid) FROM PUBLIC, anon, authenticated;

-- 2. Trigger para barrar insercao de clubes que nao sejam oficiais e atrelados a um livro
CREATE OR REPLACE FUNCTION private.require_canonical_new_group()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.kind IS DISTINCT FROM 'official'
     OR NEW.official_book_id IS NULL
     OR NEW.current_book_id IS DISTINCT FROM NEW.official_book_id
     OR NEW.is_private THEN
    RAISE EXCEPTION 'book_required_for_group' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_require_canonical_new_group ON public.user_clubs;
CREATE TRIGGER trg_require_canonical_new_group
BEFORE INSERT ON public.user_clubs
FOR EACH ROW EXECUTE FUNCTION private.require_canonical_new_group();

-- 3. Correcao de seguranca em confirm_meeting_attendance_safe
-- Impede bypass de current_user em funcoes SECURITY DEFINER
CREATE OR REPLACE FUNCTION private.confirm_meeting_attendance_safe(
  p_user uuid,
  p_meeting uuid,
  p_proof_type text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT (
    COALESCE(auth.role() = 'service_role', false)
    OR COALESCE(public.is_admin(), false)
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_proof_type IS NULL OR p_proof_type NOT IN ('moderator', 'replay_confirmation') THEN
    RAISE EXCEPTION 'invalid_attendance_proof' USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.meetings m
    WHERE m.id = p_meeting AND m.status <> 'cancelled'::public.meeting_status
  ) THEN
    RAISE EXCEPTION 'meeting_unavailable' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.meeting_attendance(user_id, meeting_id, proof_type, confirmed_at)
  VALUES (p_user, p_meeting, p_proof_type, now())
  ON CONFLICT (user_id, meeting_id)
  DO UPDATE SET proof_type = EXCLUDED.proof_type, confirmed_at = now();

  PERFORM public.award_xp(p_user, 'join_meeting'::public.xp_source, 30, p_meeting);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_meeting_attendance(
  p_user uuid,
  p_meeting uuid,
  p_proof_type text
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.confirm_meeting_attendance_safe(p_user, p_meeting, p_proof_type);
$$;

GRANT EXECUTE ON FUNCTION public.confirm_meeting_attendance(uuid, uuid, text) TO authenticated, service_role;
