"""Jackal agent session - owned ReAct loop + StreamEvent-style rendering.

History is a caller-owned list of OpenAI-shape message dicts; the loop in
llm.jac appends each turn in place. The model transport is rebuilt from the
model name on each turn (cheap) so /model swaps are immediate.
"""

import sys;
import os;
import time;
import from .llm { ToolSpec, Transport, react_loop, make_transport }
import from .tools { tool_specs }
import from .system { SYSTEM_PROMPT }

glob history: list = [],
     show_stats: bool = True,
     model: str = os.environ.get("JACKAL_MODEL", "openrouter/anthropic/claude-sonnet-5");

def set_model(name: str) -> str {
    model = name;
    return model;
}

def clear_history {
    history.clear();
}

glob _t0: float = 0.0,
     _n_tools: int = 0;

"""Render one event from the loop to stdout (line-mode UI)."""
def render_event(kind: str, data: dict) {
    out: any = sys.stdout;
    if kind == "chunk" {
        out.write(str(data.get("content", "")));
        out.flush();
    } elif kind == "tool_call" {
        out.write("\n");
        args: any = data.get("args", {});
        parts: list[str] = [];
        for pair in args.items() {
            parts.append(str(pair[0]) + "=" + str(pair[1])[:40]);
        }
        out.write(f"  * {data.get('tool')}({(', '.join(parts))[:120]})\n");
        out.flush();
        _n_tools += 1;
    } elif kind == "tool_result" {
        preview = str(data.get("result", ""))[:80].replace("\n", " ");
        out.write(f"    -> {preview}\n");
        out.flush();
    } elif kind == "error" {
        out.write(f"\n[error] {data.get('message')}\n");
        out.flush();
    }
}

"""Run one agent turn: seed history on first use, stream the loop."""
def run_turn(message: str) -> str {
    if not history {
        history.append({"role": "system", "content": SYSTEM_PROMPT});
    }
    history.append({"role": "user", "content": message});
    transport = make_transport(model);
    _t0 = time.time();
    _n_tools = 0;
    try {
        answer = react_loop(history, tool_specs(), transport, render_event);
    } finally {
        sys.stdout.write("\n");
        if show_stats {
            sys.stdout.write(
                f"  [{time.time() - _t0:.1f}s - {_n_tools} tools]\n"
            );
        }
        sys.stdout.flush();
    }
    return answer;
}
