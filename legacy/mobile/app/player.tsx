import { formatDuration } from "@huiver/shared";
import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { BookCover } from "../src/components/BookCover";
import {
  currentItem,
  cycleRate,
  cycleSleep,
  next,
  previous,
  seekBy,
  seekTo,
  toggle,
  usePlayer,
} from "../src/player/store";
import { FONT, SPACING, useTheme } from "../src/theme";

export default function PlayerScreen() {
  const { colors } = useTheme();
  const state = usePlayer(s => s);
  const item = currentItem(state);

  if (!item) {
    return (
      <View style={styles.empty}>
        <Text style={[FONT.body, { color: colors.mutedForeground }]}>Nothing playing.</Text>
      </View>
    );
  }

  const duration = state.duration ?? 0;
  const played = duration > 0 ? Math.min(1, state.position / duration) : 0;
  const rendered = duration > 0 ? Math.min(1, state.renderedSeconds / duration) : 0;
  const isLive = item.source.kind === "live";

  return (
    <View style={styles.screen}>
      <View style={styles.art}>
        <BookCover bookId={item.bookId} title={item.bookTitle} uri={item.coverUri} size={200} />
      </View>

      <View style={styles.meta}>
        <Text numberOfLines={2} style={[FONT.title, styles.center, { color: colors.foreground }]}>
          {item.chapterTitle}
        </Text>
        <Text numberOfLines={1} style={[FONT.body, styles.center, { color: colors.mutedForeground }]}>
          {item.bookTitle}
          {item.author ? ` · ${item.author}` : ""}
        </Text>
      </View>

      <Scrubber
        played={played}
        rendered={isLive ? rendered : 1}
        onScrub={fraction => seekTo(fraction * duration)}
      />

      <View style={styles.times}>
        <Text style={[FONT.caption, { color: colors.mutedForeground }]}>{formatDuration(state.position)}</Text>
        <Text style={[FONT.caption, { color: colors.mutedForeground }]}>
          {isLive ? `~${formatDuration(duration)}` : formatDuration(duration)}
        </Text>
      </View>

      {isLive ? (
        <Text style={[FONT.caption, styles.center, { color: colors.mutedForeground }]}>
          {state.waitingForAudio
            ? "Reading ahead…"
            : `Rendered up to ${formatDuration(state.renderedSeconds)} — conversion pauses if you leave the app without audio playing.`}
        </Text>
      ) : null}

      <View style={styles.transport}>
        <Control label="⏮" onPress={previous} />
        <Control label="−15" onPress={() => seekBy(-15)} />
        <Pressable onPress={toggle} style={[styles.play, { backgroundColor: colors.primary }]}>
          <Text style={[styles.playGlyph, { color: colors.primaryForeground }]}>
            {state.status === "playing" || state.status === "loading" ? "❚❚" : "▶"}
          </Text>
        </Pressable>
        <Control label="+30" onPress={() => seekBy(30)} />
        <Control label="⏭" onPress={next} />
      </View>

      <View style={styles.extras}>
        <Pressable onPress={cycleRate} hitSlop={8}>
          <Text style={[FONT.label, { color: colors.foreground }]}>{state.rate}×</Text>
        </Pressable>

        <Pressable onPress={cycleSleep} hitSlop={8}>
          <Text style={[FONT.label, { color: state.sleep ? colors.primary : colors.mutedForeground }]}>
            {state.sleep === null
              ? "Sleep timer"
              : state.sleep.kind === "chapter"
                ? "End of chapter"
                : `${state.sleep.minutes} min`}
          </Text>
        </Pressable>
      </View>
    </View>
  );
}

/** Tap-to-seek bar. A live chapter shows how far synthesis has actually got. */
function Scrubber({
  played,
  rendered,
  onScrub,
}: {
  played: number;
  rendered: number;
  onScrub: (fraction: number) => void;
}) {
  const { colors } = useTheme();

  const [width, setWidth] = useState(1);

  return (
    <Pressable
      style={styles.scrubHit}
      onLayout={event => setWidth(event.nativeEvent.layout.width || 1)}
      onPress={event => onScrub(Math.max(0, Math.min(1, event.nativeEvent.locationX / width)))}
    >
      <View style={[styles.scrubTrack, { backgroundColor: colors.border }]}>
        <View style={[styles.scrubFill, { width: `${rendered * 100}%`, backgroundColor: colors.muted }]} />
        <View style={[styles.scrubFill, { width: `${played * 100}%`, backgroundColor: colors.primary }]} />
      </View>
    </Pressable>
  );
}

function Control({ label, onPress }: { label: string; onPress: () => void }) {
  const { colors } = useTheme();
  return (
    <Pressable onPress={onPress} hitSlop={10} style={styles.control}>
      <Text style={[FONT.label, { color: colors.foreground }]}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: SPACING.xl, gap: SPACING.lg },
  empty: { flex: 1, alignItems: "center", justifyContent: "center" },
  art: { alignItems: "center", marginTop: SPACING.lg },
  meta: { gap: 4 },
  center: { textAlign: "center" },
  scrubHit: { paddingVertical: SPACING.md },
  scrubTrack: { height: 4, borderRadius: 2, overflow: "hidden" },
  scrubFill: { position: "absolute", left: 0, top: 0, bottom: 0 },
  times: { flexDirection: "row", justifyContent: "space-between", marginTop: -SPACING.md },
  transport: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginTop: SPACING.md },
  control: { paddingHorizontal: SPACING.sm, paddingVertical: SPACING.sm },
  play: { width: 64, height: 64, borderRadius: 32, alignItems: "center", justifyContent: "center" },
  playGlyph: { fontSize: 20, fontWeight: "700" },
  extras: { flexDirection: "row", justifyContent: "space-between", marginTop: SPACING.md },
});
