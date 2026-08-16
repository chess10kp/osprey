"""Pure string edit engine - no imports, no I/O.

Anchor-free module: the placement solver should decide it native. This is the
N1 dogfooding module; tools.jac calls it across the server/native bridge.
"""

"""Replace old_text with new_text in source. old_text must appear exactly once.

Returns the new source on success, or an "ERROR: ..." string describing the
failure so callers can surface it to the model without exceptions.
"""
def apply_edit(source: str, old_text: str, new_text: str) -> str {
    if len(old_text) == 0 {
        return "ERROR: old_text is empty";
    }
    first = source.find(old_text);
    if first == -1 {
        return "ERROR: old_text not found in file";
    }
    second = source.find(old_text, first + len(old_text));
    if second != -1 {
        return "ERROR: old_text matches more than once; add surrounding context to make it unique";
    }
    return source[:first] + new_text + source[first + len(old_text):];
}
