/* Runs the exact walls.asm bytes (walls.blob) against a fake camera, a fake zone collision (boxes) with a
 * fake segment test, a fake client test and a fake QueryPerformanceCounter.
 *
 * Each scene puts the camera somewhere looking somewhere (the client's view and projection: row vectors,
 * right-handed, y down, F 242, 16:9, near 0.1, far 65535), an actor's box in front of it and 0-4 walls
 * between them, makes the screen box and test depth the way the actor update (0C63D0) does, and calls the
 * entry the way the actor draw's call site does (thiscall, 9 arguments, ret 24h). Checks:
 *   - each point the stub tries is the model's (box fraction, test depth, put back through the view),
 *     and the model's points project back onto their pixels and the test depth (the inverse is right);
 *   - each segment runs from the point (0.1 toward the eye) to the eye (0.3 short of it);
 *   - the answer is 256 on the first clear segment, 0 only when all NPOINTS are blocked;
 *   - no walls: shown; a wall covering the whole box: hidden; a low wall: shown;
 *   - kept actors, near and far boxes are shown without a segment; the budget answers shown once spent,
 *     and starts again on the next frame;
 *   - USE_STOCK, no renderer, no collision, no gGame, a NaN box, a bad size, a bad projection or a NaN depth run
 *     the client's test with the same object and arguments, and its result comes back;
 *   - ebx/esi/edi/ebp and the stack pointer come back as they were; the counters agree with the calls.
 * Built and run by test_stubs.py (32-bit, no CRT).
 */
typedef unsigned long DWORD; typedef int BOOL; typedef unsigned int UINT; typedef void *HANDLE;
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

static double dsqrt(double x) { __asm { fld x } __asm { fsqrt } __asm { fstp x } return x; }
static double dabs(double x) { return x < 0 ? -x : x; }

/* ---------------------------------------------------------------- the stub */
enum { ORIG_TEST, SEG_TEST, RENDERER, GRID_OFF, GAME, QPC, BUDGET, NPOINTS, MIN_DIST, MAX_DIST, KEEP_A, KEEP_B,
       USE_STOCK, S_TESTS, S_SEGS, S_HIDDEN, S_SHOWN, S_OVER, S_FALLBACK, S_TICKS, ENTRY, NSYM };
static unsigned char *base;
static DWORD sym[NSYM];
#define P32(i) (*(DWORD *)(base + sym[i]))
#define PF(i) (*(float *)(base + sym[i]))

static void load(void) {
    static unsigned char blob[65536];
    DWORD n = 0, i, size, nrel, nsym, *h;
    HANDLE f = CreateFileA("walls.blob", 0x80000000, 1, 0, 3, 0, 0);
    if (f == (HANDLE)-1 || !ReadFile(f, blob, sizeof blob, &n, 0) || n < 12) fail("cannot read walls.blob");
    h = (DWORD *)blob; size = h[0]; nrel = h[1]; nsym = h[2];
    if (nsym != NSYM) fail("symbol count");
    base = VirtualAlloc(0, size, 0x3000, 0x40);
    if (!base) fail("VirtualAlloc");
    for (i = 0; i < size; i++) base[i] = blob[12 + 4 * (nrel + nsym) + i];
    for (i = 0; i < nrel; i++) *(DWORD *)(base + h[3 + i]) += (DWORD)base;
    for (i = 0; i < nsym; i++) sym[i] = h[3 + nrel + i];
}

/* ---------------------------------------------------------------- the fake client */
#define GRID 0x1D8
static __declspec(align(16)) unsigned char game[0x400], renderer[0x400];
static DWORD game_global, renderer_global;
static float *const view = (float *)(game + 0x94), *const proj = (float *)(game + 0x154);
#define FRAME (*(DWORD *)(game + 0x34))

/* Walls: boxes { min x y z, max x y z }. */
#define MAXW 8
static double wall[MAXW][6]; static int nwall;
#define MAXSEG 16
static float seg_from[MAXSEG][3], seg_to[MAXSEG][3]; static int seg_hit[MAXSEG], nseg;
static DWORD seg_this;

