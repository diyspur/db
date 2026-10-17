-- M08: Extend notification_kind enum for community activity, meeting lifecycle, and club invitations.
-- Dedicated migration for enum extensions.

DO $$ BEGIN
  ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'channel_activity';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'meeting_updated';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'meeting_cancelled';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TYPE public.notification_kind ADD VALUE IF NOT EXISTS 'club_invitation';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
