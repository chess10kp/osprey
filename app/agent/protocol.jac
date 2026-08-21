"""Typed async seam between Jac agent brain and UI (OSPUI-P0-PLAN Unit 9).

Versioned command/event envelopes, bounded queues, text-delta coalescing, and
turn/subprocess-group cancellation. External workers enqueue immutable events;
they never mutate the UI graph.
"""

import from ui.screen {
    ShellScreen,
}


obj Envelope {
    has version: int = 1,
        session_id: str = "",
        request_id: str = "",
        turn_id: str = "",
        tool_id: str = "",
        sequence: int = 0,
        correlation_id: str = "",
        kind: str = "",
        payload: dict[str, any] = {};
}


obj QueueStats {
    has depth: int = 0,
        dropped: int = 0,
        coalesced: int = 0;
}


obj BoundedEventQueue {
    has capacity: int = 256,
        items: list[Envelope] = [],
        dropped: int = 0,
        coalesced: int = 0;
}


obj CancelToken {
    has turn_id: str = "",
        group_id: str = "",
        cancelled: bool = False;
}


obj InProcessAdapter {
    has queue: BoundedEventQueue,
        session_id: str = "",
        last_sequence: int = 0,
        cancelled_turns: set[str] = set(),
        cancelled_groups: set[str] = set();
}


def create_queue(capacity: int = 256) -> BoundedEventQueue {
    return BoundedEventQueue(capacity=capacity);
}


def create_adapter(session_id: str, capacity: int = 256) -> InProcessAdapter {
    return InProcessAdapter(
        session_id=session_id,
        queue=create_queue(capacity),
    );
}


def make_envelope(
    kind: str,
    payload: dict[str, any] | None = None,
    session_id: str = "",
    request_id: str = "",
    turn_id: str = "",
    tool_id: str = "",
    sequence: int = 0,
    correlation_id: str = "",
    version: int = 1,
) -> Envelope {
    data: dict[str, any] = {};
    if payload is not None {
        data = payload;
    }
    return Envelope(
        version=version,
        session_id=session_id,
        request_id=request_id,
        turn_id=turn_id,
        tool_id=tool_id,
        sequence=sequence,
        correlation_id=correlation_id,
        kind=kind,
        payload=data,
    );
}


def queue_stats(queue: BoundedEventQueue) -> QueueStats {
    return QueueStats(
        depth=len(queue.items),
        dropped=queue.dropped,
        coalesced=queue.coalesced,
    );
}


"""True when two envelopes are compatible text deltas that may coalesce."""
def can_coalesce(a: Envelope, b: Envelope) -> bool {
    if a.kind != "text_delta" or b.kind != "text_delta" {
        return False;
    }
    if a.turn_id != b.turn_id or a.session_id != b.session_id {
        return False;
    }
    if a.correlation_id != b.correlation_id {
        return False;
    }
    return True;
}


"""Merge two compatible text-delta envelopes into one."""
def coalesce_text_deltas(a: Envelope, b: Envelope) -> Envelope {
    left = str(a.payload.get("text", ""));
    right = str(b.payload.get("text", ""));
    seq = b.sequence if b.sequence >= a.sequence else a.sequence;
    return make_envelope(
        kind="text_delta",
        payload={"text": left + right},
        session_id=a.session_id,
        request_id=b.request_id if b.request_id else a.request_id,
        turn_id=a.turn_id,
        tool_id=a.tool_id,
        sequence=seq,
        correlation_id=a.correlation_id,
        version=a.version,
    );
}


"""Enqueue an envelope, coalescing compatible text deltas when possible."""
def enqueue(queue: BoundedEventQueue, envelope: Envelope) -> bool {
    if queue.items {
        last = queue.items[len(queue.items) - 1];
        if can_coalesce(last, envelope) {
            queue.items[len(queue.items) - 1] = coalesce_text_deltas(
                last, envelope
            );
            queue.coalesced += 1;
            return True;
        }
    }
    if len(queue.items) >= queue.capacity {
        # Drop oldest to make room (backpressure with drop-oldest policy).
        queue.items.pop(0);
        queue.dropped += 1;
    }
    queue.items.append(envelope);
    return True;
}


"""Dequeue the next envelope in structural order, or None if empty."""
def dequeue(queue: BoundedEventQueue) -> Envelope | None {
    if not queue.items {
        return None;
    }
    return queue.items.pop(0);
}


"""Cancel a turn; subsequent completion events must carry correlation."""
def cancel_turn(adapter: InProcessAdapter, turn_id: str) -> CancelToken {
    token = CancelToken(turn_id=turn_id, cancelled=True);
    adapter.cancelled_turns.add(turn_id);
    enqueue(
        adapter.queue,
        make_envelope(
            kind="turn_cancelled",
            session_id=adapter.session_id,
            turn_id=turn_id,
            correlation_id=turn_id,
            payload={"reason": "cancelled"},
        ),
    );
    return token;
}


"""Cancel a subprocess/tool group with correlated completion events."""
def cancel_group(adapter: InProcessAdapter, group_id: str) -> CancelToken {
    token = CancelToken(group_id=group_id, cancelled=True);
    adapter.cancelled_groups.add(group_id);
    enqueue(
        adapter.queue,
        make_envelope(
            kind="group_cancelled",
            session_id=adapter.session_id,
            correlation_id=group_id,
            tool_id=group_id,
            payload={"group_id": group_id, "reason": "cancelled"},
        ),
    );
    return token;
}


"""Drive one envelope into the product TUI shell (in-process adapter)."""
def drive_screen(adapter: InProcessAdapter, shell: any, envelope: Envelope) {
    _ = adapter;
    if shell is None {
        raise ValueError("drive_screen requires a shell");
    }
    if not isinstance(shell, ShellScreen) {
        raise TypeError("drive_screen expects a ShellScreen");
    }
    if envelope.kind == "text_delta" {
        text = str(envelope.payload.get("text", ""));
        if text {
            # Streaming text updates transcript observation revision only;
            # prompt insert is reserved for user input envelopes.
            shell.transcript.observed_revision += 1;
            if not shell.transcript.source_id {
                shell.transcript.source_id = envelope.turn_id;
            }
        }
    } elif envelope.kind == "status" {
        phase = str(envelope.payload.get("phase", ""));
        if phase {
            shell.status.phase = phase;
        }
    } elif envelope.kind == "insert_text" {
        text = str(envelope.payload.get("text", ""));
        # Session is owned by the shell host; insert against prompt directly.
        shell.prompt.draft = shell.prompt.draft + text;
    }
}
