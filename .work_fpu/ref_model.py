#!/usr/bin/env python3
"""Golden reference model for the RV32 F/D FPU (v2, exact-Fraction based).

Ground truth: every finite float is an exact Fraction.  Each operation computes
its exact result as a Fraction (or a special-case decision) and then calls one
single, well-tested rounding kernel.  This removes the class of bugs that comes
from hand-rolled integer normalization in two different places.

Flags: NV(1) DZ(2) OF(4) UF(8) NX(16), RISC-V semantics
       (tininess detected after rounding).
"""
from fractions import Fraction as Fr

NV, DZ, OF, UF, NX = 1, 2, 4, 8, 16
RNE, RTZ, RDN, RUP, RMM = 0, 1, 2, 3, 4


def _cfg(fmt):
    if fmt == 's':
        return dict(fb=23, eb=8, width=32, emax=0xFF, bias=127, qbit=1 << 22, prec=24)
    return dict(fb=52, eb=11, width=64, emax=0x7FF, bias=1023, qbit=1 << 51, prec=53)


class F:
    def __init__(self, fmt):
        self.fmt = fmt
        self.__dict__.update(_cfg(fmt))
        self.mask = (1 << self.width) - 1
        self.fmask = (1 << self.fb) - 1
        self.emin = 1 - self.bias               # exponent of smallest normal
        self.emin_sub = 1 - self.bias - self.fb  # exponent of smallest subnormal

    # ---- field access ----
    def unpack(self, b):
        b &= self.mask
        return ((b >> (self.width - 1)) & 1), ((b >> self.fb) & self.emax), (b & self.fmask)

    def pack(self, s, e, f):
        return (((s & 1) << (self.width - 1)) | ((e & self.emax) << self.fb)
                | (f & self.fmask)) & self.mask

    def canon(self):
        return self.pack(0, self.emax, self.qbit)

    def inf(self, s=0):
        return self.pack(s, self.emax, 0)

    def zero(self, s=0):
        return self.pack(s, 0, 0)

    def sign(self, b):
        return (b >> (self.width - 1)) & 1

    def neg(self, b):
        return b ^ (1 << (self.width - 1))

    # ---- predicates ----
    def is_nan(self, b):
        s, e, f = self.unpack(b); return e == self.emax and f != 0

    def is_snan(self, b):
        s, e, f = self.unpack(b); return e == self.emax and f != 0 and not (f & self.qbit)

    def is_inf(self, b):
        s, e, f = self.unpack(b); return e == self.emax and f == 0

    def is_zero(self, b):
        s, e, f = self.unpack(b); return e == 0 and f == 0

    # ---- exact value ----
    def val(self, b):
        """Exact Fraction, or None for inf/nan."""
        s, e, f = self.unpack(b)
        if e == self.emax:
            return None
        if e == 0:
            m = Fr(f, 1 << self.fb) * Fr(2) ** self.emin_sub
        else:
            m = Fr((1 << self.fb) | f, 1 << self.fb) * Fr(2) ** (e - self.bias)
        return -m if s else m

    def class_mask(self, b):
        s, e, f = self.unpack(b)
        if e == self.emax:
            if f == 0:
                return 1 << (0 if s else 7)
            return 1 << (8 if self.is_snan(b) else 9)
        if e == 0:
            if f == 0:
                return 1 << (3 if s else 4)
            return 1 << (2 if s else 5)
        return 1 << (1 if s else 6)


