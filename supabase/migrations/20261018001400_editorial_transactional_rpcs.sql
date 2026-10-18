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
