// ESLint will not lint files outside the directory holding its configuration file, and the
// end-to-end specs live at `tests/e2e` rather than inside the frontend package. This config
// exists to raise the lint root to the repository. It owns no rules: it re-exports the block
// defined next to the dependencies it needs, which resolve from frontend/node_modules because
// bare specifiers are resolved relative to the importing module.
export { e2eConfig as default } from "./frontend/eslint.config.js";
