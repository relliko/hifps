/* Runs the exact gfx.asm bytes (gfx.blob) against fakes of what the client calls.
 *
 *   VSC_LAMP     called as 'call [ecx+13Ch]' with ecx = a fake vtable: the fake SetVertexShaderConstant
 *                must get a copy with c15-c17 x BRIGHT and c18 x REACH^2 (other uploads untouched).
 *   LIGHT_LAMPn  called as the SetLight wrapper (thiscall, index and light, ret 8): the fake must get
 *                the renderer in ecx and, for a point light, a copy with diffuse x BRIGHT, range x
 *                REACH, attenuation 1 / REACH and 2 / REACH^2; other lights and NULL unchanged.
 *   ACTOR_LAMP   called as vec3 *= float (cdecl): the fake must get the weight x BRIGHT.
 *   LIGHT_HOOK   called as the light builder (thiscall, out light and kind, ret 8): runs the copied
 *                first instructions and jumps to a fake rest of the builder, which checks the stack it
 *                gets and fills the light; then diffuse r, g, b x MOONF, the rest as the builder left it.
 *   AMB_HOOK     the same for the ambient builder (the copy loads eax = [ecx-1Ch]); then the colour's
 *                blue, green and red x AMBF, rounded, at most 255; alpha kept.
 * Each also: the caller's own data unchanged, ebx/esi/edi/ebp and the stack pointer kept, the fake's
 * return value returned, and factors of 1 giving the client's exact values.
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
static int checks;
static void check(int ok, const char *what) { checks++; if (!ok) fail(what); }

/* ---------------------------------------------------------------- the stub */
enum { BRIGHT, REACH, REACH2, INV_REACH, INV_REACH2, ORIG_SETLIGHT, ORIG_SCALE, S_VSC, S_LIGHT, S_ACTOR,
       VSC_LAMP, LIGHT_LAMP1, LIGHT_LAMP2, LIGHT_LAMP3, LIGHT_LAMP4, ACTOR_LAMP,
       MOONF, AMBF, LIGHT_CONT, AMB_CONT, S_MOON, S_AMB, LIGHT_HOOK, AMB_HOOK, NSYM };
static unsigned char *base;
static DWORD sym[NSYM];
#define P32(i) (*(DWORD *)(base + sym[i]))
#define PF(i) (*(float *)(base + sym[i]))
#define ADDR(i) ((DWORD)base + sym[i])

static void load(void) {
    static unsigned char blob[65536];
    DWORD n = 0, i, size, nrel, nsym, *h;
    HANDLE f = CreateFileA("gfx.blob", 0x80000000, 1, 0, 3, 0, 0);
    if (f == (HANDLE)-1 || !ReadFile(f, blob, sizeof blob, &n, 0) || n < 12) fail("cannot read gfx.blob");
    h = (DWORD *)blob; size = h[0]; nrel = h[1]; nsym = h[2];
    if (nsym != NSYM) fail("symbol count");
    base = VirtualAlloc(0, size, 0x3000, 0x40);
    if (!base) fail("VirtualAlloc");
    for (i = 0; i < size; i++) base[i] = blob[12 + 4 * (nrel + nsym) + i];
    for (i = 0; i < nrel; i++) *(DWORD *)(base + h[3 + i]) += (DWORD)base;
    for (i = 0; i < nsym; i++) sym[i] = h[3 + nrel + i];
}

/* ---------------------------------------------------------------- fakes */
static DWORD seed = 777;
static DWORD rnd(void) { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed; }
static float rndf(void) { return (float)(rnd() % 100000) / 10000.0f; }

/* SetVertexShaderConstant(this, reg, data, count), stdcall, reached through vtable slot 79. */
static DWORD v_dev, v_reg, v_cnt, v_calls; static float v_data[16]; static const float *v_ptr;
static long __stdcall fake_vsc(DWORD dev, DWORD reg, const float *data, DWORD cnt) {
    int i;
    v_calls++; v_dev = dev; v_reg = reg; v_cnt = cnt; v_ptr = data;
    for (i = 0; i < 16; i++) v_data[i] = data[i];
    return 0x1234;
}
static void *vtable[128];

/* SetLight wrapper: thiscall (index, light), ret 8. */
typedef struct { DWORD type; float diffuse[4], specular[4], ambient[4], pos[3], dir[3], range, falloff, att0, att1, att2, theta, phi; } Light;
static DWORD l_this, l_index, l_calls; static Light l_got; static const Light *l_ptr;
static long __stdcall light_body(DWORD self, DWORD index, const Light *l) {
    l_calls++; l_this = self; l_index = index; l_ptr = l;
    if (l) l_got = *l;
    return 0x5678;
}
__declspec(naked) static void fake_setlight(void) {
    __asm {
        push    dword ptr [esp + 8]
        push    dword ptr [esp + 8]
        push    ecx
        call    light_body
        ret     8
    }
}

