import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const db = new PGlite();

const bootstrap = `
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE SCHEMA auth;
CREATE SCHEMA private;

CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated, service_role;

CREATE TYPE public.xp_source AS ENUM ('join_meeting','finish_chapter','comment','quiz_answer','finish_book','streak_bonus','meeting_attendance');
CREATE TYPE public.cycle_status AS ENUM ('planned','enrolling','active','finished');
CREATE TYPE public.shelf_status AS ENUM ('want_to_read','reading','read','dnf');
CREATE TYPE public.meeting_status AS ENUM ('scheduled','live','done','cancelled');
CREATE TYPE public.meeting_kind AS ENUM ('online','in_person','hybrid');
CREATE TYPE public.notification_kind AS ENUM ('new_chapter','meeting_reminder','reply','mention','badge_unlocked','poll_open');
CREATE TYPE public.mood_kind AS ENUM ('adventurous','emotional','dark','funny','hopeful','informative','inspiring','lighthearted','mysterious','reflective','sad','tense','challenging');
CREATE TYPE public.journal_visibility AS ENUM ('private','friends','club','public');

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY,
  username text UNIQUE NOT NULL,
  display_name text,
  avatar_url text,
  role text NOT NULL DEFAULT 'reader',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'admin'
  );
$$;

CREATE TABLE public.books (
  id uuid PRIMARY KEY,
  slug text UNIQUE NOT NULL,
  title text NOT NULL,
  author text NOT NULL DEFAULT 'Author',
  page_count integer,
  total_chapters integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.seasons (
  id uuid PRIMARY KEY,
  number integer NOT NULL,
  title text NOT NULL,
  slug text UNIQUE NOT NULL,
  book_id uuid NOT NULL REFERENCES public.books(id) ON DELETE RESTRICT,
  status public.cycle_status NOT NULL DEFAULT 'active',
  starts_at date,
  ends_at date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.chapters (
  id uuid PRIMARY KEY,
  season_id uuid NOT NULL REFERENCES public.seasons(id) ON DELETE CASCADE,
  number integer NOT NULL,
  title text NOT NULL,
  summary text,
  youtube_url text,
  release_date date,
  published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION private.can_view_chapter(p_chapter uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.chapters c
      JOIN public.seasons s ON s.id = c.season_id
     WHERE c.id = p_chapter
       AND (
         COALESCE((SELECT public.is_admin()), false)
         OR (
           s.status IN ('enrolling'::public.cycle_status, 'active'::public.cycle_status, 'finished'::public.cycle_status)
           AND c.published_at IS NOT NULL
           AND c.published_at <= now()
         )
       )
  );
$$;

CREATE TABLE public.user_progress (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  chapter_id uuid NOT NULL REFERENCES public.chapters(id) ON DELETE CASCADE,
  status public.shelf_status NOT NULL DEFAULT 'want_to_read',
  percent numeric(5,2) NOT NULL DEFAULT 0,
  current_page integer,
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, chapter_id)
);

CREATE FUNCTION private.is_book_complete(p_user uuid, p_book uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.user_progress up
      JOIN public.chapters c ON c.id = up.chapter_id
      JOIN public.seasons s ON s.id = c.season_id
     WHERE up.user_id = p_user
       AND s.book_id = p_book
       AND up.status = 'read'::public.shelf_status
  );
$$;

CREATE TABLE public.reading_goals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  year integer NOT NULL,
  target_books integer NOT NULL DEFAULT 12,
  target_pages integer,
  target_minutes integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, year)
);

CREATE TABLE public.reading_goal_progress (
  goal_id uuid PRIMARY KEY REFERENCES public.reading_goals(id) ON DELETE CASCADE,
  books_done integer NOT NULL DEFAULT 0,
  pages_done integer NOT NULL DEFAULT 0,
  minutes_done integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.reading_journal_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  book_id uuid NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  chapter_id uuid REFERENCES public.chapters(id) ON DELETE SET NULL,
  season_id uuid REFERENCES public.seasons(id) ON DELETE SET NULL,
  entry_date date NOT NULL DEFAULT CURRENT_DATE,
  page_from integer,
  page_to integer,
  percent_at numeric(5,2),
  minutes_read integer,
  mood_at_time public.mood_kind,
  title text,
  body text NOT NULL,
  visibility public.journal_visibility NOT NULL DEFAULT 'private',
  is_spoiler boolean NOT NULL DEFAULT false,
  min_percent numeric(5,2) NOT NULL DEFAULT 0,
  likes_count integer NOT NULL DEFAULT 0,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chapter_id uuid NOT NULL REFERENCES public.chapters(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  parent_id uuid REFERENCES public.comments(id) ON DELETE CASCADE,
  content text NOT NULL,
  is_spoiler boolean NOT NULL DEFAULT false,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.video_timed_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chapter_id uuid NOT NULL REFERENCES public.chapters(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  at_seconds integer NOT NULL DEFAULT 0,
  content text NOT NULL,
  is_locked boolean NOT NULL DEFAULT false,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.feed_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body text,
  quote_text text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.user_clubs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE NOT NULL,
  description text,
  owner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_private boolean NOT NULL DEFAULT false,
  current_book_id uuid REFERENCES public.books(id) ON DELETE SET NULL,
  current_season_id uuid REFERENCES public.seasons(id) ON DELETE SET NULL,
  current_started_at date,
  current_ends_at date,
  archived_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.user_club_members (
  club_id uuid NOT NULL REFERENCES public.user_clubs(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'moderator', 'member')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_id, user_id)
);

CREATE TABLE public.user_club_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  club_id uuid NOT NULL REFERENCES public.user_clubs(id) ON DELETE CASCADE,
  invited_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  invited_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX user_club_invitations_pending_unique
  ON public.user_club_invitations(club_id, invited_user_id)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

CREATE TABLE public.meetings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chapter_id uuid NOT NULL REFERENCES public.chapters(id) ON DELETE CASCADE,
  title text NOT NULL,
  agenda text,
  kind public.meeting_kind NOT NULL DEFAULT 'online',
  status public.meeting_status NOT NULL DEFAULT 'scheduled',
  scheduled_at timestamptz NOT NULL,
  duration_min integer NOT NULL DEFAULT 60,
  meeting_url text,
  location text,
  host_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  capacity integer,
  recording_url text,
  notes_markdown text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.meeting_rsvps (
  meeting_id uuid NOT NULL REFERENCES public.meetings(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  attending boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (meeting_id, user_id)
);

CREATE TABLE public.meeting_attendance (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  meeting_id uuid NOT NULL REFERENCES public.meetings(id) ON DELETE CASCADE,
  proof_type text NOT NULL,
  confirmed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, meeting_id)
);

CREATE TABLE private.sent_reminders (
  user_id uuid NOT NULL,
  meeting_id uuid NOT NULL,
  reminder_window text NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, meeting_id, reminder_window)
);

CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind public.notification_kind NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.content_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content_type text NOT NULL CHECK (content_type IN ('comment', 'timed_comment', 'journal', 'post')),
  content_id uuid NOT NULL,
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 500),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'resolved', 'dismissed')),
  reviewed_by uuid REFERENCES public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.editorial_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid NOT NULL REFERENCES public.profiles(id),
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  action text NOT NULL,
  changes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.xp_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  source public.xp_source NOT NULL,
  amount integer NOT NULL,
  ref_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX xp_events_user_source_ref_idx ON public.xp_events (user_id, source, ref_id) WHERE ref_id IS NOT NULL;

CREATE TABLE public.user_xp (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  total_xp integer NOT NULL DEFAULT 0,
  season_xp integer NOT NULL DEFAULT 0,
  season_id uuid REFERENCES public.seasons(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.rate_limit_buckets (
  user_id uuid NOT NULL,
  action text NOT NULL,
  window_start timestamptz NOT NULL,
  hits integer NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, action, window_start)
);

CREATE FUNCTION public.take_rate_limit(
  p_user uuid,
  p_action text,
  p_max_hits integer,
  p_window_seconds integer
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_bucket timestamptz;
  v_hits integer;
BEGIN
  IF p_user IS NULL OR p_max_hits <= 0 OR p_window_seconds <= 0 THEN
    RETURN false;
  END IF;
  v_bucket := to_timestamp(floor(extract(epoch FROM now()) / p_window_seconds) * p_window_seconds);
  INSERT INTO private.rate_limit_buckets (user_id, action, window_start, hits)
  VALUES (p_user, p_action, v_bucket, 1)
  ON CONFLICT (user_id, action, window_start)
  DO UPDATE SET hits = private.rate_limit_buckets.hits + 1
  RETURNING hits INTO v_hits;
  RETURN v_hits <= p_max_hits;
END;
$$;

CREATE FUNCTION public.award_xp(
  p_user uuid,
  p_source public.xp_source,
  p_amount integer,
  p_ref uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.xp_events(user_id, source, amount, ref_id)
  VALUES (p_user, p_source, p_amount, p_ref)
  ON CONFLICT (user_id, source, ref_id) WHERE ref_id IS NOT NULL DO NOTHING;
  IF FOUND THEN
    INSERT INTO public.user_xp(user_id, total_xp, season_xp)
    VALUES (p_user, p_amount, p_amount)
    ON CONFLICT (user_id) DO UPDATE
      SET total_xp = public.user_xp.total_xp + EXCLUDED.total_xp,
          season_xp = public.user_xp.season_xp + EXCLUDED.season_xp;
  END IF;
END;
$$;

CREATE FUNCTION private.revoke_club_invitation(p_invitation uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.user_club_invitations
     SET revoked_at = now()
   WHERE id = p_invitation
     AND invited_by = auth.uid()
     AND accepted_at IS NULL
     AND revoked_at IS NULL;
  RETURN FOUND;
END;
$$;

CREATE FUNCTION public.revoke_club_invitation(p_invitation uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$ SELECT private.revoke_club_invitation(p_invitation); $$;

CREATE FUNCTION private.accept_club_invitation(p_invitation uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN true;
END;
$$;

CREATE FUNCTION public.accept_club_invitation(p_invitation uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$ SELECT private.accept_club_invitation(p_invitation); $$;

CREATE FUNCTION private.remove_club_member(p_club uuid, p_member uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM public.user_club_members WHERE club_id = p_club AND user_id = p_member AND role <> 'owner';
  RETURN FOUND;
END;
$$;

CREATE FUNCTION public.remove_club_member(p_club uuid, p_member uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$ SELECT private.remove_club_member(p_club, p_member); $$;

CREATE FUNCTION private.join_user_club(p_club uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN true;
END;
$$;

CREATE FUNCTION public.join_user_club(p_club uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$ SELECT private.join_user_club(p_club); $$;

ALTER TABLE public.user_clubs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_club_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meeting_rsvps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY clubs_read ON public.user_clubs FOR SELECT TO anon, authenticated
  USING (NOT is_private OR owner_id = auth.uid());

CREATE POLICY club_members_read ON public.user_club_members FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY rsvps_read ON public.meeting_rsvps FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY notif_own ON public.notifications FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY content_reports_admin_read ON public.content_reports FOR SELECT TO authenticated
  USING ((SELECT public.is_admin()));

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.meeting_rsvps, public.notifications, public.content_reports TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public, private TO service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.can_view_chapter(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.is_book_complete(uuid, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.take_rate_limit(uuid, text, integer, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.join_user_club(uuid), public.accept_club_invitation(uuid), public.revoke_club_invitation(uuid), public.remove_club_member(uuid, uuid) TO authenticated, service_role;
`;

