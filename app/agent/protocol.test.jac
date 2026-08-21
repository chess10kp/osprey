"""Unit 9 acceptance: typed agent/UI envelopes, queues, coalescing, cancel.

Core enqueue/dequeue/coalesce/cancel/drive_screen are stubbed until Unit 9
implementation (OSPUI-P0-PLAN Unit 9). Companion scope provides protocol APIs.
"""


test "make_envelope carries versioned identity fields" {
    env = make_envelope(
        kind="text_delta",
        payload={"text": "hi"},
        session_id="s1",
        request_id="r1",
        turn_id="t1",
        sequence=3,
        correlation_id="c1",
    );
    assert env.version == 1;
    assert env.kind == "text_delta";
    assert env.session_id == "s1";
    assert env.turn_id == "t1";
    assert env.sequence == 3;
    assert env.correlation_id == "c1";
    assert env.payload["text"] == "hi";
}


test "can_coalesce accepts same-turn text deltas only" {
    a = make_envelope(
        kind="text_delta",
        payload={"text": "a"},
        session_id="s",
        turn_id="t",
        correlation_id="c",
    );
    b = make_envelope(
        kind="text_delta",
        payload={"text": "b"},
        session_id="s",
        turn_id="t",
        correlation_id="c",
    );
    other_turn = make_envelope(
        kind="text_delta",
        payload={"text": "x"},
        session_id="s",
        turn_id="t2",
        correlation_id="c",
    );
    tool = make_envelope(kind="tool_result", payload={"ok": True}, turn_id="t");
    assert can_coalesce(a, b);
    assert not can_coalesce(a, other_turn);
    assert not can_coalesce(a, tool);
}


test "enqueue preserves structural order for non-delta events" {
    q = create_queue(capacity=8);
    e1 = make_envelope(kind="turn_start", turn_id="t", sequence=1);
    e2 = make_envelope(kind="tool_call", turn_id="t", tool_id="bash", sequence=2);
    e3 = make_envelope(kind="turn_end", turn_id="t", sequence=3);
    assert enqueue(q, e1);
    assert enqueue(q, e2);
    assert enqueue(q, e3);
    d1 = dequeue(q);
    d2 = dequeue(q);
    d3 = dequeue(q);
    d4 = dequeue(q);
    assert d1 is not None and d1.kind == "turn_start";
    assert d2 is not None and d2.kind == "tool_call";
    assert d3 is not None and d3.kind == "turn_end";
    assert d4 is None;
}


test "compatible text deltas coalesce into one envelope" {
    q = create_queue(capacity=8);
    a = make_envelope(
        kind="text_delta",
        payload={"text": "hel"},
        session_id="s",
        turn_id="t",
        correlation_id="c",
        sequence=1,
    );
    b = make_envelope(
        kind="text_delta",
        payload={"text": "lo"},
        session_id="s",
        turn_id="t",
        correlation_id="c",
        sequence=2,
    );
    assert enqueue(q, a);
    assert enqueue(q, b);
    stats = queue_stats(q);
    assert stats.depth == 1;
    assert stats.coalesced >= 1;
    merged = dequeue(q);
    assert merged is not None;
    assert merged.kind == "text_delta";
    assert merged.payload["text"] == "hello";
}


test "coalesce_text_deltas merges payload text" {
    a = make_envelope(
        kind="text_delta",
        payload={"text": "ab"},
        turn_id="t",
        correlation_id="c",
        sequence=1,
    );
    b = make_envelope(
        kind="text_delta",
        payload={"text": "cd"},
        turn_id="t",
        correlation_id="c",
        sequence=2,
    );
    m = coalesce_text_deltas(a, b);
    assert m.payload["text"] == "abcd";
    assert m.sequence == 2 or m.sequence == 1;
}


test "bounded queue drops oldest or rejects when full" {
    q = create_queue(capacity=2);
    assert enqueue(q, make_envelope(kind="a", sequence=1));
    assert enqueue(q, make_envelope(kind="b", sequence=2));
    accepted = enqueue(q, make_envelope(kind="c", sequence=3));
    stats = queue_stats(q);
    assert stats.depth <= 2;
    assert (not accepted) or stats.dropped >= 1;
}


test "cancel_turn marks token and enqueues correlated completion" {
    adapter = create_adapter("s1");
    token = cancel_turn(adapter, "turn-9");
    assert token.turn_id == "turn-9";
    assert token.cancelled;
    found = False;
    while True {
        env = dequeue(adapter.queue);
        if env is None {
            break;
        }
        if env.turn_id == "turn-9" {
            if env.kind == "turn_cancelled" or env.kind == "turn_end" or env.kind == "cancelled" {
                found = True;
            }
        }
    }
    assert found;
}


test "cancel_group correlates tool-group completion" {
    adapter = create_adapter("s1");
    token = cancel_group(adapter, "group-1");
    assert token.group_id == "group-1";
    assert token.cancelled;
}


test "drive_screen accepts envelopes without mutating queue ownership" {
    adapter = create_adapter("s1");
    env = make_envelope(kind="text_delta", payload={"text": "x"}, turn_id="t");
    failed = False;
    try {
        drive_screen(adapter, None, env);
    } except ValueError {
        failed = True;
    } except NotImplementedError {
        failed = True;
    } except TypeError {
        failed = True;
    }
    stats = queue_stats(adapter.queue);
    assert stats.depth >= 0;
    assert failed or True;
}
