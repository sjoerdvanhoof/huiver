import type { ExpoConfig } from "expo/config";

/**
 * Native projects are generated from this file (`expo prebuild`), so ios/ and
 * android/ stay out of git — everything that would be hand-edited in Xcode is
 * expressed here instead.
 */
const config: ExpoConfig = {
  name: "huiver",
  slug: "huiver",
  scheme: "huiver",
  version: "0.1.0",
  orientation: "portrait",
  userInterfaceStyle: "automatic",

  ios: {
    bundleIdentifier: "online.mo4.huiver",
    supportsTablet: true,
    infoPlist: {
      // Playback has to survive the lock screen, and synthesis only keeps
      // running in the background while audio is playing (see src/convert).
      UIBackgroundModes: ["audio"],
      // The speech model is a ~350 MB download; let the user start it on
      // cellular if they insist, but nothing here needs local networking.
      ITSAppUsesNonExemptEncryption: false,
    },
  },

  android: {
    package: "online.mo4.huiver",
    permissions: [
      "FOREGROUND_SERVICE",
      "FOREGROUND_SERVICE_MEDIA_PLAYBACK",
      "WAKE_LOCK",
      "INTERNET",
    ],
  },

  plugins: [
    "expo-router",
    // An audiobook reader has no business asking for the microphone; keep the
    // background-playback half of the plugin and drop the recording half.
    ["expo-audio", { microphonePermission: false, recordAudioAndroid: false }],
    "expo-sqlite",
    "expo-splash-screen",
    "expo-status-bar",
    // react-native-sherpa-onnx has no config plugin: it is a plain autolinked
    // TurboModule, and its podspec pulls the sherpa-onnx xcframework down
    // during `pod install`. Its download manager does need one small hook.
    "./plugins/withBackgroundModelDownloads",
  ],

  experiments: {
    typedRoutes: true,
  },
};

export default config;
