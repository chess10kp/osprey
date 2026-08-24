"""Interaction queue tests (P12 slice 2) — pure queue semantics."""

import time;


def _req(method: str = "select", parent: str = "corr-1", **extra: any) -> dict {
    req: dict = {
        "method": method,
        "parent_corr": parent,
        "parent_kind": "cmd_invoke",
        "extension_id": "t.ext",
        "created": time.monotonic(),
        "timeout_ms": 30000.0,
    };
    if method == "select" { req["options"] = ["a", "b"]; }
    if method == "confirm" { req["message"] = "sure?"; }
    for k in extra {
        req[k] = extra[k];
    }
    return req;
}


test "enqueue validates method and parent correlation" {
    q = new_ui_queue();
    ok1 = q.enqueue(_req());
    assert ok1[0] is True and ok1[1] == "ui-1";
    ok2 = q.enqueue(_req(method="dropdown"));
    assert ok2[0] is False;
    ok3 = q.enqueue(_req(parent=""));
    assert ok3[0] is False;
}


test "caller-supplied child correlations are honored; duplicates rejected" {
    q = new_ui_queue();
    r1 = q.enqueue(_req(parent="p", corr="child-7"));
    assert r1[0] is True and r1[1] == "child-7";
    r2 = q.enqueue(_req(parent="p", corr="child-7"));
    assert r2[0] is False;
    r3 = q.enqueue(_req(method="confirm", parent="p", corr="child-8"));
    assert r3[1] == "child-8";
    # Mixed: generated id must not collide with caller-supplied ones.
    r4 = q.enqueue(_req(parent="p"));
    assert r4[1] == "ui-1" or r4[1] != "child-7";
}


test "poll peeks FIFO head without detaching" {
    q = new_ui_queue();
    q.enqueue(_req(parent="p1"));
    q.enqueue(_req(method="confirm", parent="p2"));
    first = q.poll(time.monotonic());
    assert first[0] is not None and first[0].parent_corr == "p1";
    # Peek semantics: still queued until taken.
    again = q.poll(time.monotonic() + 1.0);
    assert again[0] is not None and again[0].parent_corr == "p1";
    assert q.take(first[0].corr) is not None;
    second = q.poll(time.monotonic() + 2.0);
    assert second[0] is not None and second[0].method == "confirm";
}


test "expired requests are reaped into the cancelled bucket" {
    q = new_ui_queue();
    q.enqueue(_req(timeout_ms=50.0));
    time.sleep(0.08);
    res = q.poll(time.monotonic());
    assert res[0] is None;
    assert len(res[1]) == 1 and res[1][0].corr == "ui-1";
}


test "respond takes by child corr; unknown corr is a no-op" {
    q = new_ui_queue();
    r = q.enqueue(_req());
    corr = r[1];
    got: any = q.take(corr);
    assert got is not None and got.method == "select";
    assert q.take(corr) is None;
}


test "cancel_by_parent cancels only that parent's children" {
    q = new_ui_queue();
    q.enqueue(_req(parent="pa"));
    q.enqueue(_req(method="confirm", parent="pb"));
    dead = q.cancel_by_parent("pa");
    assert len(dead) == 1 and dead[0].parent_corr == "pa";
    assert len(q.records) == 1 and q.records[0].parent_corr == "pb";
}


test "cancel_all drains everything" {
    q = new_ui_queue();
    q.enqueue(_req(parent="x1"));
    q.enqueue(_req(method="input", parent="x2"));
    assert q.cancel_all() == 2;
    assert q.poll(time.monotonic())[0] is None;
}
