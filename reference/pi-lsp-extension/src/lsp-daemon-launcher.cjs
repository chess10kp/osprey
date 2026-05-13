/**
 * Daemon launcher — loads lsp-daemon.ts via jiti.
 *
 * Usage: node lsp-daemon-launcher.cjs <jitiPath> <daemonScript> <socketPath> <command> [args...]
 *
 * This tiny JS file exists because the daemon runs as a detached process
 * and can't rely on --import hooks. It uses the jiti path resolved at
 * spawn time from the parent's module context.
 */
const [,, jitiPath, daemonScript, ...rest] = process.argv;

if (!jitiPath || !daemonScript) {
  console.error("Usage: node lsp-daemon-launcher.cjs <jitiPath> <daemonScript> <socketPath> <command> [args...]");
  process.exit(1);
}

// Override argv so the daemon sees: [node, daemonScript, socketPath, command, ...args]
process.argv = [process.argv[0], daemonScript, ...rest];

const { createJiti } = require(jitiPath);
const jiti = createJiti(daemonScript);
jiti(daemonScript);
