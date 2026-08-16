/** Types shared by the TUI components. */
export type Entry =
  | { kind: 'user'; text: string }
  | { kind: 'assistant'; text: string }
  | { kind: 'tool'; text: string }
  | { kind: 'info'; text: string }
  | { kind: 'error'; text: string };

export type BrainEvent =
  | { type: 'session_ready'; model: string; cwd: string }
  | { type: 'chunk'; content: string }
  | { type: 'tool_call'; tool: string; args: string }
  | { type: 'tool_result'; tool: string; result: string }
  | { type: 'turn_end'; secs: number; tools: number }
  | { type: 'info'; text: string }
  | { type: 'error'; message: string }
  | { type: 'session_end' };
