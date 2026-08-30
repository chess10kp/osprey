import from jaclang.compiler.backends.native.llvm { ir }

# Emits UTF-8 codepoint helper functions into the current module (private
# linkage, emitted once) and exposes call sites. Semantics: strings are
# UTF-8 byte buffers; "cp" = unicode codepoint. Byte lengths are passed
# explicitly so non-NUL-terminated views (str descriptors) work too.
impl NaIRGenUtf8Strings._emit_utf8_helpers -> None {
    if self.utf8_cplen_fn is not None {
        return;
    }
    if self.rc_alloc_fn is None {
        self._emit_rc_helpers();
    }
    if self.str_len_fn is None {
        self._emit_str_len_helpers();
    }
    i8 = ir.IntType(8);
    i8p = i8.as_pointer();
    i64 = ir.IntType(64);
    zero = ir.Constant(i64, 0);
    one = ir.Constant(i64, 1);
    _hl = self._nogc_headerless();

    # --- __jac_utf8_cplen(i8p s, i64 n) -> i64 : count codepoints ---
    cplen_fn = self._define_function(
        "__jac_utf8_cplen", ir.FunctionType(i64, [i8p, i64])
    );
    cplen_fn.linkage = "private";
    cplen_fn.args[0].name = "s";
    cplen_fn.args[1].name = "n";
    _u_entry = cplen_fn.append_basic_block("entry");
    _u_chk = cplen_fn.append_basic_block("chk");
    _u_body = cplen_fn.append_basic_block("body");
    _u_done = cplen_fn.append_basic_block("done");
    b = ir.IRBuilder(_u_entry);
    b.branch(_u_chk);
    b = ir.IRBuilder(_u_chk);
    ui = b.phi(i64, name="u8cp.i");
    ui.add_incoming(zero, _u_entry);
    uc = b.phi(i64, name="u8cp.c");
    uc.add_incoming(zero, _u_entry);
    ugo = b.icmp_unsigned("<", ui, cplen_fn.args[1], name="u8cp.go");
    b.cbranch(ugo, _u_body, _u_done);
    b = ir.IRBuilder(_u_body);
    ub_p = b.gep(cplen_fn.args[0], [ui], name="u8cp.p");
    ub8 = b.load(ub_p, name="u8cp.b");
    ubv = b.zext(ub8, i64, name="u8cp.bv");
    uhi = b.icmp_unsigned(">=", ubv, ir.Constant(i64, 0xC0), name="u8cp.hi");
    ulo = b.icmp_unsigned("<", ubv, ir.Constant(i64, 0x80), name="u8cp.lo");
    ulead = b.or_(uhi, ulo, name="u8cp.lead");
    uc1 = b.select(
        ulead, b.add(uc, one, name="u8cp.cinc"), uc, name="u8cp.c1"
    );
    ui1 = b.add(ui, one, name="u8cp.i1");
    ui.add_incoming(ui1, _u_body);
    uc.add_incoming(uc1, _u_body);
    b.branch(_u_chk);
    b = ir.IRBuilder(_u_done);
    b.ret(uc);
    self.utf8_cplen_fn = cplen_fn;

