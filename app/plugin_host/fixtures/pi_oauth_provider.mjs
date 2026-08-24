/**
 * Fixture: attempts registerProvider with an `oauth` block. The host cannot
 * run interactive OAuth /login flows (COMPAT_TIER T2-partial honesty), so
 * activate() throws and the extension fails loud at ext_load with a clear
 * capability error. Never loads with a dead oauth config.
 */
export default function activate(pi) {
  pi.registerProvider({
    name: "corporate-ai",
    baseUrl: "https://ai.corp.example.com",
    models: ["corp-large"],
    oauth: {
      name: "Corporate AI (SSO)",
      async login() {
        return {};
      },
      async refreshToken(creds) {
        return creds;
      },
      getApiKey() {
        return "";
      },
    },
  });
}
