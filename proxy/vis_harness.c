/* Runs the exact vis.asm bytes (vis.blob) against a fake occlusion test and a fake frame count.
 *
 * Each scenario calls the entries the way the client's call sites do (thiscall, 9 arguments, ret 24h)
 * for objects that come and go, share table sets, get called twice in a frame or skip frames. Checks:
 *   - every answer is either a test run now (with the caller's object and arguments, its result
 *     returned) or the same object's last result from fewer than N frames ago;
 *   - N = 1 runs every test (stock);
 *   - ebx/esi/edi/ebp and the stack pointer come back as they were;
 *   - an object called every frame is tested once every N frames, the re-tests spread over the frames.
 * Built and run by test_vis.py (32-bit, no CRT).
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

/* ---------------------------------------------------------------- the stub */
enum { ORIG_TEST, GET_FRAME, N_FX, N_DOOR, S_RUN, S_SKIP, TABLE, ENTRY_FX, ENTRY_DOOR, NSYM };
static unsigned char *base;
static DWORD sym[NSYM];
static unsigned char *table;
#define P32(i) (*(DWORD *)(base + sym[i]))
#define NSETS 256

static void load(void) {
    static unsigned char blob[65536];
    DWORD n = 0, i, size, nrel, nsym, *h;
    HANDLE f = CreateFileA("vis.blob", 0x80000000, 1, 0, 3, 0, 0);
    if (f == (HANDLE)-1 || !ReadFile(f, blob, sizeof blob, &n, 0) || n < 12) fail("cannot read vis.blob");
    h = (DWORD *)blob; size = h[0]; nrel = h[1]; nsym = h[2];
    if (nsym != NSYM) fail("symbol count");
    base = VirtualAlloc(0, size, 0x3000, 0x40);
    table = VirtualAlloc(0, NSETS * 32, 0x3000, 0x04);
    if (!base || !table) fail("VirtualAlloc");
    for (i = 0; i < size; i++) base[i] = blob[12 + 4 * (nrel + nsym) + i];
    for (i = 0; i < nrel; i++) *(DWORD *)(base + h[3 + i]) += (DWORD)base;
    for (i = 0; i < nsym; i++) sym[i] = h[3 + nrel + i];
}

/* ---------------------------------------------------------------- the fake client */
static DWORD g_frame;                       /* what the frame count getter returns */
static DWORD g_calls, g_obj, g_args[9], g_ret, g_seed = 12345;
static DWORD rnd(void) { g_seed ^= g_seed << 13; g_seed ^= g_seed >> 17; g_seed ^= g_seed << 5; return g_seed; }

static DWORD __stdcall test_body(DWORD obj, DWORD *args) {
    int i;
    g_calls++;
    g_obj = obj;
    for (i = 0; i < 9; i++) g_args[i] = args[i];
    g_ret = rnd() & 0x1FF;
    return g_ret;
}
/* thiscall, 9 arguments, ret 24h; scribbles on the scratch registers as a real callee may. */
__declspec(naked) static void fake_test(void) {
    __asm {
        lea     eax, [esp + 4]
        push    eax
        push    ecx
        call    test_body
        mov     ecx, 0BAD0C0DEh
        mov     edx, 0BAD0C0DEh
        ret     24h
    }
}
/* The client's getter: only eax changes. */
__declspec(naked) static void fake_frame(void) {
    __asm {
        mov     eax, g_frame
        ret
    }
}

/* Calls an entry as the client's call sites do, with known values in the registers it must keep. */
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

/* ---------------------------------------------------------------- the model */
#define NOBJ 48
typedef struct { DWORD addr, door, tested, last_frame, last_ret, calls, tests; } Obj;
static Obj obj[NOBJ];
static DWORD set_of(DWORD a) { return (a * 2654435761u) >> 24; }

static void call(Obj *o) {
    int i;
    DWORD before = g_calls, n = o->door ? P32(N_DOOR) : P32(N_FX);
    c_entry = (DWORD)base + sym[o->door ? ENTRY_DOOR : ENTRY_FX];
    c_obj = o->addr;
    for (i = 0; i < 9; i++) c_args[i] = rnd();
    c_bad = 0;
    do_call();
    if (c_bad) fail("a register the caller keeps was changed");
    if (c_esp0 != c_esp1) fail("stack pointer changed");
    o->calls++;
    if (g_calls == before + 1) {
        if (g_obj != o->addr) fail("test ran on another object");
        for (i = 0; i < 9; i++) if (g_args[i] != c_args[i]) fail("arguments not passed through");
        if (c_ret != g_ret) fail("the test's result was not returned");
        o->tested = 1; o->last_frame = g_frame; o->last_ret = g_ret; o->tests++;
    } else if (g_calls == before) {
        if (n == 1) fail("N = 1 skipped a test");
        if (!o->tested) fail("answered without ever testing");
        if (c_ret != o->last_ret) fail("answered with something other than its last result");
        if (g_frame - o->last_frame >= n) { printf("frame %lu last %lu n %lu\n", g_frame, o->last_frame, n); fail("answered with a result N or more frames old"); }
    } else fail("the test ran more than once");
}

