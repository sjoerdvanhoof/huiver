import { formatDuration } from "@huiver/shared";
import { useRouter } from "expo-router";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { currentItem, toggle, usePlayer } from "../player/store";
import { FONT, RADIUS, SPACING, useTheme } from "../theme";
import { BookCover } from "./BookCover";

/**
 * The bar above the tab area: cover, chapter, play/pause, and a hairline of
 * progress. Tapping it opens the full player, exactly as on the web.
 */
export function MiniPlayer() {
  const { colors } = useTheme();
  const router = useRouter();

  const state = usePlayer(s => s);
  const item = currentItem(state);
  if (!item || state.index < 0) return null;

  const duration = state.duration ?? 0;
  const played = duration > 0 ? Math.min(1, state.position / duration) : 0;
  // A live chapter only reaches as far as synthesis has: show that separately
  // so the untouched remainder does not read as buffered-and-ready.
  const rendered = duration > 0 ? Math.min(1, state.renderedSeconds / duration) : 0;
  const isLive = item.source.kind === "live";

  return (
    <Pressable
      onPress={() => router.push("/player")}
      style={[styles.bar, { backgroundColor: colors.card, borderColor: colors.border }]}
    >
      <View style={[styles.track, { backgroundColor: colors.border }]}>
        {isLive ? <View style={[styles.rendered, { width: `${rendered * 100}%`, backgroundColor: colors.muted }]} /> : null}
        <View style={[styles.played, { width: `${played * 100}%`, backgroundColor: colors.primary }]} />
      </View>

      <View style={styles.row}>
        <BookCover bookId={item.bookId} title={item.bookTitle} uri={item.coverUri} size={34} radius={RADIUS.sm} />

        <View style={styles.text}>
          <Text numberOfLines={1} style={[FONT.label, { color: colors.foreground }]}>
            {item.chapterTitle}
          </Text>
          <Text numberOfLines={1} style={[FONT.caption, { color: colors.mutedForeground }]}>
            {state.waitingForAudio
              ? "Synthesizing…"
              : `${formatDuration(state.position)}${duration > 0 ? ` / ${formatDuration(duration)}` : ""}`}
          </Text>
        </View>

        <Pressable onPress={toggle} hitSlop={12} style={[styles.button, { backgroundColor: colors.primary }]}>
          <Text style={[styles.glyph, { color: colors.primaryForeground }]}>
            {state.status === "playing" || state.status === "loading" ? "❚❚" : "▶"}
          </Text>
        </Pressable>
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  bar: { borderTopWidth: StyleSheet.hairlineWidth },
  track: { height: 2, width: "100%" },
  rendered: { position: "absolute", left: 0, top: 0, bottom: 0 },
  played: { position: "absolute", left: 0, top: 0, bottom: 0 },
  row: { flexDirection: "row", alignItems: "center", gap: SPACING.md, padding: SPACING.sm },
  text: { flex: 1, gap: 2 },
  button: { width: 38, height: 38, borderRadius: 19, alignItems: "center", justifyContent: "center" },
  glyph: { fontSize: 13, fontWeight: "700" },
});
