---
name: jackal-auth
description: Use when implementing authentication, login, signup, sessions, logout, protected routes, or OAuth (Google/SSO) in a Jac/Jaseci app. Provides ready-to-adapt Jac templates built on `@jac/runtime`'s `jacSignup` / `jacLogin` / `jacLogout` / `jacIsLoggedIn`.
---

# Jackal Auth Recipe

When the user asks to add authentication to a Jac app, do **not** invent
a fresh auth scheme. Pick the closest template in `assets/` and adapt it.

All templates use Jac's built-in client auth runtime — `jacSignup`,
`jacLogin`, `jacLogout`, `jacIsLoggedIn` from `@jac/runtime` — so sessions,
cookies, and storage are handled by the platform.

## 1. Inspect the project

1. Look for an existing `cl` (client) section and any `@jac/runtime` imports.
2. Look for existing auth state (`isLoggedIn`, `username`, `Login` page,
   `ProtectedRoute`).
3. Check whether the app already uses React Router (`Router`, `Routes`, `Route`).
4. Check for any OAuth/SSO config (`google`, `oauth`, `callback`).

## 2. Pick a template

| Situation                                                        | Use                                              |
| ---------------------------------------------------------------- | ------------------------------------------------ |
| Single-page app, no router, just toggle login ↔ dashboard        | `assets/auth-simple.jac`                         |
| Single-page app with slightly cleaner client-utils style          | `assets/auth-basic.jac`                          |
| Full-stack app with React Router, walkers, and protected routes  | `assets/auth-fullstack-todo.jac`                 |
| App that needs Google OAuth / SSO via the backend                 | `assets/google-oauth-example/` (multi-file)      |

If none clearly fits, ask the user one clarifying question before generating.

## 3. Adapt, do not paste

- Read the chosen template via `read`.
- Reuse the project's existing components/pages/nodes; only introduce new ones
  that are missing.
- Strip styling/layout that does not apply, but keep the auth flow intact:
  `jacIsLoggedIn` mount check → login/signup forms → `jacLogin`/`jacSignup`
  → routing/state update → `jacLogout`.
- For the full-stack template, keep the walker definitions (`create_todo`, etc.)
  as a model for how protected backend operations are structured.

## 4. Verify

After writing the new code:

1. Run the `validate_jac` MCP tool on every modified `.jac` file.
2. If errors → invoke `fix-skill` (cap 3 attempts).

## 5. Document

Update `AGENTS.md` (create the file if missing) with a short
`## Authentication` section describing:

- Which template was used as the starting point.
- Where the login/signup UI lives.
- How to gate a new page or walker on auth.

## Anti-patterns

- ❌ Reimplementing `jacLogin`/`jacSignup` against a custom backend when the
  built-in runtime already covers it.
- ❌ Storing `password` in client state after login — clear it like the
  templates do.
- ❌ Skipping the `jacIsLoggedIn()` mount check; the page will flash unauth UI.
- ❌ Bolting auth onto a CLI-only project that has no `cl` section. Ask first.

## Asset index

- `assets/auth-simple.jac` — minimal state-based login/signup/dashboard toggle
- `assets/auth-basic.jac` — same idea, slightly cleaner separation
- `assets/auth-fullstack-todo.jac` — React Router + protected routes + walkers
- `assets/google-oauth-example/` — Google OAuth via backend SSO
