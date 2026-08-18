// Rendered to /config.js at container start by envsubst (Task 9), so one image serves every
// environment. Every value here is a public client identifier or endpoint - never put a client
// secret, connection key, or token in this file.
window.__APP_CONFIG__ = {
  environment: "${APP_ENVIRONMENT}",
  tenantId: "${ENTRA_TENANT_ID}",
  spaClientId: "${ENTRA_SPA_CLIENT_ID}",
  apiClientId: "${ENTRA_API_CLIENT_ID}",
  apiBaseUrl: "${API_BASE_URL}",
  appInsightsConnectionString: "${APPLICATIONINSIGHTS_CONNECTION_STRING}",
};
