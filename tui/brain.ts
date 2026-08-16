/** Brain subprocess: spawn `jac run main.jac -- --json`, speak JSONL. */
import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import * as readline from 'node:readline';

export class BrainProc {
  private proc: ChildProcess | null = null;
  private rl: readline.Interface | null = null;

  constructor(
    private args: string[],
    private cwd: string,
    private env: Record<string, string>,
    private onEvent: (ev: any) => void = () => {}
  ) {}

  private resolveBin(bin: string): string {
    // PATH first, then the common ~/.local/bin install location
    const local = join(homedir(), '.local', 'bin', bin);
    if (existsSync(local)) return local;
    return bin;
  }

  start(onEvent: (ev: any) => void) {
    this.onEvent = onEvent;
    this.proc = spawn(this.resolveBin(this.args[0]), this.args.slice(1), {
      cwd: this.cwd,
      env: this.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.rl = readline.createInterface({ input: this.proc.stdout! });
    this.rl.on('line', (line) => {
      line = line.trim();
      if (!line) return;
      try {
        this.onEvent(JSON.parse(line));
      } catch {
        // non-protocol stdout - ignore
      }
    });
    this.proc.stderr!.on('data', (d: Buffer) => {
      const s = d.toString().trim();
      if (s && !s.startsWith('INFO')) {
        this.onEvent({ type: 'error', message: s.slice(0, 200) });
      }
    });
    this.proc.on('error', (err) => {
      this.onEvent({ type: 'error', message: `brain spawn failed: ${err.message}` });
    });
    this.proc.on('exit', (code) => {
      if (code !== 0 && code !== null) {
        this.onEvent({ type: 'error', message: `brain exited: ${code}` });
      }
    });
  }

  send(msg: Record<string, string>) {
    this.proc?.stdin?.write(JSON.stringify(msg) + '\n');
  }

  kill() {
    this.rl?.close();
    this.proc?.kill();
  }
}
