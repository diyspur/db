#!/usr/bin/env node

/**
 * Runner de testes Node.js para os módulos das Supabase Edge Functions (Deno).
 * Executa tanto `auth.test.ts` quanto `observability.test.ts` sem depender da CLI `deno`.
 */

import { register } from "node:module";

// 1. Registra hook do ESM loader para interceptar esquemas `npm:` do Deno e imports do deno.json
const loaderCode = `
export async function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith("npm:")) {
    const mockModule = [
      "export function init() {}",
      "export function setTag() {}",
      "export function withScope(cb) { cb({ setTag() {} }); }",
      "export function captureException() {}",
      "export function captureMessage() {}",
      "export async function flush() {}",
    ].join("\\n");

    return {
      format: "module",
      shortCircuit: true,
      url: "data:text/javascript," + encodeURIComponent(mockModule),
    };
  }

  if (specifier === "@supabase/supabase-js") {
    const mockModule = [
      "export function createClient() {",
      "  return {",
      "    auth: { getUser: async () => ({ data: { user: null }, error: null }) },",
      "    from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: null }) }) }) })",
      "  };",
      "}",
    ].join("\\n");

    return {
      format: "module",
      shortCircuit: true,
      url: "data:text/javascript," + encodeURIComponent(mockModule),
    };
  }

  return nextResolve(specifier, context);
}
`;

register("data:text/javascript," + encodeURIComponent(loaderCode));

// 2. Polyfill para globalThis.Deno
const envStore = new Map();

const tests = [];

globalThis.Deno = {
  env: {
    get(key) {
      if (envStore.has(key)) return envStore.get(key);
      return process.env[key];
    },
    set(key, value) {
      envStore.set(key, value);
    },
    delete(key) {
      envStore.delete(key);
    },
  },
  test(name, fn) {
    tests.push({ name, fn });
  },
};

// 3. Importa os módulos de teste
await import("../supabase/functions/_shared/auth.test.ts");
await import("../supabase/functions/_shared/observability.test.ts");

console.log(`\n🚀 Executando ${tests.length} testes unitários das Edge Functions (Node runner)...\n`);

let passed = 0;
let failed = 0;

for (const { name, fn } of tests) {
  try {
    await fn();
    console.log(`  ✅ PASS: ${name}`);
    passed++;
  } catch (err) {
    console.error(`  ❌ FAIL: ${name}`);
    console.error(err);
    failed++;
  }
}

console.log(`\n------------------------------------------------------------`);
console.log(`Testes concluídos: ${passed} passaram, ${failed} falharam, total ${tests.length}`);
console.log(`------------------------------------------------------------\n`);

if (failed > 0) {
  process.exit(1);
} else {
  process.exit(0);
}
