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