    # --- __jac_utf8_cp_off(i8p s, i64 n, i64 k) -> i64 : byte offset of
    # --- the k-th codepoint (clamped to n when out of range) ---
    cpoff_fn = self._define_function(
        "__jac_utf8_cp_off", ir.FunctionType(i64, [i8p, i64, i64])
    );
    cpoff_fn.linkage = "private";
    cpoff_fn.args[0].name = "s";
    cpoff_fn.args[1].name = "n";
    cpoff_fn.args[2].name = "k";
    _o_entry = cpoff_fn.append_basic_block("entry");
    _o_chk = cpoff_fn.append_basic_block("chk");
    _o_body = cpoff_fn.append_basic_block("body");
    _o_found = cpoff_fn.append_basic_block("found");
    _o_cont = cpoff_fn.append_basic_block("cont");
    _o_done = cpoff_fn.append_basic_block("done");
    b = ir.IRBuilder(_o_entry);
    b.branch(_o_chk);
    b = ir.IRBuilder(_o_chk);
    oi = b.phi(i64, name="u8of.i");
    oi.add_incoming(zero, _o_entry);
    ocnt = b.phi(i64, name="u8of.cnt");
    ocnt.add_incoming(zero, _o_entry);
    ogo = b.icmp_unsigned("<", oi, cpoff_fn.args[1], name="u8of.go");
    b.cbranch(ogo, _o_body, _o_done);
    b = ir.IRBuilder(_o_body);
    ob_p = b.gep(cpoff_fn.args[0], [oi], name="u8of.p");
    ob8 = b.load(ob_p, name="u8of.b");
    obv = b.zext(ob8, i64, name="u8of.bv");
    ohi = b.icmp_unsigned(">=", obv, ir.Constant(i64, 0xC0), name="u8of.hi");
    olo = b.icmp_unsigned("<", obv, ir.Constant(i64, 0x80), name="u8of.lo");
    olead = b.or_(ohi, olo, name="u8of.lead");
    oeq = b.icmp_signed("==", ocnt, cpoff_fn.args[2], name="u8of.eq");
    oisk = b.and_(olead, oeq, name="u8of.isk");
    b.cbranch(oisk, _o_found, _o_cont);
    b = ir.IRBuilder(_o_found);
    b.ret(oi);
    b = ir.IRBuilder(_o_cont);
    ocnt1 = b.select(
        olead, b.add(ocnt, one, name="u8of.cinc"), ocnt, name="u8of.c1"
    );
    oi1 = b.add(oi, one, name="u8of.i1");
    oi.add_incoming(oi1, _o_cont);
    ocnt.add_incoming(ocnt1, _o_cont);
    b.branch(_o_chk);
    b = ir.IRBuilder(_o_done);
    b.ret(cpoff_fn.args[1]);
    self.utf8_cp_off_fn = cpoff_fn;

    # --- __jac_utf8_cp_len_at(i8p s, i64 off) -> i64 : byte length (1..4)
    # --- of the codepoint starting at byte offset off ---
    cplat_fn = self._define_function(
        "__jac_utf8_cp_len_at", ir.FunctionType(i64, [i8p, i64])
    );
    cplat_fn.linkage = "private";
    cplat_fn.args[0].name = "s";
    cplat_fn.args[1].name = "off";
    _l_entry = cplat_fn.append_basic_block("entry");
    b = ir.IRBuilder(_l_entry);
    lp = b.gep(cplat_fn.args[0], [cplat_fn.args[1]], name="u8la.p");
    lb8 = b.load(lp, name="u8la.b");
    lbv = b.zext(lb8, i64, name="u8la.bv");
    lis1 = b.icmp_unsigned("<", lbv, ir.Constant(i64, 0x80), name="u8la.is1");
    ll12 = b.select(lis1, one, ir.Constant(i64, 2), name="u8la.l12");
    lis3 = b.icmp_unsigned("<", lbv, ir.Constant(i64, 0xF0), name="u8la.is3");
    ll34 = b.select(lis3, ir.Constant(i64, 3), ir.Constant(i64, 4), name="u8la.l34");
    lis2 = b.icmp_unsigned("<", lbv, ir.Constant(i64, 0xE0), name="u8la.is2");
    ll = b.select(lis2, ll12, ll34, name="u8la.len");
    b.ret(ll);
    self.utf8_cp_len_at_fn = cplat_fn;

