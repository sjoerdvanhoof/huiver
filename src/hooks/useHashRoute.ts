import { useSyncExternalStore } from "react";

export type Route =
  | { name: "library" }
  | { name: "book"; id: string }
  | { name: "settings" };

export function parseHash(hash: string): Route {
  const clean = hash.replace(/^#\/?/, "").replace(/\/+$/, "");
  if (clean === "settings") return { name: "settings" };
  const book = clean.match(/^book\/([^/]+)$/);
  if (book) return { name: "book", id: decodeURIComponent(book[1]!) };
  return { name: "library" };
}

export function href(route: Route): string {
  switch (route.name) {
    case "library":
      return "#/";
    case "settings":
      return "#/settings";
    case "book":
      return `#/book/${encodeURIComponent(route.id)}`;
  }
}

export function navigate(route: Route): void {
  window.location.hash = href(route);
}

const subscribe = (onChange: () => void) => {
  window.addEventListener("hashchange", onChange);
  return () => window.removeEventListener("hashchange", onChange);
};

const getSnapshot = () => window.location.hash;

export function useHashRoute(): Route {
  const hash = useSyncExternalStore(subscribe, getSnapshot);
  return parseHash(hash);
}