await db.exec(bootstrap);

const migrationFiles = [
  "20261017160100_official_book_groups.sql",
  "20261017160200_club_discussions_schema.sql",
  "20261017160300_club_discussions_security.sql",
  "20261017160400_club_discussions_rpcs.sql",
  "20261017160500_canonical_book_readings.sql",
  "20261017160600_book_reading_aggregates.sql",
  "20261017160700_book_scoped_meetings.sql",
  "20261017160800_notification_kinds_extension.sql",
  "20261017160900_notification_center_rpc.sql",
  "20261017161000_community_notification_outbox.sql",
  "20261017161100_community_moderation_integration.sql",
  "20261017161200_community_jobs_and_release_guards.sql",
];

for (const filename of migrationFiles) {
  const sql = await readFile(resolve(repoRoot, "supabase/migrations", filename), "utf8");
  await db.exec(sql);
  console.log(`PASS: applied ${filename}`);
}

const ids = {
  admin: "00000000-0000-4000-8000-000000000001",
  owner: "00000000-0000-4000-8000-000000000002",
  mod: "00000000-0000-4000-8000-000000000003",
  member1: "00000000-0000-4000-8000-000000000004",
  member2: "00000000-0000-4000-8000-000000000005",
  outsider: "00000000-0000-4000-8000-000000000006",
  book1: "10000000-0000-4000-8000-000000000001",
  book2: "10000000-0000-4000-8000-000000000002",
  season1: "20000000-0000-4000-8000-000000000001",
  seasonPlanned: "20000000-0000-4000-8000-000000000002",
  chapterPub: "30000000-0000-4000-8000-000000000001",
  chapterUnpub: "30000000-0000-4000-8000-000000000002",
  privateClub: "40000000-0000-4000-8000-000000000001",
  msgReq1: "50000000-0000-4000-8000-000000000001",
  msgReq2: "50000000-0000-4000-8000-000000000002",
  msgReq3: "50000000-0000-4000-8000-000000000003",
  readReq1: "60000000-0000-4000-8000-000000000001",
  readReq2: "60000000-0000-4000-8000-000000000002",
  meetReq1: "70000000-0000-4000-8000-000000000001",
  meetReq2: "70000000-0000-4000-8000-000000000002",
};

