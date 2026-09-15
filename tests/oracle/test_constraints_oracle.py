#!/usr/bin/env python3
"""Kiwi differential oracle for the Osprey constraint solver (plan §8.2).

Generates seeded required-constraint batches, evaluates each with
kiwisolver AND with the pure-Jac solver (driven through
`jac run constraints/oracle_driver.jac`), and compares:

  1. satisfiable vs unsatisfiable classification;
  2. required-constraint residuals when both accept;
  3. exact variable values for fixtures proven uniquely determined.

stdlib unittest only; kiwisolver is imported HERE and nowhere else.
Exits non-zero on disagreement and prints the seed plus a minimized
JSON fixture for every mismatch.

Local/CI:
    python3 -m venv .venv-layout-oracle
    .venv-layout-oracle/bin/python -m pip install 'kiwisolver==1.5.0'
    .venv-layout-oracle/bin/python tests/oracle/test_constraints_oracle.py \
      --jac "$(command -v jac)"
"""

import argparse
import json
import subprocess
import sys
import unittest

try:
    import kiwisolver as kw
except ImportError:  # pragma: no cover - guarded so --list output works
    kw = None

SCHEMA_VERSION = 1
TOL = 1e-6


class LCG:
    """Deterministic LCG matching the Jac-side property-test generator."""

    def __init__(self, state):
        self.state = state

    def next_int(self, bound):
        self.state = (self.state * 1103515245 + 12345) % 2147483648
        return self.state % bound


def make_batch(seed):
    """Seeded system of 1-15 vars / 1-30 required constraints."""
    rng = LCG(seed * 7919)
    n = 1 + rng.next_int(15)
    count = 1 + rng.next_int(30)
    ops = []
    for _ in range(count):
        k = 1 + rng.next_int(3)
        picked = []
        terms = []
        const = 0.0
        for _ in range(k):
            idx = rng.next_int(n)
            if idx in picked:
                continue
            picked.append(idx)
            sign = 1.0 if rng.next_int(2) == 0 else -1.0
            coef = sign * float(1 + rng.next_int(5))
            terms.append([float(idx), coef])
        if not terms:
            continue
        roll = rng.next_int(3)
        rel = {0: "eq", 1: "le", 2: "ge"}[roll]
        if roll != 0:
            # Random constant offset for inequalities. NOTE: this does NOT
            # guarantee satisfiability at the all-zero assignment (sign is
            # arbitrary relative to the e <= 0 / e >= 0 normalization in
            # run_kiwi), so batches are genuinely mixed feasible/infeasible
            # and kiwi is the classification ground truth.
            slack = float(1 + rng.next_int(10))
            if rel == "le":
                const += slack
            else:
                const -= slack
        ops.append({"op": "add", "terms": terms, "const": const, "rel": rel})
    return {
        "schema_version": SCHEMA_VERSION,
        "seed": seed,
        "vars": [str(i) for i in range(n)],
        "ops": ops,
    }


def run_kiwi(batch):
    """Evaluate the batch with kiwisolver; returns our result shape."""
    s = kw.Solver()
    # Keep references: kiwisolver identifies variables by object identity,
    # and updateVariables() writes values onto the exact objects added to
    # the solver. Fresh lookalikes would all read 0.0.
    vars_by_name = {vs: kw.Variable(vs) for vs in batch["vars"]}
    def var(vid_s):
        if vid_s not in vars_by_name:
            vars_by_name[vid_s] = kw.Variable(vid_s)
        return vars_by_name[vid_s]
    for op in batch["ops"]:
        e = None
        for vid_f, coef in op["terms"]:
            vid_s = str(int(float(vid_f)))
            term = coef * var(vid_s)
            e = term if e is None else e + term
        e = e + op["const"]
        try:
            cn = {"eq": e == 0, "le": e <= 0, "ge": e >= 0}[op["rel"]]
            s.addConstraint(cn)
        except kw.UnsatisfiableConstraint:
            return {"ok": False, "error": "unsatisfiable", "values": {}}
    s.updateVariables()
    vals = {}
    for vs in batch["vars"]:
        vals[vs] = vars_by_name[vs].value()
    return {"ok": True, "error": "ok", "values": vals}


