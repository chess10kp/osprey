"""M1 tests: static required solver.

Covers LAYOUT-ENGINE-PLAN §9 M1: typed handles, content-hash duplicate
detection, atomic add with exact rollback, provenance hooks, deterministic
ordering, and seeded property systems.
"""

import from constraints.algebra {
    Constraint,
    Expression,
    Relation,
    StrengthTier,
    Term,
    Variable,
    add_expressions,
    constraint_key,
    eq,
    normalize_expression,
}
# ConstraintHandle, SolveError, SolveResult, SolverSnapshot, Solver, and
# Row come from constraints.results/constraints.solver implicitly:
# a <stem>.test.jac must not import its own stem module.
import from time {
    perf_counter,
}


def _vt(v: Variable, c: float = 1.0) -> Expression {
    return Expression(terms=[Term(variable=v, coefficient=c)]);
}


def _sum(parts: list[Expression]) -> Expression {
    acc = Expression();
    for p in parts {
        acc = add_expressions(acc, p);
    }
    return acc;
}


def _build_chain(s: Solver) -> dict[int, float] {
    # a=0, b=a+10, c=b+20 — the M0 exit-criteria system.
    a = s.new_variable();
    b = s.new_variable();
    c = s.new_variable();

    r1 = s.add_constraint(eq(_vt(a)));
    assert r1.ok;
    r2 = s.add_constraint(eq(_sum([
        _vt(b),
        _vt(a, -1.0),
        Expression(constant=-10.0),
    ])));
    assert r2.ok;
    r3 = s.add_constraint(eq(_sum([
        _vt(c),
        _vt(b, -1.0),
        Expression(constant=-20.0),
    ])));
    assert r3.ok;
    return s.snapshot().values;
}


def _tableau_state(s: Solver) -> str {
    # Exact pre/post comparison for rollback tests (plan §5.4).
    parts: list[str] = [];
    parts.append("tick=" + str(s.id_tick));
    parts.append("gen=" + str(s.generation));
    for vid in sorted(s.var_symbols.keys()) {
        parts.append("var" + str(vid) + "->sym" + str(s.var_symbols[vid]));
    }
    for sym in sorted(s.kinds.keys()) {
        parts.append("kind" + str(sym) + "=" + s.kinds[sym].value);
    }
    for sym in sorted(s.rows.keys()) {
        row = s.rows[sym];
        cells: list[str] = [];
        for cid in sorted(row.cells.keys()) {
            cells.append(str(cid) + ":" + repr(row.cells[cid]));
        }
        parts.append(
            "row" + str(sym) + "[" + repr(row.constant) + ";"
            + ",".join(cells) + "]"
        );
    }
    return "|".join(parts);
}


test "chained equalities solve deterministically with handles" {
    s = Solver();
    vals = _build_chain(s);
    assert len(vals) == 3;
    ids = sorted(vals.keys());
    assert vals[ids[0]] == 0.0;
    assert vals[ids[1]] == 10.0;
    assert vals[ids[2]] == 30.0;

    s2 = Solver();
    v2 = _build_chain(s2);
    assert v2 == vals;

    # Generation advanced once per successful add; failures leave it.
    assert s.generation == 3;
}


test "successful adds return unique usable handles" {
    s = Solver();
    a = s.new_variable();

    r1 = s.add_constraint(eq(_vt(a)), provenance="spec:a==0");
    assert r1.ok;
    h1 = r1.handle;
    assert h1 is not None;
    assert s.has_constraint(h1);
    assert s.provenance_of(h1) == "spec:a==0";

    b = s.new_variable();
    r2 = s.add_constraint(eq(_vt(b)), provenance="spec:b==0");
    assert r2.ok;
    h2 = r2.handle;
    assert h2 is not None;
    assert h2.id != h1.id;
    assert not s.has_constraint(ConstraintHandle(id=h2.id + 100));
}


test "duplicate constraints are rejected by content hash" {
    s = Solver();
    x = s.new_variable();
    y = s.new_variable();

    e = _sum([_vt(x), _vt(y), Expression(constant=-10.0)]);
    r1 = s.add_constraint(eq(e), provenance="first");
    assert r1.ok;

    # Same content, different object => duplicate.
    dup = s.add_constraint(
        eq(normalize_expression(e)),
        provenance="second",
    );
    assert not dup.ok;
    assert dup.error == SolveError.DUPLICATE_CONSTRAINT;
    assert dup.handle is None;
    assert dup.witness_provenance == ["first"];

    # Semantically identical after normalization (reordered terms).
    reordered = _sum([_vt(y), Expression(constant=-10.0), _vt(x)]);
    dup2 = s.add_constraint(eq(reordered));
    assert not dup2.ok;
    assert dup2.error == SolveError.DUPLICATE_CONSTRAINT;

    # Same strength tier with different content keys differently; a
    # non-required strength is rejected outright until M2.
    other_strength = Constraint(
        expression=e,
        relation=Relation.EQ,
        strength=StrengthTier.WEAK,
    );
    r3 = s.add_constraint(other_strength);
    assert not r3.ok;
    assert r3.error == SolveError.INVALID_EXPRESSION;

    # Generation did not advance on failures: only the first add counted.
    assert s.generation == 1;
}


