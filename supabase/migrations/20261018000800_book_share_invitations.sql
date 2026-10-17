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
