"""Offline check: loads hifps against a client dump and reports where its call sites ended up.

Usage: python tools/check_client.py <FFXiMain_XXXXXXXX.bin> [--shift <offset> <bytes>] [--walls]

The dump is mapped at its own base (in the file name; that address must be free in this 64-bit
process) and hifps.lua runs under LuaJIT (lupa) with ashita.memory reading and writing it. Checks:
  - every call site and smoothing loop is found, and each site is patched with its table's kind;
  - calls to the getter no table names get whole ticks;
  - after unload the image is byte for byte what it was.
--walls also turns the walls toggle on and off (/hifps exp walls): the characters' test call goes to
walls_code.lua's entry, its copy is the built bytes with their relocations, and the client addresses
it's handed are the ones the dump's own code holds; off puts the call back, and it's left on for the
unload check.
--shift simulates a client update: <bytes> bytes are inserted into .text at <offset> (code after it
moves, the trailing padding of .text absorbs it, data stays put), with a new call to the getter in
them. Calls to the getter after the insert are fixed up; other code isn't (nothing here runs it).
"""
import ctypes, ctypes.wintypes as wt, os, re, struct, sys, tempfile
from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__))
HIFPS = os.path.normpath(os.path.join(HERE, '..')).replace('\\', '/')
LIBS = os.path.normpath(os.path.join(HERE, '..', '..', 'libs')).replace('\\', '/')
GETTER = re.compile(rb'\x8B\x0D....\xD9\x41\x28\xD8\x1D....\xDF\xE0\xF6\xC4\x05\x7A\x07\xD9\x05....\xC3\xD9\x41\x28\xC3', re.S)

path = sys.argv[1]
BASE = int(re.search(r'_([0-9A-Fa-f]{8})\.bin$', path).group(1), 16)
img = bytearray(open(path, 'rb').read())

pe = struct.unpack_from('<I', img, 0x3C)[0]
nsec = struct.unpack_from('<H', img, pe + 6)[0]
sec = pe + 24 + struct.unpack_from('<H', img, pe + 20)[0]
for i in range(nsec):
    e = sec + 40 * i
    if img[e:e + 8].rstrip(b'\0') == b'.text':
        TVS, TVA = struct.unpack_from('<II', img, e + 8)
getters = [m.start() for m in GETTER.finditer(img)]
assert len(getters) == 2, getters

def callers(b):
    out = []
    for m in re.finditer(rb'\xE8', bytes(b[TVA:TVA + TVS - 4])):
        i = TVA + m.start()
        if i + 5 + struct.unpack_from('<i', b, i + 1)[0] in getters:
            out.append(i)
    return out

SHIFT = None
if '--shift' in sys.argv:
    k = sys.argv.index('--shift')
    at, n = int(sys.argv[k + 1], 16), int(sys.argv[k + 2], 0)
    assert TVA < at and at > getters[1] + 0x40
    old = callers(img)
    pad_end = TVA + ((TVS + 0xFFF) & ~0xFFF)
    assert img[pad_end - n:pad_end] == b'\0' * n, 'no room in .text padding'
    new = bytearray(b'\x90' * n)
    new[0:5] = b'\xE8' + struct.pack('<i', getters[0] - (at + 5))       # a new caller
    img[at:pad_end] = new + img[at:pad_end - n]
    for c in old:
        if c >= at:
            c2 = c + n
            struct.pack_into('<i', img, c2 + 1, struct.unpack_from('<i', img, c2 + 1)[0] - n)
    SHIFT = (at, n)
    print('shifted .text by %d bytes at %06X, with a new getter call there' % (n, at))

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.VirtualAlloc.restype = ctypes.c_void_p
k32.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, wt.DWORD, wt.DWORD]
p = k32.VirtualAlloc(BASE, (len(img) + 0xFFFF) & ~0xFFFF, 0x3000, 0x40)
assert p == BASE, 'base %08X not free' % BASE
ctypes.memmove(BASE, bytes(img), len(img))
ARENA = k32.VirtualAlloc(0x20000000, 0x100000, 0x3000, 0x40)
assert ARENA == 0x20000000
ctypes.memset(ARENA, 0, 0x100000)
def rd(a, n): return bytes((ctypes.c_char * n).from_address(a))
def wr(a, b): ctypes.memmove(a, bytes(b), len(b))

