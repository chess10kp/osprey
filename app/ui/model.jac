"""OSP-backed UI model for Jackal's differential terminal renderer.

The live component tree is a graph of UiNode values connected by ordered Child
edges. Render and input closures stay in process-local UiRuntime maps so graph
nodes remain data-only. UiComponent is the thin adapter for the existing terminal
shape: render(width), handleInput(data), and invalidate().

Signals invalidate only their dependent leaves and those leaves' ancestors.
Rendering remains a cached list[str] projection; ANSI frame comparison stays in
the terminal renderer and does not traverse the signal graph.
"""


node UiNode {
    has runtime_id: str,
        kind: str = "view",
        key: str = "",
        dirty: bool = True,
        cached_width: int = -1,
        cached_lines: list[str] = [];
}


node SignalNode {
    has runtime_id: str,
        value: object = None;
}


edge Child: UiNode --> UiNode {
    has order: int = 0;
}


edge Feeds: SignalNode --> UiNode {}
edge OwnsSignal: UiNode --> SignalNode {}


walker InvalidateAncestors {
    has seen: set[str] = set(),
        changed: bool = False;

    can mark with UiNode entry {
        if here.runtime_id in self.seen {
            skip;
        }
        self.seen.add(here.runtime_id);
        if not here.dirty {
            self.changed = True;
        }
        here.dirty = True;
        here.cached_width = -1;
        here.cached_lines = [];
        visit [here <-:Child:<-];
    }
}


walker InvalidateSubtree {
    has changed: bool = False;

    can mark with UiNode entry {
        if not here.dirty {
            self.changed = True;
        }
        here.dirty = True;
        here.cached_width = -1;
        here.cached_lines = [];
        visit [here ->:Child:->];
    }
}


walker DisposeUi {
    has nodes: list[UiNode] = [];

    can descend with UiNode entry {
        visit [here ->:Child:->];
    }

    can collect with UiNode exit {
        self.nodes.append(here);
    }
}


obj RenderContext {
    has target: UiNode,
        reads: list[SignalNode] = [];
}


obj OrderedChild {
    has order: int,
        node: UiNode;
}


obj UiRuntime {
    has renderers: dict[str, any] = {},
        input_handlers: dict[str, any] = {},
        cleanups: dict[str, list[any]] = {},
        render_request: any = None;
}


glob _runtime: UiRuntime | None = None;
glob _runtime_id_seq: int = 0;
glob _render_stack: list[RenderContext] = [];


def ui_runtime -> UiRuntime {
    if _runtime is None {
        _runtime = UiRuntime();
    }
    return _runtime;
}


"""Reset process-local registries. Intended for isolated tests and reboot."""
def reset_ui_runtime {
    _runtime = UiRuntime();
    _render_stack = [];
}


def next_runtime_id(prefix: str) -> str {
    _runtime_id_seq += 1;
    return prefix + "-" + str(_runtime_id_seq);
}


"""Install the renderer's requestRender callback."""
def set_render_request_hook(fn: any) {
    ui_runtime().render_request = fn;
}


"""Create one data-only UI node and register its process-local behavior."""
def view(
    render_fn: any,
    input_fn: any = None,
    kind: str = "view",
    key: str = "",
) -> UiNode {
    n = UiNode(runtime_id=next_runtime_id("ui"), kind=kind, key=key);
    rt = ui_runtime();
    rt.renderers[n.runtime_id] = render_fn;
    if input_fn is not None {
        rt.input_handlers[n.runtime_id] = input_fn;
    }
    return n;
}


"""Create a vertical container that concatenates ordered child frames."""
def column(children: list[UiNode] | None = None, key: str = "") -> UiNode {
    n = view(_render_column, kind="column", key=key);
    for child in (children if children is not None else []) {
        mount(n, child);
    }
    return n;
}


def _render_column(n: UiNode, width: int) -> list[str] {
    return render_children(n, width);
}


"""Create a writable reactive value, optionally scoped to one UI subtree."""
def signal(initial: object, owner: UiNode | None = None) -> SignalNode {
    s = SignalNode(runtime_id=next_runtime_id("signal"), value=initial);
    if owner is not None {
        owner +>:OwnsSignal:+> s;
    }
    return s;
}


"""Read a signal and record the current leaf's exact dependency."""
def read_signal(s: SignalNode) -> object {
    if _render_stack {
        ctx = _render_stack[-1];
        if s not in ctx.reads {
            ctx.reads.append(s);
        }
    }
    return s.value;
}


"""Write with equality cutoff, then invalidate dependent render paths."""
def set_signal(s: SignalNode, value: object) {
    if value == s.value {
        return;
    }
    s.value = value;
    changed = False;
    for target in [s ->:Feeds:->] {
        w = InvalidateAncestors();
        target spawn w;
        changed = changed or w.changed;
    }
    request_render_if(changed);
}


"""Tie a signal's lifetime to a UI subtree."""
def own_signal(owner: UiNode, s: SignalNode) {
    owners = [s <-:OwnsSignal:<-];
    if owner in owners {
        return;
    }
    if owners {
        raise ValueError("Signal already has an owner: " + s.runtime_id);
    }
    owner +>:OwnsSignal:+> s;
}


def ordered_children(parent: UiNode) -> list[UiNode] {
    pairs: list[OrderedChild] = [];
    for child in [parent ->:Child:->] {
        for e in [edge parent ->:Child:-> child] {
            pairs.append(OrderedChild(order=e.order, node=child));
        }
    }
    pairs.sort(key=_child_pair_order);
    return [pair.node for pair in pairs];
}


def _child_pair_order(pair: OrderedChild) -> int {
    return pair.order;
}


