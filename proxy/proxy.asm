; hifps device proxy: a replacement vtable for the client's IDirect3DDevice8 object.
;   dedupe: drop Set* calls that set the value already in effect
;   batch:  merge consecutive DrawPrimitiveUP(TRIANGLESTRIP, 2) quads into one TRIANGLELIST draw
; The proxy keeps a shadow of the state the client set. Anything that can change device state behind
; it (BeginScene/EndScene/Present run Ashita's plugins and GUI; Reset; state blocks) clears the
; shadow, so it only ever skips a call when the device provably has that value already.
; Everything is one section: code and data. hifps copies it into its own memory and adds the block's
; base to every DIR32 relocation. ORIG/VTABLE/D_BUF are filled in by hifps.
.686
.model flat
option casemap:none

PUBLIC D_PENDING, D_PBYTES, D_STRIDE, D_PDEV, D_BUF, D_BUFSIZE
PUBLIC F_BATCH, F_DEDUPE, F_REC
PUBLIC S_SKIPPED, S_MERGED, S_BATCHES
PUBLIC ORIG, VT_RTTI, VTABLE, THUNK_TABLE, VALID_START, VALID_END, FLUSH

NSLOTS equ 128

.code

; ---------------------------------------------------------------- data
align 4
D_PENDING   dd 0            ; quads waiting in the buffer
D_PBYTES    dd 0            ; bytes used in the buffer
D_STRIDE    dd 0            ; vertex stride of the pending quads
D_PDEV      dd 0            ; device the pending quads were drawn on
D_BUF       dd 0            ; vertex buffer (set by hifps)
D_BUFSIZE   dd 0            ; its size in bytes
S_SKIPPED   dd 0            ; Set* calls dropped
S_MERGED    dd 0            ; quads taken into a batch
S_BATCHES   dd 0            ; merged draws issued
F_BATCH     db 0
F_DEDUPE    db 0
F_REC       db 0            ; between BeginStateBlock and EndStateBlock: pass everything through
            db 0
ORIG        dd NSLOTS dup(0)        ; the device's original vtable
VT_RTTI     dd 0                    ; vtable[-1] copied as is
VTABLE      dd NSLOTS dup(0)        ; what the device object points at while the proxy is on

align 4
VALID_START label byte
V_RS        db 256 dup(0)
V_TSS       db 256 dup(0)
V_TEX       db 8 dup(0)
V_VS        db 0
V_PS        db 0
V_IDX       db 0
V_MAT       db 0
V_STREAM    db 16 dup(0)
V_LEN       db 8 dup(0)
V_LIGHT     db 8 dup(0)
V_XF        db 16 dup(0)
align 4
VALID_END   label byte

RS_V        dd 256 dup(0)
TSS_V       dd 256 dup(0)
TEX_V       dd 8 dup(0)
VS_V        dd 0
PS_V        dd 0
IDX_V       dd 2 dup(0)
STREAM_V    dd 32 dup(0)
LEN_V       dd 8 dup(0)
LIGHT_V     dd 8 * 26 dup(0)        ; D3DLIGHT8, 104 bytes
MAT_V       dd 17 dup(0)            ; D3DMATERIAL8, 68 bytes
XF_V        dd 14 * 16 dup(0)       ; D3DMATRIX: VIEW, PROJECTION, TEXTURE0-7, WORLD0-3

; ---------------------------------------------------------------- helpers
; Draws the pending quads as one TRIANGLELIST. Keeps every register.
FLUSH:
    cmp     dword ptr [D_PENDING], 0
    je      flush_done
    pushad
    mov     eax, dword ptr [D_PENDING]
    mov     dword ptr [D_PENDING], 0
    inc     dword ptr [S_BATCHES]
    push    dword ptr [D_STRIDE]
    push    dword ptr [D_BUF]
    add     eax, eax
    push    eax                     ; 2 triangles a quad
    push    4                       ; D3DPT_TRIANGLELIST
    push    dword ptr [D_PDEV]
    call    dword ptr [ORIG + 4*72]
    mov     byte ptr [V_STREAM], 0  ; a UP draw resets stream 0
    popad
flush_done:
    ret

; Forget the whole shadow. Keeps every register.
INVALIDATE_ALL:
    push    eax
    push    ecx
    push    edi
    xor     eax, eax
    mov     edi, offset VALID_START
    mov     ecx, (VALID_END - VALID_START) / 4
    rep stosd
    pop     edi
    pop     ecx
    pop     eax
    ret

; ---------------------------------------------------------------- thunk shapes
; Flush, then the original method.
FLUSHFWD macro idx
T&idx&:
    call    FLUSH
    jmp     dword ptr [ORIG + 4*idx]
endm

; Flush, call the original method, forget the shadow, return its result.
CALLAFTER macro idx, nargs
T&idx&:
    call    FLUSH
    rept nargs + 1
    push    dword ptr [esp + 4*(nargs + 1)]
    endm
    call    dword ptr [ORIG + 4*idx]
    call    INVALIDATE_ALL
    ret     4*(nargs + 1)
endm

; A setter whose key is the first argument (below LIMIT) and whose value is one dword (second argument).
SETKV macro idx, nargs, LIMIT, VLD, VAL
    LOCAL newv, fwd, fwdnf
T&idx&:
    cmp     byte ptr [F_REC], 0
    jne     fwdnf
    mov     eax, [esp + 8]
    cmp     eax, LIMIT
    jae     fwd
    mov     edx, [esp + 12]
    cmp     byte ptr [VLD + eax], 0
    je      newv
    cmp     dword ptr [VAL + eax*4], edx
    jne     newv
    cmp     byte ptr [F_DEDUPE], 0
    je      fwdnf
    inc     dword ptr [S_SKIPPED]
    xor     eax, eax
    ret     4*(nargs + 1)
newv:
    mov     byte ptr [VLD + eax], 1
    mov     dword ptr [VAL + eax*4], edx
fwd:
    call    FLUSH
fwdnf:
    jmp     dword ptr [ORIG + 4*idx]
endm

; A setter whose value is NDW dwords behind a pointer at [esp + PTROFF]; eax = slot (checked by the caller).
SETMEM macro idx, nargs, NDW, VLD, VAL, PTROFF
    LOCAL copy, same, fwd, fwdnf, nul
    push    esi
    push    edi
    mov     esi, [esp + 8 + PTROFF]
    test    esi, esi
    jz      nul
    imul    edi, eax, NDW*4
    add     edi, offset VAL
    mov     ecx, NDW
    cmp     byte ptr [VLD + eax], 0
    je      copy
    repe cmpsd
    je      same
    mov     esi, [esp + 8 + PTROFF]
    imul    edi, eax, NDW*4
    add     edi, offset VAL
    mov     ecx, NDW
copy:
    rep movsd
    mov     byte ptr [VLD + eax], 1
    pop     edi
    pop     esi
    jmp     fwd
nul:
    pop     edi
    pop     esi
    jmp     fwd
same:
    pop     edi
    pop     esi
    cmp     byte ptr [F_DEDUPE], 0
    je      fwdnf
    inc     dword ptr [S_SKIPPED]
    xor     eax, eax
    ret     4*(nargs + 1)
fwd:
    call    FLUSH
fwdnf:
    jmp     dword ptr [ORIG + 4*idx]
endm

; ---------------------------------------------------------------- thunks
; Methods that change what is drawn or read back: flush first.
FLUSHFWD 5      ; ResourceManagerDiscardBytes
FLUSHFWD 10     ; SetCursorProperties
FLUSHFWD 13     ; CreateAdditionalSwapChain
FLUSHFWD 28     ; CopyRects
FLUSHFWD 29     ; UpdateTexture
FLUSHFWD 30     ; GetFrontBuffer
FLUSHFWD 31     ; SetRenderTarget
FLUSHFWD 36     ; Clear
FLUSHFWD 40     ; SetViewport
FLUSHFWD 48     ; SetClipPlane
FLUSHFWD 58     ; SetClipStatus
FLUSHFWD 66     ; SetPaletteEntries
FLUSHFWD 68     ; SetCurrentTexturePalette
FLUSHFWD 70     ; DrawPrimitive
FLUSHFWD 71     ; DrawIndexedPrimitive
FLUSHFWD 74     ; ProcessVertices
FLUSHFWD 79     ; SetVertexShaderConstant
FLUSHFWD 91     ; SetPixelShaderConstant
FLUSHFWD 94     ; DrawRectPatch
FLUSHFWD 95     ; DrawTriPatch
FLUSHFWD 96     ; DeletePatch

; Methods after which the device state is unknown (Ashita draws its GUI and runs plugins in these).
CALLAFTER 14, 1     ; Reset
CALLAFTER 15, 4     ; Present
CALLAFTER 34, 0     ; BeginScene
CALLAFTER 35, 0     ; EndScene
CALLAFTER 54, 1     ; ApplyStateBlock

; BeginStateBlock: from here on Set* calls are recorded, so pass them all through.
T52:
    call    FLUSH
    mov     byte ptr [F_REC], 1
    jmp     dword ptr [ORIG + 4*52]

; EndStateBlock
T53:
    push    dword ptr [esp + 8]
    push    dword ptr [esp + 8]
    call    dword ptr [ORIG + 4*53]
    mov     byte ptr [F_REC], 0
    call    INVALIDATE_ALL
    ret     8

; MultiplyTransform: the matrix changes to something we don't know.
T39:
    call    FLUSH
    push    eax
    push    ecx
    push    edi
    xor     eax, eax
    mov     edi, offset V_XF
    mov     ecx, 4
    rep stosd
    pop     edi
    pop     ecx
    pop     eax
    jmp     dword ptr [ORIG + 4*39]

; DrawIndexedPrimitiveUP resets stream 0 and the indices.
T73:
    call    FLUSH
    mov     byte ptr [V_STREAM], 0
    mov     byte ptr [V_IDX], 0
    jmp     dword ptr [ORIG + 4*73]

; DeleteVertexShader / DeletePixelShader: the handle may come back for a new shader.
T78:
    call    FLUSH
    mov     byte ptr [V_VS], 0
    jmp     dword ptr [ORIG + 4*78]
T90:
    call    FLUSH
    mov     byte ptr [V_PS], 0
    jmp     dword ptr [ORIG + 4*90]

SETKV 50, 2, 256, V_RS, RS_V        ; SetRenderState(state, value)
SETKV 46, 2, 8, V_LEN, LEN_V        ; LightEnable(index, enable)
SETKV 61, 2, 8, V_TEX, TEX_V        ; SetTexture(stage, texture)

; SetTextureStageState(stage, type, value): key = stage*32 + type
T63:
    cmp     byte ptr [F_REC], 0
    jne     tss_fwdnf
    mov     eax, [esp + 8]
    cmp     eax, 8
    jae     tss_fwd
    mov     ecx, [esp + 12]
    cmp     ecx, 32
    jae     tss_fwd
    shl     eax, 5
    add     eax, ecx
    mov     edx, [esp + 16]
    cmp     byte ptr [V_TSS + eax], 0
    je      tss_new
    cmp     dword ptr [TSS_V + eax*4], edx
    jne     tss_new
    cmp     byte ptr [F_DEDUPE], 0
    je      tss_fwdnf
    inc     dword ptr [S_SKIPPED]
    xor     eax, eax
    ret     16
tss_new:
    mov     byte ptr [V_TSS + eax], 1
    mov     dword ptr [TSS_V + eax*4], edx
tss_fwd:
    call    FLUSH
tss_fwdnf:
    jmp     dword ptr [ORIG + 4*63]

; SetVertexShader(handle) / SetPixelShader(handle)
ONEVAL macro idx, VLD, VAL
    LOCAL newv, fwd, fwdnf
T&idx&:
    cmp     byte ptr [F_REC], 0
    jne     fwdnf
    mov     edx, [esp + 8]
    cmp     byte ptr [VLD], 0
    je      newv
    cmp     dword ptr [VAL], edx
    jne     newv
    cmp     byte ptr [F_DEDUPE], 0
    je      fwdnf
    inc     dword ptr [S_SKIPPED]
    xor     eax, eax
    ret     8
newv:
    mov     byte ptr [VLD], 1
    mov     dword ptr [VAL], edx
fwd:
    call    FLUSH
fwdnf:
    jmp     dword ptr [ORIG + 4*idx]
endm
ONEVAL 76, V_VS, VS_V
ONEVAL 88, V_PS, PS_V

; SetStreamSource(stream, vb, stride)
T83:
    cmp     byte ptr [F_REC], 0
    jne     ss_fwdnf
    mov     eax, [esp + 8]
    cmp     eax, 16
    jae     ss_fwd
    mov     edx, [esp + 12]
    mov     ecx, [esp + 16]
    cmp     byte ptr [V_STREAM + eax], 0
    je      ss_new
    cmp     dword ptr [STREAM_V + eax*8], edx
    jne     ss_new
    cmp     dword ptr [STREAM_V + eax*8 + 4], ecx
    jne     ss_new
    cmp     byte ptr [F_DEDUPE], 0
    je      ss_fwdnf
    inc     dword ptr [S_SKIPPED]
    xor     eax, eax
    ret     16
ss_new:
    mov     byte ptr [V_STREAM + eax], 1
    mov     dword ptr [STREAM_V + eax*8], edx
    mov     dword ptr [STREAM_V + eax*8 + 4], ecx
ss_fwd:
    call    FLUSH
ss_fwdnf:
    jmp     dword ptr [ORIG + 4*83]

; SetIndices(ib, base)
T85:
    cmp     byte ptr [F_REC], 0
    jne     ix_fwdnf
    mov     edx, [esp + 8]
    mov     ecx, [esp + 12]
    cmp     byte ptr [V_IDX], 0
    je      ix_new
    cmp     dword ptr [IDX_V], edx
    jne     ix_new
    cmp     dword ptr [IDX_V + 4], ecx
    jne     ix_new
    cmp     byte ptr [F_DEDUPE], 0
    je      ix_fwdnf
    inc     dword ptr [S_SKIPPED]
    xor     eax, eax
    ret     12
ix_new:
    mov     byte ptr [V_IDX], 1
    mov     dword ptr [IDX_V], edx
    mov     dword ptr [IDX_V + 4], ecx
ix_fwd:
    call    FLUSH
ix_fwdnf:
    jmp     dword ptr [ORIG + 4*85]

; SetLight(index, light*)
T44:
    cmp     byte ptr [F_REC], 0
    jne     lt_fwdnf
    mov     eax, [esp + 8]
    cmp     eax, 8
    jae     lt_fwd
    SETMEM  44, 2, 26, V_LIGHT, LIGHT_V, 12
lt_fwd:
    call    FLUSH
lt_fwdnf:
    jmp     dword ptr [ORIG + 4*44]

; SetMaterial(material*)
T42:
    cmp     byte ptr [F_REC], 0
    jne     mt_fwdnf
    xor     eax, eax
    SETMEM  42, 1, 17, V_MAT, MAT_V, 8
mt_fwdnf:
    jmp     dword ptr [ORIG + 4*42]

; SetTransform(state, matrix*): VIEW 2 -> 0, PROJECTION 3 -> 1, TEXTURE0-7 16..23 -> 2..9, WORLD0-3 256..259 -> 10..13
T37:
    cmp     byte ptr [F_REC], 0
    jne     xf_fwdnf
    mov     eax, [esp + 8]
    cmp     eax, 2
    jb      xf_fwd
    cmp     eax, 3
    ja      xf_tex
    sub     eax, 2
    jmp     xf_have
xf_tex:
    cmp     eax, 16
    jb      xf_fwd
    cmp     eax, 23
    ja      xf_world
    sub     eax, 14
    jmp     xf_have
xf_world:
    cmp     eax, 256
    jb      xf_fwd
    cmp     eax, 259
    ja      xf_fwd
    sub     eax, 246
xf_have:
    SETMEM  37, 2, 16, V_XF, XF_V, 12
xf_fwd:
    call    FLUSH
xf_fwdnf:
    jmp     dword ptr [ORIG + 4*37]

; DrawPrimitiveUP(type, count, data, stride): merge 2-triangle strips; anything else flushes.
T72:
    cmp     byte ptr [F_BATCH], 0
    je      up_fwd
    cmp     byte ptr [F_REC], 0
    jne     up_fwd
    cmp     dword ptr [esp + 8], 5          ; D3DPT_TRIANGLESTRIP
    jne     up_fwd
    cmp     dword ptr [esp + 12], 2
    jne     up_fwd
    cmp     dword ptr [esp + 16], 0
    je      up_fwd
    mov     eax, [esp + 20]
    cmp     eax, 12
    jb      up_fwd
    cmp     eax, 64
    ja      up_fwd
    test    eax, 3
    jnz     up_fwd
    cmp     dword ptr [D_PENDING], 0
    je      up_start
    cmp     eax, dword ptr [D_STRIDE]
    jne     up_restart
    mov     ecx, [esp + 4]
    cmp     ecx, dword ptr [D_PDEV]
    jne     up_restart
    lea     ecx, [eax + eax*2]
    add     ecx, ecx                        ; 6 vertices
    add     ecx, dword ptr [D_PBYTES]
    cmp     ecx, dword ptr [D_BUFSIZE]
    ja      up_restart
    jmp     up_append
up_restart:
    call    FLUSH
up_start:
    lea     ecx, [eax + eax*2]
    add     ecx, ecx
    cmp     ecx, dword ptr [D_BUFSIZE]
    ja      up_fwd
    mov     dword ptr [D_STRIDE], eax
    mov     ecx, [esp + 4]
    mov     dword ptr [D_PDEV], ecx
    mov     dword ptr [D_PBYTES], 0
up_append:
    push    esi
    push    edi
    push    ebx
    mov     eax, [esp + 32]                 ; stride
    mov     ebx, eax
    shr     ebx, 2                          ; dwords a vertex
    mov     edx, [esp + 28]                 ; vertices
    mov     edi, dword ptr [D_BUF]
    add     edi, dword ptr [D_PBYTES]
    ; strip v0 v1 v2 v3 -> list v0 v1 v2, v2 v1 v3 (same triangles, same winding, same order)
    mov     esi, edx
    mov     ecx, ebx
    rep movsd
    lea     esi, [edx + eax]
    mov     ecx, ebx
    rep movsd
    lea     esi, [edx + eax*2]
    mov     ecx, ebx
    rep movsd
    lea     esi, [edx + eax*2]
    mov     ecx, ebx
    rep movsd
    lea     esi, [edx + eax]
    mov     ecx, ebx
    rep movsd
    lea     esi, [eax + eax*2]
    add     esi, edx
    mov     ecx, ebx
    rep movsd
    sub     edi, dword ptr [D_BUF]
    mov     dword ptr [D_PBYTES], edi
    inc     dword ptr [D_PENDING]
    inc     dword ptr [S_MERGED]
    mov     byte ptr [V_STREAM], 0          ; the client's UP draw resets stream 0
    pop     ebx
    pop     edi
    pop     esi
    xor     eax, eax
    ret     20
up_fwd:
    call    FLUSH
    mov     byte ptr [V_STREAM], 0
    jmp     dword ptr [ORIG + 4*72]

; ---------------------------------------------------------------- per-slot table
SLOT macro idx
    IFDEF T&idx&
    dd offset T&idx&
    ELSE
    dd 0
    ENDIF
endm

align 4
THUNK_TABLE label dword
i = 0
rept NSLOTS
    SLOT %i
    i = i + 1
endm

end
