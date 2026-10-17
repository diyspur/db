-- M01: Official book groups, permanent identity, and account-deletion stewardship.
-- Immutable additive migration.

ALTER TABLE public.user_clubs
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'custom',
  ADD COLUMN IF NOT EXISTS official_book_id uuid REFERENCES public.books(id) ON DELETE RESTRICT;

DO $$ BEGIN
  ALTER TABLE public.user_clubs ADD CONSTRAINT club_kind_valid
    CHECK (kind IN ('custom', 'official'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.user_clubs ADD CONSTRAINT official_club_shape
    CHECK (
      (kind = 'official' AND official_book_id IS NOT NULL AND NOT is_private)
      OR (kind = 'custom' AND official_book_id IS NULL)
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE UNIQUE INDEX IF NOT EXISTS user_clubs_one_official_per_book
  ON public.user_clubs(official_book_id)
  WHERE kind = 'official';

CREATE INDEX IF NOT EXISTS user_clubs_current_book_idx
  ON public.user_clubs(current_book_id);

CREATE INDEX IF NOT EXISTS user_clubs_current_season_idx
  ON public.user_clubs(current_season_id);

-- Preserve official groups when the inaugural owner deletes their account.
ALTER TABLE public.user_clubs
  ALTER COLUMN owner_id DROP NOT NULL;

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
     WHERE c.conrelid = 'public.user_clubs'::regclass
       AND c.contype = 'f'
       AND a.attname = 'owner_id'
  LOOP
    EXECUTE format('ALTER TABLE public.user_clubs DROP CONSTRAINT %I', v_conname);
  END LOOP;

  ALTER TABLE public.user_clubs
    ADD CONSTRAINT user_clubs_owner_id_fkey
    FOREIGN KEY (owner_id) REFERENCES public.profiles(id) ON DELETE SET NULL;
END $$;

CREATE INDEX IF NOT EXISTS user_clubs_owner_idx
  ON public.user_clubs(owner_id);

CREATE OR REPLACE FUNCTION private.enforce_user_club_invariants()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_season_book uuid;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.kind IS DISTINCT FROM NEW.kind
       OR OLD.official_book_id IS DISTINCT FROM NEW.official_book_id THEN
      RAISE EXCEPTION 'cannot_change_club_identity' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NEW.kind = 'official' THEN
    IF NEW.official_book_id IS NULL OR NEW.is_private THEN
      RAISE EXCEPTION 'official_club_must_be_public' USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'UPDATE'
       AND OLD.archived_at IS NULL
       AND NEW.archived_at IS NOT NULL
       AND NOT COALESCE((SELECT public.is_admin()), false)
       AND current_user NOT IN ('postgres', 'service_role') THEN
      RAISE EXCEPTION 'only_admin_can_archive_official_club' USING ERRCODE = '42501';
    END IF;

    IF NEW.current_season_id IS NOT NULL THEN
      SELECT s.book_id INTO v_season_book
        FROM public.seasons s
       WHERE s.id = NEW.current_season_id;
      IF NOT FOUND OR v_season_book IS DISTINCT FROM NEW.official_book_id THEN
        RAISE EXCEPTION 'season_book_mismatch' USING ERRCODE = '23514';
      END IF;
    END IF;

    NEW.current_book_id := NEW.official_book_id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.enforce_user_club_invariants() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_user_clubs_integrity ON public.user_clubs;
CREATE TRIGGER trg_user_clubs_integrity
  BEFORE INSERT OR UPDATE ON public.user_clubs
  FOR EACH ROW EXECUTE FUNCTION private.enforce_user_club_invariants();

CREATE OR REPLACE FUNCTION private.handle_profile_delete_clubs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_successor uuid;
BEGIN
  FOR r IN
    SELECT id, kind
      FROM public.user_clubs
     WHERE owner_id = OLD.id
     FOR UPDATE
  LOOP
    v_successor := NULL;
    SELECT m.user_id INTO v_successor
      FROM public.user_club_members m
     WHERE m.club_id = r.id
       AND m.user_id <> OLD.id
     ORDER BY CASE WHEN m.role = 'moderator' THEN 0 ELSE 1 END,
              m.joined_at ASC,
              m.user_id ASC
     LIMIT 1;

    IF v_successor IS NOT NULL THEN
      UPDATE public.user_club_members
         SET role = 'owner'
       WHERE club_id = r.id
         AND user_id = v_successor;
      UPDATE public.user_clubs
         SET owner_id = v_successor,
             version = version + 1
       WHERE id = r.id;
    ELSIF r.kind = 'official' THEN
      UPDATE public.user_clubs
         SET owner_id = NULL,
             version = version + 1
       WHERE id = r.id;
    ELSE
      UPDATE public.user_clubs
         SET owner_id = NULL,
             archived_at = COALESCE(archived_at, now()),
             version = version + 1
       WHERE id = r.id;
    END IF;
  END LOOP;

  RETURN OLD;
END;
$$;

REVOKE ALL ON FUNCTION private.handle_profile_delete_clubs() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_profiles_before_delete_clubs ON public.profiles;
CREATE TRIGGER trg_profiles_before_delete_clubs
  BEFORE DELETE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION private.handle_profile_delete_clubs();

-- Remove duplicate permissive policy uclubs_owner and consolidate visibility in private.can_view_user_club.
DROP POLICY IF EXISTS uclubs_owner ON public.user_clubs;
DROP POLICY IF EXISTS "uclubs_owner" ON public.user_clubs;

CREATE OR REPLACE FUNCTION private.can_view_user_club(p_club uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1
      FROM public.user_clubs c
     WHERE c.id = p_club
       AND (
         (
           c.archived_at IS NULL
           AND (
             NOT c.is_private
             OR c.owner_id = (SELECT auth.uid())
             OR EXISTS (
               SELECT 1
                 FROM public.user_club_members m
                WHERE m.club_id = c.id
                  AND m.user_id = (SELECT auth.uid())
             )
           )
         )
         OR (
           c.archived_at IS NOT NULL
           AND (
             c.owner_id = (SELECT auth.uid())
             OR COALESCE((SELECT public.is_admin()), false)
           )
         )
       )
  );
$fn$;

REVOKE ALL ON FUNCTION private.can_view_user_club(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_view_user_club(uuid) TO anon, authenticated;

-- Update update_user_club to enforce official club invariants and allow platform admin management.
CREATE OR REPLACE FUNCTION private.update_user_club(
  p_club uuid,
  p_version bigint,
  p_name text,
  p_description text,
  p_private boolean,
  p_season_id uuid DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_version bigint;
  v_kind text;
  v_official_book uuid;
  v_owner uuid;
  v_book uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  SELECT version, kind, official_book_id, owner_id
    INTO v_version, v_kind, v_official_book, v_owner
    FROM public.user_clubs
   WHERE id = p_club
     AND archived_at IS NULL
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_owner IS DISTINCT FROM auth.uid() AND NOT COALESCE((SELECT public.is_admin()), false) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_version <> p_version THEN
    RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
  END IF;

  IF length(btrim(coalesce(p_name, ''))) NOT BETWEEN 3 AND 80
     OR length(coalesce(p_description, '')) > 2000
     OR p_private IS NULL THEN
    RAISE EXCEPTION 'invalid_club' USING ERRCODE = '23514';
  END IF;

  IF v_kind = 'official' AND p_private THEN
    RAISE EXCEPTION 'official_club_must_be_public' USING ERRCODE = '42501';
  END IF;

  IF p_season_id IS NOT NULL THEN
    SELECT book_id INTO v_book FROM public.seasons WHERE id = p_season_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'season_not_found' USING ERRCODE = '23503';
    END IF;
    IF v_kind = 'official' AND v_book IS DISTINCT FROM v_official_book THEN
      RAISE EXCEPTION 'season_book_mismatch' USING ERRCODE = '23514';
    END IF;
  END IF;

  UPDATE public.user_clubs
     SET name = btrim(p_name),
         description = nullif(btrim(p_description), ''),
         is_private = CASE WHEN v_kind = 'official' THEN false ELSE p_private END,
         current_season_id = p_season_id,
         current_book_id = CASE WHEN v_kind = 'official' THEN v_official_book ELSE v_book END,
         version = version + 1
   WHERE id = p_club
  RETURNING version INTO v_version;

  RETURN v_version;
END;
$fn$;

REVOKE ALL ON FUNCTION private.update_user_club(uuid, bigint, text, text, boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.update_user_club(uuid, bigint, text, text, boolean, uuid) TO authenticated;

-- Harden invitation and member removal helpers (audit findings #3 & #4).
CREATE OR REPLACE FUNCTION private.invite_user_to_club(
  p_club uuid,
  p_invited_user uuid,
  p_expires_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.user_clubs
        WHERE id = p_club
          AND archived_at IS NULL
          AND (owner_id = auth.uid() OR COALESCE((SELECT public.is_admin()), false))
     ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_invited_user IS NULL
     OR p_invited_user = auth.uid()
     OR p_expires_at <= now() THEN
    RAISE EXCEPTION 'invalid_invitation' USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.user_club_members
     WHERE club_id = p_club AND user_id = p_invited_user
  ) THEN
    RAISE EXCEPTION 'already_member' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.user_club_invitations(club_id, invited_user_id, invited_by, expires_at)
  VALUES (p_club, p_invited_user, auth.uid(), p_expires_at)
  ON CONFLICT (club_id, invited_user_id) WHERE accepted_at IS NULL AND revoked_at IS NULL
  DO UPDATE SET expires_at = EXCLUDED.expires_at, invited_by = EXCLUDED.invited_by
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION private.invite_user_to_club(uuid, uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.invite_user_to_club(uuid, uuid, timestamptz) TO authenticated;
REVOKE ALL ON FUNCTION private.revoke_club_invitation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.revoke_club_invitation(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.accept_club_invitation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.accept_club_invitation(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.remove_club_member(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.remove_club_member(uuid, uuid) TO authenticated;
