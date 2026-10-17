-- M10: Community notification outbox, atomic enqueue triggers, and spoiler-safe delivery worker RPC.
-- Immutable additive migration.

CREATE TABLE IF NOT EXISTS private.community_notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_key text NOT NULL UNIQUE,
  event_type text NOT NULL
    CHECK (event_type IN ('message_created', 'meeting_updated', 'meeting_cancelled', 'club_invitation')),
  entity_id uuid NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  processed_at timestamptz,
  last_error_code text
);

CREATE INDEX IF NOT EXISTS community_notification_outbox_pending_idx
  ON private.community_notification_outbox(next_attempt_at ASC, created_at ASC)
  WHERE processed_at IS NULL AND attempts < 5;

REVOKE ALL ON private.community_notification_outbox FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.community_notification_outbox TO service_role;

-- Atomic enqueue triggers (no fanout inside user request transactions).
CREATE OR REPLACE FUNCTION private.enqueue_club_message_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO private.community_notification_outbox (
    event_key, event_type, entity_id, payload
  ) VALUES (
    'msg:' || NEW.id::text,
    'message_created',
    NEW.id,
    jsonb_build_object(
      'message_id', NEW.id,
      'channel_id', NEW.channel_id,
      'author_id', NEW.author_id,
      'reply_to_id', NEW.reply_to_id
    )
  )
  ON CONFLICT (event_key) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.enqueue_club_message_outbox() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_club_messages_outbox ON public.club_messages;
CREATE TRIGGER trg_club_messages_outbox
  AFTER INSERT ON public.club_messages
  FOR EACH ROW EXECUTE FUNCTION private.enqueue_club_message_outbox();

CREATE OR REPLACE FUNCTION private.enqueue_meeting_change_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_type text;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'cancelled'::public.meeting_status THEN
    v_type := 'meeting_cancelled';
  ELSIF OLD.scheduled_at IS DISTINCT FROM NEW.scheduled_at
     OR OLD.title IS DISTINCT FROM NEW.title
     OR OLD.location IS DISTINCT FROM NEW.location
     OR OLD.meeting_url IS DISTINCT FROM NEW.meeting_url THEN
    v_type := 'meeting_updated';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO private.community_notification_outbox (
    event_key, event_type, entity_id, payload
  ) VALUES (
    v_type || ':' || NEW.id::text || ':v' || NEW.version::text,
    v_type,
    NEW.id,
    jsonb_build_object(
      'meeting_id', NEW.id,
      'version', NEW.version,
      'scheduled_at', NEW.scheduled_at,
      'actor_id', auth.uid()
    )
  )
  ON CONFLICT (event_key) DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.enqueue_meeting_change_outbox() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_meetings_change_outbox ON public.meetings;
CREATE TRIGGER trg_meetings_change_outbox
  AFTER UPDATE ON public.meetings
  FOR EACH ROW EXECUTE FUNCTION private.enqueue_meeting_change_outbox();

CREATE OR REPLACE FUNCTION private.enqueue_club_invitation_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO private.community_notification_outbox (
    event_key, event_type, entity_id, payload
  ) VALUES (
    'invite:' || NEW.id::text,
    'club_invitation',
    NEW.id,
    jsonb_build_object(
      'invitation_id', NEW.id,
      'club_id', NEW.club_id,
      'invited_user_id', NEW.invited_user_id
    )
  )
  ON CONFLICT (event_key) DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.enqueue_club_invitation_outbox() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_club_invitations_outbox ON public.user_club_invitations;
CREATE TRIGGER trg_club_invitations_outbox
  AFTER INSERT ON public.user_club_invitations
  FOR EACH ROW EXECUTE FUNCTION private.enqueue_club_invitation_outbox();

