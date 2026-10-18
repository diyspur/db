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
GRANT USAGE ON SCHEMA private TO authenticated, service_role;
GRANT ALL ON SCHEMA public TO service_role;

CREATE TYPE public.shelf_status AS ENUM ('want_to_read','reading','read','dnf');

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY,
  username text UNIQUE NOT NULL,
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.books (
  id uuid PRIMARY KEY,
  title text NOT NULL,
  slug text UNIQUE NOT NULL,
  total_pages integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.seasons (
  id uuid PRIMARY KEY,
  book_id uuid REFERENCES public.books(id),
  number integer NOT NULL,
  status text NOT NULL DEFAULT 'active'
);

CREATE TABLE public.chapters (
  id uuid PRIMARY KEY,
  season_id uuid REFERENCES public.seasons(id),
  number integer NOT NULL
);

CREATE TABLE public.user_progress (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles(id),
  chapter_id uuid REFERENCES public.chapters(id),
  status public.shelf_status NOT NULL,
  finished_at timestamptz,
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE public.user_book_readings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles(id),
  book_id uuid REFERENCES public.books(id),
  status text NOT NULL,
  completed_at timestamptz,
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE public.reading_journal_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles(id),
  book_id uuid REFERENCES public.books(id),
  entry_date date NOT NULL,
  page_from integer,
  page_to integer,
  minutes_read integer DEFAULT 0,
  archived_at timestamptz,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.reading_goals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles(id) NOT NULL,
  year integer NOT NULL,
  target_books integer,
  target_pages integer,
  target_minutes integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reading_goals_user_id_year_key UNIQUE (user_id, year)
);

CREATE TABLE public.reading_goal_progress (
  goal_id uuid PRIMARY KEY REFERENCES public.reading_goals(id) ON DELETE CASCADE,
  books_done integer,
  pages_done integer,
  minutes_done integer,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION private.is_book_complete(p_user uuid, p_book uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT true;
$$;
`;

await db.exec(bootstrap);

// Apply migration dropping unique constraint
const mig5 = await readFile(resolve(repoRoot, "supabase/migrations/20261018000500_multiple_personal_reading_goals.sql"), "utf-8");
await db.exec(mig5);

// Apply our new migration
const mig11 = await readFile(resolve(repoRoot, "supabase/migrations/20261018001100_reading_goals_crud_and_progress.sql"), "utf-8");
await db.exec(mig11);
await db.exec("GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;");

// Seed users and books
const userA = "11111111-1111-4111-a111-111111111111";
const userB = "22222222-2222-4222-a222-222222222222";
const book1 = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
const book2 = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb";

await db.query(`INSERT INTO public.profiles (id, username) VALUES ($1, 'userA'), ($2, 'userB')`, [userA, userB]);
await db.query(`INSERT INTO public.books (id, title, slug) VALUES ($1, 'Livro 1', 'livro-1'), ($2, 'Livro 2', 'livro-2')`, [book1, book2]);

// Act as userA
await db.exec(`SET request.jwt.claim.sub = '${userA}'; SET ROLE authenticated;`);

// Create Goal 1: 12 books
const goal1Res = await db.query(`
  SELECT public.set_personal_reading_goal(
    gen_random_uuid(),
    'Desafio Anual 12 Livros',
    2026,
    12,
    null,
    null,
    null
  ) as goal;
`);
const rawGoal1 = goal1Res.rows[0].goal;
const goal1 = typeof rawGoal1 === 'string' ? JSON.parse(rawGoal1) : rawGoal1;
assert.equal(goal1.year, 2026);
assert.equal(goal1.target_books, 12);
assert.equal(goal1.version, 1);

// Create Goal 2: 24 books in the same year 2026
const goal2Res = await db.query(`
  SELECT public.set_personal_reading_goal(
    gen_random_uuid(),
    'Meta Ambiciosa 24 Livros',
    2026,
    24,
    null,
    null,
    null
  ) as goal;
`);
const rawGoal2 = goal2Res.rows[0].goal;
const goal2 = typeof rawGoal2 === 'string' ? JSON.parse(rawGoal2) : rawGoal2;
assert.equal(goal2.year, 2026);
assert.equal(goal2.target_books, 24);
assert.equal(goal2.version, 1);
assert.notEqual(goal1.id, goal2.id);

// Complete 1 book in 2026
await db.exec(`SET ROLE service_role;`);
await db.query(`
  INSERT INTO public.user_book_readings (user_id, book_id, status, completed_at)
  VALUES ($1, $2, 'read', '2026-06-15T12:00:00Z');
`, [userA, book1]);

// Trigger recalculation
await db.query(`SELECT private.recalculate_reading_goals_for_user_year($1, 2026);`, [userA]);

// Check progress for BOTH goals!
const progressRes = await db.query(`
  SELECT g.title, g.target_books, p.books_done
  FROM public.reading_goals g
  JOIN public.reading_goal_progress p ON p.goal_id = g.id
  WHERE g.user_id = $1 AND g.year = 2026
  ORDER BY g.target_books;
`, [userA]);

assert.equal(progressRes.rows.length, 2, "Both goals must have progress records");
assert.equal(progressRes.rows[0].books_done, 1, "Goal 1 must have 1 book done");
assert.equal(progressRes.rows[1].books_done, 1, "Goal 2 must also have 1 book done (QA-04 fixed!)");

// Add reading in 2027 — must NOT affect 2026 goals
await db.query(`
  INSERT INTO public.user_book_readings (user_id, book_id, status, completed_at)
  VALUES ($1, $2, 'read', '2027-01-10T12:00:00Z');
`, [userA, book2]);
await db.query(`SELECT private.recalculate_reading_goals_for_user_year($1, 2026);`, [userA]);

const progressAfter2027 = await db.query(`
  SELECT p.books_done FROM public.reading_goal_progress p
  JOIN public.reading_goals g ON g.id = p.goal_id
  WHERE g.id = $1;
`, [goal1.id]);
assert.equal(progressAfter2027.rows[0].books_done, 1, "2027 reading must not bleed into 2026 goal");

// Test optimistic locking (version mismatch)
await db.exec(`SET request.jwt.claim.sub = '${userA}'; SET ROLE authenticated;`);
await assert.rejects(
  async () => {
    await db.query(`
      SELECT public.set_personal_reading_goal(
        $1, 'Título Alterado', 2026, 15, null, null, 999
      );
    `, [goal1.id]);
  },
  /conflict/,
  "Version mismatch must raise conflict"
);

// Test cross-user protection (User B cannot edit User A's goal)
await db.exec(`SET request.jwt.claim.sub = '${userB}'; SET ROLE authenticated;`);
await assert.rejects(
  async () => {
    await db.query(`
      SELECT public.set_personal_reading_goal(
        $1, 'Hack', 2026, 99, null, null, 1
      );
    `, [goal1.id]);
  },
  /forbidden/,
  "User B must not be able to edit User A goal"
);

// Archive Goal 2
await db.exec(`SET request.jwt.claim.sub = '${userA}'; SET ROLE authenticated;`);
const archiveRes = await db.query(`
  SELECT public.archive_personal_reading_goal($1, 1);
`, [goal2.id]);
assert.equal(archiveRes.rows[0].archive_personal_reading_goal, true);

// Verify Goal 2 has no progress row anymore, while Goal 1 is still active
const remainingProgress = await db.query(`
  SELECT g.title FROM public.reading_goal_progress p
  JOIN public.reading_goals g ON g.id = p.goal_id
  WHERE g.user_id = $1;
`, [userA]);
assert.equal(remainingProgress.rows.length, 1);
assert.equal(remainingProgress.rows[0].title, 'Desafio Anual 12 Livros');

console.log("ALL MULTIPLE READING GOALS SMOKE TESTS PASSED!");