await db.exec(`
  INSERT INTO public.profiles (id, username, display_name, role) VALUES
    ('${ids.admin}', 'admin_user', 'Admin User', 'admin'),
    ('${ids.owner}', 'club_owner', 'Club Owner', 'reader'),
    ('${ids.mod}', 'club_mod', 'Club Mod', 'reader'),
    ('${ids.member1}', 'reader_one', 'Reader One', 'reader'),
    ('${ids.member2}', 'reader_two', 'Reader Two', 'reader'),
    ('${ids.outsider}', 'outsider_user', 'Outsider User', 'reader');

  INSERT INTO public.books (id, slug, title, author, page_count, total_chapters) VALUES
    ('${ids.book1}', 'dom-casmurro', 'Dom Casmurro', 'Machado de Assis', 256, 2),
    ('${ids.book2}', 'memorias-postumas', 'Memórias Póstumas', 'Machado de Assis', 320, 1);

  INSERT INTO public.seasons (id, number, title, slug, book_id, status, starts_at) VALUES
    ('${ids.season1}', 1, 'Temporada 1', 'temporada-1', '${ids.book1}', 'active', CURRENT_DATE - 7),
    ('${ids.seasonPlanned}', 2, 'Temporada 2', 'temporada-2', '${ids.book2}', 'planned', CURRENT_DATE + 30);

  INSERT INTO public.chapters (id, season_id, number, title, youtube_url, published_at) VALUES
    ('${ids.chapterPub}', '${ids.season1}', 1, 'Capítulo 1: Do Título', 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', now() - interval '1 day'),
    ('${ids.chapterUnpub}', '${ids.season1}', 2, 'Capítulo 2: Segredo Futuro', NULL, now() + interval '7 days');

  INSERT INTO public.user_clubs (id, name, slug, description, owner_id, is_private, kind, current_book_id, current_season_id)
  VALUES ('${ids.privateClub}', 'Clube Secreto', 'clube-secreto', 'Privado', '${ids.owner}', true, 'custom', '${ids.book1}', '${ids.season1}');

  INSERT INTO public.user_club_members (club_id, user_id, role) VALUES
    ('${ids.privateClub}', '${ids.owner}', 'owner'),
    ('${ids.privateClub}', '${ids.mod}', 'moderator'),
    ('${ids.privateClub}', '${ids.member1}', 'member');

  INSERT INTO public.club_channels (club_id, slug, name, kind, spoiler_policy, created_by)
  VALUES ('${ids.privateClub}', 'sem-spoilers', 'Sem spoilers', 'no_spoilers', 'none', '${ids.owner}');
`);

