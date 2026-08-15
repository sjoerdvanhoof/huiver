import { expect, test } from "bun:test";
import path from "node:path";

/**
 * React has to be one copy, or nothing renders.
 *
 * react-dom installs the hooks dispatcher onto *its* React, so a component that
 * imports a second copy calls hooks against a null dispatcher and the app dies
 * on first paint with "Cannot read properties of null (reading
 * 'useSyncExternalStore')". It happened here: a version bump left a stale
 * `apps/web/node_modules/react` behind while react-dom resolved from the
 * monorepo root.
 *
 * Nothing else notices — the tests pass, the bundle builds, the types check —
 * so this asserts it directly.
 */
const nodeModulesOf = (specifier: string): string => {
  const resolved = require.resolve(specifier);
  const at = resolved.lastIndexOf(`${path.sep}node_modules${path.sep}`);
  expect(at).toBeGreaterThan(-1);
  return resolved.slice(0, at + "/node_modules".length);
};

test("react and react-dom come from the same node_modules", () => {
  const react = nodeModulesOf("react");
  for (const specifier of ["react-dom", "react-dom/client", "react/jsx-runtime"]) {
    expect(nodeModulesOf(specifier)).toBe(react);
  }
});

test("only one copy of react is installed", async () => {
  const repoRoot = path.join(import.meta.dir, "..", "..", "..");

  const found: string[] = [];
  for await (const line of new Bun.Glob("**/node_modules/react/package.json").scan({
    cwd: repoRoot,
    // `legacy/` is out of the workspace and off every resolution path the apps
    // use. The retired Expo project in particular vendors its own copies of
    // React inside its generated native projects.
    absolute: false,
  })) {
    if (line.includes("legacy/mobile/")) continue;
    found.push(line);
  }

  expect(found).toEqual(["node_modules/react/package.json"]);
});
