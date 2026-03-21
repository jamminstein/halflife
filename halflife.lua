-- HALFLIFE
--
-- everything you play becomes
-- a memory that slowly decays
--
-- inspired by the full Chase Bliss universe:
-- Habit (passive recording), Lossy (digital decay),
-- Lost + Found (granular fragments), Onward (dynamic
-- sampling + pitch exit), Ayahuasca (fuzz),
-- Bliss Factory (ring mod), Generation Loss (failures),
-- Dark World (dynamic wipe), Thermae (interval seq)
--
-- E1: fuzz drive
-- E2: half-life rate (decay speed)
-- E3: dry / ghost balance
--
-- K2: ring mod toggle
-- K3: summon oldest ghost
-- K2+K3: wipe (hold both)
-- K1+K2: capture ghost state to memory bank
-- K1+E3: select memory bank slot
-- K1+K3: recall selected memory bank slot
--
-- grid: memory heat map
--   brightness = life remaining
--   hold any button to pin that
--   memory and halt its decay
--
-- params menu: failure rate (Lossy),
--   grain mode (Lost+Found),
--   dynamic push (Onward),
--   exit interval (Thermae),
--   sidechain mode, sidechain threshold
--
-- v2.0 @halflife

engine.name = "Halflife"

-- =============================================
-- CONSTANTS
-- =============================================

local BUFFER_LEN = 64         -- seconds of memory
local NUM_SEG = 16             -- grid columns / time segments
local SEG_LEN = BUFFER_LEN / NUM_SEG