def find(pat, n):
    rx = b''.join(b'.' if t == '??' else re.escape(bytes([int(t, 16)])) for t in re.findall('..', pat))
    hits = [BASE + 0x1000 + m.start() for m in re.finditer(rx, rd(BASE + 0x1000, len(img) - 0x1000), re.S)]
    return hits[n] if n < len(hits) else 0

# The fps divisor's object: a fake one in the arena.
dp = find('81EC000100003BC174218B0D', 0)
gp = struct.unpack('<I', rd(dp + 0x0C, 4))[0]
wr(gp, struct.pack('<I', ARENA)); wr(ARENA + 0x30, struct.pack('<I', 1))
before = rd(BASE, len(img))

lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
lua.execute(f"package.path = [[{HIFPS}/?.lua;{LIBS}/?.lua;]] .. package.path")
alloc_next = [ARENA + 0x1000]
def alloc(n):
    r = alloc_next[0]; alloc_next[0] += (int(n) + 15) & ~15; return r
lua.globals().py = lua.table_from({'find': lambda pat, n: find(pat, int(n)), 'alloc': lambda n: alloc(n),
                                    'base': BASE, 'size': len(img), 'install': tempfile.mkdtemp(prefix='hifps_cc_')})
events, chatlog = lua.execute(r'''
local ffi = require('ffi');
local events, chatlog = {}, {};
local function p(a, t) return ffi.cast(t .. '*', ffi.cast('uintptr_t', bit.band(a, 0xFFFFFFFF) % 4294967296)); end
local function ua(a) a = tonumber(a); return a < 0 and a + 4294967296 or a; end
local function P(a, t) return ffi.cast(t .. '*', ffi.cast('uintptr_t', ua(a))); end
ashita = {
    events = { register = function (ev, name, fn) events[ev] = fn; end },
    fs = { exists = function () return false; end, create_dir = function () return true; end },
    memory = {
        find = function (m, s, pat, off, n) return py.find(pat, n); end,
        get_base = function () return py.base; end,
        get_size = function () return py.size; end,
        read_uint8 = function (a) return P(a, 'uint8_t')[0]; end,
        read_uint32 = function (a) return P(a, 'uint32_t')[0]; end,
        read_int32 = function (a) return P(a, 'int32_t')[0]; end,
        read_float = function (a) return tonumber(P(a, 'float')[0]); end,
        read_array = function (a, n) local q = P(a, 'uint8_t'); local r = {}; for i = 1, n do r[i] = q[i - 1]; end return r; end,
        write_array = function (a, t) local q = P(a, 'uint8_t'); for i = 1, #t do q[i - 1] = t[i]; end end,
        write_float = function (a, v) P(a, 'float')[0] = v; end,
        write_uint8 = function (a, v) P(a, 'uint8_t')[0] = v; end,
        write_uint32 = function (a, v) P(a, 'uint32_t')[0] = ua(v) % 4294967296; end,
        unprotect = function () return true, 0x40; end,
        protect = function () return true; end,
        alloc = function (n) return py.alloc(n); end,
        dealloc = function () end,
    },
};
addon = {};
package.loaded['chat'] = {
    header = function (n) local s = { t = '[' .. n .. '] ' }; function s:append(x) table.insert(chatlog, self.t .. x); return self; end return s; end,
    message = function (s) return s; end, error = function (s) return 'ERROR: ' .. s; end, success = function (s) return s; end,
};
package.loaded['imgui'] = setmetatable({}, { __index = function () return function () return true; end; end });
_G.print = function (x) if (type(x) == 'table') then return; end io.write(tostring(x), '\n'); end
require('common');
AshitaCore = { GetInstallPath = function () return py.install .. '\\'; end };
dofile([[]] .. [[]] .. HIFPS_FILE);
return events, chatlog;
'''.replace('HIFPS_FILE', "'%s/hifps.lua'" % HIFPS))

fails = []
def check(cond, what):
    print(('  ok   ' if cond else '  FAIL ') + what)
    if not cond: fails.append(what)
seen = [0]
def show():
    lines = list(chatlog.values())
    for l in lines[seen[0]:]: print('   ', l)
    seen[0] = len(lines)

events['load']()
show()
STATE = lua.execute('''
local fn = ...;
local i = 1;
while true do
    local n, v = debug.getupvalue(fn, i);
    if (n == nil) then return nil; end
    if (n == 'state') then return v; end
    i = i + 1;
end''', events['d3d_present'])
check(STATE.mem is not None, 'hifps enabled')

