; hifps visibility-test cache (the 'glows' toggle).
; The client's occlusion test (thiscall on a small test object, 9 stack arguments, ret 24h) draws a
; box against the scene's depth and reads the result back from the GPU, which stalls the frame. The
; actors' calls are throttled by the client itself (and by the 'occlusion' toggle); the glows, the lens
; flare and doors call it every frame. Each of those call sites is pointed at an entry here, which
; answers with the last result for the same test object until it is N frames old (N a power of two,
; set by hifps from the frame rate), and otherwise runs the test. A re-test also happens on the
; object's own phase frame ((frame + set) mod N == 0), so objects first seen on the same frame don't
; keep re-testing on the same frame. N = 1 runs every test, as stock.
; Table: 256 sets x 2 ways of { test object, frame tested, result, unused }.
; Everything is one section: code and data. hifps copies it into its own memory and adds the block's
; base to every DIR32 relocation. ORIG_TEST, GET_FRAME, N_FX, N_DOOR and TABLE (a zeroed block of
; NSETS * 32 bytes) are filled in by hifps.
.686
.model flat
option casemap:none

PUBLIC ORIG_TEST, GET_FRAME, N_FX, N_DOOR, S_RUN, S_SKIP, TABLE, ENTRY_FX, ENTRY_DOOR

NSETS equ 256

.code

; ---------------------------------------------------------------- data
align 4
ORIG_TEST   dd 0            ; the client's test
GET_FRAME   dd 0            ; the client's frame count getter (eax = count; nothing else changes)
N_FX        dd 1            ; frames a glow or lens flare result is kept
N_DOOR      dd 1            ; frames a door result is kept
S_RUN       dd 0            ; tests run
S_SKIP      dd 0            ; tests answered from the table
TABLE       dd 0            ; the table

; ---------------------------------------------------------------- entries
; Called in place of the test: ecx = test object, 9 arguments on the stack, ret 24h, result in eax.
ENTRY_FX:
    push    dword ptr [N_FX]
    jmp     common
ENTRY_DOOR:
    push    dword ptr [N_DOOR]
common:
    push    ebx
    push    esi
    push    edi
    ; [esp] edi, [esp+4] esi, [esp+8] ebx, [esp+12] N, [esp+16] return address, [esp+20] arguments
    mov     esi, ecx
    call    dword ptr [GET_FRAME]
    mov     edi, eax                    ; frame
    mov     ebx, esi
    imul    ebx, ebx, -1640531535       ; 9E3779B1h
    shr     ebx, 24                     ; set
    mov     ecx, ebx                    ; the object's phase
    shl     ebx, 5
    add     ebx, dword ptr [TABLE]
    cmp     dword ptr [ebx], esi
    je      found
    cmp     dword ptr [ebx + 16], esi
    je      found1
    ; Not in the table: take the way tested longer ago (an empty one says frame 0).
    mov     eax, edi
    sub     eax, dword ptr [ebx + 4]
    mov     edx, edi
    sub     edx, dword ptr [ebx + 20]
    cmp     eax, edx
    jae     run
    add     ebx, 16
    jmp     run
found1:
    add     ebx, 16
found:
    mov     edx, dword ptr [esp + 12]   ; N
    mov     eax, edi
    sub     eax, dword ptr [ebx + 4]    ; frames since its last test
    cmp     eax, edx
    jae     run
    dec     edx
    lea     eax, [edi + ecx]
    test    eax, edx
    jz      run                         ; its phase frame
    inc     dword ptr [S_SKIP]
    mov     eax, dword ptr [ebx + 8]
    pop     edi
    pop     esi
    pop     ebx
    add     esp, 4
    ret     24h
run:
    rept 9
    push    dword ptr [esp + 52]        ; the arguments, last first
    endm
    mov     ecx, esi
    call    dword ptr [ORIG_TEST]
    mov     dword ptr [ebx], esi
    mov     dword ptr [ebx + 4], edi
    mov     dword ptr [ebx + 8], eax
    inc     dword ptr [S_RUN]
    pop     edi
    pop     esi
    pop     ebx
    add     esp, 4
    ret     24h

end
