"""Network seams owned by the runtime loop, not the auth data layer."""

# ── Network seam (filled by the runtime loop, NOT here) ────────────────
#
# Both functions below would perform HTTP/browser I/O against provider
# OAuth endpoints. That belongs to the LLM runtime loop, which owns fetch,
# local callback servers, and browser launch. They therefore return the
# explicit not-supported envelope documented on each signature; callers
# must treat ok=False + error="network_not_supported" as "ask the host
# runtime to perform this step, then persist returned credentials via
# credential_set/save_auth_file".


"""SEAM: exchange an OAuth refresh token for fresh credentials.

Would POST the refresh grant to the provider's token endpoint. Returns
{"ok": False, "error": "network_not_supported", "provider": <id>,
"detail": "..."}; the runtime loop fills this by performing the refresh
and handing back a validated credential dict to store."""
def oauth_refresh_credentials(provider_id: str, credentials: dict) -> dict {
    return {
        "ok": False,
        "error": "network_not_supported",
        "provider": provider_id,
        "detail": (
            "OAuth token refresh needs HTTP against the provider token "
            "endpoint; the runtime loop must perform it and persist the "
            "resulting credential."
        ),
    };
}


"""SEAM: start an interactive OAuth login for a provider.

Would open the authorize URL (and possibly a local callback server).
Returns {"ok": False, "error": "network_not_supported", "provider": <id>,
"detail": "..."}; the runtime loop drives the browser dance and hands back
credentials to store."""
def oauth_start_login(provider_id: str) -> dict {
    return {
        "ok": False,
        "error": "network_not_supported",
        "provider": provider_id,
        "detail": (
            "Interactive OAuth login needs a browser + callback server; "
            "the runtime loop must drive it and persist the resulting "
            "credential."
        ),
    };
}
