-- drums.lua
-- the five lanes, the drum sounds rumpali knows, and how General MIDI
-- drum notes map to them. pure Lua, no norns calls.

local drums = {}

-- top to bottom, in drum notation order
drums.LANES = {
  { id = "cy", name = "CY" },  -- cymbals: crash, ride, bell
  { id = "hh", name = "HH" },  -- hi-hat: closed, open, pedal
  { id = "sd", name = "SD" },  -- snare: snare, side stick, clap
  { id = "tm", name = "TM" },  -- toms (row = height) and other percussion
  { id = "bd", name = "BD" },  -- kick
}
drums.CY, drums.HH, drums.SD, drums.TM, drums.BD = 1, 2, 3, 4, 5

-- lane: which lane it scrolls in. glyph: how it is drawn.
-- row: height inside the lane (toms: 1 high, 2 mid, 3 floor).
-- gm: the General MIDI note played for it.
drums.SOUNDS = {
  { id = "kick",      name = "kick",       lane = 5, glyph = "block",   gm = 36 },
  { id = "snare",     name = "snare",      lane = 3, glyph = "block",   gm = 38 },
  { id = "side",      name = "side stick", lane = 3, glyph = "box",     gm = 37 },
  { id = "clap",      name = "clap",       lane = 3, glyph = "box",     gm = 39 },
  { id = "hh_closed", name = "hat closed", lane = 2, glyph = "x",       gm = 42 },
  { id = "hh_open",   name = "hat open",   lane = 2, glyph = "o",       gm = 46 },
  { id = "hh_pedal",  name = "hat pedal",  lane = 2, glyph = "pedal",   gm = 44 },
  { id = "tom_hi",    name = "tom high",   lane = 4, glyph = "tom", row = 1, gm = 48 },
  { id = "tom_mid",   name = "tom mid",    lane = 4, glyph = "tom", row = 2, gm = 45 },
  { id = "tom_floor", name = "tom floor",  lane = 4, glyph = "tom", row = 3, gm = 43 },
  { id = "crash",     name = "crash",      lane = 1, glyph = "star",    gm = 49 },
  { id = "ride",      name = "ride",       lane = 1, glyph = "dot",     gm = 51 },
  { id = "bell",      name = "ride bell",  lane = 1, glyph = "diamond", gm = 53 },
  { id = "perc",      name = "percussion", lane = 4, glyph = "diamond", gm = 56 },
}

drums.by_id = {}
for i, s in ipairs(drums.SOUNDS) do
  s.index = i
  drums.by_id[s.id] = s
end

-- General MIDI percussion key map (channel 10) -> sound id
local GM = {
  [35] = "kick", [36] = "kick",
  [37] = "side", [38] = "snare", [39] = "clap", [40] = "snare",
  [42] = "hh_closed", [44] = "hh_pedal", [46] = "hh_open",
  [41] = "tom_floor", [43] = "tom_floor",
  [45] = "tom_mid", [47] = "tom_mid",
  [48] = "tom_hi", [50] = "tom_hi",
  [49] = "crash", [52] = "crash", [55] = "crash", [57] = "crash",
  [51] = "ride", [59] = "ride", [53] = "bell",
}

-- the sound for a GM drum note, or nil for notes outside the GM drum map.
-- the other GM percussion (tambourine, cowbell, congas ...) goes to "perc".
function drums.gm_sound(note)
  local id = GM[note]
  if id then return drums.by_id[id] end
  if note >= 54 and note <= 81 then return drums.by_id.perc end
  return nil
end

return drums
