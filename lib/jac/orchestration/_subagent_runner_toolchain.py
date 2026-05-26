"""Pure logic functions for subagent runner.

Ports the pure (non-async, non-Agent-dependent) functions from
src/orchestration/subagent-runner.ts to Python toolchain.

The SubagentRunner class itself stays in TypeScript — it depends on
pi-agent-core Agent, async prompts, and tool approval queues.
"""

from __future__ import annotations

from typing import Any

from _subagents_toolchain import list_subagents
from _chains_toolchain import list_chains


# ── Constants ────────────────────────────────────────────────────────────────

MAX_PARALLEL_SUBAGENTS: int = 5


# ── Summary extraction ──────────────────────────────────────────────────────


def extract_assistant_summary(messages: list[dict[str, Any]]) -> str:
    """Extract text from assistant messages in reverse order.

    Messages are dicts with ``role`` and ``content``.
    Content may be a string or a list of content parts.
    """
    parts: list[str] = []
    for msg in reversed(messages):
        if msg.get("role") != "assistant":
            continue

        content = msg.get("content")

        if isinstance(content, str) and content.strip():
            parts.insert(0, content.strip())
            continue

        if isinstance(content, list):
            text_chunks: list[str] = []
            for part in content:
                if isinstance(part, str):
                    text_chunks.append(part)
                elif isinstance(part, dict) and "text" in part:
                    text_chunks.append(str(part.get("text", "")))
            text = "\n".join(text_chunks).strip()
            if text:
                parts.insert(0, text)

    return "\n\n".join(parts).strip() or "(no subagent output)"


# ── Tool call counting ──────────────────────────────────────────────────────


def count_tool_calls(messages: list[dict[str, Any]]) -> int:
    """Count tool call content parts across all messages."""
    count = 0
    for msg in messages:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            if (
                isinstance(part, dict)
                and part.get("type") == "toolCall"
            ):
                count += 1
    return count


# ── Chain template substitution ─────────────────────────────────────────────


def substitute_chain_template(template: str, task: str, previous: str) -> str:
    """Replace ``{task}`` and ``{previous}`` placeholders in a template."""
    return template.replace("{task}", task).replace("{previous}", previous)


# ── Chain step prompt building ──────────────────────────────────────────────


def build_step_prompt(
    step: dict[str, Any],
    task: str,
    previous: str,
) -> str:
    """Build the prompt for a single chain step.

    ``step`` is a dict with keys: ``task`` (template), ``reads`` (optional
    list of file paths), ``output`` (optional artifact name).
    """
    step_task = step.get("task", "")
    prompt = substitute_chain_template(step_task, task, previous)

    reads = step.get("reads")
    if reads and isinstance(reads, list) and len(reads) > 0:
        read_lines = "\n".join(f"- {f}" for f in reads)
        prompt = (
            "Read these artifacts from the prior step before continuing:\n"
            f"{read_lines}\n\n{prompt}"
        )

    output = step.get("output")
    if output:
        prompt = (
            f"{prompt}\n\n"
            f"Write your final answer for the next step as markdown "
            f"suitable for '{output}'."
        )

    return prompt


# ── Subagent tool description ───────────────────────────────────────────────


def build_subagent_tool_description(
    cwd: str,
    agent_dir: str | None = None,
) -> str:
    """Build the tool description for the ``agent`` subagent tool.

    Lists available agents (up to 12) and chains (up to 8).
    """
    agents = list_subagents(cwd, agent_dir)
    chains = list_chains(cwd, agent_dir)

    agent_lines = "\n".join(
        f"- {a['name']}: {a['description']}" for a in agents[:12]
    ) or "(none loaded)"

    chain_lines = "\n".join(
        f"- {c['name']}: {c['description']}" for c in chains[:8]
    ) or "(none loaded)"

    return (
        "Delegate a focused task to a specialized subagent in an isolated context.\n"
        "Only the final summary is returned. Up to 5 subagents may run in parallel.\n"
        "\n"
        "Available agents:\n"
        f"{agent_lines}\n"
        "\n"
        "Available chains (pass as `chain`):\n"
        f"{chain_lines}"
    )
