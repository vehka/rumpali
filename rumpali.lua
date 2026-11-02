-- rumpali: drum practice
-- v0.1.0 @vehka
-- https://github.com/vehka/rumpali
--
-- plays MIDI songs, shows the
-- drum part as scrolling cues
-- and scores your pad hits
--
-- E1: page (track/free/learn)
-- track: K3 play/pause
--   K2 stop, E2 song, E3 tempo
-- learn: E2 sound, hit a pad
-- splash image credits:
--   Spencer Plouzek / Unsplash

local drums = include("lib/drums")
local inputs = include("lib/inputs")
local smf = include("lib/smf")
local Song = include("lib/song")
local Judge = include("lib/judge")
local view = include("lib/view")

local PAGES = { "track", "free", "learn" }
local TRACK_HIT_X = 36
local FREE_HIT_X = 122
local HISTORY = 4 -- seconds of free-mode hits kept

local page = 1
local song, judge
local songs_dir

-- transport: song time runs from (ref_pos at ref_time) at `rate`
local state = "stopped" -- stopped, playing, paused, done
local pos = 0
local ref_pos, ref_time, rate = 0, 0, 1
local ev_i = 1
local held = {} -- [ch*128+note] = true for backing notes sounding
local play_clock, ui_clock
local resume_countdowns = {}
local auto_i = 1

local out -- backing/hits MIDI output vport
local learned = {}
local learn_target = 1
local learn_line1, learn_line2
local last_raw

local track_hits = {} -- { s, lane, result }
local free_hits = {}  -- { t, sound, lane, vel }
local flash = {}      -- [lane] = util.time() until which the label lights
local message, message_until = nil, 0
local dirty = true
local SPLASH_SECS = 2
local splash_img, splash_until = nil, 0 -- start-up image, until key/enc or timeout

-- ---------- helpers ----------

local function msg(text, secs)
  message, message_until = text, util.time() + (secs or 1.5)
  dirty = true
end

local function now_pos()
  if state == "playing" then return ref_pos + (util.time() - ref_time) * rate end
  return pos
end

local function vport_names()
  local names = {}
  for i = 1, 16 do names[i] = i .. " " .. (midi.vports[i].name or "none") end
  return names
end

local function guide_scale()
  local g = params:get("rumpali_guide")
  return g == 1 and 0 or g == 2 and 0.35 or 1
end

