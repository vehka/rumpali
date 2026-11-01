-- view.lua
-- drawing: lanes, cue glyphs, hit marks, beat grid, countdown, results.
-- everything is drawn with filled 1px-aligned rects (aa off) so glyphs
-- stay crisp on the 128x64 screen.

local drums = include("lib/drums")
local Song = include("lib/song")
local Judge = include("lib/judge")

local view = {}

local HEADER = 8   -- header text row height
local LABEL_W = 11 -- lane labels on the left

local function px(x, y, w, h) screen.rect(x, y, w or 1, h or 1) end

-- ---------- glyphs ----------
-- (cx, cy) is the glyph centre, integer pixels. caller sets the level.

local GLYPH = {}

function GLYPH.block(cx, cy) px(cx - 2, cy - 2, 5, 5) end

function GLYPH.box(cx, cy)
  px(cx - 2, cy - 2, 5, 1); px(cx - 2, cy + 2, 5, 1)
  px(cx - 2, cy - 1, 1, 3); px(cx + 2, cy - 1, 1, 3)
end

function GLYPH.x(cx, cy)
  for i = -2, 2 do px(cx + i, cy + i); if i ~= 0 then px(cx + i, cy - i) end end
end

function GLYPH.o(cx, cy)
  px(cx - 1, cy - 2, 3, 1); px(cx - 1, cy + 2, 3, 1)
  px(cx - 2, cy - 1, 1, 3); px(cx + 2, cy - 1, 1, 3)
end

function GLYPH.pedal(cx, cy) px(cx - 2, cy + 1, 5, 2) end

function GLYPH.star(cx, cy)
  for i = -3, 3 do
    px(cx + i, cy)
    if i ~= 0 then px(cx, cy + i) end
  end
  for i = 1, 2 do
    px(cx + i, cy + i); px(cx - i, cy - i); px(cx + i, cy - i); px(cx - i, cy + i)
  end
end

function GLYPH.dot(cx, cy) px(cx - 1, cy - 1, 3, 3) end

function GLYPH.diamond(cx, cy)
  px(cx, cy - 2); px(cx, cy + 2); px(cx - 2, cy); px(cx + 2, cy)
  px(cx - 1, cy - 1); px(cx + 1, cy - 1); px(cx - 1, cy + 1); px(cx + 1, cy + 1)
end

-- toms: a flat block, its height in the lane says which tom
function GLYPH.tom(cx, cy) px(cx - 2, cy - 1, 5, 3) end

