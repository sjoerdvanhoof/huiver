import { useEffect, useState } from "react";
import { ActivityIndicator, Alert, Pressable, ScrollView, StyleSheet, Switch, Text, View } from "react-native";
import { updateSettings, useSettings, type Theme } from "../src/settings";
import { FONT, SPACING, useTheme } from "../src/theme";
import { VOICES, deleteModel, downloadModel, refreshModelState, useModelState } from "../src/tts";

const THEMES: { value: Theme; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

export default function SettingsScreen() {
  const { colors } = useTheme();
  const settings = useSettings();

  return (
    <ScrollView contentContainerStyle={styles.screen}>
      <ModelSection />

      <Section title="Voice">
        {VOICES.map(voice => (
          <Pressable key={voice.id} onPress={() => updateSettings({ voice: voice.id })} style={styles.option}>
            <Text style={[FONT.body, { color: colors.foreground }]}>{voice.label}</Text>
            {settings.voice === voice.id ? (
              <Text style={[FONT.body, { color: colors.primary }]}>✓</Text>
            ) : null}
          </Pressable>
        ))}
        <Text style={[FONT.caption, { color: colors.mutedForeground }]}>
          Chapters already converted keep the voice they were read in. Convert them again to change it.
        </Text>
      </Section>

      <Section title="Appearance">
        <View style={styles.segmented}>
          {THEMES.map(option => (
            <Pressable
              key={option.value}
              onPress={() => updateSettings({ theme: option.value })}
              style={[
                styles.segment,
                {
                  backgroundColor: settings.theme === option.value ? colors.primary : colors.secondary,
                },
              ]}
            >
              <Text
                style={[
                  FONT.label,
                  { color: settings.theme === option.value ? colors.primaryForeground : colors.secondaryForeground },
                ]}
              >
                {option.label}
              </Text>
            </Pressable>
          ))}
        </View>
      </Section>

      <Section title="Playback">
        <View style={styles.option}>
          <View style={styles.optionText}>
            <Text style={[FONT.body, { color: colors.foreground }]}>Read on into unconverted chapters</Text>
            <Text style={[FONT.caption, { color: colors.mutedForeground }]}>
              When a chapter ends and the next one has not been converted, start reading it instead of stopping there.
            </Text>
          </View>
          <Switch
            value={settings.autoAdvanceIntoUnconverted}
            onValueChange={value => updateSettings({ autoAdvanceIntoUnconverted: value })}
          />
        </View>
      </Section>
    </ScrollView>
  );
}

function ModelSection() {
  const { colors } = useTheme();
  const model = useModelState();
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    void refreshModelState();
  }, []);

  const size = model.status === "missing" || model.status === "downloading" ? model.bytes : null;
  const sizeLabel = size ? `${Math.round(size / (1024 * 1024))} MB` : "about 350 MB";

  return (
    <Section title="Voice model">
      {model.status === "ready" ? (
        <>
          <Text style={[FONT.body, { color: colors.foreground }]}>Kokoro is installed and reads on this device.</Text>
          <Pressable
            onPress={() =>
              Alert.alert("Remove the voice model?", "Books already converted keep their audio. New conversions will need the download again.", [
                { text: "Cancel", style: "cancel" },
                { text: "Remove", style: "destructive", onPress: () => void deleteModel() },
              ])
            }
          >
            <Text style={[FONT.label, { color: colors.destructive }]}>Remove download</Text>
          </Pressable>
        </>
      ) : model.status === "downloading" ? (
        <>
          <Text style={[FONT.body, { color: colors.foreground }]}>
            {model.phase === "extracting" ? "Unpacking" : "Downloading"} — {Math.round(model.percent)}%
          </Text>
          <View style={[styles.progressTrack, { backgroundColor: colors.border }]}>
            <View style={[styles.progressFill, { width: `${model.percent}%`, backgroundColor: colors.primary }]} />
          </View>
          <Text style={[FONT.caption, { color: colors.mutedForeground }]}>
            Keep the app open. An interrupted download picks up where it stopped.
          </Text>
        </>
      ) : (
        <>
          <Text style={[FONT.body, { color: colors.foreground }]}>
            huiver reads books with Kokoro, which runs entirely on this device — nothing is uploaded. The voices are a
            one-off download of {sizeLabel}.
          </Text>
          {model.status === "error" ? (
            <Text style={[FONT.caption, { color: colors.destructive }]}>{model.message}</Text>
          ) : null}
          <Pressable
            disabled={busy}
            onPress={async () => {
              setBusy(true);
              try {
                await downloadModel();
              } catch {
                // The failure is already on the model state; nothing to add.
              } finally {
                setBusy(false);
              }
            }}
            style={[styles.primary, { backgroundColor: colors.primary, opacity: busy ? 0.6 : 1 }]}
          >
            {busy ? (
              <ActivityIndicator color={colors.primaryForeground} />
            ) : (
              <Text style={[FONT.label, { color: colors.primaryForeground }]}>Download voices</Text>
            )}
          </Pressable>
        </>
      )}
    </Section>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.section, { borderColor: colors.border }]}>
      <Text style={[FONT.heading, { color: colors.foreground }]}>{title}</Text>
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { padding: SPACING.lg, gap: SPACING.lg, paddingBottom: SPACING.xxl },
  section: { gap: SPACING.md, paddingBottom: SPACING.lg, borderBottomWidth: StyleSheet.hairlineWidth },
  option: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", gap: SPACING.md },
  optionText: { flex: 1, gap: 2 },
  segmented: { flexDirection: "row", gap: SPACING.sm },
  segment: { flex: 1, borderRadius: 8, paddingVertical: SPACING.sm, alignItems: "center" },
  primary: { borderRadius: 10, paddingVertical: SPACING.md, alignItems: "center", justifyContent: "center" },
  progressTrack: { height: 4, borderRadius: 2, overflow: "hidden" },
  progressFill: { position: "absolute", left: 0, top: 0, bottom: 0 },
});
