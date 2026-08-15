const { withAppDelegate, withDangerousMod } = require("expo/config-plugins");
const fs = require("node:fs");
const path = require("node:path");

/**
 * Let the Kokoro download finish while the app is in the background.
 *
 * The download manager in react-native-sherpa-onnx uses
 * @kesha-antonov/react-native-background-downloader, which needs the app
 * delegate to hand iOS's completion handler back to it. The library ships no
 * config plugin, and `ios/` is generated rather than committed, so the edit
 * lives here where `expo prebuild` will reapply it every time.
 *
 * Without this the model still downloads — just only while the app is on
 * screen, which is a long time to stare at a 350 MB progress bar.
 */

const HOOK = `
  // Added by plugins/withBackgroundModelDownloads.js
  public override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    RNBackgroundDownloader.setCompletionHandlerWithIdentifier(identifier, completionHandler: completionHandler)
  }
`;

const IMPORT = "#import <RNBackgroundDownloader.h>";

const withAppDelegateHook = config =>
  withAppDelegate(config, mod => {
    const { contents } = mod.modResults;
    if (contents.includes("handleEventsForBackgroundURLSession")) return mod;

    // Append the method to the AppDelegate class, just before its closing brace.
    const marker = "\n  // Linking API";
    mod.modResults.contents = contents.includes(marker)
      ? contents.replace(marker, `\n${HOOK}${marker}`)
      : contents.replace(/\n}\n\nclass ReactNativeDelegate/, `\n${HOOK}}\n\nclass ReactNativeDelegate`);

    return mod;
  });

/** The Swift delegate can only see the library through the bridging header. */
const withBridgingHeader = config =>
  withDangerousMod(config, [
    "ios",
    async mod => {
      const name = mod.modRequest.projectName;
      const header = path.join(mod.modRequest.platformProjectRoot, name, `${name}-Bridging-Header.h`);
      if (!fs.existsSync(header)) return mod;

      const contents = fs.readFileSync(header, "utf8");
      if (!contents.includes(IMPORT)) fs.writeFileSync(header, `${contents.trimEnd()}\n${IMPORT}\n`);
      return mod;
    },
  ]);

module.exports = config => withBridgingHeader(withAppDelegateHook(config));
