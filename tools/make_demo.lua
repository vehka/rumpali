-- make_demo.lua: writes demo/rumpali_demo.mid
-- run from the repo root: lua5.3 tools/make_demo.lua
--
-- 16 bars at 100 bpm: hat groove, a tom fill, a two-bar drum break
-- (bass and organ keep going, so the countdown shows), a ride groove,
-- a snare fill and a crash ending. Uses all five lanes.

local DIV = 480
local BAR = DIV * 4
local S16 = DIV // 4

local function vlq(n)
  local bytes = { n % 128 }
  n = n // 128
  while n > 0 do
    table.insert(bytes, 1, n % 128 + 128)
    n = n // 128
  end
  return string.char(table.unpack(bytes))
end

local function u32(n) return string.pack(">I4", n) end
local function u16(n) return string.pack(">I2", n) end

-- events: { tick, bytes } -> MTrk chunk
local function track(events)
  table.sort(events, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[3] < b[3] -- note-offs (0) before note-ons (1)
  end)
  local out, now = {}, 0
  for _, e in ipairs(events) do
    out[#out + 1] = vlq(e[1] - now) .. e[2]
    now = e[1]
  end
  out[#out + 1] = vlq(0) .. "\xFF\x2F\x00"
  local data = table.concat(out)
  return "MTrk" .. u32(#data) .. data
end

local function note(list, ch, tick, n, vel, len)
  list[#list + 1] = { tick, string.char(0x90 + ch - 1, n, vel), 1 }
  list[#list + 1] = { tick + len, string.char(0x80 + ch - 1, n, 0), 0 }
end

local function program(list, ch, p)
  list[#list + 1] = { 0, string.char(0xC0 + ch - 1, p), 0 }
end

-- ---------- conductor ----------
local meta = {
  { 0, "\xFF\x03" .. vlq(12) .. "rumpali demo", 0 },
  { 0, "\xFF\x51\x03" .. string.char(0x09, 0x27, 0xC0), 0 }, -- 600000 us = 100 bpm
  { 0, "\xFF\x58\x04\x04\x02\x18\x08", 0 },                -- 4/4
}

-- ---------- drums (channel 10) ----------
local KICK, SNARE, HH, HO, PEDAL = 36, 38, 42, 46, 44
local CRASH, RIDE, BELL = 49, 51, 53
local TOM_HI, TOM_MID, TOM_FLOOR = 48, 45, 43

local d = {}
local function hit(bar, s16, n, vel) note(d, 10, (bar - 1) * BAR + s16 * S16, n, vel, S16) end

local function hat_groove(bar, open_end)
  for e = 0, 7 do
    local n = (open_end and e == 7) and HO or HH
    hit(bar, e * 2, n, e % 2 == 0 and 96 or 70)
  end
  hit(bar, 0, KICK, 110); hit(bar, 8, KICK, 104)
  if bar % 2 == 0 then hit(bar, 10, KICK, 90) end
  hit(bar, 4, SNARE, 108); hit(bar, 12, SNARE, 108)
end

local function ride_groove(bar)
  for q = 0, 3 do
    hit(bar, q * 4, RIDE, 92)
    hit(bar, q * 4 + 3, RIDE, 64)
  end
  hit(bar, 4, PEDAL, 70); hit(bar, 12, PEDAL, 70)
  hit(bar, 0, KICK, 110); hit(bar, 6, KICK, 96); hit(bar, 8, KICK, 104)
  hit(bar, 4, SNARE, 110); hit(bar, 12, SNARE, 110)
  hit(bar, 14, SNARE, 40) -- ghost note
end

for bar = 1, 4 do hat_groove(bar, false) end
hit(1, 0, CRASH, 112)
for bar = 5, 7 do hat_groove(bar, true) end
-- bar 8: groove then a tom fill
hit(8, 0, KICK, 110); hit(8, 0, HH, 96); hit(8, 2, HH, 70)
hit(8, 4, SNARE, 108); hit(8, 6, SNARE, 50)
for i, n in ipairs({ TOM_HI, TOM_HI, TOM_MID, TOM_MID, TOM_FLOOR, TOM_FLOOR, TOM_FLOOR, KICK }) do
  hit(8, 7 + i, n, 90 + i * 3)
end
-- bars 9-10: drums rest
for bar = 11, 14 do ride_groove(bar) end
hit(11, 0, CRASH, 115); hit(13, 0, BELL, 100)
-- bar 15: snare fill, getting louder
hat_groove(15, false)
for i = 0, 7 do hit(15, 8 + i, SNARE, 60 + i * 8) end
-- bar 16: end
hit(16, 0, CRASH, 120); hit(16, 0, KICK, 120)

-- ---------- bass (channel 2) and organ (channel 3) ----------
local b, o = {}, {}
program(b, 2, 33) -- electric bass (finger)
program(o, 3, 17) -- percussive organ
local ROOTS = { 40, 40, 45, 47 } -- E E A B
for bar = 1, 16 do
  local root = ROOTS[(bar - 1) % 4 + 1]
  if bar == 16 then root = 40 end
  for e = 0, 7 do
    if bar < 16 or e == 0 then note(b, 2, (bar - 1) * BAR + e * DIV // 2, root, e == 0 and 100 or 84, DIV // 2 - 20) end
  end
  local len = bar == 16 and BAR or BAR - 30
  for _, iv in ipairs({ 12, 19, 24 }) do note(o, 3, (bar - 1) * BAR, root + iv + 12, 70, len) end
end

local file = "MThd" .. u32(6) .. u16(1) .. u16(4) .. u16(DIV)
  .. track(meta) .. track(d) .. track(b) .. track(o)
local f = assert(io.open("demo/rumpali_demo.mid", "wb"))
f:write(file)
f:close()
print("wrote demo/rumpali_demo.mid")
