"""Constraint solver — Jac port of the Kiwi simplex kernel (M1/M2).

Faithful adaptation of `nucleic/kiwi` `solverimpl.h` / `row.h` / `symbol.h`
(BSD-2), which is also the differential oracle for this project
(LAYOUT-ENGINE-PLAN §8.2). Deviations are documented and deliberate:

- Symbols are plain ints keyed in dicts; the kind lives in a side registry.
  Every iteration runs over sorted ids to reproduce C++ std::map ordering,
  which the oracle comparison depends on for tie-breaking.
- Outcomes are typed results, not exceptions (plan §5.4).
- Strengths use symbolic LexWeight vectors, not Kiwi's scalar encoding. This
  is the deliberate D20 divergence: one STRONG error dominates any finite
  number of MEDIUM/WEAK errors.

Not yet present (later milestones): permanent UI layout types (M4). M3
incrementality — constraint removal with marker pivoting, edit variables /
suggestValue / dualOptimize over an infeasible-row worklist — is complete.
M1 required normalization, slack/dummy handling, deterministic pivoting,
provenance, and exact rollback are complete. M2 adds non-required error
symbols and the lexicographic objective cost row.

Row invariant (as in kiwi/row.h): each row expresses
    constant + sum(cells[sym] * sym) == 0
for its basic symbol. Cells drop when coefficients go near-zero.
"""