    # --- __jac_utf8_cp_at_off(i8p s, i64 off) -> i8p : the codepoint at
    # --- byte offset off as a string (ascii -> static cache entry;
    # --- multibyte -> rc-allocated, length-stamped) ---
    cpat_fn = self._define_function(
        "__jac_utf8_cp_at_off", ir.FunctionType(i8p, [i8p, i64])
    );
    cpat_fn.linkage = "private";
    cpat_fn.args[0].name = "s";
    cpat_fn.args[1].name = "off";
    _a_entry = cpat_fn.append_basic_block("entry");
    _a_ascii = cpat_fn.append_basic_block("ascii");
    _a_multi = cpat_fn.append_basic_block("multi");
    _a_cchk = cpat_fn.append_basic_block("cpy.chk");
    _a_cbody = cpat_fn.append_basic_block("cpy.body");
    _a_cdone = cpat_fn.append_basic_block("cpy.done");
    b = ir.IRBuilder(_a_entry);
    acp = b.gep(cpat_fn.args[0], [cpat_fn.args[1]], name="u8at.cp");
    ab8 = b.load(acp, name="u8at.b");
    abv = b.zext(ab8, i64, name="u8at.bv");
    aisc = b.icmp_unsigned("<", abv, ir.Constant(i64, 0x80), name="u8at.ascii");
    b.cbranch(aisc, _a_ascii, _a_multi);
    b = ir.IRBuilder(_a_ascii);
    cache_gv = self._get_char_cache_gv();
    cached = b.gep(
        cache_gv,
        [ir.Constant(ir.IntType(32), 0), abv, ir.Constant(ir.IntType(32), 2), ir.Constant(ir.IntType(32), 0)],
        name="u8at.cached"
    );
    b.ret(cached);
    b = ir.IRBuilder(_a_multi);
    ais1 = b.icmp_unsigned("<", abv, ir.Constant(i64, 0x80), name="u8at.is1");
    al12 = b.select(ais1, one, ir.Constant(i64, 2), name="u8at.l12");
    ais3 = b.icmp_unsigned("<", abv, ir.Constant(i64, 0xF0), name="u8at.is3");
    al34 = b.select(ais3, ir.Constant(i64, 3), ir.Constant(i64, 4), name="u8at.l34");
    ais2 = b.icmp_unsigned("<", abv, ir.Constant(i64, 0xE0), name="u8at.is2");
    al = b.select(ais2, al12, al34, name="u8at.len");
    asize = b.add(al, one, name="u8at.size");
    abuf = b.call(self.rc_alloc_fn, [asize], name="u8at.buf");
    self._emit_set_type_tag(b, abuf, "str");
    b.branch(_a_cchk);
    b = ir.IRBuilder(_a_cchk);
    at = b.phi(i64, name="u8at.t");
    at.add_incoming(zero, _a_multi);
    atgo = b.icmp_unsigned("<", at, al, name="u8at.go");
    b.cbranch(atgo, _a_cbody, _a_cdone);
    b = ir.IRBuilder(_a_cbody);
    asp = b.gep(acp, [at], name="u8at.sp");
    av = b.load(asp, name="u8at.v");
    adp = b.gep(abuf, [at], name="u8at.dp");
    b.store(av, adp);
    at1 = b.add(at, one, name="u8at.t1");
    at.add_incoming(at1, _a_cbody);
    b.branch(_a_cchk);
    b = ir.IRBuilder(_a_cdone);
    anul = b.gep(abuf, [al], name="u8at.nul");
    b.store(ir.Constant(i8, 0), anul);
    if not _hl {
        b.call(self.str_stamp_fn, [abuf, al]);
    }
    b.ret(abuf);
    self.utf8_cp_at_off_fn = cpat_fn;

