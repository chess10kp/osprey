/** Resolve provider env for the brain process. Env wins; ~/.pi/agent/auth.json
 *  is the fallback so dogfooding needs zero setup. */
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export function brainEnv(): Record<string, string> {
  const env: Record<string, string> = { ...process.env } as Record<string, string>;
  const authPath = join(homedir(), '.pi', 'agent', 'auth.json');
  if (!existsSync(authPath)) return env;
  try {
    const auth = JSON.parse(readFileSync(authPath, 'utf8'));
    if (!env.OPENROUTER_API_KEY && auth.openrouter?.key) env.OPENROUTER_API_KEY = auth.openrouter.key;
    if (!env.DEEPSEEK_API_KEY && auth.deepseek?.key) env.DEEPSEEK_API_KEY = auth.deepseek.key;
  } catch { /* unreadable auth - env only */ }
  return env;
}