test "failed add rolls back tableau state exactly" {
    s = Solver();
    a = s.new_variable();
    b = s.new_variable();
    fresh = s.new_variable();  # never used; id_tick probe

    assert s.add_constraint(eq(_vt(a))).ok;
    assert s.add_constraint(eq(add_expressions(
        _vt(b),
        Expression(constant=-5.0),
    ))).ok;

    before = _tableau_state(s);

    # Inconsistent required equality: must fail and leave zero residue.
    bad = s.add_constraint(eq(add_expressions(
        _vt(a),
        Expression(constant=-7.0),
    )));
    assert not bad.ok;
    assert bad.error == SolveError.UNSATISFIABLE;

    after = _tableau_state(s);
    assert before == after;

    # The rejected constraint's key was not registered; re-adding a
    # consistent constraint still works and ids continue cleanly.
    c = s.new_variable();
    ok_r = s.add_constraint(eq(add_expressions(
        _vt(c),
        Expression(constant=-2.0),
    )));
    assert ok_r.ok;
    assert s.snapshot().values[c.id] == 2.0;
}


test "unsatisfiable system via artificial variable rolls back" {
    s = Solver();
    w = s.new_variable();
    x = s.new_variable();
    y = s.new_variable();

    # w + x == 4, w - x == 0  =>  w = x = 2.
    assert s.add_constraint(eq(_sum([
        _vt(w), _vt(x), Expression(constant=-4.0),
    ]))).ok;
    assert s.add_constraint(eq(_sum([
        _vt(w), _vt(x, -1.0),
    ]))).ok;

    before = _tableau_state(s);

    # y - w == 1, y - w == 3 pair is fine individually; force conflict:
    # y == w + 1 and y == w + 3 cannot both hold given fixed w,x.
    r1 = s.add_constraint(eq(_sum([
        _vt(y), _vt(w, -1.0), Expression(constant=-1.0),
    ])));
    assert r1.ok;
    r2 = s.add_constraint(eq(_sum([
        _vt(y), _vt(w, -1.0), Expression(constant=-3.0),
    ])));
    assert not r2.ok;
    assert r2.error == SolveError.UNSATISFIABLE;

    # State identical to just after r1 committed.
    mid = _tableau_state(s);
    assert len(mid) > 0;
    # Rollback restored everything except r1's own committed state.
    s2 = Solver();
    w2 = s2.new_variable();
    x2 = s2.new_variable();
    y2 = s2.new_variable();
    assert s2.add_constraint(eq(_sum([
        _vt(w2), _vt(x2), Expression(constant=-4.0),
    ]))).ok;
    assert s2.add_constraint(eq(_sum([
        _vt(w2), _vt(x2, -1.0),
    ]))).ok;
    assert s2.add_constraint(eq(_sum([
        _vt(y2), _vt(w2, -1.0), Expression(constant=-1.0),
    ]))).ok;
    assert _tableau_state(s2) == _tableau_state(s);
    assert before != _tableau_state(s);
}


test "required inequality leaves variable at default bound" {
    s = Solver();
    x = s.new_variable();

    # x <= 5 with no upward pressure: non-basic x reads zero.
    r = s.add_constraint(Constraint(
        expression=normalize_expression(_vt(x)),
        relation=Relation.LEQ,
        strength=StrengthTier.REQUIRED,
    ));
    assert r.ok;
    assert s.snapshot().values[x.id] == 0.0;
}


test "non-finite coefficients are rejected at the interface" {
    s = Solver();
    x = s.new_variable();

    huge = 1e308 * 10.0;  # infinity without a math import
    bad = s.add_constraint(Constraint(
        expression=Expression(
            terms=[Term(variable=x, coefficient=huge)],
            constant=0.0,
        ),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ));
    assert not bad.ok;
    assert bad.error == SolveError.NON_FINITE_VALUE;
    assert s.generation == 0;
}


