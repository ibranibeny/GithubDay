// Local development only. index.html loads this file before the bundle; in a container it is
// replaced by config.template.js rendered through envsubst.
//
// The identifiers below are intentionally blank so nothing real is committed. The app fails
// closed and names the empty fields until you paste your own dev app registration values in.
window.__APP_CONFIG__ = {
  environment: "local",
  tenantId: "",
  spaClientId: "",
  apiClientId: "",
  apiBaseUrl: "http://localhost:8000",
  appInsightsConnectionString: "",
};
