import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "../../src/lib/supabase/database.types.ts";

const PRODUCTION_PROJECT_REF = "xjhehhfhhoomblcggjpk";
const required = (name: string): string => {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const url = required("SUPABASE_URL");
const publishableKey = required("SUPABASE_PUBLISHABLE_KEY");
const serviceRoleKey = required("SUPABASE_SERVICE_ROLE_KEY");
const projectRef = new URL(url).hostname.split(".")[0];
const declaredTestRef = required("SUPABASE_TEST_PROJECT_REF");

if (projectRef === PRODUCTION_PROJECT_REF) {
  throw new Error(
    "Refusing to run mutating integration tests against the production project.",
  );
}
if (projectRef !== declaredTestRef) {
  throw new Error(
    "SUPABASE_TEST_PROJECT_REF must match the project reference in SUPABASE_URL.",
  );
}
if (Deno.env.get("SUPABASE_TEST_ALLOW_MUTATIONS") !== "true") {
  throw new Error(
    "Set SUPABASE_TEST_ALLOW_MUTATIONS=true only after verifying this is a disposable isolated project.",
  );
}

const admin = createClient<Database>(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const nonce = crypto.randomUUID().replaceAll("-", "").slice(0, 12).toLowerCase();
const password = `T3st-${crypto.randomUUID()}-Aa!`;
const createdUserIds: string[] = [];

try {
  const { data: userA, error: errA } = await admin.auth.admin.createUser({
    email: `comm-a-${nonce}@example.com`,
    password,
    email_confirm: true,
    user_metadata: {
      username: `comm_a_${nonce}`,
      display_name: `Community A ${nonce}`,
    },
  });
  if (errA || !userA.user) throw errA ?? new Error("Failed to create user A");
  createdUserIds.push(userA.user.id);

  const { data: userB, error: errB } = await admin.auth.admin.createUser({
    email: `comm-b-${nonce}@example.com`,
    password,
    email_confirm: true,
    user_metadata: {
      username: `comm_b_${nonce}`,
      display_name: `Community B ${nonce}`,
    },
  });
  if (errB || !userB.user) throw errB ?? new Error("Failed to create user B");
  createdUserIds.push(userB.user.id);

  const clientA = createClient<Database>(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const clientB = createClient<Database>(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  await clientA.auth.signInWithPassword({
    email: `comm-a-${nonce}@example.com`,
    password,
  });
  await clientB.auth.signInWithPassword({
    email: `comm-b-${nonce}@example.com`,
    password,
  });

  const { data: books } = await admin.from("books").select("id").limit(1);
  assert.ok(books && books.length > 0, "Expected at least one book in staging");
  const bookId = books[0].id;

  const { data: groupA, error: gErrA } = await clientA.rpc(
    "ensure_official_book_group",
    { p_book: bookId },
  );
  if (gErrA) throw gErrA;
  const { data: groupB, error: gErrB } = await clientB.rpc(
    "ensure_official_book_group",
    { p_book: bookId },
  );
  if (gErrB) throw gErrB;

  const rowA = Array.isArray(groupA) ? groupA[0] : groupA;
  const rowB = Array.isArray(groupB) ? groupB[0] : groupB;
  assert.equal(rowA?.club_id, rowB?.club_id, "Official group must be unique");

  const { data: directory } = await clientA.rpc("get_club_channel_directory", {
    p_club: rowA.club_id,
  });
  const noSpoilerChannel = (directory ?? []).find(
    (ch: { slug: string }) => ch.slug === "sem-spoilers",
  );
  assert.ok(noSpoilerChannel, "Default no-spoilers channel must exist");

  const clientMessageId = crypto.randomUUID();
  const { data: sent, error: sendErr } = await clientA.rpc(
    "send_club_message",
    {
      p_channel: noSpoilerChannel.id,
      p_client_message_id: clientMessageId,
      p_content: `Olá @comm_b_${nonce}, testando outbox!`,
    },
  );
  if (sendErr) throw sendErr;
  assert.ok(sent, "Message must be sent");

  const { data: processed, error: outboxErr } = await admin.rpc(
    "process_community_notification_outbox",
    { p_batch_size: 50 },
  );
  if (outboxErr) throw outboxErr;
  assert.ok(Number(processed ?? 0) >= 1, "Outbox worker must process message");

  const { data: notifsB } = await clientB
    .from("notifications")
    .select("id,kind,payload,read_at")
    .order("created_at", { ascending: false })
    .limit(5);
  assert.ok((notifsB ?? []).length >= 1, "User B must receive mention notification");

  const firstId = notifsB![0].id;
  const { data: marked1, error: markErr1 } = await clientB.rpc(
    "mark_my_notifications_read",
    { p_ids: [firstId] },
  );
  if (markErr1) throw markErr1;
  assert.equal(marked1, 1);

  const { data: marked2, error: markErr2 } = await clientB.rpc(
    "mark_my_notifications_read",
    { p_ids: [firstId] },
  );
  if (markErr2) throw markErr2;
  assert.equal(marked2, 0, "Idempotent replay must return 0 without failing");

  console.log("PASS: community-notifications integration smoke test");
} finally {
  for (const uid of createdUserIds) {
    await admin.auth.admin.deleteUser(uid).catch(() => undefined);
  }
}
