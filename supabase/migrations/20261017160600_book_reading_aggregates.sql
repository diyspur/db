-- M06: Aggregated book reading statistics snapshot and public view.
-- Immutable additive migration.

CREATE MATERIALIZED VIEW IF NOT EXISTS private.mv_book_reading_stats AS
SELECT
  b.id AS book_id,
  count(r.user_id) FILTER (WHERE r.first_started_at IS NOT NULL) AS started_readers,
  count(r.user_id) FILTER (WHERE r.status = 'reading') AS active_readers,
  count(r.user_id) FILTER (WHERE r.status = 'read') AS completed_readers,
  count(r.user_id) FILTER (
    WHERE r.first_started_at >= now() - interval '30 days'
  ) AS new_readers_30d,
  count(r.user_id) FILTER (
    WHERE r.status = 'read' AND r.completed_at >= now() - interval '30 days'
  ) AS completed_readers_30d,
  now() AS updated_at
FROM public.books b
LEFT JOIN public.user_book_readings r ON r.book_id = b.id
GROUP BY b.id;

CREATE UNIQUE INDEX IF NOT EXISTS book_reading_stats_book_idx
  ON private.mv_book_reading_stats(book_id);

-- Filter through public.books in security_invoker view so only visible books are returned.
DROP VIEW IF EXISTS public.v_book_reading_stats CASCADE;
CREATE OR REPLACE VIEW public.v_book_reading_stats
WITH (security_invoker = true)
AS
SELECT
  s.book_id,
  s.started_readers,
  s.active_readers,
  s.completed_readers,
  s.new_readers_30d,
  s.completed_readers_30d,
  s.updated_at,
  dense_rank() OVER (
    ORDER BY s.completed_readers DESC, s.active_readers DESC
  ) AS rank_position
FROM private.mv_book_reading_stats s
JOIN public.books b ON b.id = s.book_id;

REVOKE ALL ON private.mv_book_reading_stats FROM PUBLIC, anon, authenticated;
GRANT SELECT ON private.mv_book_reading_stats TO anon, authenticated, service_role;
GRANT SELECT ON public.v_book_reading_stats TO anon, authenticated, service_role;

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
    REFRESH MATERIALIZED VIEW private.mv_book_reading_stats;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.refresh_book_reading_stats() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.refresh_book_reading_stats() TO service_role;

CREATE OR REPLACE FUNCTION public.refresh_book_reading_stats()
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.refresh_book_reading_stats();
$$;

REVOKE ALL ON FUNCTION public.refresh_book_reading_stats() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_book_reading_stats() TO service_role;