async function asUser(userId, fn) {
  await db.exec(`SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '${userId}', false);`);
  try {
    return await fn();
  } finally {
    await db.exec(`RESET ROLE; SELECT set_config('request.jwt.claim.sub', '', false);`);
  }
}

async function expectError(fn, pattern, label) {
  let failed = false;
  try {
    await fn();
  } catch (err) {
    failed = true;
    if (pattern) {
      assert.match(String(err), pattern, `Expected ${label} error to match ${pattern}, got: ${String(err)}`);
    }
  }
  assert.ok(failed, `Expected error for ${label}, but succeeded`);
}

// DB01: ensure_official_book_group is idempotent and creates 1 official club + default channels
const g1 = await asUser(ids.member1, () =>
  db.query(`SELECT * FROM public.ensure_official_book_group($1)`, [ids.book1]),
);
const g2 = await asUser(ids.member2, () =>
  db.query(`SELECT * FROM public.ensure_official_book_group($1)`, [ids.book1]),
);
assert.equal(g1.rows[0].club_id, g2.rows[0].club_id, "DB01: official book group is unique and idempotent");
const officialClubId = g1.rows[0].club_id;

await expectError(
  () =>
    db.query(
      `INSERT INTO public.user_clubs (name, slug, owner_id, is_private, kind, official_book_id, current_book_id)
       VALUES ('Dup', 'dup-official', $1, false, 'official', $2, $2)`,
      [ids.admin, ids.book1],
    ),
  /unique|duplicate/i,
  "DB01 unique official book index",
);

// DB02: non-admin cannot archive official club
await expectError(
  () => asUser(ids.member1, () => db.query(`UPDATE public.user_clubs SET archived_at = now() WHERE id = $1`, [officialClubId])),
  /42501|permission denied|only_admin_can_archive_official_club/i,
  "DB02 official club cannot be archived by non-admin",
);

// DB15: Deleting owner profile preserves official club
const tempOwner = "00000000-0000-4000-8000-000000000099";
await db.query(`INSERT INTO public.profiles (id, username, role) VALUES ($1, 'temp_owner', 'reader')`, [tempOwner]);
await db.query(`UPDATE public.user_clubs SET owner_id = $1 WHERE id = $2`, [tempOwner, officialClubId]);
await db.query(`DELETE FROM public.profiles WHERE id = $1`, [tempOwner]);
const officialAfterOwnerDelete = await db.query(`SELECT id, owner_id, kind FROM public.user_clubs WHERE id = $1`, [officialClubId]);
assert.equal(officialAfterOwnerDelete.rows.length, 1, "DB15: official club survives owner profile deletion");
console.log("PASS: DB01, DB02, DB15 official book group invariants");

