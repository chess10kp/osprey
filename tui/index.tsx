#!/usr/bin/env node
/** Jackal TUI - thin Ink client over the JSONL brain protocol.
 *
 *   node --import tsx tui/index.tsx [target-dir]
 *
 * Spawns `jac run <repo>/app/main.jac -- --json` in the target directory,
 * renders the event stream, sends input. The brain holds all state; if
 * this UI dies the brain can be re-attached.
 */
import { resolve, join } from 'node:path';
import { render } from 'ink';
import React from 'react';
import { App } from './app.tsx';
import { brainEnv } from './env.ts';

const targetDir = process.argv[2] ? resolve(process.argv[2]) : process.cwd();
const here = import.meta.dirname ?? new URL('.', import.meta.url).pathname;
const repoDir = resolve(here, '..');
const brain = join(repoDir, 'app', 'main.jac');

render(<App cwd={targetDir} spawnArgs={['jac', 'run', brain, '--', '--json']} env={brainEnv()} />);