static int seg_box(const float *a, const float *b, const double *w) {
    double t0 = 0, t1 = 1;
    int i;
    for (i = 0; i < 3; i++) {
        double d = (double)b[i] - a[i];
        if (dabs(d) < 1e-12) {
            if (a[i] < w[i] || a[i] > w[3 + i]) return 0;
        } else {
            double u = (w[i] - a[i]) / d, v = (w[3 + i] - a[i]) / d;
            if (u > v) { double t = u; u = v; v = t; }
            if (u > t0) t0 = u;
            if (v < t1) t1 = v;
            if (t0 > t1) return 0;
        }
    }
    return 1;
}
static DWORD __stdcall seg_body(DWORD self, const float *from, const float *to, float *o) {
    int i, hit = 0;
    if (nseg >= MAXSEG) fail("too many segments in one test");
    seg_this = self;
    for (i = 0; i < 3; i++) { seg_from[nseg][i] = from[i]; seg_to[nseg][i] = to[i]; }
    for (i = 0; i < nwall; i++) if (seg_box(from, to, wall[i])) hit = 1;
    seg_hit[nseg++] = hit;
    o[0] = o[1] = o[2] = 12345.0f;
    return hit ? 0xBAD0C001u : 0xBAD0C000u;    /* only al counts */
}
/* thiscall (from, to, out), ret 0Ch; scribbles on the scratch and SSE registers as a real callee may. */
__declspec(naked) static void fake_seg(void) {
    __asm {
        push    dword ptr [esp + 12]
        push    dword ptr [esp + 12]
        push    dword ptr [esp + 12]
        push    ecx
        call    seg_body
        mov     ecx, 0BAD0C0DEh
        mov     edx, 0BAD0C0DEh
        xorps   xmm0, xmm0
        xorps   xmm1, xmm1
        xorps   xmm2, xmm2
        xorps   xmm3, xmm3
        xorps   xmm4, xmm4
        xorps   xmm5, xmm5
        xorps   xmm6, xmm6
        xorps   xmm7, xmm7
        ret     0Ch
    }
}

static DWORD orig_calls, orig_obj, orig_args[9], orig_ret = 777;
static DWORD __stdcall orig_body(DWORD obj, DWORD *args) {
    int i;
    orig_calls++;
    orig_obj = obj;
    for (i = 0; i < 9; i++) orig_args[i] = args[i];
    return orig_ret;
}
__declspec(naked) static void fake_orig(void) {
    __asm {
        lea     eax, [esp + 4]
        push    eax
        push    ecx
        call    orig_body
        mov     ecx, 0BAD0C0DEh
        mov     edx, 0BAD0C0DEh
        ret     24h
    }
}

static __int64 qpc_now = 1000000; static int qpc_step = 3, qpc_calls;
static BOOL __stdcall fake_qpc(__int64 *p) {
    qpc_calls++;
    *p = qpc_now;
    qpc_now += qpc_step;
    return 1;
}

/* Calls the entry as the actor draw does, with known values in the registers it must keep. */
static DWORD c_entry, c_obj, c_args[9], c_ret, c_bad, c_esp0, c_esp1;
__declspec(naked) static void do_call(void) {
    __asm {
        pushad
        mov     c_esp0, esp
        mov     eax, 8
    pushargs:
        push    dword ptr [c_args + eax * 4]
        dec     eax
        jns     pushargs
        mov     ecx, c_obj
        mov     ebx, 11111111h
        mov     esi, 22222222h
        mov     edi, 33333333h
        mov     ebp, 44444444h
        call    dword ptr [c_entry]
        mov     c_ret, eax
        cmp     ebx, 11111111h
        jne     bad
        cmp     esi, 22222222h
        jne     bad
        cmp     edi, 33333333h
        jne     bad
        cmp     ebp, 44444444h
        jne     bad
        jmp     done
    bad:
        mov     c_bad, 1
    done:
        mov     c_esp1, esp
        popad
        ret
    }
}

