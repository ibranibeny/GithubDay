import { useSyncExternalStore } from "react";

const QUERY = "(prefers-reduced-motion: reduce)";

function subscribe(onChange: () => void): () => void {
  if (typeof window.matchMedia !== "function") {
    return () => {};
  }
  const list = window.matchMedia(QUERY);
  list.addEventListener("change", onChange);
  return () => list.removeEventListener("change", onChange);
}

function read(): boolean {
  // jsdom and older embedded webviews ship without matchMedia; motion stays on rather than off.
  return typeof window.matchMedia === "function" && window.matchMedia(QUERY).matches;
}

/** Charts read this to disable their entry animation, matching the CSS media query. */
export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(subscribe, read, () => false);
}