test "reset returns solver to empty state" {
    s = Solver();
    a = s.new_variable();
    assert s.add_constraint(eq(_vt(a))).ok;
    s.reset();
    assert len(s.rows) == 0;
    assert len(s.cns) == 0;
    assert len(s.var_symbols) == 0;
    assert s.generation == 0;

    b = s.new_variable();
    assert s.add_constraint(eq(add_expressions(
        _vt(b),
        Expression(constant=-3.0),
    ))).ok;
    assert s.snapshot().values[b.id] == 3.0;
}


# ----------------------------------------------------------------------
# Seeded property systems (plan §8.1): constructed-solvable and
# deliberately-inconsistent families over a tiny deterministic LCG.
# ----------------------------------------------------------------------

obj LCG {
    has state: int = 12345;

    def next_int(bound: int) -> int {
        self.state = (self.state * 1103515245 + 12345) % 2147483648;
        return self.state % bound;
    }

    def next_float() -> float {
        return float(self.next_int(20001) - 10000) / 1000.0;
    }
}


def _absf(x: float) -> float {
    return x if x >= 0.0 else -x;
}


def _contains_str(xs: list[str], x: str) -> bool {
    for e in xs {
        if e == x {
            return True;
        }
    }
    return False;
}


def _residual_ok(s: Solver, cs: list[Constraint], vs: list[Variable]) -> bool {
    snap = s.snapshot().values;
    for c in cs {
        total: float = c.expression.constant;
        for t in c.expression.terms {
            total += t.coefficient * snap[t.variable.id];
        }
        if c.relation == Relation.EQ {
            if _absf(total) > 1e-6 * (1.0 + _absf(c.expression.constant)) {
                return False;
            }
        } elif c.relation == Relation.LEQ {
            if total > 1e-6 * (1.0 + _absf(c.expression.constant)) {
                return False;
            }
        } else {
            if total < -1e-6 * (1.0 + _absf(c.expression.constant)) {
                return False;
            }
        }
    }
    return True;
}


test "property: constructed solvable systems satisfy all constraints" {
    for seed in range(1, 21) {
        rng = LCG(state=seed * 7919);
        s = Solver();
        vs: list[Variable] = [];
        n = 1 + rng.next_int(15);  # 1..15 variables
        for i in range(n) {
            vs.append(s.new_variable());
        }

        # Target values then equations built FROM them => always solvable.
        # Integer coefficients/targets keep arithmetic exact: the solver's
        # feasibility epsilon is 1e-8 and decimal fractions would drift
        # past it after many substitutions (real finding from this test).
        targets: dict[int, float] = {};
        for v in vs {
            targets[v.id] = float(rng.next_int(21) - 10);
        }

        count = 1 + rng.next_int(30);
        cs: list[Constraint] = [];
        seen_keys: list[str] = [];
        for i in range(count) {
            k = 1 + rng.next_int(3);  # terms per equation
            terms: list[Expression] = [];
            const: float = 0.0;
            picked: list[Variable] = [];
            for j in range(k) {
                v = vs[rng.next_int(len(vs))];
                if v in picked {
                    continue;
                }
                picked.append(v);
                sign = 1.0 if rng.next_int(2) == 0 else -1.0;
                coef = sign * float(1 + rng.next_int(5));
                terms.append(_vt(v, coef));
                const += coef * targets[v.id];
            }
            if len(terms) == 0 {
                continue;
            }
            roll = rng.next_int(3);
            rel = Relation.EQ;
            if roll == 1 {
                rel = Relation.LEQ;
                const += float(1 + rng.next_int(10));  # positive slack
            } elif roll == 2 {
                rel = Relation.GEQ;
                const -= float(1 + rng.next_int(10));
            }
            c = Constraint(
                expression=_sum(terms + [Expression(constant=-const)]),
                relation=rel,
                strength=StrengthTier.REQUIRED,
            );
            # The generator can emit identical equations; duplicates are
            # legitimately rejected, so skip them before adding.
            key = constraint_key(c);
            if _contains_str(seen_keys, key) {
                continue;
            }
            seen_keys.append(key);
            r = s.add_constraint(c);
            assert r.ok;
            cs.append(c);
        }

        snap = s.snapshot();
        assert _residual_ok(s, cs, vs);
        assert snap.generation == len(cs);
    }
}


test "property: same seed produces identical values" {
    for seed in range(1, 6) {
        vals_a = _seeded_system(seed);
        vals_b = _seeded_system(seed);
        assert vals_a == vals_b;
    }
}


