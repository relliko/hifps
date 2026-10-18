"""Builds sigs.lua: a byte signature for every client offset hifps.lua's site tables name, so hifps
can find them again after a client update moves the code.

Usage: python tools/gen_sigs.py <FFXiMain_XXXXXXXX.bin> [--check <other dump> ...]

The dump must be the client the tables were written against (a memdump of FFXiMain.dll; the base is
in the file name). Each signature covers whole instructions around the offset. Bytes that change
when code or data moves are '??': rel32 branch targets, and 32-bit immediates/displacements that
point inside the image. The bytes hifps rewrites (a site's call operand, a smoothing loop's
immediate float) are '??' too, so a client hifps already patched still matches. A signature is grown
until it is unique: among the getter's callers for a call site, in .text for anything else.

--check runs the same matching (in Python) on other dumps and prints what moved or went missing.
"""
import os, re, struct, sys
import capstone

HERE = os.path.dirname(os.path.abspath(__file__))
LUA = os.path.join(HERE, '..', 'hifps.lua')
OUT = os.path.join(HERE, '..', 'sigs.lua')
# The client the tables were written against.
REF = 'C:/Games/PhoenixXI/FFXiMain_04490000.bin'

GETTER = re.compile(rb'\x8B\x0D....\xD9\x41\x28\xD8\x1D....\xDF\xE0\xF6\xC4\x05\x7A\x07\xD9\x05....\xC3\xD9\x41\x28\xC3', re.S)
MD = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
MD.detail = True


class Image:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        m = re.search(r'_([0-9A-Fa-f]{8})\.bin$', path)
        self.base = int(m.group(1), 16)
        pe = struct.unpack_from('<I', self.d, 0x3C)[0]
        n = struct.unpack_from('<H', self.d, pe + 6)[0]
        sec = pe + 24 + struct.unpack_from('<H', self.d, pe + 20)[0]
        self.text = None
        for i in range(n):
            e = sec + 40 * i
            if self.d[e:e + 8].rstrip(b'\0') == b'.text':
                vs, va = struct.unpack_from('<II', self.d, e + 8)
                self.text = (va, va + vs)
        self.getters = [m.start() for m in GETTER.finditer(self.d)]
        lo, hi = self.text
        self.callers = []
        g = set(self.getters)
        for m in re.finditer(rb'\xE8', self.d[lo:hi - 4]):
            i = lo + m.start()
            if i + 5 + struct.unpack_from('<i', self.d, i + 1)[0] in g:
                self.callers.append(i)

    def in_image(self, v):
        return self.base <= v < self.base + len(self.d)


def tables():
    """Every offset hifps.lua's tables name: (rva, what), what = 'site', 'imm' or 'op'."""
    src = open(LUA, encoding='utf-8').read()
    out = []
    for name in ('FRAC_SITES', 'INT_SITES', 'STOCK_SITES'):
        body = re.search(r'local %s = \{(.*?)\n\};' % name, src, re.S).group(1)
        body = re.sub(r'--[^\n]*', '', body)
        out += [(int(x, 16), 'site') for x in re.findall(r'0x([0-9A-Fa-f]+)', body)]
    body = re.search(r'local SMOOTH_LOOPS = \{(.*?)\n\};', src, re.S).group(1)
    body = re.sub(r'--[^\n]*', '', body)
    for s in re.findall(r'sites = \{([^}]*)\}', body):
        out += [(int(x, 16), 'site') for x in re.findall(r'0x([0-9A-Fa-f]+)', s)]
    out += [(int(x, 16), 'imm') for x in re.findall(r'imm = 0x([0-9A-Fa-f]+)', body)]
    out += [(int(x, 16), 'op') for x in re.findall(r'at = 0x([0-9A-Fa-f]+)', body)]
    seen, res = set(), []
    for r, w in out:
        if r not in seen:
            seen.add(r)
            res.append((r, w))
    return res


