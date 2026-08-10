import type { ChapterActionState } from "@huiver/shared";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";
import { useTheme } from "../theme";

/**
 * The download control from a podcast app: an arrow to convert, a spinner with
 * a percentage while it renders, a check when the audio is on disk. Tapping it
 * mid-render stops the chapter — which is a pause, not a discard.
 */
export function ChapterAction({
  state,
  progress,
  onConvert,
  onCancel,
  disabled,
}: {
  state: ChapterActionState;
  progress?: number | null;
  onConvert: () => void;
  onCancel: () => void;
  disabled?: boolean;
}) {
  const { colors } = useTheme();

  if (state === "done") {
    return (
      <View style={[styles.circle, { backgroundColor: colors.primary }]}>
        <Text style={[styles.glyph, { color: colors.primaryForeground }]}>✓</Text>
      </View>
    );
  }

  if (state === "converting" || state === "queued") {
    const percent = progress != null ? Math.round(progress * 100) : null;
    return (
      <Pressable onPress={onCancel} hitSlop={8} style={[styles.circle, { borderColor: colors.border }]}>
        {percent === null ? (
          <ActivityIndicator size="small" color={colors.primary} />
        ) : (
          <Text style={[styles.percent, { color: colors.primary }]}>{percent}</Text>
        )}
      </Pressable>
    );
  }

  return (
    <Pressable
      onPress={onConvert}
      disabled={disabled}
      hitSlop={8}
      style={[styles.circle, { borderColor: colors.border, opacity: disabled ? 0.4 : 1 }]}
    >
      <Text style={[styles.glyph, { color: state === "error" ? colors.destructive : colors.mutedForeground }]}>
        {state === "error" ? "↻" : "↓"}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  circle: {
    width: 32,
    height: 32,
    borderRadius: 16,
    borderWidth: 1,
    alignItems: "center",
    justifyContent: "center",
  },
  glyph: { fontSize: 15, fontWeight: "600" },
  percent: { fontSize: 11, fontWeight: "600" },
});