    # --- __jac_utf8_ord(i8p s) -> i64 : decode first codepoint ---
    ord_fn = self._define_function(
        "__jac_utf8_ord", ir.FunctionType(i64, [i8p])
    );
    ord_fn.linkage = "private";
    ord_fn.args[0].name = "s";
    _r_entry = ord_fn.append_basic_block("entry");
    _r_q2 = ord_fn.append_basic_block("q2");
    _r_r1 = ord_fn.append_basic_block("r1");
    _r_q3 = ord_fn.append_basic_block("q3");
    _r_r2 = ord_fn.append_basic_block("r2");
    _r_r3 = ord_fn.append_basic_block("r3");
    _r_r4 = ord_fn.append_basic_block("r4");
    b = ir.IRBuilder(_r_entry);
    rc0p = b.gep(ord_fn.args[0], [zero], name="u8ord.p0");
    rc0 = b.zext(b.load(rc0p, name="u8ord.c0b"), i64, name="u8ord.c0");
    ris1 = b.icmp_unsigned("<", rc0, ir.Constant(i64, 0x80), name="u8ord.is1");
    b.cbranch(ris1, _r_r1, _r_q2);
    b = ir.IRBuilder(_r_r1);
    b.ret(rc0);
    b = ir.IRBuilder(_r_q2);
    rc1p = b.gep(ord_fn.args[0], [one], name="u8ord.p1");
    rc1 = b.zext(b.load(rc1p, name="u8ord.c1b"), i64, name="u8ord.c1");
    ris2 = b.icmp_unsigned("<", rc0, ir.Constant(i64, 0xE0), name="u8ord.is2");
    b.cbranch(ris2, _r_r2, _r_q3);
    b = ir.IRBuilder(_r_r2);
    rt2a = b.shl(b.and_(rc0, ir.Constant(i64, 0x1F), name="u8ord.m2a"), ir.Constant(i64, 6), name="u8ord.s2a");
    rt2b = b.and_(rc1, ir.Constant(i64, 0x3F), name="u8ord.m2b");
    b.ret(b.or_(rt2a, rt2b, name="u8ord.r2"));
    b = ir.IRBuilder(_r_q3);
    rc2p = b.gep(ord_fn.args[0], [ir.Constant(i64, 2)], name="u8ord.p2");
    rc2 = b.zext(b.load(rc2p, name="u8ord.c2b"), i64, name="u8ord.c2");
    ris3 = b.icmp_unsigned("<", rc0, ir.Constant(i64, 0xF0), name="u8ord.is3");
    b.cbranch(ris3, _r_r3, _r_r4);
    b = ir.IRBuilder(_r_r3);
    rt3a = b.shl(b.and_(rc0, ir.Constant(i64, 0x0F), name="u8ord.m3a"), ir.Constant(i64, 12), name="u8ord.s3a");
    rt3b = b.shl(b.and_(rc1, ir.Constant(i64, 0x3F), name="u8ord.m3b"), ir.Constant(i64, 6), name="u8ord.s3b");
    rt3c = b.and_(rc2, ir.Constant(i64, 0x3F), name="u8ord.m3c");
    b.ret(b.or_(b.or_(rt3a, rt3b, name="u8ord.r3ab"), rt3c, name="u8ord.r3"));
    b = ir.IRBuilder(_r_r4);
    rc3p = b.gep(ord_fn.args[0], [ir.Constant(i64, 3)], name="u8ord.p3");
    rc3 = b.zext(b.load(rc3p, name="u8ord.c3b"), i64, name="u8ord.c3");
    rt4a = b.shl(b.and_(rc0, ir.Constant(i64, 0x07), name="u8ord.m4a"), ir.Constant(i64, 18), name="u8ord.s4a");
    rt4b = b.shl(b.and_(rc1, ir.Constant(i64, 0x3F), name="u8ord.m4b"), ir.Constant(i64, 12), name="u8ord.s4b");
    rt4c = b.shl(b.and_(rc2, ir.Constant(i64, 0x3F), name="u8ord.m4c"), ir.Constant(i64, 6), name="u8ord.s4c");
    rt4d = b.and_(rc3, ir.Constant(i64, 0x3F), name="u8ord.m4d");
    b.ret(
        b.or_(
            b.or_(b.or_(rt4a, rt4b, name="u8ord.r4ab"), rt4c, name="u8ord.r4abc"),
            rt4d,
            name="u8ord.r4"
        )
    );
    self.utf8_ord_fn = ord_fn;

