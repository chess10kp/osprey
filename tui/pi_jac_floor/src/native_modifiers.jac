"""Native modifier-key probe (native-modifiers.ts), Jac-native.

The original loads a macOS-only native addon (`native/.../*.node`) through
`createRequire` and asks it whether a modifier is physically held. The Jac
(CPython) runtime cannot dlopen a Node `.node` addon, so this helper is
unavailable here exactly as it is on any non-macOS Node host: it degrades to
"no native helper", and isNativeModifierPressed() always reports False.

The platform/arch gate is preserved (via the terminal_support process adapter)
so the degradation reason matches the source; only the unreachable native
require loop is dropped. The original's `nativeModifiersHelper` module-cache
reassignment is also removed -- reassigning a module glob inside a function is
an UnboundLocalError under the Jac runtime.
"""

import from .terminal_support { process }

def isNativeModifiersHelper(value: any) -> bool {
    if ((not ((value is not None) and (not isinstance(value, (str, int, float, bool))) and (not callable(value)))) or (value == None)) {
        return False;
    }
    candidate = value.isModifierPressed;
    return bool(callable(candidate));
}

def loadNativeModifiersHelper() -> any | None {
    # No Node `.node` addon is loadable under Jac; on macOS Node this is where the
    # native helper would be required. Everywhere else it is simply absent.
    if (process.platform != "darwin") {
        return None;
    }
    arch = process.arch;
    if ((arch != "x64") and (arch != "arm64")) {
        return None;
    }
    return None;
}

def:pub isNativeModifierPressed(key: any) -> bool {
    helper = loadNativeModifiersHelper();
    if not helper {
        return False;
    }
    try {
        return ((helper["isModifierPressed"] as any)(key) == True);
    }
    except Exception {
        return False;
    }
}
