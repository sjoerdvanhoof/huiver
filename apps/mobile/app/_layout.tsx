import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { useEffect } from "react";
import { StyleSheet, View } from "react-native";
import { SafeAreaProvider, useSafeAreaInsets } from "react-native-safe-area-context";
import { MiniPlayer } from "../src/components/MiniPlayer";
import { reconcileInterruptedTracks, sweepChunks } from "../src/convert/engine";
import { restoreLastSession } from "../src/player/store";
import { refreshModelState } from "../src/tts";
import { useTheme } from "../src/theme";

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <Shell />
    </SafeAreaProvider>
  );
}

function Shell() {
  const { colors, scheme } = useTheme();
  const insets = useSafeAreaInsets();

  useEffect(() => {
    // A run the OS cut short is not resumed on its own — that would start
    // synthesis nobody asked for — it just stops claiming to be in progress.
    reconcileInterruptedTracks();
    sweepChunks();
    restoreLastSession();
    void refreshModelState();
  }, []);

  return (
    <View style={[styles.root, { backgroundColor: colors.background }]}>
      <StatusBar style={scheme === "dark" ? "light" : "dark"} />

      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: colors.background },
          headerTintColor: colors.foreground,
          headerShadowVisible: false,
          contentStyle: { backgroundColor: colors.background },
        }}
      >
        <Stack.Screen name="index" options={{ title: "huiver" }} />
        <Stack.Screen name="book/[id]" options={{ title: "" }} />
        <Stack.Screen name="player" options={{ presentation: "modal", title: "Now playing" }} />
        <Stack.Screen name="settings" options={{ presentation: "modal", title: "Settings" }} />
      </Stack>

      <View style={{ paddingBottom: insets.bottom }}>
        <MiniPlayer />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({ root: { flex: 1 } });
