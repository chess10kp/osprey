import from "events" { EventEmitter }

glob ESC = "";

glob BRACKETED_PASTE_START = "[200~";

glob BRACKETED_PASTE_END = "[201~";

def isCompleteOscSequence(data: str) -> any {
    if not data.startswith(f"{ESC}]") {
        return "complete";
    }
    if (data.endswith(f"{ESC}\\\\") or data.endswith("")) {
        return "complete";
    }
    return "incomplete";
}

def isCompleteDcsSequence(data: str) -> any {
    if not data.startswith(f"{ESC}P") {
        return "complete";
    }
    if data.endswith(f"{ESC}\\\\") {
        return "complete";
    }
    return "incomplete";
}

def isCompleteApcSequence(data: str) -> any {
    if not data.startswith(f"{ESC}_") {
        return "complete";
    }
    if data.endswith(f"{ESC}\\\\") {
        return "complete";
    }
    return "incomplete";
}
