"""Gate harness entry points for OSPUI architecture validation (Unit 13).

Each gate returns success / a metrics report. Implementations fill bodies;
stubs raise until Unit 13 lands. Companion tests in gates.test.jac define
acceptance.
"""


obj Gate2Report {
    has walker_loc: int = 0,
        osp_loc: int = 0,
        callback_loc: int = 0,
        retain_walkers: bool = False,
        advantage: str = "";
}


obj Gate4Report {
    has nodes_queried: int = 0,
        cells_written: int = 0,
        latency_ms: float = 0.0,
        full_frame_cells: int = 0,
        retained_cells: int = 0;
}


"""Gate 1 — Detached graph lifecycle: no UI jids from persistent root; dispose cleans."""
def run_gate1_detached_lifecycle() -> bool {
    raise NotImplementedError("Unit 13: gate1");
}


"""Gate 2 — Arrival dispatch value vs callback-prompt baseline."""
def run_gate2_prompt_vs_callback() -> Gate2Report {
    raise NotImplementedError("Unit 13: gate2");
}


"""Gate 3 — Real layout and damage across shell scenarios."""
def run_gate3_layout_damage() -> bool {
    raise NotImplementedError("Unit 13: gate3");
}


"""Gate 4 — Invalidation benchmark numbers (nodes, cells, latency)."""
def run_gate4_invalidation_bench() -> Gate4Report {
    raise NotImplementedError("Unit 13: gate4");
}


"""Gate 5 — External ProgressBar package without framework-source edits."""
def run_gate5_external_widget() -> bool {
    raise NotImplementedError("Unit 13: gate5");
}


"""Gate 6 — Authoring scale: dozens of regions via markup, no manual ranks."""
def run_gate6_authoring_scale() -> bool {
    raise NotImplementedError("Unit 13: gate6");
}
