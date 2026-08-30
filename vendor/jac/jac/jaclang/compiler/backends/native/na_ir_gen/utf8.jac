import from jaclang.compiler.backends.native.llvm { ir }
import from jaclang.compiler.backends.native.na_ir_gen.state { NaIRGenState }

# UTF-8 codepoint semantics for native strings.
#
# Native strings are NUL-terminated UTF-8 byte buffers (i8*). Python parity
# requires len/index/slice/iteration/ord/chr/find to operate on CODEPOINTS,
# not bytes. This ability emits small private helper functions into each
# module and exposes call sites for the string codegen paths. All helpers
# take explicit byte lengths where the buffer may be a non-NUL-terminated
# view (str descriptors).
obj NaIRGenUtf8Strings(NaIRGenState) {
    def _emit_utf8_helpers -> None;
    def _call_utf8_cplen(
        b: ir.IRBuilder, ptr: ir.Value, nbytes: ir.Value, name: str = "u8.cplen"
    ) -> ir.Value;
    def _call_utf8_cp_off(
        b: ir.IRBuilder,
        ptr: ir.Value,
        nbytes: ir.Value,
        cp_index: ir.Value,
        name: str = "u8.cpoff"
    ) -> ir.Value;
    def _call_utf8_cp_len_at(
        b: ir.IRBuilder, ptr: ir.Value, off: ir.Value, name: str = "u8.cplenat"
    ) -> ir.Value;
    def _call_utf8_cp_at_off(
        b: ir.IRBuilder, ptr: ir.Value, off: ir.Value, name: str = "u8.cpat"
    ) -> ir.Value;
    def _call_utf8_ord(
        b: ir.IRBuilder, ptr: ir.Value, name: str = "u8.ord"
    ) -> ir.Value;
    def _call_utf8_chr(
        b: ir.IRBuilder, cp: ir.Value, name: str = "u8.chr"
    ) -> ir.Value;
    def _call_utf8_advance(
        b: ir.IRBuilder,
        ptr: ir.Value,
        off: ir.Value,
        delta: ir.Value,
        name: str = "u8.adv"
    ) -> ir.Value;
}
