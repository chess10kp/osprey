"""Runtime smoke for the ported command/path/fuzzy-file autocomplete.

Covers three paths through `CombinedAutocompleteProvider`:
  1. Slash-command completion (`getSuggestions` over a `/` prefix) -- no
     subprocess involved.
  2. Local file completion (`getFileSuggestions`, via the `autocomplete_support`
     `readdirSync` adapter) -- also no subprocess.
  3. Fuzzy-file completion via `fd` (`getFuzzyFileSuggestions`), exercised both
     with a real `fd` binary against an aborted `AbortSignal` (must short-
     circuit to `[]` without ever spawning `fd`) and with a missing binary
     (must catch the failed subprocess and return `[]`, not raise or hang).

No Node/child_process globals remain -- `walkDirectoryWithFd` runs
synchronously via `subprocess.run(..., timeout=...)` (see autocomplete.jac's
module docstring), so this smoke completes instantly with no event loop.

Run: jac run smoke_autocomplete.jac
"""

import from src.autocomplete { CombinedAutocompleteProvider }
import from src.input_support { AbortController }

with entry {
    commands = [
        {"name": "help", "description": "Show help"},
        {"name": "quit", "description": "Quit the app"}
    ];

    # 1. Slash-command completion: "/he" should fuzzy-match "help", not "quit".
    provider = CombinedAutocompleteProvider("src", commands, None);
    result = provider.getSuggestions(["/he"], 0, 3, {"force": False, "signal": None});
    if result is None {
        raise Exception("expected slash-command suggestions, got None");
    }
    items = result["items"];
    if len(items) != 1 {
        raise Exception(f"expected exactly one command match, got {items}");
    }
    if items[0]["value"] != "help" {
        raise Exception(f"expected 'help' match, got {items[0]}");
    }

    # applyCompletion should splice the chosen command back into the line.
    applied = provider.applyCompletion(["/he"], 0, 3, items[0], "/he");
    if applied["lines"][0] != "/help " {
        raise Exception(f"expected '/help ' after completion, got {applied['lines'][0]!r}");
    }

    # A prefix that matches no command yields no suggestions.
    noMatch = provider.getSuggestions(["/zzz"], 0, 4, {"force": False, "signal": None});
    if noMatch is not None {
        raise Exception(f"expected None for unmatched command prefix, got {noMatch}");
    }

    # 2. Local file completion (readdirSync-backed, no fd): "fuzzy" should
    # surface "fuzzy.jac" from the src/ directory.
    fileSuggestions = provider.getFileSuggestions("fuzzy");
    labels = [s["label"] for s in fileSuggestions];
    if "fuzzy.jac" not in labels {
        raise Exception(f"expected 'fuzzy.jac' among local file suggestions, got {labels}");
    }

    # A prefix under a directory that doesn't exist degrades to [] rather than raising.
    noDir = provider.getFileSuggestions("no-such-dir-xyz/thing");
    if noDir != [] {
        raise Exception(f"expected [] for a missing search directory, got {noDir}");
    }

    # 3a. Fuzzy-file path with a real `fd` binary but an ALREADY-ABORTED signal
    # must short-circuit to [] and never spawn the subprocess.
    fdProvider = CombinedAutocompleteProvider("src", [], "fd");
    ac = AbortController();
    ac.abort();
    if not ac.signal.aborted {
        raise Exception("AbortController.abort() did not set signal.aborted");
    }
    aborted_result = fdProvider.getFuzzyFileSuggestions("autocomplete", {"isQuotedPrefix": False, "signal": ac.signal});
    if aborted_result != [] {
        raise Exception(f"expected [] for an aborted fuzzy-file query, got {aborted_result}");
    }

    # 3b. Fuzzy-file path with a missing `fd` binary must catch the failed
    # subprocess and degrade to [] instead of raising or hanging.
    missingFdProvider = CombinedAutocompleteProvider("src", [], "definitely-not-a-real-binary-xyz012");
    ac2 = AbortController();
    missing_result = missingFdProvider.getFuzzyFileSuggestions("autocomplete", {"isQuotedPrefix": False, "signal": ac2.signal});
    if missing_result != [] {
        raise Exception(f"expected [] when the fd binary is missing, got {missing_result}");
    }

    # 3c. Sanity: a live fd walk (not aborted, real binary) actually finds a
    # known file, proving the synchronous subprocess path really runs `fd`
    # rather than silently no-opping every time.
    ac3 = AbortController();
    live_result = fdProvider.getFuzzyFileSuggestions("autocomplete", {"isQuotedPrefix": False, "signal": ac3.signal});
    live_labels = [s["label"] for s in live_result];
    if not any(("autocomplete" in label.lower()) for label in live_labels) {
        raise Exception(f"expected a live fd walk to surface an autocomplete file, got {live_labels}");
    }

    print("smoke_autocomplete OK");
}