// DB03 & SEC09: ensure_chapter_discussion requires chapter read + published, and redacts locked chapter titles in directory
await expectError(
  () => asUser(ids.member1, () => db.query(`SELECT * FROM public.ensure_chapter_discussion($1)`, [ids.chapterPub])),
  /42501|chapter_discussion_locked/i,
  "DB03 unread chapter blocked",
);
await db.query(
  `INSERT INTO public.user_progress (user_id, chapter_id, status, percent, finished_at) VALUES ($1, $2, 'read', 100, now())`,
  [ids.member1, ids.chapterPub],
);
const chDisc = await asUser(ids.member1, () =>
  db.query(`SELECT * FROM public.ensure_chapter_discussion($1)`, [ids.chapterPub]),
);
assert.equal(chDisc.rows[0].club_id, officialClubId);

await expectError(
  () => asUser(ids.member1, () => db.query(`SELECT * FROM public.ensure_chapter_discussion($1)`, [ids.chapterUnpub])),
  /42501|chapter_discussion_locked/i,
  "DB03 unpublished chapter blocked for reader",
);

// Admin creates channel for unpublished chapter; reader must see redacted title in directory
await db.query(
  `INSERT INTO public.user_progress (user_id, chapter_id, status, percent, finished_at) VALUES ($1, $2, 'read', 100, now())`,
  [ids.admin, ids.chapterUnpub],
);
await asUser(ids.admin, () => db.query(`SELECT * FROM public.ensure_chapter_discussion($1)`, [ids.chapterUnpub]));
const dirForReader = await asUser(ids.member1, () =>
  db.query(`SELECT slug, display_name, can_read, access_reason FROM public.get_club_channel_directory($1)`, [officialClubId]),
);
const lockedChRow = dirForReader.rows.find((r) => r.access_reason === "chapter_locked");
assert.ok(lockedChRow, "Reader sees locked chapter row in directory");
assert.equal(lockedChRow.display_name, "Capítulo 2 (bloqueado)", "SEC09: unpublished chapter title is redacted");
assert.ok(!lockedChRow.display_name.includes("Segredo Futuro"), "SEC09: future chapter title never leaked");
console.log("PASS: DB03 & SEC09 chapter discussion and title redaction");

// SEC01, SEC02, DB04: Private club channels and full_spoilers channel require membership / consent
const privChannelId = (
  await db.query(`SELECT id FROM public.club_channels WHERE club_id = $1 AND slug = 'sem-spoilers'`, [ids.privateClub])
).rows[0].id;
const outsiderRead = await asUser(ids.outsider, () =>
  db.query(`SELECT * FROM public.club_channels WHERE id = $1`, [privChannelId]),
);
assert.equal(outsiderRead.rows.length, 0, "SEC01: outsider cannot see private club channels");
await expectError(
  () => asUser(ids.outsider, () => db.query(`SELECT * FROM public.list_club_messages($1, NULL, NULL, 20)`, [privChannelId])),
  /42501|forbidden/i,
  "SEC01 outsider cannot list messages in private club",
);

const spoilersChannelId = (
  await db.query(`SELECT id FROM public.club_channels WHERE club_id = $1 AND slug = 'com-spoilers'`, [officialClubId])
).rows[0].id;
const noSpoilersChannelId = (
  await db.query(`SELECT id FROM public.club_channels WHERE club_id = $1 AND slug = 'sem-spoilers'`, [officialClubId])
).rows[0].id;

await expectError(
  () => asUser(ids.member1, () => db.query(`SELECT * FROM public.list_club_messages($1, NULL, NULL, 20)`, [spoilersChannelId])),
  /42501|forbidden/i,
  "DB04/SEC02 full_spoilers channel blocked before consent",
);
await asUser(ids.member1, () => db.query(`SELECT public.accept_channel_spoilers($1, 1)`, [spoilersChannelId]));
const spoilerMsgsAfterConsent = await asUser(ids.member1, () =>
  db.query(`SELECT * FROM public.list_club_messages($1, NULL, NULL, 20)`, [spoilersChannelId]),
);
assert.equal(spoilerMsgsAfterConsent.rows.length, 0, "DB04: full_spoilers channel readable after consent");
console.log("PASS: SEC01, SEC02, DB04 channel access & spoiler consent");

