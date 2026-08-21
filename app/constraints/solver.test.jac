"""M0 feasibility tests for the constraint solver slice.

Exit criteria (LAYOUT-ENGINE-PLAN §9 M0): deterministic chained-equality
solve, inequality handling, unsatisfiability detection, determinism across
fresh solvers, finite-value rejection, and baseline timings printed for
the progress log.
"""

import from constraints.algebra {
    Constraint,
    Expression,
    Relation,
    StrengthTier,
    Term,
    Variable,
    add_expressions,
    eq,
    normalize_expression,
}
# Row, SolveError, and Solver come from constraints.solver implicitly:
# a <stem>.test.jac file must not import its own stem module (circular
# initialization, same convention as ui/*.test.jac).
import from time {
    perf_counter,
}


def _var_term(v: Variable, coefficient: float = 1.0) -> Expression {
    return Expression(terms=[Term(variable=v, coefficient=coefficient)]);
}


def _sum(parts: list[Expression]) -> Expression {
    # Left-fold add_expressions over parts; objects do not overload +.
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

    r1 = s.add_constraint(eq(_var_term(a)));
    assert r1.ok;
    r2 = s.add_constraint(eq(_sum([
        _var_term(b),
        _var_term(a, -1.0),
        Expression(constant=-10.0),
    ])));
    assert r2.ok;
    r3 = s.add_constraint(eq(_sum([
        _var_term(c),
        _var_term(b, -1.0),
        Expression(constant=-20.0),
    ])));
    assert r3.ok;
    return s.values();
}


test "chained equalities solve deterministically" {
    s = Solver();
    vals = _build_chain(s);
    assert len(vals) == 3;
    ids = sorted(vals.keys());
    assert vals[ids[0]] == 0.0;
    assert vals[ids[1]] == 10.0;
    assert vals[ids[2]] == 30.0;

    # Fresh solver, same construction order => identical values.
    s2 = Solver();
    v2 = _build_chain(s2);
    assert v2 == vals;
}


test "required equality system with shared variables" {
    s = Solver();
    x = s.new_variable();
    y = s.new_variable();

    # x + y == 10, x - y == 4  =>  x=7, y=3.
    assert s.add_constraint(eq(_sum([
        _var_term(x),
        _var_term(y),
        Expression(constant=-10.0),
    ]))).ok;
    assert s.add_constraint(eq(_sum([
        _var_term(x),
        _var_term(y, -1.0),
        Expression(constant=-4.0),
    ]))).ok;

    vals = s.values();
    assert abs(vals[x.id] - 7.0) < 1e-6;
    assert abs(vals[y.id] - 3.0) < 1e-6;
}


test "required inequality leaves variable at default bound" {
    s = Solver();
    x = s.new_variable();

    # x <= 5 with no upward pressure: non-basic x reads zero.
    r = s.add_constraint(Constraint(
        expression=normalize_expression(_var_term(x)),
        relation=Relation.LEQ,
        strength=StrengthTier.REQUIRED,
    ));
    assert r.ok;
    vals = s.values();
    assert vals[x.id] == 0.0;
}


test "inconsistent required equalities report unsatisfiable" {
    s = Solver();
    a = s.new_variable();

    assert s.add_constraint(eq(_var_term(a))).ok;
    bad = s.add_constraint(eq(add_expressions(
        _var_term(a),
        Expression(constant=-5.0),
    )));
    assert not bad.ok;
    assert bad.error == SolveError.UNSATISFIABLE;
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
}


test "reset returns solver to empty state" {
    s = Solver();
    a = s.new_variable();
    assert s.add_constraint(eq(_var_term(a))).ok;
    s.reset();
    assert len(s.rows) == 0;
    assert len(s.cns) == 0;
    assert len(s.var_symbols) == 0;

    # Post-reset allocation restarts and solving works again.
    b = s.new_variable();
    assert s.add_constraint(eq(add_expressions(
        _var_term(b),
        Expression(constant=-3.0),
    ))).ok;
    assert s.values()[b.id] == 3.0;
}


test "baseline timings print for progress log" {
    # Row-operation microbenchmark: sparse dict merges of the shape the
    # tableau performs in insert_row/substitute.
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

    # One-shot 100-node chained-equality solve.
    s = Solver();
    vs: list[Variable] = [];
    for i in range(100) {
        vs.append(s.new_variable());
    }
    t2 = perf_counter();
    assert s.add_constraint(eq(_var_term(vs[0]))).ok;
    for i in range(1, 100) {
        c = _sum([
            _var_term(vs[i]),
            _var_term(vs[i - 1], -1.0),
            Expression(constant=-1.0),
        ]);
        assert s.add_constraint(eq(c)).ok;
    }
    vals = s.values();
    t3 = perf_counter();
    assert vals[vs[99].id] == 99.0;

    print(
        "M0 baseline: 2000 row merges in "
        + str((t1 - t0) * 1000.0)
        + " ms; 100-constraint one-shot chain solve in "
        + str((t3 - t2) * 1000.0)
        + " ms"
    );
}
