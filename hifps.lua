addon.name      = 'hifps';
addon.author    = 'Relli';
addon.version   = '0.9.5';
addon.desc      = 'Runs the client above 60fps by feeding real frame time into the game step.';

require 'common';
local ffi  = require 'ffi';
local chat = require 'chat';
local imgui = require 'imgui';

pcall(ffi.cdef, [[
    typedef struct { uint32_t cb; uint32_t PageFaultCount; size_t PeakWorkingSetSize; size_t WorkingSetSize;
        size_t QuotaPeakPagedPoolUsage; size_t QuotaPagedPoolUsage; size_t QuotaPeakNonPagedPoolUsage;
        size_t QuotaNonPagedPoolUsage; size_t PagefileUsage; size_t PeakPagefileUsage; } hifps_pmc;
    void* __stdcall GetCurrentProcess(void);
    int __stdcall K32GetProcessMemoryInfo(void* process, hifps_pmc* counters, uint32_t cb);
]]);
pcall(ffi.cdef, [[
    int __stdcall QueryPerformanceCounter(int64_t* count);
    int __stdcall QueryPerformanceFrequency(int64_t* freq);
    void __stdcall Sleep(uint32_t ms);
]]);
pcall(ffi.cdef, [[
    int __stdcall IsBadReadPtr(const void* p, size_t size);
    int __stdcall GetModuleHandleExA(uint32_t flags, const void* addr, void** module);
    uint32_t __stdcall GetModuleFileNameA(void* module, char* name, uint32_t size);
]]);

--[[
* How it works:
*   The client advances timers/animation by a per-frame "step" in 1/60s ticks, read through a getter
*   that returns max(step, 1.0). The step normally comes from the fps divisor, so anything above 60fps
*   is clamped to 1 tick per frame and the game runs fast. Both copies of that getter are replaced:
*   the first returns the real frame time in ticks (fractional), the second returns whole ticks
*   accumulated from real time (0, 1, 2...). Every call site of the getters is pointed at one of them:
*   sites that truncate the step to an integer get whole ticks, the rest get the fractional step.
*   The divisor is set to 0 (uncapped) and an optional limiter caps the frame rate.
*   Unloading restores every original byte and the divisor.
*
*   v0.4: moved the music-start and push-through-entity sites to whole ticks (found by bisecting).
*   v0.5: camera follow smoothing. The camera eases toward its target with a fixed-step loop
*   (pos += (target - pos) * k, once per whole tick). With whole ticks above 60fps it only moved
*   every other frame, which looked like blur while turning. Those loops now run once per frame with
*   k rescaled to the real step: k' = 1 - (1 - k)^step, which matches stock exactly at whole ticks.
*   v0.6: the camera distance/collision loop (also per whole tick) runs once per frame too. Its gains
*   and its delay timer read float constants from memory; those instructions are pointed at our own
*   slots, rewritten every frame: gains as 1 - (1 - g)^step, per-tick amounts as v * step.
*   v0.7: works alongside camera addons that redirect the same operands (xicamera points the two
*   0.125 "jitter" gains at its own 1.0). An operand that points somewhere else is left alone; if its
*   value behaves the same at any frame rate (a gain of 0 or 1, a per-tick amount of 0) the loop still
*   runs once per frame, otherwise hifps leaves that loop alone and prints a camera warning. Operands
*   are re-checked every frame, so either load order works, and hifps keeps its memory alive on unload
*   if another addon might still write a pointer to it back.
*   v0.8: other characters' movement and turning (CXiSkeletonActor::Update). Each actor eases its
*   position and rotation toward a target with the same fixed-step loop, but counted down from the
*   fractional step, so it ran ceil(step) passes: 1 or 2 depending on whether a frame took longer
*   than 1/60s. With many people around the frame time hovers there and everyone microstuttered
*   (found by bisecting). These loops now run once per frame with k rescaled like the camera's.
*   v0.8.1: walking animations. Each character's animation compares this frame's movement with
*   constants meant per 1/60s: under 0.01 it counts as standing still, and its speed is smoothed
*   old * 0.75 + new * 0.25 a frame. Above 60fps a slow walker (most NPCs) moved less than 0.01 a
*   frame, so it slid in its idle pose, or its walk restarted over and over at the edge. Those
*   constants are now scaled to the frame's step. Bisect leaves out the smoothing-loop sites (they
*   run once a frame either way) and asks for one more test at the end before naming a site.
*   v0.8.2: a player (Linux, WineD3D, hifps 0.6.1 at 120fps) measured the game's heap growing about
*   15 MB a minute until the 32-bit client ran out of address space after ~3 hours; capped at 60 it
*   stayed flat. /hifps mem shows the game's memory and how fast it grows; /hifps leak start finds
*   the cause on its own: a minute as usual, a minute with every call site on the stub (does the
*   growth come from a site at all, or just from more frames?), then a bisect a minute a round.
*   v0.9: /hifps exp: experimental frame-time toggles that don't touch the game step, off by
*   default (see the block above disable() for what each one does).
*   /hifps opens a config window for all of it (frame limit, counter, the toggles); /hifps help
*   prints the status line.
*   v0.9.1: 'ashita' first checks the loaded addons and plugins for users of the draw events,
*   refuses if it finds one (force overrides), and turns itself off if one is loaded later.
*   v0.9.2: the frame limit defaults to 240; a tidier config window (explanations on hover);
*   'occlusion' allows 3% slack so a 120 cap that measures 119.9fps still counts as 120.
*   v0.9.3: settings are saved (config\addons\hifps\settings.lua, all characters): on/off,
*   frame limit, counter and the experimental toggles, which come back once the game's device exists.
*   v0.9.4: the target's name pulse. Its alpha is a sine of the game's frame count (16 degrees a
*   frame, GetNamePlace's colour at 0x083197 -> 0x014D50), so above 60fps it pulsed faster. That one
*   call now reads a count of whole 1/60s ticks from real time, started from the game's own count so
*   the pulse doesn't jump; the frame count's other readers (the actor update's every-Nth-frame
*   throttles) keep the real one.
*   v0.9.5: how other players see you walk. A character counts as moving on a frame where it moved
*   over 0.02, a constant meant per 1/60s. While you move, the position packet counts the ticks
*   spent moving (MoveFlame), and a frame that doesn't count as moving starts it over; other
*   players' clients play your walk over that count's change. Without a cap the game reaches,
*   some frames are short enough to move under 0.02, so the count restarted mid-walk and others saw
*   a quick step, a pause, and the walk again. The 0.02 is now scaled to the frame's step, and
*   the count sent while standing gets the stock 1 tick instead of 0 or 1.
*
*   Bisect mode (local server only): points a group of call sites at a stub that always returns 1.0,
*   the stock 60fps value, so you can find which site causes a bug. Sites in that group run fast
*   above 60fps while it is active. The leak hunt does the same, so it stops if your character moves.
--]]

-- Call sites (offsets from FFXiMain.dll base) that use the fractional step.
local FRAC_SITES = {
    0x00766F, 0x01A9AB, 0x01B5D4, 0x01C5AF, 0x01F01F, 0x01F0F2, 0x01F82F, 0x01F87F,
    0x01F8D5, 0x01F91D, 0x0205B1, 0x02198E, 0x02AD55, 0x033ED1, 0x033FAB, 0x035944,
    0x0368B6, 0x0368CE, 0x0381D4, 0x0478BF, 0x0478D7, 0x06A000, 0x08D383,
    0x08D38F, 0x08D39D, 0x08D61D, 0x08D62B, 0x08D639, 0x08D647, 0x08D655, 0x09729C,
    0x0A57F9, 0x0A7B8A, 0x0A9FC7, 0x0AA1F7, 0x0AAB78, 0x0AADF5, 0x0B0829,
    0x0B08BF, 0x0B2F4E, 0x0B2F9E, 0x0B2FE1, 0x0B32A8, 0x0B32F0, 0x0B3333, 0x0B3376,
    0x0B56F2, 0x0B57FD, 0x0B5840, 0x0B587D, 0x0C4878, 0x0C648E,
    0x0C76CA, 0x0C7F13, 0x0C8AC8, 0x0C8AE7, 0x0CAEEA, 0x0CBC68, 0x0CDF96,
    0x12C179, 0x12C734, 0x12CBCF, 0x178BD0, 0x17A4BB, 0x188A54, 0x1EDF4C, 0x1EF1AC,
    0x1EF1D2, 0x1EF282, 0x1EF334, 0x1EF3DE, 0x1EF541, 0x1EF55D, 0x1EF570, 0x1EF590,
    0x1EF5AC, 0x1EF5BF, 0x1EF6FE, 0x1EF711, 0x1EFA27, 0x227E58, 0x24DE98, 0x24DF4E,
    0x24EBCA, 0x24EC1F, 0x24EE6D, 0x24EECB, 0x24F019, 0x24F6E6,
    -- Moved from the whole-tick list: scales the step into the lock-on run animation blend (bisect, v0.7.3).
    0x0A5194,
};
-- Call sites that truncate the step to an integer.
local INT_SITES = {
    0x005A50, 0x007BB6, 0x007D74, 0x018A10, 0x018D0E, 0x01BC9C, 0x01EEFE,
    0x020148, 0x021185, 0x0211C1, 0x021207,
    0x021243, 0x0219A0, 0x0375A0, 0x0375FB, 0x039366, 0x087495, 0x087E99, 0x0884CC,
    0x0884F5, 0x0885B1, 0x0886B3, 0x088CA7, 0x088CD4, 0x088CF9, 0x088E63, 0x088ECF,
    0x089061, 0x0891FF, 0x089228, 0x0892E7, 0x0893CB, 0x0898F5, 0x089933, 0x089958,
    0x089AFB, 0x089B67, 0x08ADD1, 0x08AE39, 0x08D34B, 0x08D3BE, 0x08D663, 0x08D671,
    0x08DAAB, 0x08EA21, 0x08ED66, 0x091AD3, 0x09670D, 0x097271, 0x0984D5,
    0x09F661, 0x0A2843, 0x0AC55D, 0x0AECC0, 0x0B035D, 0x0B578B, 0x0B76A4,
    0x0B7725, 0x0C3568, 0x0C35E9, 0x0CB4ED, 0x1175D5, 0x117766, 0x11777B, 0x1177A2,
    0x11966C, 0x11970C, 0x119F31, 0x1248DC, 0x124D47, 0x1250B0, 0x1251FE, 0x125430,
    0x125C00, 0x1268A9, 0x12B7FA, 0x12E8EC, 0x133ABE, 0x1375ED, 0x13A033, 0x13A616,
    0x14CB7B, 0x1500EB, 0x159A6C, 0x15DE2B, 0x15FF0A, 0x1628E5, 0x162913, 0x162956,
    0x18C273, 0x18C293, 0x19EAF2, 0x1CE91B, 0x1D4008, 0x1D54BA, 0x1D5530, 0x1D7AD0,
    0x1E187B, 0x1EEFDA, 0x1EF008, 0x1EF067, 0x1FB9DC, 0x1FBA03, 0x2014F6, 0x2160A3,
    0x2164C3, 0x21F263, 0x21F2C0, 0x220364, 0x220998, 0x220B14, 0x220EA2, 0x221428,
    0x221492, 0x24C316, 0x24E8BE, 0x24EB4D,
    -- Found by bisecting: these truncate after a jump, so the scan missed them.
    0x03746F,   -- music start countdown
    0x0A8778,   -- push-through-entity delay
};
-- Call sites that get the 1.0 stub, the stock 60fps step, at any frame rate.
local STOCK_SITES = {
    -- The position packet's movement counter while standing: 'counter + (int)step', which is 1 at
    -- stock. Whole ticks made it 0 or 1 frame to frame (v0.9.5).
    0x0984F6,
};

