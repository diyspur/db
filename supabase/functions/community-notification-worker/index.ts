import { constantTimeEqual, json, serviceClient } from "../_shared/auth.ts";
import { captureFunctionException } from "../_shared/observability.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const requestId = crypto.randomUUID();
  const expected =
    Deno.env.get("COMMUNITY_NOTIFICATIONS_SECRET") ??
    Deno.env.get("SCHEDULED_REMINDERS_SECRET");
  const actual =
    req.headers.get("x-community-notifications-secret") ??
    req.headers.get("x-scheduled-reminders-secret") ??
    "";

  if (!expected || !constantTimeEqual(actual, expected)) {
    return json({ error: "unauthorized" }, 401);
  }

  try {
    const body = await req.json().catch(() => ({}));
    const batchSize =
      typeof body?.batch_size === "number" &&
        Number.isInteger(body.batch_size) &&
        body.batch_size >= 1 &&
        body.batch_size <= 200
        ? body.batch_size
        : 50;
    const refreshStats = body?.refresh_stats === true;

    const service = serviceClient();
    const { data: processed, error } = await service.rpc(
      "process_community_notification_outbox",
      { p_batch_size: batchSize },
    );
    if (error) throw error;

    if (refreshStats) {
      const { error: statsError } = await service.rpc(
        "refresh_book_reading_stats",
      );
      if (statsError) {
        console.error(
          "community-notification-worker: refresh_book_reading_stats failed",
          statsError.message,
        );
      }
    }

    return json({
      ok: true,
      processed: typeof processed === "number" ? processed : 0,
      refreshed_stats: refreshStats,
    });
  } catch (error) {
    await captureFunctionException(
      error,
      "community-notification-worker",
      requestId,
    );
    console.error(
      JSON.stringify({
        level: "error",
        service: "supabase-edge",
        function: "community-notification-worker",
        request_id: requestId,
        code: "unhandled_execution_failure",
        error: error instanceof Error ? error.message : "unknown",
      }),
    );
    return json({ error: "temporarily_unavailable" }, 503);
  }
});