static void reset(DWORD nfx, DWORD ndoor) {
    int i;
    memset(table, 0, NSETS * 32);
    P32(ORIG_TEST) = (DWORD)fake_test;
    P32(GET_FRAME) = (DWORD)fake_frame;
    *(DWORD *)(base + sym[TABLE]) = (DWORD)table;
    P32(N_FX) = nfx; P32(N_DOOR) = ndoor;
    P32(S_RUN) = 0; P32(S_SKIP) = 0;
    for (i = 0; i < NOBJ; i++) {
        obj[i].tested = 0; obj[i].calls = 0; obj[i].tests = 0;
    }
}

/* Objects: addresses on 4-byte steps, 1 in 8 a door; objects 40-47 crowd three table sets (3 or 4
 * objects in a 2-way set). Odd addresses too (the lens flare's test object is at +0x17F). */
static void make_objects(void) {
    int i, k = 40;
    DWORD a;
    for (i = 0; i < 40; i++) {
        obj[i].addr = 0x05000000 + (rnd() & 0x00FFFFFC) + (i == 7 ? 0x17F : 0);
        obj[i].door = (i % 8) == 3;
    }
    for (a = 0x06000000; k < NOBJ; a += 4)
        if (set_of(a) == set_of(obj[0].addr) || set_of(a) == set_of(obj[1].addr) || set_of(a) == set_of(obj[2].addr)) {
            obj[k].addr = a; obj[k].door = 0; k++;
        }
}

/* mode 0: every object every frame; 1: objects come and go, some frames called twice, frame count
 * sometimes jumps; returns the largest number of tests on one frame after the first 64. */
static DWORD run(DWORD nfx, DWORD ndoor, int mode, int frames, DWORD *tests_out, DWORD *calls_out) {
    int f, i, rep;
    DWORD maxtests = 0;
    reset(nfx, ndoor);
    for (f = 0; f < frames; f++) {
        DWORD before = g_calls;
        g_frame += (mode == 1 && (rnd() & 31) == 0) ? 1 + (rnd() & 7) : 1;
        for (i = 0; i < (mode == 0 ? 40 : NOBJ); i++) {
            if (mode == 1 && (rnd() % 100) < 15) continue;          /* not drawn this frame */
            for (rep = (mode == 1 && (rnd() & 15) == 0) ? 2 : 1; rep > 0; rep--) call(&obj[i]);
        }
        if (f >= 64 && g_calls - before > maxtests) maxtests = g_calls - before;
    }
    if (P32(S_RUN) + P32(S_SKIP) != (DWORD)0 && tests_out) {
        DWORD t = 0, c = 0;
        for (i = 0; i < NOBJ; i++) { t += obj[i].tests; c += obj[i].calls; }
        if (t != P32(S_RUN) || c - t != P32(S_SKIP)) fail("counters disagree with the calls");
        *tests_out = t; *calls_out = c;
    }
    return maxtests;
}

int main(void) {
    static const DWORD ns[] = { 1, 2, 4, 8, 16 };
    int a, b, mode;
    load();
    make_objects();
    g_frame = 0xFFFFF000;                   /* wraps during the run */
    for (mode = 0; mode < 2; mode++)
        for (a = 0; a < 5; a++)
            for (b = 0; b < 3; b++) {
                DWORD tests = 0, calls = 0, mx = run(ns[a], ns[b], mode, 4000, &tests, &calls);
                if (mode == 0) {
                    /* Steady state: each fx object tests once every N frames, each door every Nd
                     * (objects that share a set with two others are pushed out and test more). */
                    int i, j;
                    for (i = 0; i < 40; i++) {
                        DWORD n = obj[i].door ? ns[b] : ns[a];
                        DWORD want = 4000 / n, share = 0;
                        for (j = 0; j < 40; j++) if (set_of(obj[j].addr) == set_of(obj[i].addr)) share++;
                        if (share > 2) continue;
                        if (obj[i].tests + 2 < want || obj[i].tests > want + 2) {
                            printf("object %d (n %lu): %lu tests in 4000 frames, want %lu\n", i, n, obj[i].tests, want);
                            fail("wrong test rate");
                        }
                    }
                }
                printf("mode %d N_FX %2lu N_DOOR %lu: %6lu of %6lu calls tested, at most %2lu tests on a frame\n",
                       mode, ns[a], ns[b], tests, calls, mx);
            }
    printf("OK\n");
    ExitProcess(0);
    return 0;
}
