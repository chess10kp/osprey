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
    StrengthTier,
    Variable,
    constraint_key,
    is_finite,
    near_zero,
    normalize_expression,
}
import from constraints.results {
    ConstraintHandle,
    SolveError,
    SolveResult,
    SolverSnapshot,
}


enum SymbolKind {
    INVALID = "invalid",
    EXTERNAL = "external",
    SLACK = "slack",
    ERROR = "error",
    DUMMY = "dummy"
}


# Undo log for one mutating operation (plan §5.4 atomicity).
#
# Records every state change made while adding a constraint so a failed
# operation can be reversed exactly: no residual marker rows, error
# symbols, objective terms, or advanced id counters.
obj MutationJournal {
    has id_tick_start: int = 0,
        # Symbol ids created during this operation.
        allocated_symbols: list[int] = [],
        # External variable ids registered during this operation.
        new_var_ids: list[int] = [],
        # Row keys inserted during this operation (did not exist before).
        inserted_rows: list[int] = [],
        # Pre-mutation deep copies of pre-existing touched rows.
        row_snapshots: dict[int, Row] = {},
        # Pre-mutation copy of the objective row, when touched.
        objective_snapshot: Row | None = None;
}


# Marker pair tracking one constraint's basis presence (kiwi Tag).
obj Tag {
    has marker: int = 0,
        other: int = 0;
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

    # Deep copy used by the rollback journal.
    def clone() -> Row {
        r = Row(constant=self.constant);
        r.cells = dict(self.cells);
        return r;
    }

    def substitute(symbol: int, row: Row) -> None {
        if symbol not in self.cells {
            return;
        }
        coefficient = self.cells.pop(symbol);
        self.insert_row(row, coefficient);
    }
}


# One accepted constraint's normalized content, kept so the tableau can
# be rebuilt under an alternate elimination order (see Solver._replay).
obj StoredConstraint {
    has expression: Expression,
        relation: Relation,
        strength: StrengthTier = StrengthTier.REQUIRED,
        provenance: str = "";
}


