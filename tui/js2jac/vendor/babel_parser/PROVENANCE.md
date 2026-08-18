# Vendored @babel/parser for js2jac

Hermetic parser runtime for the inbound JS/TS/JSX/TSX frontend. Installed locally
under this directory; not fetched at conversion time.

- Package: `@babel/parser`
- Version: `7.26.9` (pinned in `package.json`)
- License: MIT (see `node_modules/@babel/parser/LICENSE` after install)
- Bridge: `../../parser_bridge.mjs`

## Install (dev / editable checkout)

```bash
cd jac/jaclang/compiler/js2jac/vendor/babel_parser
npm install --ignore-scripts
```

## Bump procedure

1. Update the version in `package.json`.
2. Re-run `npm install` and record the resolved tarball hash if required by release packaging.
3. Update this file and any release payload verification scripts.

## Offline gate

Release-shaped `jac` binaries must bundle this vendor tree (or an equivalent sealed
payload) so `env -i jac tool js2jac --parse-only …` works with no network, Node,
npm, or project `node_modules`.