// DB05, SEC03: send_club_message idempotency, payload mismatch 40001, cross-channel reply rejection
const send1 = await asUser(ids.member1, () =>
  db.query(
    `SELECT * FROM public.send_club_message($1, $2, 'Olá comunidade @reader_two!', NULL, NULL)`,
    [noSpoilersChannelId, ids.msgReq1],
  ),
);
const send1Replay = await asUser(ids.member1, () =>
  db.query(
    `SELECT * FROM public.send_club_message($1, $2, 'Olá comunidade @reader_two!', NULL, NULL)`,
    [noSpoilersChannelId, ids.msgReq1],
  ),
);
assert.equal(send1.rows[0].id, send1Replay.rows[0].id, "DB05: idempotent replay returns same message id");

await expectError(
  () =>
    asUser(ids.member1, () =>
      db.query(
        `SELECT * FROM public.send_club_message($1, $2, 'Corpo diferente com mesmo UUID', NULL, NULL)`,
        [noSpoilersChannelId, ids.msgReq1],
      ),
    ),
  /40001|conflict/i,
  "DB05 client_message_id reuse with different body raises 40001",
);

// Cross-channel reply attempt must fail
await expectError(
  () =>
    asUser(ids.member1, () =>
      db.query(
        `SELECT * FROM public.send_club_message($1, $2, 'Reply cruzado', $3, NULL)`,
        [spoilersChannelId, ids.msgReq3, send1.rows[0].id],
      ),
    ),
  /23503|reply_target_unavailable/i,
  "SEC03 cross-channel reply rejected",
);
console.log("PASS: DB05 & SEC03 message idempotency & cross-channel reply protection");

// DB06: edit_club_message within 15m increments version; after 15m fails; wrong version fails
const msgId = send1.rows[0].id;
const edited = await asUser(ids.member1, () =>
  db.query(`SELECT public.edit_club_message($1, 1, 'Olá comunidade editado @reader_two!') AS version`, [msgId]),
);
assert.equal(Number(edited.rows[0].version), 2, "DB06: edit increments version to 2");

await expectError(
  () => asUser(ids.member1, () => db.query(`SELECT public.edit_club_message($1, 1, 'Stale edit')`, [msgId])),
  /40001|conflict/i,
  "DB06 optimistic locking conflict",
);

await db.query(`UPDATE public.club_messages SET created_at = now() - interval '16 minutes' WHERE id = $1`, [msgId]);
await expectError(
  () => asUser(ids.member1, () => db.query(`SELECT public.edit_club_message($1, 2, 'Late edit')`, [msgId])),
  /42501|edit_window_expired/i,
  "DB06 15-minute edit window enforced",
);
console.log("PASS: DB06 message editing & optimistic concurrency");

// SEC07 & SEC08: Sanctions (mute & ban) + ban blocks rejoin and replay
await asUser(ids.owner, () =>
  db.query(`SELECT public.apply_club_sanction($1, $2, 'mute', 'Spamming', now() + interval '1 hour')`, [ids.privateClub, ids.member1]),
);
await expectError(
  () =>
    asUser(ids.member1, () =>
      db.query(
        `SELECT * FROM public.send_club_message($1, gen_random_uuid(), 'Tentando falar mutado', NULL, NULL)`,
        [privChannelId],
      ),
    ),
  /42501|forbidden/i,
  "SEC07 muted member cannot post",
);

await asUser(ids.admin, () =>
  db.query(`SELECT public.apply_club_sanction($1, $2, 'ban', 'Abuse', NULL)`, [officialClubId, ids.member1]),
);
await expectError(
  () => asUser(ids.member1, () => db.query(`SELECT public.join_user_club($1)`, [officialClubId])),
  /42501|forbidden/i,
  "SEC08 banned member cannot rejoin public club",
);
await expectError(
  () =>
    asUser(ids.member1, () =>
      db.query(
        `SELECT * FROM public.send_club_message($1, $2, 'Olá comunidade editado @reader_two!', NULL, NULL)`,
        [noSpoilersChannelId, ids.msgReq1],
      ),
    ),
  /42501|forbidden/i,
  "SEC07 banned member cannot replay prior message",
);
// Unban member1 by expiring sanction so subsequent tests can use member1
await db.query(`UPDATE public.club_member_sanctions SET expires_at = now() - interval '1 second' WHERE user_id = $1`, [ids.member1]);
await asUser(ids.member1, () => db.query(`SELECT public.join_user_club($1)`, [officialClubId]));
console.log("PASS: SEC07 & SEC08 sanctions and ban enforcement");

// DB07 & DB08: set_my_book_reading transitions, idempotency, reading goals & v_book_reading_stats
const r1 = await asUser(ids.member1, () =>
  db.query(`SELECT * FROM public.set_my_book_reading($1, 'reading', 0, $2)`, [ids.book1, ids.readReq1]),
);
assert.equal(r1.rows[0].status, "reading", "DB07: initial status='reading'");
assert.equal(Number(r1.rows[0].version), 1);
assert.ok(r1.rows[0].first_started_at, "DB07: reading sets first_started_at");

