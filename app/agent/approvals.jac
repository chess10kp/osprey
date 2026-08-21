"""Tool approval queue (ported concept from src/agent/tool-approval.ts).

Pure logic: no I/O, no UI, no graph dependencies. The queue consumes
agent.modes.requires_approval verdicts:

  "auto"    -> executes immediately ({"decision": "auto"});
  "blocked" -> refused outright ({"decision": "blocked"});
  "confirm" -> a PendingApproval is enqueued and correlated by id;
               the caller resolves or denies via that id.

Time is caller-supplied (now_ms) so the module stays deterministic and
side-effect free. Abort paths drain the queue via cancel_all or
expire_older_than.
"""

import from .modes {
    requires_approval,
}


obj PendingApproval {
    has id: str = "",
        tool_name: str = "",
        cmd: str = "",
        mode: str = "",
        created_at: float = 0.0;
}


obj ApprovalQueue {
    has items: list[PendingApproval] = [],
        next_seq: int = 1;
}


def create_queue() -> ApprovalQueue {
    return ApprovalQueue();
}


"""Consult modes.requires_approval; enqueue only when confirmation is needed.

Returns one of:
  {"decision": "auto", ...}     — execute without prompting;
  {"decision": "blocked", ...}  — refuse the call (read-only mode rules);
  {"decision": "pending", "id"} — wait for resolve() on the given id.
"""
def request_approval(
    queue: ApprovalQueue, tool_name: str, cmd: str, mode: str, now_ms: float
) -> dict[str, any] {
    policy = requires_approval(mode, tool_name, cmd);
    if policy == "auto" {
        return {"decision": "auto", "tool_name": tool_name, "mode": mode};
    }
    if policy == "blocked" {
        return {"decision": "blocked", "tool_name": tool_name, "mode": mode};
    }
    pa = PendingApproval(
        id="approval-" + str(queue.next_seq),
        tool_name=tool_name,
        cmd=cmd.strip(),
        mode=mode,
        created_at=now_ms,
    );
    queue.next_seq += 1;
    queue.items.append(pa);
    return {"decision": "pending", "id": pa.id};
}


"""Resolve or deny a pending request by correlation id.

Returns {"id", "approved"} on success, or an error dict when the id is
unknown (already resolved, cancelled, expired, or never issued). The
matching record is removed on success.
"""
def resolve(queue: ApprovalQueue, id: str, approved: bool) -> dict[str, any] {
    idx = -1;
    for i in range(len(queue.items)) {
        if queue.items[i].id == id {
            idx = i;
            break;
        }
    }
    if idx < 0 {
        return {"error": "unknown_approval_id", "id": id};
    }
    queue.items.pop(idx);
    return {"id": id, "approved": approved};
}


"""Head of the queue (oldest pending request), or None when empty."""
def pending(queue: ApprovalQueue) -> PendingApproval | None {
    if len(queue.items) == 0 {
        return None;
    }
    return queue.items[0];
}


"""Drop every pending request without resolving; returns count dropped."""
def cancel_all(queue: ApprovalQueue) -> int {
    n = len(queue.items);
    queue.items.clear();
    return n;
}


"""Drop requests older than max_age_ms relative to now_ms; returns count.

A record survives when created_at >= now_ms - max_age_ms.
"""
def expire_older_than(queue: ApprovalQueue, now_ms: float, max_age_ms: float) -> int {
    cutoff = now_ms - max_age_ms;
    keep: list[PendingApproval] = [];
    dropped = 0;
    for rec in queue.items {
        if rec.created_at >= cutoff {
            keep.append(rec);
        } else {
            dropped += 1;
        }
    }
    queue.items = keep;
    return dropped;
}
