-- Migration: 20261018000100_community_security_release_fix.sql
-- Description: Revoke unlinked club creation, enforce canonical official groups, and harden attendance confirmation

-- 1. Revogar execucao da criacao legada de clubes avulsos sem livro
REVOKE EXECUTE ON FUNCTION public.create_user_club(text, text, boolean, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.create_user_club(text, text, boolean, uuid) FROM PUBLIC, anon, authenticated;

-- 2. Trigger para barrar insercao de clubes que nao sejam oficiais e atrelados a um livro
CREATE OR REPLACE FUNCTION private.require_canonical_new_group()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.kind IS DISTINCT FROM 'official'
     OR NEW.official_book_id IS NULL
     OR NEW.current_book_id IS DISTINCT FROM NEW.official_book_id
     OR NEW.is_private THEN
    RAISE EXCEPTION 'book_required_for_group' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_require_canonical_new_group ON public.user_clubs;
CREATE TRIGGER trg_require_canonical_new_group
BEFORE INSERT ON public.user_clubs
FOR EACH ROW EXECUTE FUNCTION private.require_canonical_new_group();

-- 3. Correcao de seguranca em confirm_meeting_attendance_safe
-- Impede bypass de current_user em funcoes SECURITY DEFINER
CREATE OR REPLACE FUNCTION private.confirm_meeting_attendance_safe(
  p_user uuid,
  p_meeting uuid,
  p_proof_type text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT (
    COALESCE(auth.role() = 'service_role', false)
    OR COALESCE(public.is_admin(), false)
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_proof_type IS NULL OR p_proof_type NOT IN ('moderator', 'replay_confirmation') THEN
    RAISE EXCEPTION 'invalid_attendance_proof' USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.meetings m
    WHERE m.id = p_meeting AND m.status <> 'cancelled'::public.meeting_status
  ) THEN
    RAISE EXCEPTION 'meeting_unavailable' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.meeting_attendance(user_id, meeting_id, proof_type, confirmed_at)
  VALUES (p_user, p_meeting, p_proof_type, now())
  ON CONFLICT (user_id, meeting_id)
  DO UPDATE SET proof_type = EXCLUDED.proof_type, confirmed_at = now();

  PERFORM public.award_xp(p_user, 'join_meeting'::public.xp_source, 30, p_meeting);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_meeting_attendance(
  p_user uuid,
  p_meeting uuid,
  p_proof_type text
) RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.confirm_meeting_attendance_safe(p_user, p_meeting, p_proof_type);
$$;

GRANT EXECUTE ON FUNCTION public.confirm_meeting_attendance(uuid, uuid, text) TO authenticated, service_role;
-- Migration: 20261018000200_book_rankings_and_refresh.sql
-- Description: Aggregate view for book reading audience (reading + read), completed, active, and dropouts (dnf)

CREATE MATERIALIZED VIEW IF NOT EXISTS private.mv_book_reading_stats_v2 AS
SELECT
  b.id AS book_id,
  count(r.user_id) FILTER (WHERE r.first_started_at IS NOT NULL) AS started_readers,
  count(r.user_id) FILTER (WHERE r.status = 'reading') AS active_readers,
  count(r.user_id) FILTER (WHERE r.status = 'read') AS completed_readers,
  count(r.user_id) FILTER (WHERE r.status = 'dnf') AS dnf_readers,
  count(r.user_id) FILTER (WHERE r.status IN ('reading', 'read')) AS reading_audience,
  count(r.user_id) FILTER (WHERE r.status IN ('reading', 'read', 'dnf')) AS participants,
  count(r.user_id) FILTER (WHERE r.first_started_at >= now() - interval '30 days') AS new_readers_30d,
  count(r.user_id) FILTER (WHERE r.status = 'read' AND r.completed_at >= now() - interval '30 days') AS completed_readers_30d,
  now() AS updated_at
FROM public.books b
LEFT JOIN public.user_book_readings r ON r.book_id = b.id
GROUP BY b.id;

CREATE UNIQUE INDEX IF NOT EXISTS mv_book_reading_stats_v2_book_idx
  ON private.mv_book_reading_stats_v2(book_id);

GRANT SELECT ON private.mv_book_reading_stats_v2 TO anon, authenticated, service_role;

DROP VIEW IF EXISTS public.v_book_reading_stats CASCADE;
CREATE OR REPLACE VIEW public.v_book_reading_stats
WITH (security_invoker = true)
AS
SELECT
  s.book_id,
  s.started_readers,
  s.active_readers,
  s.completed_readers,
  s.dnf_readers,
  s.reading_audience,
  s.participants,
  s.new_readers_30d,
  s.completed_readers_30d,
  s.updated_at,
  round(100.0 * s.dnf_readers / nullif(s.participants, 0), 2) AS dnf_rate,
  dense_rank() OVER (ORDER BY s.reading_audience DESC) AS rank_position,
  dense_rank() OVER (ORDER BY s.active_readers DESC) AS active_rank_position,
  dense_rank() OVER (ORDER BY s.completed_readers DESC) AS completed_rank_position,
  dense_rank() OVER (ORDER BY s.dnf_readers DESC) AS dnf_rank_position
FROM private.mv_book_reading_stats_v2 s
JOIN public.books b ON b.id = s.book_id;

GRANT SELECT ON public.v_book_reading_stats TO anon, authenticated, service_role;

-- Funcao atomica de refresh da view de estatisticas
CREATE OR REPLACE FUNCTION private.refresh_book_reading_stats()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtextextended('refresh-book-reading-stats', 0)
  ) THEN
    REFRESH MATERIALIZED VIEW CONCURRENTLY private.mv_book_reading_stats_v2;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION private.refresh_book_reading_stats() TO service_role;
-- Migration: 20261018000500_multiple_personal_reading_goals.sql
-- Description: Allow multiple reading goals per user and add title and versioning

ALTER TABLE public.reading_goals
  ADD COLUMN IF NOT EXISTS title text NOT NULL DEFAULT 'Minha meta de leitura',
  ADD COLUMN IF NOT EXISTS version bigint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- Remover restricao de unicidade anual para suportar multiplas metas por usuario
DO $$
DECLARE v_constraint text;
BEGIN
  FOR v_constraint IN
    SELECT c.conname
    FROM pg_catalog.pg_constraint c
    WHERE c.conrelid = 'public.reading_goals'::regclass
      AND c.contype = 'u'
      AND c.conkey = ARRAY[
        (SELECT a.attnum FROM pg_catalog.pg_attribute a WHERE a.attrelid = c.conrelid AND a.attname = 'user_id'),
        (SELECT a.attnum FROM pg_catalog.pg_attribute a WHERE a.attrelid = c.conrelid AND a.attname = 'year')
      ]::smallint[]
  LOOP
    EXECUTE format('ALTER TABLE public.reading_goals DROP CONSTRAINT %I', v_constraint);
  END LOOP;
END;
$$;

CREATE INDEX IF NOT EXISTS reading_goals_user_active_idx
  ON public.reading_goals(user_id, year, created_at)
  WHERE archived_at IS NULL;
-- Migration: 20261018000800_book_share_invitations.sql
-- Description: Dedicated table and policies for sharing books via secure email invitations

CREATE TABLE IF NOT EXISTS private.book_share_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id uuid NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  sender_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient_email text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'revoked', 'expired')),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '7 days'),
  created_at timestamptz NOT NULL DEFAULT now(),
  accepted_at timestamptz
);