obj Solver {
    # Incremental simplex tableau over required constraints.
    has rows: dict[int, Row] = {},
        kinds: dict[int, SymbolKind] = {},
        var_symbols: dict[int, int] = {},
        # Content key -> tag (kiwi m_cns, keyed by constraint identity).
        cns: dict[str, Tag] = {},
        # Handle id -> content key; provenance by handle id.
        handle_keys: dict[int, str] = {},
        provenance: dict[int, str] = {},
        next_handle_id: int = 1,
        objective: Row = Row(),
        id_tick: int = 1,
        # Variable ids never collide across table rebuilds.
        next_var_id: int = 1,
        # Accepted constraints in insertion order (rebuild input).
        history: list[StoredConstraint] = [],
        # Monotonic; increments only on successful mutation (plan §5.4).
        generation: int = 0;

    """Allocate a fresh external variable with a unique id.

    Variable ids and symbol ids share the id_tick sequence but never mix:
    each allocated variable later receives its own distinct external
    symbol via _get_var_symbol (kiwi keeps them in separate namespaces)."""
    def new_variable() -> Variable {
        v = Variable(id=self.next_var_id);
        self.next_var_id += 1;
        return v;
    }

    def add_constraint(c_raw: Constraint, provenance: str = "") -> SolveResult {
        # Finite-value rejection happens on the RAW expression before
        # normalization, which itself asserts finiteness (plan §5.3: typed
        # outcomes, not exceptions, at the interface).
        if not self._expression_is_finite(c_raw.expression) {
            return SolveResult(ok=False, error=SolveError.NON_FINITE_VALUE);
        }
        # Milestone boundary: error symbols and the symbolic objective
        # arrive at M2; before that, non-required strengths are rejected
        # rather than silently treated as required (plan §9 M1/M2).
        if c_raw.strength != StrengthTier.REQUIRED {
            return SolveResult(
                ok=False,
                error=SolveError.INVALID_EXPRESSION,
                message="non-required strengths unsupported until M2",
            );
        }
        c = Constraint(
            expression=normalize_expression(c_raw.expression),
            relation=c_raw.relation,
            strength=c_raw.strength,
        );
        key = constraint_key(c);
        if key in self.cns {
            return SolveResult(
                ok=False,
                error=SolveError.DUPLICATE_CONSTRAINT,
                witness_provenance=self._witness_for_key(key),
            );
        }

        # Fast path: incremental add on the live tableau.
        jnl = self._begin();
        tag = Tag();
        res = self._add_core(c, tag, jnl);
        if not res.ok {
            self._rollback(jnl);
            if res.error != SolveError.UNSATISFIABLE {
                res.witness_provenance = self._witness_extra(provenance);
                return res;
            }
            # DELIBERATE DIVERGENCE FROM KIWI (plan §8.2, decision D20):
            # the upstream kernel's artificial-variable phase is pivot-
            # order sensitive and can spuriously reject feasible required
            # systems depending on symbol allocation order (verified
            # against nucleic/kiwi C++ master). On UNSATISFIABLE we
            # rebuild the whole system from stored history under a small
            # set of fixed deterministic elimination orders and accept if
            # any rebuild admits the new constraint. Failure across all
            # orders is reported as UNSATISFIABLE.
            rebuilt = self._rebuild_admitting(c);
            if rebuilt is None {
                return SolveResult(
                    ok=False,
                    error=SolveError.UNSATISFIABLE,
                    message="required system inconsistent under all "
                            + "elimination orders",
                    witness_provenance=self._witness_extra(provenance),
                );
            }
            self.rows = rebuilt.rows;
            self.kinds = rebuilt.kinds;
            self.var_symbols = rebuilt.var_symbols;
            self.objective = rebuilt.objective;
            self.id_tick = rebuilt.id_tick;
            self.cns = rebuilt.cns;
        }

        # Commit: register handle + provenance, bump generation. On the
        # fast path the tag comes from the live add; after a rebuild the
        # rebuilt tags are already installed under the same content keys.
        handle = ConstraintHandle(id=self.next_handle_id);
        self.next_handle_id += 1;
        if key not in self.cns {
            self.cns[key] = tag;
        }
        self.handle_keys[handle.id] = key;
        self.provenance[handle.id] = provenance;
        self.history.append(StoredConstraint(
            expression=c.expression,
            relation=c.relation,
            strength=c.strength,
            provenance=provenance,
        ));
        self.generation += 1;
        return SolveResult(ok=True, handle=handle);

    }


    """One incremental add against the live tableau (kiwi addConstraint
    body). Fills `tag`; journal covers every mutation for rollback."""
    def _add_core(c: Constraint, tag: Tag, jnl: MutationJournal) -> SolveResult {
        row = self._create_row(c, tag, jnl);
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
            if not self._add_with_artificial_variable(row, jnl) {
                return SolveResult(
                    ok=False,
                    error=SolveError.UNSATISFIABLE,
                    message="artificial variable could not reach zero",
                );
            }
        } else {
            row.solve_for(subject);
            self._substitute(subject, row, jnl);
            self._insert_row(subject, row, jnl);
        }

        # Optimizing after every mutation keeps the tableau consistent
        # with smaller average work than batch optimizing (kiwi
        # addConstraint comment). Empty objective => immediate return.
        return self._optimize_toward(self.objective, jnl);
    }

    """Rebuild the full stored history plus `candidate` from scratch under
    a few fixed deterministic elimination orders. Returns an adopted
    Solver-state bundle if any order admits everything, else None.

    This is the documented divergence from kiwi: upstream can spuriously
    reject feasible required systems depending on symbol allocation
    order; we bound-check with alternative orders instead of trusting a
    single pivot path (decision D20)."""
    def _rebuild_admitting(candidate: Constraint) -> Solver | None {
        stored: list[StoredConstraint] = list(self.history);
        stored.append(StoredConstraint(
            expression=candidate.expression,
            relation=candidate.relation,
            strength=candidate.strength,
        ));

        orders: list[list[StoredConstraint]] = [
            stored,
            [self._terms_reversed(st) for st in stored],
            list(reversed(stored)),
            [self._terms_reversed(st) for st in reversed(stored)],
        ];

        for order in orders {
            attempt = self._replay_all(order);
            if attempt is not None {
                return attempt;
            }
        }
        return None;
    }

    def _terms_reversed(st: StoredConstraint) -> StoredConstraint {
        terms_rev = [];
        for t in st.expression.terms {
            terms_rev.append(Term(
                variable=Variable(id=t.variable.id),
                coefficient=t.coefficient,
            ));
        }
        return StoredConstraint(
            expression=Expression(terms=terms_rev, constant=st.expression.constant),
            relation=st.relation,
            strength=st.strength,
            provenance=st.provenance,
        );
    }

    """Fresh-tableau replay of `order`. Returns a state bundle on success
    (self untouched) or None on any failure."""
    def _replay_all(order: list[StoredConstraint]) -> Solver | None {
        # Replay on a scratch tableau so `self` stays untouched unless the
        # caller adopts the result.
        scratch = Solver();
        tags: dict[str, Tag] = {};
        for st in order {
            c = Constraint(
                expression=st.expression,
                relation=st.relation,
                strength=st.strength,
            );
            jnl = scratch._begin();
            tag = Tag();
            res = scratch._add_core(c, tag, jnl);
            if not res.ok {
                return None;
            }
            key = constraint_key(c);
            tags[key] = tag;
        }
        scratch.cns = tags;
        return scratch;
    }


    def has_constraint(handle: ConstraintHandle) -> bool {
        return handle.id in self.handle_keys;
    }

    def provenance_of(handle: ConstraintHandle) -> str {
        return self.provenance.get(handle.id, "");
    }

    # Snapshot of external values plus generation (plan §5.4).
    def snapshot() -> SolverSnapshot {
        vals: dict[int, float] = {};
        for vid in sorted(self.var_symbols.keys()) {
            symbol = self.var_symbols[vid];
            if symbol in self.rows {
                vals[vid] = self.rows[symbol].constant;
            } else {
                vals[vid] = 0.0;
            }
        }
        return SolverSnapshot(generation=self.generation, values=vals);
    }

    def reset() -> None {
        self.rows = {};
        self.kinds = {};
        self.var_symbols = {};
        self.cns = {};
        self.handle_keys = {};
        self.provenance = {};
        self.next_handle_id = 1;
        self.objective = Row();
        self.id_tick = 1;
        self.generation = 0;
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

    # ------------------------------------------------------------------
    # journal plumbing — every mutation routes through these
    # ------------------------------------------------------------------

    def _begin() -> MutationJournal {
        return MutationJournal(id_tick_start=self.id_tick);
    }

    # Witness provenance for a duplicate-content rejection.
    def _witness_for_key(key: str) -> list[str] {
        out: list[str] = [];
        for hid in sorted(self.handle_keys.keys()) {
            if self.handle_keys[hid] == key and self.provenance.get(hid, "") != "" {
                out.append(self.provenance[hid]);
            }
        }
        return out;
    }

    def _witness_extra(extra: str) -> list[str] {
        if extra == "" {
            return [];
        }
        return [extra];
    }

    def _new_symbol(kind: SymbolKind) -> int {
        symbol = self.id_tick;
        self.id_tick += 1;
        self.kinds[symbol] = kind;
        return symbol;
    }

    def _new_symbol_journaled(kind: SymbolKind, jnl: MutationJournal) -> int {
        symbol = self._new_symbol(kind);
        jnl.allocated_symbols.append(symbol);
        return symbol;
    }

    def _get_var_symbol(v: Variable, jnl: MutationJournal | None = None) -> int {
        if v.id in self.var_symbols {
            return self.var_symbols[v.id];
        }
        symbol = self._new_symbol(SymbolKind.EXTERNAL);
        self.var_symbols[v.id] = symbol;
        if jnl is not None {
            jnl.new_var_ids.append(v.id);
            jnl.allocated_symbols.append(symbol);
        }
        return symbol;
    }

    # Insert a row that did not exist before this operation.
    def _insert_row(symbol: int, row: Row, jnl: MutationJournal) -> None {
        if (
            symbol not in jnl.inserted_rows
            and symbol not in jnl.row_snapshots
        ) {
            jnl.inserted_rows.append(symbol);
        }
        self.rows[symbol] = row;
    }

    # Snapshot a pre-existing row once before its first mutation.
    def _touch_row(symbol: int, jnl: MutationJournal) -> None {
        if (
            symbol in self.rows
            and symbol not in jnl.row_snapshots
            and symbol not in jnl.inserted_rows
        ) {
            jnl.row_snapshots[symbol] = self.rows[symbol].clone();
        }
    }

    def _touch_objective(jnl: MutationJournal) -> None {
        if jnl.objective_snapshot is None {
            jnl.objective_snapshot = self.objective.clone();
        }
    }

    def _pop_row(symbol: int, jnl: MutationJournal) -> Row {
        self._touch_row(symbol, jnl);
        return self.rows.pop(symbol);
    }

    # Reverse every recorded change exactly (plan §5.4).
    def _rollback(jnl: MutationJournal) -> None {
        # 1. Drop rows created during the operation.
        for symbol in reversed(jnl.inserted_rows) {
            if symbol in self.rows {
                self.rows.pop(symbol);
            }
        }
        # 2. Restore pre-existing rows to pre-mutation state; re-inserts
        #    rows optimize() may have moved or removed.
        for symbol in sorted(jnl.row_snapshots.keys()) {
            self.rows[symbol] = jnl.row_snapshots[symbol].clone();
        }
        # 3. Restore the objective row.
        if jnl.objective_snapshot is not None {
            self.objective = jnl.objective_snapshot.clone();
        }
        # 4. Unregister external variables introduced here.
        for vid in reversed(jnl.new_var_ids) {
            self.var_symbols.pop(vid);
        }
        # 5. Release symbols and rewind the id counter.
        for symbol in reversed(jnl.allocated_symbols) {
            self.kinds.pop(symbol);
        }
        self.id_tick = jnl.id_tick_start;
    }

    def _create_row(c: Constraint, tag: Tag, jnl: MutationJournal) -> Row {
        row = Row(constant=c.expression.constant);
        # Substitute already-basic variables from the current tableau.
        for t in c.expression.terms {
            if not near_zero(t.coefficient) {
                symbol = self._get_var_symbol(t.variable, jnl);
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
            slack = self._new_symbol_journaled(SymbolKind.SLACK, jnl);
            tag.marker = slack;
            row.insert_symbol(slack, coeff);
            # Error symbols for non-required strengths arrive at M2.
        } else {
            # Required equality: a dummy marker keeps the basis restricted.
            dummy = self._new_symbol_journaled(SymbolKind.DUMMY, jnl);
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

        # Add via artificial variable; False means unsatisfiable
    # (kiwi addWithArtificialVariable).
    def _add_with_artificial_variable(row: Row, jnl: MutationJournal) -> bool {
        art = self._new_symbol_journaled(SymbolKind.SLACK, jnl);
        art_row = Row(constant=row.constant);
        art_row.cells = dict(row.cells);
        self._insert_row(art, art_row, jnl);

        # Artificial cost row; kept in sync by every pivot below
        # (kiwi m_artificial, substituted inside substitute()).
        artificial = Row(constant=row.constant);
        artificial.cells = dict(row.cells);
        self._optimize_toward(artificial, jnl, artificial);

        success = near_zero(artificial.constant);

        if art in self.rows {
            pivot_row = self._pop_row(art, jnl);
            if len(pivot_row.cells) > 0 {
                entering = self._any_pivotable_symbol(pivot_row);
                if entering == 0 {
                    return False;
                }
                pivot_row.insert_symbol(art, -1.0);
                pivot_row.solve_for(entering);
                self._substitute(entering, pivot_row, jnl, artificial);
                self._insert_row(entering, pivot_row, jnl);
            }
        }

        for symbol in sorted(self.rows.keys()) {
            self._touch_row(symbol, jnl);
            self.rows[symbol].remove_symbol(art);
        }
        self._touch_objective(jnl);
        self.objective.remove_symbol(art);
        return success;
    }

    def _substitute(
        symbol: int,
        row: Row,
        jnl: MutationJournal,
        extra: Row | None = None,
    ) -> None {
        for s in sorted(self.rows.keys()) {
            self._touch_row(s, jnl);
            r = self.rows[s];
            r.substitute(symbol, row);
            # Negative non-external constants would be tracked for
            # dualOptimize from M3 onward (kiwi m_infeasible_rows).
        }
        self._touch_objective(jnl);
        self.objective.substitute(symbol, row);
        # The artificial cost row participates in its own pivots
        # (kiwi substitutes into m_artificial when present).
        if extra is not None {
            extra.substitute(symbol, row);
        }
    }

    # Phase-2 simplex iterations until the target cost row is minimal
    # (kiwi optimize / addWithArtificialVariable usage). With an empty
    # objective this returns immediately.
    def _optimize_toward(
        target: Row,
        jnl: MutationJournal,
        extra: Row | None = None,
    ) -> SolveResult {
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
            row = self._pop_row(leaving, jnl);
            row.solve_for_symbols(leaving, entering);
            self._substitute(entering, row, jnl, extra);
            self._insert_row(entering, row, jnl);
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
