-- judge.lua
-- matches hits to chart cues and keeps the score.
-- a hit counts for the nearest unplayed cue in its lane inside the
-- "good" window. errors are in real milliseconds (positive = late),
-- so slowing the song down doesn't widen the windows.
-- pure Lua, no norns calls.

local Song = include("lib/song")

local Judge = {}
Judge.__index = Judge

local NLANES = 5

function Judge.new(chart)
  local j = setmetatable({ chart = chart }, Judge)
  j.perfect = 0.035
  j.good = 0.090
  j:reset()
  return j
end

function Judge:reset()
  for _, cue in ipairs(self.chart) do
    cue.result, cue.err = nil, nil
  end
  self.miss_i = 1
  self.lanes = {}
  for l = 1, NLANES do
    self.lanes[l] = { perfect = 0, good = 0, miss = 0, extra = 0, err_sum = 0, err_n = 0 }
  end
  self.last = nil -- { result, err_ms, lane }
end

-- hit in `lane` at song time s, while playing at `rate` (1 = normal).
-- count_extra: whether a hit with no cue counts against you.
-- returns result ("perfect", "good" or "extra"), the cue, error ms
function Judge:hit(lane, s, rate, count_extra)
  local chart = self.chart
  local w = self.good * rate
  local best, best_d
  for i = Song.index_at(chart, s - w), #chart do
    local cue = chart[i]
    if cue.s > s + w then break end
    if cue.lane == lane and not cue.result then
      local d = math.abs(cue.s - s)
      if not best or d < best_d then best, best_d = cue, d end
    end
  end
  local st = self.lanes[lane]
  if not best then
    if count_extra then
      st.extra = st.extra + 1
      self.last = { result = "extra", lane = lane }
    end
    return "extra"
  end
  local err = (s - best.s) / rate
  local result = math.abs(err) <= self.perfect and "perfect" or "good"
  best.result, best.err = result, err
  st[result] = st[result] + 1
  st.err_sum = st.err_sum + err
  st.err_n = st.err_n + 1
  local ms = math.floor(err * 1000 + 0.5)
  self.last = { result = result, err_ms = ms, lane = lane }
  return result, best, ms
end

-- mark cues that went past the window unplayed as missed
function Judge:advance(s, rate)
  local chart = self.chart
  local limit = s - self.good * rate
  local i = self.miss_i
  while chart[i] and chart[i].s < limit do
    local cue = chart[i]
    if not cue.result then
      cue.result = "miss"
      local st = self.lanes[cue.lane]
      st.miss = st.miss + 1
      self.last = { result = "miss", lane = cue.lane }
    end
    i = i + 1
  end
  self.miss_i = i
end

function Judge:totals()
  local t = { perfect = 0, good = 0, miss = 0, extra = 0, err_sum = 0, err_n = 0 }
  for _, st in ipairs(self.lanes) do
    for k in pairs(t) do t[k] = t[k] + st[k] end
  end
  return t
end

-- mean error in ms (positive = late), or nil with no hits
function Judge.mean_ms(st)
  if st.err_n == 0 then return nil end
  local m = st.err_sum / st.err_n * 1000
  return math.floor(m + 0.5)
end

-- share of cues hit (perfect counts full, good half), 0..100
function Judge.accuracy(st)
  local n = st.perfect + st.good + st.miss
  if n == 0 then return nil end
  return math.floor((st.perfect + st.good * 0.5) / n * 100 + 0.5)
end

return Judge