    # --- __jac_utf8_chr(i64 cp) -> i8p : encode codepoint (1..4 bytes) ---
    chr_fn = self._define_function(
        "__jac_utf8_chr", ir.FunctionType(i8p, [i64])
    );
    chr_fn.linkage = "private";
    chr_fn.args[0].name = "cp";
    _c_entry = chr_fn.append_basic_block("entry");
    _c_e2 = chr_fn.append_basic_block("e2");
    _c_b1 = chr_fn.append_basic_block("b1");
    _c_e3 = chr_fn.append_basic_block("e3");
    _c_b2 = chr_fn.append_basic_block("b2");
    _c_b3 = chr_fn.append_basic_block("b3");
    _c_b4 = chr_fn.append_basic_block("b4");
    b = ir.IRBuilder(_c_entry);
    cis1 = b.icmp_unsigned("<", chr_fn.args[0], ir.Constant(i64, 0x80), name="u8chr.is1");
    b.cbranch(cis1, _c_b1, _c_e2);
    b = ir.IRBuilder(_c_b1);
    cb1 = b.call(self.rc_alloc_fn, [ir.Constant(i64, 2)], name="u8chr.b1buf");
    self._emit_set_type_tag(b, cb1, "str");
    b.store(b.trunc(chr_fn.args[0], i8, name="u8chr.b1v"), cb1);
    cb1n = b.gep(cb1, [one], name="u8chr.b1n");
    b.store(ir.Constant(i8, 0), cb1n);
    if not _hl {
        b.call(self.str_stamp_fn, [cb1, one]);
    }
    b.ret(cb1);
    b = ir.IRBuilder(_c_e2);
    cis2 = b.icmp_unsigned("<", chr_fn.args[0], ir.Constant(i64, 0x800), name="u8chr.is2");
    b.cbranch(cis2, _c_b2, _c_e3);
    b = ir.IRBuilder(_c_b2);
    cb2 = b.call(self.rc_alloc_fn, [ir.Constant(i64, 3)], name="u8chr.b2buf");
    self._emit_set_type_tag(b, cb2, "str");
    cb2x = b.lshr(chr_fn.args[0], ir.Constant(i64, 6), name="u8chr.b2x");
    cb2y = b.and_(chr_fn.args[0], ir.Constant(i64, 0x3F), name="u8chr.b2y");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0xC0), cb2x, name="u8chr.b2h"), i8, name="u8chr.b2h8"), cb2);
    cb2p1 = b.gep(cb2, [one], name="u8chr.b2p1");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0x80), cb2y, name="u8chr.b2t"), i8, name="u8chr.b2t8"), cb2p1);
    cb2n = b.gep(cb2, [ir.Constant(i64, 2)], name="u8chr.b2n");
    b.store(ir.Constant(i8, 0), cb2n);
    if not _hl {
        b.call(self.str_stamp_fn, [cb2, ir.Constant(i64, 2)]);
    }
    b.ret(cb2);
    b = ir.IRBuilder(_c_e3);
    cis3 = b.icmp_unsigned("<", chr_fn.args[0], ir.Constant(i64, 0x10000), name="u8chr.is3");
    b.cbranch(cis3, _c_b3, _c_b4);
    b = ir.IRBuilder(_c_b3);
    cb3 = b.call(self.rc_alloc_fn, [ir.Constant(i64, 4)], name="u8chr.b3buf");
    self._emit_set_type_tag(b, cb3, "str");
    cb3x1 = b.lshr(chr_fn.args[0], ir.Constant(i64, 12), name="u8chr.b3x1");
    cb3x2 = b.lshr(chr_fn.args[0], ir.Constant(i64, 6), name="u8chr.b3x2");
    cb3y = b.and_(chr_fn.args[0], ir.Constant(i64, 0x3F), name="u8chr.b3y");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0xE0), cb3x1, name="u8chr.b3h"), i8, name="u8chr.b3h8"), cb3);
    cb3p1 = b.gep(cb3, [one], name="u8chr.b3p1");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0x80), b.and_(cb3x2, ir.Constant(i64, 0x3F), name="u8chr.b3m"), name="u8chr.b3m8v"), i8, name="u8chr.b3m8"), cb3p1);
    cb3p2 = b.gep(cb3, [ir.Constant(i64, 2)], name="u8chr.b3p2");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0x80), cb3y, name="u8chr.b3t"), i8, name="u8chr.b3t8"), cb3p2);
    cb3n = b.gep(cb3, [ir.Constant(i64, 3)], name="u8chr.b3n");
    b.store(ir.Constant(i8, 0), cb3n);
    if not _hl {
        b.call(self.str_stamp_fn, [cb3, ir.Constant(i64, 3)]);
    }
    b.ret(cb3);
    b = ir.IRBuilder(_c_b4);
    cb4 = b.call(self.rc_alloc_fn, [ir.Constant(i64, 5)], name="u8chr.b4buf");
    self._emit_set_type_tag(b, cb4, "str");
    cb4x1 = b.lshr(chr_fn.args[0], ir.Constant(i64, 18), name="u8chr.b4x1");
    cb4x2 = b.lshr(chr_fn.args[0], ir.Constant(i64, 12), name="u8chr.b4x2");
    cb4x3 = b.lshr(chr_fn.args[0], ir.Constant(i64, 6), name="u8chr.b4x3");
    cb4y = b.and_(chr_fn.args[0], ir.Constant(i64, 0x3F), name="u8chr.b4y");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0xF0), cb4x1, name="u8chr.b4h"), i8, name="u8chr.b4h8"), cb4);
    cb4p1 = b.gep(cb4, [one], name="u8chr.b4p1");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0x80), b.and_(cb4x2, ir.Constant(i64, 0x3F), name="u8chr.b4m1"), name="u8chr.b4m1v"), i8, name="u8chr.b4m18"), cb4p1);
    cb4p2 = b.gep(cb4, [ir.Constant(i64, 2)], name="u8chr.b4p2");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0x80), b.and_(cb4x3, ir.Constant(i64, 0x3F), name="u8chr.b4m2"), name="u8chr.b4m2v"), i8, name="u8chr.b4m28"), cb4p2);
    cb4p3 = b.gep(cb4, [ir.Constant(i64, 3)], name="u8chr.b4p3");
    b.store(b.trunc(b.or_(ir.Constant(i64, 0x80), cb4y, name="u8chr.b4t"), i8, name="u8chr.b4t8"), cb4p3);
    cb4n = b.gep(cb4, [ir.Constant(i64, 4)], name="u8chr.b4n");
    b.store(ir.Constant(i8, 0), cb4n);
    if not _hl {
        b.call(self.str_stamp_fn, [cb4, ir.Constant(i64, 4)]);
    }
    b.ret(cb4);
    self.utf8_chr_fn = chr_fn;

    # --- __jac_utf8_advance(i8p s, i64 off, i64 delta) -> i64 : byte
    # --- offset moved by delta codepoints (negative walks backwards) ---
    adv_fn = self._define_function(
        "__jac_utf8_advance", ir.FunctionType(i64, [i8p, i64, i64])
    );
    adv_fn.linkage = "private";
    adv_fn.args[0].name = "s";
    adv_fn.args[1].name = "off";
    adv_fn.args[2].name = "delta";
    _v_entry = adv_fn.append_basic_block("entry");
    _v_loop = adv_fn.append_basic_block("loop");
    _v_work = adv_fn.append_basic_block("work");
    _v_fwd = adv_fn.append_basic_block("fwd");
    _v_back = adv_fn.append_basic_block("back");
    _v_scan = adv_fn.append_basic_block("scan");
    _v_scancont = adv_fn.append_basic_block("scancont");
    _v_backdone = adv_fn.append_basic_block("backdone");
    _v_merge = adv_fn.append_basic_block("merge");
    _v_done = adv_fn.append_basic_block("done");
    b = ir.IRBuilder(_v_entry);
    b.branch(_v_loop);
    b = ir.IRBuilder(_v_loop);
    voff = b.phi(i64, name="u8adv.off");
    voff.add_incoming(adv_fn.args[1], _v_entry);
    vrem = b.phi(i64, name="u8adv.rem");
    vrem.add_incoming(adv_fn.args[2], _v_entry);
    vpos = b.icmp_signed(">", vrem, zero, name="u8adv.pos");
    vneg = b.icmp_signed("<", vrem, zero, name="u8adv.neg");
    vmore = b.or_(vpos, vneg, name="u8adv.more");
    b.cbranch(vmore, _v_work, _v_done);
    b = ir.IRBuilder(_v_work);
    b.cbranch(vpos, _v_fwd, _v_back);
    b = ir.IRBuilder(_v_fwd);
    vfl = b.call(self.utf8_cp_len_at_fn, [adv_fn.args[0], voff], name="u8adv.fl");
    voff_f = b.add(voff, vfl, name="u8adv.off.f");
    vrem_f = b.sub(vrem, one, name="u8adv.rem.f");
    b.branch(_v_merge);
    b = ir.IRBuilder(_v_back);
    vob = b.sub(voff, one, name="u8adv.ob");
    b.branch(_v_scan);
    b = ir.IRBuilder(_v_scan);
    vo_p = b.phi(i64, name="u8adv.o");
    vo_p.add_incoming(vob, _v_back);
    vbp = b.gep(adv_fn.args[0], [vo_p], name="u8adv.bp");
    vbv = b.zext(b.load(vbp, name="u8adv.b"), i64, name="u8adv.bv");
    vcont = b.and_(
        b.icmp_unsigned(">=", vbv, ir.Constant(i64, 0x80), name="u8adv.chi"),
        b.icmp_unsigned("<", vbv, ir.Constant(i64, 0xC0), name="u8adv.clo"),
        name="u8adv.iscont"
    );
    b.cbranch(vcont, _v_scancont, _v_backdone);
    b = ir.IRBuilder(_v_scancont);
    vo_n = b.sub(vo_p, one, name="u8adv.on");
    vo_p.add_incoming(vo_n, _v_scancont);
    b.branch(_v_scan);
    b = ir.IRBuilder(_v_backdone);
    voff_b = vo_p;
    vrem_b = b.add(vrem, one, name="u8adv.rem.b");
    b.branch(_v_merge);
    b = ir.IRBuilder(_v_merge);
    voff_n = b.phi(i64, name="u8adv.off.n");
    voff_n.add_incoming(voff_f, _v_fwd);
    voff_n.add_incoming(voff_b, _v_backdone);
    vrem_n = b.phi(i64, name="u8adv.rem.n");
    vrem_n.add_incoming(vrem_f, _v_fwd);
    vrem_n.add_incoming(vrem_b, _v_backdone);
    voff.add_incoming(voff_n, _v_merge);
    vrem.add_incoming(vrem_n, _v_merge);
    b.branch(_v_loop);
    b = ir.IRBuilder(_v_done);
    b.ret(voff);
    self.utf8_advance_fn = adv_fn;
}

