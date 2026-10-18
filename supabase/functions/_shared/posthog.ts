import { isSensitiveKey, sanitizePayload } from "./observability.ts";

function getEnv(key: string): string | undefined {
  if (typeof Deno !== "undefined" && typeof Deno.env?.get === "function") {
    try {
      return Deno.env.get(key);
    } catch {
      return undefined;
    }
  }
  if (typeof process !== "undefined" && process.env) {
    return process.env[key];
  }
  return undefined;
}

export const POSTHOG_MAX_STRING_LENGTH = 100;
export const POSTHOG_TIMEOUT_MS = 1500;

/**
 * Sanitiza propriedades analíticas para envio ao PostHog:
 * - Redige chaves sensíveis e PII (senhas, tokens, emails, CPFs, cartões).
 * - Trunca todas as strings a no máximo 100 caracteres.
 */
export function sanitizePostHogProperties(
  props: Record<string, unknown> = {},
): Record<string, unknown> {
  if (!props || typeof props !== "object") return {};

  const sanitized: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(props)) {
    if (isSensitiveKey(key)) {
      sanitized[key] = "[REDACTED]";
    } else {
      sanitized[key] = sanitizePayload(value, POSTHOG_MAX_STRING_LENGTH);
    }
  }
  return sanitized;
}

/**
 * Captura analítica server-side mínima para eventos de negócio confirmados.
 * Não bloqueia a resposta nem registra dados pessoais sensíveis.
 * Timeout seguro de no máximo 1500ms via AbortController.
 */
export async function captureServerEvent(
  distinctId: string,
  event: string,
  properties: Record<string, unknown> = {},
): Promise<void> {
  const host = getEnv("POSTHOG_HOST") ?? "https://us.i.posthog.com";
  const token = getEnv("POSTHOG_PROJECT_TOKEN") ?? getEnv("NEXT_PUBLIC_POSTHOG_KEY");

  if (!token) return;

  const sanitizedProperties = sanitizePostHogProperties(properties);

  const controller = new AbortController();
  const timeoutId = setTimeout(() => {
    try {
      controller.abort();
    } catch {
      // noop
    }
  }, POSTHOG_TIMEOUT_MS);

  try {
    await fetch(`${host.replace(/\/$/, "")}/capture/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        api_key: token,
        event: typeof event === "string" ? event.slice(0, POSTHOG_MAX_STRING_LENGTH) : String(event),
        distinct_id: distinctId,
        properties: {
          ...sanitizedProperties,
          $lib: "supabase-edge-function",
        },
      }),
    });
  } catch {
    // Telemetria nunca interrompe a execução de negócio
  } finally {
    clearTimeout(timeoutId);
  }
}
