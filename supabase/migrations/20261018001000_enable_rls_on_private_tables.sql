-- Migration: 20261018001000_enable_rls_on_private_tables.sql
-- Description: Enable RLS on 9 private schema tables with service_role policies and grant get_club_channel_directory to anon

-- 1. Habilitar RLS de forma idempotente e segura nas 9 tabelas do schema private
DO $$
DECLARE
  v_tbl text;
  v_tables text[] := ARRAY[
    'quiz_rate_limits',
    'sent_reminders',
    'newsletter_dispatch_runs',
    'stripe_customers',
    'rate_limits',
    'book_reading_requests',
    'meeting_operation_requests',
    'community_notification_outbox',
    'book_share_invitations'
  ];
BEGIN
  FOREACH v_tbl IN ARRAY v_tables
  LOOP
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'private' AND tablename = v_tbl) THEN
      EXECUTE format('ALTER TABLE private.%I ENABLE ROW LEVEL SECURITY;', v_tbl);

      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'private' AND tablename = v_tbl AND policyname = 'service_role_all'
      ) THEN
        EXECUTE format('CREATE POLICY service_role_all ON private.%I FOR ALL TO service_role USING (true) WITH CHECK (true);', v_tbl);
      END IF;
    END IF;
  END LOOP;
END $$;

-- 2. Conceder permissao de execucao ao role anon para leitura publica do diretorio de canais (sem expor mensagens)
GRANT EXECUTE ON FUNCTION public.get_club_channel_directory(uuid) TO anon;
