import { supabase } from "./client";

export type CommunityStats = {
  book_id: string;
  mood_percent: Record<string, number>;
  pace_percent: Record<"slow" | "medium" | "fast", number>;
  plot_vs_character_avg: number | null;
  sample_size: number | null;
  avg_rating: number;
  ratings_count: number;
  avg_spice_level: number;
};

export type BookReadingStats = {
  book_id: string;
  started_readers: number;
  active_readers: number;
  completed_readers: number;
  new_readers_30d: number;
  completed_readers_30d: number;
  updated_at: string;
  rank_position: number;
};

export async function getBookCommunityStats(
  bookId: string,
): Promise<CommunityStats | null> {
  const { data, error } = await supabase
    .from("v_book_community_stats")
    .select(
      "book_id,mood_percent,pace_percent,plot_vs_character_avg,sample_size,avg_rating,ratings_count,avg_spice_level",
    )
    .eq("book_id", bookId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return {
    book_id: data.book_id ?? bookId,
    mood_percent: (data.mood_percent ?? {}) as Record<string, number>,
    pace_percent: (data.pace_percent ?? {}) as Record<
      "slow" | "medium" | "fast",
      number
    >,
    plot_vs_character_avg: data.plot_vs_character_avg,
    sample_size: data.sample_size,
    avg_rating: data.avg_rating ?? 0,
    ratings_count: data.ratings_count ?? 0,
    avg_spice_level: data.avg_spice_level ?? 0,
  };
}

export async function getBookReadingStats(
  bookId: string,
): Promise<BookReadingStats | null> {
  const { data, error } = await supabase
    .from("v_book_reading_stats")
    .select(
      "book_id,started_readers,active_readers,completed_readers,new_readers_30d,completed_readers_30d,updated_at,rank_position",
    )
    .eq("book_id", bookId)
    .maybeSingle();
  if (error) throw error;
  if (!data || !data.book_id) return null;
  return {
    book_id: data.book_id,
    started_readers: Number(data.started_readers ?? 0),
    active_readers: Number(data.active_readers ?? 0),
    completed_readers: Number(data.completed_readers ?? 0),
    new_readers_30d: Number(data.new_readers_30d ?? 0),
    completed_readers_30d: Number(data.completed_readers_30d ?? 0),
    updated_at: data.updated_at ?? new Date().toISOString(),
    rank_position: Number(data.rank_position ?? 1),
  };
}
