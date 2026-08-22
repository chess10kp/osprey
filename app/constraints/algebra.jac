"""Constraint algebra: variables, expressions, relations, strengths.

Pure data-oriented values for the layout constraint solver. No OSP types,
no terminal code, no Python imports, no app domain types (LAYOUT-ENGINE-PLAN
§3). Expressions are sparse coefficient maps keyed by symbol/variable id.

Numeric policy (§5.3): reject NaN/infinity at the interface; one named
EPSILON for zero tests; normalize by combining duplicate variables, dropping
coefficients within epsilon of zero, and ordering terms by id.

Structure follows the Kiwi simplex kernel (nucleic/kiwi, BSD-2) — our
differential oracle — adapted to Jac data objects.
"""

glob EPSILON: float = 1e-8;


def near_zero(value: float) -> bool {
    return abs(value) < EPSILON;
}


def is_finite(x: float) -> bool {
    # No math import: NaN is the only value not equal to itself, and the
    # magnitude checks catch infinity without a module dependency.
    return x == x and x < 1e308 and x > -1e308;
}


def require_finite(x: float) -> None {
    if not is_finite(x) {
        raise ValueError("non-finite value rejected at constraint interface");
    }
}


enum Relation {
    LEQ = "leq",
    EQ = "eq",
    GEQ = "geq"
}


enum StrengthTier {
    REQUIRED = "required",
    STRONG = "strong",
    MEDIUM = "medium",
    WEAK = "weak"
}


obj Variable {
    has id: int;
}


obj Term {
    has variable: Variable,
        coefficient: float;
}


obj Expression {
    has terms: list[Term] = [],
        constant: float = 0.0;
}


obj Constraint {
    has expression: Expression,
        relation: Relation,
        strength: StrengthTier;
}


"""Combine duplicate variables, drop near-zero coefficients, order by id."""
def normalize_expression(e: Expression) -> Expression {
    require_finite(e.constant);
    merged: dict[int, float] = {};
    for t in e.terms {
        require_finite(t.coefficient);
        vid = t.variable.id;
        merged[vid] = merged.get(vid, 0.0) + t.coefficient;
    }
    terms: list[Term] = [];
    for vid in sorted(merged.keys()) {
        c = merged[vid];
        if not near_zero(c) {
            terms.append(Term(variable=Variable(id=vid), coefficient=c));
        }
    }
    return Expression(terms=terms, constant=e.constant);
}


def term(v: Variable, coefficient: float = 1.0) -> Expression {
    return Expression(terms=[Term(variable=v, coefficient=coefficient)]);
}


"""Combine two expressions; Jac objects do not overload `+`."""
def add_expressions(a: Expression, b: Expression) -> Expression {
    return normalize_expression(
        Expression(
            terms=a.terms + b.terms,
            constant=a.constant + b.constant,
        )
    );
}


"""Deterministic content key for duplicate detection (plan §5.4).

Two constraints with the same normalized expression, relation, and
strength produce the same key. Floats render via repr so the key is
stable within and across processes for identical inputs."""
def constraint_key(c: Constraint) -> str {
    e = normalize_expression(c.expression);
    parts: list[str] = [];
    parts.append(c.relation.value);
    parts.append(c.strength.value);
    for t in e.terms {
        parts.append(str(t.variable.id) + ":" + repr(t.coefficient));
    }
    parts.append("|" + repr(e.constant));
    return ";".join(parts);
}


def eq(expr: Expression) -> Constraint {
    return Constraint(
        expression=normalize_expression(expr),
        relation=Relation.EQ,
        strength=StrengthTier.REQUIRED,
    );
}
