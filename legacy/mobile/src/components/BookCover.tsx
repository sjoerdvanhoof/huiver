import { coverGradient, coverInitial } from "@huiver/shared";
import { LinearGradient } from "expo-linear-gradient";
import { Image, StyleSheet, Text, View } from "react-native";
import { RADIUS } from "../theme";

/**
 * A book's cover, or the deterministic gradient it falls back to. The gradient
 * and the initial come from @huiver/shared, so a book looks the same here as it
 * does in the browser.
 */
export function BookCover({
  bookId,
  title,
  uri,
  size = 96,
  radius = RADIUS.md,
}: {
  bookId: string;
  title: string;
  uri: string | null;
  size?: number;
  radius?: number;
}) {
  const style = { width: size, height: size * 1.5, borderRadius: radius };

  if (uri) return <Image source={{ uri }} style={style} resizeMode="cover" />;

  const [from, to] = coverGradient(bookId);
  return (
    <LinearGradient colors={[from, to]} start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }} style={[style, styles.center]}>
      <Text style={[styles.initial, { fontSize: size * 0.5 }]}>{coverInitial(title)}</Text>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  center: { alignItems: "center", justifyContent: "center" },
  initial: { color: "rgba(255,255,255,0.45)", fontWeight: "300" },
});
