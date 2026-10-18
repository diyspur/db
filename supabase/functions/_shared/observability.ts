import * as Sentry from "npm:@sentry/deno@11.6.0";

export type LogLevel = "info" | "error";

export interface LogEdgeFields {
  service?: string;
  environment?: string;
  request_id?: string;
  requestId?: string;
  functionName?: string;
  edge_function?: string;
  error?: unknown;
  [key: string]: unknown;
}

const MAX_STRING_LENGTH = 250;
const MAX_RECURSION_DEPTH = 12;

const BEARER_REGEX = /\bBearer\s+[A-Za-z0-9\-._~+/]+=*/gi;
const JWT_REGEX = /\beyJ[A-Za-z0-9-_]+\.eyJ[A-Za-z0-9-_]+\.[A-Za-z0-9-_]+\b/g;
const CREDIT_CARD_REGEX = /\b(?:\d{4}[ -]){3}\d{4}\b|\b\d{4}[ -]\d{6}[ -]\d{5}\b|\b\d{13,19}\b/g;
const CPF_FORMATTED_REGEX = /\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/g;
const EMAIL_REGEX = /\b([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})\b/g;
const QUERY_PARAM_SECRET_REGEX = /([?&][^=&#\s]*(?:token|auth|key|secret|password|senha|code|credential|signature|session|cartao)[^=&#\s]*=)[^&#\s]+/gi;
const URI_CREDENTIALS_REGEX = /(:\/\/[^/@\s]*:)([^@\s]+)(@)/gi;

export function getEnv(key: string): string | undefined {
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

export function isSensitiveKey(key: string): boolean {
  if (!key || typeof key !== "string") return false;

  const normalized = key
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[-_]/g, "");

  // Exceção de domínio: autores de livros no clube de leitura não são credenciais
  if (
    normalized.includes("author") &&
    !normalized.includes("authorize") &&
    !normalized.includes("authorization")
  ) {
    return false;
  }

  return (
    normalized.includes("password") ||
    normalized.includes("senha") ||
    normalized.includes("secret") ||
    normalized.includes("token") ||
    normalized.includes("apikey") ||
    normalized.includes("creditcard") ||
    normalized.includes("cardnumber") ||
    normalized.includes("cartao") ||
    normalized.includes("cvv") ||
    normalized.includes("cvc") ||
    normalized.includes("cpf") ||
    normalized === "auth" ||
    normalized.includes("authorization") ||
    normalized.includes("cookie") ||
    normalized.includes("credential") ||
    normalized.includes("privatekey")
  );
}

export function maskEmail(email: string): string {
  return email.replace(EMAIL_REGEX, (_match, local: string, domain: string) => {
    const firstChar = local[0] || "u";
    const domainParts = domain.split(".");
    if (domainParts.length >= 2) {
      const suffix = domainParts.slice(1).join(".");
      return `${firstChar}***@***.${suffix}`;
    }
    return `${firstChar}***@***`;
  });
}

function isSensitiveQueryParam(param: string): boolean {
  const norm = param
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[-_]/g, "");

  return (
    norm.includes("token") ||
    norm.includes("secret") ||
    norm.includes("auth") ||
    norm.includes("password") ||
    norm.includes("senha") ||
    norm.includes("key") ||
    norm.includes("code") ||
    norm.includes("credential") ||
    norm.includes("signature") ||
    norm.includes("session") ||
    norm.includes("cartao")
  );
}

function sanitizeUrlString(value: string): string {
  if (!value.includes("?")) return value;

  try {
    const isAbsolute = value.startsWith("http://") || value.startsWith("https://");
    const parsed = new URL(value, "http://localhost");
    let modified = false;

    for (const key of Array.from(parsed.searchParams.keys())) {
      if (isSensitiveQueryParam(key)) {
        parsed.searchParams.set(key, "[REDACTED]");
        modified = true;
      }
    }

    if (modified) {
      if (isAbsolute) {
        return parsed.toString();
      }
      return parsed.pathname + parsed.search + parsed.hash;
    }
  } catch {
    return value.replace(QUERY_PARAM_SECRET_REGEX, "$1%5BREDACTED%5D");
  }

  return value;
}

export function redactPiiText(text: string): string {
  if (!text || typeof text !== "string") return text;

  let result = text;
  result = result.replace(JWT_REGEX, "[REDACTED]");
  result = result.replace(BEARER_REGEX, "Bearer [REDACTED]");
  result = result.replace(CREDIT_CARD_REGEX, "[REDACTED]");
  result = result.replace(CPF_FORMATTED_REGEX, "[REDACTED]");
  result = maskEmail(result);
  result = result.replace(URI_CREDENTIALS_REGEX, "$1[REDACTED]$3");
  result = sanitizeUrlString(result);
  return result;
}

export function sanitizeString(str: string, maxLength = MAX_STRING_LENGTH): string {
  let result = redactPiiText(str);
  if (result.length > maxLength) {
    result = result.slice(0, maxLength);
  }
  return result;
}

function sanitizeInternal<T>(input: T, seen: WeakSet<object>, depth: number, maxLength: number): T {
  if (depth > MAX_RECURSION_DEPTH) {
    return "[MAX_DEPTH_EXCEEDED]" as unknown as T;
  }
  if (input === null || input === undefined) {
    return input;
  }
  if (typeof input === "string") {
    return sanitizeString(input, maxLength) as unknown as T;
  }
  if (typeof input === "number" || typeof input === "boolean" || typeof input === "bigint") {
    return input;
  }
  if (input instanceof Error) {
    return sanitizeError(input) as unknown as T;
  }
  if (input instanceof Date) {
    return new Date(input.getTime()) as unknown as T;
  }
  if (input instanceof RegExp) {
    return input;
  }
  if (typeof input === "object") {
    if (seen.has(input)) {
      return "[CIRCULAR]" as unknown as T;
    }
    seen.add(input);

    if (Array.isArray(input)) {
      return input.map((item) => sanitizeInternal(item, seen, depth + 1, maxLength)) as unknown as T;
    }

    const output: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(input)) {
      if (isSensitiveKey(key)) {
        output[key] = "[REDACTED]";
      } else {
        output[key] = sanitizeInternal(value, seen, depth + 1, maxLength);
      }
    }
    return output as T;
  }
  return input;
}

