import { supabase } from "./client";

export type ClubProgressPanel = {
  club_id: string;
  club_name: string;
  current_book_id: string | null;
  current_book_title: string | null;
  current_season_id: string | null;
  current_season_title: string | null;
  current_started_at: string | null;
  current_ends_at: string | null;
  distinct_readers: number;
  chapters_read: number;
  chapters_in_progress: number;
  avg_percent: number;
  finished_count: number;
  reading_count: number;
  not_started_count: number;
};

export type OfficialBookGroupResult = {
  club_id: string;
  club_slug: string;
};

export type ClubChannelDirectoryItem = {
  id: string;
  slug: string;
  kind: "no_spoilers" | "full_spoilers" | "chapter" | "topic";
  display_name: string;
  chapter_id: string | null;
  chapter_number: number | null;
  season_number: number | null;
  spoiler_policy: "none" | "whole_book" | "chapter";
  rules_version: number;
  can_read: boolean;
  has_consent: boolean;
  access_reason:
    | "ok"
    | "unauthenticated"
    | "not_member"
    | "banned"
    | "chapter_locked"
    | "chapter_unread"
    | "consent_required";
};

export async function getClubProgressPanel(
  clubId: string,
): Promise<ClubProgressPanel | null> {
  const { data, error } = await supabase
    .from("v_club_progress_panel")
    .select(
      "club_id,club_name,current_book_id,current_book_title,current_season_id,current_season_title,current_started_at,current_ends_at,distinct_readers,chapters_read,chapters_in_progress,avg_percent,finished_count,reading_count,not_started_count",
    )
    .eq("club_id", clubId)
    .maybeSingle();
  if (error) throw error;
  return data as ClubProgressPanel | null;
}

export async function ensureOfficialBookGroup(
  bookId: string,
): Promise<OfficialBookGroupResult> {
  const { data, error } = await supabase.rpc("ensure_official_book_group", {
    p_book: bookId,
  });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) throw new Error("Failed to ensure official book group");
  return row as OfficialBookGroupResult;
}

export async function getClubChannelDirectory(
  clubId: string,
): Promise<ClubChannelDirectoryItem[]> {
  const { data, error } = await supabase.rpc("get_club_channel_directory", {
    p_club: clubId,
  });
  if (error) throw error;
  return (data ?? []) as ClubChannelDirectoryItem[];
}

export async function setClubReadingContext(
  clubId: string,
  context: {
    version: number;
    name: string;
    description?: string | null;
    is_private: boolean;
    current_season_id?: string | null;
  },
): Promise<number> {
  const { data, error } = await supabase.rpc("update_user_club", {
    p_club: clubId,
    p_version: context.version,
    p_name: context.name,
    p_description: context.description ?? null,
    p_private: context.is_private,
    p_season_id: context.current_season_id ?? null,
  });
  if (error) throw error;
  return Number(data);
}
