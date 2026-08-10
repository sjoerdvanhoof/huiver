import { formatApproxDuration } from "@huiver/shared";
import { Link, useRouter } from "expo-router";
import { useState } from "react";
import { ActivityIndicator, Alert, FlatList, Pressable, StyleSheet, Text, View } from "react-native";
import { BookCover } from "../src/components/BookCover";
import { pickAndImportBook } from "../src/import/importBook";
import { useLibrary } from "../src/library";
import { FONT, SPACING, useTheme } from "../src/theme";
import type { BookSummary } from "../src/db/queries";

export default function LibraryScreen() {
  const { colors } = useTheme();
  const router = useRouter();
  const { books, reload } = useLibrary();
  const [importing, setImporting] = useState(false);

  async function onImport() {
    setImporting(true);
    try {
      const imported = await pickAndImportBook();
      reload();
      if (imported) router.push({ pathname: "/book/[id]", params: { id: imported.id } });
    } catch (error) {
      Alert.alert("Could not read that file", error instanceof Error ? error.message : String(error));
    } finally {
      setImporting(false);
    }
  }

  return (
    <View style={styles.screen}>
      <FlatList
        data={books}
        keyExtractor={book => book.id}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <Text style={[FONT.body, styles.empty, { color: colors.mutedForeground }]}>
            No books yet. Add an EPUB and huiver will read it to you.
          </Text>
        }
        renderItem={({ item }) => <BookRow book={item} />}
      />

      <View style={[styles.footer, { borderColor: colors.border }]}>
        <Pressable
          onPress={onImport}
          disabled={importing}
          style={[styles.add, { backgroundColor: colors.primary, opacity: importing ? 0.6 : 1 }]}
        >
          {importing ? (
            <ActivityIndicator color={colors.primaryForeground} />
          ) : (
            <Text style={[FONT.heading, { color: colors.primaryForeground }]}>Add a book</Text>
          )}
        </Pressable>

        <Link href="/settings" asChild>
          <Pressable hitSlop={10} style={styles.settings}>
            <Text style={[FONT.body, { color: colors.mutedForeground }]}>Settings</Text>
          </Pressable>
        </Link>
      </View>
    </View>
  );
}

function BookRow({ book }: { book: BookSummary }) {
  const { colors } = useTheme();

  const converted = `${book.convertedCount}/${book.chapterCount} chapters`;
  // Before anything is rendered there is no measured rate to go on, so fall
  // back to Kokoro's rough ~16 characters a second.
  const estimate = book.durationSeconds > 0 ? book.durationSeconds : book.charCount / 16;

  return (
    <Link href={{ pathname: "/book/[id]", params: { id: book.id } }} asChild>
      <Pressable style={styles.row}>
        <BookCover bookId={book.id} title={book.title} uri={book.cover_path} size={56} />

        <View style={styles.rowText}>
          <Text numberOfLines={2} style={[FONT.heading, { color: colors.foreground }]}>
            {book.title}
          </Text>
          {book.author ? (
            <Text numberOfLines={1} style={[FONT.body, { color: colors.mutedForeground }]}>
              {book.author}
            </Text>
          ) : null}
          <Text style={[FONT.caption, { color: colors.mutedForeground }]}>
            {converted} · {formatApproxDuration(estimate)}
          </Text>
        </View>
      </Pressable>
    </Link>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1 },
  list: { padding: SPACING.lg, gap: SPACING.lg },
  empty: { textAlign: "center", marginTop: SPACING.xxl },
  row: { flexDirection: "row", gap: SPACING.lg, alignItems: "center" },
  rowText: { flex: 1, gap: 3 },
  footer: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.md,
    padding: SPACING.lg,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  add: { flex: 1, borderRadius: 12, paddingVertical: SPACING.md, alignItems: "center", justifyContent: "center" },
  settings: { paddingHorizontal: SPACING.md, paddingVertical: SPACING.md },
});
