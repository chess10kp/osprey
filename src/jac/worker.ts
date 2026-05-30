// ────────────────────────────────────────────────────────────────────────────
// Persistent Python worker — replaces per-call spawnSync with a long-lived
// child process communicating over JSON-RPC (newline-delimited JSON).
//
// The worker (lib/jac/bridge/worker.py) stays alive for the entire session.
// Each call is ~1-3ms (pipe write + read) instead of 20-50ms (python spawn).
// ────────────────────────────────────────────────────────────────────────────

import { spawn, type ChildProcess } from "node:child_process";
import { join } from "node:path";
import { createInterface } from "node:readline";

const BRIDGE_REL = "lib/jac/bridge/worker.py";

interface PendingCall {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
}

let _proc: ChildProcess | null = null;
let _seq = 0;
const _pending = new Map<number, PendingCall>();
let _initPromise: Promise<void> | null = null;
let _shuttingDown = false;

function resolveJackalRoot(): string {
  const env = process.env.JACKAL_ROOT;
  if (env) return env;
  // Walk up from cwd looking for lib/jac/bridge/worker.py
  let dir = process.cwd();
  for (let i = 0; i < 20; i++) {
    if (require("fs").existsSync(join(dir, BRIDGE_REL))) return dir;
    const parent = join(dir, "..");
    if (parent === dir) break;
    dir = parent;
  }
  // Fallback: JACKAL_AGENT_DIR or the jackal repo root
  return process.env.JACKAL_AGENT_DIR ?? process.cwd();
}

function resolvePython(): string {
  return process.env.JACKAL_TOOLCHAIN_PYTHON || "python3";
}

/** Start the worker process and wait for its readiness signal. */
async function ensureWorker(): Promise<void> {
  if (_proc && !_proc.killed) return;

  const root = resolveJackalRoot();
  const script = join(root, BRIDGE_REL);
  const python = resolvePython();

  _initPromise = new Promise<void>((resolveInit, rejectInit) => {
    const proc = spawn(python, [script], {
      cwd: root,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });

    let ready = false;
    let stderrBuf = "";

    proc.on("error", (err) => {
      if (!ready) rejectInit(err);
    });

    proc.on("exit", (code, signal) => {
      _proc = null;
      _initPromise = null;
      if (!ready) {
        rejectInit(new Error(`worker exited before ready (code=${code}, signal=${signal}, stderr=${stderrBuf})`));
      } else if (!_shuttingDown) {
        // Worker died unexpectedly — reject all pending calls
        for (const [id, pending] of _pending) {
          pending.reject(new Error(`worker exited (code=${code})`));
          _pending.delete(id);
        }
      }
    });

    proc.stderr?.on("data", (chunk: Buffer) => {
      stderrBuf += chunk.toString();
      // Keep last 2KB for diagnostics
      if (stderrBuf.length > 2048) stderrBuf = stderrBuf.slice(-2048);
    });

    const rl = createInterface({ input: proc.stdout! });
    rl.on("line", (line: string) => {
      if (!line.trim()) return;
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(line);
      } catch {
        return;
      }

      // Readiness signal: no id, result="ready"
      if (!ready && msg.result === "ready" && msg.id === undefined) {
        ready = true;
        _proc = proc;
        resolveInit();
        return;
      }

      // JSON-RPC response
      const id = typeof msg.id === "number" ? msg.id : null;
      if (id !== null && _pending.has(id)) {
        const pending = _pending.get(id)!;
        _pending.delete(id);
        if (msg.error) {
          const errData = msg.error as Record<string, unknown>;
          const trace = (errData.data as Record<string, unknown>)?.trace;
          const errMsg = String(errData.message ?? "unknown error");
          pending.reject(new Error(trace ? `${errMsg}\n${trace}` : errMsg));
        } else {
          pending.resolve(msg.result);
        }
      }
    });
  });

  await _initPromise;
}

/** Send a JSON-RPC request and return the response result. */
async function rpc(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
  if (_shuttingDown) throw new Error("worker is shutting down");
  await ensureWorker();

  return new Promise<unknown>((resolve, reject) => {
    const id = ++_seq;
    _pending.set(id, { resolve, reject });

    const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";

    _proc!.stdin!.write(msg, (err) => {
      if (err) {
        _pending.delete(id);
        reject(err);
      }
    });
  });
}

// ── Public API ──────────────────────────────────────────────────────────────

/** Call the persistent worker with an op and params. Returns the `result` field. */
export async function workerCall<T = unknown>(
  op: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  const response = await rpc(op, params) as Record<string, unknown> | undefined;
  // The worker wraps dispatch results in {"result": <payload>}, so we unwrap
  if (response && typeof response === "object" && "result" in response) {
    return response.result as T;
  }
  // Some ops return the value directly
  return response as T;
}

/**
 * Synchronous bridge call — uses the persistent worker under the hood.
 *
 * This replaces `invokeBridgeSync`. It waits for the worker's response,
 * blocking the current async context but NOT the Node event loop.
 * The calling code in jac-bridge.ts awaits this in an async context.
 */
export async function workerBridgeCall<T = unknown>(
  request: Record<string, unknown>,
): Promise<T> {
  const op = request.op as string;
  if (!op) throw new Error("missing 'op' in bridge request");

  // Strip 'op' from params — it becomes the JSON-RPC method
  const params = { ...request };
  delete params.op;

  const response = await rpc(op, params) as Record<string, unknown> | undefined;

  // Dispatch responses are wrapped in {"result": <payload>}
  if (response && typeof response === "object" && "result" in response) {
    // Parse the payload like parseBridgeLine does
    const result = response.result;
    if (result && typeof result === "object" && "ok" in (result as Record<string, unknown>)) {
      const r = result as Record<string, unknown>;
      if (r.ok === false) {
        throw new Error(String(r.error ?? "bridge error"));
      }
      // Return the unwrapped payload (everything except 'ok')
      const payload = { ...r };
      delete payload.ok;
      return (Object.keys(payload).length === 1 ? Object.values(payload)[0] : payload) as T;
    }
    return result as T;
  }

  return response as T;
}

/** Gracefully shut down the worker. Call on app exit. */
export async function shutdownWorker(): Promise<void> {
  _shuttingDown = true;
  if (!_proc || _proc.killed) return;
  try {
    await rpc("shutdown");
  } catch {
    /* swallow — worker may already be dead */
  }
  try {
    _proc.kill();
  } catch {
    /* swallow */
  }
  _proc = null;
}