# ---------------------------------------------------------------------------
# THE rounding kernel.  Given an exact nonzero rational magnitude `mag`
# (a Fraction), a sign, and a rounding mode, produce the correctly rounded
# float and its flags.  Handles subnormal, overflow and underflow.
# ---------------------------------------------------------------------------
def round_frac(F, sign, mag, rm, exact_zero_is_pos=True):
    flags = 0
    assert mag >= 0
    if mag == 0:
        return F.zero(0 if (rm in (RNE, RMM) or exact_zero_is_pos) else (1 if rm == RDN else 0)), 0

    # Express mag = num / 2^k  with num an integer
    num, den = mag.numerator, mag.denominator
    assert (den & (den - 1)) == 0, ("non power-of-two denominator", den)
    k = den.bit_length() - 1

    # value = num * 2^-k.  We want `prec+1` significant bits plus rounding info.
    # Find the position of the LSB of the target significand.
    # Normal case: exponent field e_f = floor(log2(mag)) + bias, and we keep
    # prec bits, so lsb weight = 2^(e_f - bias - fb).
    # Subnormal case: lsb weight is fixed at 2^emin_sub.
    # Work in integers: shift `num` so that the LSB weight is 2^w.
    bl = num.bit_length() - 1
    # smallest exponent of the value's MSB, in the "weight" units below
    msb_weight = bl - k          # value = 1.xxx * 2^msb_weight
    e_unb = msb_weight
    e_f = e_unb + F.bias         # tentative exponent field

    if e_f >= 1:
        # normal (or overflow) path
        w = e_unb - F.fb          # weight of the target LSB
    else:
        # subnormal / underflow: target LSB fixed
        w = F.emin_sub

    # shift so that num*2^-k has LSB weight 2^w  =>  integer N = value / 2^w
    shift = w + k                # value * 2^shift = integer  (may be negative)
    if shift >= 0:
        N = num << shift
        sticky = 0
    else:
        sh = -shift
        N = num >> sh
        sticky = 1 if (num & ((1 << sh) - 1)) else 0

    # N is the truncated magnitude in units of 2^w; round bit is bit 0 of... no:
    # N already IS the result significand (LSB at 2^w) when shift>=0 (exact).
    # When shift<0 we truncated - undo one more bit to get the round bit.
    # Unify: redo with one extra bit kept.
    #   N = value / 2^w  (floor when truncating)
    #   we need round bit = (value/2^w mod 2) ... only meaningful if inexact.
    # Conceptually: let q = floor(value / 2^w). round_bit = bit0 of q when
    # value/2^w is not an integer.
    if shift >= 0:
        q = N
        rb = 0
        st = 0
        inexact = 0
    else:
        sh = -shift
        q = num >> sh
        rb = (num >> (sh - 1)) & 1 if sh >= 1 else 0
        rem = num & ((1 << (sh - 1)) - 1) if sh >= 1 else 0
        st = 1 if rem else 0
        inexact = 1 if (rb or st) else 0

    if inexact:
        flags |= NX
        lsb = q & 1
        if rm == RNE:
            inc = rb and (st or lsb)
        elif rm == RMM:
            inc = rb
        elif rm == RTZ:
            inc = 0
        elif rm == RUP:
            inc = (sign == 0)
        elif rm == RDN:
            inc = (sign == 1)
        else:
            inc = rb and (st or lsb)
        q += 1 if inc else 0

    # now result magnitude = q * 2^w
    if q == 0:
        # underflowed to zero
        if flags & NX:
            flags |= UF
        return F.zero(sign), flags

    bl_q = q.bit_length() - 1
    e_res = w + bl_q            # MSB exponent of result
    e_f = e_res + F.bias

    if e_f >= F.emax:
        # overflow
        flags |= OF | NX
        if rm == RTZ or (rm == RDN and sign == 0) or (rm == RUP and sign == 1):
            return F.pack(sign, F.emax - 1, F.fmask), flags
        return F.inf(sign), flags

    if e_f <= 0:
        # subnormal result
        if flags & NX:
            flags |= UF
        # fraction = q * 2^w / 2^emin_sub
        s2 = w - F.emin_sub
        frac = q << s2 if s2 >= 0 else q >> (-s2)
        assert 0 <= frac <= F.fmask, (frac, F.fmask)
        return F.pack(sign, 0, frac), flags

    # Normal result.  q is the significand with LSB at 2^w, and the value's
    # MSB sits at 2^(w+bl_q).  For a normal result with prec significant bits
    # the implied LSB weight is 2^(e_res - fb), so q may need a right shift
    # when rounding carried it up a bit (or when the subnormal region handed
    # control to the normal region with fewer than prec bits set).
    shift = (e_res - F.fb) - w
    if shift >= 0:
        q <<= shift
        assert q.bit_length() - 1 == F.fb, (q.bit_length() - 1, F.fb)
    else:
        # shift left is impossible here: q already carries prec bits when
        # normal.  A negative shift means q has *more* than prec bits, which
        # can happen after a subnormal->normal promotion; re-normalize by
        # dropping the surplus low bits (they are zero by construction).
        drop = -shift
        assert (q & ((1 << drop) - 1)) == 0, (q, drop)
        q >>= drop
    frac = q & F.fmask
    return F.pack(sign, e_f, frac), flags


