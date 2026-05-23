# Jackal

## Jackal Coding Agent

A Jac-native, terminal-first Jac coding agent that gives Jac developers the agentic workflow with better keyboard ergonomics, multimodal context, CLI/toolchain awareness, and Jac-specific project intelligence.

---

## Running Jackal

### On your machine

1. Install Node.js (for `npm install` in this repo).
2. Install Jac so `jac` and `jac mcp` work (`pip install jaclang` or your team’s standard installer).
3. Clone this repo, then from the repo root:

   ```bash
   npm install
   npm run build:agent   # compile the agent-next runtime
   ./jackal.sh
   ```

   `./jackal.sh` launches the **Agent-Next Jackal shell** by default. Optional: `ln -s "$(pwd)/jackal.sh" ~/.local/bin/jackal` and run `jackal` from anywhere.

Run **`/jac-doctor`** inside the running Jackal shell to confirm `jac`, MCP, and provider setup.

Patches are applied automatically via the `postinstall` script. If you skipped `npm install`, run `npx patch-package` manually.

Use **`./jackal.sh`** from the directory you want as the agent’s working tree (for example `cd` into a Jac project first, then invoke the script with an absolute path to `jackal.sh`).

### Launch modes

```bash
# Default: Agent-Next shell (recommended)
./jackal.sh

# Classic Pi TUI path (compatibility)
./jackal.sh --pi
# or
JACKAL_CLASSIC_PI=1 ./jackal.sh
```

### Troubleshooting

- If first launch fails with missing `agent-next/dist/index.js`, run:
  ```bash
  npm run build:agent
  ```
- Verify Jac + MCP wiring with:
  ```bash
  /jac-doctor
  ```

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

See `QUICK_REFERENCE.md` for a condensed guide to all slash commands, flags, and common workflows.

---

