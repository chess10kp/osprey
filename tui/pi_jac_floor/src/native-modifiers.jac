# interop import: node:module { createRequire }
# interop import: node:path { path }
# interop import: node:url { fileURLToPath }

glob cjsRequire = createRequire(__file__);

glob nativeModifiersHelper: any | None = None;

def isNativeModifiersHelper(value: any) -> bool {
    if ((not ((value is not None) and (not isinstance(value, (str, int, float, bool))) and (not callable(value)))) or (value == None)) {
        return False;
    }
    candidate = value.isModifierPressed;
    return bool(callable(candidate));
}

def loadNativeModifiersHelper() -> any | None {
    if (nativeModifiersHelper != None) {
        return ((lambda (_jx_null0: any) -> any { return (_jx_null0 if _jx_null0 is not None else None); })(nativeModifiersHelper));
    }
    nativeModifiersHelper = None;
    if (process.platform != "darwin") {
        return None;
    }
    arch = process.arch;
    if ((arch != "x64") and (arch != "arm64")) {
        return None;
    }
    moduleDir = path.dirname(fileURLToPath(__file__));
    nativePath = "native".join(path);
    candidates = [moduleDir.join(path), moduleDir.join(path), path.dirname(process.execPath).join(path)];
    for modulePath in candidates {
        try {
            helper = cjsRequire(modulePath);
            if isNativeModifiersHelper(helper) {
                nativeModifiersHelper = helper;
                return (helper as any | None);
            }
        }
        except Exception {
        }
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