export function sanitizePayload<T>(input: T, maxLength = MAX_STRING_LENGTH): T {
  try {
    const seen = new WeakSet<object>();
    return sanitizeInternal(input, seen, 0, maxLength);
  } catch {
    if (typeof input === "string") return "[UNSANITIZED_DATA]" as unknown as T;
    if (Array.isArray(input)) return ["[UNSANITIZED_DATA]"] as unknown as T;
    if (typeof input === "object" && input !== null) {
      return { unredacted: "[UNSANITIZED_DATA]" } as unknown as T;
    }
    return "[UNSANITIZED_DATA]" as unknown as T;
  }
}

export function sanitizeError(error: unknown): Record<string, unknown> {
  try {
    if (error === null || error === undefined) {
      return { message: "Unknown error" };
    }
    if (error instanceof Error) {
      const sanitized: Record<string, unknown> = {
        name: error.name || "Error",
        message: sanitizeString(error.message || ""),
      };
      if (error.stack) {
        sanitized.stack = redactPiiText(error.stack);
      }
      if (error.cause) {
        sanitized.cause = sanitizePayload(error.cause);
      }
      for (const [key, val] of Object.entries(error)) {
        if (key === "name" || key === "message" || key === "stack" || key === "cause") {
          continue;
        }
        if (isSensitiveKey(key)) {
          sanitized[key] = "[REDACTED]";
        } else {
          sanitized[key] = sanitizePayload(val);
        }
      }
      return sanitized;
    }
    if (typeof error === "string") {
      return { message: sanitizeString(error) };
    }
    if (typeof error === "object") {
      return sanitizePayload(error as Record<string, unknown>);
    }
    return { message: String(error) };
  } catch {
    return { message: "Error sanitization failed" };
  }
}

let initialized = false;