const r2 = await asUser(ids.member1, () =>
  db.query(`SELECT * FROM public.set_my_book_reading($1, 'read', 1, $2)`, [ids.book1, ids.readReq2]),
);
assert.equal(r2.rows[0].status, "read");
assert.equal(Number(r2.rows[0].version), 2, "DB07: read increments version to 2");
assert.ok(r2.rows[0].completed_at, "DB07: read sets completed_at");

const r2Replay = await asUser(ids.member1, () =>
  db.query(`SELECT * FROM public.set_my_book_reading($1, 'read', 1, $2)`, [ids.book1, ids.readReq2]),
);
assert.equal(Number(r2Replay.rows[0].version), 2, "DB07: replay returns same version without error");

await expectError(
  () => asUser(ids.member1, () => db.query(`SELECT * FROM public.set_my_book_reading($1, 'want_to_read', 1, $2)`, [ids.book1, ids.readReq2])),
  /40001|conflict/i,
  "DB07 client_request_id reuse with different status fails",
);

await db.query(`SELECT public.refresh_book_reading_stats()`);
const stats = await db.query(`SELECT * FROM public.v_book_reading_stats WHERE book_id = $1`, [ids.book1]);
assert.equal(Number(stats.rows[0].completed_readers), 1, "DB08: v_book_reading_stats reflects canonical completed_readers");
assert.equal(Number(stats.rows[0].rank_position), 1, "DB08: rank_position computed via dense_rank");
console.log("PASS: DB07 & DB08 canonical book readings and aggregate rankings");

// DB09, DB10, SEC10: Book-scoped and club-scoped meetings with nullable chapter_id
const clubMeetingId = (
  await asUser(ids.owner, () =>
    db.query(
      `SELECT public.create_club_meeting($1, $2, NULL, 'Encontro Geral do Livro', 'online', now() + interval '2 days', 60, 'https://meet.example.com/123', NULL, 'Sem capítulo fixo', 'none', $3) AS id`,
      [ids.privateClub, ids.book1, ids.meetReq1],
    ),
  )
).rows[0].id;

const clubMeetingRow = await db.query(`SELECT * FROM public.meetings WHERE id = $1`, [clubMeetingId]);
assert.equal(clubMeetingRow.rows[0].chapter_id, null, "DB09: meeting created with chapter_id IS NULL");
assert.equal(clubMeetingRow.rows[0].book_id, ids.book1);

const outsiderMeetingView = await asUser(ids.outsider, () =>
  db.query(`SELECT * FROM public.meetings WHERE id = $1`, [clubMeetingId]),
);
assert.equal(outsiderMeetingView.rows.length, 0, "SEC10: outsider cannot view private club meeting");

await expectError(
  () =>
    asUser(ids.outsider, () =>
      db.query(`INSERT INTO public.meeting_rsvps (meeting_id, user_id, attending) VALUES ($1, $2, true)`, [
        clubMeetingId,
        ids.outsider,
      ]),
    ),
  /42501|row-level security/i,
  "SEC10 outsider cannot RSVP to private club meeting",
);

// DB10: Chapter from another book rejected
const chBook2 = "30000000-0000-4000-8000-000000000099";
await db.query(`INSERT INTO public.chapters (id, season_id, number, title, published_at) VALUES ($1, $2, 1, 'Ch B2', now())`, [
  chBook2,
  ids.seasonPlanned,
]);
await expectError(
  () =>
    asUser(ids.owner, () =>
      db.query(
        `SELECT public.create_club_meeting($1, $2, $3, 'Mismatch', 'online', now() + interval '3 days', 60, 'https://meet.example.com/x', NULL, NULL, 'none', $4)`,
        [ids.privateClub, ids.book1, chBook2, ids.meetReq2],
      ),
    ),
  /23514|meeting_chapter_book_mismatch/i,
  "DB10 chapter from different book rejected",
);
console.log("PASS: DB09, DB10, SEC10 book/club meetings and RLS");

// DB11, DB12, DB13, SEC11, SEC13: Outbox processing, neutral payloads, preferences, blocks, idempotent mark read
const outboxResult = await db.query(`SELECT public.process_community_notification_outbox(50) AS processed`);
assert.ok(Number(outboxResult.rows[0].processed) >= 1, "DB12: outbox processed pending events");

const m2Notifs = await asUser(ids.member2, () =>
  db.query(`SELECT id, kind, payload, read_at FROM public.notifications WHERE user_id = $1`, [ids.member2]),
);
assert.ok(m2Notifs.rows.length >= 1, "DB12: mentioned member received notification");
for (const n of m2Notifs.rows) {
  assert.equal(n.payload.excerpt, undefined, "SEC13: notification payload never contains message body excerpt");
  assert.equal(n.payload.content, undefined, "SEC13: notification payload never contains raw message content");
}

