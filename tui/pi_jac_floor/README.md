# pi-tui Jac floor

Jac port of `@earendil-works/pi-tui` under `src/`, plus runtime smokes and an interactive demo.

## Docs

- [Differential rendering](docs/DIFFERENTIAL_RENDERING.md) — flat-line diff model, in-place vs append vs shift, Textual comparison, regression smokes

## Check (static validation)

```bash
cd tui/pi_jac_floor
jac check .                    # whole project
jac check src/tui.jac          # single module
```

## Interactive demo

Uses the alternate screen buffer, clears on start, pins the prompt to the
bottom of the terminal, and `/clear` wipes the screen (not just the log text).

```bash
# Interactive demo (needs a real TTY)
jac run demo_playground.jac
```

# Default project entry (smoke_pure.jac)
jac run

# All runtime smokes
for f in smoke_*.jac; do jac run "$f"; done
```

Jac compiles on the fly (cache: `.jac/cache/`). No separate build step.

Force recompile:

```bash
jac run --no-cache demo_playground.jac
```

## Clean cache

```bash
jac clean --cache
```

## Regenerate from TypeScript source

```bash
./tui/scripts/js2jac_pi_tui.sh
```