# Expected kinds from the tables (old offsets), mapped through the shift.
kinds = lua.execute('''
local src = io.open(... .. '/hifps.lua'):read('*a');
local function list(name)
    local body = src:match('local ' .. name .. ' = (%b{})');
    body = body:gsub('%-%-[^\\n]*', '');
    local t = {};
    for h in body:gmatch('0x(%x+)') do t[#t + 1] = tonumber(h, 16); end
    return t;
end
local r = {};
for _, x in ipairs(list('FRAC_SITES')) do r[x] = 'f'; end
for _, x in ipairs(list('INT_SITES')) do r[x] = 'i'; end
for _, x in ipairs(list('STOCK_SITES')) do r[x] = 's'; end
return r;
''', HIFPS)
# Where each offset should be: shifted by --shift, or (another client) where gen_sigs.py's own
# matcher, written separately in Python, finds its signature.
sys.path.insert(0, HERE)
import gen_sigs
SIGS = {r: (w, o, h) for r, w, o, h in gen_sigs.build(gen_sigs.Image(gen_sigs.REF))} if os.path.exists(gen_sigs.REF) else {}
other = None
if SIGS and os.path.basename(path) != os.path.basename(gen_sigs.REF):
    other = gen_sigs.Image(path)
def moved(rva):
    if SHIFT:
        return rva + SHIFT[1] if rva >= SHIFT[0] else rva
    if other is not None and rva in SIGS:
        w, o, h = SIGS[rva]
        if gen_sigs.compile_pat(h).match(other.d, rva - o):
            return rva
        m = gen_sigs.matches(other, o, h, w)
        return m[0] if len(m) == 1 else None
    return rva
got = {}
for i in range(1, len(STATE.sites) + 1):
    s = STATE.sites[i]
    got[(int(s.addr) & 0xFFFFFFFF) - BASE] = s.kind
want = {moved(r): k for r, k in kinds.items()}
check(all(got.get(r) == k for r, k in want.items()), 'every FRAC/INT/STOCK site found at its place with its kind (%d)' % len(want))
bad = [(hex(r), k, got.get(r)) for r, k in want.items() if got.get(r) != k][:5]
if bad: print('   e.g.', bad)
check(sorted(got) == sorted(callers(img)),
      'every call to the getter is patched (%d sites, %d callers)' % (len(got), len(callers(img))))
if SHIFT:
    check(got.get(SHIFT[0]) == 'i', 'the new getter call gets whole ticks')
loops = re.search(r'local SMOOTH_LOOPS = \{(.*?)\n\};', open(HIFPS + '/hifps.lua', encoding='utf-8').read(), re.S).group(1)
loops = re.sub(r'--[^\n]*', '', loops)
n_imm, n_ops = len(re.findall(r'imm = 0x', loops)), len(re.findall(r'at = 0x', loops))
check(len(STATE.smooth) == n_imm and len(STATE.ops) == n_ops,
      'smoothing loops: %d of %d immediates, %d of %d operands patched' % (len(STATE.smooth), n_imm, len(STATE.ops), n_ops))
for i in range(1, len(STATE.ops) + 1):
    o = STATE.ops[i]
    d = struct.unpack('<I', rd(int(o.addr) & 0xFFFFFFFF, 4))[0]
    if d != (int(o.slot) & 0xFFFFFFFF): check(False, 'operand at %06X points at its slot' % ((int(o.addr) & 0xFFFFFFFF) - BASE))