// SEC11: Direct client INSERT or payload UPDATE on notifications is blocked
await expectError(
  () =>
    asUser(ids.member2, () =>
      db.query(`INSERT INTO public.notifications (user_id, kind, payload) VALUES ($1, 'mention', '{}'::jsonb)`, [ids.member2]),
    ),
  /42501|permission denied|row-level security/i,
  "SEC11 direct client INSERT into notifications blocked",
);
await expectError(
  () =>
    asUser(ids.member2, () =>
      db.query(`UPDATE public.notifications SET payload = '{"hacked":true}'::jsonb WHERE id = $1`, [m2Notifs.rows[0].id]),
    ),
  /42501|permission denied|notification_fields_immutable/i,
  "SEC11 direct client UPDATE of notification payload blocked",
);

// DB11: mark_my_notifications_read is idempotent on replay
const mark1 = await asUser(ids.member2, () =>
  db.query(`SELECT public.mark_my_notifications_read($1, NULL) AS count`, [[m2Notifs.rows[0].id]]),
);
const mark2 = await asUser(ids.member2, () =>
  db.query(`SELECT public.mark_my_notifications_read($1, NULL) AS count`, [[m2Notifs.rows[0].id]]),
);
assert.equal(Number(mark1.rows[0].count), 1);
assert.equal(Number(mark2.rows[0].count), 0, "DB11: second call returns 0 without error");
console.log("PASS: DB11, DB12, DB13, SEC11, SEC13 notifications & outbox security");

// DB14 & SEC15: Content reporting and moderation queue
const privMsg = await asUser(ids.owner, () =>
  db.query(`SELECT * FROM public.send_club_message($1, gen_random_uuid(), 'Mensagem interna do clube privado', NULL, NULL)`, [privChannelId]),
);
await expectError(
  () =>
    asUser(ids.outsider, () =>
      db.query(`SELECT public.report_content('club_message', $1, 'Nao tenho acesso')`, [privMsg.rows[0].id]),
    ),
  /42501|target_unavailable/i,
  "SEC15 report_content rejects unreadable private message",
);

const reportId = (
  await asUser(ids.member2, () =>
    db.query(`SELECT public.report_content('club_message', $1, 'Spoiler sem tag') AS id`, [msgId]),
  )
).rows[0].id;
const reportIdDup = (
  await asUser(ids.member2, () =>
    db.query(`SELECT public.report_content('club_message', $1, 'Duplicado atualizado') AS id`, [msgId]),
  )
).rows[0].id;
assert.equal(reportId, reportIdDup, "DB14: duplicate pending report returns existing report id");

const queue = await asUser(ids.admin, () => db.query(`SELECT * FROM public.get_moderation_queue(NULL, 20)`));
assert.equal(queue.rows.length, 1, "Moderation queue returns pending report with context");
assert.equal(queue.rows[0].content_id, msgId);
assert.ok(queue.rows[0].content_excerpt.includes("Olá comunidade"), "Moderation queue includes safe excerpt");

await asUser(ids.admin, () =>
  db.query(`SELECT public.moderate_content_report($1, 'hide_content', 'Spoiler confirmado', NULL)`, [reportId]),
);
const hiddenMsg = await db.query(`SELECT deleted_at FROM public.club_messages WHERE id = $1`, [msgId]);
assert.ok(hiddenMsg.rows[0].deleted_at, "DB14: moderate_content_report soft-deletes target club_message");
console.log("PASS: DB14 & SEC15 moderation queue and report hardening");

// SEC16: Verify new private.* functions are not executable by anon
const leakyPrivates = await db.query(`
  SELECT p.proname
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'private'
    AND p.proname IN (
      'ensure_official_book_group',
      'ensure_chapter_discussion',
      'create_club_topic_channel',
      'accept_channel_spoilers',
      'revoke_channel_spoilers',
      'set_channel_preference',
      'block_community_user',
      'unblock_community_user',
      'apply_club_sanction',
      'set_club_member_role',
      'send_club_message',
      'edit_club_message',
      'delete_club_message',
      'set_my_book_reading',
      'refresh_book_reading_stats',
      'create_club_meeting',
      'update_club_meeting',
      'cancel_club_meeting',
      'set_my_notification_preferences',
      'mark_my_notifications_read',
      'process_community_notification_outbox'
    )
    AND has_function_privilege('anon', p.oid, 'EXECUTE')
`);
assert.deepEqual(leakyPrivates.rows, [], "SEC16: no private.* discussion/community function is executable by anon");
console.log("PASS: SEC16 private schema privilege isolation");

await db.close();
console.log("ALL COMMUNITY DISCUSSIONS PGLITE SMOKE TESTS PASSED!");
