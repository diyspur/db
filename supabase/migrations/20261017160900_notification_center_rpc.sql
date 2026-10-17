-- M09: Notification deduplication, unread index, privilege hardening, preferences, and idempotent read RPC.
-- Immutable additive migration.

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS dedupe_key text;

CREATE UNIQUE INDEX IF NOT EXISTS notifications_user_dedupe_idx
  ON public.notifications(user_id, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS notifications_unread_user_idx
  ON public.notifications(user_id, created_at DESC, id DESC)
  WHERE read_at IS NULL;

-- Harden public.notifications: remove permissive FOR ALL policy and restrict client DML to read_at updates only.
DROP POLICY IF EXISTS notif_own ON public.notifications;
DROP POLICY IF EXISTS "notif_own" ON public.notifications;
DROP POLICY IF EXISTS notifications_select_own ON public.notifications;
DROP POLICY IF EXISTS notifications_update_own ON public.notifications;

REVOKE ALL ON public.notifications FROM anon, authenticated;
GRANT SELECT, UPDATE (read_at) ON public.notifications TO authenticated;
GRANT ALL ON public.notifications TO service_role;

CREATE POLICY notifications_select_own ON public.notifications
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE POLICY notifications_update_own ON public.notifications
  FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION private.enforce_notification_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF current_user NOT IN ('postgres', 'service_role') THEN
    IF OLD.id IS DISTINCT FROM NEW.id
       OR OLD.user_id IS DISTINCT FROM NEW.user_id
       OR OLD.kind IS DISTINCT FROM NEW.kind
       OR OLD.payload IS DISTINCT FROM NEW.payload
       OR OLD.created_at IS DISTINCT FROM NEW.created_at
       OR OLD.dedupe_key IS DISTINCT FROM NEW.dedupe_key THEN
      RAISE EXCEPTION 'notification_fields_immutable' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.enforce_notification_immutability() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_notifications_immutable_fields ON public.notifications;
CREATE TRIGGER trg_notifications_immutable_fields
  BEFORE UPDATE ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION private.enforce_notification_immutability();

-- Global notification preferences per user.
CREATE TABLE IF NOT EXISTS public.user_notification_preferences (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  replies boolean NOT NULL DEFAULT true,
  mentions boolean NOT NULL DEFAULT true,
  meeting_reminders boolean NOT NULL DEFAULT true,
  channel_activity boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_notification_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_notification_preferences FROM anon, authenticated;
GRANT SELECT ON public.user_notification_preferences TO authenticated;

DROP POLICY IF EXISTS user_notification_preferences_own ON public.user_notification_preferences;
CREATE POLICY user_notification_preferences_own ON public.user_notification_preferences
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION private.set_my_notification_preferences(
  p_replies boolean,
  p_mentions boolean,
  p_meeting_reminders boolean,
  p_channel_activity boolean DEFAULT true
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_replies IS NULL OR p_mentions IS NULL OR p_meeting_reminders IS NULL OR p_channel_activity IS NULL THEN
    RAISE EXCEPTION 'invalid_preferences' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.user_notification_preferences (
    user_id, replies, mentions, meeting_reminders, channel_activity, updated_at
  ) VALUES (
    auth.uid(), p_replies, p_mentions, p_meeting_reminders, p_channel_activity, now()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET replies = EXCLUDED.replies,
        mentions = EXCLUDED.mentions,
        meeting_reminders = EXCLUDED.meeting_reminders,
        channel_activity = EXCLUDED.channel_activity,
        updated_at = now();

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.set_my_notification_preferences(boolean, boolean, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.set_my_notification_preferences(boolean, boolean, boolean, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_my_notification_preferences(
  p_replies boolean,
  p_mentions boolean,
  p_meeting_reminders boolean,
  p_channel_activity boolean DEFAULT true
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.set_my_notification_preferences(p_replies, p_mentions, p_meeting_reminders, p_channel_activity);
$$;

REVOKE ALL ON FUNCTION public.set_my_notification_preferences(boolean, boolean, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_my_notification_preferences(boolean, boolean, boolean, boolean) TO authenticated;

-- Idempotent notification read RPC (Section 10.2).
CREATE OR REPLACE FUNCTION private.mark_my_notifications_read(
  p_ids uuid[] DEFAULT NULL,
  p_before timestamptz DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF (p_ids IS NULL) = (p_before IS NULL)
     OR (p_ids IS NOT NULL AND (cardinality(p_ids) = 0 OR cardinality(p_ids) > 100))
     OR p_before > now() + interval '5 seconds' THEN
    RAISE EXCEPTION 'invalid_read_request' USING ERRCODE = '23514';
  END IF;

  UPDATE public.notifications
     SET read_at = now()
   WHERE user_id = auth.uid()
     AND read_at IS NULL
     AND (
       (p_ids IS NOT NULL AND id = ANY(p_ids))
       OR (p_before IS NOT NULL AND created_at <= p_before)
     );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION private.mark_my_notifications_read(uuid[], timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.mark_my_notifications_read(uuid[], timestamptz)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_my_notifications_read(
  p_ids uuid[] DEFAULT NULL,
  p_before timestamptz DEFAULT NULL
) RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.mark_my_notifications_read(p_ids, p_before);
$$;

REVOKE ALL ON FUNCTION public.mark_my_notifications_read(uuid[], timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_my_notifications_read(uuid[], timestamptz)
  TO authenticated;
