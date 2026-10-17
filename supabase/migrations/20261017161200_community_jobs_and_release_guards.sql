-- M12: Release guards, reminder preferences/dedupe, club progress panel fix, attendance XP, and moderation queue context.
-- Immutable additive migration.

-- 1. Update deliver_meeting_reminder to respect user_notification_preferences, cancelled status, and dedupe_key.
CREATE OR REPLACE FUNCTION public.deliver_meeting_reminder(
  p_user uuid,
  p_meeting uuid,
  p_window text DEFAULT '48h'
) RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_meeting public.meetings%ROWTYPE;
  v_claimed integer;
BEGIN
  IF p_window <> '48h' THEN
    RAISE EXCEPTION 'unsupported reminder window' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_meeting
    FROM public.meetings m
   WHERE m.id = p_meeting;

  IF NOT FOUND
     OR v_meeting.status <> 'scheduled'::public.meeting_status
     OR v_meeting.scheduled_at < statement_timestamp()
     OR v_meeting.scheduled_at > statement_timestamp() + interval '48 hours'
     OR NOT EXISTS (
       SELECT 1
         FROM public.meeting_rsvps r
        WHERE r.meeting_id = p_meeting
          AND r.user_id = p_user
          AND r.attending
     )
     OR NOT COALESCE(
       (
         SELECT np.meeting_reminders
           FROM public.user_notification_preferences np
          WHERE np.user_id = p_user
       ),
       true
     )
     OR (
       v_meeting.club_id IS NOT NULL
       AND private.is_club_banned(v_meeting.club_id, p_user)
     ) THEN
    RETURN false;
  END IF;

  INSERT INTO private.sent_reminders (user_id, meeting_id, reminder_window)
  VALUES (p_user, p_meeting, p_window)
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN false;
  END IF;

  INSERT INTO public.notifications (user_id, kind, dedupe_key, payload)
  VALUES (
    p_user,
    'meeting_reminder'::public.notification_kind,
    'reminder:' || v_meeting.id::text || ':' || p_window,
    jsonb_build_object(
      'meeting_id', v_meeting.id,
      'entity_type', 'meeting',
      'entity_id', v_meeting.id,
      'title', v_meeting.title,
      'at', v_meeting.scheduled_at
    )
  )
  ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.deliver_meeting_reminder(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deliver_meeting_reminder(uuid, uuid, text) TO service_role;

-- 2. Fix confirm_meeting_attendance to allow service_role or admin and award idempotent XP (audit finding #6).
CREATE OR REPLACE FUNCTION public.confirm_meeting_attendance(
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
    COALESCE((SELECT public.is_admin()), false)
    OR current_user IN ('postgres', 'service_role')
  ) OR p_proof_type NOT IN ('moderator', 'replay_confirmation') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.meeting_attendance(user_id, meeting_id, proof_type)
  VALUES (p_user, p_meeting, p_proof_type)
  ON CONFLICT (user_id, meeting_id)
  DO UPDATE SET proof_type = EXCLUDED.proof_type, confirmed_at = now();

  PERFORM public.award_xp(p_user, 'join_meeting'::public.xp_source, 30, p_meeting);
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_meeting_attendance(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_meeting_attendance(uuid, uuid, text) TO authenticated, service_role;

-- 3. Fix private.club_progress_counts so accepted members of private clubs also receive club aggregates (audit finding #2).
CREATE OR REPLACE FUNCTION private.club_progress_counts(p_club uuid)
RETURNS TABLE (
  finished_count bigint,
  reading_count bigint,
  not_started_count bigint,
  avg_percent numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    count(*) FILTER (WHERE up.status = 'read'::public.shelf_status),
    count(*) FILTER (WHERE up.status = 'reading'::public.shelf_status),
    count(*) FILTER (WHERE up.status = 'want_to_read'::public.shelf_status),
    coalesce(round(avg(up.percent)::numeric, 2), 0::numeric)
  FROM public.user_clubs AS uc
  JOIN public.user_club_members AS member_scope
    ON member_scope.club_id = uc.id
  LEFT JOIN public.user_progress AS up
    ON up.user_id = member_scope.user_id
   AND up.chapter_id IN (
     SELECT c.id
     FROM public.chapters AS c
     JOIN public.seasons AS s ON s.id = c.season_id
     WHERE s.book_id = uc.current_book_id
       AND (uc.current_season_id IS NULL OR s.id = uc.current_season_id)
   )
  WHERE uc.id = p_club
    AND private.can_view_user_club(uc.id);
$$;

REVOKE ALL ON FUNCTION private.club_progress_counts(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.club_progress_counts(uuid) TO anon, authenticated, service_role;

-- 4. Enriched moderation queue RPC so admins/club moderators see safe context instead of raw UUIDs.
CREATE OR REPLACE FUNCTION public.get_moderation_queue(
  p_club uuid DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS TABLE (
  id uuid,
  content_type text,
  content_id uuid,
  reason text,
  status text,
  created_at timestamptz,
  reporter_id uuid,
  content_excerpt text,
  content_author_id uuid,
  club_id uuid,
  club_slug text,
  channel_slug text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_user uuid := auth.uid();
  v_is_admin boolean := COALESCE((SELECT public.is_admin()), false);
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT v_is_admin AND (p_club IS NULL OR NOT private.can_manage_club(p_club, v_user)) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    cr.id,
    cr.content_type,
    cr.content_id,
    cr.reason,
    cr.status,
    cr.created_at,
    cr.reporter_id,
    CASE
      WHEN cr.content_type = 'club_message' THEN left(cm.content, 280)
      WHEN cr.content_type = 'comment' THEN left(c.content, 280)
      WHEN cr.content_type = 'timed_comment' THEN left(vtc.content, 280)
      WHEN cr.content_type = 'post' THEN left(COALESCE(fp.body, fp.quote_text), 280)
      ELSE NULL
    END AS content_excerpt,
    CASE
      WHEN cr.content_type = 'club_message' THEN cm.author_id
      WHEN cr.content_type = 'comment' THEN c.user_id
      WHEN cr.content_type = 'timed_comment' THEN vtc.user_id
      WHEN cr.content_type = 'post' THEN fp.author_id
      ELSE NULL
    END AS content_author_id,
    ch.club_id,
    cl.slug AS club_slug,
    ch.slug AS channel_slug
  FROM public.content_reports cr
  LEFT JOIN public.club_messages cm
    ON cr.content_type = 'club_message' AND cm.id = cr.content_id
  LEFT JOIN public.club_channels ch
    ON ch.id = cm.channel_id
  LEFT JOIN public.user_clubs cl
    ON cl.id = ch.club_id
  LEFT JOIN public.comments c
    ON cr.content_type = 'comment' AND c.id = cr.content_id
  LEFT JOIN public.video_timed_comments vtc
    ON cr.content_type = 'timed_comment' AND vtc.id = cr.content_id
  LEFT JOIN public.feed_posts fp
    ON cr.content_type = 'post' AND fp.id = cr.content_id
  WHERE cr.status = 'pending'
    AND (
      (v_is_admin AND (p_club IS NULL OR ch.club_id = p_club))
      OR (NOT v_is_admin AND cr.content_type = 'club_message' AND ch.club_id = p_club)
    )
  ORDER BY cr.created_at ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 100);
END;
$$;

REVOKE ALL ON FUNCTION public.get_moderation_queue(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_moderation_queue(uuid, integer) TO authenticated;