/* vec3 *= float, cdecl. */
static DWORD s_calls; static float s_w; static float *s_vec;
static void __cdecl fake_scale(float *v, float w) { s_calls++; s_vec = v; s_w = w; v[0] *= w; v[1] *= w; v[2] *= w; }

/* The rest of the light builder, reached from LIGHT_TRAMP after 'sub esp, 30h; push ebx; push esi':
 * [esp] esi, [esp+4] ebx (the caller's), 30h of locals, [esp+38h] return, [esp+3Ch] out, [esp+40h] kind. */
static DWORD fl_env, fl_out, fl_kind, fl_calls, fl_stackbad;
static float fl_vals[2][3];
static void __stdcall light_fill(DWORD env, Light *out, DWORD kind) {
    fl_calls++; fl_env = env; fl_out = (DWORD)out; fl_kind = kind;
    memset(out, 0, sizeof *out);
    out->type = 3;
    out->diffuse[0] = fl_vals[kind & 1][0]; out->diffuse[1] = fl_vals[kind & 1][1]; out->diffuse[2] = fl_vals[kind & 1][2];
    out->diffuse[3] = 1.0f; out->ambient[0] = 0.25f; out->dir[0] = -0.5f; out->dir[1] = 0.75f;
}
__declspec(naked) static void fake_light_rest(void) {
    __asm {
        cmp     dword ptr [esp], 22222222h
        jne     lr_bad
        cmp     dword ptr [esp + 4], 11111111h
        je      lr_go
    lr_bad:
        mov     fl_stackbad, 1
    lr_go:
        mov     ebx, 0BADBADh               ; the builder may use them; they come back from the stack
        mov     esi, 0BADBADh
        push    dword ptr [esp + 40h]       ; kind
        push    dword ptr [esp + 40h]       ; out
        push    ecx                         ; environment
        call    light_fill
        mov     eax, 0FACEFEEDh
        pop     esi
        pop     ebx
        add     esp, 30h
        ret     8
    }
}

/* The rest of the ambient builder, reached from AMB_TRAMP after 'mov eax, [ecx-1Ch]; sub esp, 20h':
 * 20h of locals, [esp+20h] return, [esp+24h] out, [esp+28h] kind. */
static DWORD fa_env, fa_out, fa_kind, fa_calls, fa_eax, fa_color[2];
static void __stdcall amb_fill(DWORD env, DWORD *out, DWORD kind, DWORD eaxv) {
    fa_calls++; fa_env = env; fa_out = (DWORD)out; fa_kind = kind; fa_eax = eaxv;
    *out = fa_color[kind & 1];
}
__declspec(naked) static void fake_amb_rest(void) {
    __asm {
        push    eax
        push    dword ptr [esp + 2Ch]       ; kind
        push    dword ptr [esp + 2Ch]       ; out
        push    ecx
        call    amb_fill
        mov     eax, 0FACEFEEDh
        add     esp, 20h
        ret     8
    }
}
/* x87 fistp's default: round to nearest, ties to even. */
static long round_even(double v) {
    long f = (long)v;                       /* v >= 0 */
    double d = v - (double)f;
    if (d > 0.5 || (d == 0.5 && (f & 1))) f++;
    return f;
}

/* Calls an entry with 4 dwords on the stack (callee pops 'pops' bytes), ecx given, known values in the
 * registers the caller keeps. */
static DWORD c_entry, c_ecx, c_args[4], c_ret, c_bad, c_esp0, c_esp1, c_pops;
__declspec(naked) static void do_call(void) {
    __asm {
        pushad
        mov     c_esp0, esp
        push    dword ptr [c_args + 12]
        push    dword ptr [c_args + 8]
        push    dword ptr [c_args + 4]
        push    dword ptr [c_args]
        mov     ecx, c_ecx
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
        add     esp, c_pops                 ; what the callee left (cdecl: all 16 bytes)
        mov     c_esp1, esp
        popad
        ret
    }
}
static void call4(DWORD entry, DWORD ecx, DWORD a0, DWORD a1, DWORD a2, DWORD a3, DWORD left) {
    c_entry = entry; c_ecx = ecx; c_args[0] = a0; c_args[1] = a1; c_args[2] = a2; c_args[3] = a3;
    c_pops = left; c_bad = 0;
    do_call();
    check(!c_bad, "a register the caller keeps was changed");
    check(c_esp0 == c_esp1, "stack pointer changed");
}

static void set_factors(float b, float r) {
    PF(BRIGHT) = b; PF(REACH) = r; PF(REACH2) = r * r; PF(INV_REACH) = 1.0f / r; PF(INV_REACH2) = 1.0f / (r * r);
}

