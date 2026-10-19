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
  title text NOT NULL DEFAULT 'Minha meta de leitura',
  year integer NOT NULL,
  target_books integer,
  target_pages integer,
  target_minutes integer,
  version bigint NOT NULL DEFAULT 1,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.reading_goal_progress (
  goal_id uuid PRIMARY KEY REFERENCES public.reading_goals(id) ON DELETE CASCADE,
  books_done integer,
  pages_done integer,
  minutes_done integer,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.user_up_next (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  book_id uuid NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  position integer NOT NULL,
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, book_id),
  UNIQUE (user_id, position)
);

CREATE FUNCTION private.is_book_complete(p_user uuid, p_book uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT true;
$$;
`;

await db.exec(bootstrap);

// Apply prior baseline migrations
const mig5 = await readFile(resolve(repoRoot, "supabase/migrations/20261018000500_multiple_personal_reading_goals.sql"), "utf-8");
await db.exec(mig5);

const mig11 = await readFile(resolve(repoRoot, "supabase/migrations/20261018001100_reading_goals_crud_and_progress.sql"), "utf-8");
await db.exec(mig11);

const mig12 = await readFile(resolve(repoRoot, "supabase/migrations/20261018001200_continuous_up_next_queue.sql"), "utf-8");
await db.exec(mig12);

const mig15 = await readFile(resolve(repoRoot, "supabase/migrations/20261018001500_repair_personal_goals_contract.sql"), "utf-8");
await db.exec(mig15);

const mig16 = await readFile(resolve(repoRoot, "supabase/migrations/20261018001600_up_next_reorder_rpc.sql"), "utf-8");
await db.exec(mig16);

// Apply strict migration if it exists
try {
  const mig17 = await readFile(resolve(repoRoot, "supabase/migrations/20261018001700_strict_up_next_and_goals.sql"), "utf-8");
  await db.exec(mig17);
} catch {
  // Expected before Step 2.3
}

await db.exec("GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;");

// Seed users and books
const userA = "11111111-1111-4111-a111-111111111111";
const userB = "22222222-2222-4222-a222-222222222222";
const book1 = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
const book2 = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb";
const book3 = "cccccccc-cccc-4ccc-cccc-cccccccccccc";
const bookForeign = "dddddddd-dddd-4ddd-dddd-dddddddddddd";

await db.query(`INSERT INTO public.profiles (id, username) VALUES ($1, 'userA'), ($2, 'userB')`, [userA, userB]);
await db.query(`INSERT INTO public.books (id, title, slug) VALUES
  ($1, 'Livro 1', 'livro-1'),
  ($2, 'Livro 2', 'livro-2'),
  ($3, 'Livro 3', 'livro-3'),
  ($4, 'Livro Fora', 'livro-fora')`,
  [book1, book2, book3, bookForeign]
);

// Act as userA
await db.exec(`SET request.jwt.claim.sub = '${userA}'; SET ROLE authenticated;`);

// Populate userA queue with book1, book2, book3 (positions 1, 2, 3)
await db.query(`SELECT public.add_to_up_next_atomic($1);`, [book1]);
await db.query(`SELECT public.add_to_up_next_atomic($1);`, [book2]);
await db.query(`SELECT public.add_to_up_next_atomic($1);`, [book3]);

console.log("1. Test reorder with foreign book (not in user's queue) -> expects 40900");
await assert.rejects(
  async () => {
    await db.query(`SELECT public.reorder_up_next(ARRAY[$1, $2, $3]::uuid[]);`, [book1, book2, bookForeign]);
  },
  (err) => {
    const matched = err.code === "40900" || /queue_changed_or_invalid_order|40900/.test(err.message);
    assert.ok(matched, `Expected 40900 or queue_changed_or_invalid_order, got: ${err.code} ${err.message}`);
    return true;
  },
  "Reorder with foreign book must fail with 40900"
);

console.log("2. Test reorder with incomplete array (cardinality 2 vs queue 3) -> expects 40900");
await assert.rejects(
  async () => {
    await db.query(`SELECT public.reorder_up_next(ARRAY[$1, $2]::uuid[]);`, [book1, book2]);
  },
  (err) => {
    const matched = err.code === "40900" || /queue_changed_or_invalid_order|40900/.test(err.message);
    assert.ok(matched, `Expected 40900 or queue_changed_or_invalid_order, got: ${err.code} ${err.message}`);
    return true;
  },
  "Reorder with incomplete array must fail with 40900"
);

console.log("3. Test set_personal_reading_goal with non-existent random p_id -> expects P0002");
const nonExistentGoalId = "99999999-9999-4999-a999-999999999999";
await assert.rejects(
  async () => {
    await db.query(`
      SELECT public.set_personal_reading_goal(
        $1, 'Meta Inexistente', 2026, 10, null, null, null
      );
    `, [nonExistentGoalId]);
  },
  (err) => {
    const matched = err.code === "P0002" || /not_found|P0002/.test(err.message);
    assert.ok(matched, `Expected P0002 or not_found, got: ${err.code} ${err.message}`);
    return true;
  },
  "Updating non-existent goal must raise P0002 (no phantom inserts)"
);

console.log("4. Test set_personal_reading_goal with archived goal -> expects 40900");
// Create valid goal with null p_id
const createdGoalRes = await db.query(`
  SELECT public.set_personal_reading_goal(
    null, 'Meta Ativa', 2026, 12, null, null, null
  ) as goal;
`);
const rawGoal = createdGoalRes.rows[0].goal;
const activeGoal = typeof rawGoal === "string" ? JSON.parse(rawGoal) : rawGoal;
assert.ok(activeGoal.id, "Active goal must be created");

// Archive the goal
await db.query(`SELECT public.archive_personal_reading_goal($1, $2);`, [activeGoal.id, activeGoal.version]);

// Try to modify the archived goal
await assert.rejects(
  async () => {
    await db.query(`
      SELECT public.set_personal_reading_goal(
        $1, 'Meta Modificada', 2026, 15, null, null, $2
      );
    `, [activeGoal.id, Number(activeGoal.version) + 1]);
  },
  (err) => {
    const matched = err.code === "40900" || /goal_archived|40900/.test(err.message);
    assert.ok(matched, `Expected 40900 or goal_archived, got: ${err.code} ${err.message}`);
    return true;
  },
  "Updating archived goal must raise 40900 (goal_archived)"
);

console.log("5. Test valid reorder_up_next exact permutation");
const reorderRes = await db.query(`
  SELECT public.reorder_up_next(ARRAY[$1, $2, $3]::uuid[]);
`, [book3, book1, book2]);
assert.equal(reorderRes.rows[0].reorder_up_next, true);

const orderCheck = await db.query(`
  SELECT book_id, position FROM public.user_up_next
  WHERE user_id = $1 ORDER BY position ASC;
`, [userA]);
assert.deepEqual(
  orderCheck.rows.map(r => ({ book: r.book_id, pos: r.position })),
  [
    { book: book3, pos: 1 },
    { book: book1, pos: 2 },
    { book: book2, pos: 3 },
  ]
);

console.log("6. Test remove_from_up_next_atomic with position compacting");
const removeRes = await db.query(`
  SELECT public.remove_from_up_next_atomic($1);
`, [book1]); // remove middle item (pos 2)
assert.equal(removeRes.rows[0].remove_from_up_next_atomic, true);

const orderAfterRemove = await db.query(`
  SELECT book_id, position FROM public.user_up_next
  WHERE user_id = $1 ORDER BY position ASC;
`, [userA]);
assert.deepEqual(
  orderAfterRemove.rows.map(r => ({ book: r.book_id, pos: r.position })),
  [
    { book: book3, pos: 1 },
    { book: book2, pos: 2 },
  ],
  "Position must be compacted sequentially after atomic removal"
);

console.log("7. Test year immutability on goal edit -> expects 22023");
// Create a new goal for 2026
const newGoalRes = await db.query(`
  SELECT public.set_personal_reading_goal(
    null, 'Meta 2026', 2026, 10, null, null, null
  ) as goal;
`);
const newGoal = typeof newGoalRes.rows[0].goal === "string" ? JSON.parse(newGoalRes.rows[0].goal) : newGoalRes.rows[0].goal;

await assert.rejects(
  async () => {
    await db.query(`
      SELECT public.set_personal_reading_goal(
        $1, 'Tentando Mudar Ano', 2027, 10, null, null, $2
      );
    `, [newGoal.id, newGoal.version]);
  },
  (err) => {
    const matched = err.code === "22023" || /goal_year_is_immutable|22023/.test(err.message);
    assert.ok(matched, `Expected 22023 or goal_year_is_immutable, got: ${err.code} ${err.message}`);
    return true;
  },
  "Changing goal year must be rejected with 22023"
);

console.log("8. Test invalid target < 1 -> expects 22023");
await assert.rejects(
  async () => {
    await db.query(`
      SELECT public.set_personal_reading_goal(
        null, 'Meta Zero', 2026, 0, null, null, null
      );
    `);
  },
  (err) => {
    const matched = err.code === "22023" || /invalid_target|22023/.test(err.message);
    assert.ok(matched, `Expected 22023 or invalid_target, got: ${err.code} ${err.message}`);
    return true;
  },
  "Target books < 1 must be rejected with 22023"
);

console.log("ALL UP_NEXT AND GOALS STRICT TESTS PASSED!");
