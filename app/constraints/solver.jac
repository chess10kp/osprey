"""Constraint solver — Jac port of the Kiwi simplex kernel (M0 slice).

Faithful adaptation of `nucleic/kiwi` `solverimpl.h` / `row.h` / `symbol.h`
(BSD-2), which is also the differential oracle for this project
(LAYOUT-ENGINE-PLAN §8.2). Deviations are documented and deliberate:

- Symbols are plain ints keyed in dicts; the kind lives in a side registry.
  Every iteration runs over sorted ids to reproduce C++ std::map ordering,
  which the oracle comparison depends on for tie-breaking.
- Outcomes are typed results, not exceptions (plan §5.4).
- Strengths will become symbolic LexWeight vectors at M2, not Kiwi's scalar
  encoding (plan §8.2 divergence).

Not yet present (later milestones): non-required error symbols and
objective cost-row semantics (M1/M2), constraint removal with marker
pivoting (M3), edit variables / suggestValue / dualOptimize (M3), rollback
journal (M1), content-based duplicate detection (M1). This slice gates the
toolchain: finite floats, sparse dict rows, one deterministic solve,
server placement.

Row invariant (as in kiwi/row.h): each row expresses
    constant + sum(cells[sym] * sym) == 0
for its basic symbol. Cells drop when coefficients go near-zero.
"""

import from constraints.algebra {
    EPSILON,
    Constraint,
    Expression,
    Relation,
    Variable,
    is_finite,
    near_zero,
    normalize_expression,
}


enum SymbolKind {
    INVALID = "invalid",
    EXTERNAL = "external",
    SLACK = "slack",
    ERROR = "error",
    DUMMY = "dummy"
}


enum SolveError {
    OK = "ok",
    UNSATISFIABLE = "unsatisfiable",
    NON_FINITE_VALUE = "non_finite_value",
    INTERNAL_INVARIANT = "internal_invariant"
}


"""Marker pair tracking one constraint's basis presence (kiwi Tag)."""
obj Tag {
    has marker: int = 0,
        other: int = 0;
}


obj SolveResult {
    has ok: bool = True,
        error: SolveError = SolveError.OK,
        message: str = "";
}


"""Tableau row: constant + sum(cells[symbol] * symbol) == 0.
Direct port of kiwi/row.h."""
obj Row {
    has constant: float = 0.0,
        cells: dict[int, float] = {};

    def insert_symbol(symbol: int, coefficient: float = 1.0) -> None {
        self.cells[symbol] = self.cells.get(symbol, 0.0) + coefficient;
        if near_zero(self.cells[symbol]) {
            self.cells.pop(symbol);
        }
    }

    def insert_row(other: Row, coefficient: float = 1.0) -> None {
        self.constant += other.constant * coefficient;
        for symbol in sorted(other.cells.keys()) {
            coeff = other.cells[symbol] * coefficient;
            if not near_zero(coeff) {
                self.insert_symbol(symbol, coeff);
            }
        }
    }

    def remove_symbol(symbol: int) -> None {
        if symbol in self.cells {
            self.cells.pop(symbol);
        }
    }

    def reverse_sign() -> None {
        self.constant = -self.constant;
        for symbol in sorted(self.cells.keys()) {
            self.cells[symbol] = -self.cells[symbol];
        }
    }

    """a * x + rest = 0  =>  x = (-1/a) * rest - constant/a.
    The target symbol must exist in cells (kiwi solveFor)."""
    def solve_for(symbol: int) -> None {
        coeff = -1.0 / self.cells[symbol];
        self.cells.pop(symbol);
        self.constant *= coeff;
        for s in sorted(self.cells.keys()) {
            self.cells[s] *= coeff;
        }
    }

    """Solve so `lhs` enters and `rhs` leaves (kiwi solveFor lhs, rhs)."""
    def solve_for_symbols(lhs: int, rhs: int) -> None {
        self.insert_symbol(lhs, -1.0);
        self.solve_for(rhs);
    }

    def coefficient_for(symbol: int) -> float {
        return self.cells.get(symbol, 0.0);
    }

    def substitute(symbol: int, row: Row) -> None {
        if symbol not in self.cells {
            return;
        }
        coefficient = self.cells.pop(symbol);
        self.insert_row(row, coefficient);
    }
}


