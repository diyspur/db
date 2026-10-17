-- M04: Transactional RPCs for official book groups, chapter discussions, spoiler consents, and persistent messages.
-- Immutable additive migration.

CREATE OR REPLACE FUNCTION private.ensure_official_book_group(p_book uuid)
RETURNS TABLE (club_id uuid, club_slug text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_user uuid := auth.uid();
  v_title text;
  v_club uuid;
  v_slug text;
  v_archived timestamptz;
  v_created boolean := false;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_book IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT b.title INTO v_title
    FROM public.books b
   WHERE b.id = p_book;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'book_not_found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('official-book:' || p_book::text, 0)
  );

  SELECT id, slug, archived_at
    INTO v_club, v_slug, v_archived
    FROM public.user_clubs
   WHERE kind = 'official'
     AND official_book_id = p_book;

  IF FOUND AND v_archived IS NOT NULL THEN
    RAISE EXCEPTION 'group_unavailable' USING ERRCODE = '42501';
  END IF;

  IF v_club IS NULL THEN
    v_club := gen_random_uuid();
    v_slug := 'livro-' || replace(p_book::text, '-', '');
    INSERT INTO public.user_clubs (
      id, owner_id, name, slug, description, is_private, kind, official_book_id, current_book_id
    ) VALUES (
      v_club,
      v_user,
      left('Leitores de ' || btrim(v_title), 80),
      v_slug,
      'Comunidade oficial desta obra.',
      false,
      'official',
      p_book,
      p_book
    );
    v_created := true;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.club_member_sanctions
     WHERE club_id = v_club
       AND user_id = v_user
       AND kind = 'ban'
       AND (expires_at IS NULL OR expires_at > now())
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.user_club_members(club_id, user_id, role)
  VALUES (v_club, v_user, CASE WHEN v_created THEN 'owner' ELSE 'member' END)
  ON CONFLICT (club_id, user_id) DO NOTHING;

  INSERT INTO public.club_channels(club_id, kind, slug, name, spoiler_policy, created_by)
  VALUES
    (v_club, 'no_spoilers', 'sem-spoilers', 'Sem spoilers', 'none', v_user),
    (v_club, 'full_spoilers', 'com-spoilers', 'Com spoilers', 'whole_book', v_user)
  ON CONFLICT (club_id, slug) DO NOTHING;

  IF EXISTS (
    SELECT 1
      FROM public.club_channels ch
     WHERE ch.club_id = v_club
       AND (
         (ch.slug = 'sem-spoilers' AND (ch.kind <> 'no_spoilers' OR ch.spoiler_policy <> 'none'))
         OR (ch.slug = 'com-spoilers' AND (ch.kind <> 'full_spoilers' OR ch.spoiler_policy <> 'whole_book'))
       )
  ) THEN
    RAISE EXCEPTION 'default_channel_corrupted' USING ERRCODE = '23514';
  END IF;

  RETURN QUERY SELECT v_club, v_slug;
END;
$$;

