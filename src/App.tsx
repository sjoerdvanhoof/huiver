import { ChevronLeft, Headphones, Moon, Settings, Sun } from "lucide-react";
import { useEffect } from "react";
import { ConversionIndicator } from "./components/ConversionIndicator";
import { href, navigate, useHashRoute } from "./hooks/useHashRoute";
import { useTheme } from "./hooks/useTheme";
import { BookPage } from "./pages/BookPage";
import { LibraryPage } from "./pages/LibraryPage";
import { SettingsPage } from "./pages/SettingsPage";
import { FullPlayer } from "./player/FullPlayer";
import { MiniPlayer } from "./player/MiniPlayer";
import { restoreLastSession } from "./player/restore";
import { usePlayer } from "./player/store";
import "./index.css";

export function App() {
  const route = useHashRoute();
  const { resolved, setTheme } = useTheme();
  const playerVisible = usePlayer(s => s.index >= 0);

  // Put the last listening session one tap away after a reload.
  useEffect(() => {
    void restoreLastSession();
  }, []);

  return (
    <div className={playerVisible ? "pb-24" : "pb-8"}>
      <header className="sticky top-0 z-30 border-b bg-background/85 backdrop-blur-md">
        <div className="mx-auto flex h-14 max-w-6xl items-center gap-2 px-4 sm:px-6">
          {route.name === "book" && (
            <button
              onClick={() => navigate({ name: "library" })}
              aria-label="Back to library"
              className="-ml-2 rounded-full p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            >
              <ChevronLeft className="size-5" />
            </button>
          )}

          <a href={href({ name: "library" })} className="flex items-center gap-2.5">
            <Headphones className="size-6 text-primary" />
            <span className="text-lg font-bold tracking-tight">huiver</span>
          </a>

          <span className="hidden text-xs text-muted-foreground sm:block">
            Turn ebooks into audiobooks, locally.
          </span>

          <div className="ml-auto flex items-center gap-1">
            <ConversionIndicator />
            <button
              onClick={() => setTheme(resolved === "dark" ? "light" : "dark")}
              aria-label={resolved === "dark" ? "Switch to light mode" : "Switch to dark mode"}
              className="rounded-full p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            >
              {resolved === "dark" ? <Sun className="size-5" /> : <Moon className="size-5" />}
            </button>
            <a
              href={href({ name: "settings" })}
              aria-label="Settings"
              className={`rounded-full p-2 transition-colors hover:bg-accent hover:text-foreground ${
                route.name === "settings" ? "text-foreground" : "text-muted-foreground"
              }`}
            >
              <Settings className="size-5" />
            </a>
          </div>
        </div>
      </header>

      <main className="mx-auto w-full max-w-6xl px-4 pt-6 sm:px-6">
        {route.name === "library" && <LibraryPage />}
        {route.name === "book" && <BookPage key={route.id} bookId={route.id} />}
        {route.name === "settings" && <SettingsPage />}
      </main>

      <MiniPlayer />
      <FullPlayer />
    </div>
  );
}

export default App;
