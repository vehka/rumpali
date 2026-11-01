-- song.lua
-- a MIDI file as rumpali uses it: the backing events, the drum chart
-- (channel 10 notes, sorted into lanes), the beat grid and the countdowns.
-- times are in song seconds; negative times are the count-in before
-- the file starts. pure Lua, no norns calls.

local smf = include("lib/smf")
local drums = include("lib/drums")

local Song = {}
Song.__index = Song

local DRUM_CH = 9 -- channel 10, zero based

local function basename(path)
  local name = path:match("([^/]+)$") or path
  return (name:gsub("%.[Mm][Ii][Dd][Ii]?$", ""))
end

local function seg_at_tick(song, tick)
  local s = song.segs[1]
  for k = 2, #song.segs do
    if song.segs[k].tick <= tick then s = song.segs[k] else break end
  end
  return s
end

-- first index in list whose .s >= sec (list sorted by .s)
function Song.index_at(list, sec)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid].s < sec then lo = mid + 1 else hi = mid end
  end
  return lo
end

function Song.load(path, yield_fn)
  local f = io.open(path, "rb")
  if not f then return nil, "can't open file" end
  local data = f:read("a")
  f:close()
  return Song.from_data(data, basename(path), yield_fn)
end

function Song.from_data(data, name, yield_fn)
  local parsed, err = smf.parse(data, yield_fn)
  if not parsed then return nil, err end
  local song = setmetatable(parsed, Song)
  song.name = name or "song"
  song:build_chart()
  song:build_grid()
  song:find_countdowns(2)
  return song
end

-- drum chart: one cue per lane per tick (the loudest one wins)
function Song:build_chart()
  local chart, seen = {}, {}
  self.lanes_used = {}
  self.channels = {}
  for _, e in ipairs(self.events) do
    local hi, ch = e.st - e.st % 16, e.st % 16
    if hi == 0x90 and e.b > 0 then
      self.channels[ch + 1] = true
      if ch == DRUM_CH then
        local snd = drums.gm_sound(e.a)
        if snd then
          local key = e.t * 8 + snd.lane
          local prev = seen[key]
          if prev then
            if e.b > prev.vel then prev.sound, prev.vel = snd, e.b end
          else
            local cue = { s = e.s, t = e.t, sound = snd, lane = snd.lane, vel = e.b }
            chart[#chart + 1] = cue
            seen[key] = cue
            self.lanes_used[snd.lane] = true
          end
        end
      end
    end
  end
  self.chart = chart
  local last_tick = 0
  for _, e in ipairs(self.events) do if e.t > last_tick then last_tick = e.t end end
  self.last_tick = last_tick
  -- the tempo the screen scrolls at: where the drums start
  local first_tick = chart[1] and chart[1].t or 0
  self.ref_bpm = 60e6 / seg_at_tick(self, first_tick).uspq
end

function Song:bar_ticks()
  return math.floor(self.bar_beats * self.div + 0.5)
end

-- beat and bar lines from tick 0 to the bar after the last event
function Song:build_grid()
  local beats = {}
  local bar_ticks = self:bar_ticks()
  local last = (self.last_tick // bar_ticks + 1) * bar_ticks
  local bar = 0
  for tick = 0, last, self.div do
    local is_bar = tick % bar_ticks == 0
    if is_bar then bar = bar + 1 end
    beats[#beats + 1] = { s = smf.sec_at_tick(self, tick), bar = is_bar and bar or nil }
  end
  self.beats = beats
  self.finish = math.max(self.len, beats[#beats].s)
end

-- the bar number at song time sec (bar 1 starts at 0; count-in is bar 0)
function Song:bar_at(sec)
  local n = 0
  for _, b in ipairs(self.beats) do
    if b.s > sec then break end
    if b.bar then n = b.bar end
  end
  return n
end

-- one bar of beats counting down to the bar starting at `bar_tick`,
-- at the tempo of that bar (so a fast lead-in bar doesn't rush it)
function Song:countdown_before_tick(bar_tick)
  local at = smf.sec_at_tick(self, bar_tick)
  local beat = seg_at_tick(self, bar_tick).uspq / 1e6
  local n = math.max(1, math.floor(self.bar_beats + 0.5))
  local cd = { at = at, beats = {} }
  for k = n, 1, -1 do cd.beats[#cd.beats + 1] = at - k * beat end
  return cd
end

-- countdowns before the first drum hit and after every gap of at least
-- gap_bars bars without drums. sets self.start: where playback begins.
function Song:find_countdowns(gap_bars)
  local cds = {}
  local bar_ticks = self:bar_ticks()
  local prev
  for _, cue in ipairs(self.chart) do
    if not prev or cue.t - prev.t >= gap_bars * bar_ticks then
      cds[#cds + 1] = self:countdown_before_tick(cue.t // bar_ticks * bar_ticks)
    end
    prev = cue
  end
  self.countdowns = cds
  self.start = 0
  if cds[1] then self.start = math.min(0, cds[1].beats[1]) end
  -- count-in beat lines before the file starts
  local pre = {}
  if cds[1] and self.start < 0 then
    for _, s in ipairs(cds[1].beats) do
      if s < 0 then pre[#pre + 1] = { s = s, bar = (#pre == 0) and 0 or nil } end
    end
  end
  self.pre_beats = pre
end

-- the countdown showing at song time sec, and the number to show
function Song.countdown_at(list, sec)
  for _, cd in ipairs(list) do
    local b = cd.beats
    if sec >= b[1] and sec < cd.at then
      for k = #b, 1, -1 do
        if sec >= b[k] then return cd, #b - k + 1 end
      end
    end
  end
  return nil
end

return Song