/* ---------------------------------------------------------------- the camera and the box */
static DWORD seed = 12345;
static DWORD rnd(void) { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed; }
static double frand(double a, double b) { return a + (b - a) * (double)(rnd() >> 8) / 16777216.0; }
static DWORD fbits(float f) { return *(DWORD *)&f; }
static float bitsf(DWORD d) { return *(float *)&d; }

static double eye[3];
#define WI 5120
#define HI 2880
#define W ((float)WI)
#define H ((float)HI)
static void normalize(double *v) { double l = dsqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); v[0] /= l; v[1] /= l; v[2] /= l; }
static void cross(const double *a, const double *b, double *o) {
    o[0] = a[1] * b[2] - a[2] * b[1]; o[1] = a[2] * b[0] - a[0] * b[2]; o[2] = a[0] * b[1] - a[1] * b[0];
}
/* D3DXMatrixLookAtRH with up = -y (the client's y is down), and PerspectiveFovRH with F 242 at 16:9. */
static void camera(const double *e, const double *at) {
    double z[3], x[3], y[3], up[3] = { 0, -1, 0 };
    int i;
    for (i = 0; i < 3; i++) { eye[i] = e[i]; z[i] = e[i] - at[i]; }
    normalize(z); cross(up, z, x); normalize(x); cross(z, x, y);
    memset(view, 0, 64);
    for (i = 0; i < 3; i++) { view[4 * i] = (float)x[i]; view[4 * i + 1] = (float)y[i]; view[4 * i + 2] = (float)z[i]; }
    view[12] = (float)-(x[0] * e[0] + x[1] * e[1] + x[2] * e[2]);
    view[13] = (float)-(y[0] * e[0] + y[1] * e[1] + y[2] * e[2]);
    view[14] = (float)-(z[0] * e[0] + z[1] * e[1] + z[2] * e[2]);
    view[15] = 1;
    memset(proj, 0, 64);
    proj[5] = 242.0f / 192.0f;
    proj[0] = proj[5] / 1.68563f;
    proj[10] = 65535.0f / (0.1f - 65535.0f);
    proj[11] = -1;
    proj[14] = 0.1f * 65535.0f / (0.1f - 65535.0f);
}
static void to_view(const double *w, double *v) {
    int i;
    for (i = 0; i < 3; i++) v[i] = w[0] * view[i] + w[1] * view[4 + i] + w[2] * view[8 + i] + view[12 + i];
}
/* View space to pixels and NDC z, as 028370 + 0278E0 do. */
static void to_screen(const double *v, double *s) {
    double cw = -v[2], x = v[0] * proj[0] / cw, y = v[1] * proj[5] / cw, z = (v[2] * proj[10] + proj[14]) / cw;
    s[0] = (x + 1) * (double)(WI >> 1);
    s[1] = (1 - y) * (double)(HI >> 1);
    s[2] = z;
}
/* The actor update's box: 8 corners in view space, nearer than _22 clamped to it (z0 then 0.01), projected;
 * the box is { min x, min y, max x, max y } and the depth a quarter of the way in. 0 if the game
 * wouldn't test it (z0 < 0). */
static float box[4], depth;
static int make_box(const double *lo, const double *hi) {
    double mn[3] = { 1e30, 1e30, 1e30 }, mx[3] = { -1e30, -1e30, -1e30 };
    int c, i, clamped = 0;
    for (c = 0; c < 8; c++) {
        double w[3], v[3], s[3];
        w[0] = (c & 1) ? hi[0] : lo[0]; w[1] = (c & 2) ? hi[1] : lo[1]; w[2] = (c & 4) ? hi[2] : lo[2];
        to_view(w, v);
        if (v[2] > -proj[5]) { v[2] = -proj[5]; clamped = 1; }
        to_screen(v, s);
        for (i = 0; i < 3; i++) { if (s[i] < mn[i]) mn[i] = s[i]; if (s[i] > mx[i]) mx[i] = s[i]; }
    }
    if (clamped) mn[2] = 0.01;
    if (mn[2] < 0) return 0;
    box[0] = (float)mn[0]; box[1] = (float)mn[1]; box[2] = (float)mx[0]; box[3] = (float)mx[1];
    depth = (float)(mn[2] + (mx[2] - mn[2]) * 0.25f);
    return 1;
}

