-- ============================================================================
-- SCRIPT DE LIMPEZA E SANIFICAÇÃO GERAL DO SUPABASE (DIYSPUR)
-- Objetivo:
--  1. Manter todos os dados de livros e metadados descritivos (books, authors, seasons, chapters, content_warnings, quizzes, etc.)
--  2. Limpar todas as outras tabelas de interação, mensagens, progresso, encontros e filas
--  3. Limpar todos os usuários de auth.users e public.profiles, mantendo EXCLUSIVAMENTE admin@diyspur.com com role 'admin'
-- ============================================================================

BEGIN;

-- 1. Limpeza de tabelas de interação, mensagens e comunidade
TRUNCATE TABLE
  public.club_messages,
  public.club_channels,
  public.club_channel_consents,
  public.club_channel_preferences,
  public.club_channel_prompts,
  public.user_club_members,
  public.user_club_invitations,
  public.club_member_sanctions,
  public.user_clubs,
  public.community_user_blocks,
  public.content_reports,
  public.comments,
  public.video_timed_comments,
  public.feed_post_comments,
  public.feed_post_likes,
  public.feed_post_media,
  public.feed_posts,
  public.reactions,
  public.follows
CASCADE;

-- 2. Limpeza de estante pessoal, leituras, fila e diários
TRUNCATE TABLE
  public.user_book_readings,
  public.user_progress,
  public.book_reading_requests,
  public.user_up_next,
  public.reading_goal_progress,
  public.reading_goals,
  public.reading_list_items,
  public.reading_list_collaborators,
  public.reading_lists,
  public.reading_journal_likes,
  public.reading_journal_attachments,
  public.reading_journal_entries,
  public.buddy_read_checkpoints,
  public.buddy_read_members,
  public.buddy_reads
CASCADE;

-- 3. Limpeza de gamificação, métricas, votos, encontros e quizzes
TRUNCATE TABLE
  public.xp_events,
  public.user_xp,
  public.user_streaks,
  public.user_achievements,
  public.achievements,
  public.user_milestone_progress,
  public.milestones,
  public.user_challenge_prompt_progress,
  public.user_challenges,
  public.chapter_prompt_responses,
  public.chapter_activity_attempts,
  public.quiz_attempts,
  public.quiz_rate_limits,
  public.meeting_attendance,
  public.meeting_rsvps,
  public.meeting_operation_requests,
  public.sent_reminders,
  public.meetings,
  public.book_reviews,
  public.book_mood_votes,
  public.book_content_warning_votes,
  public.book_poll_votes,
  public.book_poll_options,
  public.book_polls,
  public.host_prompt_votes
CASCADE;

-- 4. Limpeza de notificações, newsletters, auditoria e filas de background
TRUNCATE TABLE
  public.notifications,
  public.push_subscriptions,
  public.user_notification_preferences,
  public.community_notification_outbox,
  public.newsletter_deliveries,
  public.newsletter_dispatch_runs,
  public.newsletter_subscribers,
  public.rate_limits,
  public.social_render_jobs,
  public.user_match_cache,
  public.user_reading_embeddings,
  public.user_reading_preferences,
  public.user_quiz_averages,
  public.chapter_quiz_averages,
  public.editorial_audit_log,
  public.payment_events,
  public.stripe_customers,
  public.user_subscriptions,
  public.user_membership_perks,
  public.affiliate_clicks
CASCADE;

-- 5. Higienização de Usuários: Deixar APENAS admin@diyspur.com
DO $$
DECLARE
  v_admin_id uuid;
BEGIN
  -- Localizar o ID do usuário administrador
  SELECT id INTO v_admin_id FROM auth.users WHERE lower(email) = 'admin@diyspur.com';
  
  IF v_admin_id IS NULL THEN
    RAISE NOTICE 'Usuário admin@diyspur.com não encontrado em auth.users. Criando registro com credenciais seguras...';
    v_admin_id := gen_random_uuid();
    INSERT INTO auth.users (
      id, instance_id, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at, role, aud
    ) VALUES (
      v_admin_id,
      '00000000-0000-0000-0000-000000000000',
      'admin@diyspur.com',
      crypt('Admin@Diyspur2026!', gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}',
      '{"display_name":"Administrador DIYSPUR","username":"admin"}',
      now(),
      now(),
      'authenticated',
      'authenticated'
    );
  END IF;

  -- Remove todos os perfis exceto o do admin
  DELETE FROM public.profiles WHERE id <> v_admin_id;

  -- Garante a existência e a role 'admin' no perfil
  INSERT INTO public.profiles (id, display_name, username, role, bio, created_at, updated_at)
  VALUES (v_admin_id, 'Administrador DIYSPUR', 'admin', 'admin', 'Administração DIYSPUR', now(), now())
  ON CONFLICT (id) DO UPDATE
  SET role = 'admin',
      display_name = COALESCE(public.profiles.display_name, 'Administrador DIYSPUR'),
      username = COALESCE(public.profiles.username, 'admin');

  -- Remove todos os outros usuários de auth.users
  DELETE FROM auth.users WHERE id <> v_admin_id;
  
  RAISE NOTICE 'Saneamento concluído! Apenas o usuário % (ID: %) foi preservado.', 'admin@diyspur.com', v_admin_id;
END $$;

COMMIT;