def round_frac_flags(F, sign, mag, rm):
    return round_frac(F, sign, mag, rm)


# ---------------------------------------------------------------------------
# operations
# ---------------------------------------------------------------------------
def op_add(F, a, b, rm, sub=0):
    if F.is_nan(a) or F.is_nan(b):
        return F.canon(), (NV if (F.is_snan(a) or F.is_snan(b)) else 0)
    bs = F.sign(b) ^ sub
    b2 = F.pack(bs, *F.unpack(b)[1:])
    if F.is_inf(a) and F.is_inf(b2):
        if F.sign(a) != bs:
            return F.canon(), NV
        return F.inf(F.sign(a)), 0
    if F.is_inf(a):
        return F.inf(F.sign(a)), 0
    if F.is_inf(b2):
        return F.inf(bs), 0
    va, vb = F.val(a), F.val(b2)
    s = va + vb
    if s == 0:
        # exact zero: both zero, or exact cancellation
        both_zero = (va == 0 and vb == 0)
        if both_zero:
            if F.sign(a) == bs:
                return F.zero(F.sign(a)), 0
            return F.zero(1 if rm == RDN else 0), 0
        # exact cancellation of nonzero operands
        return F.zero(1 if rm == RDN else 0), 0
    sign = 1 if s < 0 else 0
    return round_frac(F, sign, abs(s), rm)


def op_mul(F, a, b, rm):
    if F.is_nan(a) or F.is_nan(b):
        return F.canon(), (NV if (F.is_snan(a) or F.is_snan(b)) else 0)
    sign = F.sign(a) ^ F.sign(b)
    if (F.is_inf(a) and F.is_zero(b)) or (F.is_zero(a) and F.is_inf(b)):
        return F.canon(), NV
    if F.is_inf(a) or F.is_inf(b):
        return F.inf(sign), 0
    if F.is_zero(a) or F.is_zero(b):
        return F.zero(sign), 0
    return round_frac(F, sign, F.val(a) * F.val(b), rm)


def op_fma(F, a, b, c, rm, neg_p=0, neg_c=0):
    """(neg_p? -(a*b) : a*b) + (neg_c? -c : c) with ONE rounding.
    a is never negated (rs1)."""
    b2 = F.neg(b) if neg_p else b
    c2 = F.neg(c) if neg_c else c
    flags = 0
    if F.is_nan(a) or F.is_nan(b2) or F.is_nan(c2):
        if F.is_snan(a) or F.is_snan(b2) or F.is_snan(c2):
            flags |= NV
        return F.canon(), flags
    sign_p = F.sign(a) ^ F.sign(b2)
    infp = F.is_inf(a) or F.is_inf(b2)
    zerop = F.is_zero(a) or F.is_zero(b2)
    if (F.is_inf(a) and F.is_zero(b2)) or (F.is_zero(a) and F.is_inf(b2)):
        return F.canon(), NV
    if infp:
        if F.is_inf(c2) and F.sign(c2) != sign_p:
            return F.canon(), NV
        return F.inf(sign_p), 0
    if F.is_inf(c2):
        return F.inf(F.sign(c2)), 0
    if zerop:
        if F.is_zero(c2):
            # (+0 * x) + (+0) etc: sign = both-zero signed rule
            vp = sign_p
            vc = F.sign(c2)
            if vp == vc:
                return F.zero(vp), 0
            return F.zero(1 if rm == RDN else 0), 0
        return c2, 0
    if F.is_zero(c2):
        return round_frac(F, sign_p, abs(F.val(a) * F.val(b2)), rm), 0
    vp = F.val(a) * F.val(b2)
    vc = F.val(c2)
    s = vp + vc
    if s == 0:
        return F.zero(1 if rm == RDN else 0), 0
    sign = 1 if s < 0 else 0
    return round_frac(F, sign, abs(s), rm)