-- Fixed-step smoothing loops: "n = (int)step; repeat n times: v += (target - v) * k", with k pushed
-- as an immediate float. Their call sites get the 1.0 stub (one pass per frame) and the immediate is
-- rewritten every frame to 1 - (1 - k)^step. imm = offset of the 4 immediate bytes, pre = the bytes
-- in front of them (default 68, a push).
-- ops: instructions in the loop that read a float constant from memory ("fmul/fsub dword [const]").
-- at = offset of the instruction's disp32, const = offset of the constant it reads. The disp32 is
-- pointed at a slot of ours; mode 'ease' gets 1 - (1 - v)^step, 'lin' gets v * step, 'pow' v^step.
-- fallback: how the sites are fed if another addon changed the loop (default whole ticks).
local CAMERA_EFFECT = 'That part of the camera may blur or move at the wrong speed above 60fps. Unload the other camera addon, or use /hifps limit 60.';
local ACTOR_EFFECT = 'Other characters may move or turn unevenly above 60fps. Unload the other addon, or use /hifps limit 60.';
local MOVE_EFFECT = 'Other players may see you walk in bursts above 60fps. Unload the other addon, or use /hifps limit 60.';
local SMOOTH_LOOPS = {
    { name = 'camera follow', sites = { 0x01F5A2 },           imm = 0x01F5D4, k = 0.25 },
    { name = 'camera ease',   sites = { 0x01F66B, 0x01F711 }, imm = 0x01F6C7, k = 0.05 },
    { name = 'camera distance/collision', sites = { 0x01FA38, 0x01FE7C }, ops = {
        { at = 0x01FA57, const = 0x32961C, mode = 'lin'  },         -- delay timer -= 1.0
        { at = 0x01FCCA, const = 0x32A3E0, mode = 'lin'  },         -- per-tick move amount
        { at = 0x01FD28, const = 0x329A08, mode = 'ease' },         -- pull in when too far
        { at = 0x01FD4E, const = 0x32A3C4, mode = 'ease' },         -- push out when too close
        { at = 0x01FDA7, const = 0x32A3C0, mode = 'ease' },
        { at = 0x01FE38, const = 0x32A3BC, mode = 'ease' },
        { at = 0x01FE48, const = 0x32A3BC, mode = 'ease' },
    } },
    -- CXiSkeletonActor::Update, every character: "n = step; do { v += (target - v) * k; n -= 1 } while
    -- (n > 0)". Counted down from the fractional step it ran ceil(step) passes, so a frame just over
    -- 1/60s moved everyone almost twice as far (bisect, v0.8). Fallback: the fractional step as before.
    { name = 'character movement', effect = ACTOR_EFFECT, fallback = 'f', sites = { 0x0C65BA }, ops = {
        { at = 0x0C65F0, const = 0x32A3BC, mode = 'ease' },         -- position += (target - position) * 0.125: x
        { at = 0x0C6601, const = 0x32A3BC, mode = 'ease' },         -- y
        { at = 0x0C660F, const = 0x32A3BC, mode = 'ease' },         -- z
    } },
    -- Turning, two copies of the same loop. k is 0.125 (a "mov [esp+14], imm"), or the entity's speed
    -- (percent, 100 by default) * 0.00125, which can only be scaled linearly here: within ~3% at 100.
    { name = 'character turning', effect = ACTOR_EFFECT, fallback = 'f', sites = { 0x0C6882 },
        imm = 0x0C684B, pre = { 0xC7, 0x44, 0x24, 0x14 }, k = 0.125, ops = {
        { at = 0x0C687A, const = 0x331364, mode = 'lin' },
    } },
    { name = 'character turning', effect = ACTOR_EFFECT, fallback = 'f', sites = { 0x0C6C64 },
        imm = 0x0C6C2D, pre = { 0xC7, 0x44, 0x24, 0x14 }, k = 0.125, ops = {
        { at = 0x0C6C5C, const = 0x331364, mode = 'lin' },
    } },
    -- The walk/run animation, after the movement loop (no call sites of its own): this frame's
    -- movement under 0.01 counts as none (0C7100; it's still applied, but the animation code gets a
    -- zero vector), under 0.0001 as speed 0 (0C8A74, in 0C8930); the animation speed (movement
    -- against the character's speed for the frame) is smoothed into [actor+824] (0C8B30).
    { name = 'character animation', effect = ACTOR_EFFECT, sites = {}, ops = {
        { at = 0x0C7102, const = 0x329A18, mode = 'lin'  },         -- moved at all: 0.01 a tick
        { at = 0x0C8A76, const = 0x32A1A8, mode = 'lin'  },         -- any speed: 0.0001 a tick
        { at = 0x0C8B38, const = 0x329D34, mode = 'pow'  },         -- smoothing: old * 0.75 ...
        { at = 0x0C8B40, const = 0x329CE4, mode = 'ease' },         -- ... + new * 0.25
    } },
    -- The 'moving' flag (CXiControlActor::Update, 0A5BA9): this frame's movement over 0.02 sets
    -- [actor+F8]. While it is set, the position packet (0983F0) counts the ticks spent moving and
    -- sends the count as MoveFlame; a frame without it starts the count over. Other players' clients
    -- play your walk over the count's change (08CD20), so a short frame that moved under 0.02 made
    -- you walk in bursts to them (v0.9.5).
    { name = 'movement flag', effect = MOVE_EFFECT, sites = {}, ops = {
        { at = 0x0A5BAB, const = 0x32B7B4, mode = 'lin'  },         -- moved: 0.02 a tick
    } },
};
local MAX_OPS = 24;
-- The target's name pulse: 'mov cl, [esi+3]; mov ebp, ecx; call <frame count>; shl eax, 4; cdq;
-- mov ecx, 360' in GetNamePlace's colour (0x083192); the call at +5. Our count and its getter live
-- after the operand slots.
local PULSE_PAT = '8A4E038BE9E8????????C1E00499B968010000';
local PULSE_OFF = 32 + MAX_OPS * 4;

local MIN_STEP = 0.05;  -- ticks; ~1200fps
local MAX_STEP = 4.0;   -- ticks; hitches longer than this slow the game down like before

local state = T{
    sites       = T{},      -- { addr, kind ('f'|'i'|'s'), backup (rel32 bytes), target }
    smooth      = T{},      -- { addr (immediate), k, backup, prot }
    ops         = T{},      -- { addr (disp32), const (game constant address), v (its value), mode, slot, name, warned }
    getters     = T{},      -- { addr, backup }
    pulse       = nil,      -- the name pulse's call: { addr, backup (rel32 bytes), target }
    ticks       = 0,        -- whole 1/60s ticks for it (u32)
    mem         = nil,      -- +0 frac step, +4 whole step, +16 stub code, +24 1.0f
    g_frac      = nil,
    g_int       = nil,
    stub        = nil,
    accum       = 0,
    div_ptr     = nil,
    div_orig    = nil,
    limit       = 240,      -- fps cap, 0 = none (use vsync / driver cap)
    last        = nil,
    freq        = 0,
    frames      = 0,
    fps         = 0,
    fps_timer   = 0,
    step        = 1.0,
    counter     = true,     -- fps counter in the top left
    bisect      = nil,      -- { list, lo, hi, round, confirm, all }
    samples     = T{},      -- the game's memory, { time, bytes } once a second (the last few minutes)
    sample_t    = 0,
    hunt        = nil,      -- a leak hunt: { phase, t0 (measuring from), pos, base, floor, cut }
    read_memory = nil,      -- the game's private memory in bytes, or nil (set below)
};

local qpc_buf = ffi.new('int64_t[1]');
local function now()
    ffi.C.QueryPerformanceCounter(qpc_buf);
    return tonumber(qpc_buf[0]) / state.freq;
end

local function msg(s) print(chat.header(addon.name):append(chat.message(s))); end
local function err(s) print(chat.header(addon.name):append(chat.error(s))); end

local function write_bytes(addr, bytes)
    local ok, prot = ashita.memory.unprotect(addr, #bytes);
    if (not ok) then return false; end
    ashita.memory.write_array(addr, bytes);
    ashita.memory.protect(addr, #bytes, prot);
    return true;
end

local function le32(v)
    v = bit.tobit(v);
    return { bit.band(v, 0xFF), bit.band(bit.rshift(v, 8), 0xFF), bit.band(bit.rshift(v, 16), 0xFF), bit.band(bit.rshift(v, 24), 0xFF) };
end

local function call_target(site)
    return bit.tobit(site + 5 + ashita.memory.read_int32(site + 1));
end

local function point_site(s, target)
    if (s.target == target) then return true; end
    if (not write_bytes(s.addr + 1, le32(target - (s.addr + 5)))) then return false; end
    s.target = target;
    return true;
end

-- The name pulse's call pointed at our tick count (state.mem + PULSE_OFF), which starts from the
-- game's frame count (its getter is 'mov eax, [obj]; mov eax, [eax+0x34]; ret'). Not found: the
-- pulse stays the game's.
local function patch_pulse()
    local p = ashita.memory.find(0, 0, PULSE_PAT, 0, 0);
    if (p == nil or p == 0) then return; end
    local site = p + 5;
    if (ashita.memory.read_uint8(site) ~= 0xE8) then return; end
    local tgt = call_target(site);
    local start = 0;
    if (ashita.memory.read_uint8(tgt) == 0xA1) then
        local obj = ashita.memory.read_uint32(ashita.memory.read_uint32(tgt + 1));
        if (obj ~= nil and obj ~= 0) then start = ashita.memory.read_uint32(obj + 0x34); end
    end
    local cnt = state.mem + PULSE_OFF;
    state.ticks = start;
    ashita.memory.write_uint32(cnt, start);
    local c = le32(cnt);
    ashita.memory.write_array(cnt + 4, { 0xA1, c[1], c[2], c[3], c[4], 0xC3 });
    local s = { addr = site, backup = ashita.memory.read_array(site + 1, 4), target = tgt };
    if (point_site(s, bit.tobit(cnt + 4))) then state.pulse = s; end
end

local function find_divisor()
    local p = ashita.memory.find(0, 0, '81EC000100003BC174218B0D', 0, 0);
    if (p == 0) then return nil; end
    p = ashita.memory.read_uint32(p + 0x0C);
    p = ashita.memory.read_uint32(p);
    if (p == 0) then return nil; end
    return p + 0x30;
end

-- Unsigned address from a bit.tobit / read_uint32 value.
local function u32(v) v = bit.tobit(v); return v < 0 and v + 4294967296 or v; end

-- True if an operand with this value behaves the same at any step, so it needs no rescaling.
local function step_invariant(mode, v)
    if (mode == 'ease') then return v == 0 or math.abs(v) == 1; end
    if (mode == 'pow') then return v == 0 or v == 1; end
    return v == 0;
end

local function loop_warning(name, effect, addr, detail)
    err(('Warning: the %s code at %08X was changed by another addon (%s) in a way hifps cannot adjust for. %s'):fmt(name, addr, detail, effect or CAMERA_EFFECT));
end

local function set_divisor(v)
    if (state.div_ptr ~= nil) then ashita.memory.write_uint32(state.div_ptr, v); end
end

--[[
* Experimental frame-time toggles (/hifps exp). All off by default (saved with the settings); each one puts back
* what it changed when turned off, on /hifps off and on unload. None of them changes the game step.
*   ashita    Ashita's device wrapper hands every draw call to every plugin, and the addons plugin
*             looks the event up in every loaded addon, about 3,000 times a frame although no addon
*             here handles d3d_dp/dip/dpup/dipup. Skips that (those four events stop firing).
*             Before turning on it reads the loaded addons' Lua files for those event names and
*             each plugin's four draw callbacks (any that do more than return false), and refuses
*             if something uses them (/hifps exp ashita force overrides). While on, it checks again
*             whenever the loaded addons or plugins change, and turns itself off for a newcomer.
*   occlusion Characters test whether they are hidden behind walls with a GPU readback that stalls
*             the frame; the client tests each one every 4th frame. Above 60fps this tests every
*             4m-th frame instead, m = fps/60 rounded down to a power of two, so a result is never
*             older than at stock 60fps. Targeting reads the result, so this keeps it that fresh.
*   sse       The client skins characters on the CPU and only uses its SSE code when the CPU says
*             "Intel"; other CPUs get the x87 code. Turns the SSE code on for them.
*   batch     The text and UI draw one quad per draw call; consecutive quads with nothing changed
*             in between become one draw. Same triangles, same order, same state.
*   dedupe    About 40% of the client's device calls set a value already in effect; drops those.
*   batch and dedupe replace the client device's vtable with proxy_code.lua (built from
*   proxy/proxy.asm and tested against a simulated device by proxy/gen_harness.py).
--]]
local PROXY = require('proxy_code');
local PROXY_BUF = 0x20000;      -- bytes of merged vertices: 780 text quads a draw
local EXP_NAMES = { 'ashita', 'occlusion', 'sse', 'batch', 'dedupe' };
local EXP_DESC = {
    ashita    = 'skip Ashita\'s per-draw plugin dispatch (d3d_dp/dip/dpup/dipup stop firing)',
    occlusion = 'test hidden characters less often above 60fps, as fresh as stock at 60fps (within 3%)',
    sse       = 'SSE character skinning on non-Intel CPUs',
    batch     = 'merge consecutive text and UI quads into one draw',
    dedupe    = 'drop device calls that set a value already in effect',
};
-- For the config window.
local EXP_LABEL = {
    ashita    = 'Skip Ashita\'s per-draw plugin dispatch',
    occlusion = 'Test hidden characters less often',
    sse       = 'SSE character skinning on non-Intel CPUs',
    batch     = 'Batch text and UI quads',
    dedupe    = 'Drop repeated device calls',
};
local EXP_HINT = {
    ashita    = 'Ashita hands each of ~3,000 draws a frame to every plugin and addon. The d3d_dp/dip/dpup/dipup events stop firing; no addon here uses them.',
    occlusion = 'The behind-a-wall test for characters stalls the frame on a GPU readback. Tests every 4m-th frame instead of every 4th above 60fps (m = fps/60, rounded down to 1, 2, 4, 8 or 16), so a result is as fresh as at stock 60fps, within 3% (targeting reads it).',
    sse       = 'The client skins characters on the CPU and only uses its SSE code when the CPU says Intel; this turns it on for other CPUs.',
    batch     = 'Text and UI draw one quad per call; consecutive quads with nothing changed between them become one draw. Same picture.',
    dedupe    = 'About 40% of the client\'s device calls set a value already in effect; these are dropped before they reach Ashita.',
};
-- A plain table: a T{} answers an unset field like exp.last with its own method.
local exp = {
    err     = {},       -- name -> why it could not be turned on
    on      = {},       -- name -> true
    ashita  = T{},      -- patched jumps { addr }
    occl    = nil,      -- { addr, m }
    sse     = nil,      -- { addr } of the flag byte we set, or { addr = nil } if it was on already
    proxy   = nil,      -- { base } kept allocated once made (a thread may still be in a thunk)
    dev     = nil,      -- client device object while the proxy is on
    vt      = nil,      -- its own vtable
    prev    = nil,      -- proxy counters a second ago { skipped, merged, batches }
    rate    = nil,      -- per second, same fields
    force   = false,    -- 'ashita' turned on although something uses the draw events
    dp      = nil,      -- the device wrapper's DrawPrimitive (for the plugin check)
    scan    = {},       -- addon name -> its uses of the draw events (cache)
    users   = nil,      -- what would lose the draw events: { 'addon x (...)', 'plugin y (...)' }
    checked = nil,      -- 'n addons and m plugins'
    notes   = nil,      -- what could not be checked
    sig     = nil,      -- loaded addons and plugins at the last check
};

--[[
* Settings, kept in <Ashita>\config\addons\hifps\settings.lua for all characters (frame rate is the
* machine's business, not a character's). What is saved is what you set: a toggle that could not be
* turned on, or that hifps turned off by itself, keeps its saved value. Saved toggles are turned on
* again once the game's device exists.
--]]
local prefs = { enabled = true, limit = 240, counter = true, exp = {}, ashita_force = false };
local restore_pending = false;

local function prefs_dir()
    local ok, root = pcall(function () return AshitaCore:GetInstallPath(); end);
    if (not ok or type(root) ~= 'string') then return nil; end
    return ('%sconfig\\addons\\%s'):fmt(root, addon.name);
end

local function load_prefs()
    local dir = prefs_dir();
    if (dir == nil) then return; end
    local file = dir .. '\\settings.lua';
    if (not ashita.fs.exists(file)) then return; end
    local chunk = loadfile(file);
    local ok, t = false, nil;
    if (chunk ~= nil) then
        setfenv(chunk, {});
        ok, t = pcall(chunk);
    end
    if (not ok or type(t) ~= 'table') then
        err(('Could not read %s; using the defaults.'):fmt(file));
        return;
    end
    if (type(t.enabled) == 'boolean') then prefs.enabled = t.enabled; end
    if (type(t.limit) == 'number') then prefs.limit = math.max(0, math.min(1000, math.floor(t.limit))); end
    if (type(t.counter) == 'boolean') then prefs.counter = t.counter; end
    if (type(t.ashita_force) == 'boolean') then prefs.ashita_force = t.ashita_force; end
    if (type(t.exp) == 'table') then
        for _, n in ipairs(EXP_NAMES) do prefs.exp[n] = (t.exp[n] == true) or nil; end
    end
end

local function save_prefs()
    local dir = prefs_dir();
    if (dir == nil) then return; end
    if (not ashita.fs.exists(dir)) then (ashita.fs.create_dir or ashita.fs.create_directory)(dir); end
    local lines = {
        '-- hifps settings, for all characters. hifps writes this file; change them with /hifps.',
        'return {',
        ('    enabled      = %s,     -- run above 60fps'):fmt(tostring(prefs.enabled)),
        ('    limit        = %d,      -- frame cap, 0 = none'):fmt(prefs.limit),
        ('    counter      = %s,     -- fps counter in the corner'):fmt(tostring(prefs.counter)),
        ('    ashita_force = %s,    -- keep \'ashita\' on even if an addon or plugin uses the draw events'):fmt(tostring(prefs.ashita_force)),
        '    exp = {                 -- experimental toggles',
    };
    for _, n in ipairs(EXP_NAMES) do
        lines[#lines + 1] = ('        %-9s = %s,'):fmt(n, tostring(prefs.exp[n] == true));
    end
    lines[#lines + 1] = '    },';
    lines[#lines + 1] = '};';
    local f = io.open(dir .. '\\settings.lua', 'w');
    if (f == nil) then
        err(('Could not write %s\\settings.lua.'):fmt(dir));
        return;
    end
    f:write(table.concat(lines, '\n'), '\n');
    f:close();
end

local function set_pref(k, v)
    if (prefs[k] == v) then return; end
    prefs[k] = v;
    save_prefs();
end

local function read_u32(a) return u32(ashita.memory.read_uint32(a)); end

-- The client's IDirect3DDevice8 (Ashita's wrapper object): [renderer + 8]. The renderer pointer's
-- address is found once.
local renderer_ptr = nil;
local function client_device()
    if (renderer_ptr == nil) then
        local p = ashita.memory.find(0, 0, '8BC8E8????????85C0A3????????0F84????????8B5C241C', 0, 0);
        if (p == 0) then return nil; end
        renderer_ptr = read_u32(p + 10);
    end
    local r = read_u32(renderer_ptr);
    if (r == 0) then return nil; end
    local dev = read_u32(r + 8);
    return dev ~= 0 and dev or nil;
end

local function match_at(t, i, pat)
    for k, b in ipairs(pat) do
        if (b ~= false and t[i + k - 1] ~= b) then return false; end
    end
    return true;
end

local function find_bytes(t, pat)
    for i = 1, #t - #pat + 1 do
        if (match_at(t, i, pat)) then return i; end
    end
    return nil;
end
local function at_u32(t, i) return t[i] + t[i + 1] * 256 + t[i + 2] * 65536 + t[i + 3] * 16777216; end
local function at_rel32(t, i) local v = at_u32(t, i); return v >= 0x80000000 and v - 4294967296 or v; end
local function readable(p, n) return p ~= 0 and ffi.C.IsBadReadPtr(ffi.cast('void*', p), n or 4) == 0; end
local function module_name(a)
    local h = ffi.new('void*[1]');
    if (ffi.C.GetModuleHandleExA(6, ffi.cast('void*', a), h) == 0) then return nil; end   -- FROM_ADDRESS | UNCHANGED_REFCOUNT
    local s = ffi.new('char[260]');
    local n = ffi.C.GetModuleFileNameA(h[0], s, 260);
    return ffi.string(s, n):match('([^\\/]+)$');
end
local function cstring(a)
    if (not readable(a, 48)) then return nil; end
    local s = {};
    for _, c in ipairs(ashita.memory.read_array(a, 48)) do
        if (c == 0) then break; end
        s[#s + 1] = string.char(c);
    end
    return #s > 0 and table.concat(s) or nil;
end
-- The constant a one-line function returns, read from its code (nothing is run):
-- 'mov eax, imm32; ret', 'push imm8; pop eax; ret' or 'xor eax, eax; ret'.
local function const_return(fn)
    if (not readable(fn, 8)) then return nil; end
    local b = ashita.memory.read_array(fn, 8);
    if (b[1] == 0xB8 and b[6] == 0xC3) then return at_u32(b, 2); end
    if (b[1] == 0x6A and b[3] == 0x58 and b[4] == 0xC3) then return b[2]; end
    if (b[1] == 0x33 and b[2] == 0xC0 and b[3] == 0xC3) then return 0; end
    return nil;
end
-- A plugin callback that only returns false ('xor al, al' or 'mov al, 0', then ret).
local function returns_false(fn)
    if (not readable(fn, 6)) then return false; end
    local b = ashita.memory.read_array(fn, 6);
    local zero = ((b[1] == 0x30 or b[1] == 0x31 or b[1] == 0x32 or b[1] == 0x33) and b[2] == 0xC0) or (b[1] == 0xB0 and b[2] == 0x00);
    return zero and (b[3] == 0xC2 or b[3] == 0xC3);
end

-- ashita: who would lose the draw events. Addons: the Lua files of the loaded ones that name one.
local DRAW_EVENTS = { 'd3d_dp', 'd3d_dip', 'd3d_dpup', 'd3d_dipup' };

local function file_draw_events(path)
    local f = io.open(path, 'r');
    if (f == nil) then return nil; end
    local hits, n = nil, 0;
    for line in f:lines() do
        n = n + 1;
        if (not line:match('^%s*%-%-')) then
            for _, e in ipairs(DRAW_EVENTS) do
                if (line:find("'" .. e .. "'", 1, true) or line:find('"' .. e .. '"', 1, true)) then
                    hits = hits or {};
                    hits[#hits + 1] = ('%s line %d uses %s'):fmt(path:match('([^\\/]+)$'), n, e);
                end
            end
        end
    end
    f:close();
    return hits;
end

-- Loaded addon names (other than hifps), or nil if Ashita doesn't say.
local function loaded_addons()
    local am = rawget(_G, 'AddonManager');
    if (am == nil) then return nil; end
    local ok, count = pcall(function () return am:Count(); end);
    if (not ok or type(count) ~= 'number') then return nil; end
    local list, seen = {}, {};
    for i = 0, count do
        local ok2, name = pcall(function () return am:Get(i); end);
        if (ok2 and type(name) == 'string' and name ~= '' and not seen[name:lower()] and name:lower() ~= addon.name) then
            seen[name:lower()] = true;
            list[#list + 1] = name;
        end
    end
    table.sort(list);
    return list;
end

-- An addon's uses of the draw events: { 'file line n uses d3d_x', ... }, cached per addon.
local function addon_draw_events(name)
    if (exp.scan[name] ~= nil) then return exp.scan[name]; end
    local am = rawget(_G, 'AddonManager');
    local ok, file = pcall(function () return am:GetFileName(name); end);
    if (not ok or type(file) ~= 'string' or file == '') then file = nil; end
    local dir = (file and file:match('^(.*)[\\/]')) or ('%saddons\\%s'):fmt(AshitaCore:GetInstallPath(), name);
    local paths, seen = {}, {};
    if (file ~= nil) then paths[1] = file; seen[file:lower()] = true; end
    for _, f in pairs(ashita.fs.get_directory(dir, '.*\\.lua$', true) or {}) do
        if (type(f) == 'string') then
            local p = f:match('^%a:[\\/]') and f or (dir .. '\\' .. f);
            if (not seen[p:lower()]) then
                seen[p:lower()] = true;
                paths[#paths + 1] = p;
            end
        end
    end
    local hits = {};
    for _, p in ipairs(paths) do
        for _, h in ipairs(file_draw_events(p) or {}) do hits[#hits + 1] = h; end
    end
    exp.scan[name] = hits;
    return hits;
end

-- Plugins: Ashita's plugin list, read the way its per-draw loop reads it (dp: the wrapper's
-- DrawPrimitive; the offsets come from the code it calls). Returns the names of plugins whose draw
-- callbacks do more than return false and how many plugins were checked, or nil and why. Only
-- reads memory; no plugin code is run.
local function plugin_draw_users(dp)
    if (not readable(dp, 0x60)) then return nil, 'unknown Ashita build'; end
    local w = ashita.memory.read_array(dp, 0x60);
    local i = find_bytes(w, { 0xE8, false, false, false, false, 0x83, 0xB8, false, false, false, false, 0x00, false });  -- call core; cmp [eax+..], 0; je (jmp while 'ashita' is on)
    local j = find_bytes(w, { 0x8B, 0x88, false, false, false, false, 0x85, 0xC9, 0x74 });                               -- mov ecx, [eax+pm]; test; je
    local k = find_bytes(w, { 0xE8, false, false, false, false, 0x84, 0xC0, 0x74 });                                     -- call the plugins' draw; test al, al
    if (i == nil or j == nil or k == nil) then return nil, 'unknown Ashita build'; end
    local getter = u32(dp + i - 1 + 5 + at_rel32(w, i + 1));
    local pmfn = u32(dp + k - 1 + 5 + at_rel32(w, k + 1));
    if (not readable(getter, 0x60) or not readable(pmfn, 0x160)) then return nil, 'unknown Ashita build'; end
    local g = ashita.memory.read_array(getter, 0x60);
    local f = ashita.memory.read_array(pmfn, 0x160);
    local c = find_bytes(g, { 0xB8, false, false, false, false, 0x8B, 0x4D, 0xF4 });                                     -- mov eax, offset core
    local h = find_bytes(f, { 0x8B, 0x46, false, 0xA8, 0x01 });                                                           -- mov eax, [esi+head]; test al, 1
    local x = find_bytes(f, { 0x38, 0x48, false });                                                                       -- cmp [eax+faulted], cl
    local p = find_bytes(f, { 0x8B, 0x48, false, 0x8B, 0x01, 0x8B, 0x40, false, 0xFF, 0xD0, 0xA8, 0x08 });                -- plugin; GetFlags; test al, 8
    local d = find_bytes(f, { 0x8B, 0x48, false, 0x8B, 0x01, 0x8B, 0x40, false, 0xFF, 0x75 });                            -- plugin; its DrawPrimitive
    local n = find_bytes(f, { 0x8B, 0x4E, false, 0x8B, 0x04, 0x08 });                                                     -- next = [entry + [esi+link]]
    if (c == nil or h == nil or x == nil or p == nil or d == nil or n == nil) then return nil, 'unknown Ashita build'; end
    local core, pmoff = at_u32(g, c + 1), at_u32(w, j + 2);
    local HEAD, FAULT, PLUG, FLAGS, DPOFF, LINK = f[h + 2], f[x + 2], f[p + 2], f[p + 7], f[d + 7], f[n + 2];
    if (not readable(core + pmoff, 4)) then return nil, 'no plugin manager'; end
    local pm = read_u32(core + pmoff);
    if (not readable(pm, math.max(HEAD, LINK) + 4)) then return nil, 'no plugin manager'; end
    local link = read_u32(pm + LINK);
    local e = read_u32(pm + HEAD);
    local users, checked = {}, 0;
    for _ = 1, 64 do
        if (e == 0 or e % 2 == 1 or link > 0x1000 or not readable(e, math.max(FAULT, PLUG, link) + 4)) then break; end
        if (ashita.memory.read_uint8(e + FAULT) == 0) then
            local plug = read_u32(e + PLUG);
            local vt = readable(plug, 4) and read_u32(plug) or 0;
            if (readable(vt, DPOFF + 16)) then
                checked = checked + 1;
                local name = cstring(const_return(read_u32(vt)) or 0) or module_name(vt) or ('plugin at %08X'):fmt(plug);
                local flags = const_return(read_u32(vt + FLAGS));
                local mod = (module_name(read_u32(vt + DPOFF)) or ''):lower();
                if (name:lower() ~= 'addons' and mod ~= 'addons.dll' and (flags == nil or bit.band(flags, 8) ~= 0)) then
                    for q = 0, 3 do
                        if (not returns_false(read_u32(vt + DPOFF + 4 * q))) then
                            users[#users + 1] = name;
                            break;
                        end
                    end
                end
            end
        end
        e = read_u32(e + link);
    end
    return users, checked;
end

-- Everything that would stop working with 'ashita' on (dp: the wrapper's DrawPrimitive):
-- users { 'addon x (...)', 'plugin y (...)' }, a summary of what was checked, and what could not be.
local function draw_event_users(dp)
    local users, notes = {}, {};
    local list = loaded_addons();
    if (list == nil) then
        notes[#notes + 1] = 'could not list the loaded addons';
    else
        for _, name in ipairs(list) do
            local hits = addon_draw_events(name);
            if (#hits > 0) then users[#users + 1] = ('addon %s (%s)'):fmt(name, table.concat(hits, ', ')); end
        end
    end
    local plugs, n = plugin_draw_users(dp);
    if (plugs == nil) then
        notes[#notes + 1] = ('could not check the plugins: %s'):fmt(n);
    else
        for _, name in ipairs(plugs) do users[#users + 1] = ('plugin %s (handles draw calls)'):fmt(name); end
    end
    return users, ('%s addons, %s plugins'):fmt(list and tostring(#list) or '?', plugs and tostring(n) or '?'), notes;
end

-- The loaded addons and plugins right now, to notice a change cheaply.
local function loaded_signature()
    local list = loaded_addons();
    local ok, np = pcall(function () return AshitaCore:GetPluginManager():Count(); end);
    return ('%s|%s'):fmt(list and table.concat(list, ',') or '?', ok and tostring(np) or '?');
end

-- ashita: in each of the wrapper's four draw methods, 'cmp dword [eax+10Ch], 0; je forward' decides
-- whether plugins see the draw. je -> jmp. Refuses if a loaded addon or plugin uses the draw events,
-- unless forced.
local ASHITA_PAT = { 0x83, 0xB8, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x74, false, 0x8B, 0x88, 0x34, 0x01, 0x00, 0x00, 0x85, 0xC9, 0x74 };
local function ashita_on()
    local dev = client_device();
    if (dev == nil) then return 'the client device was not found'; end
    local vt = exp.vt or read_u32(dev);
    local base, size = ashita.memory.get_base('Ashita.dll'), ashita.memory.get_size('Ashita.dll');
    if (base == 0) then return 'Ashita.dll was not found'; end
    local sites = T{};
    for slot = 70, 73 do
        local fn = read_u32(vt + 4 * slot);
        if (fn < base or fn >= base + size) then
            return ('draw method %d is at %08X, outside Ashita.dll (another addon hooks it)'):fmt(slot, fn);
        end
        local t = ashita.memory.read_array(fn, 0x60);
        local at = nil;
        for i = 1, #t - #ASHITA_PAT + 1 do
            if (match_at(t, i, ASHITA_PAT)) then at = fn + i - 1 + 7; break; end
        end
        if (at == nil) then return ('draw method %d doesn\'t look like the analysed Ashita (no plugin check found)'):fmt(slot); end
        sites:append(at);
    end
    exp.dp = read_u32(vt + 4 * 70);
    exp.scan = {};
    exp.users, exp.checked, exp.notes = draw_event_users(exp.dp);
    exp.sig = loaded_signature();
    if (#exp.users > 0 and not exp.force) then
        return ('it would break %s'):fmt(table.concat(exp.users, '; '));
    end
    for _, a in ipairs(sites) do
        if (not write_bytes(a, { 0xEB })) then return 'could not write Ashita.dll'; end
        exp.ashita:append(a);
    end
end
local function ashita_off()
    for _, a in ipairs(exp.ashita) do
        if (ashita.memory.read_uint8(a) == 0xEB) then write_bytes(a, { 0x74 }); end
    end
    exp.ashita = T{};
    exp.force = false;
end

-- While 'ashita' is on: when the loaded addons or plugins change, check them again. A newcomer that
-- uses the draw events turns it off (unless it was forced on).
local function ashita_watch()
    if (not exp.on.ashita or exp.dp == nil) then return; end
    local sig = loaded_signature();
    if (sig == exp.sig) then return; end
    exp.sig = sig;
    -- Forget unloaded addons, so one loaded again is read again; keep the rest (reading is slow).
    local now_loaded = {};
    for _, name in ipairs(loaded_addons() or {}) do now_loaded[name] = true; end
    for name in pairs(exp.scan) do
        if (not now_loaded[name]) then exp.scan[name] = nil; end
    end
    local users, checked, notes = draw_event_users(exp.dp);
    local had = {};
    for _, u in ipairs(exp.users or {}) do had[u] = true; end
    local new = {};
    for _, u in ipairs(users) do
        if (not had[u]) then new[#new + 1] = u; end
    end
    exp.users, exp.checked, exp.notes = users, checked, notes;
    if (#new == 0) then return; end
    if (exp.force) then
        err(('ashita (forced on): %s will not get its draw events.'):fmt(table.concat(new, '; ')));
        return;
    end
    exp.on.ashita = nil;
    ashita_off();
    exp.err.ashita = ('Turned off: %s needs the draw events.'):fmt(table.concat(new, '; '));
    err(('ashita turned off: %s needs the draw events. /hifps exp ashita force keeps it on anyway.'):fmt(table.concat(new, '; ')));
end

-- occlusion: at the rotation test 'and eax, 80000003h; jns; dec; or eax, -4; inc' (frame mod 4) the
-- actor's phase (0-3, edi) is compared with the frame; becomes 'and eax, 4m-1; shl edi, log2 m'.
local OCCL_PAT = '8BBEF0090000E8????????250300008079054883C8FC403BC7';
local OCCL_STOCK = { 0x25, 0x03, 0x00, 0x00, 0x80, 0x79, 0x05, 0x48, 0x83, 0xC8, 0xFC, 0x40 };
local function occl_bytes(m)
    local sh = math.floor(math.log(m) / math.log(2) + 0.5);
    return { 0x83, 0xE0, 4 * m - 1, 0xC1, 0xE7, sh, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
end
-- 3% slack: a frame limit of 120 measures as 119.9fps and should still count as 120.
local function occl_m()
    local m = 1;
    while (m < 16 and m * 2 <= state.fps * 1.03 / 60) do m = m * 2; end
    return m;
end
local function occl_set(m)
    if (exp.occl == nil or exp.occl.m == m) then return; end
    if (write_bytes(exp.occl.addr, occl_bytes(m))) then exp.occl.m = m; end
end
local function occlusion_on()
    local p = ashita.memory.find(0, 0, OCCL_PAT, 0, 0);
    if (p == 0) then return 'the occlusion test was not found (changed client, or another addon patched it)'; end
    local a = p + 11;
    local have = ashita.memory.read_array(a, #OCCL_STOCK);
    for i, b in ipairs(OCCL_STOCK) do
        if (have[i] ~= b) then return 'the occlusion test is not the stock code'; end
    end
    exp.occl = { addr = a, m = nil };
    occl_set(occl_m());
end
local function occlusion_off()
    if (exp.occl ~= nil) then write_bytes(exp.occl.addr, OCCL_STOCK); end
    exp.occl = nil;
end

-- sse: the CPU feature object (getter 'mov eax, [obj]; mov al, [eax+9]; ret'); +9 = SSE skinning.
local function sse_on()
    local p = ashita.memory.find(0, 0, 'A1????????8A4009C3', 0, 0);
    if (p == 0) then return 'the CPU feature flags were not found'; end
    local obj = read_u32(read_u32(p + 1));
    if (obj == 0) then return 'the CPU feature object does not exist yet'; end
    if (ashita.memory.read_uint8(obj + 9) ~= 0) then
        exp.sse = { addr = nil };
        msg('sse: the client already uses its SSE skinning on this CPU (Intel); nothing to change.');
        return;
    end
    ashita.memory.write_uint8(obj + 9, 1);
    exp.sse = { addr = obj + 9 };
end
local function sse_off()
    if (exp.sse ~= nil and exp.sse.addr ~= nil) then ashita.memory.write_uint8(exp.sse.addr, 0); end
    exp.sse = nil;
end

-- batch / dedupe: the device proxy.
local function psym(name) return exp.proxy.base + PROXY.sym[name]; end
local function proxy_flags()
    ashita.memory.write_uint8(psym('F_BATCH'), exp.on.batch and 1 or 0);
    ashita.memory.write_uint8(psym('F_DEDUPE'), exp.on.dedupe and 1 or 0);
end
local function proxy_make()
    local size = PROXY.size + 16 + PROXY_BUF;
    local base = ashita.memory.alloc(size);
    if (base == nil or base == 0) then return nil; end
    base = u32(base);
    ashita.memory.unprotect(base, size);
    local code = {};
    for i = 1, #PROXY.hex, 2 do code[#code + 1] = tonumber(PROXY.hex:sub(i, i + 1), 16); end
    ashita.memory.write_array(base, code);
    for _, r in ipairs(PROXY.relocs) do
        ashita.memory.write_uint32(base + r, (read_u32(base + r) + base) % 4294967296);
    end
    local buf = base + PROXY.size + 15 - (base + PROXY.size + 15) % 16;
    ashita.memory.write_uint32(base + PROXY.sym.D_BUF, buf);
    ashita.memory.write_uint32(base + PROXY.sym.D_BUFSIZE, PROXY_BUF);
    return { base = base };
end
local function proxy_on()
    if (exp.dev ~= nil) then proxy_flags(); return; end
    local dev = client_device();
    if (dev == nil) then return 'the client device was not found'; end
    if (exp.proxy == nil) then
        exp.proxy = proxy_make();
        if (exp.proxy == nil) then return 'could not allocate memory'; end
    end
    local vt = read_u32(dev);
    local orig, vtab, thunks = psym('ORIG'), psym('VTABLE'), psym('THUNK_TABLE');
    -- Fresh state: nothing known, nothing pending, counters at 0.
    local vs, ve = psym('VALID_START'), psym('VALID_END');
    local zero = {};
    for i = 1, ve - vs do zero[i] = 0; end
    ashita.memory.write_array(vs, zero);
    for _, n in ipairs({ 'D_PENDING', 'S_SKIPPED', 'S_MERGED', 'S_BATCHES' }) do ashita.memory.write_uint32(psym(n), 0); end
    ashita.memory.write_uint8(psym('F_REC'), 0);
    for i = 0, 127 do
        local f = read_u32(vt + 4 * i);
        local t = read_u32(thunks + 4 * i);
        ashita.memory.write_uint32(orig + 4 * i, f);
        ashita.memory.write_uint32(vtab + 4 * i, t ~= 0 and t or f);
    end
    ashita.memory.write_uint32(psym('VT_RTTI'), read_u32(vt - 4));
    proxy_flags();
    exp.dev, exp.vt, exp.prev, exp.rate = dev, vt, nil, nil;
    ashita.memory.write_uint32(dev, vtab);
end
local function proxy_off()
    if (exp.proxy == nil) then return; end
    proxy_flags();
    if (exp.on.batch or exp.on.dedupe or exp.dev == nil) then return; end
    -- Put the device's own vtable back unless something else has replaced ours since.
    if (read_u32(exp.dev) == psym('VTABLE')) then ashita.memory.write_uint32(exp.dev, exp.vt); end
    ashita.memory.write_uint32(psym('D_PENDING'), 0);
    exp.dev, exp.vt = nil, nil;
end

local EXP_ON = { ashita = ashita_on, occlusion = occlusion_on, sse = sse_on, batch = proxy_on, dedupe = proxy_on };
local EXP_OFF = { ashita = ashita_off, occlusion = occlusion_off, sse = sse_off, batch = proxy_off, dedupe = proxy_off };

-- Returns an error string, or nil.
local function exp_set(name, on)
    if (on == (exp.on[name] == true)) then return nil; end
    exp.on[name] = on or nil;
    local e = (on and EXP_ON or EXP_OFF)[name]();
    if (e ~= nil and on) then
        -- Undo whatever part of it was done.
        exp.on[name] = nil;
        EXP_OFF[name]();
    end
    return e;
end

local function exp_all_off()
    for _, n in ipairs(EXP_NAMES) do exp_set(n, false); end
end

-- Once a second from the present callback.
local function exp_tick()
    if (exp.occl ~= nil) then occl_set(occl_m()); end
    ashita_watch();
    if (exp.dev ~= nil) then
        local now_c = { read_u32(psym('S_SKIPPED')), read_u32(psym('S_MERGED')), read_u32(psym('S_BATCHES')) };
        if (exp.prev ~= nil) then
            exp.rate = { now_c[1] - exp.prev[1], now_c[2] - exp.prev[2], now_c[3] - exp.prev[3] };
        end
        exp.prev = now_c;
    end
end

-- What a toggle that is on is doing right now, or nil.
local function exp_stat(n)
    if (not exp.on[n]) then return nil; end
    if (n == 'ashita' and exp.checked ~= nil) then
        if (exp.force and #exp.users > 0) then
            return ('forced on: %d without their draw events'):fmt(#exp.users);
        end
        return ('nothing uses the draw events (%s)'):fmt(exp.checked);
    elseif (n == 'occlusion' and exp.occl ~= nil) then
        return ('every %d frames at %.0f fps'):fmt(4 * (exp.occl.m or 1), state.fps);
    elseif (n == 'sse' and exp.sse ~= nil and exp.sse.addr == nil) then
        return 'already on (Intel CPU)';
    elseif (exp.rate ~= nil and state.fps > 0) then
        if (n == 'batch') then return ('%.0f quads a frame in %.0f draws'):fmt(exp.rate[2] / state.fps, exp.rate[3] / state.fps); end
        if (n == 'dedupe') then return ('%.0f calls a frame dropped'):fmt(exp.rate[1] / state.fps); end
    end
    return nil;
end

-- Turns a toggle on or off and says so (quiet: only failures, for the config window).
-- force: turn 'ashita' on even if something uses the draw events.
-- restoring: turning saved toggles back on at load; the saved values are left as they are.
local function exp_toggle(n, on, quiet, force, restoring)
    if (n == 'ashita' and on) then
        if (force) then
            exp.force = true;
        elseif (not exp.on.ashita) then
            exp.force = false;
        end
    end
    local e = exp_set(n, on);
    exp.err[n] = e and ('Not turned on: %s.'):fmt(e) or nil;
    if (not restoring and (e == nil or not on)) then
        prefs.exp[n] = exp.on[n] or nil;
        if (n == 'ashita') then prefs.ashita_force = exp.on.ashita == true and exp.force == true; end
        save_prefs();
    end
    if (e ~= nil) then
        local hint = (n == 'ashita' and exp.users ~= nil and #exp.users > 0) and ' /hifps exp ashita force turns it on anyway.' or '';
        err(('%s: not turned on: %s.%s'):fmt(n, e, hint));
    elseif (not quiet) then
        msg(('%s %s: %s.'):fmt(n, exp.on[n] and 'on' or 'off', EXP_DESC[n]));
        if (n == 'ashita' and on and exp.checked ~= nil) then
            if (exp.force and #exp.users > 0) then
                err(('ashita forced on: %s will not get its draw events.'):fmt(table.concat(exp.users, '; ')));
            else
                msg(('ashita: checked %s; nothing uses the draw events.'):fmt(exp.checked));
            end
            for _, note in ipairs(exp.notes or {}) do err('ashita: ' .. note .. '.'); end
        end
    end
end

-- Turns the saved toggles back on (from the present callback, once the client's device exists).
local function restore_exp()
    if (client_device() == nil) then return; end
    restore_pending = false;
    local done = {};
    for _, n in ipairs(EXP_NAMES) do
        if (prefs.exp[n] and not exp.on[n]) then
            exp_toggle(n, true, true, n == 'ashita' and prefs.ashita_force, true);
            if (exp.on[n]) then done[#done + 1] = n; end
        end
    end
    if (#done > 0) then msg(('Saved experimental toggles back on: %s.'):fmt(table.concat(done, ', '))); end
end

-- /hifps exp ashita check: what uses the draw events, without changing anything.
local function ashita_check()
    local dev = client_device();
    if (dev == nil) then err('ashita check: the client device was not found.'); return; end
    local dp = read_u32((exp.vt or read_u32(dev)) + 4 * 70);
    exp.scan = {};
    local users, checked, notes = draw_event_users(dp);
    if (#users == 0) then
        msg(('ashita check: %s checked; nothing uses the draw events.'):fmt(checked));
    else
        err(('ashita check: %s checked; these use the draw events: %s.'):fmt(checked, table.concat(users, '; ')));
    end
    for _, note in ipairs(notes) do err('ashita check: ' .. note .. '.'); end
end

local function exp_report()
    for _, n in ipairs(EXP_NAMES) do
        local s = exp_stat(n);
        msg(('  %-9s %s  %s%s'):fmt(n, exp.on[n] and 'ON ' or 'off', EXP_DESC[n], s and (' (%s)'):fmt(s) or ''));
    end
end

local function disable()
    exp_all_off();
    for _, l in ipairs(state.smooth) do
        ashita.memory.write_array(l.addr, l.backup);
        ashita.memory.protect(l.addr, 4, l.prot);
    end
    state.smooth = T{};
    -- Operands: restore only the ones that still point at our slot. If another addon holds one, it
    -- may write our slot address back into the code when it unloads, so keep our memory alive with
    -- the stock values in the slots.
    local keep_mem = false;
    for _, o in ipairs(state.ops) do
        local d = bit.tobit(ashita.memory.read_uint32(o.addr));
        if (d == bit.tobit(o.slot)) then
            write_bytes(o.addr, le32(o.const));
        elseif (d ~= o.const) then
            keep_mem = true;
        end
    end
    if (keep_mem) then
        for _, o in ipairs(state.ops) do ashita.memory.write_float(o.slot, o.v); end
    end
    state.ops = T{};
    if (state.pulse ~= nil) then
        write_bytes(state.pulse.addr + 1, state.pulse.backup);
        state.pulse = nil;
    end
    for _, s in ipairs(state.sites) do
        if (s.patched) then write_bytes(s.addr + 1, s.backup); end
    end
    state.sites = T{};
    for _, g in ipairs(state.getters) do
        write_bytes(g.addr, g.backup);
    end
    state.getters = T{};
    if (state.div_orig ~= nil) then set_divisor(state.div_orig); state.div_orig = nil; end
    if (state.mem ~= nil) then
        if (not keep_mem) then ashita.memory.dealloc(state.mem); end
        state.mem = nil;
    end
    state.bisect, state.hunt = nil, nil;
end

-- The sites a bisect has on the 1.0 stub: the first half of the candidates left (b.list[b.lo..b.hi],
-- site numbers), the last one while it's checked, or all of them (b.all).
local function bisect_set(b)
    local set = {};
    if (b ~= nil) then
        local hi = b.confirm and b.lo or b.all and b.hi or math.floor((b.lo + b.hi) / 2);
        for k = b.lo, hi do set[b.list[k]] = true; end
    end
    return set;
end

-- Points every site at its normal target, except the bisect's, which get the 1.0 stub.
local function apply_targets()
    local set = bisect_set(state.bisect);
    for i, s in ipairs(state.sites) do
        local t = (s.kind == 'f') and state.g_frac or (s.kind == 's') and state.stub or state.g_int;
        if (set[i]) then t = state.stub; end
        if (not point_site(s, t)) then return false; end
        s.patched = true;
    end
    return true;
end

local function enable()
    local f = ffi.new('int64_t[1]');
    ffi.C.QueryPerformanceFrequency(f);
    state.freq = tonumber(f[0]);

    -- Frame step getter: mov ecx,[obj]; fld [ecx+28]; fcomp [1.0]; fnstsw ax; test ah,5; jp +7; fld [1.0]; ret; fld [ecx+28]; ret
    local pat = '8B0D????????D94128D81D????????DFE0F6C4057A07D905????????C3D94128C3';
    local addrs = T{};
    for i = 0, 3 do
        local a = ashita.memory.find(0, 0, pat, 0, i);
        if (a == 0) then break; end
        addrs:append(bit.tobit(a));
    end
    table.sort(addrs);
    if (#addrs ~= 2) then
        err(('Expected 2 frame step getters, found %d; not patching.'):fmt(#addrs));
        return false;
    end

    state.div_ptr = find_divisor();
    if (state.div_ptr == nil) then
        err('Could not find the fps divisor; not patching.');
        return false;
    end

    -- Check every call site before touching anything.
    local base = ashita.memory.get_base('FFXiMain.dll');
    local sites = T{};
    local function add(list, kind)
        for _, rva in ipairs(list) do
            local a = base + rva;
            local t = (ashita.memory.read_uint8(a) == 0xE8) and call_target(a) or nil;
            if (t ~= addrs[1] and t ~= addrs[2]) then
                err(('Call site %08X does not call the step getter; client differs from the analysed one. Not patching.'):fmt(a));
                return false;
            end
            sites:append({ addr = a, kind = kind, backup = ashita.memory.read_array(a + 1, 4), target = t, patched = false });
        end
        return true;
    end
    if (not add(FRAC_SITES, 'f') or not add(INT_SITES, 'i') or not add(STOCK_SITES, 's')) then return false; end
    local smooth = T{};
    local ops = T{};
    for _, l in ipairs(SMOOTH_LOOPS) do
        -- Check the loop's constants first. If something else (e.g. another addon) already changed
        -- one, leave this loop on whole ticks instead of refusing to load.
        local bad = nil;
        local l_smooth, l_ops = T{}, T{};
        if (l.imm ~= nil) then
            local a = base + l.imm;
            local kb = ffi.new('float[1]', l.k);
            local want = ffi.string(ffi.cast('const char*', kb), 4);
            local have = ffi.string(ffi.cast('const char*', a), 4);
            local pre = l.pre or { 0x68 };
            local ok = (have == want);
            for i, b in ipairs(pre) do
                if (ashita.memory.read_uint8(a - #pre + i - 1) ~= b) then ok = false; end
            end
            if (not ok) then
                bad = a - #pre;
            else
                l_smooth:append({ addr = a, k = l.k, backup = ashita.memory.read_array(a, 4) });
            end
        end
        local detail = nil;
        if (bad ~= nil) then
            local f = ashita.memory.read_array(bad, #(l.pre or { 0x68 }) + 4);
            local hex = T{};
            for _, b in ipairs(f) do hex:append(('%02X'):fmt(b)); end
            detail = 'found ' .. hex:concat(' ');
        end
        for _, o in ipairs(l.ops or {}) do
            local a = base + o.at;
            local c = bit.tobit(base + o.const);
            if (bad == nil) then
                local d = bit.tobit(ashita.memory.read_uint32(a));
                if (ashita.memory.read_uint8(a - 2) ~= 0xD8) then
                    local f = ashita.memory.read_array(a - 2, 6);
                    bad, detail = a - 2, ('found %02X %02X %02X %02X %02X %02X'):fmt(f[1], f[2], f[3], f[4], f[5], f[6]);
                elseif (d ~= c and not step_invariant(o.mode, ashita.memory.read_float(u32(d)))) then
                    -- Redirected by another addon to a value that depends on the frame rate.
                    bad, detail = a - 2, ('value %g'):fmt(ashita.memory.read_float(u32(d)));
                else
                    l_ops:append({ addr = a, const = c, v = ashita.memory.read_float(u32(c)), mode = o.mode, name = l.name, effect = l.effect });
                end
            end
        end
        if (bad ~= nil) then
            loop_warning(l.name, l.effect, bad, detail);
            if (not add(l.sites, l.fallback or 'i')) then return false; end
        else
            if (not add(l.sites, 's')) then return false; end
            for _, x in ipairs(l_smooth) do smooth:append(x); end
            for _, x in ipairs(l_ops) do ops:append(x); end
        end
    end
    if (#ops > MAX_OPS) then err('Too many operand patches.'); return false; end

    -- Our memory: two step floats, and an executable stub "fld dword [1.0]; ret" for bisecting.
    -- +32: one float slot per redirected operand. Then the name pulse's tick count (u32) and its
    -- getter "mov eax, [count]; ret".
    local memsize = PULSE_OFF + 16;
    state.mem = ashita.memory.alloc(memsize);
    if (state.mem == nil or state.mem == 0) then
        err('Could not allocate memory; not patching.');
        return false;
    end
    ashita.memory.unprotect(state.mem, memsize);
    ashita.memory.write_float(state.mem, 1.0);
    ashita.memory.write_float(state.mem + 4, 1.0);
    ashita.memory.write_float(state.mem + 24, 1.0);
    local c = le32(state.mem + 24);
    ashita.memory.write_array(state.mem + 16, { 0xD9, 0x05, c[1], c[2], c[3], c[4], 0xC3 });
    state.stub = bit.tobit(state.mem + 16);
    state.accum = 0;

    -- New getter bodies: fld dword ptr [mem + 0 / 4]; ret
    for i, g in ipairs(addrs) do
        local a = le32(state.mem + (i - 1) * 4);
        local body = { 0xD9, 0x05, a[1], a[2], a[3], a[4], 0xC3 };
        local backup = ashita.memory.read_array(g, #body);
        if (not write_bytes(g, body)) then
            err('Failed to write patch; restoring.');
            disable();
            return false;
        end
        state.getters:append({ addr = g, backup = backup });
    end
    state.g_frac, state.g_int = addrs[1], addrs[2];

    state.sites = sites;
    for _, l in ipairs(smooth) do
        local ok, prot = ashita.memory.unprotect(l.addr, 4);
        if (not ok) then
            err('Failed to unprotect a smoothing constant; restoring.');
            disable();
            return false;
        end
        l.prot = prot;
        state.smooth:append(l);
    end
    for i, o in ipairs(ops) do
        o.slot = u32(state.mem + 32 + (i - 1) * 4);
        ashita.memory.write_float(o.slot, o.v);
        state.ops:append(o);
        -- Take over only operands that still point at the game's constant; leave other addons' alone.
        if (bit.tobit(ashita.memory.read_uint32(o.addr)) == o.const) then
            if (not write_bytes(o.addr, le32(o.slot))) then
                err('Failed to redirect an operand; restoring.');
                disable();
                return false;
            end
        end
    end
    if (not apply_targets()) then
        err('Failed to redirect a call; restoring.');
        disable();
        return false;
    end
    patch_pulse();

    state.div_orig = ashita.memory.read_uint32(state.div_ptr);
    set_divisor(0);
    state.last = now();
    state.fps_timer = state.last;
    msg(('Enabled. %d call sites, limit %s.'):fmt(#state.sites, state.limit > 0 and tostring(state.limit) or 'none'));
    return true;
end

local KIND = { f = 'fractional', i = 'whole-tick', s = 'smoothing-loop' };

local function site_text(i)
    local s = state.sites[i];
    return ('site #%d at %08X (offset %06X, %s step)'):fmt(i, s.addr, s.addr - ashita.memory.get_base('FFXiMain.dll'), KIND[s.kind] or s.kind);
end

local function bisect_report()
    local b = state.bisect;
    if (b.lo == b.hi) then
        -- One left: only it on the stub, and one more test before it's named (if the bug was never
        -- gone, every answer was 'broken' and this is just the last site).
        b.confirm = true;
        apply_targets();
        msg(('Narrowed to %s. Only it is on the 1.0 stub now: test once more, then /hifps bisect fixed (bug gone) or /hifps bisect broken (still there).'):fmt(site_text(b.list[b.lo])));
        return;
    end
    local mid = math.floor((b.lo + b.hi) / 2);
    msg(('Round %d: %d candidates left, %d of them back to stock behaviour. Test the bug, then type /hifps bisect fixed (bug gone) or /hifps bisect broken (bug still there).'):fmt(
        b.round, b.hi - b.lo + 1, mid - b.lo + 1));
end

-- The game's private memory in bytes (committed on Windows; resident heap plus swap under Wine), or
-- nil if it can't be read.
local pmc = nil;
state.read_memory = function ()
    local ok, v = pcall(function ()
        pmc = pmc or ffi.new('hifps_pmc');
        pmc.cb = ffi.sizeof('hifps_pmc');
        if (ffi.C.K32GetProcessMemoryInfo(ffi.C.GetCurrentProcess(), pmc, pmc.cb) == 0) then
            return nil;
        end
        return tonumber(pmc.PagefileUsage);
    end);
    return ok and v or nil;
end;

-- How fast the game's memory grew since time `since` (MB a minute, a least-squares line through the
-- samples), or nil with too few samples.
local function slope(since)
    local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0;
    for _, s in ipairs(state.samples) do
        if (s[1] >= since) then
            local x, y = s[1] - since, s[2] / 1048576;
            n, sx, sy, sxx, sxy = n + 1, sx + x, sy + y, sxx + x * x, sxy + x * y;
        end
    end
    local d = n * sxx - sx * sx;
    if (n < 5 or d <= 0) then
        return nil;
    end
    return (n * sxy - sx * sy) / d * 60;
end

-- The sites a bisect can change (the smoothing-loop sites are on the stub anyway).
local function bisect_list()
    local list = {};
    for i, s in ipairs(state.sites) do
        if (s.kind ~= 's') then list[#list + 1] = i; end
    end
    return list;
end

-- Your character's position, or nil.
local function my_pos()
    local ok, x, y, z = pcall(function ()
        local mm = AshitaCore:GetMemoryManager();
        local i = mm:GetParty():GetMemberTargetIndex(0);
        local ent = mm:GetEntity();
        return ent:GetLocalPositionX(i), ent:GetLocalPositionY(i), ent:GetLocalPositionZ(i);
    end);
    if (not ok or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number') then
        return nil;
    end
    return { x, y, z };
end

--[[
* The leak hunt: measures how fast the game's memory grows for HUNT_WINDOW seconds at a time (after
* HUNT_SETTLE) with every site as usual, then with every candidate on the stub, then bisects the
* candidates, deciding 'fixed' or 'broken' itself: a round counts as fixed when the growth is nearer
* the all-on-the-stub rate than the usual one. Runs once a second from present.
--]]
local HUNT_WINDOW, HUNT_SETTLE, HUNT_MIN = 60, 5, 3.0;

local function hunt_end(text)
    state.hunt, state.bisect = nil, nil;
    apply_targets();
    msg(text);
end

local function hunt_step(t)
    local h = state.hunt;
    if (h == nil) then
        return;
    end
    local p = my_pos();
    if (p == nil or math.abs(p[1] - h.pos[1]) + math.abs(p[2] - h.pos[2]) + math.abs(p[3] - h.pos[3]) > 1) then
        hunt_end('Leak hunt stopped: your character moved or zoned. Sites on the 1.0 stub run the game fast above 60fps, your movement too, so stand still for the whole hunt. All sites are back to the hifps behaviour.');
        return;
    end
    if (t < h.t0 + HUNT_WINDOW) then
        return;
    end
    local s = slope(h.t0);
    if (s == nil) then
        hunt_end('Leak hunt stopped: the game\'s memory couldn\'t be read.');
        return;
    end
    local b = state.bisect;
    if (h.phase == 'base') then
        if (s < HUNT_MIN) then
            hunt_end(('Leak hunt: the game\'s memory grew %.1f MB a minute at %.0f fps with every site as usual, so there\'s no leak here to hunt.'):fmt(s, state.fps));
            return;
        end
        local list = bisect_list();
        h.base, h.phase = s, 'floor';
        state.bisect = { list = list, lo = 1, hi = #list, round = 1, all = true };
        apply_targets();
        msg(('Leak hunt: %.1f MB a minute as usual (%.0f fps). Next minute: all %d call sites on the 1.0 stub.'):fmt(s, state.fps, #list));
    elseif (h.phase == 'floor') then
        if (h.base - s < HUNT_MIN or s > h.base * 0.6) then
            hunt_end(('Leak hunt: with all %d call sites on the stub the game\'s memory still grew %.1f MB a minute (%.1f as usual, %.0f fps), so it isn\'t one of them. It comes with the frame rate itself: something that leaks a little every frame (the renderer, an addon or a plugin) or hifps\'s per-frame loops. All sites are back to the hifps behaviour. Tell Claude these numbers.'):fmt(
                #b.list, s, h.base, state.fps));
            return;
        end
        h.floor, h.cut, h.phase = s, (h.base + s) / 2, 'round';
        b.all = nil;
        apply_targets();
        msg(('Leak hunt: %.1f MB a minute with all of them on the stub, so it\'s a call site. Round 1 of about %d: half of them on the stub.'):fmt(
            s, math.ceil(math.log(#b.list) / math.log(2)) + 1));
    elseif (h.phase == 'round') then
        local gone = s < h.cut;
        local mid = math.floor((b.lo + b.hi) / 2);
        if (gone) then b.hi = mid; else b.lo = mid + 1; end
        b.round = b.round + 1;
        if (b.lo == b.hi) then
            b.confirm, h.phase = true, 'confirm';
            apply_targets();
            msg(('Leak hunt: %.1f MB a minute (%s). Narrowed to %s: measuring it alone on the stub.'):fmt(
                s, gone and 'gone' or 'still there', site_text(b.list[b.lo])));
        else
            apply_targets();
            msg(('Leak hunt: %.1f MB a minute (%s). Round %d: %d candidates left.'):fmt(
                s, gone and 'gone' or 'still there', b.round, b.hi - b.lo + 1));
        end
    else
        local site = site_text(b.list[b.lo]);
        if (s < h.cut) then
            hunt_end(('Found it: %s. Alone on the stub the game\'s memory grew %.1f MB a minute; %.1f with every site as usual, %.1f with all on the stub (%.0f fps). All sites are back to the hifps behaviour (so the leak is too). Tell Claude this address and these numbers.'):fmt(
                site, s, h.base, h.floor, state.fps));
        else
            hunt_end(('Leak hunt: not a single call site (still %.1f MB a minute with only %s on the stub; %.1f as usual, %.1f with all on the stub). It may take two or more sites together. All sites are back to the hifps behaviour. Tell Claude these numbers.'):fmt(
                s, site, h.base, h.floor));
        end
        return;
    end
    h.t0 = t + HUNT_SETTLE;
end

-- The config window (/hifps). Drawn while hifps is off too, so it can be turned back on here.
local GUI_W = 400;
local gui = { open = { false } };
local GREEN, RED = { 0.55, 0.9, 0.55, 1.0 }, { 1.0, 0.45, 0.45, 1.0 };

-- A '(?)' after the last item; text shows as a tooltip while either is hovered.
local function help(text)
    local hot = imgui.IsItemHovered();
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if (hot or imgui.IsItemHovered()) then
        imgui.BeginTooltip();
        imgui.PushTextWrapPos(320);
        imgui.Text(text);
        imgui.PopTextWrapPos();
        imgui.EndTooltip();
    end
end

local function draw_config()
    if (not gui.open[1]) then return; end
    imgui.SetNextWindowSize({ GUI_W, 0 }, ImGuiCond_Always);
    if (imgui.Begin(('hifps %s###hifps_config'):fmt(addon.version), gui.open, bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoResize))) then
        imgui.PushTextWrapPos(GUI_W - 16);
        local on = state.mem ~= nil;

        local v = { on };
        if (imgui.Checkbox('Run above 60fps##hifps_on', v)) then
            if (v[1]) then
                if (enable()) then restore_pending = true; end
            else
                disable();
                msg('Disabled; original code and divisor restored.');
            end
            set_pref('enabled', v[1]);
            on = state.mem ~= nil;
        end
        imgui.SameLine();
        if (on) then
            imgui.TextColored(GREEN, ('%.0f fps, step %.2f ticks'):fmt(state.fps, state.step));
        else
            imgui.TextDisabled('off: the game runs at its stock 30/60fps');
        end

        imgui.PushItemWidth(100);
        local lim = { state.limit };
        if (imgui.InputInt('Frame limit##hifps_limit', lim, 10, 30)) then
            state.limit = math.max(0, math.min(1000, lim[1]));
            set_pref('limit', state.limit);
        end
        imgui.PopItemWidth();
        help('hifps caps the frame rate here; 0 or none: no cap from hifps (vsync or the driver may still cap). While a cap holds, the experimental options free frame time instead of raising the number.');
        for i, p in ipairs({ 60, 120, 144, 165, 240, 0 }) do
            if (i > 1) then imgui.SameLine(); end
            if (imgui.SmallButton(p > 0 and ('%d##hifps_l%d'):fmt(p, p) or 'none##hifps_l0')) then
                state.limit = p;
                set_pref('limit', p);
            end
        end

        local c = { state.counter };
        if (imgui.Checkbox('FPS counter in the top-left corner##hifps_counter', c)) then
            state.counter = c[1];
            set_pref('counter', c[1]);
        end

        imgui.SeparatorText('Experimental (off by default)');
        if (not on) then
            imgui.TextDisabled('Turn hifps on to use these.');
            imgui.BeginDisabled();
        end
        for _, n in ipairs(EXP_NAMES) do
            local t = { exp.on[n] == true };
            if (imgui.Checkbox(('%s##hifps_exp_%s'):fmt(EXP_LABEL[n], n), t)) then exp_toggle(n, t[1], true); end
            help(EXP_HINT[n]);
            imgui.Indent(28);
            local s = exp_stat(n);
            if (s ~= nil) then imgui.TextColored(GREEN, s); end
            if (exp.err[n] ~= nil) then imgui.TextColored(RED, exp.err[n]); end
            if (n == 'ashita') then
                if (exp.force and exp.on.ashita and exp.users ~= nil and #exp.users > 0) then
                    imgui.TextColored(RED, 'Without their draw events: ' .. table.concat(exp.users, '; '));
                end
                for _, note in ipairs(exp.notes or {}) do imgui.TextDisabled('Note: ' .. note .. '.'); end
                if (not exp.on.ashita and exp.users ~= nil and #exp.users > 0) then
                    if (imgui.SmallButton('Turn on anyway##hifps_ashita_force')) then exp_toggle('ashita', true, true, true); end
                    imgui.SameLine();
                end
                if (imgui.SmallButton('Check now##hifps_ashita_check')) then ashita_check(); end
            end
            imgui.Unindent(28);
        end
        imgui.Spacing();
        if (imgui.Button('All on##hifps_allon')) then
            for _, n in ipairs(EXP_NAMES) do exp_toggle(n, true, true); end
        end
        imgui.SameLine();
        if (imgui.Button('All off##hifps_alloff')) then
            for _, n in ipairs(EXP_NAMES) do exp_toggle(n, false, true); end
        end
        if (not on) then imgui.EndDisabled(); end
        imgui.TextDisabled('Saved for all characters (config\\addons\\hifps\\settings.lua).');
        imgui.PopTextWrapPos();
    end
    imgui.End();
end

ashita.events.register('load', 'load_cb', function ()
    load_prefs();
    state.limit, state.counter = prefs.limit, prefs.counter;
    if (prefs.enabled) then
        if (enable()) then restore_pending = true; end
    else
        msg('Off, as saved. /hifps opens the settings.');
    end
end);

ashita.events.register('unload', 'unload_cb', function ()
    disable();
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    draw_config();
    if (state.mem == nil) then return; end
    if (restore_pending) then restore_exp(); end

    -- Frame limiter: sleep most of the remaining time, then spin.
    if (state.limit > 0) then
        local target = state.last + 1.0 / state.limit;
        local t = now();
        local remain = target - t;
        if (remain > 0.002) then
            ffi.C.Sleep(math.floor((remain - 0.0015) * 1000));
        end
        while (now() < target) do end
    end

    local t = now();
    local dt = t - state.last;
    state.last = t;

    local step = math.max(MIN_STEP, math.min(MAX_STEP, dt * 60.0));
    state.step = step;
    ashita.memory.write_float(state.mem, step);

    -- Whole ticks for the callers that truncate; the remainder carries to the next frame.
    state.accum = state.accum + step;
    local whole = math.floor(state.accum);
    state.accum = state.accum - whole;
    ashita.memory.write_float(state.mem + 4, whole);
    -- The name pulse counts the same whole ticks: 60 a second at any frame rate.
    if (state.pulse ~= nil) then
        state.ticks = (state.ticks + whole) % 4294967296;
        ashita.memory.write_uint32(state.mem + PULSE_OFF, state.ticks);
    end

    -- Smoothing loops run once per frame; scale their factor to this frame's step.
    for _, l in ipairs(state.smooth) do
        ashita.memory.write_float(l.addr, 1.0 - math.pow(1.0 - l.k, step));
    end
    for _, o in ipairs(state.ops) do
        local v = o.v * step;
        local m = math.abs(o.v);
        if (o.mode == 'ease' and m > 0 and m < 1) then
            v = (1.0 - math.pow(1.0 - m, step)) * (o.v < 0 and -1 or 1);
        elseif (o.mode == 'pow') then
            v = o.v > 0 and math.pow(o.v, step) or o.v;
        end
        ashita.memory.write_float(o.slot, v);
        -- Another addon may have redirected this operand since, or handed it back.
        local d = bit.tobit(ashita.memory.read_uint32(o.addr));
        if (d == o.const) then
            write_bytes(o.addr, le32(o.slot));
            o.warned = false;
        elseif (d ~= bit.tobit(o.slot) and not o.warned and not step_invariant(o.mode, ashita.memory.read_float(u32(d)))) then
            loop_warning(o.name, o.effect, o.addr - 2, ('value %g'):fmt(ashita.memory.read_float(u32(d))));
            o.warned = true;
        end
    end

    state.frames = state.frames + 1;

    -- The game's memory, once a second (for /hifps mem and the leak hunt).
    if (t - state.sample_t >= 1) then
        state.sample_t = t;
        local b = state.read_memory();
        if (b ~= nil) then
            state.samples:append({ t, b });
            if (#state.samples > 200) then
                table.remove(state.samples, 1);
            end
        end
        hunt_step(t);
    end
    if (t - state.fps_timer >= 1.0) then
        state.fps = state.frames / (t - state.fps_timer);
        state.frames = 0;
        state.fps_timer = t;
        exp_tick();
    end

    if (state.counter) then
        -- Small box hugging the top-left corner: tight padding, no rounding or border, no min size.
        imgui.SetNextWindowPos({ 0, 0 }, ImGuiCond_Always);
        imgui.SetNextWindowBgAlpha(0.5);
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 3, 0 });
        imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 });
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
        local flags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoSavedSettings,
            ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoInputs);
        if (imgui.Begin('hifps_counter', true, flags)) then
            imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * 0.8);
            imgui.Text(('%.0f'):fmt(state.fps));
            imgui.PopFont();
        end
        imgui.End();
        imgui.PopStyleVar(4);
    end
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/hifps') then return; end
    e.blocked = true;

    if (#args == 1 or args[2] == 'config' or args[2] == 'gui') then
        gui.open[1] = not gui.open[1];
        return;
    end

    if (#args >= 3 and args[2] == 'limit') then
        state.limit = math.max(0, math.min(1000, args[3]:number_or(240)));
        set_pref('limit', state.limit);
        msg(('Frame limit set to %s.'):fmt(state.limit > 0 and tostring(state.limit) or 'none'));
        return;
    end
    if (#args >= 2 and args[2] == 'counter') then
        state.counter = not state.counter;
        set_pref('counter', state.counter);
        msg(('FPS counter %s.'):fmt(state.counter and 'shown' or 'hidden'));
        return;
    end
    if (#args >= 2 and args[2] == 'off') then
        disable();
        set_pref('enabled', false);
        msg('Disabled; original code and divisor restored.');
        return;
    end
    if (#args >= 2 and args[2] == 'on') then
        if (state.mem == nil and enable()) then restore_pending = true; end
        set_pref('enabled', true);
        return;
    end

    if (#args >= 2 and args[2] == 'exp') then
        if (#args == 2) then
            msg('Experimental frame-time toggles (off by default, saved; /hifps exp <name|all> [on|off], /hifps exp ashita check|force):');
            exp_report();
            return;
        end
        if (state.mem == nil) then err('Enable hifps first (/hifps on).'); return; end
        if (args[3] == 'ashita' and args[4] == 'check') then ashita_check(); return; end
        if (args[3] == 'ashita' and args[4] == 'force') then exp_toggle('ashita', true, false, true); return; end
        local names = (args[3] == 'all') and EXP_NAMES or { args[3] };
        if (EXP_DESC[names[1]] == nil) then
            err(('Unknown toggle "%s". Toggles: %s, all.'):fmt(args[3], table.concat(EXP_NAMES, ', ')));
            return;
        end
        for _, n in ipairs(names) do
            local want = (args[4] == 'on') or (args[4] ~= 'off' and not exp.on[n]);
            if (args[3] == 'all') then want = (args[4] ~= 'off'); end
            exp_toggle(n, want);
        end
        return;
    end

    if (#args >= 2 and args[2] == 'mem') then
        local b = state.read_memory();
        local s = slope(now() - 60);
        msg(('The game\'s memory: %s, %s over the last minute at %.0f fps. hifps\'s own Lua: %.0f KB.%s'):fmt(
            b ~= nil and ('%.0f MB'):fmt(b / 1048576) or 'unreadable',
            s ~= nil and ('%+.1f MB a minute'):fmt(s) or 'not enough samples yet',
            state.fps, collectgarbage('count'), state.hunt ~= nil and ' A leak hunt is running.' or ''));
        return;
    end

    if (#args >= 3 and args[2] == 'leak') then
        if (args[3] == 'start') then
            if (state.mem == nil) then err('Enable hifps first.'); return; end
            if (state.read_memory() == nil) then
                err('The game\'s memory can\'t be read here.');
                return;
            end
            local pos = my_pos();
            if (pos == nil) then
                err('Your position can\'t be read; log in first.');
                return;
            end
            if (state.fps < 70) then
                err(('The frame rate is %.0f; the leak shows above 60fps. Raise it (/hifps limit 120, or 0 for none) and start again.'):fmt(state.fps));
                return;
            end
            local n = #bisect_list();
            state.bisect = nil;
            apply_targets();
            state.hunt = { phase = 'base', t0 = now() + HUNT_SETTLE, pos = pos };
            msg(('Leak hunt: a minute measuring the game\'s memory as usual, a minute with all %d call sites on the 1.0 stub, then about %d rounds of a minute (%d minutes in all). Stand still somewhere busy (a town), keep the frame rate up and don\'t zone: sites on the stub run the game fast above 60fps, so moving stops the hunt. /hifps leak stop ends it.'):fmt(
                n, math.ceil(math.log(n) / math.log(2)) + 1, math.ceil((math.ceil(math.log(n) / math.log(2)) + 3) * (HUNT_WINDOW + HUNT_SETTLE) / 60)));
        elseif (args[3] == 'stop') then
            if (state.hunt == nil) then err('No leak hunt running.'); return; end
            hunt_end('Leak hunt stopped; all sites back to the hifps behaviour.');
        else
            err('Usage: /hifps leak start | stop');
        end
        return;
    end

    if (#args >= 3 and args[2] == 'bisect') then
        if (state.mem == nil) then err('Enable hifps first.'); return; end
        if (state.hunt ~= nil) then err('A leak hunt is running; /hifps leak stop first.'); return; end
        local cmd = args[3];
        if (cmd == 'start') then
            -- Only sites the stub changes: smoothing-loop sites are on it anyway.
            local list = bisect_list();
            state.bisect = { list = list, lo = 1, hi = #list, round = 1 };
            msg(('Bisecting %d call sites (the %d smoothing-loop sites run once a frame either way, so they are left out).'):fmt(#list, #state.sites - #list));
            apply_targets();
            bisect_report();
        elseif (cmd == 'fixed' or cmd == 'broken') then
            local b = state.bisect;
            if (b == nil) then err('No bisect running; use /hifps bisect start.'); return; end
            if (b.confirm) then
                if (cmd == 'fixed') then
                    msg(('Found it: %s. It stays on the 1.0 stub until /hifps bisect stop, so the bug should stay gone. Tell Claude this address.'):fmt(site_text(b.list[b.lo])));
                else
                    state.bisect = nil;
                    apply_targets();
                    msg('Not a single call site: with only that one on the stub the bug is still there, so it comes from something hifps doesn\'t change site by site (a loop or a per-frame constant). All sites are back to the hifps behaviour. Tell Claude what you saw.');
                end
                return;
            end
            local mid = math.floor((b.lo + b.hi) / 2);
            if (cmd == 'fixed') then b.hi = mid; else b.lo = mid + 1; end
            b.round = b.round + 1;
            apply_targets();
            bisect_report();
        elseif (cmd == 'stop') then
            state.bisect = nil;
            apply_targets();
            msg('Bisect stopped; all sites back to the hifps behaviour.');
        else
            err('Usage: /hifps bisect start | fixed | broken | stop');
        end
        return;
    end

    msg(('%s, %.1f fps, step %.3f ticks, limit %s. Commands: /hifps (config window), /hifps limit <n|0>, /hifps counter, /hifps on, /hifps off, /hifps exp [<name|all> [on|off]], /hifps mem, /hifps leak start|stop, /hifps bisect start|fixed|broken|stop'):fmt(
        state.mem ~= nil and 'Enabled' or 'Disabled', state.fps, state.step,
        state.limit > 0 and tostring(state.limit) or 'none'));
end);
