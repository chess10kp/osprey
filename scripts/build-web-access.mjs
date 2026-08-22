// Bundle the pi-web-access library surface (raw .ts npm package) into
// dist/web-access.mjs so the runtime can import it without a TS loader.
// Node refuses to type-strip files under node_modules, so this build step is
// required; see scripts/web-access-entry.ts for the exported surface.
import { build } from "esbuild";

await build({
  entryPoints: ["scripts/web-access-entry.ts"],
  outfile: "dist/web-access.mjs",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  sourcemap: false,
  legalComments: "none",
  // Peer deps resolve from jackal's own node_modules at runtime.
  external: ["@earendil-works/*"],
  logLevel: "warning",
});
