/**
 * The web app's design tokens, converted from oklch to sRGB once so React
 * Native can use them directly. Names match `apps/web/styles/globals.css`, so a
 * colour changed there has an obvious counterpart here.
 */
export type ThemeColors = {
  background: string;
  foreground: string;
  card: string;
  cardForeground: string;
  primary: string;
  primaryForeground: string;
  secondary: string;
  secondaryForeground: string;
  muted: string;
  mutedForeground: string;
  accent: string;
  accentForeground: string;
  destructive: string;
  border: string;
  input: string;
  ring: string;
};

export const LIGHT: ThemeColors = {
  background: "#fdfcf9",
  foreground: "#0a0a0a",
  card: "#ffffff",
  cardForeground: "#0a0a0a",
  // Warm ember accent so play controls and progress read as an audio brand.
  primary: "#b94a00",
  primaryForeground: "#fdfaf3",
  secondary: "#f5f5f5",
  secondaryForeground: "#171717",
  muted: "#f5f5f5",
  mutedForeground: "#737373",
  accent: "#f5f5f5",
  accentForeground: "#171717",
  destructive: "#e7000b",
  border: "#e5e5e5",
  input: "#e5e5e5",
  ring: "#cb764e",
};

export const DARK: ThemeColors = {
  background: "#0f0d0b",
  foreground: "#f6f5f2",
  card: "#191714",
  cardForeground: "#f6f5f2",
  primary: "#f59145",
  primaryForeground: "#1a100a",
  secondary: "#262626",
  secondaryForeground: "#fafafa",
  muted: "#262626",
  mutedForeground: "#a1a1a1",
  accent: "#262626",
  accentForeground: "#fafafa",
  destructive: "#ff6467",
  // The web uses translucent white for borders in dark mode; these are the
  // flattened equivalents over `card`/`background`.
  border: "#2a2724",
  input: "#332f2b",
  ring: "#ae6f42",
};

/** `--radius: 0.625rem` and its Tailwind-derived steps. */
export const RADIUS = { sm: 6, md: 8, lg: 10, xl: 14 } as const;

export const SPACING = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const;

export const FONT = {
  title: { fontSize: 22, fontWeight: "600" },
  heading: { fontSize: 17, fontWeight: "600" },
  body: { fontSize: 15, fontWeight: "400" },
  label: { fontSize: 13, fontWeight: "500" },
  caption: { fontSize: 12, fontWeight: "400" },
} as const;