export function initFunctionObservability(functionName: string): void {
  const dsn = getEnv("SENTRY_DSN");
  const environment = getEnv("SENTRY_ENVIRONMENT") ?? getEnv("ENVIRONMENT") ?? "production";
  if (!dsn || initialized) return;

  try {
    if (typeof Sentry?.init === "function") {
      Sentry.init({
        dsn,
        environment,
        sendDefaultPii: false,
        tracesSampleRate: 0,
      });
    }
    if (typeof Sentry?.setTag === "function") {
      Sentry.setTag("service", "supabase-edge");
      Sentry.setTag("edge_function", functionName);
    }
    initialized = true;
  } catch {
    // Fail-safe
  }
}

export async function captureFunctionException(
  error: unknown,
  functionName: string,
  requestId: string,
): Promise<void> {
  const dsn = getEnv("SENTRY_DSN");
  if (!dsn) return; // logs nativos Supabase continuam disponíveis.

  try {
    initFunctionObservability(functionName);
    if (typeof Sentry?.withScope === "function") {
      Sentry.withScope((scope) => {
        if (typeof scope?.setTag === "function") {
          scope.setTag("service", "supabase-edge");
          scope.setTag("edge_function", functionName);
          scope.setTag("request_id", requestId);
        }
        if (typeof Sentry?.captureException === "function") {
          Sentry.captureException(error);
        }
      });
    } else if (typeof Sentry?.captureException === "function") {
      Sentry.captureException(error);
    }
  } catch {
    // Fail-safe
  }

  try {
    if (typeof Sentry?.flush === "function") {
      await Sentry.flush(1500);
    }
  } catch {
    // Flush timeout ou erro de rede não deve impedir o envio da resposta.
  }
}

export function logEdge(
  level: LogLevel,
  event: string,
  fields?: Record<string, unknown>,
): void {
  try {
    const service = (fields?.service as string) ?? "supabase-edge";
    const environment =
      (fields?.environment as string) ??
      getEnv("SENTRY_ENVIRONMENT") ??
      getEnv("ENVIRONMENT") ??
      "production";

    const logRecord: Record<string, unknown> = {
      timestamp: new Date().toISOString(),
      level,
      event: sanitizeString(event),
      service: sanitizeString(service),
      environment: sanitizeString(environment),
    };

    const requestId = fields?.request_id ?? fields?.requestId;
    if (requestId !== undefined && requestId !== null) {
      logRecord.request_id = sanitizePayload(requestId);
    }

    if (fields) {
      for (const [key, value] of Object.entries(fields)) {
        if (
          key === "service" ||
          key === "environment" ||
          key === "request_id" ||
          key === "requestId" ||
          key === "level" ||
          key === "event" ||
          key === "timestamp"
        ) {
          continue;
        }

        if (key === "error") {
          logRecord.error = sanitizeError(value);
          continue;
        }

        if (isSensitiveKey(key)) {
          logRecord[key] = "[REDACTED]";
        } else {
          logRecord[key] = sanitizePayload(value);
        }
      }
    }

    const jsonLine = JSON.stringify(logRecord);
    if (level === "error") {
      console.error(jsonLine);
    } else {
      console.info(jsonLine);
    }
  } catch {
    try {
      console.error(JSON.stringify({ level: "error", event: "log_edge_failed" }));
    } catch {
      // noop
    }
  }
}

export function logEdgeInfo(
  event: string,
  fields?: Record<string, unknown>,
): void {
  logEdge("info", event, fields);
}

export function logEdgeError(
  event: string,
  error: unknown,
  fields?: Record<string, unknown>,
): void {
  try {
    const fnName =
      (fields?.edge_function as string) ||
      (fields?.function as string) ||
      (fields?.functionName as string) ||
      "supabase-edge";
    const reqId =
      (fields?.request_id as string) ||
      (fields?.requestId as string) ||
      "";

    // Dispara Sentry capture de forma não-bloqueante
    captureFunctionException(error, fnName, reqId).catch(() => {});

    logEdge("error", event, {
      ...fields,
      error,
    });
  } catch {
    try {
      console.error(JSON.stringify({ level: "error", event: "log_edge_error_failed" }));
    } catch {
      // noop
    }
  }
}