def instructions(img, rva, before, after):
    """Whole instructions covering [rva - before, rva + after), decoded from a point far enough back
    that the stream has synchronised; the instruction containing rva must start at a boundary."""
    for back in range(64, 160, 8):
        start = rva - before - back
        ins = list(MD.disasm(img.d[start:rva + after + 16], start))
        if not ins or ins[-1].address + ins[-1].size < rva + after:
            continue
        if not any(i.address <= rva < i.address + i.size for i in ins):
            continue
        keep = [i for i in ins if i.address + i.size > rva - before and i.address < rva + after]
        return keep
    raise RuntimeError('could not decode around %06X' % rva)


def signature(img, rva, what, before, after):
    ins = instructions(img, rva, before, after)
    lo = ins[0].address
    hi = ins[-1].address + ins[-1].size
    pat = list(img.d[lo:hi])
    mask = [False] * len(pat)

    def hide(a, n):
        for k in range(a, a + n):
            if lo <= k < hi:
                mask[k - lo] = True

    for i in ins:
        branch = i.group(capstone.CS_GRP_JUMP) or i.group(capstone.CS_GRP_CALL)
        if i.imm_size == 4:
            v = struct.unpack_from('<I', img.d, i.address + i.imm_offset)[0]
            if (branch and i.bytes[0] in (0xE8, 0xE9, 0x0F)) or img.in_image(v):
                hide(i.address + i.imm_offset, 4)
        if i.disp_size == 4:
            v = struct.unpack_from('<I', img.d, i.address + i.disp_offset)[0]
            if img.in_image(v):
                hide(i.address + i.disp_offset, 4)
    # The bytes hifps rewrites.
    if what == 'site':
        hide(rva + 1, 4)
    else:
        hide(rva, 4)
    hexs = ''.join('??' if m else '%02X' % b for b, m in zip(pat, mask))
    return rva - lo, hexs


def compile_pat(hexs):
    return re.compile(b''.join(b'.' if hexs[i:i + 2] == '??' else re.escape(bytes([int(hexs[i:i + 2], 16)]))
                               for i in range(0, len(hexs), 2)), re.S)


def matches(img, off, hexs, what, near=None):
    rx = compile_pat(hexs)
    if what == 'site':
        return [c for c in img.callers if c - off >= 0 and rx.match(img.d, c - off)]
    lo, hi = img.text
    return [m.start() + off for m in rx.finditer(img.d, lo, hi)]


def build(img):
    sigs = []
    for rva, what in tables():
        for size in range(12, 97, 4):
            off, hexs = signature(img, rva, what, size, size)
            m = matches(img, off, hexs, what)
            if m == [rva]:
                break
        else:
            raise RuntimeError('no unique signature for %06X (%s)' % (rva, what))
        sigs.append((rva, what, off, hexs))
    return sigs


def write(img, sigs, path):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('-- Generated by tools/gen_sigs.py from FFXiMain_%08X.bin; do not edit.\n' % img.base)
        f.write('-- [offset in that client] = { kind, offset of it in the pattern, pattern }\n')
        f.write('return {\n')
        for rva, what, off, hexs in sigs:
            f.write("    [0x%06X] = { '%s', %d, '%s' },\n" % (rva, what, off, hexs))
        f.write('};\n')


def check(sigs, img):
    moved, lost = 0, []
    for rva, what, off, hexs in sigs:
        rx = compile_pat(hexs)
        if rva - off >= 0 and rx.match(img.d, rva - off):
            continue
        m = matches(img, off, hexs, what)
        if len(m) == 1:
            moved += 1
        else:
            lost.append((rva, what, len(m)))
    print('%s: %d getter callers, %d signatures, %d at the same offset, %d moved, %d not found' % (
        os.path.basename(img.path), len(img.callers), len(sigs), len(sigs) - moved - len(lost), moved, len(lost)))
    for rva, what, n in lost:
        print('  %06X %s: %d matches' % (rva, what, n))


if __name__ == '__main__':
    src = Image(sys.argv[1])
    src.path = sys.argv[1]
    sigs = build(src)
    write(src, sigs, OUT)
    print('wrote %s: %d signatures' % (OUT, len(sigs)))
    args = sys.argv[2:]
    while args and args[0] == '--check':
        img = Image(args[1])
        img.path = args[1]
        check(sigs, img)
        args = args[2:]
