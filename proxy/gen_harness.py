"""Writes harness.c: runs the exact proxy bytes (proxy.blob) in front of a simulated D3D8 device.

Each seed runs one random client call stream twice: straight to the simulated device, then through
the proxy. Every triangle drawn (with a hash of all device state that affects it), every other draw,
clear, Present and Get* result is logged; the two logs must be identical. The device scrambles some
state inside Present/BeginScene/EndScene, as Ashita's GUI and plugins do. The stack pointer is
checked around every call.
"""
import os
HERE = os.path.dirname(os.path.abspath(__file__))

NARGS = [2,0,0,0,0,1,1,1,1,1, 3,3,1,2,1,4,3,1,2,1, 7,8,6,5,5,6,5,4,5,2, 1,2,1,1,0,0,6,2,2,2,
         1,1,1,1,2,2,2,2,2,2, 2,2,0,1,1,1,1,2,1,1, 2,2,3,3,1,3,2,2,1,1, 3,5,4,8,5,4,1,1,1,3,
         3,3,3,3,3,2,2,2,1,1, 1,3,3,3,3,3,1]
assert len(NARGS) == 97

methods = []
for i in range(128):
    n = NARGS[i] if i < 97 else 0
    params = ''.join(', DWORD a%d' % k for k in range(n))
    vals = ', '.join(['a%d' % k for k in range(n)] + ['0'] * (8 - n)) if n < 8 else ', '.join('a%d' % k for k in range(8))
    methods.append('static HRESULT __stdcall m%d(void *self%s) { DWORD a[8] = { %s }; return sim(self, %d, a); }' % (i, params, vals, i))

