import {
  logEdge,
  logEdgeInfo,
  logEdgeError,
  initFunctionObservability,
  captureFunctionException,
  isSensitiveKey,
  maskEmail,
  redactPiiText,
  sanitizeString,
  sanitizePayload,
  sanitizeError,
} from "./observability.ts";
import {
  sanitizePostHogProperties,
  captureServerEvent,
  POSTHOG_MAX_STRING_LENGTH,
} from "./posthog.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(`Assertion failed: ${message}`);
  }
}

function assertEquals<T>(actual: T, expected: T, message?: string) {
  if (actual !== expected) {
    throw new Error(
      `Assertion failed${message ? ` (${message})` : ""}: expected ${JSON.stringify(
        expected,
      )}, received ${JSON.stringify(actual)}`,
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Tests for Redaction & Sanitization Helpers
// ---------------------------------------------------------------------------

Deno.test("isSensitiveKey identifies confidential keys and respects domain exceptions", () => {
  // Sensitive keys
  assert(isSensitiveKey("password"), "password should be sensitive");
  assert(isSensitiveKey("senha"), "senha should be sensitive");
  assert(isSensitiveKey("access_token"), "access_token should be sensitive");
  assert(isSensitiveKey("apiKey"), "apiKey should be sensitive");
  assert(isSensitiveKey("client_secret"), "client_secret should be sensitive");
  assert(isSensitiveKey("credit_card"), "credit_card should be sensitive");
  assert(isSensitiveKey("user_cpf"), "user_cpf should be sensitive");
  assert(isSensitiveKey("authorization"), "authorization should be sensitive");
  assert(isSensitiveKey("cookie"), "cookie should be sensitive");

  // Domain exceptions: book authors (safe fields only)
  assertEquals(isSensitiveKey("author"), false, "author is domain concept, not credential");
  assertEquals(isSensitiveKey("author_id"), false, "author_id is not credential");
  assertEquals(isSensitiveKey("book_author"), false, "book_author is not credential");
  assertEquals(isSensitiveKey("author_name"), false, "author_name is not credential");
  assertEquals(isSensitiveKey("authorId"), false, "authorId is not credential");
  assertEquals(isSensitiveKey("authorName"), false, "authorName is not credential");

  // Sensitive terms inside author-prefixed fields must be redacted
  assert(isSensitiveKey("author_token"), "author_token contains sensitive term token");
  assert(isSensitiveKey("author_password"), "author_password contains sensitive term password");
  assert(isSensitiveKey("author_secret"), "author_secret contains sensitive term secret");
  assert(isSensitiveKey("author_key"), "author_key contains sensitive term key");
});

Deno.test("maskEmail masks local part and preserves domain suffix", () => {
  assertEquals(maskEmail("joao.silva@diyspur.com.br"), "j***@***.com.br");
  assertEquals(maskEmail("admin@gmail.com"), "a***@***.com");
  assertEquals(maskEmail("user@corp.org"), "u***@***.org");
});

Deno.test("redactPiiText scrubs tokens, bearer headers, credit cards, emails, and credentials", () => {
  const bearerSample = "Request with Bearer ya29.a0ARrdaM-fakeTokenValue123456 in header";
  const redactedBearer = redactPiiText(bearerSample);
  assert(!redactedBearer.includes("fakeTokenValue"), "Bearer token must be redacted");
  assert(redactedBearer.includes("Bearer [REDACTED]"), "Bearer header replaced with [REDACTED]");

  const jwtSample = "Token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.doNotLeakSignature123";
  const redactedJwt = redactPiiText(jwtSample);
  assert(!redactedJwt.includes("doNotLeakSignature123"), "JWT must be redacted");
  assert(redactedJwt.includes("[REDACTED]"), "JWT replaced with [REDACTED]");

  const cardSample = "Payment using card 4532 0151 1283 0366 at checkout";
  const redactedCard = redactPiiText(cardSample);
  assert(!redactedCard.includes("4532 0151"), "Credit card must be redacted");
  assert(redactedCard.includes("[REDACTED]"), "Card replaced with [REDACTED]");

  const urlSample = "https://api.diyspur.com/v1/auth?token=super-secret-token&redirect=/books";
  const redactedUrl = redactPiiText(urlSample);
  assert(!redactedUrl.includes("super-secret-token"), "Query string token must be redacted");
});

Deno.test("sanitizeString truncates strings exceeding max length", () => {
  const longText = "a".repeat(300);
  const truncated = sanitizeString(longText, 250);
  assertEquals(truncated.length, 250, "String must be truncated to 250 characters");
});

Deno.test("sanitizePayload redacts sensitive keys and recurses through nested objects and arrays", () => {
  const payload = {
    book_id: "book-123",
    author: "Machado de Assis",
    password: "plain-text-password",
    user_metadata: {
      email: "leitor@diyspur.com.br",
      token: "secret-token",
      tags: ["romance", "Bearer secretToken12345"],
    },
  };

  const sanitized = sanitizePayload(payload) as Record<string, unknown>;
  assertEquals(sanitized.book_id, "book-123");
  assertEquals(sanitized.author, "Machado de Assis");
  assertEquals(sanitized.password, "[REDACTED]");

  const meta = sanitized.user_metadata as Record<string, unknown>;
  assertEquals(meta.token, "[REDACTED]");
  assertEquals(meta.email, "l***@***.com.br");

  const tags = meta.tags as string[];
  assertEquals(tags[0], "romance");
  assertEquals(tags[1], "Bearer [REDACTED]");
});

Deno.test("sanitizePayload converts BigInt to string without throwing on JSON.stringify", () => {
  const payload = {
    numeric_id: 100n,
    total_count: 9007199254740995n,
  };

  const sanitized = sanitizePayload(payload) as Record<string, unknown>;
  assertEquals(sanitized.numeric_id, "100");
  assertEquals(sanitized.total_count, "9007199254740995");

  // Must not throw TypeError: Do not know how to serialize a BigInt
  const json = JSON.stringify(sanitized);
  assert(json.includes('"numeric_id":"100"'), "BigInt was converted to string in json");
});

Deno.test("sanitizePayload handles circular structures safely", () => {
  const circular: Record<string, unknown> = { name: "test" };
  circular.self = circular;

  const result = sanitizePayload(circular) as Record<string, unknown>;
  assertEquals(result.name, "test");
  assertEquals(result.self, "[CIRCULAR]");
});

Deno.test("sanitizeError redacts PII in error messages and stack traces", () => {
  const err = new Error("Failed to authenticate user dev@diyspur.com.br with Bearer secret999");
  const sanitized = sanitizeError(err);

  assertEquals(sanitized.name, "Error");
  assert(!String(sanitized.message).includes("secret999"), "Error message should not leak token");
  assert(String(sanitized.message).includes("d***@***.com.br"), "Email should be masked");
});

// ---------------------------------------------------------------------------
// 2. Tests for logEdge, logEdgeInfo, and logEdgeError
// ---------------------------------------------------------------------------

Deno.test("logEdge outputs valid JSON log line matching frontend contract", () => {
  const originalInfo = console.info;
  let loggedOutput = "";
  console.info = (msg: unknown) => {
    loggedOutput = String(msg);
  };

  try {
    logEdge("info", "book_chapter_completed", {
      request_id: "req-edge-001",
      book_id: "b1",
      chapter_number: 4,
      user_email: "reader@diyspur.com.br",
      token: "leaked_jwt_here",
    });

    assert(loggedOutput.length > 0, "Log line must be emitted");
    const parsed = JSON.parse(loggedOutput);

    assertEquals(parsed.level, "info");
    assertEquals(parsed.event, "book_chapter_completed");
    assertEquals(parsed.service, "supabase-edge");
    assert(parsed.environment !== undefined, "environment should be defined");
    assert(parsed.timestamp !== undefined, "timestamp should be defined");
    assertEquals(parsed.request_id, "req-edge-001");
    assertEquals(parsed.book_id, "b1");
    assertEquals(parsed.chapter_number, 4);
    assertEquals(parsed.user_email, "r***@***.com.br");
    assertEquals(parsed.token, "[REDACTED]");
  } finally {
    console.info = originalInfo;
  }
});

Deno.test("logEdge routes error level to console.error", () => {
  const originalError = console.error;
  let loggedOutput = "";
  console.error = (msg: unknown) => {
    loggedOutput = String(msg);
  };

  try {
    logEdge("error", "database_connection_timeout", {
      requestId: "req-err-999",
      retry_count: 3,
    });

    assert(loggedOutput.length > 0, "Error log line must be emitted");
    const parsed = JSON.parse(loggedOutput);

    assertEquals(parsed.level, "error");
    assertEquals(parsed.event, "database_connection_timeout");
    assertEquals(parsed.service, "supabase-edge");
    assertEquals(parsed.request_id, "req-err-999");
    assertEquals(parsed.retry_count, 3);
  } finally {
    console.error = originalError;
  }
});

Deno.test("logEdgeInfo convenience function calls logEdge with level info", () => {
  const originalInfo = console.info;
  let loggedOutput = "";
  console.info = (msg: unknown) => {
    loggedOutput = String(msg);
  };

  try {
    logEdgeInfo("xp_awarded", {
      request_id: "req-xp-1",
      amount: 50,
      source: "quiz_answer",
    });

    const parsed = JSON.parse(loggedOutput);
    assertEquals(parsed.level, "info");
    assertEquals(parsed.event, "xp_awarded");
    assertEquals(parsed.amount, 50);
  } finally {
    console.info = originalInfo;
  }
});

Deno.test("logEdgeError captures exception and logs structured error payload", () => {
  const originalError = console.error;
  let loggedOutput = "";
  console.error = (msg: unknown) => {
    loggedOutput = String(msg);
  };

  try {
    const error = new Error("Database timeout on RPC award_xp");
    logEdgeError("award_xp_failed", error, {
      edge_function: "award-xp",
      request_id: "req-edge-err-42",
      password: "do-not-log-password",
    });

    assert(loggedOutput.length > 0, "Error log line must be emitted");
    const parsed = JSON.parse(loggedOutput);

    assertEquals(parsed.level, "error");
    assertEquals(parsed.event, "award_xp_failed");
    assertEquals(parsed.service, "supabase-edge");
    assertEquals(parsed.request_id, "req-edge-err-42");
    assertEquals(parsed.password, "[REDACTED]");
    assert(parsed.error !== undefined, "error payload should be attached");
    assertEquals(parsed.error.message, "Database timeout on RPC award_xp");
  } finally {
    console.error = originalError;
  }
});

Deno.test("initFunctionObservability and captureFunctionException handle missing DSN gracefully", async () => {
  // Without SENTRY_DSN, functions should no-op safely without throwing
  initFunctionObservability("award-xp");
  await captureFunctionException(new Error("Test error"), "award-xp", "req-test-123");
});

// ---------------------------------------------------------------------------
// 3. Tests for PostHog Analytics Integration
// ---------------------------------------------------------------------------

Deno.test("sanitizePostHogProperties truncates strings to max 100 chars and filters PII", () => {
  const longValue = "x".repeat(200);
  const input = {
    book_title: "Dom Casmurro",
    description: longValue,
    user_password: "sensitivePassword123",
    client_secret: "secret-key-123",
    email: "reader.vip@diyspur.com.br",
    nested: {
      auth_token: "token123",
      long_comment: "y".repeat(150),
    },
  };

  const sanitized = sanitizePostHogProperties(input);

  assertEquals(sanitized.book_title, "Dom Casmurro");
  assertEquals((sanitized.description as string).length, POSTHOG_MAX_STRING_LENGTH);
  assertEquals(sanitized.user_password, "[REDACTED]");
  assertEquals(sanitized.client_secret, "[REDACTED]");
  assertEquals(sanitized.email, "r***@***.com.br");

  const nested = sanitized.nested as Record<string, unknown>;
  assertEquals(nested.auth_token, "[REDACTED]");
  assertEquals((nested.long_comment as string).length, POSTHOG_MAX_STRING_LENGTH);
});

Deno.test("captureServerEvent exits silently if no token is configured", async () => {
  // Neither POSTHOG_PROJECT_TOKEN nor NEXT_PUBLIC_POSTHOG_KEY is set in raw test env
  await captureServerEvent("user-123", "book_read_finished", {
    book_id: "book-1",
  });
});

Deno.test("captureServerEvent sends sanitized payload and uses AbortController timeout", async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalled = false;
  let receivedUrl = "";
  let receivedPayload: Record<string, unknown> | null = null;
  let hasSignal = false;

  // Mock fetch
  globalThis.fetch = (async (url: string | URL | Request, init?: RequestInit) => {
    fetchCalled = true;
    receivedUrl = String(url);
    receivedPayload = JSON.parse(init?.body as string);
    hasSignal = Boolean(init?.signal);
    return new Response(JSON.stringify({ status: 1 }), { status: 200 });
  }) as typeof fetch;

  // Temporarily set env token
  const previousToken = Deno.env.get("POSTHOG_PROJECT_TOKEN");
  if (typeof Deno.env?.set === "function") {
    Deno.env.set("POSTHOG_PROJECT_TOKEN", "phc_test_token_12345");
  } else if (typeof process !== "undefined" && process.env) {
    process.env.POSTHOG_PROJECT_TOKEN = "phc_test_token_12345";
  }

  try {
    await captureServerEvent("user-test-uuid", "streak_achieved", {
      streak_days: 7,
      password: "plain_password",
      long_text: "z".repeat(180),
    });

    assert(fetchCalled, "fetch must be called when token is present");
    assert(receivedUrl.endsWith("/capture/"), "Endpoint should be /capture/");
    assert(hasSignal, "Request must have an AbortSignal configured");
    assertEquals(receivedPayload?.api_key, "phc_test_token_12345");
    assertEquals(receivedPayload?.event, "streak_achieved");
    assertEquals(receivedPayload?.distinct_id, "user-test-uuid");

    const props = receivedPayload?.properties as Record<string, unknown>;
    assertEquals(props.streak_days, 7);
    assertEquals(props.password, "[REDACTED]");
    assertEquals((props.long_text as string).length, 100);
    assertEquals(props.$lib, "supabase-edge-function");
  } finally {
    globalThis.fetch = originalFetch;
    if (typeof Deno.env?.delete === "function") {
      Deno.env.delete("POSTHOG_PROJECT_TOKEN");
    } else if (typeof process !== "undefined" && process.env) {
      if (previousToken !== undefined) {
        process.env.POSTHOG_PROJECT_TOKEN = previousToken;
      } else {
        delete process.env.POSTHOG_PROJECT_TOKEN;
      }
    }
  }
});

Deno.test("captureServerEvent never throws even if fetch encounters network error or abort", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (() => {
    throw new Error("Simulated network drop / DNS failure");
  }) as unknown as typeof fetch;

  const previousToken = Deno.env.get("POSTHOG_PROJECT_TOKEN");
  if (typeof Deno.env?.set === "function") {
    Deno.env.set("POSTHOG_PROJECT_TOKEN", "phc_test_token_12345");
  } else if (typeof process !== "undefined" && process.env) {
    process.env.POSTHOG_PROJECT_TOKEN = "phc_test_token_12345";
  }

  try {
    // Should complete cleanly without rejecting
    await captureServerEvent("user-abc", "error_resilience_test");
  } finally {
    globalThis.fetch = originalFetch;
    if (typeof Deno.env?.delete === "function") {
      Deno.env.delete("POSTHOG_PROJECT_TOKEN");
    } else if (typeof process !== "undefined" && process.env) {
      if (previousToken !== undefined) {
        process.env.POSTHOG_PROJECT_TOKEN = previousToken;
      } else {
        delete process.env.POSTHOG_PROJECT_TOKEN;
      }
    }
  }
});