def render_children(parent: UiNode, width: int) -> list[str] {
    lines: list[str] = [];
    for child in ordered_children(parent) {
        lines.extend(render_node(child, width));
    }
    return lines;
}


"""Attach a child at an ordered position. A node can have one parent."""
def mount(parent: UiNode, child: UiNode, index: int = -1) {
    parents = [child <-:Child:<-];
    if parents {
        raise ValueError("UI node is already mounted: " + child.runtime_id);
    }
    current = ordered_children(parent);
    pos = len(current) if index < 0 else max(0, min(index, len(current)));
    for existing in current[pos:] {
        for e in [edge parent ->:Child:-> existing] {
            e.order += 1;
        }
    }
    parent +>:Child(order=pos):+> child;
    invalidate_ancestors(parent);
}


"""Move one mounted child without rebuilding its subtree."""
def move(child: UiNode, index: int) {
    parents = [child <-:Child:<-];
    if len(parents) != 1 {
        raise ValueError("UI node must have exactly one parent to move");
    }
    parent = parents[0];
    children = ordered_children(parent);
    children.remove(child);
    pos = max(0, min(index, len(children)));
    children.insert(pos, child);
    _sync_child_order(parent, children);
    invalidate_ancestors(parent);
}


"""Detach a subtree and optionally release all of its runtime behavior."""
def unmount(child: UiNode, dispose: bool = True) {
    parents = [child <-:Child:<-];
    for parent in parents {
        for e in [edge parent ->:Child:-> child] {
            del e;
        }
        _sync_child_order(parent, ordered_children(parent));
        invalidate_ancestors(parent);
    }
    if dispose {
        dispose_tree(child);
    }
}


def _sync_child_order(parent: UiNode, children: list[UiNode]) {
    for (index, child) in enumerate(children) {
        for e in [edge parent ->:Child:-> child] {
            e.order = index;
        }
    }
}


"""Project one node through its cached process-local renderer."""
def render_node(n: UiNode, width: int) -> list[str] {
    if not n.dirty and n.cached_width == width {
        return list(n.cached_lines);
    }
    fn = ui_runtime().renderers.get(n.runtime_id);
    if fn is None {
        return [];
    }
    ctx = RenderContext(target=n);
    _render_stack.append(ctx);
    try {
        lines = fn(n, width);
    } finally {
        _render_stack.pop();
    }
    commit_dependencies(n, ctx.reads);
    n.cached_width = width;
    n.cached_lines = list(lines);
    n.dirty = False;
    return list(n.cached_lines);
}


"""Replace a leaf's Feeds set after a successful render."""
def commit_dependencies(target: UiNode, dependencies: list[SignalNode]) {
    old = [target <-:Feeds:<-];
    for source in old {
        if source not in dependencies {
            for e in [edge source ->:Feeds:-> target] {
                del e;
            }
        }
    }
    for source in dependencies {
        if source not in old {
            source +>:Feeds:+> target;
        }
    }
}


def handle_input(n: UiNode, data: str) {
    handler = ui_runtime().input_handlers.get(n.runtime_id);
    if handler is not None {
        handler(n, data);
    }
}


def invalidate_ancestors(n: UiNode) {
    w = InvalidateAncestors();
    n spawn w;
    request_render_if(w.changed);
}


"""Invalidate one subtree and its ancestor projection caches."""
def invalidate_tree(n: UiNode) {
    down = InvalidateSubtree();
    n spawn down;
    up = InvalidateAncestors();
    for parent in [n <-:Child:<-] {
        parent spawn up;
    }
    request_render_if(down.changed or up.changed);
}


def request_render_if(changed: bool) {
    hook = ui_runtime().render_request;
    if changed and hook is not None {
        hook();
    }
}


"""Release closures, dependencies, handlers, and owned signals."""
def teardown_node(n: UiNode) {
    rt = ui_runtime();
    for fn in reversed(rt.cleanups.pop(n.runtime_id, [])) {
        fn();
    }
    rt.renderers.pop(n.runtime_id, None);
    rt.input_handlers.pop(n.runtime_id, None);
    for source in [n <-:Feeds:<-] {
        for e in [edge source ->:Feeds:-> n] {
            del e;
        }
    }
    for owned in list([n ->:OwnsSignal:->]) {
        dispose_signal(owned);
    }
}


def dispose_signal(s: SignalNode) {
    for target in [s ->:Feeds:->] {
        for e in [edge s ->:Feeds:-> target] {
            del e;
        }
    }
    del s;
}


"""Post-order teardown and deletion of one live UI subtree."""
def dispose_tree(n: UiNode) {
    parents = list([n <-:Child:<-]);
    for parent in parents {
        for e in [edge parent ->:Child:-> n] {
            del e;
        }
    }
    w = DisposeUi();
    n spawn w;
    for dead in w.nodes {
        teardown_node(dead);
        del dead;
    }
    for parent in parents {
        _sync_child_order(parent, ordered_children(parent));
        invalidate_ancestors(parent);
    }
}


def on_cleanup(n: UiNode, fn: any) {
    ui_runtime().cleanups.setdefault(n.runtime_id, []).append(fn);
}


obj UiComponent {
    has root_view: UiNode,
        focused: bool = False;

    def render(width: float) -> list[str] {
        return render_node(self.root_view, int(width));
    }

    def handleInput(data: str) {
        handle_input(self.root_view, data);
    }

    def invalidate {
        invalidate_tree(self.root_view);
    }
}


"""Adapt an OSP subtree to the existing terminal Component interface."""
def project(root_view: UiNode) -> UiComponent {
    return UiComponent(root_view=root_view);
}


def registered_view_count -> int {
    return len(ui_runtime().renderers);
}
