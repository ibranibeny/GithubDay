import js from "@eslint/js";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import globals from "globals";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist", "coverage", "playwright-report", "test-results"] },
  {
    files: ["src/**/*.{ts,tsx}"],
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.browser,
    },
    plugins: {
      "react-hooks": reactHooks,
      "react-refresh": reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      "react-refresh/only-export-components": ["warn", { allowConstantExport: true }],
    },
  },
  {
    // Build and test tooling runs under Node, not the browser: vite/vitest/playwright
    // configs plus repo scripts.
    files: ["*.config.{ts,js,mjs}", "scripts/**/*.{ts,js,mjs}"],
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.node,
    },
  },
);

/**
 * The end-to-end specs live at the repository root, because one of them tests the deployed API
 * rather than this package. ESLint refuses to lint files outside its config file's directory,
 * so the root `eslint.config.js` re-exports this block; the paths below are root-relative. The
 * dependencies stay resolved from here, the only workspace with a node_modules tree.
 */
export const e2eConfig = tseslint.config({
  files: ["tests/e2e/**/*.ts"],
  extends: [js.configs.recommended, ...tseslint.configs.recommended],
  languageOptions: {
    ecmaVersion: 2022,
    // Playwright drives a browser from Node: the spec body runs in Node, and the callbacks
    // handed to page.evaluate and page.addInitScript are evaluated in the page.
    globals: { ...globals.node, ...globals.browser },
  },
});