/* ---------------------------------------------------------------- the model */
static const double FXS[9] = { 0.5, 0.5, 1 / 6.0, 5 / 6.0, 0.5, 1 / 6.0, 5 / 6.0, 1 / 6.0, 5 / 6.0 };
static const double FYS[9] = { 0.5, 1 / 6.0, 0.5, 0.5, 5 / 6.0, 1 / 6.0, 1 / 6.0, 5 / 6.0, 5 / 6.0 };
/* The model's point k (world) and the segment's ends; returns the view distance. */
static double model_point(int k, double *p, double *from, double *to) {
    double x0 = box[0] < box[2] ? box[0] : box[2], x1 = box[0] < box[2] ? box[2] : box[0];
    double y0 = box[1] < box[3] ? box[1] : box[3], y1 = box[1] < box[3] ? box[3] : box[1];
    double px = x0 + FXS[k] * (x1 - x0), py = y0 + FYS[k] * (y1 - y0);
    double d = proj[14] / (depth + proj[10]);
    double v[3], a[3], u[3], l, s[3], back[3];
    int j;
    v[0] = (px * 2 / W - 1) * d / proj[0];
    v[1] = (1 - py * 2 / H) * d / proj[5];
    v[2] = -d;
    for (j = 0; j < 3; j++) a[j] = v[j] - view[12 + j];
    for (j = 0; j < 3; j++) p[j] = a[0] * view[4 * j] + a[1] * view[4 * j + 1] + a[2] * view[4 * j + 2];
    /* The inverse is right: the point goes back onto its pixel at the test depth (to the float view's
     * rounding, about 1e-4 yalms at 800 from the origin). */
    to_view(p, back);
    to_screen(back, s);
    if (dabs(s[0] - px) > 0.05 + 0.5 / d || dabs(s[1] - py) > 0.05 + 0.5 / d || dabs(-back[2] - d) > 2e-3) {
        printf("point %d: pixel %d,%d -> %d,%d (x1000)\n", k, (int)(px * 1000), (int)(py * 1000), (int)(s[0] * 1000), (int)(s[1] * 1000));
        fail("a point put back into the world doesn't project onto its pixel");
    }
    for (j = 0; j < 3; j++) u[j] = eye[j] - p[j];
    l = dsqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
    for (j = 0; j < 3; j++) { u[j] /= l; from[j] = p[j] + 0.1 * u[j]; to[j] = eye[j] - 0.3 * u[j]; }
    return d;
}

/* ---------------------------------------------------------------- running a test */
#define OBJ 0x05123400u                         /* the test object; the actor is 0x8F0 below it */
static int calls, n_shown, n_hidden, n_mis, n_fx, n_inside, n_centred, n_segs_total;

/* Calls the entry with the box and depth; checks registers, stack, and the client's test not run. */
static void call_entry(float wdt, float hgt) {
    static float rect[4];
    int i;
    for (i = 0; i < 4; i++) rect[i] = box[i];
    c_entry = (DWORD)base + sym[ENTRY];
    c_obj = OBJ;
    c_args[0] = (DWORD)rect; c_args[1] = fbits(depth); c_args[2] = fbits(wdt); c_args[3] = fbits(hgt);
    c_args[4] = rnd(); c_args[5] = rnd(); c_args[6] = 1; c_args[7] = 1; c_args[8] = 0;
    nseg = 0;
    c_bad = 0;
    do_call();
    calls++;
    if (c_bad) fail("a register the caller keeps was changed");
    if (c_esp0 != c_esp1) fail("stack pointer changed");
    for (i = 0; i < 4; i++) if (fbits(rect[i]) != fbits(box[i])) fail("the box was written to");
    n_segs_total += nseg;
}

