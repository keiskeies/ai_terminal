// tools/platform.ts - W8 mobile/desktop tool subset profiles
//
// Mobile (iOS/Android) keeps the Dart engine; the Node side still reports
// which tools are "mobile-safe" so the Flutter routing layer can make an
// informed decision. Desktop gets the full registry.
//
// Mobile-safe: read-only + fetch_url + web_search (network, no local FS writes).
// Desktop-only: write/patch/move/delete (local FS mutations), local_exec (pty).

export type PlatformProfile = "desktop" | "mobile";

/** Tools that are safe to use on mobile (read-only / network, no local FS mutations). */
export const MOBILE_SAFE_TOOLS: ReadonlySet<string> = new Set([
  "local_file_read",   // read-only
  "local_dir_list",    // read-only
  "local_file_search", // read-only
  "fetch_url",         // network
  "web_search",        // network
]);

/** Tools that are desktop-only (local FS writes, pty exec). */
export const DESKTOP_ONLY_TOOLS: ReadonlySet<string> = new Set([
  "local_file_write",
  "local_file_patch",
  "local_file_move",
  "local_file_delete",
  "local_exec",
]);

/**
 * Given a platform, returns the set of tool names that should be registered.
 * "desktop" (default) → all tools. "mobile" → MOBILE_SAFE_TOOLS only.
 */
export function toolsForPlatform(platform: PlatformProfile, allTools: string[]): string[] {
  if (platform === "mobile") {
    return allTools.filter((n) => MOBILE_SAFE_TOOLS.has(n));
  }
  // desktop: everything
  return allTools;
}
