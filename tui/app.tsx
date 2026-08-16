/** Main Ink app: spawns the brain, renders the event stream. */
import React, { useEffect, useRef, useState, useCallback } from 'react';
import { Box, Text, Static, useInput } from 'ink';
import { BrainProc } from './brain.ts';
import type { Entry, BrainEvent } from './types.ts';

export function App(props: { cwd: string; spawnArgs: string[]; env: Record<string, string> }) {
  const [entries, setEntries] = useState<Entry[]>([]);
  const [streaming, setStreaming] = useState<string | null>(null);
  const [pendingTools, setPendingTools] = useState<{ tool: string; args: string }[]>([]);
  const [model, setModel] = useState('…');
  const [busy, setBusy] = useState(false);
  const brainRef = useRef<BrainProc | null>(null);

  const addEntry = useCallback((e: Entry) => setEntries((prev) => [...prev, e]), []);

  useEffect(() => {
    const brain = new BrainProc(props.spawnArgs, props.cwd, props.env);
    brainRef.current = brain;
    brain.start((ev: BrainEvent) => {
      switch (ev.type) {
        case 'session_ready':
          setModel(ev.model);
          break;
        case 'chunk':
          setStreaming((prev) => (prev ?? '') + ev.content);
          break;
        case 'tool_call': {
          const args = typeof ev.args === 'string' ? ev.args : JSON.stringify(ev.args);
          setPendingTools((prev) => [...prev, { tool: ev.tool, args: args.slice(0, 80) }]);
          break;
        }
        case 'tool_result':
          setPendingTools((prev) => prev.filter((t, i) => !(i === prev.length - 1 && t.tool === ev.tool)));
          addEntry({ kind: 'tool', text: `${ev.tool} → ${ev.result.slice(0, 160).replace(/\n/g, ' ')}` });
          break;
        case 'turn_end':
          setStreaming((prev) => {
            if (prev) addEntry({ kind: 'assistant', text: prev });
            return null;
          });
          setPendingTools([]);
          setBusy(false);
          break;
        case 'info':
          addEntry({ kind: 'info', text: ev.text });
          break;
        case 'error':
          addEntry({ kind: 'error', text: ev.message });
          setBusy(false);
          break;
        case 'session_end':
          brain.kill();
          process.exit(0);
      }
    });
    return () => brain.kill();
  }, []);

  const submit = (text: string) => {
    const brain = brainRef.current;
    if (!brain) return;
    addEntry({ kind: 'user', text });
    if (text.startsWith('/')) {
      brain.send({ type: 'command', text });
    } else {
      setBusy(true);
      brain.send({ type: 'user', text });
    }
  };

  return (
    <Box flexDirection="column">
      <Static items={entries}>
        {(e, i) => <EntryLine key={i} entry={e} />}
      </Static>

      {streaming !== null && streaming !== '' && (
        <Box flexDirection="column" paddingLeft={2}>
          <Text color="magenta">assistant</Text>
          <Text>{streaming.slice(-2000)}</Text>
        </Box>
      )}
      {pendingTools.map((t, i) => (
        <Box key={i} paddingLeft={2}>
          <Text color="cyan">  * {t.tool}({t.args})</Text>
        </Box>
      ))}

      <Box borderStyle="round" borderColor={busy ? 'yellow' : 'green'} flexDirection="column">
        {busy ? (
          <Box paddingLeft={1}>
            <Text color="yellow">● working…</Text>
          </Box>
        ) : (
          <Input onSubmit={submit} model={model} />
        )}
      </Box>
      <Box>
        <Text dimColor>{props.cwd} · /model /clear /help /exit · Ctrl+C quit</Text>
      </Box>
    </Box>
  );
}

/** Hand-rolled single-line input (ink's useInput, no extra deps). */
function Input(props: { onSubmit: (v: string) => void; model: string }) {
  const [buf, setBuf] = useState('');
  const [history, setHistory] = useState<string[]>([]);
  const [hIdx, setHIdx] = useState(-1);

  useInput((input, key) => {
    // Paste / coalesced chunks can carry embedded newlines; ink parses one
    // keypress per data event, so a trailing \r would be lost. Split here.
    if (key.return || input.includes('\r') || input.includes('\n')) {
      const before = key.return ? '' : input.split(/[\r\n]/)[0];
      const v = before ? buf + before : buf;
      setBuf('');
      setHistory((h) => [v, ...h]);
      setHIdx(-1);
      if (v.trim()) props.onSubmit(v.trim());
    } else if (key.upArrow) {
      const v = buf;
      setBuf('');
      setHistory((h) => [v, ...h]);
      setHIdx(-1);
      if (v.trim()) props.onSubmit(v.trim());
    } else if (key.upArrow) {
      if (history.length) {
        const i = Math.min(hIdx + 1, history.length - 1);
        setHIdx(i);
        setBuf(history[i]);
      }
    } else if (key.downArrow) {
      if (hIdx > 0) {
        setHIdx(hIdx - 1);
        setBuf(history[hIdx - 1]);
      } else {
        setHIdx(-1);
        setBuf('');
      }
    } else if (key.backspace || key.delete) {
      setBuf((b) => b.slice(0, -1));
    } else if (key.ctrl && (input === 'u' || input === 'U')) {
      setBuf('');
    } else if (input && !key.ctrl && !key.meta && !key.escape) {
      setBuf((b) => b + input);
    }
  });

  return (
    <Box paddingLeft={1}>
      <Text color="green">{props.model} &gt; </Text>
      <Text>{buf}</Text>
      <Text inverse> </Text>
    </Box>
  );
}

function EntryLine(props: { entry: Entry }) {
  const { entry } = props;
  if (entry.kind === 'user') {
    return (
      <Box flexDirection="column" paddingLeft={2}>
        <Text color="green" bold>you</Text>
        <Text>{entry.text}</Text>
      </Box>
    );
  }
  if (entry.kind === 'assistant') {
    return (
      <Box flexDirection="column" paddingLeft={2}>
        <Text color="magenta">assistant</Text>
        <Text>{entry.text}</Text>
      </Box>
    );
  }
  if (entry.kind === 'tool') {
    return (
      <Box paddingLeft={2}>
        <Text color="cyan">  ✔ {entry.text.slice(0, 200)}</Text>
      </Box>
    );
  }
  if (entry.kind === 'error') {
    return (
      <Box paddingLeft={2}>
        <Text color="red">✖ {entry.text}</Text>
      </Box>
    );
  }
  return (
    <Box paddingLeft={2}>
      <Text dimColor>  {entry.text}</Text>
    </Box>
  );
}