REVOKE ALL ON private.book_share_invitations FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.book_share_invitations TO service_role;

CREATE INDEX IF NOT EXISTS book_share_invitations_sender_idx
  ON private.book_share_invitations(sender_user_id, status);

CREATE INDEX IF NOT EXISTS book_share_invitations_email_idx
  ON private.book_share_invitations(recipient_email, status);
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
-- Migration: 20261018001100_reading_goals_crud_and_progress.sql
-- Description: Multi-goal recalculation and optimistic CRUD RPCs (QA-03, QA-04)

-- 1. Helper function to recalculate all active goals for a user in a specific calendar year
CREATE OR REPLACE FUNCTION private.recalculate_reading_goals_for_user_year(p_user uuid, p_year int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_books int;
  v_pages int;
  v_minutes int;
  v_start_date date := pg_catalog.make_date(p_year, 1, 1);
  v_end_date date := pg_catalog.make_date(p_year + 1, 1, 1);
BEGIN
  IF p_user IS NULL OR p_year IS NULL THEN
    RETURN;
  END IF;

  -- Contagem de livros canônicos distintos concluídos no ano
  SELECT COUNT(*) INTO v_books
  FROM (
    SELECT ubr.book_id
    FROM public.user_book_readings ubr
    WHERE ubr.user_id = p_user
      AND ubr.status = 'read'
      AND ubr.completed_at >= v_start_date
      AND ubr.completed_at < v_end_date
    UNION
    SELECT DISTINCT s.book_id
    FROM public.user_progress up
    JOIN public.chapters c ON c.id = up.chapter_id
    JOIN public.seasons s ON s.id = c.season_id
    WHERE up.user_id = p_user
      AND up.status = 'read'::public.shelf_status
      AND up.finished_at >= v_start_date
      AND up.finished_at < v_end_date
      AND private.is_book_complete(p_user, s.book_id)
      AND NOT EXISTS (
        SELECT 1
        FROM public.user_book_readings ubr2
        WHERE ubr2.user_id = p_user
          AND ubr2.book_id = s.book_id
          AND ubr2.status <> 'read'
      )
  ) books;

  -- Soma de páginas e minutos lidos a partir de registros ativos do diário no ano
  SELECT
    COALESCE(SUM(
      CASE
        WHEN rje.page_to IS NOT NULL AND rje.page_from IS NOT NULL AND rje.page_to >= rje.page_from THEN rje.page_to - rje.page_from + 1
        WHEN rje.page_to IS NOT NULL THEN rje.page_to
        ELSE 0
      END
    ), 0),
    COALESCE(SUM(rje.minutes_read), 0)
  INTO v_pages, v_minutes
  FROM public.reading_journal_entries rje
  WHERE rje.user_id = p_user
    AND rje.entry_date >= v_start_date
    AND rje.entry_date < v_end_date
    AND rje.archived_at IS NULL;

  -- Atualiza todas as metas ativas do usuário naquele ano
  INSERT INTO public.reading_goal_progress
    (goal_id, books_done, pages_done, minutes_done, updated_at)
  SELECT g.id, v_books, v_pages, v_minutes, pg_catalog.clock_timestamp()
  FROM public.reading_goals g
  WHERE g.user_id = p_user
    AND g.year = p_year
    AND g.archived_at IS NULL
  ON CONFLICT (goal_id) DO UPDATE
  SET books_done = EXCLUDED.books_done,
      pages_done = EXCLUDED.pages_done,
      minutes_done = EXCLUDED.minutes_done,
      updated_at = EXCLUDED.updated_at;
END;
$$;

-- 2. Trigger function ajustada para despachar recálculo em todas as metas ativas
CREATE OR REPLACE FUNCTION private.refresh_reading_goal_progress()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := COALESCE(NEW.user_id, OLD.user_id);
  v_year int;
  v_old_year int;
  v_event_date timestamptz;
BEGIN
  IF TG_TABLE_NAME = 'reading_journal_entries' THEN
    v_event_date := COALESCE(NEW.entry_date::timestamptz, OLD.entry_date::timestamptz);
  ELSIF TG_TABLE_NAME = 'user_book_readings' THEN
    v_event_date := COALESCE(NEW.completed_at, OLD.completed_at, NEW.updated_at, OLD.updated_at);
  ELSIF TG_TABLE_NAME = 'user_progress' THEN
    v_event_date := COALESCE(NEW.finished_at, OLD.finished_at, NEW.updated_at, OLD.updated_at);
  END IF;

  v_year := COALESCE(EXTRACT(YEAR FROM v_event_date)::int, EXTRACT(YEAR FROM pg_catalog.current_date)::int);

  -- Se houve mudança de data entre anos, recalcula ambos
  IF TG_OP = 'UPDATE' THEN
    IF TG_TABLE_NAME = 'reading_journal_entries' AND OLD.entry_date IS NOT NULL THEN
      v_old_year := EXTRACT(YEAR FROM OLD.entry_date)::int;
      IF v_old_year IS DISTINCT FROM v_year THEN
        PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_old_year);
      END IF;
    ELSIF TG_TABLE_NAME = 'user_book_readings' AND OLD.completed_at IS NOT NULL THEN
      v_old_year := EXTRACT(YEAR FROM OLD.completed_at)::int;
      IF v_old_year IS DISTINCT FROM v_year THEN
        PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_old_year);
      END IF;
    END IF;
  END IF;

  PERFORM private.recalculate_reading_goals_for_user_year(v_user, v_year);

  RETURN NULL;