import from constraints.algebra {
    EPSILON,
    Constraint,
    Expression,
    LexWeight,
    Relation,
    StrengthTier,
    Term,
    Variable,
    constraint_key,
    is_finite,
    lex_add,
    lex_compare,
    lex_is_negative,
    lex_is_zero,
    lex_neg,
    lex_scale,
    lex_zero,
    near_zero,
    normalize_expression,
    strength_weight,
    term,
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
        # Pre-mutation copy of the lexicographic objective, when touched.
        objective_snapshot: CostRow | None = None,
        # Length of the infeasible-row worklist before this operation.
        infeasible_start: int = 0;
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

    # Shift the row constant; returns the new constant so callers can
    # detect infeasibility (kiwi Row::add).
    def add(delta: float) -> float {
        self.constant += delta;
        return self.constant;
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


# Lexicographic objective row. Tableau rows remain numeric; only objective
# coefficients need symbolic tier arithmetic. The first differing component
# (strong, medium, weak) decides every comparison, so scalar overflow or a
# large count of weak errors can never outweigh one stronger error.
obj CostRow {
    has constant: LexWeight = LexWeight(),
        cells: dict[int, LexWeight] = {};

    def insert_symbol(symbol: int, coefficient: LexWeight) -> None {
        if lex_is_zero(coefficient) {
            return;
        }
        current = self.cells.get(symbol, lex_zero());
        updated = lex_add(current, coefficient);
        if lex_is_zero(updated) {
            self.cells.pop(symbol);
        } else {
            self.cells[symbol] = updated;
        }
    }

    def insert_row(other: Row, coefficient: LexWeight) -> None {
        self.constant = lex_add(
            self.constant,
            lex_scale(coefficient, other.constant),
        );
        for symbol in sorted(other.cells.keys()) {
            self.insert_symbol(
                symbol,
                lex_scale(coefficient, other.cells[symbol]),
            );
        }
    }

    def remove_symbol(symbol: int) -> None {
        if symbol in self.cells {
            self.cells.pop(symbol);
        }
    }

    def clone() -> CostRow {
        copy = CostRow(constant=LexWeight(tiers=[
            self.constant.tiers[0],
            self.constant.tiers[1],
            self.constant.tiers[2],
        ]));
        for symbol in sorted(self.cells.keys()) {
            weight = self.cells[symbol];
            copy.cells[symbol] = LexWeight(tiers=[
                weight.tiers[0], weight.tiers[1], weight.tiers[2],
            ]);
        }
        return copy;
    }

    def substitute(symbol: int, row: Row) -> None {
        coefficient = self.cells.get(symbol);
        if coefficient is None {
            return;
        }
        self.cells.pop(symbol);
        self.insert_row(row, coefficient);
    }
}


# One accepted constraint's normalized content, kept so the tableau can
# be rebuilt under an alternate elimination order (see Solver._replay).
# content_key is stamped once at construction so removal can drop the
# entry without renormalizing every survivor.
obj StoredConstraint {
    has expression: Expression,
        relation: Relation,
        strength: StrengthTier = StrengthTier.REQUIRED,
        provenance: str = "",
        content_key: str = "";
}


# Bookkeeping for one edit variable (kiwi EditInfo). The tag belongs to
# the underlying soft equality constraint; constant is the last accepted
# suggestion.
obj EditInfo {
    has var_id: int,
        key: str,
        handle: ConstraintHandle,
        constant: float = 0.0;
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
        objective: CostRow = CostRow(),
        id_tick: int = 1,
        # Variable ids never collide across table rebuilds.
        next_var_id: int = 1,
        # Accepted constraints in insertion order (rebuild input).
        history: list[StoredConstraint] = [],
        # var id -> edit bookkeeping (kiwi m_edits).
        edits: dict[int, EditInfo] = {},
        # LIFO worklist of possibly-infeasible row symbols (kiwi
        # m_infeasible_rows); drained by dualOptimize after suggestions.
        infeasible_rows: list[int] = [],
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
            self._adopt(rebuilt);
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
            content_key=key,
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

        # Optimize after every mutation. The target is lexicographic, so
        # higher tiers are exhausted before lower tiers are considered.
        return self._optimize_cost(jnl);
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
            content_key=constraint_key(candidate),
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
            content_key=st.content_key,
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
        # Preserve the complete accepted set so a future rebuild after this
        # adoption does not silently forget constraints.
        scratch.history = list(order);
        return scratch;
    }


    def has_constraint(handle: ConstraintHandle) -> bool {
        return handle.id in self.handle_keys;
    }

    def provenance_of(handle: ConstraintHandle) -> str {
        return self.provenance.get(handle.id, "");
    }

    # ------------------------------------------------------------------
    # M3 — removal, edit variables, dual optimization
    # ------------------------------------------------------------------

    def remove_constraint(handle: ConstraintHandle) -> SolveResult {
        if handle.id not in self.handle_keys {
            return SolveResult(ok=False, error=SolveError.UNKNOWN_CONSTRAINT);
        }
        key = self.handle_keys[handle.id];
        if key not in self.cns {
            return SolveResult(ok=False, error=SolveError.UNKNOWN_CONSTRAINT);
        }
        tag = Tag(marker=self.cns[key].marker, other=self.cns[key].other);
        strength = self._strength_for_key(key);
        jnl = self._begin();
        res = self._remove_core(tag, strength, jnl);
        if not res.ok {
            self._rollback(jnl);
            return res;
        }
        self.cns.pop(key);
        self.handle_keys.pop(handle.id);
        self.provenance.pop(handle.id);
        self.history = [
            st for st in self.history if st.content_key != key
        ];
        # An edit variable's underlying constraint was removed underneath
        # it; drop the registration so it cannot suggest again.
        for vid in sorted(self.edits.keys()) {
            if self.edits[vid].key == key {
                self.edits.pop(vid);
            }
        }
        self.generation += 1;
        return res;
    }

    def add_edit_variable(v: Variable, strength: StrengthTier) -> SolveResult {
        if v.id in self.edits {
            return SolveResult(
                ok=False,
                error=SolveError.DUPLICATE_EDIT_VARIABLE,
            );
        }
        if strength == StrengthTier.REQUIRED {
            return SolveResult(
                ok=False,
                error=SolveError.REQUIRED_EDIT_VARIABLE,
                message="edit variables cannot be required",
            );
        }
        # The edit variable is exactly a soft equality v == 0 (kiwi
        # addEditVariable); suggestions move its constant incrementally.
        c = Constraint(
            expression=normalize_expression(term(v)),
            relation=Relation.EQ,
            strength=strength,
        );
        res = self.add_constraint(c);
        if not res.ok {
            return res;
        }
        handle = res.handle;
        if handle is None {
            return SolveResult(
                ok=False,
                error=SolveError.INTERNAL_INVARIANT,
                message="accepted add returned no handle",
            );
        }
        self.edits[v.id] = EditInfo(
            var_id=v.id,
            key=self.handle_keys[handle.id],
            handle=handle,
        );
        return res;
    }

    def remove_edit_variable(v: Variable) -> SolveResult {
        if v.id not in self.edits {
            return SolveResult(ok=False, error=SolveError.UNKNOWN_EDIT_VARIABLE);
        }
        info = self.edits[v.id];
        res = self.remove_constraint(info.handle);
        # remove_constraint already dropped the edits entry for the
        # underlying constraint; nothing further to clean up.
        return res;
    }

    def has_edit_variable(v: Variable) -> bool {
        return v.id in self.edits;
    }

    """Move an edit variable to a suggested value, then restore
    feasibility by dual optimization (kiwi suggestValue under a
    DualOptimizeGuard)."""
    def suggest_value(v: Variable, value: float) -> SolveResult {
        if not is_finite(value) {
            return SolveResult(ok=False, error=SolveError.NON_FINITE_VALUE);
        }
        if v.id not in self.edits {
            return SolveResult(ok=False, error=SolveError.UNKNOWN_EDIT_VARIABLE);
        }
        info = self.edits[v.id];
        if info.key not in self.cns {
            return SolveResult(ok=False, error=SolveError.UNKNOWN_EDIT_VARIABLE);
        }
        delta = value - info.constant;
        jnl = self._begin();
        self._apply_suggestion(info, delta, jnl);
        res = self._dual_optimize(jnl);
        if not res.ok {
            self._rollback(jnl);
            return res;
        }
        info.constant = value;
        self.generation += 1;
        return SolveResult(ok=True);
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
        self.objective = CostRow();
        self.id_tick = 1;
        self.next_var_id = 1;
        self.history = [];
        self.edits = {};
        self.infeasible_rows = [];
        self.generation = 0;
    }

    # Strength of a stored constraint by content key; REQUIRED fallback
    # means "no error effects" for removal.
    def _strength_for_key(key: str) -> StrengthTier {
        for st in self.history {
            if st.content_key == key {
                return st.strength;
            }
        }
        return StrengthTier.REQUIRED;
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
        return MutationJournal(
            id_tick_start=self.id_tick,
            infeasible_start=len(self.infeasible_rows),
        );
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
        # 6. Drop worklist entries recorded during the failed operation.
        del self.infeasible_rows[jnl.infeasible_start:];
    }

    # Canonical pivot (kiwi optimize/dualOptimize body): `leaving` leaves
    # the basis, `entering` replaces it. The row is popped, re-expressed,
    # substituted everywhere (tracking newly infeasible rows), and
    # re-inserted under its entering symbol. `_remove_core` passes
    # reinsert=False: a removed constraint's row leaves the tableau for
    # good (kiwi removeConstraint does not reinsert).
    def _pivot(
        entering: int,
        leaving: int,
        jnl: MutationJournal,
        extra: Row | None = None,
        reinsert: bool = True,
    ) -> None {
        row = self._pop_row(leaving, jnl);
        row.solve_for_symbols(leaving, entering);
        self._substitute(entering, row, jnl, extra);
        if reinsert {
            self._insert_row(entering, row, jnl);
        }
    }

    # Adopt a replayed state bundle wholesale. Every mutable field the
    # rebuild may have changed is swapped here — nothing else in
    # add_constraint touches these — so adoption is all-or-nothing by
    # construction (plan §5.4). handle_keys/provenance/next_handle_id/
    # next_var_id/edits/history are deliberately NOT adopted: content-key
    # identity makes them rebuild-invariant across table rebuilds.
    def _adopt(bundle: Solver) -> None {
        self.rows = bundle.rows;
        self.kinds = bundle.kinds;
        self.var_symbols = bundle.var_symbols;
        self.objective = bundle.objective;
        self.id_tick = bundle.id_tick;
        self.cns = bundle.cns;
        # Stale worklist entries would reference old-symbol ids that now
        # denote different rows in the adopted tableau.
        self.infeasible_rows = bundle.infeasible_rows;
    }

    # ------------------------------------------------------------------
    # M3 internals — removal pivoting and dual simplex
    # ------------------------------------------------------------------

    # One removal against the live tableau (kiwi removeConstraint body).
    def _remove_core(tag: Tag, strength: StrengthTier, jnl: MutationJournal) -> SolveResult {
        # Remove the error effects from the objective BEFORE pivoting, or
        # substitutions into the objective would double-count them.
        self._remove_constraint_effects(tag, strength, jnl);
        marker = tag.marker;
        if marker in self.rows {
            # Marker is basic: simply drop the row.
            self._pop_row(marker, jnl);
        } else {
            leaving = self._get_marker_leaving_row(marker);
            if leaving == 0 {
                return SolveResult(
                    ok=False,
                    error=SolveError.INTERNAL_INVARIANT,
                    message="failed to find leaving row",
                );
            }
            self._pivot(marker, leaving, jnl, reinsert=False);
        }
        # Optimize so the solver stays consistent after removal.
        return self._optimize_cost(jnl);
    }

    def _remove_constraint_effects(
        tag: Tag,
        strength: StrengthTier,
        jnl: MutationJournal,
    ) -> None {
        weight = strength_weight(strength);
        if lex_is_zero(weight) {
            return;
        }
        if self._kind_of(tag.marker) == SymbolKind.ERROR {
            self._remove_marker_effects(tag.marker, weight, jnl);
        }
        if self._kind_of(tag.other) == SymbolKind.ERROR {
            self._remove_marker_effects(tag.other, weight, jnl);
        }
    }

    def _remove_marker_effects(
        marker: int,
        weight: LexWeight,
        jnl: MutationJournal,
    ) -> None {
        self._touch_objective(jnl);
        row = self.rows.get(marker);
        if row is not None {
            self.objective.insert_row(row, lex_neg(weight));
        } else {
            self.objective.insert_symbol(marker, lex_neg(weight));
        }
    }

    # Leaving-row choice for a marker (kiwi getMarkerLeavingRow):
    # 1) restricted row with negative marker coefficient and minimal
    #    -constant/coefficient;
    # 2) restricted row with minimal constant/coefficient;
    # 3) last unrestricted (external-basic) row containing the marker.
    # Sorted-id iteration makes ties resolve deterministically.
    def _get_marker_leaving_row(marker: int) -> int {
        ratio1 = 1e308;
        ratio2 = 1e308;
        first = 0;
        second = 0;
        third = 0;
        for symbol in sorted(self.rows.keys()) {
            coeff = self.rows[symbol].coefficient_for(marker);
            if near_zero(coeff) {
                continue;
            }
            if self._kind_of(symbol) == SymbolKind.EXTERNAL {
                third = symbol;
            } elif coeff < 0.0 {
                r = -self.rows[symbol].constant / coeff;
                if r < ratio1 {
                    ratio1 = r;
                    first = symbol;
                }
            } else {
                r = self.rows[symbol].constant / coeff;
                if r < ratio2 {
                    ratio2 = r;
                    second = symbol;
                }
            }
        }
        if first != 0 {
            return first;
        }
        if second != 0 {
            return second;
        }
        return third;
    }

    # Dual simplex over the infeasible-row worklist (kiwi dualOptimize).
    # Precondition: the objective is optimal but some basic rows have
    # negative constants (after a suggestion moved an edit constant).
    def _dual_optimize(jnl: MutationJournal) -> SolveResult {
        while len(self.infeasible_rows) > 0 {
            leaving = self.infeasible_rows.pop();
            row = self.rows.get(leaving);
            if (
                row is None
                or near_zero(row.constant)
                or row.constant >= 0.0
            ) {
                continue;
            }
            entering = self._get_dual_entering_symbol(row);
            if entering == 0 {
                return SolveResult(
                    ok=False,
                    error=SolveError.INTERNAL_INVARIANT,
                    message="dual optimize failed",
                );
            }
            self._pivot(entering, leaving, jnl);
        }
        return SolveResult(ok=True);
    }

    # Entering symbol for a dual pivot: among the row's cells with
    # positive coefficient, minimize objective-coefficient/cell-coefficient
    # lexicographically (kiwi getDualEnteringSymbol). Ties keep the
    # smallest symbol id via sorted iteration and strict comparison.
    def _get_dual_entering_symbol(row: Row) -> int {
        entering = 0;
        best_coeff = 0.0;
        for symbol in sorted(row.cells.keys()) {
            cell = row.cells[symbol];
            if cell <= 0.0 or self._kind_of(symbol) == SymbolKind.DUMMY {
                continue;
            }
            if entering == 0 or self._dual_ratio_less(
                self._objective_weight(symbol),
                cell,
                self._objective_weight(entering),
                best_coeff,
            ) {
                entering = symbol;
                best_coeff = cell;
            }
        }
        return entering;
    }

    def _objective_weight(symbol: int) -> LexWeight {
        return self.objective.cells.get(symbol, lex_zero());
    }

    # w1/c1 <lex w2/c2 with positive c1, c2, compared cross-multiplied so
    # no division ever happens: w1*c2 <lex w2*c1.
    def _dual_ratio_less(
        w1: LexWeight,
        c1: float,
        w2: LexWeight,
        c2: float,
    ) -> bool {
        return lex_compare(lex_scale(w1, c2), lex_scale(w2, c1)) < 0;
    }

    # Shift every basic occurrence of an edit pair by delta and queue
    # rows left infeasible (kiwi suggestValue body).
    def _apply_suggestion(
        info: EditInfo,
        delta: float,
        jnl: MutationJournal,
    ) -> None {
        marker = self.cns[info.key].marker;
        other = self.cns[info.key].other;
        row = self.rows.get(marker);
        if row is not None {
            self._touch_row(marker, jnl);
            if row.add(-delta) < 0.0 {
                self.infeasible_rows.append(marker);
            }
            return;
        }
        row = self.rows.get(other);
        if row is not None {
            self._touch_row(other, jnl);
            if row.add(delta) < 0.0 {
                self.infeasible_rows.append(other);
            }
            return;
        }
        for symbol in sorted(self.rows.keys()) {
            r = self.rows[symbol];
            coeff = r.coefficient_for(marker);
            if near_zero(coeff) {
                continue;
            }
            self._touch_row(symbol, jnl);
            if r.add(delta * coeff) < 0.0 {
                if self._kind_of(symbol) != SymbolKind.EXTERNAL {
                    self.infeasible_rows.append(symbol);
                }
            }
        }
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
            if c.strength == StrengthTier.REQUIRED {
                # A required inequality has only its non-negative slack.
                tag.other = 0;
            } else {
                # LEQ violation is positive expression, hence -error; GEQ
                # violation is negative expression, hence +error.
                error = self._new_symbol_journaled(SymbolKind.ERROR, jnl);
                tag.other = error;
                row.insert_symbol(error, -coeff);
                self._add_objective(error, strength_weight(c.strength), jnl);
            }
        } else {
            if c.strength == StrengthTier.REQUIRED {
                # Required equality: a dummy marker keeps the basis restricted.
                dummy = self._new_symbol_journaled(SymbolKind.DUMMY, jnl);
                tag.marker = dummy;
                row.insert_symbol(dummy);
            } else {
                # A soft equality needs two non-negative error
                # directions: v == eplus - eminus, i.e. v - eplus +
                # eminus = 0 (kiwi OP_EQ soft case). The marker keeps a
                # NEGATIVE coefficient so chooseSubject can pick it as
                # pivot subject when no external symbol is available.
                plus = self._new_symbol_journaled(SymbolKind.ERROR, jnl);
                minus = self._new_symbol_journaled(SymbolKind.ERROR, jnl);
                tag.marker = plus;
                tag.other = minus;
                row.insert_symbol(plus, -1.0);
                row.insert_symbol(minus, 1.0);
                weight = strength_weight(c.strength);
                self._add_objective(plus, weight, jnl);
                self._add_objective(minus, weight, jnl);
            }
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
        # Track rows driven out of feasibility so a later suggestion's
        # dualOptimize can repair them (kiwi m_infeasible_rows).
        for s in sorted(self.rows.keys()) {
            if (
                self._kind_of(s) != SymbolKind.EXTERNAL
                and self.rows[s].constant < 0.0
                and s not in self.infeasible_rows
            ) {
                self.infeasible_rows.append(s);
            }
        }
    }

    # Add one error symbol to the symbolic objective. If the error is
    # already basic, immediately express its cost through that basic row.
    def _add_objective(
        symbol: int,
        weight: LexWeight,
        jnl: MutationJournal,
    ) -> None {
        if lex_is_zero(weight) {
            return;
        }
        self._touch_objective(jnl);
        self.objective.insert_symbol(symbol, weight);
        if symbol in self.rows {
            self.objective.substitute(symbol, self.rows[symbol]);
        }
    }

    # Phase-2 simplex over the symbolic objective. A negative vector means
    # that entering the symbol improves the first tier that differs; sorted
    # ids make equal-tier choices deterministic. This is multiobjective
    # simplex, not a scalar approximation of Kiwi's objective.
    def _optimize_cost(jnl: MutationJournal) -> SolveResult {
        while True {
            entering = self._get_entering_cost_symbol();
            if entering == 0 {
                return SolveResult(ok=True);
            }
            leaving = self._get_leaving_row(entering);
            if leaving == 0 {
                return SolveResult(
                    ok=False,
                    error=SolveError.INTERNAL_INVARIANT,
                    message="lexicographic objective unbounded",
                );
            }
            self._pivot(entering, leaving, jnl);
        }
    }

    # Phase-2 simplex iterations until a numeric target cost row is minimal
    # (used only by the artificial-variable feasibility phase).
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
            self._pivot(entering, leaving, jnl, extra);
        }
    }

    """First non-dummy cell with negative numeric coefficient."""
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

    """First non-dummy cell with lexicographically negative cost."""
    def _get_entering_cost_symbol() -> int {
        for symbol in sorted(self.objective.cells.keys()) {
            if (
                self._kind_of(symbol) != SymbolKind.DUMMY
                and lex_is_negative(self.objective.cells[symbol])
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
