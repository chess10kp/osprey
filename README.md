# Jackal

## Jackal Coding Agent

**A fast native coding agent with a compatible JavaScript extension layer.**

> Native where performance matters. JavaScript where compatibility matters.

Jackal is a terminal-first coding agent with an fx-style form factor: a small native runtime that starts instantly, feels like a Unix tool, scripts cleanly (`jackal ask "..."`, structured JSON output), embeds via ACP, and stays out of your way. On top of that native core sits a lazily-started, Pi-compatible JavaScript extension host — so existing Pi extensions keep working, while performance-sensitive extensions can migrate to Jac/NA without changing the plugin model.

The product equation: **fx's form factor + Pi's ecosystem + Jac's codespace architecture.**

> **Architecture (Aug 2026):** Jackal's all-Jac harness under `app/` and custom Jac differential TUI are authoritative. The former TypeScript, Ink, and legacy Jac runtime trees have been removed; `tui/js2jac/` remains the active conversion workstream. New product development targets `app/`; see [`ROADMAP.md`](ROADMAP.md) and [`docs/NA-HARNESS-EXPLORATION.md`](docs/NA-HARNESS-EXPLORATION.md).

---

## Running Jackal

### On your machine

1. Install Node.js (the native harness uses Node for its plugin-host sidecar), then install dependencies:
   ```bash
   npm install
   ```
2. Install Jac so `jac` and `jac mcp` work (`pip install jaclang` or your team's standard installer).
3. Clone this repo, then from the repo root:

   ```bash
   ./jackal.sh
   ```

   The launcher starts the native TUI when attached to a terminal. Use `--mode normal|auto-accept|yolo|plan|ask` (or `JACKAL_MODE`) to select the development mode; Shift+Tab cycles modes in-shell. Use `/login` to save a provider API key. For headless use, run `./jackal.sh --repl` (line REPL) or `./jackal.sh --json` (JSONL protocol). Optionally symlink it with `ln -s "$(pwd)/jackal.sh" ~/.local/bin/jackal` and run `jackal` from anywhere.


Run **`/jac-doctor`** inside the running Jackal shell to confirm `jac`, MCP, and provider setup.

Patches are applied automatically via the `postinstall` script. If you skipped `npm install`, run `npx patch-package` manually.

Use **`./jackal.sh`** from the directory you want as the agent’s working tree (for example `cd` into a Jac project first, then invoke the script with an absolute path to `jackal.sh`).

### Troubleshooting

- If first launch fails because `jac` is missing, install Jac and ensure the `jac` executable is on `PATH`.
- For headless operation, use:
  ```bash
  ./jackal.sh --repl
  ./jackal.sh --json
  ```
  Or inside the running shell: `/jac-doctor`

### With Docker

If you do not want Jac installed on the host, build and run the image from this repository (includes Jac and a copy of Jackal under `/opt/jackal`):

```bash
docker build -t jackal .
docker run --rm -it \
  -v /path/to/your/jac-project:/workspace \
  -w /workspace \
  jackal
```

- **TTY:** The shell is interactive; keep `-it`.
- **API keys:** mount provider auth files or set environment variables as appropriate. Example:  
  `-v "$HOME/.jackal/auth.json:/opt/jackal/jackal/auth.json:ro"`
- **Updating Jackal:** rebuild the image after `git pull` so `/opt/jackal` picks up changes.
- **Image:** The image includes the agent runtime and Jac. Rebuild the image to change included versions.
- **Flags:** arguments after the image name are passed through to `jackal.sh`, for example:  
  `docker run --rm -it -v "$PWD:/workspace" -w /workspace jackal --plan`

---

### Quick Reference

See [`docs/QUICK_REFERENCE.md`](docs/QUICK_REFERENCE.md) for a condensed guide to slash commands, flags, and common workflows.

---


### Acknowledgements

- [Pi](https://pi.dev): For inspiring the TUI implementation
