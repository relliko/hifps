; hifps occlusion by the zone's walls (the 'walls' toggle).
; The client's test for whether a character is hidden (thiscall on the actor's test object at
; actor+0x8F0, 9 stack arguments, ret 24h; 0 = hidden) draws the character's screen box against the
; scene's depth and reads the result back from the GPU, which waits for the GPU to finish the frame so
; far: about 40% of the main thread in a 2026-10-21 profile. The actor draw's call of it is pointed at
; ENTRY here, which answers from the zone's collision instead, with the game's own segment test (the
; one the camera keeps itself out of walls with: thiscall on the world renderer, (from, to, hit out),
; ret 0Ch, al = 1 when collision lies on the segment). Nothing waits on the GPU.
;
; The box (argument 1) is { x0, y0, x1, y1 } in viewport pixels and argument 2 the NDC depth a quarter
; of the way in from its near face (both made by the actor update, 0C63D0); arguments 3 and 4 are the
; viewport's width and height as floats. Up to NPOINTS points of a 3 x 3 grid over the box (the middle,
; then the middle of the top, the sides and the bottom, then the corners) are put back into the world
; at that depth, with the camera's view (gGame+94h) and projection (gGame+154h). The first point with a
; clear segment from the camera's eye answers 256 (shown); 0 (hidden) only when every one is blocked.
; Shown without a segment: the actors in KEEP_A and KEEP_B (the player and the target), boxes nearer
; than MIN_DIST or farther than MAX_DIST, a point too near the eye or numbers that make no sense
; there. Once a frame's segments have taken BUDGET QueryPerformanceCounter ticks, the rest of the
; frame's tests answer shown. The client's own test runs (fallback) while USE_STOCK is set (hifps
; sets it in cutscenes, whose cameras can sit inside walls), when no collision is loaded, or when the
; camera or the box make no sense.
; Everything is one section: code and data. hifps copies it into its own memory and adds the block's
; base to every DIR32 relocation, then fills in ORIG_TEST, SEG_TEST, RENDERER, GRID_OFF, GAME, QPC,
; BUDGET, and every frame the KEEP actors and USE_STOCK.
.686
.xmm
.model flat
option casemap:none

PUBLIC ORIG_TEST, SEG_TEST, RENDERER, GRID_OFF, GAME, QPC, BUDGET, NPOINTS, MIN_DIST, MAX_DIST
PUBLIC KEEP_A, KEEP_B, USE_STOCK, S_TESTS, S_SEGS, S_HIDDEN, S_SHOWN, S_OVER, S_FALLBACK, S_TICKS, ENTRY

; gGame's fields (hifps checks them against the client's own getters)
G_FRAME     equ 34h             ; frame count
G_VIEW      equ 94h             ; view matrix (row vectors)
G_PROJ      equ 154h            ; projection: _11 +0, _22 +14h, _33 +28h, _43 +38h

; locals (ebp-relative)
L_T0        equ -8              ; QueryPerformanceCounter at the start (int64)
L_T1        equ -16             ; and at the end
L_X0        equ -20             ; the box, sorted
L_Y0        equ -24
L_X1        equ -28
L_Y1        equ -32
L_D         equ -36             ; view distance of the test depth
L_SX        equ -40             ; 2 / width
L_SY        equ -44             ; 2 / height
L_I11       equ -48             ; d / _11
L_I22       equ -52             ; d / _22
L_EYE       equ -64             ; the eye (world x, y, z)
L_FROM      equ -80             ; the segment's ends (x, y, z)
L_TO        equ -96
L_OUT       equ -112            ; where the test puts its hit
L_K         equ -116            ; point
L_P         equ -128            ; the point (world x, y, z)
L_SIZE      equ 128

.code

