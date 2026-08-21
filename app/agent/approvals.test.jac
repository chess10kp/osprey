"""Tool approval queue tests (ported concept from src/agent/tool-approval.ts).

Covers: auto/blocked/pending policy routing, correlated resolve/deny by id,
unknown-id errors, FIFO ordering, and cancel/expire abort sweeps.

This file is tested merged with agent/approvals.jac (same-stem convention),
so all symbols under test are referenced directly without imports.

Note on modes semantics: modes.requires_approval returns "confirm" for every
executable call in normal mode (reads included), so in normal mode even a
read-only tool enters the queue. Reads are auto-approved only outside
normal mode.
"""


test "read-only tool is auto-approved and never enqueued outside normal mode" {
    for mode in ["auto-accept", "yolo", "plan", "ask"] {
        q = create_queue();
        res = request_approval(q, "read_file", "", mode, 1000.0);
        assert res["decision"] == "auto";
        assert pending(q) is None;
        assert len(q.items) == 0;
    }
}


test "read-only tool in normal mode still requires confirmation" {
    q = create_queue();
    res = request_approval(q, "read_file", "", "normal", 1000.0);
    assert res["decision"] == "pending";
    head = pending(q);
    assert head is not None;
    assert head.tool_name == "read_file";
    assert len(q.items) == 1;
}


test "destructive command in plan mode is blocked without enqueueing" {
    q = create_queue();
    res = request_approval(q, "run_command", "rm -rf /", "plan", 1000.0);
    assert res["decision"] == "blocked";
    assert pending(q) is None;
    assert len(q.items) == 0;
    res2 = request_approval(q, "write_file", "", "ask", 1000.0);
    assert res2["decision"] == "blocked";
    assert len(q.items) == 0;
}


test "destructive command in normal mode pends then resolves approved" {
    q = create_queue();
    res = request_approval(q, "run_command", "git push --force", "normal", 1000.0);
    assert res["decision"] == "pending";
    head = pending(q);
    assert head is not None;
    assert head.tool_name == "run_command";
    assert head.cmd == "git push --force";
    assert head.mode == "normal";
    assert head.created_at == 1000.0;
    out = resolve(q, res["id"], True);
    assert out["id"] == res["id"];
    assert out["approved"] is True;
    assert pending(q) is None;
    assert len(q.items) == 0;
}


test "deny path returns approved=False and drops the request" {
    q = create_queue();
    res = request_approval(q, "write_file", "/tmp/x.txt", "normal", 1000.0);
    assert res["decision"] == "pending";
    out = resolve(q, res["id"], False);
    assert out["approved"] is False;
    assert out["id"] == res["id"];
    assert len(q.items) == 0;
}


test "resolving an unknown or already-resolved id errors cleanly" {
    q = create_queue();
    out = resolve(q, "approval-999", True);
    assert "error" in out;
    assert out["error"] == "unknown_approval_id";
    assert out["id"] == "approval-999";
    res = request_approval(q, "write_file", "", "normal", 1000.0);
    resolve(q, res["id"], True);
    again = resolve(q, res["id"], True);
    assert "error" in again;
    assert again["error"] == "unknown_approval_id";
}


test "multiple pending requests come out FIFO by id order" {
    q = create_queue();
    r1 = request_approval(q, "write_file", "a.txt", "normal", 1000.0);
    r2 = request_approval(q, "edit_file", "b.txt", "normal", 1010.0);
    r3 = request_approval(q, "run_command", "npm install", "normal", 1020.0);
    assert r1["decision"] == "pending";
    assert r2["decision"] == "pending";
    assert r3["decision"] == "pending";
    ids = [r1["id"], r2["id"], r3["id"]];
    assert len(set(ids)) == 3;
    head1 = pending(q);
    assert head1.id == ids[0];
    resolve(q, ids[0], True);
    head2 = pending(q);
    assert head2.id == ids[1];
    resolve(q, ids[1], False);
    head3 = pending(q);
    assert head3.id == ids[2];
    resolve(q, ids[2], True);
    assert pending(q) is None;
}


test "cancel_all drains the queue exactly once" {
    q = create_queue();
    request_approval(q, "write_file", "", "normal", 1000.0);
    request_approval(q, "edit_file", "", "normal", 1010.0);
    dropped = cancel_all(q);
    assert dropped == 2;
    assert pending(q) is None;
    assert cancel_all(q) == 0;
    # Queue keeps issuing fresh ids after a drain.
    res = request_approval(q, "write_file", "", "normal", 1020.0);
    assert res["decision"] == "pending";
    assert resolve(q, res["id"], True)["approved"] is True;
}


test "expire_older_than drops only entries past the age window" {
    q = create_queue();
    r_old = request_approval(q, "write_file", "", "normal", 1000.0);
    r_new = request_approval(q, "edit_file", "", "normal", 5000.0);
    old_rec = q.items[0];
    new_rec = q.items[1];
    old_rec.created_at = 1000.0;
    new_rec.created_at = 5000.0;
    # now=6000, window=2000: cutoff 4000 keeps only the newer record.
    assert expire_older_than(q, 6000.0, 2000.0) == 1;
    assert pending(q).id == r_new["id"];
    assert resolve(q, r_old["id"], True)["error"] == "unknown_approval_id";
    # Boundary: created_at equal to the cutoff survives.
    assert expire_older_than(q, 7000.0, 2000.0) == 0;
    assert expire_older_than(q, 7000.0001, 2000.0) == 1;
    assert pending(q) is None;
    assert expire_older_than(q, 8000.0, 1000.0) == 0;
}