-- Helper: check if a specific user is eligible to receive notifications for a channel at delivery time.
CREATE OR REPLACE FUNCTION private.can_user_receive_channel_notification(
  p_user uuid,
  p_channel uuid,
  p_author uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_user IS NOT NULL
     AND (p_author IS NULL OR p_user <> p_author)
     AND EXISTS (
       SELECT 1
         FROM public.club_channels ch
         JOIN public.user_clubs cl ON cl.id = ch.club_id
         JOIN public.user_club_members m
           ON m.club_id = cl.id
          AND m.user_id = p_user
        WHERE ch.id = p_channel
          AND cl.archived_at IS NULL
          AND ch.archived_at IS NULL
          AND NOT private.is_club_banned(cl.id, p_user)
          AND (
            ch.kind <> 'chapter' OR EXISTS (
              SELECT 1
                FROM public.user_progress p
               WHERE p.user_id = p_user
                 AND p.chapter_id = ch.chapter_id
                 AND p.status = 'read'::public.shelf_status
            )
          )
     )
     AND (
       p_author IS NULL OR NOT EXISTS (
         SELECT 1
           FROM public.community_user_blocks b
          WHERE (b.user_id = p_user AND b.blocked_user_id = p_author)
             OR (b.user_id = p_author AND b.blocked_user_id = p_user)
       )
     )
     AND COALESCE(
       (
         SELECT pref.mode <> 'muted'
           FROM public.club_channel_preferences pref
          WHERE pref.channel_id = p_channel
            AND pref.user_id = p_user
       ),
       true
     );
$$;

REVOKE ALL ON FUNCTION private.can_user_receive_channel_notification(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Process outbox batch with SKIP LOCKED, delivery-time authorization, and neutral spoiler-free payloads.
CREATE OR REPLACE FUNCTION private.process_community_notification_outbox(
  p_batch_size integer DEFAULT 50
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_item private.community_notification_outbox%ROWTYPE;
  v_msg public.club_messages%ROWTYPE;
  v_ch public.club_channels%ROWTYPE;
  v_cl public.user_clubs%ROWTYPE;
  v_meeting public.meetings%ROWTYPE;
  v_inv public.user_club_invitations%ROWTYPE;
  v_reply_author uuid;
  v_mention record;
  v_follower record;
  v_rsvp record;
  v_bucket text;
  v_processed integer := 0;
BEGIN
  FOR v_item IN
    SELECT *
      FROM private.community_notification_outbox o
     WHERE o.processed_at IS NULL
       AND o.attempts < 5
       AND o.next_attempt_at <= now()
       AND (o.locked_until IS NULL OR o.locked_until <= now())
     ORDER BY o.created_at ASC
     FOR UPDATE SKIP LOCKED
     LIMIT LEAST(GREATEST(COALESCE(p_batch_size, 50), 1), 200)
  LOOP
    BEGIN
      UPDATE private.community_notification_outbox
         SET locked_until = now() + interval '2 minutes',
             attempts = attempts + 1
       WHERE id = v_item.id;

      IF v_item.event_type = 'message_created' THEN
        SELECT * INTO v_msg
          FROM public.club_messages
         WHERE id = v_item.entity_id
           AND deleted_at IS NULL;

        IF FOUND THEN
          SELECT * INTO v_ch
            FROM public.club_channels
           WHERE id = v_msg.channel_id
             AND archived_at IS NULL;

          SELECT * INTO v_cl
            FROM public.user_clubs
           WHERE id = v_ch.club_id
             AND archived_at IS NULL;

          IF v_ch.id IS NOT NULL AND v_cl.id IS NOT NULL THEN
            -- 1. Reply notification
            IF v_msg.reply_to_id IS NOT NULL THEN
              SELECT author_id INTO v_reply_author
                FROM public.club_messages
               WHERE id = v_msg.reply_to_id
                 AND deleted_at IS NULL;

              IF v_reply_author IS NOT NULL
                 AND private.can_user_receive_channel_notification(v_reply_author, v_ch.id, v_msg.author_id)
                 AND COALESCE(
                   (SELECT np.replies FROM public.user_notification_preferences np WHERE np.user_id = v_reply_author),
                   true
                 ) THEN
                INSERT INTO public.notifications (user_id, kind, dedupe_key, payload)
                VALUES (
                  v_reply_author,
                  'reply'::public.notification_kind,
                  'reply:' || v_msg.id::text || ':' || v_reply_author::text,
                  jsonb_build_object(
                    'title', 'Nova resposta em uma conversa acompanhada',
                    'entity_type', 'club_message',
                    'entity_id', v_msg.id,
                    'channel_id', v_ch.id,
                    'club_id', v_cl.id
                  )
                )
                ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING;
              END IF;
            END IF;

            -- 2. Validated @username mentions
            FOR v_mention IN
              SELECT DISTINCT p.id AS user_id
                FROM regexp_matches(lower(v_msg.content), '(?:^|[^a-z0-9_])@([a-z0-9_]{3,24})', 'g') m(match)
                JOIN public.profiles p ON lower(p.username) = m.match[1]
               WHERE p.id IS DISTINCT FROM v_msg.author_id
            LOOP
              IF private.can_user_receive_channel_notification(v_mention.user_id, v_ch.id, v_msg.author_id)
                 AND COALESCE(
                   (SELECT np.mentions FROM public.user_notification_preferences np WHERE np.user_id = v_mention.user_id),
                   true
                 ) THEN
                INSERT INTO public.notifications (user_id, kind, dedupe_key, payload)
                VALUES (
                  v_mention.user_id,
                  'mention'::public.notification_kind,
                  'mention:' || v_msg.id::text || ':' || v_mention.user_id::text,
                  jsonb_build_object(
                    'title', 'Você foi mencionado(a) em uma conversa acompanhada',
                    'entity_type', 'club_message',
                    'entity_id', v_msg.id,
                    'channel_id', v_ch.id,
                    'club_id', v_cl.id
                  )
                )
                ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING;
              END IF;
            END LOOP;

            -- 3. 15-minute bucketed activity for members following the channel
            v_bucket := (extract(epoch from v_msg.created_at)::bigint / 900)::text;
            FOR v_follower IN
              SELECT pref.user_id
                FROM public.club_channel_preferences pref
               WHERE pref.channel_id = v_ch.id
                 AND pref.mode = 'following'
                 AND pref.user_id IS DISTINCT FROM v_msg.author_id
                 AND pref.user_id IS DISTINCT FROM v_reply_author
            LOOP
              IF private.can_user_receive_channel_notification(v_follower.user_id, v_ch.id, v_msg.author_id)
                 AND COALESCE(
                   (SELECT np.channel_activity FROM public.user_notification_preferences np WHERE np.user_id = v_follower.user_id),
                   true
                 ) THEN
                INSERT INTO public.notifications (user_id, kind, dedupe_key, payload)
                VALUES (
                  v_follower.user_id,
                  'channel_activity'::public.notification_kind,
                  'activity:' || v_ch.id::text || ':' || v_bucket || ':' || v_follower.user_id::text,
                  jsonb_build_object(
                    'title', 'Novas mensagens em um canal que você acompanha',
                    'entity_type', 'club_channel',
                    'entity_id', v_ch.id,
                    'channel_id', v_ch.id,
                    'club_id', v_cl.id
                  )
                )
                ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING;
              END IF;
            END LOOP;
          END IF;
        END IF;

      ELSIF v_item.event_type IN ('meeting_updated', 'meeting_cancelled') THEN
        SELECT * INTO v_meeting
          FROM public.meetings
         WHERE id = v_item.entity_id;

        IF FOUND THEN
          FOR v_rsvp IN
            SELECT r.user_id
              FROM public.meeting_rsvps r
             WHERE r.meeting_id = v_meeting.id
               AND r.attending = true
               AND (
                 v_meeting.club_id IS NULL
                 OR NOT private.is_club_banned(v_meeting.club_id, r.user_id)
               )
          LOOP
            IF COALESCE(
              (SELECT np.meeting_reminders FROM public.user_notification_preferences np WHERE np.user_id = v_rsvp.user_id),
              true
            ) THEN
              INSERT INTO public.notifications (user_id, kind, dedupe_key, payload)
              VALUES (
                v_rsvp.user_id,
                CASE
                  WHEN v_item.event_type = 'meeting_cancelled'
                    THEN 'meeting_cancelled'::public.notification_kind
                  ELSE 'meeting_updated'::public.notification_kind
                END,
                'meeting-change:' || v_meeting.id::text || ':' || COALESCE(v_item.payload->>'version', '1') || ':' || v_rsvp.user_id::text,
                jsonb_build_object(
                  'title',
                  CASE
                    WHEN v_item.event_type = 'meeting_cancelled'
                      THEN 'Encontro cancelado na sua agenda'
                    ELSE 'Horário ou detalhes de encontro atualizados'
                  END,
                  'entity_type', 'meeting',
                  'entity_id', v_meeting.id,
                  'meeting_id', v_meeting.id,
                  'at', v_meeting.scheduled_at
                )
              )
              ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING;
            END IF;
          END LOOP;
        END IF;

      ELSIF v_item.event_type = 'club_invitation' THEN
        SELECT * INTO v_inv
          FROM public.user_club_invitations
         WHERE id = v_item.entity_id
           AND accepted_at IS NULL
           AND revoked_at IS NULL
           AND expires_at > now();

        IF FOUND AND NOT private.is_club_banned(v_inv.club_id, v_inv.invited_user_id) THEN
          INSERT INTO public.notifications (user_id, kind, dedupe_key, payload)
          VALUES (
            v_inv.invited_user_id,
            'club_invitation'::public.notification_kind,
            'club-invite:' || v_inv.id::text,
            jsonb_build_object(
              'title', 'Você recebeu um convite para participar de um grupo',
              'entity_type', 'club_invitation',
              'entity_id', v_inv.id,
              'club_id', v_inv.club_id
            )
          )
          ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING;
        END IF;
      END IF;

      UPDATE private.community_notification_outbox
         SET processed_at = now(),
             locked_until = NULL,
             last_error_code = NULL
       WHERE id = v_item.id;

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE private.community_notification_outbox
         SET locked_until = NULL,
             next_attempt_at = now() + make_interval(secs => LEAST(300, 15 * (2 ^ GREATEST(v_item.attempts, 0)))::integer),
             last_error_code = SQLSTATE
       WHERE id = v_item.id;
    END;
  END LOOP;

  RETURN v_processed;
END;
$$;

REVOKE ALL ON FUNCTION private.process_community_notification_outbox(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.process_community_notification_outbox(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.process_community_notification_outbox(
  p_batch_size integer DEFAULT 50
) RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.process_community_notification_outbox(p_batch_size);
$$;

REVOKE ALL ON FUNCTION public.process_community_notification_outbox(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_community_notification_outbox(integer) TO service_role;
