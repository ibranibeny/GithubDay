/** The app publishes its Entra configuration on `window`; the specs set it before load. */
interface Window {
  __APP_CONFIG__?: unknown;
}