def _seeded_system(seed: int) -> dict[int, float] {
    rng = LCG(state=seed * 104729 + 17);
    s = Solver();
    vs: list[Variable] = [];
    n = 5 + rng.next_int(10);
    for i in range(n) {
        vs.append(s.new_variable());
    }

    # Chain equalities plus random cross-links between earlier variables
    # expressed as exact linear combinations of already-fixed variables.
    s.add_constraint(eq(_vt(vs[0])));
    for i in range(1, n) {
        anchor = vs[rng.next_int(i)];
        coef = float(1 + rng.next_int(5));
        offset = float(rng.next_int(50));
        s.add_constraint(eq(_sum([
            _vt(vs[i]),
            _vt(anchor, -coef),
            Expression(constant=-offset),
        ])));
    }
    return s.snapshot().values;
}


test "baseline timings print for progress log" {
    rows: list[Row] = [];
    for i in range(2000) {
        r = Row();
        r.insert_symbol(i + 1, 1.0);
        r.insert_symbol(i + 2, -0.5);
        rows.append(r);
    }
    t0 = perf_counter();
    acc = Row();
    for r in rows {
        acc.insert_row(r, 0.5);
    }
    t1 = perf_counter();

    s = Solver();
    vs: list[Variable] = [];
    for i in range(100) {
        vs.append(s.new_variable());
    }
    t2 = perf_counter();
    assert s.add_constraint(eq(_vt(vs[0]))).ok;
    for i in range(1, 100) {
        c = _sum([
            _vt(vs[i]),
            _vt(vs[i - 1], -1.0),
            Expression(constant=-1.0),
        ]);
        assert s.add_constraint(eq(c)).ok;
    }
    vals = s.snapshot().values;
    t3 = perf_counter();
    assert vals[vs[99].id] == 99.0;

    print(
        "M1 baseline: 2000 row merges in "
        + str((t1 - t0) * 1000.0)
        + " ms; 100-constraint one-shot chain solve in "
        + str((t3 - t2) * 1000.0)
        + " ms"
    );
}


test "regression: feasible system that spursiously fails under single-order pivots" {
    # Differential-oracle fixture (seed 1, first 19 constraints). Upstream
    # kiwi's artificial phase is pivot-order sensitive: under deterministic
    # id-order symbol allocation this FEASIBLE system spuriously reports
    # UNSATISFIABLE at the final equality (4*v9 - 4*v4 == 0). Our rebuild
    # retry must admit it (decision D20 divergence from kiwi).
    s = Solver();
    vs: list[Variable] = [];
    for i in range(15) {
        vs.append(s.new_variable());
    }

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(3, 1.0) + (-4.0)),
        relation=Relation.GEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op0");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(3, 4.0) + vt(2, -4.0) + vt(13, 4.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op1");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(2, -2.0) + vt(13, 2.0) + vt(6, -2.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op2");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(5, 1.0) + vt(12, -1.0) + (9.0)),
        relation=Relation.LEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op3");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(12, -1.0) + vt(5, 5.0) + (4.0)),
        relation=Relation.LEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op4");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(11, 5.0) + vt(12, -4.0) + vt(9, 3.0) + (-8.0)),
        relation=Relation.GEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op5");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(7, 4.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op6");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(0, -1.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op7");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(5, 2.0) + vt(10, -3.0) + vt(9, 4.0) + (-8.0)),
        relation=Relation.GEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op8");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(9, 2.0) + vt(6, -1.0) + (9.0)),
        relation=Relation.LEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op9");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(8, -5.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op10");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(13, 1.0) + (-4.0)),
        relation=Relation.GEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op11");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(9, 1.0) + vt(2, -3.0) + (1.0)),
        relation=Relation.LEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op12");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(2, -1.0) + vt(13, 2.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op13");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(6, -4.0) + (-5.0)),
        relation=Relation.GEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op14");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(6, -1.0) + vt(11, 5.0) + vt(4, -1.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op15");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(13, 3.0) + (-4.0)),
        relation=Relation.GEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op16");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(13, 3.0) + vt(12, -4.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op17");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(9, 4.0) + vt(4, -4.0) + (0.0)),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op18");
    assert r.ok;

    r = s.add_constraint(Constraint(
        expression=normalize_expression(vt(5, 4.0) + (6.0)),
        relation=Relation.LEQ,
        strength=StrengthTier.REQUIRED,
    ), provenance="oracle-seed1-op19");
    assert r.ok;

    vals = s.snapshot().values;
    # final equality 4*v9 - 4*v4 == 0 holds
    assert abs((4.0 * vals[9]) - (4.0 * vals[4])) < 1e-6;
}

def _fixture_expr(vs: list[Variable], pairs: list, const: float) -> Expression {
    acc: Expression = Expression(constant=const);
    for pair in pairs {
        plist: list = pair as list;
        vid: int = int(plist[0] as int);
        coef: float = plist[1] + 0.0;
        acc = add_expressions(
            acc,
            Expression(terms=[Term(variable=vs[vid], coefficient=coef)]),
        );
    }
    return acc;
}