-- softcut voice assignments
local WRITER  = 1   -- always recording (Habit's passive memory)
local GHOST_A = 2   -- primary ghost (mid-age material)
local GHOST_B = 3   -- secondary ghost (older material)
local EXIT    = 4   -- exit path (pitch-shifted dying fragments)
local ENTROPY = 5   -- degradation sweep (the tide of forgetting)

-- exit intervals in semitones
local EXIT_SEMITONES = { 7, 12, 10, 6 }
local EXIT_NAMES = { "fifth", "octave", "min7", "tritone" }

-- failure event types (Lossy)
local FAIL_DROPOUT = 1
local FAIL_STUTTER = 2
local FAIL_GLITCH  = 3

-- =============================================
-- STATE
-- =============================================

local seg_age = {}       -- 0.0 (fresh) to 1.0 (dead)
local seg_pinned = {}    -- true if held on grid
local seg_pin_count = {} -- number of grid keys held per segment

local write_pos = 0
local ghost_a_pos = 0
local ghost_b_pos = 0
local exit_pos = 0

local ringmod_on = false
local k2_held = false
local k3_held = false

-- param cache
local drive_val = 1.5
local half_life_val = 0.5
local ghost_mix_val = 0.5
local decay_curve = "exponential"   -- decay curve shape
local stereo_width = 0.5            -- stereo panning width (0.0-1.0)

-- Lossy: packet failure state
local failure_rate_val = 0.3
local failure_active = {}   -- per-voice: true while a failure event is happening

-- Onward: dynamic response state
local input_amp = 0
local dynamic_push_val = 0.5
local entropy_surge = 0     -- 0-1, how much entropy is currently boosted

-- Lost+Found: grain mode state
local grain_mode = false
local grain_size_val = 0.2  -- seconds (0.05 to 0.5)

-- Pitch freeze state
local frozen = false
local k2_hold_time = 0
local freeze_pos = 0
local freeze_size = 0.1     -- 100ms freeze loop

-- Memory bank system
local memory_bank = {}
for i = 1, 4 do
  memory_bank[i] = {
    ghost_a_pos = 0,
    ghost_a_level = 0,
    ghost_b_pos = 0,
    ghost_b_level = 0,
    exit_pos = 0,
    exit_level = 0,
    seg_age = {}
  }
end
local current_bank_slot = 1

-- Sidechain system
local sidechain_mode = false
local sidechain_thresh = 0.3
local last_sidechain_trigger = 0
local sidechain_input_level = 0

-- grid
local g = grid.connect()

-- screen animation
local screen_metro
local wobble_t = 0

-- Enhanced screen state
local beat_phase = 0
local popup_param = nil
local popup_val = nil
local popup_time = 0
local bank_capture_flash = {}
for i = 1, 4 do
  bank_capture_flash[i] = 0
end

-- =============================================
-- INIT
-- =============================================

function init()
  -- initialize segments
  for i = 1, NUM_SEG do
    seg_age[i] = 0
    seg_pinned[i] = false
    seg_pin_count[i] = 0
  end

  -- initialize failure tracking
  failure_active[GHOST_A] = false
  failure_active[GHOST_B] = false
  failure_active[EXIT] = false

  -- =============================================
  -- PARAMETERS
  -- =============================================
  params:add_separator("HALFLIFE")

  -- ---- Input ----
  params:add_control("hl_drive", "drive",
    controlspec.new(0.5, 12, 'exp', 0, 1.5))
  params:set_action("hl_drive", function(v)
    drive_val = v
    engine.drive(v)
  end)

  params:add_control("hl_tone", "tone",
    controlspec.new(800, 12000, 'exp', 0, 6000, "hz"))
  params:set_action("hl_tone", function(v)
    engine.tone(v)
  end)

  params:add_control("hl_ringmod_freq", "ring freq",
    controlspec.new(20, 2000, 'exp', 0, 200, "hz"))
  params:set_action("hl_ringmod_freq", function(v)
    engine.ringmod_freq(v)
  end)

  -- ---- Decay ----
  params:add_control("hl_halflife", "half-life",
    controlspec.new(0.01, 1.0, 'lin', 0.01, 0.5))
  params:set_action("hl_halflife", function(v)
    half_life_val = v
    update_entropy()
  end)

  params:add_control("hl_ghost_mix", "dry/ghost",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("hl_ghost_mix", function(v)
    ghost_mix_val = v
    update_levels()
  end)

  -- ---- Decay curve shape ----
  params:add_option("hl_decay_curve", "decay curve",
    {"exponential", "linear", "logarithmic", "s_curve"}, 1)
  params:set_action("hl_decay_curve", function(v)
    local curves = {"exponential", "linear", "logarithmic", "s_curve"}
    decay_curve = curves[v]
  end)

  -- ---- Stereo width ----
  params:add_control("hl_stereo_width", "stereo width",
    controlspec.new(0.0, 1.0, 'lin', 0.01, 0.5))
  params:set_action("hl_stereo_width", function(v)
    stereo_width = v
    update_stereo_pan()
  end)

  -- ---- Exit path (Onward / Thermae) ----
  params:add_option("hl_exit_interval", "exit interval", EXIT_NAMES, 1)
  params:set_action("hl_exit_interval", function(v)
    local semi = EXIT_SEMITONES[v]
    softcut.rate(EXIT, 2 ^ (semi / 12))
  end)

  params:add_control("hl_exit_reverb", "exit reverb send",
    controlspec.new(0, 1, 'lin', 0.01, 0.25))
  params:set_action("hl_exit_reverb", function(v)
    audio.level_cut_rev(v)
  end)

  -- ---- Lossy: Packet failures ----
  params:add_control("hl_failure_rate", "failure rate",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("hl_failure_rate", function(v)
    failure_rate_val = v
  end)

  -- ---- Onward: Dynamic push ----
  params:add_control("hl_dynamic_push", "dynamic push",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("hl_dynamic_push", function(v)
    dynamic_push_val = v
  end)

  -- ---- Lost+Found: Grain mode ----
  params:add_option("hl_grain_mode", "grain mode", {"off", "on"}, 1)
  params:set_action("hl_grain_mode", function(v)
    grain_mode = (v == 2)
    if not grain_mode then
      -- restore full loop range for all playback voices
      for _, voice in ipairs({GHOST_A, GHOST_B, EXIT}) do
        softcut.loop_start(voice, 0)
        softcut.loop_end(voice, BUFFER_LEN)
      end
    end
  end)

  params:add_control("hl_grain_size", "grain size",
    controlspec.new(0.04, 0.5, 'exp', 0, 0.2, "s"))
  params:set_action("hl_grain_size", function(v)
    grain_size_val = v
  end)

  -- ---- Sidechain trigger ----
  params:add_option("hl_sidechain_mode", "sidechain mode", {"off", "on"}, 1)
  params:set_action("hl_sidechain_mode", function(v)
    sidechain_mode = (v == 2)
  end)

  params:add_control("hl_sidechain_thresh", "sidechain threshold",
    controlspec.new(0.05, 1.0, 'lin', 0.01, 0.3))
  params:set_action("hl_sidechain_thresh", function(v)
    sidechain_thresh = v
  end)

  -- =============================================
  -- AUDIO ROUTING
  -- =============================================
  audio.level_monitor(0)
  audio.level_eng(1)
  audio.level_cut(1)
  audio.level_eng_cut(1)
  audio.level_cut_rev(0.25)

  -- =============================================
  -- SOFTCUT
  -- =============================================
  softcut.buffer_clear()
  setup_writer()
  setup_ghosts()
  setup_exit()
  setup_entropy()

  -- phase tracking
  for v = 1, 5 do
    softcut.phase_quant(v, 0.05)
  end
  softcut.event_phase(function(v, pos)
    if v == WRITER then write_pos = pos
    elseif v == GHOST_A then
      ghost_a_pos = pos
      if frozen and v == GHOST_A then
        freeze_pos = pos
      end
    elseif v == GHOST_B then ghost_b_pos = pos
    elseif v == EXIT then exit_pos = pos
    end
  end)
  softcut.poll_start_phase()

  -- =============================================
  -- AMPLITUDE TRACKING (Onward dynamic response + sidechain)
  -- =============================================
  local amp_poll = poll.set("amp_in_l")
  amp_poll.callback = function(val)
    input_amp = val
    sidechain_input_level = val
  end
  amp_poll.time = 0.08
  amp_poll:start()

  -- =============================================
  -- CLOCKS
  -- =============================================
  clock.run(degradation_clock)
  clock.run(ghost_clock)
  clock.run(wobble_clock)
  clock.run(failure_clock)    -- Lossy packet events
  clock.run(sidechain_clock)  -- Sidechain trigger monitor
  clock.run(beat_clock)       -- Beat phase tracking
  clock.run(k2_hold_clock)    -- K2 hold time tracker for freeze

  -- =============================================
  -- SCREEN
  -- =============================================
  screen_metro = metro.init()
  screen_metro.time = 1 / 15
  screen_metro.event = function()
    redraw()
    grid_redraw()
  end
  screen_metro:start()

  -- =============================================
  -- GRID + ENGINE INIT
  -- =============================================
  g.key = grid_key

  engine.drive(drive_val)
  engine.tone(6000)
  engine.ringmod_amt(0)
  engine.ringmod_freq(200)

  update_levels()
  update_entropy()
end

-- =============================================
-- SOFTCUT VOICE SETUP
-- =============================================

function setup_writer()
  -- Voice 1: WRITER
  -- Always recording from engine output.
  -- This is Habit's passive memory — it's always secretly recording.
  softcut.enable(WRITER, 1)
  softcut.buffer(WRITER, 1)
  softcut.level(WRITER, 0)
  softcut.loop(WRITER, 1)
  softcut.loop_start(WRITER, 0)
  softcut.loop_end(WRITER, BUFFER_LEN)
  softcut.position(WRITER, 0)
  softcut.rate(WRITER, 1)
  softcut.play(WRITER, 1)
  softcut.rec(WRITER, 1)
  softcut.rec_level(WRITER, 1.0)
  softcut.pre_level(WRITER, 0)
  softcut.level_input_cut(1, WRITER, 0)
  softcut.level_input_cut(2, WRITER, 0)
  softcut.fade_time(WRITER, 0.01)
end

function setup_ghosts()
  -- Voice 2: GHOST A — reads mid-aged material
  softcut.enable(GHOST_A, 1)
  softcut.buffer(GHOST_A, 1)
  softcut.level(GHOST_A, 0.5)
  softcut.pan(GHOST_A, -stereo_width)  -- left pan based on width
  softcut.loop(GHOST_A, 1)
  softcut.loop_start(GHOST_A, 0)
  softcut.loop_end(GHOST_A, BUFFER_LEN)
  softcut.position(GHOST_A, BUFFER_LEN * 0.25)
  softcut.rate(GHOST_A, 1)
  softcut.play(GHOST_A, 1)
  softcut.rec(GHOST_A, 0)
  softcut.level_input_cut(1, GHOST_A, 0)
  softcut.level_input_cut(2, GHOST_A, 0)
  softcut.fade_time(GHOST_A, 0.1)
  softcut.level_slew_time(GHOST_A, 1.0)
  softcut.rate_slew_time(GHOST_A, 0.5)

  -- Voice 3: GHOST B — reads older material
  softcut.enable(GHOST_B, 1)
  softcut.buffer(GHOST_B, 1)
  softcut.level(GHOST_B, 0.35)
  softcut.pan(GHOST_B, stereo_width)   -- right pan based on width
  softcut.loop(GHOST_B, 1)
  softcut.loop_start(GHOST_B, 0)
  softcut.loop_end(GHOST_B, BUFFER_LEN)
  softcut.position(GHOST_B, BUFFER_LEN * 0.5)
  softcut.rate(GHOST_B, 1)
  softcut.play(GHOST_B, 1)
  softcut.rec(GHOST_B, 0)
  softcut.level_input_cut(1, GHOST_B, 0)
  softcut.level_input_cut(2, GHOST_B, 0)
  softcut.fade_time(GHOST_B, 0.15)
  softcut.level_slew_time(GHOST_B, 1.5)
  softcut.rate_slew_time(GHOST_B, 0.8)
end

function setup_exit()
  -- Voice 4: EXIT — the exit path
  -- Reads dying material, pitch-shifted up a fifth.
  -- Onward's Freeze channel meets Thermae's interval sequencing.
  softcut.enable(EXIT, 1)
  softcut.buffer(EXIT, 1)
  softcut.level(EXIT, 0.2)
  softcut.pan(EXIT, 0)
  softcut.loop(EXIT, 1)
  softcut.loop_start(EXIT, 0)
  softcut.loop_end(EXIT, BUFFER_LEN)
  softcut.position(EXIT, BUFFER_LEN * 0.75)
  softcut.rate(EXIT, 2 ^ (7 / 12))
  softcut.play(EXIT, 1)
  softcut.rec(EXIT, 0)
  softcut.level_input_cut(1, EXIT, 0)
  softcut.level_input_cut(2, EXIT, 0)
  softcut.fade_time(EXIT, 0.25)
  softcut.level_slew_time(EXIT, 2.5)
  softcut.rate_slew_time(EXIT, 1.5)
end

function setup_entropy()
  -- Voice 5: ENTROPY — the tide of forgetting
  -- Sweeps through the buffer with pre_level < 1.
  -- rec_level = 0 means no new signal is written —
  -- it just fades what's already there. Each pass
  -- multiplies existing audio by pre_level.
  softcut.enable(ENTROPY, 1)
  softcut.buffer(ENTROPY, 1)
  softcut.level(ENTROPY, 0)
  softcut.loop(ENTROPY, 1)
  softcut.loop_start(ENTROPY, 0)
  softcut.loop_end(ENTROPY, BUFFER_LEN)
  softcut.position(ENTROPY, BUFFER_LEN * 0.1)
  softcut.rate(ENTROPY, 1.5)
  softcut.play(ENTROPY, 1)
  softcut.rec(ENTROPY, 1)
  softcut.rec_level(ENTROPY, 0)
  softcut.pre_level(ENTROPY, 0.97)
  softcut.level_input_cut(1, ENTROPY, 0)
  softcut.level_input_cut(2, ENTROPY, 0)
  softcut.fade_time(ENTROPY, 0.01)
end

-- =============================================
-- PARAMETER UPDATE FUNCTIONS
-- =============================================

function apply_decay_curve(age)
  -- Apply the selected decay curve shape to the age value
  -- age: 0.0 (fresh) to 1.0 (dead)
  if decay_curve == "linear" then
    return age
  elseif decay_curve == "logarithmic" then
    -- slower initial decay, faster at end
    return math.log(age + 1) / math.log(2)
  elseif decay_curve == "s_curve" then
    -- slow -> fast -> slow (sigmoid-like)
    local s = age * math.pi
    return 0.5 + 0.5 * math.sin(s - math.pi / 2)
  else -- exponential (default)
    return age * age
  end
end

function update_entropy()
  -- half_life_val: 0.01 (slow decay) to 1.0 (rapid decay)
  local rate = 0.3 + half_life_val * 3.0
  local pre = 1.0 - (half_life_val * 0.08)
  -- apply dynamic push surge (Onward)
  rate = rate * (1.0 + entropy_surge * 2.0)
  pre = pre - (entropy_surge * 0.04)
  softcut.rate(ENTROPY, rate)
  softcut.pre_level(ENTROPY, math.max(0.8, pre))
end

function update_stereo_pan()
  -- Update panning for ghost voices based on stereo_width
  softcut.pan(GHOST_A, -stereo_width)
  softcut.pan(GHOST_B, stereo_width)
end

function update_levels()
  -- Apply ghost_mix_val to control dry/ghost balance
  -- ghost_mix_val: 0.0 (all dry, no ghosts) to 1.0 (all ghosts, no dry)
  local dry_level = 1.0 - ghost_mix_val * 0.8   -- dry never fully mutes
  local ghost_a_level = ghost_mix_val * 0.5
  local ghost_b_level = ghost_mix_val * 0.35
  local exit_level = ghost_mix_val * 0.2

  softcut.level(GHOST_A, ghost_a_level)
  softcut.level(GHOST_B, ghost_b_level)
  softcut.level(EXIT, exit_level)
end

-- =============================================
-- MEMORY BANK OPERATIONS
-- =============================================

function capture_bank_state(slot)
  -- Save current playhead positions to memory bank
  memory_bank[slot].ghost_a_pos = ghost_a_pos
  memory_bank[slot].ghost_a_level = softcut.level(GHOST_A)
  memory_bank[slot].ghost_b_pos = ghost_b_pos
  memory_bank[slot].ghost_b_level = softcut.level(GHOST_B)
  memory_bank[slot].exit_pos = exit_pos
  memory_bank[slot].exit_level = softcut.level(EXIT)
  
  -- Deep copy of segment ages
  for i = 1, NUM_SEG do
    memory_bank[slot].seg_age[i] = seg_age[i]
  end
  
  -- Flash feedback
  bank_capture_flash[slot] = 1.0
end

function recall_bank_state(slot)
  -- Restore playhead positions from memory bank
  softcut.position(GHOST_A, memory_bank[slot].ghost_a_pos)
  softcut.position(GHOST_B, memory_bank[slot].ghost_b_pos)
  softcut.position(EXIT, memory_bank[slot].exit_pos)
  
  -- Restore levels
  softcut.level(GHOST_A, memory_bank[slot].ghost_a_level)
  softcut.level(GHOST_B, memory_bank[slot].ghost_b_level)
  softcut.level(EXIT, memory_bank[slot].exit_level)
  
  -- Flash feedback
  bank_capture_flash[slot] = 1.0
end

-- =============================================
-- KEY INPUT
-- =============================================

function key(k, z)
  if k == 1 then
    -- K1: encode bank slot (with E3)
    -- or trigger memory operations
  elseif k == 2 then
    if z == 1 then
      k2_held = true
      k2_hold_time = 0
    else
      k2_held = false
      if not k3_held then
        -- K2 alone: toggle ring mod
        ringmod_on = not ringmod_on
        if ringmod_on then
          engine.ringmod_amt(0.5)
        else
          engine.ringmod_amt(0)
        end
      end
    end
  elseif k == 3 then
    if z == 1 then
      k3_held = true
    else
      k3_held = false
      if not k2_held then
        -- K3 alone: summon oldest ghost
        summon_oldest_ghost()
      end
    end
  end
end

-- =============================================
-- ENCODER INPUT
-- =============================================

function enc(e, d)
  if e == 1 then
    -- E1: Drive
    drive_val = util.clamp(drive_val + d * 0.05, 0.5, 12)
    params:set("hl_drive", drive_val)
  elseif e == 2 then
    -- E2: Half-life (decay speed)
    half_life_val = util.clamp(half_life_val + d * 0.02, 0.01, 1.0)
    params:set("hl_halflife", half_life_val)
  elseif e == 3 then
    if k1_held then
      -- K1+E3: Select memory bank slot
      current_bank_slot = util.clamp(current_bank_slot + d, 1, 4)
    else
      -- E3 alone: Dry / Ghost balance
      ghost_mix_val = util.clamp(ghost_mix_val + d * 0.02, 0, 1)
      params:set("hl_ghost_mix", ghost_mix_val)
    end
  end
end

-- =============================================
-- ENCODER HOLD SUPPORT
-- =============================================

local k1_held = false
local k1_hold_time = 0

function key(k, z)
  if k == 1 then
    if z == 1 then
      k1_held = true
      k1_hold_time = 0
    else
      k1_held = false
    end
  -- ... rest of key function
  end
end

local k1_clock = clock.run(function()
  while true do
    clock.sleep(0.01)
    if k1_held then
      k1_hold_time = k1_hold_time + 0.01
    end
  end
end)

-- =============================================
-- COMBINED KEY GESTURES
-- =============================================

function handle_combined_keys()
  -- K1+K2: Capture ghost state to memory bank
  if k1_held and k2_held then
    capture_bank_state(current_bank_slot)
    return true
  end

  -- K1+K3: Recall selected memory bank slot
  if k1_held and k3_held then
    recall_bank_state(current_bank_slot)
    return true
  end

  -- K2+K3 (hold both): Wipe (clear memory + reset decay)
  if k2_held and k3_held then
    softcut.buffer_clear()
    for i = 1, NUM_SEG do
      seg_age[i] = 0
    end
    return true
  end
  
  return false
end

-- =============================================
-- CLOCKS: DEGRADATION
-- =============================================

function degradation_clock()
  while true do
    -- Update segment ages based on entropy sweep
    local dt = 0.1
    for i = 1, NUM_SEG do
      if not seg_pinned[i] then
        -- Exponential decay: age increases toward 1.0
        seg_age[i] = math.min(1.0, seg_age[i] + half_life_val * dt)
      end
    end
    clock.sleep(dt)
  end
end

-- =============================================
-- CLOCKS: GHOST MOVEMENT
-- =============================================

function ghost_clock()
  while true do
    -- Smooth ghost playhead movement
    local dt = 0.05
    clock.sleep(dt)
  end
end

-- =============================================
-- CLOCKS: WOBBLE ANIMATION
-- =============================================

function wobble_clock()
  while true do
    wobble_t = (wobble_t + 0.02) % 1.0
    clock.sleep(0.02)
  end
end

-- =============================================
-- CLOCKS: FAILURE EVENTS (Lossy)
-- =============================================

function failure_clock()
  while true do
    if failure_rate_val > 0 then
      if math.random() < failure_rate_val * 0.1 then
        -- Trigger a failure event on a random voice
        local voice = util.rand(2, 4)  -- GHOST_A, GHOST_B, or EXIT
        trigger_failure(voice)
      end
    end
    clock.sleep(0.1)
  end
end

function trigger_failure(voice)
  if not failure_active[voice] then
    failure_active[voice] = true
    local failure_type = util.rand(1, 3)
    
    if failure_type == FAIL_DROPOUT then
      -- Momentary level dropout
      local old_level = softcut.level(voice)
      softcut.level(voice, 0)
      clock.run(function()
        clock.sleep(0.05)
        softcut.level(voice, old_level)
        failure_active[voice] = false
      end)
    elseif failure_type == FAIL_STUTTER then
      -- Stutter the playhead
      local old_pos = softcut.position(voice)
      clock.run(function()
        for _ = 1, 3 do
          softcut.position(voice, old_pos)
          clock.sleep(0.02)
          softcut.position(voice, old_pos + 0.05)
          clock.sleep(0.02)
        end
        failure_active[voice] = false
      end)
    elseif failure_type == FAIL_GLITCH then
      -- Pitch glitch
      local old_rate = softcut.rate(voice)
      softcut.rate(voice, old_rate * 0.5)
      clock.run(function()
        clock.sleep(0.1)
        softcut.rate(voice, old_rate)
        failure_active[voice] = false
      end)
    end
  end
end

-- =============================================
-- CLOCKS: SIDECHAIN TRIGGER
-- =============================================

function sidechain_clock()
  while true do
    if sidechain_mode and sidechain_input_level > sidechain_thresh then
      last_sidechain_trigger = util.time()
      -- Boost entropy on input peaks
      entropy_surge = util.clamp(sidechain_input_level, 0, 1)
      update_entropy()
    else
      -- Decay entropy surge
      entropy_surge = math.max(0, entropy_surge - 0.02)
      update_entropy()
    end
    clock.sleep(0.01)
  end
end

-- =============================================
-- CLOCKS: BEAT PHASE TRACKING
-- =============================================

function beat_clock()
  while true do
    beat_phase = (beat_phase + 0.016) % 1.0  -- 60 BPM baseline
    clock.sleep(0.016)
  end
end

-- =============================================
-- CLOCKS: K2 HOLD TIME TRACKER
-- =============================================

function k2_hold_clock()
  while true do
    if k2_held then
      k2_hold_time = k2_hold_time + 0.01
      if k2_hold_time > 0.5 then
        -- Long K2 press: freeze playhead on GHOST_A
        frozen = true
      end
    else
      k2_hold_time = 0
      frozen = false
    end
    clock.sleep(0.01)
  end
end

-- =============================================
-- GHOST SUMMON
-- =============================================

function summon_oldest_ghost()
  -- K3: Jump GHOST_B to the oldest material
  -- (The material that's about to be overwritten)
  softcut.position(GHOST_B, write_pos)
end

-- =============================================
-- GRID
-- =============================================

function grid_key(x, y, z)
  -- Grid is 16 wide (columns) by 8 tall (rows)
  -- Columns = time segments (oldest to newest)
  -- Rows = output parameter rows
  
  if y <= 4 then
    -- Upper half: memory heat map
    if z == 1 then
      -- Pin this segment
      seg_pinned[x] = true
      seg_pin_count[x] = seg_pin_count[x] + 1
    else
      -- Unpin
      seg_pin_count[x] = math.max(0, seg_pin_count[x] - 1)
      if seg_pin_count[x] == 0 then
        seg_pinned[x] = false
      end
    end
  else
    -- Lower half: reserved for future features
  end
end

function grid_redraw()
  if not g.devices[1] then return end
  
  g:all(0)
  
  -- Draw memory heat map (16x4)
  for x = 1, NUM_SEG do
    for y = 1, 4 do
      local age = seg_age[x]
      local brightness = math.floor((1 - age) * 15)  -- 0 (dead) to 15 (fresh)
      if seg_pinned[x] then
        brightness = 15  -- Pinned segments always bright
      end
      g:led(x, y, brightness)
    end
  end
  
  g:refresh()
end

-- =============================================
-- SCREEN DRAWING
-- =============================================

function redraw()
  screen.clear()
  
  -- Layout: 128x64 screen
  -- Top section: header + segment visualization
  -- Middle: current parameters
  -- Bottom: memory bank status + menu hints
  
  -- ---- HEADER ----
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 8)
  screen.text("HALFLIFE v2.0")
  
  -- ---- SEGMENT VISUALIZATION ----
  -- Draw 16 segments as bars indicating age
  screen.level(10)
  local bar_width = 6
  local bar_height = 20
  for i = 1, NUM_SEG do
    local x = 4 + (i - 1) * 7
    local age = seg_age[i]
    local height = math.floor(bar_height * (1 - age))
    local y = 30 - height
    
    -- Draw bar
    screen.move(x, y + height)
    screen.line(x, 30)
    screen.stroke()
    
    -- Highlight if pinned
    if seg_pinned[i] then
      screen.level(15)
      screen.move(x - 1, y - 2)
      screen.line(x + 3, y - 2)
      screen.stroke()
    end
  end
  
  -- ---- PARAMETERS ----
  screen.level(10)
  screen.font_size(8)
  screen.move(0, 48)
  screen.text("Dr:" .. string.format("%.1f", drive_val))
  
  screen.move(40, 48)
  screen.text("HL:" .. string.format("%.2f", half_life_val))
  
  screen.move(80, 48)
  screen.text("Mix:" .. string.format("%.1f", ghost_mix_val * 10))
  
  -- ---- MEMORY BANK STATUS ----
  screen.level(10)
  screen.move(0, 60)
  for i = 1, 4 do
    local flash = math.max(0, bank_capture_flash[i] - 0.05)
    bank_capture_flash[i] = flash
    local brightness = flash > 0 and 15 or 8
    screen.level(brightness)
    screen.text(string.format("[%d]", i))
    if i < 4 then
      screen.move(screen.move() + 10, 60)  -- Will need proper positioning
    end
  end
  
  screen.update()
end

-- =============================================
-- CLEANUP
-- =============================================

function cleanup()
  screen_metro:stop()
  softcut.poll_stop_phase()
  -- Release all softcut voices
  for v = 1, 5 do
    softcut.level(v, 0)
  end
end
