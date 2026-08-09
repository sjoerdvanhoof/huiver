import { useSyncExternalStore } from "react";

/** Settings is a sheet, not a destination — there are only two routes. */
export type Route = { name: "library" } | { name: "book"; id: string };

export function parseHash(hash: string): Route {
  const clean = hash.replace(/^#\/?/, "").replace(/\/+$/, "");
  const book = clean.match(/^book\/([^/]+)$/);
  if (book) return { name: "book", id: decodeURIComponent(book[1]!) };
  return { name: "library" };
}

export function href(route: Route): string {
  switch (route.name) {
    case "library":
      return "#/";
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
