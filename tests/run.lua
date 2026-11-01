-- offline tests for the pure parts (no norns needed)
-- run from the repo root: lua5.3 tests/run.lua

function include(p) return dofile(p .. ".lua") end

local drums = include("lib/drums")
local inputs = include("lib/inputs")
local Song = include("lib/song")
local Judge = include("lib/judge")

local failed, passed = 0, 0
local function check(cond, what)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. what) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- ---------- drums / inputs ----------
check(drums.gm_sound(36).lane == drums.BD, "36 is kick lane")
check(drums.gm_sound(46).glyph == "o", "46 is open hat")
check(drums.gm_sound(43).row == 3, "43 is floor tom")
check(drums.gm_sound(56).id == "perc", "cowbell is perc")
check(drums.gm_sound(20) == nil, "20 is not a drum")

local learned = {}
local s, gm = inputs.lookup(1, learned, 10, 38)
check(s.id == "snare" and gm == 38, "gm profile passes snare through")
s = inputs.lookup(2, learned, 9, 60)
check(s.id == "hh_closed", "channels profile: channel 9 is closed hat")
inputs.learn(1, learned, 10, 38, "clap")
check(inputs.lookup(1, learned, 10, 38).id == "clap", "learned pad wins")
check(inputs.lookup(2, learned, 2, 38).id == "snare", "learning is per profile")
check(inputs.count(1, learned) == 1, "learned count")
local v = inputs.validate({ schema = 1, learned = { gm = { ["10:38"] = "clap", bad = "kick", ["1:2"] = "nope" } } })
check(v.gm["10:38"] == "clap" and v.gm.bad == nil and v.gm["1:2"] == nil, "validate drops bad entries")
check(next(inputs.validate(nil)) == nil, "validate nil")
v = inputs.validate({ schema = 1, learned = { rytm = { ["1:36"] = "kick" } } })
check(v.channels and v.channels["1:36"] == "kick" and v.rytm == nil, "old rytm pads move to channels")
inputs.clear(1, learned)
check(inputs.count(1, learned) == 0, "clear")

-- ---------- demo song ----------
local song = assert(Song.load("demo/rumpali_demo.mid"))
check(near(song.ref_bpm, 100, 0.01), "demo ref bpm 100")
check(#song.countdowns == 2, "demo has start + break countdowns (" .. #song.countdowns .. ")")
local beat = 0.6
check(near(song.countdowns[1].at, 0) and near(song.countdowns[1].beats[1], -4 * beat), "start countdown is the bar before bar 1")
check(near(song.start, -2.4), "start at count-in")
check(near(song.countdowns[2].at, 10 * 4 * beat), "break countdown ends at bar 11")
check(near(song.countdowns[2].beats[1], 9 * 4 * beat), "break countdown is bar 10")
for lane = 1, 5 do check(song.lanes_used[lane], "demo uses lane " .. lane) end
check(song:bar_at(0) == 1 and song:bar_at(2.41) == 2 and song:bar_at(-1) == 0, "bar numbers")
local cd, n = Song.countdown_at(song.countdowns, -2.4)
check(cd and n == 4, "countdown shows 4 first")
cd, n = Song.countdown_at(song.countdowns, -0.1)
check(cd and n == 1, "countdown shows 1 last")
check(Song.countdown_at(song.countdowns, 0.0) == nil, "no countdown once the bar starts")
song:find_countdowns(3)
check(#song.countdowns == 1, "a 2-bar rest doesn't count with gap 3")
song:find_countdowns(2)
-- same-lane same-tick dedupe: bar 13 beat 1 has ride + bell -> one cue, the bell
local bar13 = 12 * 4 * beat
local cy = {}
for _, c in ipairs(song.chart) do if near(c.s, bar13) and c.lane == drums.CY then cy[#cy + 1] = c end end
check(#cy == 1 and cy[1].sound.id == "bell", "ride+bell on one tick -> one cue")

-- ---------- judge ----------
local j = Judge.new(song.chart)
local first = song.chart[1]
local r, cue, ms = j:hit(first.lane, first.s + 0.020, 1, true)
check(r == "perfect" and cue == first and ms == 20, "20 ms late is perfect")
r = j:hit(first.lane, first.s + 0.020, 1, true)
check(r == "extra", "a cue only counts once")
-- second kick cue: 60 ms early is good
local k2
for i = 2, #song.chart do if song.chart[i].lane == drums.BD then k2 = song.chart[i]; break end end
r, cue, ms = j:hit(drums.BD, k2.s - 0.060, 1, true)
check(r == "good" and ms == -60, "60 ms early is good")
-- half speed: song-time error 0.040 is 80 ms real -> good, not perfect
local k3
for i = 1, #song.chart do local c = song.chart[i]; if c.lane == drums.BD and c.s > k2.s then k3 = c; break end end
r, cue, ms = j:hit(drums.BD, k3.s + 0.040, 0.5, true)
check(r == "good" and ms == 80, "windows are in real time at half speed")
j:advance(song.finish + 1, 1)
local tot = j:totals()
check(tot.perfect + tot.good + tot.miss == #song.chart, "every cue judged at the end")
check(tot.extra == 1, "one extra")
check(Judge.mean_ms({ err_sum = 0.03, err_n = 2 }) == 15, "mean ms")
check(Judge.accuracy({ perfect = 1, good = 2, miss = 1 }) == 50, "accuracy")
j:reset()
check(j:totals().perfect == 0 and not song.chart[1].result, "reset")

-- ---------- optional: a local file passed on the command line ----------
if arg[1] then
  local s2 = assert(Song.load(arg[1]))
  print(("%s: %d cues, %.1f bpm, start %.2f, %d countdowns"):format(
    s2.name, #s2.chart, s2.ref_bpm, s2.start, #s2.countdowns))
  for i, c in ipairs(s2.countdowns) do
    print(("  countdown %d: %.2f .. %.2f"):format(i, c.beats[1], c.at))
  end
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
