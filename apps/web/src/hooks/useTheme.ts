import { useCallback, useEffect, useSyncExternalStore } from "react";

export type Theme = "system" | "light" | "dark";

const STORAGE_KEY = "huiver:theme";

let current: Theme = readStored();
const listeners = new Set<() => void>();

function readStored(): Theme {
  if (typeof localStorage === "undefined") return "system";
  const value = localStorage.getItem(STORAGE_KEY);
  return value === "light" || value === "dark" ? value : "system";
}

const prefersDark = () =>
  typeof matchMedia !== "undefined" && matchMedia("(prefers-color-scheme: dark)").matches;

export const resolveTheme = (theme: Theme): "light" | "dark" =>
  theme === "system" ? (prefersDark() ? "dark" : "light") : theme;

function apply(theme: Theme): void {
  const dark = resolveTheme(theme) === "dark";
  document.documentElement.classList.toggle("dark", dark);
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute("content", dark ? "#0f0f0f" : "#ffffff");
}

/** Module-level so the player, app bar and settings page all agree. */
export function setTheme(theme: Theme): void {
  current = theme;
  try {
    localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    // Private-mode storage failures shouldn't break theming.
  }
  apply(theme);
  listeners.forEach(l => l());
}

const subscribe = (onChange: () => void) => {
  listeners.add(onChange);
  return () => listeners.delete(onChange);
};

export function useTheme(): { theme: Theme; resolved: "light" | "dark"; setTheme: (t: Theme) => void } {
  const theme = useSyncExternalStore(subscribe, () => current);

  // Follow OS changes while in "system" mode.
  useEffect(() => {
    const media = matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => {
      if (current === "system") {
        apply(current);
        listeners.forEach(l => l());
      }
    };
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, []);

  const set = useCallback((t: Theme) => setTheme(t), []);
  return { theme, resolved: resolveTheme(theme), setTheme: set };
}