-- the countdowns that can show now: the song's, plus a resume count-in
local function active_countdowns()
  if not song or state ~= "playing" then return {} end
  if #resume_countdowns == 0 then return song.countdowns end
  local all = { resume_countdowns[1] }
  for _, cd in ipairs(song.countdowns) do all[#all + 1] = cd end
  return all
end

local function rows_for_song()
  if page ~= 1 or not song then return { 1, 2, 3, 4, 5 } end
  local rows = {}
  for lane = 1, 5 do if song.lanes_used[lane] then rows[#rows + 1] = lane end end
  if #rows == 0 then rows = { 1, 2, 3, 4, 5 } end
  return rows
end

-- ---------- backing output ----------

local function note_off_all()
  if not out then return end
  for key in pairs(held) do
    out:note_off(key % 128, 0, key // 128)
  end
  held = {}
  if song then
    for ch in pairs(song.channels) do
      out:cc(64, 0, ch)
      out:cc(123, 0, ch)
    end
  end
end

local function dispatch(e)
  local hi, ch = e.st - e.st % 16, e.st % 16 + 1
  if hi == 0x90 and e.b > 0 then
    local vel = e.b
    if ch == 10 then
      local g = guide_scale()
      if g == 0 then return end
      vel = math.max(1, math.floor(vel * g + 0.5))
    else
      local b = params:get("rumpali_backing") / 100
      if b == 0 then return end
      vel = util.clamp(math.floor(vel * b + 0.5), 1, 127)
    end
    local key = ch * 128 + e.a
    if held[key] then out:note_off(e.a, 0, ch) end
    out:note_on(e.a, vel, ch)
    held[key] = true
  elseif hi == 0x80 or hi == 0x90 then
    local key = ch * 128 + e.a
    if held[key] then
      out:note_off(e.a, 0, ch)
      held[key] = nil
    end
  elseif hi == 0xC0 then
    out:program_change(e.a, ch)
  elseif hi == 0xD0 then
    out:send({ e.st, e.a })
  else
    out:send({ e.st, e.a, e.b })
  end
end

-- programs and controllers the file set before index i
local function chase(i)
  if not out then return end
  local prog, cc = {}, {}
  for k = 1, i - 1 do
    local e = song.events[k]
    local hi, ch = e.st - e.st % 16, e.st % 16 + 1
    if hi == 0xC0 then prog[ch] = e.a
    elseif hi == 0xB0 then cc[ch] = cc[ch] or {}; cc[ch][e.a] = e.b end
  end
  for ch in pairs(song.channels) do
    out:program_change(prog[ch] or 0, ch)
    for n, v in pairs(cc[ch] or {}) do out:cc(n, v, ch) end
  end
end

-- ---------- hits ----------

local function play_hit(gm_note, vel, from_port)
  if params:get("rumpali_play_hits") ~= 2 or not out then return end
  if from_port == params:get("rumpali_out") then return end -- no echo
  vel = util.clamp(math.floor(vel * params:get("rumpali_hit_boost") / 100 + 0.5), 1, 127)
  out:note_on(gm_note, vel, 10)
  clock.run(function()
    clock.sleep(0.15)
    if out then out:note_off(gm_note, 0, 10) end
  end)
end

local function register_hit(sound, vel, t)
  local lane = sound.lane
  flash[lane] = t + 0.1
  free_hits[#free_hits + 1] = { t = t, sound = sound, lane = lane, vel = vel }
  if state == "playing" and judge then
    local s = ref_pos + (t - ref_time) * rate - params:get("rumpali_latency") / 1000 * rate
    local in_countdown = Song.countdown_at(active_countdowns(), s)
    local result = judge:hit(lane, s, rate, not in_countdown)
    track_hits[#track_hits + 1] = { s = s, lane = lane, result = result }
  end
  dirty = true
end

local function learn_hit(ch, note, vel)
  local target = drums.SOUNDS[learn_target]
  inputs.learn(params:get("rumpali_profile"), learned, ch, note, target.id)
  local err = tab.save({ schema = 1, learned = learned }, norns.state.data .. "learned.data")
  if err then print("rumpali: saving learned pads failed: " .. tostring(err)) end
  learn_line1 = "ch" .. ch .. " note " .. note .. " -> " .. target.name
  learn_line2 = nil
  learn_target = util.clamp(learn_target + 1, 1, #drums.SOUNDS)
  return target
end

local function midi_event(port, data)
  local m = midi.to_msg(data)
  if m.type ~= "note_on" then return end
  local sel = params:get("rumpali_in")
  if sel > 1 and sel - 1 ~= port then return end
  local t = util.time()
  last_raw = { port = port, ch = m.ch, note = m.note, vel = m.vel }
  if page == 3 then
    local target = learn_hit(m.ch, m.note, m.vel)
    play_hit(target.gm, m.vel, port)
    dirty = true
    return
  end
  local sound, gm_note = inputs.lookup(params:get("rumpali_profile"), learned, m.ch, m.note)
  if not sound then return end
  play_hit(gm_note, m.vel, port)
  register_hit(sound, m.vel, t)
end

-- REPL helper for testing without drums: rumpali_hit(38) or rumpali_hit(38, 100, 10)
function rumpali_hit(note, vel, ch)
  midi_event(0, { 0x90 + (ch or 10) - 1, note, vel or 100 })
end

-- ---------- transport ----------

local function finish()
  note_off_all()
  state = "done"
  play_clock = nil
  dirty = true
end

local function play_loop()
  while true do
    clock.sleep(0.001)
    local p = ref_pos + (util.time() - ref_time) * rate
    local ev = song.events
    while ev[ev_i] and ev[ev_i].s <= p do
      dispatch(ev[ev_i])
      ev_i = ev_i + 1
    end
    if params:get("rumpali_autoplay") == 2 then
      local chart = song.chart
      while chart[auto_i] and chart[auto_i].s <= p do
        local cue = chart[auto_i]
        auto_i = auto_i + 1
        if math.random() > 0.05 then
          local jitter = (math.random() - 0.5) * 0.12
          local vel = cue.vel
          clock.run(function()
            clock.sleep(math.max(0, jitter + 0.03))
            if state == "playing" then register_hit(cue.sound, vel, util.time() - 0.03) end
          end)
        end
      end
    end
    judge:advance(p, rate)
    if p >= song.finish + 0.5 then
      pos = p
      finish()
      return
    end
  end
end

local function start_at(p)
  if not song or play_clock then return end
  pos = p
  ev_i = Song.index_at(song.events, p)
  auto_i = Song.index_at(song.chart, p)
  chase(ev_i)
  ref_pos, ref_time = p, util.time()
  rate = params:get("rumpali_tempo") / 100
  state = "playing"
  play_clock = clock.run(play_loop)
  dirty = true
end

local function stop_clock()
  if play_clock then
    clock.cancel(play_clock)
    play_clock = nil
  end
end

local function pause()
  if state ~= "playing" then return end
  pos = now_pos()
  stop_clock()
  note_off_all()
  state = "paused"
  dirty = true
end

-- resume one bar before the bar you paused in, with a countdown over it.
-- paused before the drums came in: start over with the song's count-in.
local function resume()
  if state ~= "paused" then return end
  local first = song.countdowns[1]
  if not first or pos < first.at then
    resume_countdowns = {}
    start_at(song.start)
    return
  end
  local bar_ticks = song:bar_ticks()
  local tick = smf.tick_at_sec(song, math.max(0, pos))
  local bar_tick = math.floor(tick / bar_ticks) * bar_ticks
  local cd = song:countdown_before_tick(bar_tick)
  resume_countdowns = { cd }
  start_at(math.max(song.start, cd.beats[1]))
end

local function rewind()
  stop_clock()
  note_off_all()
  resume_countdowns = {}
  track_hits = {}
  if judge then judge:reset() end
  pos = song and song.start or 0
  state = "stopped"
  dirty = true
end

local function play_pause()
  if not song then msg("no song"); return end
  if state == "playing" then pause()
  elseif state == "paused" then resume()
  else
    if state == "done" then rewind() end
    start_at(song.start)
  end
end

-- ---------- songs ----------

local function list_songs()
  local list = {}
  for _, f in ipairs(util.scandir(songs_dir) or {}) do
    if f:lower():match("%.midi?$") then list[#list + 1] = songs_dir .. f end
  end
  table.sort(list)
  return list
end

local function load_song(path)
  if not path or not path:lower():match("%.midi?$") then return end
  rewind()
  local s, err = Song.load(path)
  if not s then
    msg("can't load: " .. tostring(err), 3)
    print("rumpali: " .. path .. ": " .. tostring(err))
    return
  end
  song = s
  song:find_countdowns(params:get("rumpali_gap"))
  judge = Judge.new(song.chart)
  judge.perfect = params:get("rumpali_perfect") / 1000
  judge.good = params:get("rumpali_good") / 1000
  pos = song.start
  if #song.chart == 0 then msg("no drums on channel 10", 3) end
  dirty = true
end

local function step_song(d)
  local list = list_songs()
  if #list == 0 then msg("no songs in data/rumpali/songs"); return end
  local cur = params:get("rumpali_song")
  local i = 0
  for k, p in ipairs(list) do if p == cur then i = k end end
  i = util.clamp(i + d, 1, #list)
  if list[i] ~= cur then params:set("rumpali_song", list[i]) end
end

local function install_demos()
  util.make_dir(songs_dir)
  if #list_songs() == 0 then
    os.execute("cp " .. norns.state.path .. "demo/*.mid " .. songs_dir .. " 2>/dev/null")
  end
end

-- ---------- params ----------

local function add_params()
  local ports = vport_names()
  local default_out = 1
  for i = 1, 16 do
    if midi.vports[i].name == "fluidsynth" then default_out = i end
  end
  local in_names = { "all" }
  for i = 1, 16 do in_names[i + 1] = ports[i] end

  params:add_separator("rumpali_sep", "RUMPALI")

  params:add_group("rumpali_song_group", "song", 7)
  params:add_file("rumpali_song", "song", songs_dir)
  params:set_action("rumpali_song", load_song)
  params:add_number("rumpali_tempo", "tempo", 25, 150, 100, function(p) return p:get() .. "%" end)
  params:set_action("rumpali_tempo", function(v)
    if state == "playing" then
      ref_pos, ref_time = now_pos(), util.time()
    end
    rate = v / 100
    dirty = true
  end)
  params:add_option("rumpali_guide", "guide drums", { "off", "quiet", "full" }, 1)
  params:add_number("rumpali_backing", "backing volume", 0, 150, 100, function(p) return p:get() .. "%" end)
  params:add_number("rumpali_gap", "countdown after", 1, 16, 2, function(p)
    return p:get() .. (p:get() == 1 and " bar" or " bars") .. " rest"
  end)
  params:set_action("rumpali_gap", function(v)
    if song then song:find_countdowns(v); dirty = true end
  end)
  params:add_number("rumpali_zoom", "zoom", 16, 80, 40, function(p) return p:get() .. " px/beat" end)
  params:set_action("rumpali_zoom", function() dirty = true end)
  params:add_option("rumpali_autoplay", "autoplay (test)", { "off", "on" }, 1)
  params:set_save("rumpali_autoplay", false) -- never comes back on by itself

  params:add_group("rumpali_judge_group", "timing", 4)
  params:add_number("rumpali_latency", "latency", -150, 150, 0, function(p) return p:get() .. " ms" end)
  params:add_number("rumpali_perfect", "perfect window", 10, 80, 35, function(p) return "±" .. p:get() .. " ms" end)
  params:set_action("rumpali_perfect", function(v) if judge then judge.perfect = v / 1000 end end)
  params:add_number("rumpali_good", "good window", 30, 200, 90, function(p) return "±" .. p:get() .. " ms" end)
  params:set_action("rumpali_good", function(v) if judge then judge.good = v / 1000 end end)
  params:add_trigger("rumpali_calibrate", "latency += last mean")
  params:set_action("rumpali_calibrate", function()
    if not judge then return end
    local m = Judge.mean_ms(judge:totals())
    if m then
      params:delta("rumpali_latency", m)
      msg("latency " .. params:get("rumpali_latency") .. " ms")
    else
      msg("no hits to calibrate from")
    end
  end)

  params:add_group("rumpali_midi_group", "midi", 5)
  params:add_option("rumpali_in", "drums in", in_names, 1)
  params:add_option("rumpali_profile", "drum kit", inputs.names, 1)
  params:set_action("rumpali_profile", function() dirty = true end)
  params:add_option("rumpali_out", "sound out", ports, default_out)
  params:set_action("rumpali_out", function(v)
    note_off_all()
    out = midi.connect(v)
  end)
  params:add_option("rumpali_play_hits", "play my hits", { "off", "on" }, 2)
  params:add_number("rumpali_hit_boost", "my hits velocity", 50, 400, 100, function(p) return p:get() .. "%" end)
end

-- ---------- norns callbacks ----------

local function end_splash()
  splash_img = nil
  dirty = true
end

function init()
  local ok, img = pcall(screen.load_png, norns.state.path .. "img/splash.png")
  if ok then
    splash_img, splash_until = img, math.huge
    redraw() -- show it while the rest of init runs
  end

  songs_dir = norns.state.data .. "songs/"
  install_demos()

  local ok, saved = pcall(tab.load, norns.state.data .. "learned.data")
  learned = inputs.validate(ok and saved or nil)

  for i = 1, 16 do
    local port = i
    midi.connect(i).event = function(data) midi_event(port, data) end
  end

  add_params()
  params:read(norns.state.data .. "settings.pset", true)
  params:bang()
  if not song then
    local list = list_songs()
    if list[1] then params:set("rumpali_song", list[1]) end
  end

  ui_clock = clock.run(function()
    while true do
      clock.sleep(1 / 30)
      if splash_img and util.time() >= splash_until then end_splash() end
      if dirty or state == "playing" or page == 2 then
        redraw()
        dirty = false
      end
    end
  end)
  -- count the splash time from here, so a slow load doesn't eat into it
  if splash_img then splash_until = util.time() + SPLASH_SECS end
end

function enc(n, d)
  if splash_img then end_splash(); return end
  if n == 1 then
    local new = util.clamp(page + d, 1, #PAGES)
    if new ~= page then
      if page == 1 then pause() end
      page = new
      if page == 1 then msg("track", 0.8) end
    end
  elseif page == 1 then
    if n == 2 then
      if state == "playing" then msg("stop first (K2)") else step_song(d) end
    elseif n == 3 then params:delta("rumpali_tempo", d) end
  elseif page == 2 then
    if n == 3 then params:delta("rumpali_zoom", d) end
  elseif page == 3 then
    if n == 2 then learn_target = util.clamp(learn_target + d, 1, #drums.SOUNDS) end
  end
  dirty = true
end

local clear_armed_until = 0

function key(n, z)
  if z ~= 1 then return end
  if splash_img then end_splash(); return end
  if page == 1 then
    if n == 3 then play_pause()
    elseif n == 2 then
      if state == "stopped" then msg(song and song.name or "no song")
      else rewind() end
    end
  elseif page == 2 then
    if n == 2 then free_hits = {} end
  elseif page == 3 then
    if n == 3 then
      local p = params:get("rumpali_profile")
      if util.time() < clear_armed_until then
        inputs.clear(p, learned)
        tab.save({ schema = 1, learned = learned }, norns.state.data .. "learned.data")
        learn_line1, learn_line2 = "learned pads cleared", nil
        clear_armed_until = 0
      else
        learn_line1, learn_line2 = "K3 again to clear", nil
        clear_armed_until = util.time() + 2
      end
    end
  end
  dirty = true
end

local function header_message(default_mid)
  if message and util.time() < message_until then return message, 15 end
  return default_mid, 8
end

local function bpm_text()
  if not song then return "" end
  return math.floor(song.ref_bpm * rate + 0.5) .. "bpm"
end

local function draw_track()
  if state == "done" and judge then
    view.results(judge, song.name, rows_for_song())
    return
  end
  local t = util.time()
  local p = now_pos()
  -- drop hits that have scrolled off
  local pps = params:get("rumpali_zoom") * (song and song.ref_bpm or 120) / 60
  local oldest = p - TRACK_HIT_X / pps
  while track_hits[1] and track_hits[1].s < oldest do table.remove(track_hits, 1) end

  local left, mid, mid_level, right
  if song then
    left = "b" .. song:bar_at(p)
    if state == "stopped" then
      mid, mid_level = header_message(song.name)
      right = bpm_text()
    else
      local last = judge.last
      if last and last.result ~= "extra" then
        local txt = last.result == "miss" and "miss" or
          (last.result .. " " .. (last.err_ms > 0 and "+" or "") .. last.err_ms)
        mid, mid_level = txt, last.result == "perfect" and 15 or 8
      end
      local m, ml = header_message(nil)
      if m then mid, mid_level = m, ml end
      local tot = judge:totals()
      right = state == "paused" and "paused" or (tot.perfect + tot.good) .. "/" .. tot.miss
    end
  else
    mid, mid_level = header_message("no song")
  end
  view.track({
    song = song, now = p, pps = pps, hit_x = TRACK_HIT_X, rows = rows_for_song(),
    hits = track_hits, flash = flash, now_t = t,
    countdowns = active_countdowns(),
    header = { left = left, mid = mid, mid_level = mid_level, right = right },
  })
end

local function draw_free()
  local t = util.time()
  while free_hits[1] and free_hits[1].t < t - HISTORY do table.remove(free_hits, 1) end
  local tempo = params:get("clock_tempo")
  local last = free_hits[#free_hits]
  local mid, ml = header_message(nil)
  view.free({
    now_t = t, pps = params:get("rumpali_zoom") * tempo / 60, hit_x = FREE_HIT_X,
    hits = free_hits, flash = flash,
    header = { left = "FREE", mid = mid, mid_level = ml,
      right = last and (drums.LANES[last.lane].name .. " " .. last.vel) or nil },
  })
end

local function draw_learn()
  local p = params:get("rumpali_profile")
  local line2 = learn_line2
  if not line2 and last_raw then
    line2 = "last: port " .. last_raw.port .. " ch" .. last_raw.ch .. " n" .. last_raw.note
  end
  view.learn({
    profile = inputs.names[p], target = learn_target,
    line1 = learn_line1, line2 = line2, count = inputs.count(p, learned),
  })
end

function redraw()
  screen.clear()
  if splash_img then screen.display_image(splash_img, 0, 0)
  elseif page == 1 then draw_track()
  elseif page == 2 then draw_free()
  else draw_learn() end
  screen.update()
end

function cleanup()
  stop_clock()
  note_off_all()
  if ui_clock then clock.cancel(ui_clock); ui_clock = nil end
  if songs_dir then params:write(norns.state.data .. "settings.pset") end
end