obj Solver {
    # Incremental simplex tableau over required constraints.
    has rows: dict[int, Row] = {},
        kinds: dict[int, SymbolKind] = {},
        var_symbols: dict[int, int] = {},
        cns: dict[int, Tag] = {},
        next_cns_key: int = 1,
        objective: Row = Row(),
        id_tick: int = 1;

    """Allocate a fresh external variable with a unique id.

    Variable ids and symbol ids share the id_tick sequence but never mix:
    each allocated variable later receives its own distinct external
    symbol via _get_var_symbol (kiwi keeps them in separate namespaces)."""
    def new_variable() -> Variable {
        v = Variable(id=self.id_tick);
        self.id_tick += 1;
        return v;
    }

    def add_constraint(c_raw: Constraint) -> SolveResult {
        # Finite-value rejection happens on the RAW expression before
        # normalization, which itself asserts finiteness (plan §5.3: typed
        # outcomes, not exceptions, at the interface).
        if not self._expression_is_finite(c_raw.expression) {
            return SolveResult(ok=False, error=SolveError.NON_FINITE_VALUE);
        }
        c = Constraint(
            expression=normalize_expression(c_raw.expression),
            relation=c_raw.relation,
            strength=c_raw.strength,
        );
        # M0 slice: keys are unique per call, so duplicates cannot recur.
        # Content hashing lands with the M1 journal (plan §5.4).
        key = self.next_cns_key;
        self.next_cns_key += 1;

        tag = Tag();
        row = self._create_row(c, tag);
        subject = self._choose_subject(row, tag);

        # No valid entering subject: an all-dummy row is redundant when its
        # constant is zero (the dummy marker may enter the basis) and
        # unsatisfiable otherwise (kiwi addConstraint).
        if (
            self._kind_of(subject) == SymbolKind.INVALID
            and self._all_dummies(row)
        ) {
            if not near_zero(row.constant) {
                return SolveResult(
                    ok=False,
                    error=SolveError.UNSATISFIABLE,
                    message="required system inconsistent",
                );
            }
            subject = tag.marker;
        }

        if self._kind_of(subject) == SymbolKind.INVALID {
            if not self._add_with_artificial_variable(row) {
                return SolveResult(
                    ok=False,
                    error=SolveError.UNSATISFIABLE,
                    message="artificial variable could not reach zero",
                );
            }
        } else {
            row.solve_for(subject);
            self._substitute(subject, row);
            self.rows[subject] = row;
        }

        self.cns[key] = tag;
        # Optimizing after every mutation keeps the tableau consistent
        # with smaller average work than batch optimizing (kiwi
        # addConstraint comment). Empty objective => immediate return.
        return self._optimize_toward(self.objective);
    }

    """External variable values keyed by variable id (kiwi updateVariables).

    Non-basic variables read zero; basic variables read their row constant.
    """
    def values() -> dict[int, float] {
        out: dict[int, float] = {};
        for vid in sorted(self.var_symbols.keys()) {
            symbol = self.var_symbols[vid];
            if symbol in self.rows {
                out[vid] = self.rows[symbol].constant;
            } else {
                out[vid] = 0.0;
            }
        }
        return out;
    }

    def reset() -> None {
        self.rows = {};
        self.kinds = {};
        self.var_symbols = {};
        self.cns = {};
        self.next_cns_key = 1;
        self.objective = Row();
        self.id_tick = 1;
    }

    # ------------------------------------------------------------------
    # internals — mirrors kiwi solverimpl.h private section
    # ------------------------------------------------------------------

    def _expression_is_finite(e: Expression) -> bool {
        if not is_finite(e.constant) {
            return False;
        }
        for t in e.terms {
            if not is_finite(t.coefficient) {
                return False;
            }
        }
        return True;
    }

    def _kind_of(symbol: int) -> SymbolKind {
        if symbol <= 0 {
            return SymbolKind.INVALID;
        }
        return self.kinds.get(symbol, SymbolKind.INVALID);
    }

    def _new_symbol(kind: SymbolKind) -> int {
        symbol = self.id_tick;
        self.id_tick += 1;
        self.kinds[symbol] = kind;
        return symbol;
    }

    def _get_var_symbol(v: Variable) -> int {
        if v.id in self.var_symbols {
            return self.var_symbols[v.id];
        }
        symbol = self._new_symbol(SymbolKind.EXTERNAL);
        self.var_symbols[v.id] = symbol;
        return symbol;
    }

    def _create_row(c: Constraint, tag: Tag) -> Row {
        row = Row(constant=c.expression.constant);
        # Substitute already-basic variables from the current tableau.
        for t in c.expression.terms {
            if not near_zero(t.coefficient) {
                symbol = self._get_var_symbol(t.variable);
                basic = self.rows.get(symbol);
                if basic is not None {
                    row.insert_row(basic, t.coefficient);
                } else {
                    row.insert_symbol(symbol, t.coefficient);
                }
            }
        }
        if c.relation == Relation.LEQ or c.relation == Relation.GEQ {
            coeff = 1.0 if c.relation == Relation.LEQ else -1.0;
            slack = self._new_symbol(SymbolKind.SLACK);
            tag.marker = slack;
            row.insert_symbol(slack, coeff);
            # Error symbols for non-required strengths arrive at M1/M2.
        } else {
            # Required equality: a dummy marker keeps the basis restricted.
            dummy = self._new_symbol(SymbolKind.DUMMY);
            tag.marker = dummy;
            row.insert_symbol(dummy);
        }
        if row.constant < 0.0 {
            row.reverse_sign();
        }
        return row;
    }

    """Subject precedence (kiwi chooseSubject): first external symbol in
    ascending id order, then a negatively-coefficiented slack/error tag."""
    def _choose_subject(row: Row, tag: Tag) -> int {
        for symbol in sorted(row.cells.keys()) {
            if self._kind_of(symbol) == SymbolKind.EXTERNAL {
                return symbol;
            }
        }
        for candidate in [tag.marker, tag.other] {
            kind = self._kind_of(candidate);
            if (
                (kind == SymbolKind.SLACK or kind == SymbolKind.ERROR)
                and row.coefficient_for(candidate) < 0.0
            ) {
                return candidate;
            }
        }
        return 0;
    }

    def _all_dummies(row: Row) -> bool {
        for symbol in sorted(row.cells.keys()) {
            if self._kind_of(symbol) != SymbolKind.DUMMY {
                return False;
            }
        }
        return True;
    }

    def _any_pivotable_symbol(row: Row) -> int {
        for symbol in sorted(row.cells.keys()) {
            kind = self._kind_of(symbol);
            if kind == SymbolKind.SLACK or kind == SymbolKind.ERROR {
                return symbol;
            }
        }
        return 0;
    }

    """Add via artificial variable; False means unsatisfiable
    (kiwi addWithArtificialVariable)."""
    def _add_with_artificial_variable(row: Row) -> bool {
        art = self._new_symbol(SymbolKind.SLACK);
        art_row = Row(constant=row.constant);
        art_row.cells = dict(row.cells);
        self.rows[art] = art_row;

        artificial = Row(constant=row.constant);
        artificial.cells = dict(row.cells);
        self._optimize_toward(artificial);

        success = near_zero(artificial.constant);

        if art in self.rows {
            pivot_row = self.rows.pop(art);
            if len(pivot_row.cells) > 0 {
                entering = self._any_pivotable_symbol(pivot_row);
                if entering == 0 {
                    return False;
                }
                pivot_row.insert_symbol(art, -1.0);
                pivot_row.solve_for(entering);
                self._substitute(entering, pivot_row);
                self.rows[entering] = pivot_row;
            }
        }

        for symbol in sorted(self.rows.keys()) {
            self.rows[symbol].remove_symbol(art);
        }
        self.objective.remove_symbol(art);
        return success;
    }

    def _substitute(symbol: int, row: Row) -> None {
        for s in sorted(self.rows.keys()) {
            r = self.rows[s];
            r.substitute(symbol, row);
            # Negative non-external constants would be tracked for
            # dualOptimize from M3 onward (kiwi m_infeasible_rows).
        }
        self.objective.substitute(symbol, row);
    }

    """Phase-2 simplex iterations until the target cost row is minimal
    (kiwi optimize / addWithArtificialVariable usage). With an empty
    objective this returns immediately."""
    def _optimize_toward(target: Row) -> SolveResult {
        while True {
            entering = self._get_entering_symbol(target);
            if entering == 0 {
                return SolveResult(ok=True);
            }
            leaving = self._get_leaving_row(entering);
            if leaving == 0 {
                return SolveResult(
                    ok=False,
                    error=SolveError.INTERNAL_INVARIANT,
                    message="objective unbounded",
                );
            }
            row = self.rows.pop(leaving);
            row.solve_for_symbols(leaving, entering);
            self._substitute(entering, row);
            self.rows[entering] = row;
        }
    }

    """First non-dummy cell with negative coefficient, by ascending id
    (kiwi getEnteringSymbol)."""
    def _get_entering_symbol(objective: Row) -> int {
        for symbol in sorted(objective.cells.keys()) {
            if (
                self._kind_of(symbol) != SymbolKind.DUMMY
                and objective.cells[symbol] < 0.0
            ) {
                return symbol;
            }
        }
        return 0;
    }

    """Restricted row with negative entering coefficient minimizing
    -constant/coefficient; ties resolve to the smallest symbol id,
    reproducing kiwi's std::map iteration order (kiwi getLeavingRow)."""
    def _get_leaving_row(entering: int) -> int {
        ratio = 1e308;
        found = 0;
        for symbol in sorted(self.rows.keys()) {
            if self._kind_of(symbol) == SymbolKind.EXTERNAL {
                continue;
            }
            temp = self.rows[symbol].coefficient_for(entering);
            if temp < 0.0 {
                temp_ratio = -self.rows[symbol].constant / temp;
                if temp_ratio < ratio {
                    ratio = temp_ratio;
                    found = symbol;
                }
            }
        }
        return found;
    }
}
