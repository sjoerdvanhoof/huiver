import type { ChapterActionState } from "@huiver/shared";
import { formatApproxDuration, formatDuration, formatEstimate } from "@huiver/shared";
import { useLocalSearchParams, useRouter } from "expo-router";
import { Alert, FlatList, Pressable, StyleSheet, Text, View } from "react-native";
import { BookCover } from "../../src/components/BookCover";
import { ChapterAction } from "../../src/components/ChapterAction";
import { convertChapter, stopConversion, useConversionProgress } from "../../src/convert/engine";
import { deleteBook, getBook, type ChapterWithTrack } from "../../src/db/queries";
import { useChapters } from "../../src/library";
import { charsPerSecond, playChapter, usePlayer } from "../../src/player/store";
import { getSettings } from "../../src/settings";
import { FONT, SPACING, useTheme } from "../../src/theme";
import { getModelState } from "../../src/tts";

export default function BookScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { colors } = useTheme();
  const router = useRouter();

  const book = getBook(id);
  const { chapters, reload } = useChapters(id);
  const progress = useConversionProgress();
  const playingChapterId = usePlayer(state => state.queue[state.index]?.chapterId ?? null);

  if (!book) return null;

  const rate = charsPerSecond(chapters);
  const convertedCount = chapters.filter(chapter => chapter.track?.status === "done").length;

  function onConvert(chapterId: string) {
    const model = getModelState();
    if (model.status !== "ready") {
      Alert.alert(
        "Voice model needed",
        "huiver reads books with Kokoro, which runs on this device. The voice model is a one-off download of about 350 MB.",
        [
          { text: "Not now", style: "cancel" },
          { text: "Go to settings", onPress: () => router.push("/settings") },
        ],
      );
      return;
    }
    convertChapter({ chapterId, voice: getSettings().voice });
  }

  function onDelete() {
    Alert.alert("Delete this book?", "Its text and any audio rendered for it will be removed.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: () => {
          deleteBook(id);
          router.back();
        },
      },
    ]);
  }

  return (
    <FlatList
      data={chapters}
      keyExtractor={chapter => chapter.id}
      contentContainerStyle={styles.list}
      ListHeaderComponent={
        <View style={styles.header}>
          <BookCover bookId={book.id} title={book.title} uri={book.cover_path} size={110} />

          <View style={styles.headerText}>
            <Text style={[FONT.title, { color: colors.foreground }]}>{book.title}</Text>
            {book.author ? <Text style={[FONT.body, { color: colors.mutedForeground }]}>{book.author}</Text> : null}
            <Text style={[FONT.caption, { color: colors.mutedForeground }]}>
              {convertedCount}/{chapters.length} converted
            </Text>

            <View style={styles.headerButtons}>
              <Pressable
                onPress={() => {
                  const first = chapters.find(chapter => chapter.position && !chapter.position.completed) ?? chapters[0];
                  if (first) playChapter(id, first.id);
                }}
                style={[styles.primary, { backgroundColor: colors.primary }]}
              >
                <Text style={[FONT.label, { color: colors.primaryForeground }]}>
                  {chapters.some(chapter => chapter.position) ? "Resume" : "Play"}
                </Text>
              </Pressable>

              <Pressable onPress={onDelete} hitSlop={8} style={styles.secondary}>
                <Text style={[FONT.label, { color: colors.destructive }]}>Delete</Text>
              </Pressable>
            </View>
          </View>
        </View>
      }
      renderItem={({ item }) => (
        <ChapterRow
          chapter={item}
          charsPerSecond={rate}
          playing={item.id === playingChapterId}
          converting={progress?.chapterId === item.id ? progress : null}
          onPlay={() => playChapter(id, item.id)}
          onConvert={() => onConvert(item.id)}
          onCancel={() => {
            stopConversion(item.id);
            reload();
          }}
        />
      )}
    />
  );
}

function ChapterRow({
  chapter,
  charsPerSecond: rate,
  playing,
  converting,
  onPlay,
  onConvert,
  onCancel,
}: {
  chapter: ChapterWithTrack;
  charsPerSecond: number;
  playing: boolean;
  converting: { chunksDone: number; chunksTotal: number } | null;
  onPlay: () => void;
  onConvert: () => void;
  onCancel: () => void;
}) {
  const { colors } = useTheme();

  const state: ChapterActionState = converting
    ? "converting"
    : chapter.track?.status === "done"
      ? "done"
      : chapter.track?.status === "error"
        ? "error"
        : "none";

  const duration =
    chapter.track?.status === "done" && chapter.track.duration
      ? formatDuration(chapter.track.duration)
      : formatEstimate(chapter.char_count / rate);

  const listened = chapter.position?.position_seconds ?? 0;

  return (
    <Pressable onPress={onPlay} style={styles.row}>
      <View style={styles.rowText}>
        <Text numberOfLines={2} style={[FONT.body, { color: playing ? colors.primary : colors.foreground }]}>
          {chapter.idx + 1}. {chapter.title}
        </Text>
        <Text style={[FONT.caption, { color: colors.mutedForeground }]}>
          {duration}
          {listened > 5 && !chapter.position?.completed ? ` · ${formatApproxDuration(listened)} in` : ""}
          {chapter.position?.completed ? " · finished" : ""}
          {chapter.track?.status === "error" ? ` · ${chapter.track.error ?? "failed"}` : ""}
        </Text>
      </View>

      <ChapterAction
        state={state}
        progress={converting && converting.chunksTotal > 0 ? converting.chunksDone / converting.chunksTotal : null}
        onConvert={onConvert}
        onCancel={onCancel}
      />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  list: { padding: SPACING.lg, gap: SPACING.md, paddingBottom: SPACING.xxl },
  header: { flexDirection: "row", gap: SPACING.lg, marginBottom: SPACING.lg },
  headerText: { flex: 1, gap: 4 },
  headerButtons: { flexDirection: "row", alignItems: "center", gap: SPACING.md, marginTop: SPACING.sm },
  primary: { borderRadius: 10, paddingHorizontal: SPACING.xl, paddingVertical: SPACING.sm },
  secondary: { paddingVertical: SPACING.sm },
  row: { flexDirection: "row", alignItems: "center", gap: SPACING.md },
  rowText: { flex: 1, gap: 2 },
});