C = r'''
typedef unsigned long DWORD; typedef int BOOL; typedef unsigned int UINT; typedef long HRESULT;
typedef unsigned char BYTE; typedef void *HANDLE;
__declspec(dllimport) void *__stdcall VirtualAlloc(void *, DWORD, DWORD, DWORD);
__declspec(dllimport) HANDLE __stdcall CreateFileA(const char *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
__declspec(dllimport) BOOL __stdcall ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) void __stdcall ExitProcess(UINT);
__declspec(dllimport) int __cdecl wsprintfA(char *, const char *, ...);
int _fltused = 0;
#pragma function(memcpy, memset)
void *memcpy(void *d, const void *s, unsigned n) { char *a = d; const char *b = s; while (n--) *a++ = *b++; return d; }
void *memset(void *d, int c, unsigned n) { char *a = d; while (n--) *a++ = (char)c; return d; }
static char pbuf[1024];
static void out(const char *s) { DWORD n = 0, w; while (s[n]) n++; WriteFile(GetStdHandle((DWORD)-11), s, n, &w, 0); }
#define printf(...) (wsprintfA(pbuf, __VA_ARGS__), out(pbuf))
static void fail(const char *s) { out("FAIL: "); out(s); out("\n"); ExitProcess(1); }

/* ---------------------------------------------------------------- the simulated device */
typedef struct { void **vtbl; } Dev;
static Dev dev;
static DWORD rs[256], tss[8][32], tex[8], vs, ps, strm[16][2], idx[2], len[8], rt, vp[6];
static BYTE light[8][104], mat[68], xf[14][64];
static int rec;
#define MAXREC 64
#define MAXBLK 32
typedef struct { DWORD i, a[8]; BYTE blob[104]; } Rec;
static Rec blk[MAXBLK][MAXREC]; static int blkn[MAXBLK], nblk, cur;

static DWORD *obs; static int nobs, maxobs;
static DWORD gets[3000000]; static int ngets;
static void logget(DWORD a, DWORD b) { if (ngets + 2 > 3000000) fail("get log full"); gets[ngets++] = a; gets[ngets++] = b; }
static void log3(DWORD k, DWORD a, DWORD b) {
    if (nobs + 3 > maxobs) fail("log full");
    obs[nobs++] = k; obs[nobs++] = a; obs[nobs++] = b;
}
static DWORD fnv(DWORD h, const void *p, int n) { const BYTE *b = p; while (n--) { h ^= *b++; h *= 16777619u; } return h; }
static DWORD state_hash(int full) {
    DWORD h = 2166136261u;
    h = fnv(h, rs, sizeof rs); h = fnv(h, tss, sizeof tss); h = fnv(h, tex, sizeof tex);
    h = fnv(h, &vs, 4); h = fnv(h, &ps, 4); h = fnv(h, len, sizeof len); h = fnv(h, light, sizeof light);
    h = fnv(h, mat, sizeof mat); h = fnv(h, xf, sizeof xf); h = fnv(h, &rt, 4); h = fnv(h, vp, sizeof vp);
    if (full) { h = fnv(h, strm, sizeof strm); h = fnv(h, idx, sizeof idx); }
    else h = fnv(h, &strm[1][0], sizeof strm - 8);   /* UP draws: stream 0 and the indices don't matter */
    return h;
}
static int xf_slot(DWORD s) {
    if (s == 2 || s == 3) return s - 2;
    if (s >= 16 && s <= 23) return s - 14;
    if (s >= 256 && s <= 259) return s - 246;
    return -1;
}
static DWORD scr = 1;
static DWORD srnd(void) { scr ^= scr << 13; scr ^= scr >> 17; scr ^= scr << 5; return scr; }
/* What Ashita's GUI and plugins may do inside Present/BeginScene/EndScene. */
static void scramble(void) {
    int n = srnd() % 4, k;
    for (k = 0; k < n; k++) {
        DWORD r = srnd();
        switch (r % 6) {
        case 0: rs[(r >> 8) % 256] = (r >> 16) % 3; break;
        case 1: tss[(r >> 8) % 2][(r >> 12) % 32] = (r >> 20) % 3; break;
        case 2: tex[(r >> 8) % 2] = 0x9000; break;
        case 3: vs = 0x9001; break;
        case 4: strm[0][0] = 0x9002; break;
        case 5: xf[(r >> 8) % 14][0] ^= 1; break;
        }
    }
}
static HRESULT sim(void *self, int i, DWORD *a);
static int hooked[128];   /* slots the proxy hooks: their order against draws matters */
static void apply(Rec *r) { DWORD a[8]; int k; for (k = 0; k < 8; k++) a[k] = r->a[k];
    if (r->i == 44) a[1] = (DWORD)r->blob; if (r->i == 42) a[0] = (DWORD)r->blob; if (r->i == 37) a[1] = (DWORD)r->blob;
    sim(&dev, r->i, a); }
static int record(int i, DWORD *a, const void *blob, int n) {
    Rec *r;
    if (!rec) return 0;
    if (blkn[cur] >= MAXREC) fail("block full");
    r = &blk[cur][blkn[cur]++]; r->i = i; memcpy(r->a, a, 32);
    if (blob) memcpy(r->blob, blob, n);
    return 1;
}
static HRESULT sim(void *self, int i, DWORD *a) {
    int k;
    if (self != &dev) fail("wrong this");
    switch (i) {
    case 50: if (record(i, a, 0, 0)) return 0; if (a[0] < 256) rs[a[0]] = a[1]; return 0;
    case 63: if (record(i, a, 0, 0)) return 0; if (a[0] < 8 && a[1] < 32) tss[a[0]][a[1]] = a[2]; return 0;
    case 61: if (record(i, a, 0, 0)) return 0; if (a[0] < 8) tex[a[0]] = a[1]; return 0;
    case 76: if (record(i, a, 0, 0)) return 0; vs = a[0]; return 0;
    case 88: if (record(i, a, 0, 0)) return 0; ps = a[0]; return 0;
    case 83: if (record(i, a, 0, 0)) return 0; if (a[0] < 16) { strm[a[0]][0] = a[1]; strm[a[0]][1] = a[2]; } return 0;
    case 85: if (record(i, a, 0, 0)) return 0; idx[0] = a[0]; idx[1] = a[1]; return 0;
    case 46: if (record(i, a, 0, 0)) return 0; if (a[0] < 8) len[a[0]] = a[1]; return 0;
    case 44: if (record(i, a, (void *)a[1], 104)) return 0; if (a[0] < 8) memcpy(light[a[0]], (void *)a[1], 104); return 0;
    case 42: if (record(i, a, (void *)a[0], 68)) return 0; memcpy(mat, (void *)a[0], 68); return 0;
    case 37: if (record(i, a, (void *)a[1], 64)) return 0; k = xf_slot(a[0]); if (k >= 0) memcpy(xf[k], (void *)a[1], 64); return 0;
    case 39: k = xf_slot(a[0]); if (k >= 0) { BYTE *m = (BYTE *)a[1]; int j; for (j = 0; j < 64; j++) xf[k][j] ^= m[j] + 1; } return 0;
    case 40: memcpy(vp, (void *)a[0], 24); return 0;
    case 31: rt = a[0]; vp[0] = vp[1] = 0; vp[2] = 640; vp[3] = 480; return 0;
    case 52: if (nblk >= MAXBLK) fail("too many blocks"); cur = nblk++; blkn[cur] = 0; rec = 1; return 0;
    case 53: rec = 0; *(DWORD *)a[0] = cur + 1; return 0;
    case 54: if (a[0] >= 1 && (int)a[0] <= nblk) { int b = a[0] - 1; for (k = 0; k < blkn[b]; k++) apply(&blk[b][k]); } log3(54, a[0], state_hash(1)); return 0;
    case 14: memset(rs, 0, sizeof rs); memset(tss, 0, sizeof tss); memset(tex, 0, sizeof tex); vs = ps = 0;
             memset(strm, 0, sizeof strm); memset(idx, 0, sizeof idx); memset(len, 0, sizeof len); memset(light, 0, sizeof light);
             memset(mat, 0, sizeof mat); memset(xf, 0, sizeof xf); log3(14, 0, 0); return 0;
    case 15: case 34: case 35: log3(i, state_hash(1), 0); scramble(); return 0;
    case 36: log3(36, state_hash(1), a[0]); return 0;
    case 70: log3(70, state_hash(1), a[0] * 65536 + a[1] * 256 + a[2]); return 0;
    case 71: log3(71, state_hash(1), a[1] + a[3] * 256); return 0;
    case 73: log3(73, state_hash(1), a[3]); strm[0][0] = strm[0][1] = 0; idx[0] = idx[1] = 0; return 0;
    case 72: {
        DWORD sh = state_hash(0), t, type = a[0], n = a[1], stride = a[3];
        BYTE *v = (BYTE *)a[2];
        for (t = 0; t < n; t++) {
            DWORD i0, i1, i2;
            if (type == 5) { if (t & 1) { i0 = t + 1; i1 = t; } else { i0 = t; i1 = t + 1; } i2 = t + 2; }
            else if (type == 4) { i0 = 3 * t; i1 = 3 * t + 1; i2 = 3 * t + 2; }
            else { log3(72, sh, type * 1000 + n); break; }
            log3(1, sh, fnv(fnv(fnv(2166136261u, v + i0 * stride, stride), v + i1 * stride, stride), v + i2 * stride, stride));
        }
        strm[0][0] = strm[0][1] = 0;
        return 0; }
    case 51: *(DWORD *)a[1] = a[0] < 256 ? rs[a[0]] : 0; logget(a[0], *(DWORD *)a[1]); return 0;
    case 62: *(DWORD *)a[2] = (a[0] < 8 && a[1] < 32) ? tss[a[0]][a[1]] : 0; logget(a[1], *(DWORD *)a[2]); return 0;
    case 77: *(DWORD *)a[0] = vs; logget(77, vs); return 0;
    case 78: log3(78, a[0], 0); return 0;
    default: if (hooked[i]) log3(1000 + i, 0, 0); else logget(1000 + i, 0); return 0;
    }
}
'''
C += '\n'.join(methods) + '\n'
C += 'static void *simvt[128] = { %s };\n' % ', '.join('(void *)m%d' % i for i in range(128))
C += 'static const int NARGS[97] = { %s };\n' % ', '.join(map(str, NARGS))
C += r'''
/* ---------------------------------------------------------------- calling like the client */
static DWORD call(int i, int n, DWORD *args) {
    void *fn = dev.vtbl[i], *self = &dev;
    DWORD r, before, after;
    if (n != NARGS[i]) fail("arg count");
    __asm {
        mov before, esp
        mov ecx, n
        mov esi, args
    L1: test ecx, ecx
        jz L2
        dec ecx
        push dword ptr [esi + ecx*4]
        jmp L1
    L2: push self
        call fn
        mov r, eax
        mov after, esp
    }
    if (before != after) { printf("method %d: esp %08lx -> %08lx\n", i, before, after); fail("stack imbalance"); }
    return r;
}
static DWORD crnd_s;
static DWORD crnd(void) { crnd_s ^= crnd_s << 13; crnd_s ^= crnd_s >> 17; crnd_s ^= crnd_s << 5; return crnd_s; }
static BYTE lights[3][104], mats[3][68], mtx[3][64], vbuf[1024], vport[2][24];
static DWORD tokens[16]; static int ntok;

static void client(DWORD seed, int steps) {
    int s;
    DWORD a[8];
    crnd_s = seed; scr = seed * 7 + 1; ntok = 0;
    for (s = 0; s < steps; s++) {
        DWORD r = crnd(), w = r % 100, x = crnd();
        memset(a, 0, sizeof a);
        if (w < 30) {           /* a glyph: SetVertexShader + strip quad from a reused buffer */
            DWORD stride = (x % 10 == 0) ? 20 : (x % 37 == 0) ? 68 : 28, k;
            if (x % 3 == 0) { a[0] = 0x144; call(76, 1, a); }
            for (k = 0; k < stride; k++) vbuf[k + (x >> 8) % (3 * stride)] = (BYTE)crnd();
            a[0] = 5; a[1] = 2; a[2] = (DWORD)vbuf; a[3] = stride; call(72, 4, a);
        } else if (w < 33) { a[0] = (x & 1) ? 4 : 5; a[1] = (x & 1) ? 1 : 3; a[2] = (DWORD)vbuf; a[3] = 28; call(72, 4, a); }
        else if (w < 43) { static const DWORD K[] = { 7, 27, 137, 22, 60, 300 }; a[0] = K[x % 6]; a[1] = (x >> 8) % 3; call(50, 2, a); }
        else if (w < 50) { a[0] = (x % 7 == 0) ? 9 : x % 2; a[1] = (x >> 4) % 5 == 4 ? 40 : 1 + (x >> 4) % 4; a[2] = (x >> 8) % 3; call(63, 3, a); }
        else if (w < 54) { a[0] = (x % 9 == 0) ? 8 : x % 2; a[1] = ((x >> 4) % 3) * 0x1000; call(61, 2, a); }
        else if (w < 57) { static const DWORD H[] = { 0x144, 0x152, 0x5 }; a[0] = H[x % 3]; call(76, 1, a); }
        else if (w < 58) { a[0] = x % 2; call(88, 1, a); }
        else if (w < 61) { a[0] = (x % 11 == 0) ? 17 : x % 2; a[1] = 0x3000 + ((x >> 4) % 2) * 0x1000; a[2] = (x >> 8) % 2 ? 28 : 32; call(83, 3, a); }
        else if (w < 62) { a[0] = 0x5000 + (x % 2) * 0x1000; a[1] = ((x >> 4) % 2) * 4; call(85, 2, a); }
        else if (w < 64) { a[0] = (x % 9 == 0) ? 9 : x % 2; a[1] = (x >> 4) % 2; call(46, 2, a); }
        else if (w < 66) { if (x % 5 == 0) lights[x % 3][(x >> 8) % 104] ^= 1; a[0] = (x >> 3) % 9 == 0 ? 9 : (x >> 3) % 2; a[1] = (DWORD)lights[(x >> 6) % 3]; call(44, 2, a); }
        else if (w < 67) { if (x % 5 == 0) mats[x % 3][(x >> 8) % 68] ^= 1; a[0] = (DWORD)mats[(x >> 6) % 3]; call(42, 1, a); }
        else if (w < 71) { static const DWORD S[] = { 2, 3, 16, 256, 257, 1, 300 }; if (x % 5 == 0) mtx[x % 3][(x >> 8) % 64] ^= 1; a[0] = S[(x >> 3) % 7]; a[1] = (DWORD)mtx[(x >> 6) % 3]; call(37, 2, a); }
        else if (w < 72) { a[0] = (x % 2) ? 256 : 2; a[1] = (DWORD)mtx[(x >> 6) % 3]; call(39, 2, a); }
        else if (w < 75) { a[0] = 4; a[1] = x % 100; a[2] = 2; call(70, 3, a); }
        else if (w < 77) { a[0] = 4; a[1] = 0; a[2] = 0; a[3] = 12; a[4] = 0; a[5] = x % 50; call(71, 5, a); }
        else if (w < 78) { a[0] = 4; a[3] = 1; a[6] = (DWORD)vbuf; a[7] = 28; call(73, 8, a); }
        else if (w < 80) { a[0] = 1 + x % 2; call(31, 2, a); }
        else if (w < 81) { vport[x % 2][(x >> 4) % 24] ^= 1; a[0] = (DWORD)vport[x % 2]; call(40, 1, a); }
        else if (w < 82) { a[1] = 0; a[2] = 3; call(36, 6, a); }
        else if (w < 84) call(34, 0, a);
        else if (w < 86) call(35, 0, a);
        else if (w < 88) call(15, 4, a);
        else if (w < 90) { DWORD v; a[0] = (x % 2) ? 7 : 137; a[1] = (DWORD)&v; call(51, 2, a); }
        else if (w < 91) { DWORD v; a[0] = 0; a[1] = 1; a[2] = (DWORD)&v; call(62, 3, a); }
        else if (w < 92) { DWORD v; a[0] = (DWORD)&v; call(77, 1, a); }
        else if (w < 93) {      /* record a state block */
            int k, n = 1 + x % 4;
            if (ntok >= 16) continue;
            call(52, 0, a);
            for (k = 0; k < n; k++) {
                DWORD y = crnd();
                memset(a, 0, sizeof a);
                if (y % 3 == 0) { a[0] = 27; a[1] = (y >> 4) % 3; call(50, 2, a); }
                else if (y % 3 == 1) { a[0] = 0; a[1] = 1; a[2] = (y >> 4) % 3; call(63, 3, a); }
                else { a[0] = 0; a[1] = ((y >> 4) % 3) * 0x1000; call(61, 2, a); }
            }
            memset(a, 0, sizeof a); a[0] = (DWORD)&tokens[ntok++]; call(53, 1, a);
        }
        else if (w < 96) { if (ntok) { a[0] = tokens[x % ntok]; call(54, 1, a); } }
        else if (w < 97) { a[0] = 0x144; call(78, 1, a); }
        else if (w < 98) { a[0] = 0; call(5, 1, a); }      /* something flushing but harmless */
        else if (w < 99) { a[0] = 0; call(0, 2, a); }      /* QueryInterface: passes through */
        else if (x % 50 == 0) call(14, 1, a);              /* Reset, now and then */
    }
    memset(a, 0, sizeof a);
    call(15, 4, a);
}

static void reset_sim(void) {
    memset(rs, 0, sizeof rs); memset(tss, 0, sizeof tss); memset(tex, 0, sizeof tex); vs = ps = 0;
    memset(strm, 0, sizeof strm); memset(idx, 0, sizeof idx); memset(len, 0, sizeof len); memset(light, 0, sizeof light);
    memset(mat, 0, sizeof mat); memset(xf, 0, sizeof xf); rt = 0; memset(vp, 0, sizeof vp); rec = 0; nblk = 0;
    memset(vbuf, 0, sizeof vbuf); memset(lights, 0, sizeof lights); memset(mats, 0, sizeof mats); memset(mtx, 0, sizeof mtx); memset(vport, 0, sizeof vport);
    lights[1][0] = 1; lights[2][5] = 2; mats[1][0] = 1; mtx[1][0] = 1; mtx[2][63] = 7;
}

/* ---------------------------------------------------------------- the proxy */
enum { D_PENDING, D_PBYTES, D_STRIDE, D_PDEV, D_BUF, D_BUFSIZE, S_SKIPPED, S_MERGED, S_BATCHES, F_BATCH,
       F_DEDUPE, F_REC, ORIG, VT_RTTI, VTABLE, THUNK_TABLE, VALID_START, VALID_END, FLUSH, NSYM };
static DWORD sym[NSYM];
static BYTE *base;
#define P32(s) (*(DWORD *)(base + sym[s]))
#define P8(s) (*(BYTE *)(base + sym[s]))

static void load_proxy(DWORD bufsize) {
    static BYTE file[65536];
    DWORD got = 0, size, nrel, nsym, *rel, i;
    HANDLE h = CreateFileA("proxy.blob", 0x80000000, 1, 0, 3, 0, 0);
    if (h == (HANDLE)-1) fail("proxy.blob");
    ReadFile(h, file, sizeof file, &got, 0);
    size = ((DWORD *)file)[0]; nrel = ((DWORD *)file)[1]; nsym = ((DWORD *)file)[2];
    if (nsym != NSYM) fail("symbol count");
    rel = (DWORD *)file + 3;
    for (i = 0; i < NSYM; i++) sym[i] = rel[nrel + i];
    base = VirtualAlloc(0, size + 16 + bufsize, 0x3000, 0x40);
    memcpy(base, (BYTE *)(rel + nrel + NSYM), size);
    for (i = 0; i < nrel; i++) *(DWORD *)(base + rel[i]) += (DWORD)base;
    P32(D_BUF) = ((DWORD)base + size + 15) & ~15u;
    P32(D_BUFSIZE) = bufsize;
    for (i = 0; i < 128; i++) ((DWORD *)(base + sym[ORIG]))[i] = (DWORD)simvt[i];
    for (i = 0; i < 128; i++) {
        DWORD t = ((DWORD *)(base + sym[THUNK_TABLE]))[i];
        ((DWORD *)(base + sym[VTABLE]))[i] = t ? t : ((DWORD *)(base + sym[ORIG]))[i];
        hooked[i] = t != 0;
    }
}
static void reset_proxy(int batch, int dedupe) {
    memset(base + sym[VALID_START], 0, sym[VALID_END] - sym[VALID_START]);
    P32(D_PENDING) = 0; P32(S_SKIPPED) = P32(S_MERGED) = P32(S_BATCHES) = 0;
    P8(F_BATCH) = (BYTE)batch; P8(F_DEDUPE) = (BYTE)dedupe; P8(F_REC) = 0;
}

static DWORD refgets[3000000]; static int nrefgets;
void start(void) {
    DWORD *ref, seed;
    int nref, mode, total_runs = 0;
    static const char *names[] = { "neither", "batch", "dedupe", "both" };
    DWORD sk[4] = { 0 }, mg[4] = { 0 }, bt[4] = { 0 }, calls_ref = 0;
    maxobs = 6000000;
    ref = VirtualAlloc(0, maxobs * 4, 0x3000, 0x04);
    obs = VirtualAlloc(0, maxobs * 4, 0x3000, 0x04);
    load_proxy(8192);   /* small buffer so the full-buffer path runs too */
    for (seed = 1; seed <= 60; seed++) {
        int steps = (seed % 10 == 0) ? 200000 : 20000;
        DWORD *tmp;
        reset_sim(); nobs = 0; ngets = 0; dev.vtbl = simvt;
        client(seed, steps);
        nref = nobs; tmp = ref; ref = obs; obs = tmp;
        memcpy(refgets, gets, ngets * 4); nrefgets = ngets;
        for (mode = 0; mode < 4; mode++) {
            int k;
            reset_sim(); nobs = 0; ngets = 0;
            reset_proxy(mode & 1, (mode >> 1) & 1);
            dev.vtbl = (void **)(base + sym[VTABLE]);
            client(seed, steps);
            if (P32(D_PENDING) != 0) fail("batch left pending after Present");
            if (nobs != nref) { printf("seed %lu mode %s: %d observations, reference %d\n", seed, names[mode], nobs / 3, nref / 3); }
            for (k = 0; k < (nobs < nref ? nobs : nref); k++) {
                if (obs[k] != ref[k]) {
                    int j = k - k % 3;
                    printf("seed %lu mode %s: first difference at observation %d: proxy (%lu %08lx %08lx) reference (%lu %08lx %08lx)\n",
                        seed, names[mode], j / 3, obs[j], obs[j + 1], obs[j + 2], ref[j], ref[j + 1], ref[j + 2]);
                    fail("mismatch");
                }
            }
            if (nobs != nref) fail("length mismatch");
            if (ngets != nrefgets) fail("get count mismatch");
            for (k = 0; k < ngets; k++) if (gets[k] != refgets[k]) { printf("seed %lu mode %s: Get result %d differs\n", seed, names[mode], k / 2); fail("get mismatch"); }
            sk[mode] += P32(S_SKIPPED); mg[mode] += P32(S_MERGED); bt[mode] += P32(S_BATCHES);
            total_runs++;
        }
    }
    printf("OK: %d proxied runs identical to the direct runs.\n", total_runs);
    for (mode = 0; mode < 4; mode++)
        printf("  %-7s skipped %8lu Set calls, merged %8lu quads into %7lu draws\n", names[mode], sk[mode], mg[mode], bt[mode]);
    ExitProcess(0);
}
'''
open(os.path.join(HERE, 'harness.c'), 'w').write(C)
print('wrote harness.c')
