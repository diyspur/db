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
GRANT USAGE ON SCHEMA private TO service_role;

-- 9 private tables:
CREATE TABLE private.quiz_rate_limits (
  user_id uuid NOT NULL,
  chapter_id uuid NOT NULL,
  window_started_at timestamptz NOT NULL,
  attempts integer NOT NULL,
  PRIMARY KEY (user_id, chapter_id)
);

CREATE TABLE private.sent_reminders (
  user_id uuid NOT NULL,
  meeting_id uuid NOT NULL,
  reminder_window text NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, meeting_id, reminder_window)
);

CREATE TABLE private.newsletter_dispatch_runs (
  issue_id uuid NOT NULL,
  audience_key text NOT NULL,
  started_at timestamptz NOT NULL,
  completed_at timestamptz,
  PRIMARY KEY (issue_id, audience_key)
);

CREATE TABLE private.stripe_customers (
  customer_id text PRIMARY KEY,
  user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.rate_limits (
  user_id uuid NOT NULL,
  bucket text NOT NULL,
  window_started_at timestamptz NOT NULL,
  request_count integer NOT NULL,
  PRIMARY KEY (user_id, bucket)
);

CREATE TABLE private.book_reading_requests (
  user_id uuid NOT NULL,
  request_id uuid NOT NULL,
  book_id uuid NOT NULL,
  status text NOT NULL,
  resulting_version bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, request_id)
);

CREATE TABLE private.meeting_operation_requests (
  actor_id uuid NOT NULL,
  operation text NOT NULL,
  request_id uuid NOT NULL,
  payload_hash text NOT NULL,
  meeting_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_id, operation, request_id)
);

CREATE TABLE private.community_notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_key text NOT NULL UNIQUE,
  event_type text NOT NULL,
  entity_id uuid NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.book_share_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id uuid NOT NULL,
  sender_user_id uuid NOT NULL,
  recipient_email text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Mock RPC get_club_channel_directory
CREATE FUNCTION public.get_club_channel_directory(p_club uuid)
RETURNS TABLE (id uuid, name text)
LANGUAGE sql
AS $$ SELECT gen_random_uuid(), 'canal-teste'::text; $$;
REVOKE ALL ON FUNCTION public.get_club_channel_directory(uuid) FROM PUBLIC, anon;
`;

await db.exec(bootstrap);

// Apply migration 20261018001000_enable_rls_on_private_tables.sql
const sql = await readFile(resolve(repoRoot, "supabase/migrations/20261018001000_enable_rls_on_private_tables.sql"), "utf8");
await db.exec(sql);
console.log("PASS: applied 20261018001000_enable_rls_on_private_tables.sql");

// Check RLS on all 9 tables
const rlsResult = await db.query(`
  SELECT c.relname, c.relrowsecurity
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'private'
    AND c.relkind = 'r'
    AND c.relname IN (
      'quiz_rate_limits',
      'sent_reminders',
      'newsletter_dispatch_runs',
      'stripe_customers',
      'rate_limits',
      'book_reading_requests',
      'meeting_operation_requests',
      'community_notification_outbox',
      'book_share_invitations'
    )
`);

assert.equal(rlsResult.rows.length, 9, "All 9 tables exist in private schema");
for (const row of rlsResult.rows) {
  assert.equal(row.relrowsecurity, true, `private.${row.relname} has RLS enabled`);
}
console.log("PASS: All 9 private tables have row level security enabled");

// Check service_role policies exist
const policyResult = await db.query(`
  SELECT tablename, policyname
  FROM pg_policies
  WHERE schemaname = 'private'
    AND policyname = 'service_role_all'
`);
assert.equal(policyResult.rows.length, 9, "All 9 private tables have service_role_all policy");
console.log("PASS: All 9 private tables have service_role_all policies");

// Check anon permission on get_club_channel_directory
const anonPriv = await db.query(`
  SELECT has_function_privilege('anon', p.oid, 'EXECUTE') AS can_exec
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_club_channel_directory'
`);
assert.equal(anonPriv.rows[0].can_exec, true, "anon role has execute privilege on get_club_channel_directory");
console.log("PASS: anon can execute get_club_channel_directory for public club channel listings");

await db.close();
console.log("ALL PRIVATE SCHEMA RLS ASSERTIONS PASSED!");