REVOKE ALL ON FUNCTION private.ensure_official_book_group(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.ensure_official_book_group(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.ensure_official_book_group(p_book uuid)
RETURNS TABLE (club_id uuid, club_slug text)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.ensure_official_book_group(p_book);
$$;

REVOKE ALL ON FUNCTION public.ensure_official_book_group(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_official_book_group(uuid) TO authenticated;

-- Ensure chapter discussion channel after validating editorial gate and chapter progress.
CREATE OR REPLACE FUNCTION private.ensure_chapter_discussion(p_chapter uuid)
RETURNS TABLE (club_id uuid, club_slug text, channel_id uuid, channel_slug text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_user uuid := auth.uid();
  v_book uuid;
  v_chapter_num integer;
  v_season_num integer;
  v_club uuid;
  v_club_slug text;
  v_channel uuid;
  v_channel_slug text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_chapter IS NULL THEN
    RAISE EXCEPTION 'invalid_chapter' USING ERRCODE = '23514';
  END IF;

  SELECT s.book_id, c.number, s.number
    INTO v_book, v_chapter_num, v_season_num
    FROM public.chapters c
    JOIN public.seasons s ON s.id = c.season_id
   WHERE c.id = p_chapter;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chapter_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT private.can_view_chapter(p_chapter)
     OR NOT EXISTS (
       SELECT 1
         FROM public.user_progress p
        WHERE p.user_id = v_user
          AND p.chapter_id = p_chapter
          AND p.status = 'read'::public.shelf_status
     ) THEN
    RAISE EXCEPTION 'chapter_discussion_locked' USING ERRCODE = '42501';
  END IF;

  SELECT g.club_id, g.club_slug
    INTO v_club, v_club_slug
    FROM private.ensure_official_book_group(v_book) g;

  v_channel_slug := 'capitulo-' || replace(p_chapter::text, '-', '');

  INSERT INTO public.club_channels (
    club_id, kind, slug, name, chapter_id, spoiler_policy, created_by
  ) VALUES (
    v_club,
    'chapter',
    v_channel_slug,
    left('Capítulo ' || v_chapter_num || ' · Temporada ' || v_season_num, 80),
    p_chapter,
    'chapter',
    v_user
  )
  ON CONFLICT (club_id, chapter_id) WHERE chapter_id IS NOT NULL DO NOTHING;

  SELECT ch.id, ch.slug
    INTO v_channel, v_channel_slug
    FROM public.club_channels ch
   WHERE ch.club_id = v_club
     AND ch.chapter_id = p_chapter;

  RETURN QUERY SELECT v_club, v_club_slug, v_channel, v_channel_slug;
END;
$$;

REVOKE ALL ON FUNCTION private.ensure_chapter_discussion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.ensure_chapter_discussion(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.ensure_chapter_discussion(p_chapter uuid)
RETURNS TABLE (club_id uuid, club_slug text, channel_id uuid, channel_slug text)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.ensure_chapter_discussion(p_chapter);
$$;

REVOKE ALL ON FUNCTION public.ensure_chapter_discussion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_chapter_discussion(uuid) TO authenticated;

-- Safe channel directory: redacts future/locked chapter titles.
CREATE OR REPLACE FUNCTION public.get_club_channel_directory(p_club uuid)
RETURNS TABLE (
  id uuid,
  slug text,
  kind text,
  display_name text,
  chapter_id uuid,
  chapter_number integer,
  season_number integer,
  spoiler_policy text,
  rules_version integer,
  can_read boolean,
  has_consent boolean,
  access_reason text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    ch.id,
    ch.slug,
    ch.kind,
    CASE
      WHEN ch.kind = 'chapter' AND NOT private.can_view_chapter(ch.chapter_id)
        THEN 'Capítulo ' || COALESCE(c.number::text, '') || ' (bloqueado)'
      ELSE ch.name
    END AS display_name,
    ch.chapter_id,
    c.number AS chapter_number,
    s.number AS season_number,
    ch.spoiler_policy,
    ch.rules_version,
    private.can_read_club_channel(ch.id) AS can_read,
    EXISTS (
      SELECT 1
        FROM public.club_channel_consents co
       WHERE co.channel_id = ch.id
         AND co.user_id = (SELECT auth.uid())
         AND co.rules_version = ch.rules_version
    ) AS has_consent,
    CASE
      WHEN (SELECT auth.uid()) IS NULL THEN 'unauthenticated'
      WHEN NOT EXISTS (
        SELECT 1
          FROM public.user_club_members m
         WHERE m.club_id = cl.id
           AND m.user_id = (SELECT auth.uid())
      ) THEN 'not_member'
      WHEN private.is_club_banned(cl.id, (SELECT auth.uid())) THEN 'banned'
      WHEN ch.kind = 'chapter' AND NOT private.can_view_chapter(ch.chapter_id) THEN 'chapter_locked'
      WHEN ch.kind = 'chapter' AND NOT EXISTS (
        SELECT 1
          FROM public.user_progress p
         WHERE p.user_id = (SELECT auth.uid())
           AND p.chapter_id = ch.chapter_id
           AND p.status = 'read'::public.shelf_status
      ) THEN 'chapter_unread'
      WHEN ch.spoiler_policy <> 'none' AND NOT EXISTS (
        SELECT 1
          FROM public.club_channel_consents co
         WHERE co.channel_id = ch.id
           AND co.user_id = (SELECT auth.uid())
           AND co.rules_version = ch.rules_version
      ) THEN 'consent_required'
      ELSE 'ok'
    END AS access_reason
  FROM public.club_channels ch
  JOIN public.user_clubs cl ON cl.id = ch.club_id
  LEFT JOIN public.chapters c ON c.id = ch.chapter_id
  LEFT JOIN public.seasons s ON s.id = c.season_id
  WHERE ch.club_id = p_club
    AND cl.archived_at IS NULL
    AND ch.archived_at IS NULL
    AND private.can_view_user_club(cl.id)
  ORDER BY
    CASE ch.kind
      WHEN 'no_spoilers' THEN 0
      WHEN 'full_spoilers' THEN 1
      WHEN 'chapter' THEN 2
      ELSE 3
    END,
    s.number NULLS LAST,
    c.number NULLS LAST,
    ch.created_at ASC;
$$;

REVOKE ALL ON FUNCTION public.get_club_channel_directory(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_club_channel_directory(uuid) TO authenticated;

-- Create topic channel (owner/moderator/admin).
CREATE OR REPLACE FUNCTION private.create_club_topic_channel(
  p_club uuid,
  p_name text,
  p_slug text,
  p_spoiler_policy text,
  p_request_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_count integer;
  v_existing uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.can_manage_club(p_club, v_user) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_request_id IS NULL
     OR length(btrim(coalesce(p_name, ''))) NOT BETWEEN 1 AND 80
     OR coalesce(p_slug, '') !~ '^[a-z0-9][a-z0-9-]{0,99}$'
     OR p_slug IN ('sem-spoilers', 'com-spoilers')
     OR p_slug LIKE 'capitulo-%'
     OR p_spoiler_policy NOT IN ('none', 'whole_book') THEN
    RAISE EXCEPTION 'invalid_channel' USING ERRCODE = '23514';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('club-topic:' || p_club::text, 0)
  );

  SELECT id INTO v_existing
    FROM public.club_channels
   WHERE id = p_request_id
     AND club_id = p_club;

  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT count(*) INTO v_count
    FROM public.club_channels
   WHERE club_id = p_club
     AND kind = 'topic'
     AND archived_at IS NULL;

  IF v_count >= 25 THEN
    RAISE EXCEPTION 'channel_limit_reached' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.club_channels (
    id, club_id, kind, slug, name, spoiler_policy, created_by
  ) VALUES (
    p_request_id, p_club, 'topic', p_slug, btrim(p_name), p_spoiler_policy, v_user
  );

  RETURN p_request_id;
END;
$$;

REVOKE ALL ON FUNCTION private.create_club_topic_channel(uuid, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.create_club_topic_channel(uuid, text, text, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_club_topic_channel(
  p_club uuid,
  p_name text,
  p_slug text,
  p_spoiler_policy text,
  p_request_id uuid
) RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.create_club_topic_channel(p_club, p_name, p_slug, p_spoiler_policy, p_request_id);
$$;

REVOKE ALL ON FUNCTION public.create_club_topic_channel(uuid, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_club_topic_channel(uuid, text, text, text, uuid) TO authenticated;

-- Accept and revoke channel spoiler consent.
CREATE OR REPLACE FUNCTION private.accept_channel_spoilers(
  p_channel uuid,
  p_rules_version integer
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_club uuid;
  v_kind text;
  v_chapter uuid;
  v_version integer;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  SELECT ch.club_id, ch.kind, ch.chapter_id, ch.rules_version
    INTO v_club, v_kind, v_chapter, v_version
    FROM public.club_channels ch
    JOIN public.user_clubs cl ON cl.id = ch.club_id
   WHERE ch.id = p_channel
     AND ch.archived_at IS NULL
     AND cl.archived_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'channel_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_version IS DISTINCT FROM p_rules_version THEN
    RAISE EXCEPTION 'rules_version_mismatch' USING ERRCODE = '40001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.user_club_members m
     WHERE m.club_id = v_club
       AND m.user_id = v_user
  ) OR private.is_club_banned(v_club, v_user) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_kind = 'chapter' AND (
    NOT private.can_view_chapter(v_chapter)
    OR NOT EXISTS (
      SELECT 1
        FROM public.user_progress p
       WHERE p.user_id = v_user
         AND p.chapter_id = v_chapter
         AND p.status = 'read'::public.shelf_status
    )
  ) THEN
    RAISE EXCEPTION 'chapter_discussion_locked' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.club_channel_consents(channel_id, user_id, rules_version, accepted_at)
  VALUES (p_channel, v_user, p_rules_version, now())
  ON CONFLICT (channel_id, user_id)
  DO UPDATE SET rules_version = EXCLUDED.rules_version, accepted_at = now();

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.accept_channel_spoilers(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.accept_channel_spoilers(uuid, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_channel_spoilers(
  p_channel uuid,
  p_rules_version integer
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.accept_channel_spoilers(p_channel, p_rules_version);
$$;

REVOKE ALL ON FUNCTION public.accept_channel_spoilers(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_channel_spoilers(uuid, integer) TO authenticated;

CREATE OR REPLACE FUNCTION private.revoke_channel_spoilers(p_channel uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.club_channel_consents
   WHERE channel_id = p_channel
     AND user_id = auth.uid();

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.revoke_channel_spoilers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.revoke_channel_spoilers(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.revoke_channel_spoilers(p_channel uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.revoke_channel_spoilers(p_channel);
$$;

REVOKE ALL ON FUNCTION public.revoke_channel_spoilers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_channel_spoilers(uuid) TO authenticated;

-- Channel notification preference RPC.
CREATE OR REPLACE FUNCTION private.set_channel_preference(
  p_channel uuid,
  p_mode text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_club uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_mode NOT IN ('muted', 'mentions', 'following') THEN
    RAISE EXCEPTION 'invalid_preference_mode' USING ERRCODE = '23514';
  END IF;

  SELECT ch.club_id INTO v_club
    FROM public.club_channels ch
    JOIN public.user_clubs cl ON cl.id = ch.club_id
   WHERE ch.id = p_channel
     AND ch.archived_at IS NULL
     AND cl.archived_at IS NULL;

  IF NOT FOUND OR NOT EXISTS (
    SELECT 1 FROM public.user_club_members m WHERE m.club_id = v_club AND m.user_id = v_user
  ) OR private.is_club_banned(v_club, v_user) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.club_channel_preferences(channel_id, user_id, mode, last_seen_at, updated_at)
  VALUES (p_channel, v_user, p_mode, now(), now())
  ON CONFLICT (channel_id, user_id)
  DO UPDATE SET mode = EXCLUDED.mode, updated_at = now();

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.set_channel_preference(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.set_channel_preference(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_channel_preference(
  p_channel uuid,
  p_mode text
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.set_channel_preference(p_channel, p_mode);
$$;

REVOKE ALL ON FUNCTION public.set_channel_preference(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_channel_preference(uuid, text) TO authenticated;

-- User blocks RPCs.
CREATE OR REPLACE FUNCTION private.block_community_user(p_target_user uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;
  IF p_target_user IS NULL OR p_target_user = auth.uid() THEN
    RAISE EXCEPTION 'invalid_block_target' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.community_user_blocks(user_id, blocked_user_id)
  VALUES (auth.uid(), p_target_user)
  ON CONFLICT DO NOTHING;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.block_community_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.block_community_user(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.block_community_user(p_target_user uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.block_community_user(p_target_user);
$$;

REVOKE ALL ON FUNCTION public.block_community_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.block_community_user(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.unblock_community_user(p_target_user uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.community_user_blocks
   WHERE user_id = auth.uid()
     AND blocked_user_id = p_target_user;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.unblock_community_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.unblock_community_user(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.unblock_community_user(p_target_user uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.unblock_community_user(p_target_user);
$$;

REVOKE ALL ON FUNCTION public.unblock_community_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unblock_community_user(uuid) TO authenticated;

-- Club sanctions and role management.
CREATE OR REPLACE FUNCTION private.apply_club_sanction(
  p_club uuid,
  p_user uuid,
  p_kind text,
  p_reason text,
  p_expires_at timestamptz DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_owner uuid;
BEGIN
  IF v_actor IS NULL OR NOT private.can_manage_club(p_club, v_actor) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT owner_id INTO v_owner FROM public.user_clubs WHERE id = p_club;
  IF p_user IS NULL
     OR p_user = v_actor
     OR (p_user = v_owner AND NOT COALESCE((SELECT public.is_admin()), false))
     OR p_kind NOT IN ('mute', 'ban')
     OR length(btrim(coalesce(p_reason, ''))) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'invalid_sanction' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.club_member_sanctions(club_id, user_id, kind, expires_at, reason, applied_by, created_at)
  VALUES (p_club, p_user, p_kind, p_expires_at, btrim(p_reason), v_actor, now())
  ON CONFLICT (club_id, user_id)
  DO UPDATE SET
    kind = EXCLUDED.kind,
    expires_at = EXCLUDED.expires_at,
    reason = EXCLUDED.reason,
    applied_by = v_actor,
    created_at = now();

  IF p_kind = 'ban' THEN
    IF p_user = v_owner THEN
      UPDATE public.user_clubs SET owner_id = NULL, version = version + 1 WHERE id = p_club;
    END IF;
    DELETE FROM public.user_club_members
     WHERE club_id = p_club
       AND user_id = p_user;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.apply_club_sanction(uuid, uuid, text, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.apply_club_sanction(uuid, uuid, text, text, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_club_sanction(
  p_club uuid,
  p_user uuid,
  p_kind text,
  p_reason text,
  p_expires_at timestamptz DEFAULT NULL
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.apply_club_sanction(p_club, p_user, p_kind, p_reason, p_expires_at);
$$;

REVOKE ALL ON FUNCTION public.apply_club_sanction(uuid, uuid, text, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.apply_club_sanction(uuid, uuid, text, text, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION private.set_club_member_role(
  p_club uuid,
  p_member uuid,
  p_role text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_owner uuid;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  SELECT owner_id INTO v_owner FROM public.user_clubs WHERE id = p_club AND archived_at IS NULL;
  IF NOT FOUND OR (v_owner IS DISTINCT FROM v_actor AND NOT COALESCE((SELECT public.is_admin()), false)) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_member IS NULL OR p_member = v_owner OR p_role NOT IN ('moderator', 'member') THEN
    RAISE EXCEPTION 'invalid_role_change' USING ERRCODE = '23514';
  END IF;

  UPDATE public.user_club_members
     SET role = p_role
   WHERE club_id = p_club
     AND user_id = p_member
     AND role <> 'owner';

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION private.set_club_member_role(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.set_club_member_role(uuid, uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_club_member_role(
  p_club uuid,
  p_member uuid,
  p_role text
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.set_club_member_role(p_club, p_member, p_role);
$$;

REVOKE ALL ON FUNCTION public.set_club_member_role(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_club_member_role(uuid, uuid, text) TO authenticated;

-- Keyset pagination and message context RPCs.
CREATE OR REPLACE FUNCTION public.list_club_messages(
  p_channel uuid,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 50
) RETURNS TABLE (
  id uuid,
  channel_id uuid,
  author_id uuid,
  content text,
  reply_to_id uuid,
  video_sec integer,
  version bigint,
  created_at timestamptz,
  edited_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF p_channel IS NULL OR (p_before_created_at IS NULL) <> (p_before_id IS NULL) THEN
    RAISE EXCEPTION 'invalid_cursor' USING ERRCODE = '23514';
  END IF;

  IF NOT private.can_read_club_channel(p_channel) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.channel_id,
    m.author_id,
    m.content,
    m.reply_to_id,
    m.video_sec,
    m.version,
    m.created_at,
    m.edited_at
  FROM public.club_messages m
  WHERE m.channel_id = p_channel
    AND m.deleted_at IS NULL
    AND (
      p_before_created_at IS NULL
      OR (m.created_at, m.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY m.created_at DESC, m.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 50) + 1;
END;
$$;

REVOKE ALL ON FUNCTION public.list_club_messages(uuid, timestamptz, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_club_messages(uuid, timestamptz, uuid, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_club_message_context(
  p_message uuid,
  p_window integer DEFAULT 20
) RETURNS TABLE (
  id uuid,
  channel_id uuid,
  author_id uuid,
  content text,
  reply_to_id uuid,
  video_sec integer,
  version bigint,
  created_at timestamptz,
  edited_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_channel uuid;
  v_created timestamptz;
  v_half integer := LEAST(GREATEST(COALESCE(p_window, 20), 2), 50) / 2;
BEGIN
  SELECT m.channel_id, m.created_at
    INTO v_channel, v_created
    FROM public.club_messages m
   WHERE m.id = p_message
     AND m.deleted_at IS NULL;

  IF NOT FOUND OR NOT private.can_read_club_channel(v_channel) THEN
    RETURN;
  END IF;

  RETURN QUERY
  (
    SELECT m.id, m.channel_id, m.author_id, m.content, m.reply_to_id, m.video_sec, m.version, m.created_at, m.edited_at
      FROM public.club_messages m
     WHERE m.channel_id = v_channel
       AND m.deleted_at IS NULL
       AND (m.created_at, m.id) <= (v_created, p_message)
     ORDER BY m.created_at DESC, m.id DESC
     LIMIT v_half + 1
  )
  UNION ALL
  (
    SELECT m.id, m.channel_id, m.author_id, m.content, m.reply_to_id, m.video_sec, m.version, m.created_at, m.edited_at
      FROM public.club_messages m
     WHERE m.channel_id = v_channel
       AND m.deleted_at IS NULL
       AND (m.created_at, m.id) > (v_created, p_message)
     ORDER BY m.created_at ASC, m.id ASC
     LIMIT v_half
  )
  ORDER BY created_at DESC, id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_club_message_context(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_club_message_context(uuid, integer) TO authenticated;

-- Send, edit, and delete message RPCs.
CREATE OR REPLACE FUNCTION private.send_club_message(
  p_channel uuid,
  p_client_message_id uuid,
  p_content text,
  p_reply_to uuid DEFAULT NULL,
  p_video_sec integer DEFAULT NULL
) RETURNS TABLE (
  id uuid,
  channel_id uuid,
  author_id uuid,
  content text,
  reply_to_id uuid,
  video_sec integer,
  version bigint,
  created_at timestamptz,
  club_slug text,
  channel_slug text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_user uuid := auth.uid();
  v_trimmed text := btrim(coalesce(p_content, ''));
  v_existing public.club_messages%ROWTYPE;
  v_channel_kind text;
  v_channel_slug text;
  v_chapter uuid;
  v_club_slug text;
  v_has_video boolean := false;
  v_reply_author uuid;
  v_inserted public.club_messages%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_channel IS NULL OR p_client_message_id IS NULL THEN
    RAISE EXCEPTION 'invalid_message' USING ERRCODE = '23514';
  END IF;

  IF length(v_trimmed) NOT BETWEEN 1 AND 4000 THEN
    RAISE EXCEPTION 'invalid_message_length' USING ERRCODE = '23514';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('club-msg-user:' || v_user::text, 0)
  );

  -- Always validate current channel write permission BEFORE returning any replay (SDD 7.3).
  IF NOT private.can_write_club_channel(p_channel) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT ch.kind, ch.slug, ch.chapter_id, cl.slug
    INTO v_channel_kind, v_channel_slug, v_chapter, v_club_slug
    FROM public.club_channels ch
    JOIN public.user_clubs cl ON cl.id = ch.club_id
   WHERE ch.id = p_channel;

  SELECT * INTO v_existing
    FROM public.club_messages m
   WHERE m.author_id = v_user
     AND m.client_message_id = p_client_message_id;

  IF FOUND THEN
    IF v_existing.channel_id IS DISTINCT FROM p_channel
       OR v_existing.content IS DISTINCT FROM v_trimmed
       OR v_existing.reply_to_id IS DISTINCT FROM p_reply_to
       OR v_existing.video_sec IS DISTINCT FROM p_video_sec THEN
      RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
    END IF;

    RETURN QUERY
    SELECT
      v_existing.id,
      v_existing.channel_id,
      v_existing.author_id,
      v_existing.content,
      v_existing.reply_to_id,
      v_existing.video_sec,
      v_existing.version,
      v_existing.created_at,
      v_club_slug,
      v_channel_slug;
    RETURN;
  END IF;

  IF p_video_sec IS NOT NULL THEN
    IF p_video_sec NOT BETWEEN 0 AND 86400 OR v_channel_kind <> 'chapter' THEN
      RAISE EXCEPTION 'invalid_video_timestamp' USING ERRCODE = '23514';
    END IF;
    SELECT (c.youtube_url IS NOT NULL AND length(btrim(c.youtube_url)) > 0)
      INTO v_has_video
      FROM public.chapters c
     WHERE c.id = v_chapter;
    IF NOT COALESCE(v_has_video, false) THEN
      RAISE EXCEPTION 'chapter_has_no_video' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF p_reply_to IS NOT NULL THEN
    SELECT m.author_id INTO v_reply_author
      FROM public.club_messages m
     WHERE m.id = p_reply_to
       AND m.channel_id = p_channel
       AND m.deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'reply_target_unavailable' USING ERRCODE = '23503';
    END IF;

    IF v_reply_author IS NOT NULL AND EXISTS (
      SELECT 1
        FROM public.community_user_blocks b
       WHERE (b.user_id = v_user AND b.blocked_user_id = v_reply_author)
          OR (b.user_id = v_reply_author AND b.blocked_user_id = v_user)
    ) THEN
      RAISE EXCEPTION 'reply_target_unavailable' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NOT public.take_rate_limit(v_user, 'club_msg_60s', 10, 60)
     OR NOT public.take_rate_limit(v_user, 'club_msg_3600s', 200, 3600) THEN
    RAISE EXCEPTION 'rate_limit_exceeded' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.club_messages (
    channel_id, author_id, client_message_id, content, reply_to_id, video_sec
  ) VALUES (
    p_channel, v_user, p_client_message_id, v_trimmed, p_reply_to, p_video_sec
  )
  RETURNING * INTO v_inserted;

  RETURN QUERY
  SELECT
    v_inserted.id,
    v_inserted.channel_id,
    v_inserted.author_id,
    v_inserted.content,
    v_inserted.reply_to_id,
    v_inserted.video_sec,
    v_inserted.version,
    v_inserted.created_at,
    v_club_slug,
    v_channel_slug;
END;
$$;

REVOKE ALL ON FUNCTION private.send_club_message(uuid, uuid, text, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.send_club_message(uuid, uuid, text, uuid, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.send_club_message(
  p_channel uuid,
  p_client_message_id uuid,
  p_content text,
  p_reply_to uuid DEFAULT NULL,
  p_video_sec integer DEFAULT NULL
) RETURNS TABLE (
  id uuid,
  channel_id uuid,
  author_id uuid,
  content text,
  reply_to_id uuid,
  video_sec integer,
  version bigint,
  created_at timestamptz,
  club_slug text,
  channel_slug text
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM private.send_club_message(p_channel, p_client_message_id, p_content, p_reply_to, p_video_sec);
$$;

REVOKE ALL ON FUNCTION public.send_club_message(uuid, uuid, text, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_club_message(uuid, uuid, text, uuid, integer) TO authenticated;

CREATE OR REPLACE FUNCTION private.edit_club_message(
  p_message uuid,
  p_version bigint,
  p_content text
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_trimmed text := btrim(coalesce(p_content, ''));
  v_row public.club_messages%ROWTYPE;
  v_version bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF length(v_trimmed) NOT BETWEEN 1 AND 4000 OR p_version IS NULL THEN
    RAISE EXCEPTION 'invalid_message' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_row
    FROM public.club_messages
   WHERE id = p_message
     AND deleted_at IS NULL
   FOR UPDATE;

  IF NOT FOUND
     OR v_row.author_id IS DISTINCT FROM v_user
     OR NOT private.can_write_club_channel(v_row.channel_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_row.created_at < now() - interval '15 minutes' THEN
    RAISE EXCEPTION 'edit_window_expired' USING ERRCODE = '42501';
  END IF;

  IF v_row.version <> p_version THEN
    RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
  END IF;

  UPDATE public.club_messages
     SET content = v_trimmed,
         edited_at = now(),
         version = version + 1
   WHERE id = p_message
  RETURNING version INTO v_version;

  RETURN v_version;
END;
$$;

REVOKE ALL ON FUNCTION private.edit_club_message(uuid, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.edit_club_message(uuid, bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.edit_club_message(
  p_message uuid,
  p_version bigint,
  p_content text
) RETURNS bigint
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.edit_club_message(p_message, p_version, p_content);
$$;

REVOKE ALL ON FUNCTION public.edit_club_message(uuid, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_club_message(uuid, bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION private.delete_club_message(
  p_message uuid,
  p_version bigint
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_row public.club_messages%ROWTYPE;
  v_club uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
    FROM public.club_messages
   WHERE id = p_message
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_row.deleted_at IS NOT NULL THEN
    RETURN true;
  END IF;

  SELECT ch.club_id INTO v_club
    FROM public.club_channels ch
   WHERE ch.id = v_row.channel_id;

  IF (
    v_row.author_id = v_user AND private.can_read_club_channel(v_row.channel_id)
  ) OR private.can_manage_club(v_club, v_user) THEN
    IF p_version IS NOT NULL AND v_row.version <> p_version THEN
      RAISE EXCEPTION 'conflict' USING ERRCODE = '40001';
    END IF;

    UPDATE public.club_messages
       SET deleted_at = now(),
           version = version + 1
     WHERE id = p_message;
    RETURN true;
  END IF;

  RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
END;
$$;

REVOKE ALL ON FUNCTION private.delete_club_message(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.delete_club_message(uuid, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_club_message(
  p_message uuid,
  p_version bigint
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.delete_club_message(p_message, p_version);
$$;

REVOKE ALL ON FUNCTION public.delete_club_message(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_club_message(uuid, bigint) TO authenticated;

-- Editorial prompt management for channels (Section 14.2).
CREATE OR REPLACE FUNCTION private.create_channel_editorial_prompt(
  p_channel uuid,
  p_body text,
  p_position integer DEFAULT 0
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_club uuid;
  v_id uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  SELECT ch.club_id INTO v_club
    FROM public.club_channels ch
   WHERE ch.id = p_channel
     AND ch.archived_at IS NULL;

  IF NOT FOUND OR NOT private.can_manage_club(v_club, v_user) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF length(btrim(coalesce(p_body, ''))) NOT BETWEEN 3 AND 1000
     OR COALESCE(p_position, -1) < 0 THEN
    RAISE EXCEPTION 'invalid_prompt' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.club_channel_prompts(channel_id, body, position, created_by)
  VALUES (p_channel, btrim(p_body), COALESCE(p_position, 0), v_user)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION private.create_channel_editorial_prompt(uuid, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.create_channel_editorial_prompt(uuid, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_channel_editorial_prompt(
  p_channel uuid,
  p_body text,
  p_position integer DEFAULT 0
) RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.create_channel_editorial_prompt(p_channel, p_body, p_position);
$$;

REVOKE ALL ON FUNCTION public.create_channel_editorial_prompt(uuid, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_channel_editorial_prompt(uuid, text, integer) TO authenticated;