if '--walls' in sys.argv:
    def u32(a): return struct.unpack('<I', rd(a, 4))[0]
    def target(site): return (site + 5 + struct.unpack('<i', rd(site + 1, 4))[0]) & 0xFFFFFFFF
    def command(text): events['command'](lua.table_from({'command': text, 'blocked': False})); show()
    EXP = lua.execute('''
local fn = ...;
local i = 1;
while true do
    local n, v = debug.getupvalue(fn, i);
    if (n == nil) then return nil; end
    if (n == 'exp') then return v; end
    i = i + 1;
end''', events['command'])
    W = lua.eval("package.loaded['walls_code']")
    site = find('8D8EF0080000E8????????3BC58986F4', 0) + 6
    stock = rd(site, 5)
    command('/hifps exp walls on')
    check(EXP.on['walls'] is True and EXP.walls is not None and EXP.walls.site is not None, 'walls on')
    if EXP.walls is not None and EXP.walls.site is not None:
        base = int(EXP.walls.base) & 0xFFFFFFFF
        def sym(n): return base + int(W.sym[n])
        code = bytearray(bytes.fromhex(W.hex))
        for i in range(1, len(W.relocs) + 1):
            r = int(W.relocs[i])
            struct.pack_into('<I', code, r, (struct.unpack_from('<I', code, r)[0] + base) & 0xFFFFFFFF)
        data = [sym(n) for n in ('ORIG_TEST', 'SEG_TEST', 'RENDERER', 'GRID_OFF', 'GAME', 'QPC', 'BUDGET', 'KEEP_A', 'KEEP_B',
                                 'S_TESTS', 'S_SEGS', 'S_HIDDEN', 'S_SHOWN', 'S_OVER', 'S_FALLBACK', 'S_TICKS')]
        got_code = bytearray(rd(base, int(W.size)))
        for a in data: got_code[a - base:a - base + 4] = code[a - base:a - base + 4]
        check(got_code == code, 'the walls code is the built bytes with their relocations (%d bytes, %d relocations)' % (int(W.size), len(W.relocs)))
        check(target(site) == sym('ENTRY'), 'the characters\' test call at %06X goes to the walls entry' % (site - BASE))
        check(u32(sym('ORIG_TEST')) == (site + 5 + struct.unpack('<i', stock[1:])[0]) & 0xFFFFFFFF,
              'ORIG_TEST is where the call went (%06X)' % (u32(sym('ORIG_TEST')) - BASE))
        seg = find('81C178010000E9????????90909090908A442404A2????????C3', 0)
        cam = find('8B0D????????8D94248C0000008D6F44528D4424605550E8????????84C07517', 0)
        check(u32(sym('SEG_TEST')) == seg and target(cam + 0x17) == seg, 'SEG_TEST is the camera\'s segment test (%06X)' % (seg - BASE))
        check(u32(sym('RENDERER')) == u32(cam + 2), 'RENDERER is the camera\'s renderer global (%08X)' % u32(cam + 2))
        check(u32(sym('GRID_OFF')) == 0x178 + rd(find('81ECD0000000535556578BF98B4760C7877C8001000000000085C00F84', 0) + 14, 1)[0],
              'GRID_OFF is the collision map (+178h) plus its grid field (+60h)')
        game = u32(find('A1????????0594000000C3', 0) + 1)
        check(u32(sym('GAME')) == game and u32(find('A1????????0554010000C3', 0) + 1) == game and u32(target(find('8BBEF0090000E8', 0) + 6) + 1) == game,
              'GAME is the global the view, projection and frame count getters read (%08X)' % game)
        check(u32(sym('QPC')) != 0, 'QPC set')
        check(u32(sym('BUDGET')) == int(STATE.freq) // 1000, 'BUDGET is 1 ms of QueryPerformanceCounter ticks (%d)' % u32(sym('BUDGET')))
        check(u32(sym('NPOINTS')) == 9 and struct.unpack('<ff', rd(sym('MIN_DIST'), 4) + rd(sym('MAX_DIST'), 4)) == (1.0, 100.0),
              'NPOINTS 9, MIN_DIST 1, MAX_DIST 100')
        # The present callback's per-frame part (the whole callback would read the client's heap).
        keep = lua.execute('''
local fn = ...;
local i = 1;
while true do
    local n, v = debug.getupvalue(fn, i);
    if (n == nil) then return nil; end
    if (n == 'walls_keep') then return v; end
    i = i + 1;
end''', events['d3d_present'])
        wr(sym('KEEP_A'), b'\xEE' * 4); wr(sym('USE_STOCK'), b'\xEE' * 4)
        keep()
        check(u32(sym('KEEP_A')) == 0 and u32(sym('KEEP_B')) == 0 and u32(sym('USE_STOCK')) == 0,
              'walls_keep: no actors to keep and no cutscene without the game')
    command('/hifps exp walls off')
    check(EXP.on['walls'] is None and rd(site, 5) == stock, 'walls off puts the call back')
    command('/hifps exp walls on')
    check(EXP.on['walls'] is True, 'walls on again (left on for the unload check)')

events['unload']()
show()
after = rd(BASE, len(img))
diff = [i for i in range(len(img)) if before[i] != after[i]]
check(not diff, 'image back to what it was after unload' + ('' if not diff else ' (%d bytes differ, first at %06X)' % (len(diff), diff[0])))
print('FAILED: %d' % len(fails) if fails else 'all ok')
sys.exit(1 if fails else 0)
