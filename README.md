# Jackal

## Jackal Coding Agent

A Pi-powered, terminal-native Jac coding agent that gives Jac developers the agentic workflow with better keyboard ergonomics, multimodal context, CLI/toolchain awareness, and Jac-specific project intelligence.

---

## Running Jackal

### On your machine

1. Install **Node.js** (for `npm install` in this repo).
2. Install the **Pi** CLI globally (same major line as `package.json` / this repo’s dev tooling), for example:  
   `npm install -g @earendil-works/pi-coding-agent`
3. Install **Jac** so `jac` and `jac mcp` work (`pip install jaclang` or your team’s standard installer).
4. Clone this repo, then from the repo root:

   ```bash
   npm install
   ./jackal.sh
   ```

   Optional: `ln -s "$(pwd)/jackal.sh" ~/.local/bin/jackal` and run `jackal` from anywhere.

5. In the Pi session, run **`/jac-doctor`** to confirm `jac`, MCP, and provider setup.

6. Patches are applied automatically via the `postinstall` script. If you skipped `npm install`, run `npx patch-package` manually.

Use **`./jackal.sh`** from the directory you want as the agent’s working tree (for example `cd` into a Jac project first, then invoke the script with an absolute path to `jackal.sh`).

### With Docker

If you do not want Pi or Jac installed on the host, build and run the image from this repository (includes Pi, Jac, and a copy of Jackal under `/opt/jackal`):

```bash
docker build -t jackal .
docker run --rm -it \
  -v /path/to/your/jac-project:/workspace \
  -w /workspace \
  jackal
```

- **TTY:** Pi is interactive; keep `-it`.
- **API keys:** configure Pi the same way you would locally. For example, mount an auth file if you use one:  
  `-v "$HOME/.pi/agent/auth.json:/opt/jackal/jackal/auth.json:ro"`  
  (or set whatever environment variables your provider expects).
- **Updating Jackal:** rebuild the image after `git pull` so `/opt/jackal` picks up changes.
- **Pi version:** the image defaults to `@earendil-works/pi-coding-agent@0.74.0` (see `Dockerfile`). Override when building, for example:  
  `docker build --build-arg PI_VERSION=0.74.0 -t jackal .`
- **Flags:** arguments after the image name are passed through to `jackal.sh` / `pi`, for example:  
  `docker run --rm -it -v "$PWD:/workspace" -w /workspace jackal --plan`

---

### Quick Reference

See `QUICK_REFERENCE.md` for a condensed guide to all slash commands, flags, and common workflows.

---

