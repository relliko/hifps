; hifps lamp light (the 'lamps' graphics setting): brightness and reach of the zone's lamps at night.
; A lamp reaches the picture three ways, and each one's call is pointed at an entry here:
;   VSC_LAMP     zone meshes with a vertex shader: in place of 'call [ecx+13Ch]', the
;                SetVertexShaderConstant(dev, 15, data, 4) upload of c15-c17 (the lamps' red, green and
;                blue, one lamp per component) and c18 (each lamp's range squared, a hard cut-off in
;                the shader). Uploads a copy: colours x BRIGHT, c18 x REACH2.
;   LIGHT_LAMPn  zone meshes without a shader: the client's SetLight wrapper (thiscall on the renderer,
;                (index, D3DLIGHT8*), ret 8) for lamp lights 1-4. Passes a copy of a point light:
;                diffuse x BRIGHT, range x REACH, attenuation 1 / REACH, attenuation 2 / REACH2 (the
;                same falloff, stretched).
;   ACTOR_LAMP   characters: a lamp is folded into the character's light table as a directional
;                light whose colour is scaled by a weight (cdecl vec3 *= float, 0272B0). Weight x BRIGHT.
; With BRIGHT = REACH = 1 every value comes out as the client's.
;
; Night lighting (the 'night' graphics setting): every sun/moon light and every ambient colour the
; client uses comes from two builders on an environment object (thiscall, (out, kind), ret 8; kind 0
; the zone, 1 characters): 188CA0 fills a directional D3DLIGHT8, 188E00 a D3DCOLOR. Their entries
; jump here (LIGHT_HOOK, AMB_HOOK); the builder runs from a copy of its first instructions
; (LIGHT_TRAMP, AMB_TRAMP), then the output is scaled: diffuse x MOONF, ambient bytes x AMBF
; (clamped at 255). hifps sets MOONF and AMBF from the Vana'diel hour (1 by day).
; Everything is one section: code and data. hifps copies it into its own memory and adds the block's
; base to every DIR32 relocation. ORIG_SETLIGHT, ORIG_SCALE and the factors are filled in by hifps.
.686
.model flat
option casemap:none

PUBLIC BRIGHT, REACH, REACH2, INV_REACH, INV_REACH2, ORIG_SETLIGHT, ORIG_SCALE
PUBLIC S_VSC, S_LIGHT, S_ACTOR
PUBLIC VSC_LAMP, LIGHT_LAMP1, LIGHT_LAMP2, LIGHT_LAMP3, LIGHT_LAMP4, ACTOR_LAMP
PUBLIC MOONF, AMBF, LIGHT_CONT, AMB_CONT, S_MOON, S_AMB, LIGHT_HOOK, AMB_HOOK

LIGHT_SIZE equ 104          ; D3DLIGHT8

.code

; ---------------------------------------------------------------- data
align 4
BRIGHT          dd 1.0
REACH           dd 1.0
REACH2          dd 1.0          ; REACH squared
INV_REACH       dd 1.0          ; 1 / REACH
INV_REACH2      dd 1.0          ; 1 / REACH squared
ORIG_SETLIGHT   dd 0            ; the client's SetLight wrapper
ORIG_SCALE      dd 0            ; the client's vec3 *= float
S_VSC           dd 0            ; lamp constant uploads changed
S_LIGHT         dd 0            ; lamp lights changed
S_ACTOR         dd 0            ; lamps on characters changed
MOONF           dd 1.0          ; sun/moon diffuse factor now
AMBF            dd 1.0          ; ambient factor now
LIGHT_CONT      dd 0            ; 188CA0 + 5: where the light builder goes on after its first instructions
AMB_CONT        dd 0            ; 188E00 + 6: the same for the ambient builder
S_MOON          dd 0            ; lights built
S_AMB           dd 0            ; ambient colours built
VSC_BUF         dd 16 dup(0)
LIGHT_BUF       db 4 * LIGHT_SIZE dup(0)

; ---------------------------------------------------------------- entries
; [esp+4] device, [esp+8] register, [esp+12] data, [esp+16] count; ecx = the device's vtable.
VSC_LAMP:
    cmp     dword ptr [esp + 8], 15
    jne     vsc_go
    cmp     dword ptr [esp + 16], 4
    jne     vsc_go
    mov     eax, [esp + 12]
    xor     edx, edx
vsc_rgb:
    fld     dword ptr [eax + edx * 4]
    fmul    dword ptr [BRIGHT]
    fstp    dword ptr [VSC_BUF + edx * 4]
    inc     edx
    cmp     edx, 12
    jb      vsc_rgb
vsc_range:
    fld     dword ptr [eax + edx * 4]
    fmul    dword ptr [REACH2]
    fstp    dword ptr [VSC_BUF + edx * 4]
    inc     edx
    cmp     edx, 16
    jb      vsc_range
    mov     dword ptr [esp + 12], offset VSC_BUF
    inc     dword ptr [S_VSC]
