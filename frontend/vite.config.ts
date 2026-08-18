import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    // Without this vitest stubs every CSS request, and the dashboard test asserts on the real
    // stylesheet text (imported with ?raw) to prove focus states ship.
    css: true,
  },
});
