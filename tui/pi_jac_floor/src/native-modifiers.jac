# interop import: node:module { createRequire }
# interop import: node:path { path }
# interop import: node:url { fileURLToPath }

glob cjsRequire = createRequire(__file__);

glob nativeModifiersHelper: any | None = None;

# ===== JS2JAC UNCONVERTED (1 decl(s), needs LLM) =====
# JS2JAC-HOLE[E7200] Declaration produced no output:
# | function isNativeModifiersHelper(value: unknown): value is NativeModifiersHelper {
# | 	if (typeof value !== "object" || value === null) return false;
# | 	const candidate = (value as { isModifierPressed?: unknown }).isModifierPressed;
# | 	return typeof candidate === "function";
# | }