impl NaIRGenUtf8Strings._call_utf8_cplen(
    b: ir.IRBuilder, ptr: ir.Value, nbytes: ir.Value, name: str = "u8.cplen"
) -> ir.Value {
    self._emit_utf8_helpers();
    nbytes = self._coerce_type(nbytes, ir.IntType(64));
    return b.call(self.utf8_cplen_fn, [ptr, nbytes], name=name);
}

impl NaIRGenUtf8Strings._call_utf8_cp_off(
    b: ir.IRBuilder,
    ptr: ir.Value,
    nbytes: ir.Value,
    cp_index: ir.Value,
    name: str = "u8.cpoff"
) -> ir.Value {
    self._emit_utf8_helpers();
    nbytes = self._coerce_type(nbytes, ir.IntType(64));
    cp_index = self._coerce_type(cp_index, ir.IntType(64));
    return b.call(self.utf8_cp_off_fn, [ptr, nbytes, cp_index], name=name);
}

impl NaIRGenUtf8Strings._call_utf8_cp_len_at(
    b: ir.IRBuilder, ptr: ir.Value, off: ir.Value, name: str = "u8.cplenat"
) -> ir.Value {
    self._emit_utf8_helpers();
    off = self._coerce_type(off, ir.IntType(64));
    return b.call(self.utf8_cp_len_at_fn, [ptr, off], name=name);
}

