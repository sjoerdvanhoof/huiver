import { useColorScheme } from "react-native";
import { useSettings } from "../settings";
import { DARK, LIGHT, type ThemeColors } from "./tokens";

export { DARK, LIGHT, RADIUS, SPACING, FONT } from "./tokens";
export type { ThemeColors } from "./tokens";

export type ResolvedTheme = { colors: ThemeColors; scheme: "light" | "dark" };

/**
 * The active palette. "system" follows the OS; an explicit choice in settings
 * wins, which is the same rule the web app's theme toggle follows.
 */
export function useTheme(): ResolvedTheme {
  const { theme } = useSettings();
  const system = useColorScheme();
  const scheme = theme === "system" ? (system === "dark" ? "dark" : "light") : theme;

  return { colors: scheme === "dark" ? DARK : LIGHT, scheme };
}
