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
