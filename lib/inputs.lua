-- inputs.lua
-- input profiles: which drum sound an incoming MIDI note is.
-- learned pads (per profile) take priority over the profile's own map.
-- pure Lua, no norns calls.

local drums = include("lib/drums")

local inputs = {}

-- Channels: each track sends on its own MIDI channel (track 1 on
-- channel 1 and so on), whatever the note. Track order follows a common
-- drum machine layout; learn pads if they don't land in the right lane.
local CHANNEL_TRACKS = {
  "kick",      -- 1 BD
  "snare",     -- 2 SD
  "side",      -- 3 RS
  "clap",      -- 4 CP
  "tom_floor", -- 5 BT
  "tom_floor", -- 6 LT
  "tom_mid",   -- 7 MT
  "tom_hi",    -- 8 HT
  "hh_closed", -- 9 CH
  "hh_open",   -- 10 OH
  "crash",     -- 11 CY
  "perc",      -- 12 CB
}

inputs.PROFILES = {
  {
    id = "gm",
    name = "GM",
    -- General MIDI drum notes on any channel
    lookup = function(ch, note)
      local s = drums.gm_sound(note)
      if s then return s, note end
    end,
  },
  {
    id = "channels",
    name = "Channels",
    lookup = function(ch, note)
      local id = CHANNEL_TRACKS[ch]
      if id then
        local s = drums.by_id[id]
        return s, s.gm
      end
    end,
  },
}

inputs.names = {}
for i, p in ipairs(inputs.PROFILES) do inputs.names[i] = p.name end

function inputs.key(ch, note)
  return ch .. ":" .. note
end

-- learned: { [profile id] = { ["ch:note"] = sound id } }
-- returns the sound and the GM note to play for it, or nil
function inputs.lookup(profile_index, learned, ch, note)
  local p = inputs.PROFILES[profile_index] or inputs.PROFILES[1]
  local mine = learned and learned[p.id]
  local id = mine and mine[inputs.key(ch, note)]
  if id and drums.by_id[id] then
    local s = drums.by_id[id]
    return s, s.gm
  end
  return p.lookup(ch, note)
end

function inputs.learn(profile_index, learned, ch, note, sound_id)
  local p = inputs.PROFILES[profile_index] or inputs.PROFILES[1]
  learned[p.id] = learned[p.id] or {}
  learned[p.id][inputs.key(ch, note)] = sound_id
end

function inputs.count(profile_index, learned)
  local p = inputs.PROFILES[profile_index] or inputs.PROFILES[1]
  local n = 0
  for _ in pairs(learned[p.id] or {}) do n = n + 1 end
  return n
end

function inputs.clear(profile_index, learned)
  local p = inputs.PROFILES[profile_index] or inputs.PROFILES[1]
  learned[p.id] = nil
end

-- profile ids from older versions
local RENAMED = { rytm = "channels" }

-- keep only well-formed entries from a loaded file
function inputs.validate(t)
  local out = {}
  if type(t) ~= "table" or t.schema ~= 1 or type(t.learned) ~= "table" then return out end
  for pid, map in pairs(t.learned) do
    pid = RENAMED[pid] or pid
    if type(pid) == "string" and type(map) == "table" then
      for k, id in pairs(map) do
        if type(k) == "string" and k:match("^%d+:%d+$") and drums.by_id[id] then
          out[pid] = out[pid] or {}
          out[pid][k] = id
        end
      end
    end
  end
  return out
end

return inputs