impl NaIRGenUtf8Strings._call_utf8_cp_at_off(
    b: ir.IRBuilder, ptr: ir.Value, off: ir.Value, name: str = "u8.cpat"
) -> ir.Value {
    self._emit_utf8_helpers();
    off = self._coerce_type(off, ir.IntType(64));
    return b.call(self.utf8_cp_at_off_fn, [ptr, off], name=name);
}

impl NaIRGenUtf8Strings._call_utf8_ord(
    b: ir.IRBuilder, ptr: ir.Value, name: str = "u8.ord"
) -> ir.Value {
    self._emit_utf8_helpers();
    return b.call(self.utf8_ord_fn, [ptr], name=name);
}

impl NaIRGenUtf8Strings._call_utf8_chr(
    b: ir.IRBuilder, cp: ir.Value, name: str = "u8.chr"
) -> ir.Value {
    self._emit_utf8_helpers();
    cp = self._coerce_type(cp, ir.IntType(64));
    return b.call(self.utf8_chr_fn, [cp], name=name);
}

impl NaIRGenUtf8Strings._call_utf8_advance(
    b: ir.IRBuilder,
    ptr: ir.Value,
    off: ir.Value,
    delta: ir.Value,
    name: str = "u8.adv"
) -> ir.Value {
    self._emit_utf8_helpers();
    off = self._coerce_type(off, ir.IntType(64));
    delta = self._coerce_type(delta, ir.IntType(64));
    return b.call(self.utf8_advance_fn, [ptr, off, delta], name=name);
}
