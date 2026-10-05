addon.name      = 'hifps';
addon.author    = 'relliko';
addon.version   = '0.7';
addon.desc      = 'Runs the client above 60fps by feeding real frame time into the game step.';

require 'common';
local ffi  = require 'ffi';
local chat = require 'chat';
local imgui = require 'imgui';

pcall(ffi.cdef, [[
    int __stdcall QueryPerformanceCounter(int64_t* count);
    int __stdcall QueryPerformanceFrequency(int64_t* freq);
    void __stdcall Sleep(uint32_t ms);
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
*
*   Bisect mode (local server only): points a group of call sites at a stub that always returns 1.0,
*   the stock 60fps value, so you can find which site causes a bug. Sites in that group run fast
*   above 60fps while it is active.
--]]

-- Call sites (offsets from FFXiMain.dll base) that use the fractional step.
local FRAC_SITES = {
    0x00766F, 0x01A9AB, 0x01B5D4, 0x01C5AF, 0x01F01F, 0x01F0F2, 0x01F82F, 0x01F87F,
    0x01F8D5, 0x01F91D, 0x0205B1, 0x02198E, 0x02AD55, 0x033ED1, 0x033FAB, 0x035944,
    0x0368B6, 0x0368CE, 0x0381D4, 0x0478BF, 0x0478D7, 0x06A000, 0x08D383,
    0x08D38F, 0x08D39D, 0x08D61D, 0x08D62B, 0x08D639, 0x08D647, 0x08D655, 0x09729C,
    0x0A57F9, 0x0A7B8A, 0x0A9FC7, 0x0AA1F7, 0x0AAB78, 0x0AADF5, 0x0B0829,
    0x0B08BF, 0x0B2F4E, 0x0B2F9E, 0x0B2FE1, 0x0B32A8, 0x0B32F0, 0x0B3333, 0x0B3376,
    0x0B56F2, 0x0B57FD, 0x0B5840, 0x0B587D, 0x0C4878, 0x0C648E, 0x0C65BA, 0x0C6882,
    0x0C6C64, 0x0C76CA, 0x0C7F13, 0x0C8AC8, 0x0C8AE7, 0x0CAEEA, 0x0CBC68, 0x0CDF96,
    0x12C179, 0x12C734, 0x12CBCF, 0x178BD0, 0x17A4BB, 0x188A54, 0x1EDF4C, 0x1EF1AC,
    0x1EF1D2, 0x1EF282, 0x1EF334, 0x1EF3DE, 0x1EF541, 0x1EF55D, 0x1EF570, 0x1EF590,
    0x1EF5AC, 0x1EF5BF, 0x1EF6FE, 0x1EF711, 0x1EFA27, 0x227E58, 0x24DE98, 0x24DF4E,
    0x24EBCA, 0x24EC1F, 0x24EE6D, 0x24EECB, 0x24F019, 0x24F6E6,
};
-- Call sites that truncate the step to an integer.
local INT_SITES = {
    0x005A50, 0x007BB6, 0x007D74, 0x018A10, 0x018D0E, 0x01BC9C, 0x01EEFE,
    0x020148, 0x021185, 0x0211C1, 0x021207,
    0x021243, 0x0219A0, 0x0375A0, 0x0375FB, 0x039366, 0x087495, 0x087E99, 0x0884CC,
    0x0884F5, 0x0885B1, 0x0886B3, 0x088CA7, 0x088CD4, 0x088CF9, 0x088E63, 0x088ECF,
    0x089061, 0x0891FF, 0x089228, 0x0892E7, 0x0893CB, 0x0898F5, 0x089933, 0x089958,
    0x089AFB, 0x089B67, 0x08ADD1, 0x08AE39, 0x08D34B, 0x08D3BE, 0x08D663, 0x08D671,
    0x08DAAB, 0x08EA21, 0x08ED66, 0x091AD3, 0x09670D, 0x097271, 0x0984D5, 0x0984F6,
    0x09F661, 0x0A2843, 0x0A5194, 0x0AC55D, 0x0AECC0, 0x0B035D, 0x0B578B, 0x0B76A4,
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

-- Fixed-step smoothing loops: "n = (int)step; repeat n times: v += (target - v) * k", with k pushed
-- as an immediate float. Their call sites get the 1.0 stub (one pass per frame) and the immediate is
-- rewritten every frame to 1 - (1 - k)^step. imm = offset of the 4 immediate bytes (after a 68 push).
-- ops: instructions in the loop that read a float constant from memory ("fmul/fsub dword [const]").
-- at = offset of the instruction's disp32, const = offset of the constant it reads. The disp32 is
-- pointed at a slot of ours; mode 'ease' gets 1 - (1 - v)^step, 'lin' gets v * step.
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
};
local MAX_OPS = 16;

local MIN_STEP = 0.05;  -- ticks; ~1200fps
local MAX_STEP = 4.0;   -- ticks; hitches longer than this slow the game down like before

local state = T{
    sites       = T{},      -- { addr, kind ('f'|'i'|'s'), backup (rel32 bytes), target }
    smooth      = T{},      -- { addr (immediate), k, backup, prot }
    ops         = T{},      -- { addr (disp32), const (game constant address), v (its value), mode, slot, name, warned }
    getters     = T{},      -- { addr, backup }
    mem         = nil,      -- +0 frac step, +4 whole step, +16 stub code, +24 1.0f
    g_frac      = nil,
    g_int       = nil,
    stub        = nil,
    accum       = 0,
    div_ptr     = nil,
    div_orig    = nil,
    limit       = 120,      -- fps cap, 0 = none (use vsync / driver cap)
    last        = nil,
    freq        = 0,
    frames      = 0,
    fps         = 0,
    fps_timer   = 0,
    step        = 1.0,
    counter     = true,     -- fps counter in the top left
    bisect      = nil,      -- { lo, hi, round }
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
    return v == 0;
end

local function camera_warning(name, addr, detail)
    err(('Camera warning: the %s code at %08X was changed by another addon (%s) in a way hifps cannot adjust for. That part of the camera may blur or move at the wrong speed above 60fps. Unload the other camera addon, or use /hifps limit 60.'):fmt(name, addr, detail));
end

local function set_divisor(v)
    if (state.div_ptr ~= nil) then ashita.memory.write_uint32(state.div_ptr, v); end
end

local function disable()
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
    state.bisect = nil;
end

-- Points every site at its normal target, except bisect candidates lo..mid, which get the 1.0 stub.
local function apply_targets()
    local b = state.bisect;
    local mid = b and math.floor((b.lo + b.hi) / 2) or 0;
    for i, s in ipairs(state.sites) do
        local t = (s.kind == 'f') and state.g_frac or (s.kind == 's') and state.stub or state.g_int;
        if (b ~= nil and i >= b.lo and i <= mid) then t = state.stub; end
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
    if (not add(FRAC_SITES, 'f') or not add(INT_SITES, 'i')) then return false; end
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
            if (ashita.memory.read_uint8(a - 1) ~= 0x68 or have ~= want) then
                bad = a - 1;
            else
                l_smooth:append({ addr = a, k = l.k, backup = ashita.memory.read_array(a, 4) });
            end
        end
        local detail = nil;
        if (bad ~= nil) then
            local f = ashita.memory.read_array(bad, 5);
            detail = ('found %02X %02X %02X %02X %02X'):fmt(f[1], f[2], f[3], f[4], f[5]);
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
                    l_ops:append({ addr = a, const = c, v = ashita.memory.read_float(u32(c)), mode = o.mode, name = l.name });
                end
            end
        end
        if (bad ~= nil) then
            camera_warning(l.name, bad, detail);
            if (not add(l.sites, 'i')) then return false; end
        else
            if (not add(l.sites, 's')) then return false; end
            for _, x in ipairs(l_smooth) do smooth:append(x); end
            for _, x in ipairs(l_ops) do ops:append(x); end
        end
    end
    if (#ops > MAX_OPS) then err('Too many operand patches.'); return false; end

    -- Our memory: two step floats, and an executable stub "fld dword [1.0]; ret" for bisecting.
    -- +32: one float slot per redirected operand.
    local memsize = 32 + MAX_OPS * 4;
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

    state.div_orig = ashita.memory.read_uint32(state.div_ptr);
    set_divisor(0);
    state.last = now();
    state.fps_timer = state.last;
    msg(('Enabled. %d call sites, limit %s.'):fmt(#state.sites, state.limit > 0 and tostring(state.limit) or 'none'));
    return true;
end

local function bisect_report()
    local b = state.bisect;
    if (b.lo == b.hi) then
        local s = state.sites[b.lo];
        msg(('Found it: site #%d at %08X (offset %06X, %s step). It is still on the 1.0 stub, so the bug should be gone. Tell Claude this address.'):fmt(
            b.lo, s.addr, s.addr - ashita.memory.get_base('FFXiMain.dll'), s.kind == 'f' and 'fractional' or 'whole-tick'));
        -- Leave only the culprit on the stub.
        state.bisect = { lo = b.lo, hi = b.lo, round = b.round };
        local mid = b.lo;
        for i, s2 in ipairs(state.sites) do
            local t = (s2.kind == 'f') and state.g_frac or (s2.kind == 's') and state.stub or state.g_int;
            if (i == mid) then t = state.stub; end
            point_site(s2, t);
        end
        return;
    end
    local mid = math.floor((b.lo + b.hi) / 2);
    msg(('Round %d: %d candidates left. Sites %d-%d are back to stock behaviour. Test the bug, then type /hifps bisect fixed (bug gone) or /hifps bisect broken (bug still there).'):fmt(
        b.round, b.hi - b.lo + 1, b.lo, mid));
end

ashita.events.register('load', 'load_cb', function ()
    enable();
end);

ashita.events.register('unload', 'unload_cb', function ()
    disable();
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    if (state.mem == nil) then return; end

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

    -- Smoothing loops run once per frame; scale their factor to this frame's step.
    for _, l in ipairs(state.smooth) do
        ashita.memory.write_float(l.addr, 1.0 - math.pow(1.0 - l.k, step));
    end
    for _, o in ipairs(state.ops) do
        local v = o.v * step;
        local m = math.abs(o.v);
        if (o.mode == 'ease' and m > 0 and m < 1) then
            v = (1.0 - math.pow(1.0 - m, step)) * (o.v < 0 and -1 or 1);
        end
        ashita.memory.write_float(o.slot, v);
        -- Another addon may have redirected this operand since, or handed it back.
        local d = bit.tobit(ashita.memory.read_uint32(o.addr));
        if (d == o.const) then
            write_bytes(o.addr, le32(o.slot));
            o.warned = false;
        elseif (d ~= bit.tobit(o.slot) and not o.warned and not step_invariant(o.mode, ashita.memory.read_float(u32(d)))) then
            camera_warning(o.name, o.addr - 2, ('value %g'):fmt(ashita.memory.read_float(u32(d))));
            o.warned = true;
        end
    end

    state.frames = state.frames + 1;
    if (t - state.fps_timer >= 1.0) then
        state.fps = state.frames / (t - state.fps_timer);
        state.frames = 0;
        state.fps_timer = t;
    end

    if (state.counter) then
        imgui.SetNextWindowPos({ 0, 0 }, ImGuiCond_Always);
        imgui.SetNextWindowBgAlpha(0.35);
        local flags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoSavedSettings,
            ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoInputs);
        if (imgui.Begin('hifps_counter', true, flags)) then
            imgui.Text(('%.0f fps'):fmt(state.fps));
        end
        imgui.End();
    end
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/hifps') then return; end
    e.blocked = true;

    if (#args >= 3 and args[2] == 'limit') then
        state.limit = math.max(0, args[3]:number_or(120));
        msg(('Frame limit set to %s.'):fmt(state.limit > 0 and tostring(state.limit) or 'none'));
        return;
    end
    if (#args >= 2 and args[2] == 'counter') then
        state.counter = not state.counter;
        msg(('FPS counter %s.'):fmt(state.counter and 'shown' or 'hidden'));
        return;
    end
    if (#args >= 2 and args[2] == 'off') then
        disable();
        msg('Disabled; original code and divisor restored.');
        return;
    end
    if (#args >= 2 and args[2] == 'on') then
        if (state.mem == nil) then enable(); end
        return;
    end

    if (#args >= 3 and args[2] == 'bisect') then
        if (state.mem == nil) then err('Enable hifps first.'); return; end
        local cmd = args[3];
        if (cmd == 'start') then
            state.bisect = { lo = 1, hi = #state.sites, round = 1 };
            apply_targets();
            bisect_report();
        elseif (cmd == 'fixed' or cmd == 'broken') then
            local b = state.bisect;
            if (b == nil) then err('No bisect running; use /hifps bisect start.'); return; end
            if (b.lo == b.hi) then bisect_report(); return; end
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

    msg(('%s, %.1f fps, step %.3f ticks, limit %s. Commands: /hifps limit <n|0>, /hifps counter, /hifps on, /hifps off, /hifps bisect start|fixed|broken|stop'):fmt(
        state.mem ~= nil and 'Enabled' or 'Disabled', state.fps, state.step,
        state.limit > 0 and tostring(state.limit) or 'none'));
end);