vsc_go:
    jmp     dword ptr [ecx + 13Ch]

; [esp+4] index, [esp+8] light; ecx = the renderer (kept for the wrapper). One buffer per call site.
LIGHT_LAMP1:
    mov     eax, offset LIGHT_BUF
    jmp     light_common
LIGHT_LAMP2:
    mov     eax, offset LIGHT_BUF + LIGHT_SIZE
    jmp     light_common
LIGHT_LAMP3:
    mov     eax, offset LIGHT_BUF + 2 * LIGHT_SIZE
    jmp     light_common
LIGHT_LAMP4:
    mov     eax, offset LIGHT_BUF + 3 * LIGHT_SIZE
light_common:
    mov     edx, [esp + 8]
    test    edx, edx
    jz      light_go
    cmp     dword ptr [edx], 1          ; D3DLIGHT_POINT
    jne     light_go
    push    esi
    push    edi
    push    ecx
    mov     esi, edx
    mov     edi, eax
    mov     ecx, LIGHT_SIZE / 4
    cld
    rep movsd
    pop     ecx
    pop     edi
    pop     esi
    fld     dword ptr [eax + 4]         ; Diffuse r, g, b
    fmul    dword ptr [BRIGHT]
    fstp    dword ptr [eax + 4]
    fld     dword ptr [eax + 8]
    fmul    dword ptr [BRIGHT]
    fstp    dword ptr [eax + 8]
    fld     dword ptr [eax + 12]
    fmul    dword ptr [BRIGHT]
    fstp    dword ptr [eax + 12]
    fld     dword ptr [eax + 4Ch]       ; Range
    fmul    dword ptr [REACH]
    fstp    dword ptr [eax + 4Ch]
    fld     dword ptr [eax + 58h]       ; Attenuation1
    fmul    dword ptr [INV_REACH]
    fstp    dword ptr [eax + 58h]
    fld     dword ptr [eax + 5Ch]       ; Attenuation2
    fmul    dword ptr [INV_REACH2]
    fstp    dword ptr [eax + 5Ch]
    mov     [esp + 8], eax
    inc     dword ptr [S_LIGHT]
light_go:
    jmp     dword ptr [ORIG_SETLIGHT]

; cdecl: [esp+4] vec3, [esp+8] weight.
ACTOR_LAMP:
    fld     dword ptr [esp + 8]
    fmul    dword ptr [BRIGHT]
    fstp    dword ptr [esp + 8]
    inc     dword ptr [S_ACTOR]
    jmp     dword ptr [ORIG_SCALE]

; In place of the light builder: ecx = environment, [esp+4] out D3DLIGHT8, [esp+8] kind; ret 8.
LIGHT_HOOK:
    push    dword ptr [esp + 8]
    push    dword ptr [esp + 8]
    call    LIGHT_TRAMP                 ; ecx as given
    push    eax
    mov     eax, [esp + 8]              ; out
    test    eax, eax
    jz      lh_done
    fld     dword ptr [eax + 4]         ; Diffuse r, g, b
    fmul    dword ptr [MOONF]
    fstp    dword ptr [eax + 4]
    fld     dword ptr [eax + 8]
    fmul    dword ptr [MOONF]
    fstp    dword ptr [eax + 8]
    fld     dword ptr [eax + 12]
    fmul    dword ptr [MOONF]
    fstp    dword ptr [eax + 12]
    inc     dword ptr [S_MOON]
lh_done:
    pop     eax
    ret     8
; 188CA0's first instructions, then the rest of it.
LIGHT_TRAMP:
    sub     esp, 30h
    push    ebx
    push    esi
    jmp     dword ptr [LIGHT_CONT]

; In place of the ambient builder: ecx = environment, [esp+4] out D3DCOLOR, [esp+8] kind; ret 8.
AMB_HOOK:
    push    dword ptr [esp + 8]
    push    dword ptr [esp + 8]
    call    AMB_TRAMP
    push    eax
    mov     eax, [esp + 8]              ; out
    test    eax, eax
    jz      ah_done
    push    ecx
    push    edx
    xor     ecx, ecx                    ; blue, green, red; alpha kept
ah_byte:
    movzx   edx, byte ptr [eax + ecx]
    push    edx
    fild    dword ptr [esp]
    fmul    dword ptr [AMBF]
    fistp   dword ptr [esp]
    pop     edx
    cmp     edx, 255
    jbe     ah_keep
    mov     edx, 255
ah_keep:
    mov     byte ptr [eax + ecx], dl
    inc     ecx
    cmp     ecx, 3
    jb      ah_byte
    pop     edx
    pop     ecx
    inc     dword ptr [S_AMB]
ah_done:
    pop     eax
    ret     8
; 188E00's first instructions, then the rest of it.
AMB_TRAMP:
    mov     eax, [ecx - 1Ch]
    sub     esp, 20h
    jmp     dword ptr [AMB_CONT]

end
