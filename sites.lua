--[[
* Finds hifps.lua's client offsets in the running client, so a client update that moves code doesn't
* stop hifps. sigs.lua (tools/gen_sigs.py) holds a byte signature for every offset the site tables
* name, built from the client they were written against.
*
* resolve(mem, getters) -> { map = { [old offset] = offset now }, extra = { offsets } }
*   mem      const uint8_t* at FFXiMain.dll's base (in game; the tests pass a dump)
*   getters  the two step getters' offsets
*   map      only offsets that were found; a missing one stays nil
*   extra    calls to a getter that no table names (new in this client); hifps feeds them whole ticks
* An offset is looked for where it was, then shifted like the nearest offset found so far, then (a
* call site) among all calls to the getters, then (anything else) everywhere in .text.
--]]

local ffi  = require('ffi');
local SIGS = require('sigs');

local M = {};

local function u32(mem, o) return ffi.cast('const uint32_t*', mem + o)[0]; end
local function i32(mem, o) return ffi.cast('const int32_t*', mem + o)[0]; end

-- .text's offset range, from the PE header.
function M.text(mem)
    local pe = u32(mem, 0x3C);
    local n = ffi.cast('const uint16_t*', mem + pe + 6)[0];
    local sec = pe + 24 + ffi.cast('const uint16_t*', mem + pe + 20)[0];
    for i = 0, n - 1 do
        local e = sec + 40 * i;
        if (ffi.string(mem + e, 5) == '.text') then
            local va = u32(mem, e + 12);
            return va, va + u32(mem, e + 8);
        end
    end
    return nil;
end

-- Offsets of every 'call rel32' in [lo, hi) whose target is one of the getters.
function M.callers(mem, lo, hi, getters)
    local g1, g2 = getters[1], getters[2];
    local out = {};
    for o = lo, hi - 5 do
        if (mem[o] == 0xE8) then
            local t = o + 5 + i32(mem, o + 1);
            if (t == g1 or t == g2) then out[#out + 1] = o; end
        end
    end
    return out;
end

-- Pattern as an array of bytes, -1 for '??'.
local compiled = {};
local function pat(rva)
    local p = compiled[rva];
    if (p == nil) then
        local s = SIGS[rva][3];
        p = {};
        for i = 1, #s, 2 do
            local h = s:sub(i, i + 1);
            p[#p + 1] = (h == '??') and -1 or tonumber(h, 16);
        end
        compiled[rva] = p;
    end
    return p;
end

local function match(mem, lo, hi, at, p)
    if (at < lo or at + #p > hi) then return false; end
    for i = 1, #p do
        local b = p[i];
        if (b >= 0 and mem[at + i - 1] ~= b) then return false; end
    end
    return true;
end

-- Every place in [lo, hi) the pattern matches (pattern start offsets), up to 2.
local function scan(mem, lo, hi, p)
    local first, fb = 1, -1;
    for i = 1, #p do if (p[i] >= 0) then first, fb = i, p[i]; break; end end
    local out = {};
    for o = lo + first - 1, hi - #p + first - 1 do
        if (mem[o] == fb and match(mem, lo, hi, o - first + 1, p)) then
            out[#out + 1] = o - first + 1;
            if (#out > 1) then break; end
        end
    end
    return out;
end

function M.resolve(mem, getters)
    local lo, hi = M.text(mem);
    local callers = M.callers(mem, lo, hi, getters);
    local keys = {};
    for rva in pairs(SIGS) do keys[#keys + 1] = rva; end
    table.sort(keys);

    local map, found = {}, {};   -- found: sorted { old, delta } of what was found, for shifts
    local function nearest_delta(rva)
        local best, bd = nil, nil;
        for _, f in ipairs(found) do
            local d = math.abs(f[1] - rva);
            if (bd == nil or d < bd) then best, bd = f[2], d; end
        end
        return best;
    end
    local function try(rva, at)
        local s = SIGS[rva];
        if (match(mem, lo, hi, at - s[2], pat(rva))) then
            map[rva] = at;
            found[#found + 1] = { rva, at - rva };
            return true;
        end
        return false;
    end

    -- Where they were; then shifted like a neighbour.
    local left = {};
    for _, rva in ipairs(keys) do
        if (not try(rva, rva)) then left[#left + 1] = rva; end
    end
    local again = {};
    for _, rva in ipairs(left) do
        local d = nearest_delta(rva);
        if (d == nil or d == 0 or not try(rva, rva + d)) then again[#again + 1] = rva; end
    end
    -- Then by search: call sites among the getters' callers (unique match only), the rest in .text.
    local taken = {};
    for _, at in pairs(map) do taken[at] = true; end
    for _, rva in ipairs(again) do
        local s, p = SIGS[rva], pat(rva);
        local hit = {};
        if (s[1] == 'site') then
            for _, c in ipairs(callers) do
                if (not taken[c] and match(mem, lo, hi, c - s[2], p)) then hit[#hit + 1] = c; end
            end
        else
            for _, o in ipairs(scan(mem, lo, hi, p)) do hit[#hit + 1] = o + s[2]; end
        end
        if (#hit == 1) then
            map[rva] = hit[1];
            taken[hit[1]] = true;
        end
    end

    local named = {};
    for rva, at in pairs(map) do if (SIGS[rva][1] == 'site') then named[at] = true; end end
    local extra = {};
    for _, c in ipairs(callers) do
        if (not named[c]) then extra[#extra + 1] = c; end
    end
    return { map = map, extra = extra, callers = #callers };
end

return M;