/* A scene's test: every segment is the model's, and the answer follows the segments. */
static int check_scene(void) {
    DWORD before = orig_calls, np = P32(NPOINTS);
    int k;
    call_entry(W, H);
    if (orig_calls != before) fail("the client's test ran in a normal scene");
    if (nseg > 0 && seg_this != (DWORD)renderer) fail("the segment test ran on something other than the renderer");
    if (nseg > (int)np) fail("more segments than NPOINTS");
    for (k = 0; k < nseg; k++) {
        double p[3], from[3], to[3];
        int j;
        model_point(k, p, from, to);
        for (j = 0; j < 3; j++) {
            double tol = 0.02 + 2e-4 * dabs(from[j]);
            if (dabs(seg_from[k][j] - from[j]) > tol || dabs(seg_to[k][j] - to[j]) > tol) {
                printf("segment %d axis %d: from %d want %d, to %d want %d (x1000)\n", k, j,
                       (int)(seg_from[k][j] * 1000), (int)(from[j] * 1000), (int)(seg_to[k][j] * 1000), (int)(to[j] * 1000));
                fail("a segment isn't the model's");
            }
        }
        if (k < nseg - 1 && !seg_hit[k]) fail("kept testing after a clear segment");
        /* The model's own answer for the exact ends (in double): only grazing cases may differ. */
        {
            float ff[3], tf[3];
            int i, hit = 0;
            for (j = 0; j < 3; j++) { ff[j] = (float)from[j]; tf[j] = (float)to[j]; }
            for (i = 0; i < nwall; i++) if (seg_box(ff, tf, wall[i])) hit = 1;
            if (hit != seg_hit[k]) n_mis++;
        }
    }
    if (nseg == 0) fail("no segment in a normal scene");
    if (c_ret == 256) {
        if (seg_hit[nseg - 1]) fail("shown, but the last segment was blocked");
        n_shown++;
    } else if (c_ret == 0) {
        if (nseg != (int)np) fail("hidden before every point was tried");
        for (k = 0; k < nseg; k++) if (!seg_hit[k]) fail("hidden with a clear segment");
        n_hidden++;
    } else fail("answer neither 0 nor 256");
    return (int)c_ret;
}

/* The stub's settings and counters, the collision loaded, no walls (the camera stays). */
static void reset(void) {
    *(DWORD *)(renderer + GRID) = 0x0BADF00D;
    game_global = (DWORD)game; renderer_global = (DWORD)renderer;
    P32(ORIG_TEST) = (DWORD)fake_orig; P32(SEG_TEST) = (DWORD)fake_seg;
    P32(RENDERER) = (DWORD)&renderer_global; P32(GRID_OFF) = GRID; P32(GAME) = (DWORD)&game_global;
    P32(QPC) = (DWORD)fake_qpc; P32(BUDGET) = 0; P32(NPOINTS) = 9; PF(MIN_DIST) = 1.0f; PF(MAX_DIST) = 100.0f;
    P32(KEEP_A) = 0; P32(KEEP_B) = 0; P32(USE_STOCK) = 0;
    P32(S_TESTS) = P32(S_SEGS) = P32(S_HIDDEN) = P32(S_SHOWN) = P32(S_OVER) = P32(S_FALLBACK) = P32(S_TICKS) = 0;
    nwall = 0;
}