int main(void) {
    static const float factors[][2] = { { 1.0f, 1.0f }, { 1.5f, 1.0f }, { 2.0f, 1.25f }, { 0.75f, 1.5f }, { 3.0f, 2.0f } };
    int k, i, rep;
    load();
    vtable[79] = (void *)fake_vsc;
    P32(ORIG_SETLIGHT) = (DWORD)fake_setlight;
    P32(ORIG_SCALE) = (DWORD)fake_scale;

    for (k = 0; k < 5; k++) {
        float b = factors[k][0], r = factors[k][1];
        set_factors(b, r);
        for (rep = 0; rep < 200; rep++) {
            /* ---- VSC_LAMP: the lamp upload */
            float data[16], keep[16];
            Light l, lk;
            float vec[3], w;
            const Light *site_copy[4];
            DWORD before;
            for (i = 0; i < 16; i++) keep[i] = data[i] = rndf();
            before = v_calls;
            call4(ADDR(VSC_LAMP), (DWORD)vtable, 0xDE71CE, 15, (DWORD)data, 4, 0);
            check(v_calls == before + 1 && c_ret == 0x1234, "vsc: the device method ran once, its result returned");
            check(v_dev == 0xDE71CE && v_reg == 15 && v_cnt == 4, "vsc: device, register and count passed");
            for (i = 0; i < 16; i++) check(data[i] == keep[i], "vsc: the client's constants unchanged");
            for (i = 0; i < 12; i++) check(v_data[i] == keep[i] * b, "vsc: lamp colour x BRIGHT");
            for (i = 12; i < 16; i++) check(v_data[i] == keep[i] * (r * r), "vsc: range^2 x REACH^2");
            if (b == 1.0f && r == 1.0f) for (i = 0; i < 16; i++) check(v_data[i] == keep[i], "vsc: factors of 1 give the client's values");
            /* any other upload passes through as is */
            call4(ADDR(VSC_LAMP), (DWORD)vtable, 0xDE71CE, 11, (DWORD)data, 3, 0);
            check(v_ptr == data && v_reg == 11 && v_cnt == 3, "vsc: other uploads untouched");

            /* ---- LIGHT_LAMPn: a point light, then a directional one, then NULL */
            for (i = 0; i < 4; i++) {
                DWORD e = ADDR(LIGHT_LAMP1 + i);
                memset(&l, 0, sizeof l);
                l.type = 1;
                l.diffuse[0] = rndf(); l.diffuse[1] = rndf(); l.diffuse[2] = rndf(); l.diffuse[3] = rndf();
                l.specular[0] = rndf(); l.ambient[1] = rndf(); l.pos[0] = rndf(); l.pos[2] = rndf();
                l.range = rndf() + 1.0f; l.att0 = rndf(); l.att1 = rndf(); l.att2 = rndf() + 0.1f; l.falloff = rndf();
                lk = l;
                before = l_calls;
                call4(e, 0x5E4DE4E8, 1 + i, (DWORD)&l, 0xAAAA, 0xBBBB, 8);
                check(l_calls == before + 1 && c_ret == 0x5678, "light: the wrapper ran once, its result returned");
                check(l_this == 0x5E4DE4E8 && l_index == (DWORD)(1 + i), "light: renderer in ecx and the index passed");
                check(l.diffuse[0] == lk.diffuse[0] && l.range == lk.range && l.att2 == lk.att2, "light: the client's light unchanged");
                check(l_ptr != &l, "light: a copy was passed");
                check(l_got.diffuse[0] == lk.diffuse[0] * b && l_got.diffuse[1] == lk.diffuse[1] * b && l_got.diffuse[2] == lk.diffuse[2] * b,
                      "light: diffuse x BRIGHT");
                check(l_got.diffuse[3] == lk.diffuse[3] && l_got.specular[0] == lk.specular[0] && l_got.ambient[1] == lk.ambient[1]
                      && l_got.pos[0] == lk.pos[0] && l_got.pos[2] == lk.pos[2] && l_got.att0 == lk.att0 && l_got.falloff == lk.falloff,
                      "light: everything else copied as is");
                check(l_got.range == lk.range * r, "light: range x REACH");
                check(l_got.att1 == lk.att1 * (1.0f / r) && l_got.att2 == lk.att2 * (1.0f / (r * r)), "light: attenuation stretched");
                if (b == 1.0f && r == 1.0f) check(l_got.diffuse[0] == lk.diffuse[0] && l_got.range == lk.range && l_got.att1 == lk.att1 && l_got.att2 == lk.att2,
                                                  "light: factors of 1 give the client's values");
                /* the copies are per call site */
                site_copy[i] = l_ptr;
                if (i == 3) check(site_copy[0] != site_copy[1] && site_copy[1] != site_copy[2] && site_copy[2] != site_copy[3]
                                  && site_copy[0] != site_copy[3], "light: each call site has its own copy");
                l.type = 3;
                call4(e, 0x5E4DE4E8, 1 + i, (DWORD)&l, 0, 0, 8);
                check(l_ptr == &l, "light: a directional light passes as is");
                call4(e, 0x5E4DE4E8, 1 + i, 0, 0, 0, 8);
                check(l_ptr == 0, "light: NULL passes as is");
            }

            /* ---- ACTOR_LAMP: cdecl, the caller pops */
            vec[0] = rndf(); vec[1] = rndf(); vec[2] = rndf();
            w = rndf();
            before = s_calls;
            call4(ADDR(ACTOR_LAMP), 0, (DWORD)vec, *(DWORD *)&w, 0, 0, 16);
            check(s_calls == before + 1 && s_vec == vec, "actor: the scale ran once on the caller's vector");
            check(s_w == w * b, "actor: weight x BRIGHT");
        }
        printf("BRIGHT %d/100 REACH %d/100: ok\n", (int)(b * 100), (int)(r * 100));
    }
    check(P32(S_VSC) == 5 * 200 && P32(S_LIGHT) == 5 * 200 * 4 && P32(S_ACTOR) == 5 * 200, "counters");

    /* ---- the night hooks */
    {
        static const float night[][2] = { { 1.0f, 1.0f }, { 1.3f, 1.6f }, { 2.5f, 2.5f }, { 0.5f, 0.75f }, { 1.75f, 1.0f } };
        static DWORD envbuf[64];
        DWORD env = (DWORD)&envbuf[16];
        P32(LIGHT_CONT) = (DWORD)fake_light_rest;
        P32(AMB_CONT) = (DWORD)fake_amb_rest;
        for (k = 0; k < 5; k++) {
            float m = night[k][0], a = night[k][1];
            PF(MOONF) = m; PF(AMBF) = a;
            for (rep = 0; rep < 400; rep++) {
                Light lo;
                DWORD kind = rnd() & 1, col, o, before, j;
                envbuf[16 - 7] = 1 + (rnd() & 1);           /* [env-1Ch]: the builder's mode */
                for (i = 0; i < 3; i++) fl_vals[kind][i] = rndf() / 5.0f;
                before = fl_calls; fl_stackbad = 0;
                call4(ADDR(LIGHT_HOOK), env, (DWORD)&lo, kind, 0, 0, 8);
                check(fl_calls == before + 1 && !fl_stackbad, "light: the builder ran once with the caller's ebx/esi saved");
                check(fl_env == env && fl_out == (DWORD)&lo && fl_kind == kind, "light: environment, out and kind passed");
                check(c_ret == 0xFACEFEED, "light: the builder's eax returned");
                for (i = 0; i < 3; i++) check(lo.diffuse[i] == fl_vals[kind][i] * m, "light: diffuse x MOONF");
                check(lo.diffuse[3] == 1.0f && lo.type == 3 && lo.ambient[0] == 0.25f && lo.dir[0] == -0.5f && lo.dir[1] == 0.75f,
                      "light: everything else as the builder left it");

                col = rnd();
                fa_color[kind] = col;
                o = 0xDEADBEEF;
                before = fa_calls;
                call4(ADDR(AMB_HOOK), env, (DWORD)&o, kind, 0, 0, 8);
                check(fa_calls == before + 1 && fa_env == env && fa_out == (DWORD)&o && fa_kind == kind, "ambient: the builder ran once, args passed");
                check(fa_eax == envbuf[16 - 7], "ambient: the copied first instruction loaded eax = [ecx-1Ch]");
                check(c_ret == 0xFACEFEED, "ambient: the builder's eax returned");
                check((o >> 24) == (col >> 24), "ambient: alpha kept");
                for (j = 0; j < 3; j++) {
                    long want = round_even((double)((col >> (8 * j)) & 0xFF) * (double)a);
                    if (want > 255) want = 255;
                    check(((o >> (8 * j)) & 0xFF) == (DWORD)want, "ambient: colour byte x AMBF, rounded, at most 255");
                }
                if (a == 1.0f) check(o == col, "ambient: a factor of 1 gives the client's colour");
            }
            printf("MOONF %d/100 AMBF %d/100: ok\n", (int)(m * 100), (int)(a * 100));
        }
        check(P32(S_MOON) == 5 * 400 && P32(S_AMB) == 5 * 400, "night counters");
    }
    printf("OK: %d checks\n", checks);
    ExitProcess(0);
    return 0;
}