local function glyph(sound, cx, cy, lane_h)
  if sound.row then
    local step = math.max(2, math.min(4, (lane_h - 3) // 3))
    cy = cy + (sound.row - 2) * step
  end
  GLYPH[sound.glyph](cx, cy)
  screen.fill()
end

local function vel_level(vel)
  return 4 + math.floor(vel / 127 * 11 + 0.5)
end

-- ---------- layout ----------

-- rows: list of lane numbers to show, top to bottom
function view.layout(rows)
  local L = { rows = rows, y = {}, h = 0 }
  local n = #rows
  L.h = (64 - HEADER) // n
  local top = HEADER + (64 - HEADER - L.h * n) // 2
  for i, lane in ipairs(rows) do
    L.y[lane] = top + (i - 1) * L.h + L.h // 2 -- lane centre
  end
  L.top = top
  L.bottom = top + L.h * n - 1
  return L
end

local function header(left, mid, right, mid_level)
  screen.font_face(1)
  screen.font_size(8)
  screen.level(10)
  if left then screen.move(0, 6); screen.text(left) end
  if right then screen.move(127, 6); screen.text_right(right) end
  if mid then
    screen.level(mid_level or 15)
    screen.move(64, 6); screen.text_center(mid)
  end
end

local function labels(L, flash, now_t)
  screen.font_size(8)
  for _, lane in ipairs(L.rows) do
    local lit = flash[lane] and flash[lane] > now_t
    screen.level(lit and 15 or 3)
    screen.move(0, L.y[lane] + 3)
    screen.text(drums.LANES[lane].name)
  end
end

local function grid_lines(L, beats, now, hit_x, pps)
  local s0 = now - (hit_x - LABEL_W) / pps
  local s1 = now + (128 - hit_x) / pps
  for i = Song.index_at(beats, s0), #beats do
    local b = beats[i]
    if b.s > s1 then break end
    local x = math.floor(hit_x + (b.s - now) * pps + 0.5)
    if x >= LABEL_W then
      if b.bar then
        screen.level(3)
        for y = L.top, L.bottom, 2 do px(x, y) end
      else
        screen.level(1)
        for y = L.top, L.bottom, 4 do px(x, y) end
      end
      screen.fill()
    end
  end
end

local function hit_line(L, x)
  screen.level(7)
  px(x, L.top, 1, L.bottom - L.top + 1)
  screen.fill()
end

-- ---------- track mode ----------
-- st: { song, now, pps, hit_x, rows, hits, flash, now_t, countdowns,
--       header = {left, mid, right, mid_level}, judging }

local function cues(L, chart, now, hit_x, pps)
  local s0 = now - (hit_x - LABEL_W) / pps
  local s1 = now + (128 - hit_x + 4) / pps
  for i = Song.index_at(chart, s0), #chart do
    local cue = chart[i]
    if cue.s > s1 then break end
    local y = L.y[cue.lane]
    if y then
      local x = math.floor(hit_x + (cue.s - now) * pps + 0.5)
      if x >= LABEL_W + 3 then
        if cue.result == "miss" then screen.level(1)
        elseif cue.result then screen.level(4)
        else screen.level(vel_level(cue.vel)) end
        glyph(cue.sound, x, y, L.h)
      end
    end
  end
end

-- your hits: a short vertical mark at the time you played, so it sits
-- next to its cue and shows early/late as it scrolls away
local function hit_marks(L, hits, now, hit_x, pps)
  local half = math.max(2, L.h // 2 - 1)
  for _, h in ipairs(hits) do
    local y = L.y[h.lane]
    if y then
      local x = math.floor(hit_x + (h.s - now) * pps + 0.5)
      if x >= LABEL_W and x <= 127 then
        screen.level(h.result == "perfect" and 15 or h.result == "good" and 9 or 3)
        px(x, y - half, 1, half * 2 + 1)
        screen.fill()
      end
    end
  end
end

local function countdown(L, n, total)
  local cx, cy = 80, L.top + (L.bottom - L.top) // 2
  screen.level(0)
  px(cx - 14, cy - 13, 29, 27)
  screen.fill()
  screen.level(15)
  screen.font_face(1)
  screen.font_size(24)
  screen.move(cx, cy + 8)
  screen.text_center(tostring(n))
  -- one dot per beat, filled as they pass
  local w = total * 4 - 1
  for k = 1, total do
    screen.level(k <= total - n + 1 and 15 or 3)
    px(cx - w // 2 + (k - 1) * 4, cy + 11, 3, 2)
    screen.fill()
  end
  screen.font_size(8)
end

function view.track(st)
  local L = view.layout(st.rows)
  screen.aa(0)
  local song = st.song
  if song then
    grid_lines(L, song.pre_beats, st.now, st.hit_x, st.pps)
    grid_lines(L, song.beats, st.now, st.hit_x, st.pps)
    hit_line(L, st.hit_x)
    cues(L, song.chart, st.now, st.hit_x, st.pps)
    hit_marks(L, st.hits, st.now, st.hit_x, st.pps)
    local cd, n = Song.countdown_at(st.countdowns, st.now)
    if cd then countdown(L, n, #cd.beats) end
  else
    hit_line(L, st.hit_x)
  end
  labels(L, st.flash, st.now_t)
  local h = st.header
  header(h.left, h.mid, h.right, h.mid_level)
end

-- ---------- free mode ----------
-- st: { now_t, pps, hit_x, hits = {t, sound, lane, vel}, flash, header }

function view.free(st)
  local L = view.layout({ 1, 2, 3, 4, 5 })
  screen.aa(0)
  hit_line(L, st.hit_x)
  for _, h in ipairs(st.hits) do
    local x = math.floor(st.hit_x + (h.t - st.now_t) * st.pps + 0.5)
    if x >= LABEL_W + 3 then
      screen.level(vel_level(h.vel))
      glyph(h.sound, x, L.y[h.lane], L.h)
    end
  end
  labels(L, st.flash, st.now_t)
  local h = st.header
  header(h.left, h.mid, h.right, h.mid_level)
end

-- ---------- results ----------

local function fmt_ms(ms)
  if not ms then return "-" end
  return (ms > 0 and "+" or "") .. ms
end

function view.results(judge, song_name, rows)
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)
  local tot = judge:totals()
  local acc = Judge.accuracy(tot)
  screen.level(15)
  screen.move(0, 6)
  screen.text(song_name or "")
  screen.move(127, 6)
  screen.text_right(acc and (acc .. "%") or "")
  local cols = { 40, 60, 80, 100, 127 }
  local y = 15
  screen.level(4)
  local heads = { "P", "G", "M", "X", "ms" }
  for i, t in ipairs(heads) do screen.move(cols[i], y); screen.text_right(t) end
  local function row(name, st, level)
    y = y + 8
    screen.level(level)
    screen.move(0, y); screen.text(name)
    local vals = { st.perfect, st.good, st.miss, st.extra, fmt_ms(Judge.mean_ms(st)) }
    for i, v in ipairs(vals) do screen.move(cols[i], y); screen.text_right(tostring(v)) end
  end
  for _, lane in ipairs(rows) do row(drums.LANES[lane].name, judge.lanes[lane], 10) end
  row("all", tot, 15)
end

-- ---------- learn ----------

function view.learn(st)
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)
  screen.level(10)
  screen.move(0, 6); screen.text("LEARN")
  screen.move(127, 6); screen.text_right(st.profile)
  -- target list around the selection
  local sel = st.target
  for k = -1, 1 do
    local s = drums.SOUNDS[sel + k]
    if s then
      local y = 26 + k * 9
      screen.level(k == 0 and 15 or 3)
      screen.move(0, y); screen.text(k == 0 and ">" or " ")
      screen.move(8, y); screen.text(s.name)
      screen.move(64, y); screen.text(drums.LANES[s.lane].name)
      screen.fill()
      glyph(s, 84, y - 3, 9)
    end
  end
  screen.level(4)
  screen.move(0, 46); screen.text(st.line1 or "hit a pad to assign it")
  screen.move(0, 55); screen.text(st.line2 or "")
  screen.move(0, 63); screen.text("K3 clear learned (" .. st.count .. ")")
end

return view
