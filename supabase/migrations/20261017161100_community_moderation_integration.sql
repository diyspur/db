-- M11: Moderation integration for club messages, target access validation, pending deduplication, and atomic sanction decisions.
-- Immutable additive migration.

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
     WHERE c.conrelid = 'public.content_reports'::regclass
       AND c.contype = 'c'
       AND a.attname = 'content_type'
  LOOP
    EXECUTE format('ALTER TABLE public.content_reports DROP CONSTRAINT %I', v_conname);
  END LOOP;

  ALTER TABLE public.content_reports
    ADD CONSTRAINT content_reports_content_type_valid
    CHECK (content_type IN ('comment', 'timed_comment', 'journal', 'post', 'club_message'));
END $$;

-- Prevent direct table inserts/updates bypassing report_content validation (audit finding #5).
REVOKE INSERT, UPDATE, DELETE ON public.content_reports FROM anon, authenticated;

-- Deduplicate any pre-existing duplicate pending reports before creating the unique index.
DELETE FROM public.content_reports a
USING public.content_reports b
WHERE a.id > b.id
  AND a.reporter_id = b.reporter_id
  AND a.content_type = b.content_type
  AND a.content_id = b.content_id
  AND a.status = 'pending'
  AND b.status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS content_reports_pending_dedupe_idx
  ON public.content_reports(reporter_id, content_type, content_id)
  WHERE status = 'pending';

-- Validate target existence and caller read authorization before accepting a report (SEC15).
CREATE OR REPLACE FUNCTION public.report_content(
  p_content_type text,
  p_content_id uuid,
  p_reason text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_trimmed text := btrim(coalesce(p_reason, ''));
  v_accessible boolean := false;
  v_id uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_content_id IS NULL
     OR p_content_type NOT IN ('comment', 'timed_comment', 'journal', 'post', 'club_message')
     OR length(v_trimmed) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'invalid_report' USING ERRCODE = '23514';
  END IF;

  IF p_content_type = 'club_message' THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.club_messages m
       WHERE m.id = p_content_id
         AND m.deleted_at IS NULL
         AND private.can_read_club_channel(m.channel_id)
    ) INTO v_accessible;
  ELSIF p_content_type = 'comment' THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.comments c
       WHERE c.id = p_content_id
         AND c.deleted_at IS NULL
         AND private.can_view_chapter(c.chapter_id)
    ) INTO v_accessible;
  ELSIF p_content_type = 'timed_comment' THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.video_timed_comments c
       WHERE c.id = p_content_id
         AND c.deleted_at IS NULL
         AND private.can_view_chapter(c.chapter_id)
    ) INTO v_accessible;
  ELSIF p_content_type = 'post' THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.feed_posts p
       WHERE p.id = p_content_id
         AND p.deleted_at IS NULL
    ) INTO v_accessible;
  ELSIF p_content_type = 'journal' THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.reading_journal_entries j
       WHERE j.id = p_content_id
         AND j.archived_at IS NULL
         AND (
           j.user_id = v_user
           OR j.visibility = 'public'::public.journal_visibility
         )
    ) INTO v_accessible;
  END IF;

  IF NOT COALESCE(v_accessible, false) THEN
    RAISE EXCEPTION 'target_unavailable' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.content_reports(reporter_id, content_type, content_id, reason, status)
  VALUES (v_user, p_content_type, p_content_id, v_trimmed, 'pending')
  ON CONFLICT (reporter_id, content_type, content_id) WHERE status = 'pending'
  DO UPDATE SET reason = EXCLUDED.reason
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.report_content(text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_content(text, uuid, text) TO authenticated;

-- Update hide_reported_content and review_content_report to support club_message and log to editorial_audit_log.
CREATE OR REPLACE FUNCTION public.hide_reported_content(p_report uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
BEGIN
  IF NOT COALESCE((SELECT public.is_admin()), false) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT id, content_type, content_id INTO r
    FROM public.content_reports
   WHERE id = p_report
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF r.content_type = 'comment' THEN
    UPDATE public.comments SET deleted_at = now() WHERE id = r.content_id;
  ELSIF r.content_type = 'timed_comment' THEN
    UPDATE public.video_timed_comments SET deleted_at = now() WHERE id = r.content_id;
  ELSIF r.content_type = 'post' THEN
    UPDATE public.feed_posts SET deleted_at = now() WHERE id = r.content_id;
  ELSIF r.content_type = 'journal' THEN
    UPDATE public.reading_journal_entries SET archived_at = now() WHERE id = r.content_id;
  ELSIF r.content_type = 'club_message' THEN
    UPDATE public.club_messages
       SET deleted_at = now(),
           version = version + 1
     WHERE id = r.content_id;
  ELSE
    RAISE EXCEPTION 'invalid_content_type' USING ERRCODE = '22023';
  END IF;

  UPDATE public.content_reports
     SET status = 'resolved',
         reviewed_by = (SELECT auth.uid()),
         reviewed_at = now()
   WHERE id = p_report;

  IF (SELECT auth.uid()) IS NOT NULL THEN
    INSERT INTO public.editorial_audit_log(actor_id, entity_type, entity_id, action, changes)
    VALUES (
      (SELECT auth.uid()),
      'content_report',
      p_report,
      'hide_reported_content',
      jsonb_build_object('content_type', r.content_type, 'content_id', r.content_id)
    );
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.hide_reported_content(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hide_reported_content(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.review_content_report(p_report uuid, p_status text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT COALESCE((SELECT public.is_admin()), false)
     OR p_status NOT IN ('resolved', 'dismissed') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.content_reports
     SET status = p_status,
         reviewed_by = (SELECT auth.uid()),
         reviewed_at = now()
   WHERE id = p_report;

  IF FOUND AND (SELECT auth.uid()) IS NOT NULL THEN
    INSERT INTO public.editorial_audit_log(actor_id, entity_type, entity_id, action, changes)
    VALUES (
      (SELECT auth.uid()),
      'content_report',
      p_report,
      'review_' || p_status,
      jsonb_build_object('status', p_status)
    );
    RETURN true;
  END IF;

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.review_content_report(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_content_report(uuid, text) TO authenticated;

-- Atomic moderation decision RPC supporting hide, mute, and ban within club or global admin scope (SDD 14.1).
CREATE OR REPLACE FUNCTION public.moderate_content_report(
  p_report uuid,
  p_action text,
  p_note text DEFAULT NULL,
  p_sanction_expires_at timestamptz DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_report public.content_reports%ROWTYPE;
  v_msg public.club_messages%ROWTYPE;
  v_club uuid;
  v_owner uuid;
  v_reason text := COALESCE(nullif(btrim(coalesce(p_note, '')), ''), 'Decisão de moderação da comunidade');
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;

  IF p_action NOT IN ('dismiss', 'resolve', 'hide_content', 'mute_member', 'ban_member') THEN
    RAISE EXCEPTION 'invalid_moderation_action' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_report
    FROM public.content_reports
   WHERE id = p_report
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_report.content_type = 'club_message' THEN
    SELECT m.* INTO v_msg
      FROM public.club_messages m
     WHERE m.id = v_report.content_id;

    IF FOUND THEN
      SELECT ch.club_id INTO v_club
        FROM public.club_channels ch
       WHERE ch.id = v_msg.channel_id;
    END IF;
  END IF;

  IF NOT (
    COALESCE((SELECT public.is_admin()), false)
    OR (v_club IS NOT NULL AND private.can_manage_club(v_club, v_actor))
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_action IN ('hide_content', 'mute_member', 'ban_member') THEN
    IF v_report.content_type = 'comment' THEN
      UPDATE public.comments SET deleted_at = now() WHERE id = v_report.content_id;
    ELSIF v_report.content_type = 'timed_comment' THEN
      UPDATE public.video_timed_comments SET deleted_at = now() WHERE id = v_report.content_id;
    ELSIF v_report.content_type = 'post' THEN
      UPDATE public.feed_posts SET deleted_at = now() WHERE id = v_report.content_id;
    ELSIF v_report.content_type = 'journal' THEN
      UPDATE public.reading_journal_entries SET archived_at = now() WHERE id = v_report.content_id;
    ELSIF v_report.content_type = 'club_message' THEN
      UPDATE public.club_messages
         SET deleted_at = now(),
             version = version + 1
       WHERE id = v_report.content_id;
    END IF;
  END IF;

  IF p_action IN ('mute_member', 'ban_member') AND v_club IS NOT NULL AND v_msg.author_id IS NOT NULL THEN
    SELECT owner_id INTO v_owner FROM public.user_clubs WHERE id = v_club;
    IF v_msg.author_id IS DISTINCT FROM v_owner AND v_msg.author_id IS DISTINCT FROM v_actor THEN
      INSERT INTO public.club_member_sanctions(club_id, user_id, kind, expires_at, reason, applied_by, created_at)
      VALUES (
        v_club,
        v_msg.author_id,
        CASE WHEN p_action = 'ban_member' THEN 'ban' ELSE 'mute' END,
        p_sanction_expires_at,
        left(v_reason, 500),
        v_actor,
        now()
      )
      ON CONFLICT (club_id, user_id) DO UPDATE
        SET kind = EXCLUDED.kind,
            expires_at = EXCLUDED.expires_at,
            reason = EXCLUDED.reason,
            applied_by = v_actor,
            created_at = now();

      IF p_action = 'ban_member' THEN
        DELETE FROM public.user_club_members
         WHERE club_id = v_club
           AND user_id = v_msg.author_id
           AND role <> 'owner';
      END IF;
    END IF;
  END IF;

  UPDATE public.content_reports
     SET status = CASE WHEN p_action = 'dismiss' THEN 'dismissed' ELSE 'resolved' END,
         reviewed_by = v_actor,
         reviewed_at = now()
   WHERE id = p_report;

  INSERT INTO public.editorial_audit_log(actor_id, entity_type, entity_id, action, changes)
  VALUES (
    v_actor,
    'content_report',
    p_report,
    p_action,
    jsonb_build_object(
      'content_type', v_report.content_type,
      'content_id', v_report.content_id,
      'club_id', v_club,
      'note', left(v_reason, 500)
    )
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.moderate_content_report(uuid, text, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.moderate_content_report(uuid, text, text, timestamptz) TO authenticated;