/* A random camera and an actor's box in front of it at distance r. */
static double lo[3], hi[3], centre[3];
static void random_scene(double rmin, double rmax) {
    double e[3], at[3], f[3], x[3], y[3], r, wdt, hgt, ox, oy, up[3] = { 0, -1, 0 };
    int i;
    e[0] = frand(-800, 800); e[1] = frand(-60, 60); e[2] = frand(-800, 800);
    f[0] = frand(-1, 1); f[1] = frand(-0.6, 0.6); f[2] = frand(-1, 1);
    normalize(f);
    for (i = 0; i < 3; i++) at[i] = e[i] + f[i];
    camera(e, at);
    cross(f, up, x); normalize(x); cross(x, f, y);
    r = frand(rmin, rmax); ox = frand(-0.5, 0.5) * r; oy = frand(-0.3, 0.3) * r;
    for (i = 0; i < 3; i++) centre[i] = e[i] + f[i] * r + x[i] * ox + y[i] * oy;
    wdt = frand(0.4, 3.0); hgt = frand(0.8, 6.0);
    lo[0] = centre[0] - wdt / 2; hi[0] = centre[0] + wdt / 2;
    lo[1] = centre[1] - hgt / 2; hi[1] = centre[1] + hgt / 2;
    lo[2] = centre[2] - wdt / 2; hi[2] = centre[2] + wdt / 2;
}
/* A wall: a box around a point between the eye and the actor. */
static void add_wall(double t, double sx, double sy, double sz, double jitter) {
    double c[3];
    int i;
    for (i = 0; i < 3; i++) c[i] = eye[i] + (centre[i] - eye[i]) * t + frand(-jitter, jitter);
    wall[nwall][0] = c[0] - sx; wall[nwall][3] = c[0] + sx;
    wall[nwall][1] = c[1] - sy; wall[nwall][4] = c[1] + sy;
    wall[nwall][2] = c[2] - sz; wall[nwall][5] = c[2] + sz;
    nwall++;
}

/* A test that must run the client's own test: same object and arguments, its result returned. */
static void want_fallback(const char *what) {
    DWORD before = orig_calls, fb = P32(S_FALLBACK);
    int i;
    call_entry(W, H);
    if (orig_calls != before + 1) { out(what); out(": "); fail("the client's test didn't run"); }
    if (orig_obj != OBJ) fail("the client's test ran on another object");
    for (i = 0; i < 9; i++) if (orig_args[i] != c_args[i]) fail("arguments not passed through");
    if (c_ret != orig_ret) fail("the client's result wasn't returned");
    if (nseg != 0) fail("a segment ran before falling back");
    if (P32(S_FALLBACK) != fb + 1) fail("fallback not counted");
    orig_ret = rnd() & 0x1FF;
}
static void want_shown(const char *what) {
    DWORD before = orig_calls;
    call_entry(W, H);
    if (c_ret != 256) { out(what); out(": "); fail("not shown"); }
    if (orig_calls != before) fail("the client's test ran");
    if (nseg != 0) { out(what); out(": "); fail("a segment ran"); }
}

/* The test depth's view distance (as the stub works it out). */
static double box_dist(void) { return proj[14] / (depth + proj[10]); }
/* A scene in [rmin, rmax] the game would test, with its box between 1.05 and 100 yalms. */
static void scene(double rmin, double rmax) {
    for (;;) {
        random_scene(rmin, rmax);
        if (make_box(lo, hi) && box_dist() > 1.05 && box_dist() < 100) return;
    }
}
/* A slab across the line of sight at t of the way from the eye (thin along its major axis), 400 across. */
static void add_slab(double t) {
    double c[3], f[3];
    int i, k;
    for (i = 0; i < 3; i++) { c[i] = eye[i] + (centre[i] - eye[i]) * t; f[i] = centre[i] - eye[i]; }
    k = dabs(f[0]) > dabs(f[1]) ? (dabs(f[0]) > dabs(f[2]) ? 0 : 2) : (dabs(f[1]) > dabs(f[2]) ? 1 : 2);
    for (i = 0; i < 3; i++) { wall[nwall][i] = c[i] - (i == k ? 0.2 : 200); wall[nwall][3 + i] = c[i] + (i == k ? 0.2 : 200); }
    nwall++;
}