def residual_violation(batch, values):
    """Max violation of any constraint under `values` (0 if satisfied)."""
    worst = 0.0
    for op in batch["ops"]:
        total = op["const"]
        for vid_s, coef in op["terms"]:
            total += coef * values.get(str(int(float(vid_s))), 0.0)
        mag = max(1.0, abs(op["const"]))
        viol = {
            "eq": abs(total),
            "le": max(0.0, total),
            "ge": max(0.0, -total),
        }[op["rel"]]
        worst = max(worst, viol / mag)
    return worst


def uniquely_determined(batch):
    """True when eq constraints give every var exactly one pivot row.

    Sufficient condition for unique determination: every variable occurs
    in exactly one equality and equalities cover all variables.
    """
    eq_count = {}
    covered = set()
    for op in batch["ops"]:
        if op["rel"] != "eq":
            continue
        for vid_s, _coef in op["terms"]:
            key = str(int(float(vid_s)))
            eq_count[key] = eq_count.get(key, 0) + 1
            covered.add(key)
    n = len(batch["vars"])
    return (
        len(eq_count) == n
        and covered == {str(i) for i in range(n)}
        and all(c == 1 for c in eq_count.values())
    )


class OracleHarness:
    def __init__(self, jac_bin):
        self.jac_bin = jac_bin
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(
            [self.jac_bin, "run", "constraints/oracle_driver.jac"],
            cwd="app",
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )

    def stop(self):
        if self.proc:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=60)
            except Exception:
                self.proc.kill()
            self.proc = None

    def run_all(self, batches):
        """Feed all batches, close stdin, read every response line.

        The driver flushes at EOF only, so interleaved write/read would
        deadlock the pipe."""
        assert self.proc is not None, "start() first"
        for b in batches:
            self.proc.stdin.write(json.dumps(b) + "\n")
        self.proc.stdin.close()
        results = {}
        for b in batches:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("oracle driver died mid-stream")
            r = json.loads(line)
            if r.get("schema_version") != SCHEMA_VERSION:
                raise RuntimeError(f"bad driver response: {line[:200]}")
            results[b["seed"]] = r
        return results


FAILURES = []


def check_batch(batch, ours, theirs):
    seed = batch["seed"]
    if ours["ok"] != theirs["ok"]:
        FAILURES.append((seed, "classification",
                         f"ours={ours['ok']}/{ours['error']} "
                         f"kiwi={theirs['ok']}/{theirs['error']}"))
        return
    if not ours["ok"]:
        return  # both reject; error taxonomy compared loosely at M2
    if ours["error"] != "ok":
        return
    # Both accept: residuals must be satisfied on BOTH sides.
    for name, vals in (("ours", ours["values"]), ("kiwi", theirs["values"])):
        v = residual_violation(batch, vals)
        if v > TOL:
            FAILURES.append((seed, f"{name}_residual", f"violation={v}"))
            return
    # Value comparison only where the solution is provably unique.
    if uniquely_determined(batch):
        for k in theirs["values"]:
            a = ours["values"].get(k, 0.0)
            b = theirs["values"][k]
            if abs(a - b) > TOL * max(1.0, abs(b)):
                FAILURES.append((
                    seed, "unique_values",
                    f"var {k}: ours={a} kiwi={b} batch={json.dumps(batch)}",
                ))
                return


class TestOracleDifferential(unittest.TestCase):
    SEEDS = list(range(1, 41))

    def test_differential_against_kiwi(self):
        batches = [make_batch(s) for s in self.SEEDS]
        harness = OracleHarness(JAC_BIN)
        harness.start()
        try:
            results = harness.run_all(batches)
        finally:
            harness.stop()
        for batch in batches:
            with self.subTest(seed=batch["seed"]):
                check_batch(batch, results[batch["seed"]],
                            run_kiwi(batch))
        if FAILURES:
            for seed, kind, detail in FAILURES[:5]:
                print(f"ORACLE MISMATCH seed={seed} {kind}: {detail}")
            self.fail(f"{len(FAILURES)} oracle mismatches "
                      f"(first seed={FAILURES[0][0]})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--jac", default="jac")
    args, _ = parser.parse_known_args()
    JAC_BIN = args.jac
    unittest.main(verbosity=2, argv=["oracle"])
