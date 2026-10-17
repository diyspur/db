-- M02: Persistent channels, messages, spoiler consents, preferences, sanctions, blocks, and editorial prompts.
-- Immutable additive migration.

CREATE TABLE IF NOT EXISTS public.club_channels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  club_id uuid NOT NULL REFERENCES public.user_clubs(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('no_spoilers', 'full_spoilers', 'chapter', 'topic')),
  slug text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,99}$'),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  chapter_id uuid REFERENCES public.chapters(id) ON DELETE RESTRICT,
  spoiler_policy text NOT NULL DEFAULT 'none'
    CHECK (spoiler_policy IN ('none', 'whole_book', 'chapter')),
  rules_version integer NOT NULL DEFAULT 1 CHECK (rules_version > 0),
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (club_id, slug),
  CHECK ((kind = 'chapter') = (chapter_id IS NOT NULL)),
  CHECK (
    (kind = 'no_spoilers' AND spoiler_policy = 'none')
    OR (kind = 'full_spoilers' AND spoiler_policy = 'whole_book')
    OR (kind = 'chapter' AND spoiler_policy = 'chapter')
    OR (kind = 'topic' AND spoiler_policy IN ('none', 'whole_book'))
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS club_default_channel_unique
  ON public.club_channels(club_id, kind)
  WHERE kind IN ('no_spoilers', 'full_spoilers');

CREATE UNIQUE INDEX IF NOT EXISTS club_chapter_channel_unique
  ON public.club_channels(club_id, chapter_id)
  WHERE chapter_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS club_channels_chapter_idx
  ON public.club_channels(chapter_id);

CREATE INDEX IF NOT EXISTS club_channels_created_by_idx
  ON public.club_channels(created_by);

CREATE TABLE IF NOT EXISTS public.club_channel_consents (
  channel_id uuid NOT NULL REFERENCES public.club_channels(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rules_version integer NOT NULL CHECK (rules_version > 0),
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX IF NOT EXISTS club_channel_consents_user_idx
  ON public.club_channel_consents(user_id);

CREATE TABLE IF NOT EXISTS public.club_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id uuid NOT NULL REFERENCES public.club_channels(id) ON DELETE CASCADE,
  author_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  client_message_id uuid NOT NULL,
  content text NOT NULL CHECK (length(btrim(content)) BETWEEN 1 AND 4000),
  reply_to_id uuid,
  video_sec integer CHECK (video_sec BETWEEN 0 AND 86400),
  version bigint NOT NULL DEFAULT 1,
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel_id, id),
  UNIQUE (author_id, client_message_id),
  FOREIGN KEY (channel_id, reply_to_id)
    REFERENCES public.club_messages(channel_id, id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS club_messages_history_idx
  ON public.club_messages(channel_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS club_messages_author_idx
  ON public.club_messages(author_id);

CREATE INDEX IF NOT EXISTS club_messages_reply_idx
  ON public.club_messages(channel_id, reply_to_id);

CREATE TABLE IF NOT EXISTS public.club_channel_preferences (
  channel_id uuid NOT NULL REFERENCES public.club_channels(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  mode text NOT NULL DEFAULT 'mentions'
    CHECK (mode IN ('muted', 'mentions', 'following')),
  last_seen_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX IF NOT EXISTS club_channel_preferences_user_idx
  ON public.club_channel_preferences(user_id);

CREATE TABLE IF NOT EXISTS public.club_member_sanctions (
  club_id uuid NOT NULL REFERENCES public.user_clubs(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('mute', 'ban')),
  expires_at timestamptz,
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 500),
  applied_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_id, user_id)
);

CREATE INDEX IF NOT EXISTS club_member_sanctions_user_idx
  ON public.club_member_sanctions(user_id);

CREATE INDEX IF NOT EXISTS club_member_sanctions_actor_idx
  ON public.club_member_sanctions(applied_by);

CREATE TABLE IF NOT EXISTS public.community_user_blocks (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  blocked_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, blocked_user_id),
  CHECK (user_id <> blocked_user_id)
);

CREATE INDEX IF NOT EXISTS community_user_blocks_target_idx
  ON public.community_user_blocks(blocked_user_id);

CREATE TABLE IF NOT EXISTS public.club_channel_prompts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id uuid NOT NULL REFERENCES public.club_channels(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (length(btrim(body)) BETWEEN 3 AND 1000),
  position integer NOT NULL DEFAULT 0 CHECK (position >= 0),
  published_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS club_channel_prompts_channel_idx
  ON public.club_channel_prompts(channel_id, position ASC, created_at ASC);

CREATE INDEX IF NOT EXISTS club_channel_prompts_created_by_idx
  ON public.club_channel_prompts(created_by);

-- Enforce that chapter channels in an official book club belong to that book.
CREATE OR REPLACE FUNCTION private.validate_club_channel_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_club_kind text;
  v_official_book uuid;
  v_chapter_book uuid;
BEGIN
  SELECT kind, official_book_id
    INTO v_club_kind, v_official_book
    FROM public.user_clubs
   WHERE id = NEW.club_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'club_not_found' USING ERRCODE = '23503';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.club_id IS DISTINCT FROM NEW.club_id
       OR OLD.kind IS DISTINCT FROM NEW.kind
       OR OLD.chapter_id IS DISTINCT FROM NEW.chapter_id THEN
      RAISE EXCEPTION 'cannot_change_channel_identity' USING ERRCODE = '42501';
    END IF;
    IF OLD.kind IN ('no_spoilers', 'full_spoilers')
       AND (OLD.slug IS DISTINCT FROM NEW.slug OR NEW.archived_at IS NOT NULL) THEN
      RAISE EXCEPTION 'default_channels_are_immutable' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NEW.chapter_id IS NOT NULL THEN
    SELECT s.book_id
      INTO v_chapter_book
      FROM public.chapters c
      JOIN public.seasons s ON s.id = c.season_id
     WHERE c.id = NEW.chapter_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'chapter_not_found' USING ERRCODE = '23503';
    END IF;

    IF v_club_kind = 'official' AND v_chapter_book IS DISTINCT FROM v_official_book THEN
      RAISE EXCEPTION 'chapter_book_mismatch' USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.validate_club_channel_context() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_club_channels_context ON public.club_channels;
CREATE TRIGGER trg_club_channels_context
  BEFORE INSERT OR UPDATE ON public.club_channels
  FOR EACH ROW EXECUTE FUNCTION private.validate_club_channel_context();