def op_div(F, a, b, rm):
    if F.is_nan(a) or F.is_nan(b):
        return F.canon(), (NV if (F.is_snan(a) or F.is_snan(b)) else 0)
    sign = F.sign(a) ^ F.sign(b)
    if (F.is_inf(a) and F.is_inf(b)) or (F.is_zero(a) and F.is_zero(b)):
        return F.canon(), NV
    if F.is_inf(a):
        return F.inf(sign), 0
    if F.is_inf(b):
        return F.zero(sign), 0
    if F.is_zero(b):
        return F.inf(sign), DZ
    if F.is_zero(a):
        return F.zero(sign), 0
    return round_frac(F, sign, F.val(a) / F.val(b), rm)


def _isqrt(n):
    if n == 0:
        return 0
    x = 1 << ((n.bit_length() + 1) // 2)
    while True:
        y = (x + n // x) // 2
        if y >= x:
            return x
        x = y


def op_sqrt(F, a, rm):
    """Exact sqrt via isqrt on a scaled integer, then round.

    We need round bit + sticky, so we compute the root with 2*(prec+3) bits
    and rely on the exact remainder for stickiness.  To be fully exact we
    instead construct the exact rational bound: sqrt(mag) is irrational in
    general, so we pass a Fraction approximation that is provably within
    half an ulp of the last kept bit, and compute the sticky flag from the
    integer square-root remainder.
    """
    if F.is_nan(a):
        return F.canon(), (NV if F.is_snan(a) else 0)
    if F.is_zero(a):
        return F.zero(F.sign(a)), 0
    if F.sign(a) == 1:
        return F.canon(), NV
    if F.is_inf(a):
        return F.inf(0), 0
    mag = F.val(a)
    num, den = mag.numerator, mag.denominator
    # sqrt(num/den) = sqrt(num * den) / den
    n = num * den
    r = _isqrt(n)
    sticky = 1 if r * r != n else 0
    # lower bound r/den <= sqrt(mag) < (r+1)/den ; if not exact, push the
    # numerator one bit further so rounding ties can be resolved
    if sticky:
        # refine: use sqrt to 2*(prec+2)+2 bits
        extra = 2 * (F.prec + 3)
        r2 = _isqrt(n << (2 * extra))
        exact = (r2 * r2 == (n << (2 * extra)))
        val = Fr(r2, den * (1 << extra))
        if not exact:
            # val is a floor; a value strictly below the true sqrt by <2^-extra
            # is enough: only a tie could be misjudged, and a tie needs the
            # true sqrt to be exactly a midpoint, i.e. exact -> excluded.
            pass
        return round_frac(F, 0, val, rm)
    return round_frac(F, 0, Fr(r, den), rm)


def op_cmp(F, a, b, op):
    if F.is_nan(a) or F.is_nan(b):
        if op == 'feq':
            return 0, (NV if (F.is_snan(a) or F.is_snan(b)) else 0)
        return 0, NV
    va, vb = F.val(a), F.val(b)
    if va is None or vb is None:
        # at least one inf; replace with a comparable sentinel
        def sent(x, v):
            if v is not None:
                return v
            return Fr(10**400) if F.sign(x) == 0 else Fr(-10**400)
        va, vb = sent(a, va), sent(b, vb)
    eq = (va == vb)
    lt = (va < vb)
    if op == 'feq':
        return (1 if eq else 0), 0
    if op == 'flt':
        return (1 if lt else 0), 0
    if op == 'fle':
        return (1 if (lt or eq) else 0), 0
    raise ValueError(op)


def op_minmax(F, a, b, is_max):
    flags = NV if (F.is_snan(a) or F.is_snan(b)) else 0
    if F.is_nan(a) and F.is_nan(b):
        return F.canon(), flags
    if F.is_nan(a):
        return b, flags
    if F.is_nan(b):
        return a, flags
    if F.is_zero(a) and F.is_zero(b):
        sa, sb = F.sign(a), F.sign(b)
        return (F.zero(sa & sb) if is_max else F.zero(sa | sb)), flags
    lt, _ = op_cmp(F, a, b, 'flt')
    gt, _ = op_cmp(F, b, a, 'flt')
    if lt:
        return (b if is_max else a), flags
    if gt:
        return (a if is_max else b), flags
    return a, flags


def op_sgnj(F, a, b, mode):
    sa, sb = F.sign(a), F.sign(b)
    s = {'j': sb, 'jn': sb ^ 1, 'jx': sa ^ sb}[mode]
    return F.pack(s, *F.unpack(a)[1:]), 0


# ---------------------------------------------------------------------------
# conversions
# ---------------------------------------------------------------------------
def cvt_f2i(F, a, rm, unsigned, width=32):
    """float -> integer of `width` bits."""
    if F.is_nan(a):
        return (0xFFFFFFFF if unsigned else 0x7FFFFFFF), NV
    if F.is_inf(a):
        if unsigned:
            return (0 if F.sign(a) else 0xFFFFFFFF), NV
        return (0x80000000 if F.sign(a) else 0x7FFFFFFF), NV
    v = F.val(a)
    sign = 1 if v < 0 else 0
    m = -v if sign else v
    ip = m.numerator // m.denominator
    frac = m - ip
    flags = 0
    if frac != 0:
        flags = NX
        if rm == RNE:
            if frac > Fr(1, 2) or (frac == Fr(1, 2) and (ip & 1)):
                ip += 1
        elif rm == RMM:
            if frac >= Fr(1, 2):
                ip += 1
        elif rm == RTZ:
            pass
        elif rm == RUP:
            if sign == 0:
                ip += 1
        elif rm == RDN:
            if sign == 1:
                ip += 1
    signed = -ip if sign else ip
    if unsigned:
        lo, hi = 0, (1 << width) - 1
        out_lo, out_hi = (0 if sign else 0xFFFFFFFF), None
    else:
        lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    if signed < lo or signed > hi:
        if unsigned:
            return (0 if sign else 0xFFFFFFFF), NV
        return (0x80000000 if sign else 0x7FFFFFFF), NV
    return signed & 0xFFFFFFFF, flags


def cvt_i2f(F, a, rm, unsigned):
    """32-bit int (pattern in a) -> float."""
    if unsigned:
        sign, mag = 0, a & 0xFFFFFFFF
    else:
        u = a & 0xFFFFFFFF
        sign = (u >> 31) & 1
        mag = ((~u) + 1) & 0xFFFFFFFF if sign else u
    if mag == 0:
        return F.zero(0), 0
    return round_frac(F, sign, Fr(mag), rm)


def cvt_wide(Ft, abits, rm, signed_from, is_nan, is_inf, sign_of, val_of,
             f2i=None):
    """Not used - kept for clarity."""
    raise NotImplementedError


def cvt_s_d(a, rm):
    """fcvt.s.d : double a -> single.  Uses Fs/Fd singletons."""
    Fd, Fs = F('d'), F('s')
    if Fd.is_nan(a):
        return Fs.canon(), (NV if Fd.is_snan(a) else 0)
    if Fd.is_inf(a):
        return Fs.inf(Fd.sign(a)), 0
    if Fd.is_zero(a):
        return Fs.zero(Fd.sign(a)), 0
    v = Fd.val(a)
    sign = 1 if v < 0 else 0
    return round_frac(Fs, sign, abs(v), rm)


def cvt_d_s(a):
    """fcvt.d.s : single a -> double, exact."""
    Fs, Fd = F('s'), F('d')
    if Fs.is_nan(a):
        return Fd.canon(), (NV if Fs.is_snan(a) else 0)
    if Fs.is_inf(a):
        return Fd.inf(Fs.sign(a)), 0
    if Fs.is_zero(a):
        return Fd.zero(Fs.sign(a)), 0
    v = Fs.val(a)
    sign = 1 if v < 0 else 0
    return round_frac(Fd, sign, abs(v), RNE)


def box_s(v32):
    return (0xFFFFFFFF00000000 | (v32 & 0xFFFFFFFF)) & ((1 << 64) - 1)


def unbox_s(v64):
    if ((v64 >> 32) & 0xFFFFFFFF) != 0xFFFFFFFF:
        return 0x7FC00000
    return v64 & 0xFFFFFFFF
