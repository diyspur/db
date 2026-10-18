#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_PROJECT_REF:?Set SUPABASE_PROJECT_REF before deployment}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMPORT_MAP="$ROOT_DIR/supabase/functions/deno.json"

SUPABASE_BIN="npx supabase"

# User functions keep JWT verification; service/webhook functions authenticate themselves.
for fn in quiz-validate award-xp vote-next-book ai-recommendations ai-user-embeddings match-readers social-render-card newsletter-dispatch generate-book-embeddings; do
  echo "Deploying $fn..."
  $SUPABASE_BIN functions deploy "$fn" --import-map "$IMPORT_MAP" --project-ref "$SUPABASE_PROJECT_REF"
done

for fn in scheduled-reminders stripe-webhook community-notification-worker; do
  echo "Deploying $fn (--no-verify-jwt)..."
  $SUPABASE_BIN functions deploy "$fn" --no-verify-jwt --import-map "$IMPORT_MAP" --project-ref "$SUPABASE_PROJECT_REF"
done