END;
$$;

-- 3. RPC para criação / edição de metas com versão e bloqueio otimista
CREATE OR REPLACE FUNCTION public.set_personal_reading_goal(
  p_id uuid,
  p_title text,
  p_year integer,
  p_books integer,
  p_pages integer,
  p_minutes integer,
  p_version bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_goal public.reading_goals%ROWTYPE;
  v_title text := btrim(COALESCE(p_title, 'Minha meta de leitura'));
  v_target_id uuid;
  v_target_version bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '42501';
  END IF;

  IF p_year IS NULL OR p_year < 2020 OR p_year > 2050 THEN
    RAISE EXCEPTION 'invalid_year' USING errcode = '22023';
  END IF;

  IF (p_books IS NOT NULL AND p_books < 0)
     OR (p_pages IS NOT NULL AND p_pages < 0)
     OR (p_minutes IS NOT NULL AND p_minutes < 0) THEN
    RAISE EXCEPTION 'invalid_target' USING errcode = '22023';
  END IF;

  IF (p_books IS NULL OR p_books <= 0)
     AND (p_pages IS NULL OR p_pages <= 0)
     AND (p_minutes IS NULL OR p_minutes <= 0) THEN
    RAISE EXCEPTION 'at_least_one_target_required' USING errcode = '22023';
  END IF;

  IF length(v_title) < 1 OR length(v_title) > 120 THEN
    RAISE EXCEPTION 'invalid_title' USING errcode = '22023';
  END IF;

  -- Se p_id foi fornecido, verifica existência e propriedade
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_goal
    FROM public.reading_goals
    WHERE id = p_id;

    IF FOUND THEN
      IF v_goal.user_id <> v_user THEN
        RAISE EXCEPTION 'forbidden' USING errcode = '42501';
      END IF;

      IF p_version IS NOT NULL AND v_goal.version <> p_version THEN
        RAISE EXCEPTION 'conflict' USING errcode = '40900';
      END IF;

      UPDATE public.reading_goals
      SET title = v_title,
          year = p_year,
          target_books = p_books,
          target_pages = p_pages,
          target_minutes = p_minutes,
          version = v_goal.version + 1,
          updated_at = pg_catalog.clock_timestamp()
      WHERE id = p_id
      RETURNING * INTO v_goal;

      v_target_id := v_goal.id;
    END IF;
  END IF;

  -- Se for nova meta
  IF v_target_id IS NULL THEN
    v_target_id := COALESCE(p_id, pg_catalog.gen_random_uuid());
    INSERT INTO public.reading_goals (
      id, user_id, title, year, target_books, target_pages, target_minutes, version, created_at, updated_at
    ) VALUES (
      v_target_id, v_user, v_title, p_year, p_books, p_pages, p_minutes, 1, pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    RETURNING * INTO v_goal;
  END IF;

  -- Recalcula progresso imediatamente
  PERFORM private.recalculate_reading_goals_for_user_year(v_user, p_year);

  RETURN pg_catalog.jsonb_build_object(
    'id', v_goal.id,
    'user_id', v_goal.user_id,
    'title', v_goal.title,
    'year', v_goal.year,
    'target_books', v_goal.target_books,
    'target_pages', v_goal.target_pages,
    'target_minutes', v_goal.target_minutes,
    'version', v_goal.version,
    'created_at', v_goal.created_at,
    'updated_at', v_goal.updated_at
  );
END;
$$;

-- 4. RPC para arquivamento de metas
CREATE OR REPLACE FUNCTION public.archive_personal_reading_goal(
  p_id uuid,
  p_version bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_goal public.reading_goals%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_goal
  FROM public.reading_goals
  WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING errcode = 'P0002';
  END IF;

  IF v_goal.user_id <> v_user THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF p_version IS NOT NULL AND v_goal.version <> p_version THEN
    RAISE EXCEPTION 'conflict' USING errcode = '40900';
  END IF;

  UPDATE public.reading_goals
  SET archived_at = pg_catalog.clock_timestamp(),
      version = v_goal.version + 1,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_id;

  -- Remove registro de progresso da meta arquivada
  DELETE FROM public.reading_goal_progress WHERE goal_id = p_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_personal_reading_goal(uuid, text, integer, integer, integer, integer, bigint) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.archive_personal_reading_goal(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.archive_personal_reading_goal(uuid, bigint) TO authenticated, service_role;
-- Migration: 20261018001200_continuous_up_next_queue.sql
-- Description: Continuous reading queue without 5-book cap (QA-06)

DO $$
DECLARE v_constraint text;
BEGIN
  FOR v_constraint IN
    SELECT c.conname
    FROM pg_catalog.pg_constraint c
    WHERE c.conrelid = 'public.user_up_next'::regclass
      AND c.contype = 'c'
  LOOP
    EXECUTE format('ALTER TABLE public.user_up_next DROP CONSTRAINT %I', v_constraint);
  END LOOP;
END;
$$;

ALTER TABLE public.user_up_next
  ADD CONSTRAINT user_up_next_position_check CHECK (position > 0);

CREATE OR REPLACE FUNCTION public.add_to_up_next_atomic(p_book uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_position integer;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING errcode = '42501';
  END IF;

  -- Bloqueio transacional por usuário para evitar condição de corrida
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user::text, 0)
  );

  -- Se o livro já estiver na fila do usuário, retorna a posição atual sem duplicar
  SELECT q.position INTO v_position
  FROM public.user_up_next q
  WHERE q.user_id = v_user AND q.book_id = p_book;

  IF FOUND THEN
    RETURN v_position;
  END IF;

  -- Aloca próxima posição sequencial na playlist contínua
  SELECT COALESCE(MAX(q.position), 0) + 1 INTO v_position
  FROM public.user_up_next q
  WHERE q.user_id = v_user;

  INSERT INTO public.user_up_next(user_id, book_id, position)
  VALUES (v_user, p_book, v_position);

  RETURN v_position;
END;
$$;

REVOKE ALL ON FUNCTION public.add_to_up_next_atomic(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_to_up_next_atomic(uuid) TO authenticated, service_role;
-- Migration: 20261018001300_book_invitations_rpc.sql
-- Description: RPC for creating and managing book share invitations (QA-09, QA-10)

CREATE OR REPLACE FUNCTION public.create_book_share_invitation(
  p_book uuid,
  p_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sender uuid := (SELECT auth.uid());
  v_clean_email text := lower(btrim(p_email));
  v_book_title text;
  v_token text := pg_catalog.encode(pg_catalog.gen_random_bytes(32), 'hex');
  v_hash text;
  v_id uuid;
BEGIN
  IF v_sender IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '42501';
  END IF;

  IF p_book IS NULL THEN
    RAISE EXCEPTION 'invalid_book' USING errcode = '22023';
  END IF;

  SELECT title INTO v_book_title
  FROM public.books
  WHERE id = p_book;

  IF v_book_title IS NULL THEN
    RAISE EXCEPTION 'book_not_found' USING errcode = 'P0002';
  END IF;

  IF v_clean_email IS NULL OR v_clean_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_clean_email) > 255 THEN
    RAISE EXCEPTION 'invalid_email' USING errcode = '22023';
  END IF;

  -- Computa hash do token usando sha256 (via sha256 function ou digest)
  v_hash := pg_catalog.encode(pg_catalog.sha256(v_token::bytea), 'hex');

  -- Insere convite na tabela privada
  INSERT INTO private.book_share_invitations (
    book_id,
    sender_user_id,
    recipient_email,
    token_hash,
    status,
    expires_at,
    created_at
  ) VALUES (
    p_book,
    v_sender,
    v_clean_email,
    v_hash,
    'pending',
    pg_catalog.clock_timestamp() + interval '7 days',
    pg_catalog.clock_timestamp()
  )
  RETURNING id INTO v_id;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'invitation_id', v_id,
    'message', 'Convite enviado com sucesso para o leitor.'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_book_share_invitation(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_book_share_invitation(uuid, text) TO authenticated, service_role;
-- Migração: RPCs transacionais para operação editorial com auditoria integrada (QA-27)
-- Garante que updates em livros, temporadas e capítulos ocorram atomicamente com o registro no editorial_audit_log

-- 1. Atualização transacional de livros
create or replace function public.update_editorial_book(
  p_id uuid,
  p_title text,
  p_synopsis text default null,
  p_cover text default null,
  p_pages integer default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_updated uuid;
begin
  if v_actor is null or not public.is_admin() then
    raise exception 'admin_required' using errcode = '42501';
  end if;

  if p_id is null
    or p_title is null or length(btrim(p_title)) not between 1 and 200
    or (p_pages is not null and p_pages <= 0)
    or (p_cover is not null and p_cover <> '' and p_cover !~ '^https://')
    or length(coalesce(p_synopsis, '')) > 20000 then
    raise exception 'invalid_book' using errcode = '22023';
  end if;

  update public.books
  set title = btrim(p_title),
      synopsis = nullif(btrim(p_synopsis), ''),
      cover_url = nullif(btrim(p_cover), ''),
      total_pages = p_pages
  where id = p_id
  returning id into v_updated;

  if v_updated is null then
    raise exception 'book_not_found' using errcode = 'P0002';
  end if;

  insert into public.editorial_audit_log(actor_id, entity_type, entity_id, action, changes)
  values (
    v_actor,
    'book',
    p_id,
    'update',
    pg_catalog.jsonb_build_object(
      'title', btrim(p_title),
      'synopsis', nullif(btrim(p_synopsis), ''),
      'cover_url', nullif(btrim(p_cover), ''),
      'total_pages', p_pages
    )
  );

  return true;
end;
$$;

revoke all on function public.update_editorial_book(uuid, text, text, text, integer) from public, anon;
grant execute on function public.update_editorial_book(uuid, text, text, text, integer) to authenticated, service_role;

-- 2. Atualização transacional de temporadas
create or replace function public.update_editorial_season(
  p_id uuid,
  p_title text,
  p_description text default null,
  p_status text default 'planned'
) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_updated uuid;
begin
  if v_actor is null or not public.is_admin() then
    raise exception 'admin_required' using errcode = '42501';
  end if;

  if p_id is null
    or p_title is null or length(btrim(p_title)) not between 1 and 200
    or p_status not in ('planned', 'enrolling', 'active', 'finished')
    or length(coalesce(p_description, '')) > 20000 then
    raise exception 'invalid_season' using errcode = '22023';
  end if;

  update public.seasons
  set title = btrim(p_title),
      description = nullif(btrim(p_description), ''),
      status = p_status::public.cycle_status
  where id = p_id
  returning id into v_updated;

  if v_updated is null then
    raise exception 'season_not_found' using errcode = 'P0002';
  end if;

  insert into public.editorial_audit_log(actor_id, entity_type, entity_id, action, changes)
  values (
    v_actor,
    'season',
    p_id,
    'update',
    pg_catalog.jsonb_build_object(
      'title', btrim(p_title),
      'description', nullif(btrim(p_description), ''),
      'status', p_status
    )
  );

  return true;
end;
$$;

revoke all on function public.update_editorial_season(uuid, text, text, text) from public, anon;
grant execute on function public.update_editorial_season(uuid, text, text, text) to authenticated, service_role;

-- 3. Atualização transacional de capítulos
create or replace function public.update_editorial_chapter(
  p_id uuid,
  p_title text,
  p_reading_range text default null,
  p_summary text default null,
  p_youtube_url text default null,
  p_published_at timestamptz default null,
  p_is_draft boolean default false
) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_updated uuid;
  v_action text;
  v_q_count integer;
  v_should_publish boolean;
begin
  if v_actor is null or not public.is_admin() then
    raise exception 'admin_required' using errcode = '42501';
  end if;

  if p_id is null
    or p_title is null or length(btrim(p_title)) not between 1 and 200
    or length(coalesce(p_reading_range, '')) > 500
    or length(coalesce(p_summary, '')) > 20000 then
    raise exception 'invalid_chapter' using errcode = '22023';
  end if;

  v_should_publish := not coalesce(p_is_draft, false) and p_published_at is not null;

  if v_should_publish then
    if p_youtube_url is null or p_youtube_url !~* '^https:\/\/(www\.)?(youtube\.com|youtu\.be)\/' then
      raise exception 'valid_youtube_url_required' using errcode = '22023';
    end if;

    select count(*) into v_q_count
    from public.quiz_questions
    where chapter_id = p_id;

    if v_q_count <> 5 then
      raise exception 'five_questions_required' using errcode = '22023';
    end if;
  end if;

  update public.chapters
  set title = btrim(p_title),
      reading_range = nullif(btrim(p_reading_range), ''),
      summary = nullif(btrim(p_summary), ''),
      youtube_url = nullif(btrim(p_youtube_url), ''),
      published_at = p_published_at,
      is_draft = coalesce(p_is_draft, false)
  where id = p_id
  returning id into v_updated;

  if v_updated is null then
    raise exception 'chapter_not_found' using errcode = 'P0002';
  end if;

  v_action := case when v_should_publish then 'publish_or_schedule' else 'save_draft' end;

  insert into public.editorial_audit_log(actor_id, entity_type, entity_id, action, changes)
  values (
    v_actor,
    'chapter',
    p_id,
    v_action,
    pg_catalog.jsonb_build_object(
      'title', btrim(p_title),
      'published_at', p_published_at,
      'is_draft', coalesce(p_is_draft, false)
    )
  );

  return true;
end;
$$;

revoke all on function public.update_editorial_chapter(uuid, text, text, text, text, timestamptz, boolean) from public, anon;
grant execute on function public.update_editorial_chapter(uuid, text, text, text, text, timestamptz, boolean) to authenticated, service_role;