; ---------------------------------------------------------------- data
align 4
ORIG_TEST   dd 0                ; the client's test
SEG_TEST    dd 0                ; the segment test (world renderer)
RENDERER    dd 0                ; the global holding the world renderer
GRID_OFF    dd 0                ; renderer field that is 0 while no collision is loaded
GAME        dd 0                ; the global holding gGame
QPC         dd 0                ; kernel32 QueryPerformanceCounter (0: no timing, no budget)
BUDGET      dd 0                ; ticks of segments a frame (0: no limit)
NPOINTS     dd 9                ; points tried before a box counts as hidden (1-9)
MIN_DIST    REAL4 1.0           ; yalms
MAX_DIST    REAL4 100.0
KEEP_A      dd 0                ; actors always shown
KEEP_B      dd 0
USE_STOCK   dd 0                ; non-zero: the client's own test
S_TESTS     dd 0                ; calls
S_SEGS      dd 0                ; segments tested
S_HIDDEN    dd 0                ; answered hidden
S_SHOWN     dd 0                ; answered shown without a clear segment (kept, near, far, odd numbers)
S_OVER      dd 0                ; answered shown, the frame's budget spent
S_FALLBACK  dd 0                ; the client's test run
S_TICKS     dd 0                ; ticks spent (low 32 bits)
LAST_FRAME  dd 0
SPENT       dd 0                ; ticks spent this frame
; The points, as fractions of the box (screen y down: the top is the head).
PX          REAL4 0.5, 0.5, 0.16666667, 0.83333333, 0.5, 0.16666667, 0.83333333, 0.16666667, 0.83333333
PY          REAL4 0.5, 0.16666667, 0.5, 0.5, 0.83333333, 0.16666667, 0.16666667, 0.83333333, 0.83333333
F_ONE       REAL4 1.0
F_SIZE_MAX  REAL4 65536.0
F_RECT_MAX  REAL4 1.0e6
F_WORLD_MAX REAL4 1.0e5
F_PROJ_MIN  REAL4 0.01
F_DEN_MAX   REAL4 -1.0e-7       ; z + _33 must be below this (else the depth is at the far plane)
F_FROM_OFF  REAL4 0.1           ; the segment starts this far off the point (a surface through it isn't a hit)
F_TO_OFF    REAL4 0.3           ; and ends this far short of the eye

; ---------------------------------------------------------------- helpers
; xmm0, xmm1, xmm2 = a view-space point; edi = gGame; writes the world point to [edx].
; w_j = sum_i (v_i - t_i) R[j][i], R[j][i] at view + 4 (4j + i), t_i at view + 48 + 4i.
to_world:
    subss   xmm0, dword ptr [edi + G_VIEW + 48]
    subss   xmm1, dword ptr [edi + G_VIEW + 52]
    subss   xmm2, dword ptr [edi + G_VIEW + 56]
    movss   xmm3, dword ptr [edi + G_VIEW + 0]
    mulss   xmm3, xmm0
    movss   xmm4, dword ptr [edi + G_VIEW + 4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, dword ptr [edi + G_VIEW + 8]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   dword ptr [edx], xmm3
    movss   xmm3, dword ptr [edi + G_VIEW + 16]
    mulss   xmm3, xmm0
    movss   xmm4, dword ptr [edi + G_VIEW + 20]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, dword ptr [edi + G_VIEW + 24]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   dword ptr [edx + 4], xmm3
    movss   xmm3, dword ptr [edi + G_VIEW + 32]
    mulss   xmm3, xmm0
    movss   xmm4, dword ptr [edi + G_VIEW + 36]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, dword ptr [edi + G_VIEW + 40]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   dword ptr [edx + 8], xmm3
    ret

; ecx floats at [edx], each a number with |v| < xmm7: eax = 0, else eax = 1. Changes xmm0, xmm6, ecx, edx.
check_n:
    xorps   xmm6, xmm6
    subss   xmm6, xmm7
cn_next:
    movss   xmm0, dword ptr [edx]
    comiss  xmm0, xmm7
    jp      cn_bad                      ; NaN
    jae     cn_bad
    comiss  xmm0, xmm6
    jbe     cn_bad
    add     edx, 4
    dec     ecx
    jnz     cn_next
    xor     eax, eax
    ret
cn_bad:
    mov     eax, 1
    ret

; ---------------------------------------------------------------- the test
; ecx = the test object, 9 arguments on the stack ([ebp+8] the box, [ebp+12] the depth, [ebp+16] and
; [ebp+20] the viewport size), ret 24h, result in eax.
ENTRY:
    push    ebp
    mov     ebp, esp
    sub     esp, L_SIZE
    push    ebx
    push    esi
    push    edi
    mov     esi, ecx
    inc     dword ptr [S_TESTS]
    lea     eax, [esi - 8F0h]           ; the actor
    cmp     eax, dword ptr [KEEP_A]
    je      shown
    cmp     eax, dword ptr [KEEP_B]
    je      shown
    cmp     dword ptr [USE_STOCK], 0
    jne     fallback
    ; The zone's collision and the camera.
    mov     eax, dword ptr [RENDERER]
    mov     ebx, dword ptr [eax]
    test    ebx, ebx
    jz      fallback
    mov     eax, dword ptr [GRID_OFF]
    cmp     dword ptr [ebx + eax], 0
    je      fallback
    mov     eax, dword ptr [GAME]
    mov     edi, dword ptr [eax]
    test    edi, edi
    jz      fallback
    ; The frame's budget.
    mov     eax, dword ptr [edi + G_FRAME]
    cmp     eax, dword ptr [LAST_FRAME]
    je      @F
    mov     dword ptr [LAST_FRAME], eax
    mov     dword ptr [SPENT], 0
@@:
    mov     eax, dword ptr [BUDGET]
    test    eax, eax
    jz      @F
    cmp     dword ptr [SPENT], eax
    jae     over
@@:
    ; The box, sorted, and the viewport size.
    mov     eax, dword ptr [ebp + 8]
    test    eax, eax
    jz      fallback
    movss   xmm0, dword ptr [eax]
    movss   xmm1, dword ptr [eax + 4]
    movss   xmm2, dword ptr [eax + 8]
    movss   xmm3, dword ptr [eax + 12]
    movss   xmm4, xmm0
    minss   xmm0, xmm2
    maxss   xmm2, xmm4
    movss   xmm4, xmm1
    minss   xmm1, xmm3
    maxss   xmm3, xmm4
    movss   dword ptr [ebp + L_X0], xmm0
    movss   dword ptr [ebp + L_Y0], xmm1
    movss   dword ptr [ebp + L_X1], xmm2
    movss   dword ptr [ebp + L_Y1], xmm3
    movss   xmm7, dword ptr [F_RECT_MAX]
    lea     edx, [ebp + L_Y1]
    mov     ecx, 4
    call    check_n
    test    eax, eax
    jnz     fallback
    ; minss/maxss pass a NaN through either way: check the box's corners as given too.
    mov     edx, dword ptr [ebp + 8]
    mov     ecx, 4
    call    check_n
    test    eax, eax
    jnz     fallback
    movss   xmm1, dword ptr [ebp + 16]  ; width
    movss   xmm2, dword ptr [ebp + 20]  ; height
    comiss  xmm1, dword ptr [F_ONE]
    jp      fallback
    jb      fallback
    comiss  xmm1, dword ptr [F_SIZE_MAX]
    ja      fallback
    comiss  xmm2, dword ptr [F_ONE]
    jp      fallback
    jb      fallback
    comiss  xmm2, dword ptr [F_SIZE_MAX]
    ja      fallback
    movss   xmm0, dword ptr [F_ONE]
    addss   xmm0, xmm0
    movss   xmm3, xmm0
    divss   xmm0, xmm1
    movss   dword ptr [ebp + L_SX], xmm0
    divss   xmm3, xmm2
    movss   dword ptr [ebp + L_SY], xmm3
    ; The projection: _11 and _22 must be usable, and d = _43 / (z + _33).
    movss   xmm0, dword ptr [edi + G_PROJ + 0]
    comiss  xmm0, dword ptr [F_PROJ_MIN]
    jp      fallback
    jb      fallback
    movss   xmm0, dword ptr [edi + G_PROJ + 14h]
    comiss  xmm0, dword ptr [F_PROJ_MIN]
    jp      fallback
    jb      fallback
    movss   xmm0, dword ptr [ebp + 12]  ; the depth
    ucomiss xmm0, xmm0
    jp      fallback
    addss   xmm0, dword ptr [edi + G_PROJ + 28h]
    comiss  xmm0, dword ptr [F_DEN_MAX]
    jp      fallback
    jae     far_shown                   ; at or past the far plane
    movss   xmm1, dword ptr [edi + G_PROJ + 38h]
    divss   xmm1, xmm0
    ucomiss xmm1, xmm1
    jp      fallback
    comiss  xmm1, dword ptr [MIN_DIST]
    jb      shown                       ; nearer than MIN_DIST (or behind the eye)
    comiss  xmm1, dword ptr [MAX_DIST]
    ja      far_shown
    movss   dword ptr [ebp + L_D], xmm1
    movss   xmm0, xmm1
    divss   xmm0, dword ptr [edi + G_PROJ + 0]
    movss   dword ptr [ebp + L_I11], xmm0
    divss   xmm1, dword ptr [edi + G_PROJ + 14h]
    movss   dword ptr [ebp + L_I22], xmm1
    ; The eye: the view's origin in the world.
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    lea     edx, [ebp + L_EYE]
    call    to_world
    movss   xmm7, dword ptr [F_WORLD_MAX]
    lea     edx, [ebp + L_EYE]
    mov     ecx, 3
    call    check_n
    test    eax, eax
    jnz     fallback
    ; The segments.
    mov     eax, dword ptr [QPC]
    test    eax, eax
    jz      @F
    lea     ecx, [ebp + L_T0]
    push    ecx
    call    eax
@@:
    mov     dword ptr [ebp + L_K], 0
next_point:
    mov     eax, dword ptr [ebp + L_K]
    cmp     eax, dword ptr [NPOINTS]
    jae     blocked
    cmp     eax, 9
    jae     blocked
    ; Where it is on the screen, in NDC, in view space, in the world.
    movss   xmm0, dword ptr [ebp + L_X1]
    subss   xmm0, dword ptr [ebp + L_X0]
    mulss   xmm0, dword ptr [PX + eax * 4]
    addss   xmm0, dword ptr [ebp + L_X0]
    movss   xmm1, dword ptr [ebp + L_Y1]
    subss   xmm1, dword ptr [ebp + L_Y0]
    mulss   xmm1, dword ptr [PY + eax * 4]
    addss   xmm1, dword ptr [ebp + L_Y0]
    mulss   xmm0, dword ptr [ebp + L_SX]
    subss   xmm0, dword ptr [F_ONE]     ; x / (w / 2) - 1
    mulss   xmm1, dword ptr [ebp + L_SY]
    movss   xmm2, dword ptr [F_ONE]
    subss   xmm2, xmm1
    movss   xmm1, xmm2                  ; 1 - y / (h / 2)
    mulss   xmm0, dword ptr [ebp + L_I11]
    mulss   xmm1, dword ptr [ebp + L_I22]
    xorps   xmm2, xmm2
    subss   xmm2, dword ptr [ebp + L_D] ; -d
    lea     edx, [ebp + L_P]
    call    to_world
    ; u = the way to the eye, l its length.
    movss   xmm0, dword ptr [ebp + L_EYE]
    subss   xmm0, dword ptr [ebp + L_P]
    movss   xmm1, dword ptr [ebp + L_EYE + 4]
    subss   xmm1, dword ptr [ebp + L_P + 4]
    movss   xmm2, dword ptr [ebp + L_EYE + 8]
    subss   xmm2, dword ptr [ebp + L_P + 8]
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3
    comiss  xmm3, dword ptr [F_ONE]
    jp      odd                         ; NaN
    jb      odd                         ; within a yalm of the eye
    movss   xmm4, dword ptr [F_ONE]
    divss   xmm4, xmm3
    mulss   xmm0, xmm4
    mulss   xmm1, xmm4
    mulss   xmm2, xmm4
    ; from = p + 0.1 u, to = eye - 0.3 u
    movss   xmm5, dword ptr [F_FROM_OFF]
    movss   xmm3, xmm0
    mulss   xmm3, xmm5
    addss   xmm3, dword ptr [ebp + L_P]
    movss   dword ptr [ebp + L_FROM], xmm3
    movss   xmm3, xmm1
    mulss   xmm3, xmm5
    addss   xmm3, dword ptr [ebp + L_P + 4]
    movss   dword ptr [ebp + L_FROM + 4], xmm3
    movss   xmm3, xmm2
    mulss   xmm3, xmm5
    addss   xmm3, dword ptr [ebp + L_P + 8]
    movss   dword ptr [ebp + L_FROM + 8], xmm3
    movss   xmm5, dword ptr [F_TO_OFF]
    mulss   xmm0, xmm5
    movss   xmm3, dword ptr [ebp + L_EYE]
    subss   xmm3, xmm0
    movss   dword ptr [ebp + L_TO], xmm3
    mulss   xmm1, xmm5
    movss   xmm3, dword ptr [ebp + L_EYE + 4]
    subss   xmm3, xmm1
    movss   dword ptr [ebp + L_TO + 4], xmm3
    mulss   xmm2, xmm5
    movss   xmm3, dword ptr [ebp + L_EYE + 8]
    subss   xmm3, xmm2
    movss   dword ptr [ebp + L_TO + 8], xmm3
    movss   xmm7, dword ptr [F_WORLD_MAX]
    lea     edx, [ebp + L_FROM]
    mov     ecx, 3
    call    check_n
    test    eax, eax
    jnz     odd
    ; The game's test (ebx and edi come back as they were).
    lea     eax, [ebp + L_OUT]
    push    eax
    lea     eax, [ebp + L_TO]
    push    eax
    lea     eax, [ebp + L_FROM]
    push    eax
    mov     ecx, ebx
    call    dword ptr [SEG_TEST]
    inc     dword ptr [S_SEGS]
    test    al, al
    jz      clear
    inc     dword ptr [ebp + L_K]
    jmp     next_point

odd:                                    ; numbers that make no sense: shown
    inc     dword ptr [S_SHOWN]
clear:
    mov     esi, 256
    jmp     timed
blocked:
    inc     dword ptr [S_HIDDEN]
    xor     esi, esi
timed:
    mov     eax, dword ptr [QPC]
    test    eax, eax
    jz      @F
    lea     ecx, [ebp + L_T1]
    push    ecx
    call    eax
    mov     eax, dword ptr [ebp + L_T1]
    sub     eax, dword ptr [ebp + L_T0]
    add     dword ptr [SPENT], eax
    add     dword ptr [S_TICKS], eax
@@:
    mov     eax, esi
    jmp     done

over:
    inc     dword ptr [S_OVER]
    mov     eax, 256
    jmp     done
far_shown:
shown:
    inc     dword ptr [S_SHOWN]
    mov     eax, 256
    jmp     done

fallback:
    inc     dword ptr [S_FALLBACK]
    push    dword ptr [ebp + 40]        ; the arguments, last first
    push    dword ptr [ebp + 36]
    push    dword ptr [ebp + 32]
    push    dword ptr [ebp + 28]
    push    dword ptr [ebp + 24]
    push    dword ptr [ebp + 20]
    push    dword ptr [ebp + 16]
    push    dword ptr [ebp + 12]
    push    dword ptr [ebp + 8]
    mov     ecx, esi
    call    dword ptr [ORIG_TEST]
done:
    pop     edi
    pop     esi
    pop     ebx
    mov     esp, ebp
    pop     ebp
    ret     24h

end
