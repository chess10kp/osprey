"""Extension declaration helpers (native control plane)."""

test "decl_from_dict defaults activation from runtime" {
    d = decl_from_dict({"id": "a", "path": "./x.js", "runtime": "node"});
    assert d.activation == "sidecar";
    n = decl_from_dict({"id": "b", "path": "n", "runtime": "native"});
    assert n.activation == "native";
}


test "node_sidecar_decls skips lazy and native" {
    rows = [
        decl_from_dict({"id": "a", "path": "a.js", "runtime": "node"}),
        decl_from_dict({
            "id": "b",
            "path": "b.js",
            "runtime": "node",
            "activation": "lazy",
        }),
        decl_from_dict({"id": "c", "path": "c.jac", "runtime": "native"}),
    ];
    side = node_sidecar_decls(rows);
    assert len(side) == 1;
    assert side[0].id == "a";
}


test "extensions_label formats loading n/m" {
    st = ExtensionStatus(phase="loading", loaded=2, total=5, ready=False);
    assert extensions_label(st) == "extensions: loading 2/5";
    st2 = ExtensionStatus(phase="ready", loaded=5, total=5, ready=True);
    assert extensions_label(st2) == "extensions: ready 5/5";
}
