-- M03: RLS, privileges, and security helpers for community discussions.
-- Immutable additive migration.

CREATE OR REPLACE FUNCTION private.is_club_banned(p_club uuid, p_user uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_user IS NOT NULL AND EXISTS (
    SELECT 1
      FROM public.club_member_sanctions s
     WHERE s.club_id = p_club
       AND s.user_id = p_user
       AND s.kind = 'ban'
       AND (s.expires_at IS NULL OR s.expires_at > now())
  );
$$;

REVOKE ALL ON FUNCTION private.is_club_banned(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_club_banned(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.is_club_muted(p_club uuid, p_user uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_user IS NOT NULL AND EXISTS (
    SELECT 1
      FROM public.club_member_sanctions s
     WHERE s.club_id = p_club
       AND s.user_id = p_user
       AND s.kind IN ('mute', 'ban')
       AND (s.expires_at IS NULL OR s.expires_at > now())
  );
$$;

REVOKE ALL ON FUNCTION private.is_club_muted(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_club_muted(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.can_manage_club(p_club uuid, p_user uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_user IS NOT NULL AND (
    COALESCE((SELECT public.is_admin()), false)
    OR EXISTS (
      SELECT 1
        FROM public.user_clubs c
       WHERE c.id = p_club
         AND c.archived_at IS NULL
         AND (
           c.owner_id = p_user
           OR EXISTS (
             SELECT 1
               FROM public.user_club_members m
              WHERE m.club_id = c.id
                AND m.user_id = p_user
                AND m.role IN ('owner', 'moderator')
           )
         )
         AND NOT private.is_club_banned(c.id, p_user)
    )
  );
$$;

REVOKE ALL ON FUNCTION private.can_manage_club(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_manage_club(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.can_read_club_channel(p_channel uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1
      FROM public.club_channels ch
      JOIN public.user_clubs cl ON cl.id = ch.club_id
      JOIN public.user_club_members m
        ON m.club_id = cl.id
       AND m.user_id = auth.uid()
     WHERE ch.id = p_channel
       AND cl.archived_at IS NULL
       AND ch.archived_at IS NULL
       AND NOT EXISTS (
         SELECT 1
           FROM public.club_member_sanctions s
          WHERE s.club_id = cl.id
            AND s.user_id = auth.uid()
            AND s.kind = 'ban'
            AND (s.expires_at IS NULL OR s.expires_at > now())
       )
       AND (
         ch.kind <> 'chapter' OR (
           private.can_view_chapter(ch.chapter_id)
           AND EXISTS (
             SELECT 1
               FROM public.user_progress p
              WHERE p.user_id = auth.uid()
                AND p.chapter_id = ch.chapter_id
                AND p.status = 'read'::public.shelf_status
           )
         )
       )
       AND (
         ch.spoiler_policy = 'none' OR EXISTS (
           SELECT 1
             FROM public.club_channel_consents co
            WHERE co.channel_id = ch.id
              AND co.user_id = auth.uid()
              AND co.rules_version = ch.rules_version
         )
       )
  );
$$;

REVOKE ALL ON FUNCTION private.can_read_club_channel(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_read_club_channel(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.can_write_club_channel(p_channel uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.can_read_club_channel(p_channel)
     AND EXISTS (
       SELECT 1
         FROM public.profiles pr
        WHERE pr.id = auth.uid()
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.club_channels ch
         JOIN public.club_member_sanctions s ON s.club_id = ch.club_id
        WHERE ch.id = p_channel
          AND s.user_id = auth.uid()
          AND s.kind IN ('mute', 'ban')
          AND (s.expires_at IS NULL OR s.expires_at > now())
     );
$$;

REVOKE ALL ON FUNCTION private.can_write_club_channel(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_write_club_channel(uuid) TO authenticated;

-- Enforce ban checks on existing join_user_club and accept_club_invitation (SEC08).
CREATE OR REPLACE FUNCTION private.join_user_club(p_club uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_private boolean;
  v_archived timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT is_private, archived_at
    INTO v_private, v_archived
    FROM public.user_clubs
   WHERE id = p_club
   FOR UPDATE;

  IF NOT FOUND
     OR v_archived IS NOT NULL
     OR v_private
     OR private.is_club_banned(p_club, auth.uid()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.user_club_members(club_id, user_id, role)
  VALUES (p_club, auth.uid(), 'member')
  ON CONFLICT DO NOTHING;

  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION private.join_user_club(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.join_user_club(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.accept_club_invitation(p_invitation uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_club uuid;
BEGIN
  SELECT i.club_id INTO v_club
    FROM public.user_club_invitations i
    JOIN public.user_clubs c ON c.id = i.club_id
   WHERE i.id = p_invitation
     AND i.invited_user_id = auth.uid()
     AND i.accepted_at IS NULL
     AND i.revoked_at IS NULL
     AND i.expires_at > now()
     AND c.archived_at IS NULL
   FOR UPDATE OF i;

  IF v_club IS NULL OR private.is_club_banned(v_club, auth.uid()) THEN
    RAISE EXCEPTION 'invitation_unavailable' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.user_club_members(club_id, user_id, role)
  VALUES (v_club, auth.uid(), 'member')
  ON CONFLICT DO NOTHING;

  UPDATE public.user_club_invitations
     SET accepted_at = now()
   WHERE id = p_invitation;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.accept_club_invitation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.accept_club_invitation(uuid) TO authenticated;

-- RLS and strict grants on discussion tables.
ALTER TABLE public.community_user_blocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.community_user_blocks FROM anon, authenticated;
GRANT SELECT ON public.community_user_blocks TO authenticated;

DROP POLICY IF EXISTS community_user_blocks_select_own ON public.community_user_blocks;
CREATE POLICY community_user_blocks_select_own ON public.community_user_blocks
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

ALTER TABLE public.club_channel_consents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.club_channel_consents FROM anon, authenticated;
GRANT SELECT ON public.club_channel_consents TO authenticated;

DROP POLICY IF EXISTS club_channel_consents_select_own ON public.club_channel_consents;
CREATE POLICY club_channel_consents_select_own ON public.club_channel_consents
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

ALTER TABLE public.club_channel_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.club_channel_preferences FROM anon, authenticated;
GRANT SELECT ON public.club_channel_preferences TO authenticated;

DROP POLICY IF EXISTS club_channel_preferences_select_own ON public.club_channel_preferences;
CREATE POLICY club_channel_preferences_select_own ON public.club_channel_preferences
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

ALTER TABLE public.club_member_sanctions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.club_member_sanctions FROM anon, authenticated;
GRANT SELECT ON public.club_member_sanctions TO authenticated;

DROP POLICY IF EXISTS club_member_sanctions_select_authorized ON public.club_member_sanctions;
CREATE POLICY club_member_sanctions_select_authorized ON public.club_member_sanctions
  FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR private.can_manage_club(club_id, (SELECT auth.uid()))
  );

ALTER TABLE public.club_channels ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.club_channels FROM anon, authenticated;
GRANT SELECT ON public.club_channels TO authenticated;

DROP POLICY IF EXISTS club_channels_select_member ON public.club_channels;
CREATE POLICY club_channels_select_member ON public.club_channels
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
        FROM public.user_clubs c
        JOIN public.user_club_members m
          ON m.club_id = c.id
         AND m.user_id = (SELECT auth.uid())
       WHERE c.id = club_channels.club_id
         AND c.archived_at IS NULL
    )
    AND NOT private.is_club_banned(club_id, (SELECT auth.uid()))
    AND (
      kind <> 'chapter'
      OR private.can_view_chapter(chapter_id)
      OR private.can_manage_club(club_id, (SELECT auth.uid()))
    )
  );

ALTER TABLE public.club_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.club_messages FROM anon, authenticated;
GRANT SELECT ON public.club_messages TO authenticated;

DROP POLICY IF EXISTS club_messages_select ON public.club_messages;
CREATE POLICY club_messages_select ON public.club_messages
  FOR SELECT TO authenticated
  USING (
    deleted_at IS NULL
    AND private.can_read_club_channel(channel_id)
    AND (
      author_id IS NULL
      OR NOT EXISTS (
        SELECT 1
          FROM public.community_user_blocks b
         WHERE b.user_id = (SELECT auth.uid())
           AND b.blocked_user_id = author_id
      )
    )
  );

ALTER TABLE public.club_channel_prompts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.club_channel_prompts FROM anon, authenticated;
GRANT SELECT ON public.club_channel_prompts TO authenticated;

DROP POLICY IF EXISTS club_channel_prompts_select ON public.club_channel_prompts;
CREATE POLICY club_channel_prompts_select ON public.club_channel_prompts
  FOR SELECT TO authenticated
  USING (
    published_at <= now()
    AND (
      private.can_read_club_channel(channel_id)
      OR EXISTS (
        SELECT 1
          FROM public.club_channels ch
         WHERE ch.id = club_channel_prompts.channel_id
           AND private.can_manage_club(ch.club_id, (SELECT auth.uid()))
      )
    )
  );