int main(void) {
    int s, k, mode, n_low = 0;
    load();
    memset(game, 0, sizeof game); memset(renderer, 0, sizeof renderer);

    /* 1. Random scenes, random walls; every NPOINTS. */
    for (mode = 0; mode < 3; mode++)
        for (s = 0; s < 6000; s++) {
            int w;
            reset();
            P32(NPOINTS) = mode == 0 ? 9 : mode == 1 ? 1 + (rnd() % 9) : 5;
            scene(1.5, 95);
            for (w = (int)(rnd() % 5); w > 0; w--)
                add_wall(frand(0.15, 0.9), frand(0.05, 6), frand(0.05, 6), frand(0.05, 6), 2.0);
            check_scene();
            /* The middle point lands on the actor (its box, a little bigger). */
            {
                double p[3], from[3], to[3], m = 0.25;
                model_point(0, p, from, to);
                n_centred++;
                if (p[0] > lo[0] - m && p[0] < hi[0] + m && p[1] > lo[1] - m && p[1] < hi[1] + m && p[2] > lo[2] - m && p[2] < hi[2] + m)
                    n_inside++;
            }
        }
    printf("random scenes: %d shown, %d hidden, %d segments; %d segment answers differ from the model's (grazing)\n",
           n_shown, n_hidden, n_segs_total, n_mis);
    printf("the middle point is on the actor's box (+0.25) in %d of %d\n", n_inside, n_centred);
    if (n_mis * 200 > n_segs_total) fail("too many segment answers differ from the model's");
    if (n_inside * 10 < n_centred * 9) fail("the middle point misses the actor too often");
    if (n_shown < 1000 || n_hidden < 500) fail("the scenes don't cover both answers");

    /* 2. Fixed cases: no walls shown on the first segment; a slab across the view hidden after 9; a
     * wall below the box's bottom, the eye above the box: shown. */
    for (s = 0; s < 3000; s++) {
        double p[3], from[3], to[3];
        reset();
        scene(10, 90);
        if (check_scene() != 256 || nseg != 1) fail("no walls: not shown on the first segment");
        add_slab(0.35);
        if (check_scene() != 0 || nseg != 9) fail("a slab across the view: not hidden after 9 segments");
        nwall = 0;
        model_point(0, p, from, to);
        if (eye[1] > lo[1] - 0.5 || p[1] >= hi[1]) continue;
        for (k = 0; k < 3; k++) { wall[0][k] = eye[k] + (centre[k] - eye[k]) * 0.9 - 3; wall[0][3 + k] = wall[0][k] + 6; }
        wall[0][1] = hi[1]; wall[0][4] = hi[1] + 50;
        nwall = 1;
        if (check_scene() != 256) fail("a wall below the box hid it");
        n_low++;
    }
    printf("fixed cases ok (%d with a low wall)\n", n_low);
    if (n_low < 300) fail("too few low-wall cases");

    /* 3. Shown without a segment: kept actors, near, far, at the far plane, behind. */
    reset();
    scene(10, 40);
    add_wall(0.5, 200, 200, 200, 0);    /* everything blocked */
    P32(KEEP_A) = OBJ - 0x8F0; want_shown("KEEP_A"); P32(KEEP_A) = 0;
    P32(KEEP_B) = OBJ - 0x8F0; want_shown("KEEP_B"); P32(KEEP_B) = 0;
    {
        float dz = depth;
        depth = 0.05f; want_shown("near");
        depth = 0.9995f; want_shown("far");
        depth = 1.0f; want_shown("far plane");
        depth = 1.5f; want_shown("past the far plane");
        depth = -0.5f; want_shown("behind");
        depth = dz;
    }
    PF(MAX_DIST) = 5.0f; want_shown("MAX_DIST"); PF(MAX_DIST) = 100.0f;
    PF(MIN_DIST) = 50.0f; want_shown("MIN_DIST"); PF(MIN_DIST) = 1.0f;
    if (check_scene() != 0) fail("everything blocked: not hidden");

    /* 4. The budget: once a frame's ticks are spent, shown without a segment; the next frame starts again. */
    reset();
    scene(10, 40);
    add_wall(0.5, 200, 200, 200, 0);
    qpc_step = 100; P32(BUDGET) = 450;
    FRAME = 7;
    for (k = 0; k < 4; k++) {
        int q = qpc_calls;
        if (check_scene() != 0) fail("budget: a test within the budget wasn't run");
        if (qpc_calls != q + 2) fail("budget: not timed");
    }
    /* 4 tests x 100 ticks = 400 < 450: one more runs (500), then the frame's spent. */
    if (check_scene() != 0) fail("budget: the 5th test didn't run");
    want_shown("over budget");
    want_shown("over budget again");
    if (P32(S_OVER) != 2) fail("budget: over not counted");
    if (P32(S_TICKS) != 500) fail("budget: ticks not counted");
    FRAME = 8;
    if (check_scene() != 0) fail("budget: the next frame didn't start again");
    P32(BUDGET) = 0; qpc_step = 3;
    P32(QPC) = 0;
    { int q = qpc_calls; if (check_scene() != 0 || qpc_calls != q) fail("no QPC: timing still called"); }

    /* 5. The client's own test. */
    reset();
    scene(10, 40);
    P32(USE_STOCK) = 1; want_fallback("USE_STOCK"); P32(USE_STOCK) = 0;
    renderer_global = 0; want_fallback("no renderer"); renderer_global = (DWORD)renderer;
    *(DWORD *)(renderer + GRID) = 0; want_fallback("no collision"); *(DWORD *)(renderer + GRID) = 1;
    game_global = 0; want_fallback("no gGame"); game_global = (DWORD)game;
    box[1] = bitsf(0x7FC00000); want_fallback("NaN in the box"); make_box(lo, hi);
    box[2] = 3e6f; want_fallback("box out of range"); make_box(lo, hi);
    {
        DWORD before = orig_calls;
        call_entry(0.0f, H); if (orig_calls != before + 1) fail("zero width: no fallback");
        call_entry(W, bitsf(0x7FC00000)); if (orig_calls != before + 2) fail("NaN height: no fallback");
        call_entry(W, 1e6f); if (orig_calls != before + 3) fail("huge height: no fallback");
    }
    { float p0 = proj[0]; proj[0] = 0; want_fallback("_11 = 0"); proj[0] = bitsf(0x7FC00000); want_fallback("_11 NaN"); proj[0] = p0; }
    { float p5 = proj[5]; proj[5] = -1; want_fallback("_22 < 0"); proj[5] = p5; }
    { float dz = depth; depth = bitsf(0x7FC00000); want_fallback("NaN depth"); depth = dz; }
    { float v = view[13]; view[13] = 1e9f; want_fallback("eye out of range"); view[13] = v; }
    check_scene();

    /* 6. The counters agree with the answers. */
    reset();
    {
        DWORD segs = 0, clear = 0, hidden = 0, shown = 0;
        for (s = 0; s < 3000; s++) {
            int w;
            nwall = 0;
            random_scene(0.5, 120);
            if (!make_box(lo, hi)) continue;
            for (w = (int)(rnd() % 4); w > 0; w--) add_wall(frand(0.2, 0.9), frand(0.1, 5), frand(0.1, 5), frand(0.1, 5), 2.0);
            call_entry(W, H);
            segs += nseg;
            if (c_ret == 0) hidden++;
            else if (nseg > 0 && !seg_hit[nseg - 1]) clear++;
            else shown++;
        }
        printf("counters: %lu tests, %lu segments, %lu clear, %lu hidden, %lu shown without a clear one, %lu fallbacks\n",
               P32(S_TESTS), P32(S_SEGS), clear, P32(S_HIDDEN), P32(S_SHOWN), P32(S_FALLBACK));
        if (P32(S_SEGS) != segs || P32(S_HIDDEN) != hidden || P32(S_SHOWN) != shown || P32(S_FALLBACK) != 0
            || P32(S_OVER) != 0 || P32(S_TESTS) != clear + hidden + shown)
            fail("the counters disagree with the answers");
        if (shown == 0) fail("no near or far boxes in the counter run");
    }
    printf("OK\n");
    ExitProcess(0);
    return 0;
}
