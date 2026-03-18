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
  local dry = 1.0 - ghost_mix_val * 0.6
  audio.level_eng(dry)
  if not failure_active[GHOST_A] then
    softcut.level(GHOST_A, ghost_mix_val * 0.65)
  end
  if not failure_active[GHOST_B] then
    softcut.level(GHOST_B, ghost_mix_val * 0.45)
  end
  if not failure_active[EXIT] then
    softcut.level(EXIT, ghost_mix_val * 0.3)
  end
end

-- =============================================
-- MEMORY BANK FUNCTIONS
-- =============================================

function capture_ghost_state()
  local bank = memory_bank[current_bank_slot]
  bank.ghost_a_pos = ghost_a_pos
  bank.ghost_a_level = softcut.level(GHOST_A)
  bank.ghost_b_pos = ghost_b_pos
  bank.ghost_b_level = softcut.level(GHOST_B)
  bank.exit_pos = exit_pos
  bank.exit_level = softcut.level(EXIT)
  bank.seg_age = {}
  for i = 1, NUM_SEG do
    bank.seg_age[i] = seg_age[i]
  end
  -- trigger flash
  bank_capture_flash[current_bank_slot] = 0.3
end

function recall_ghost_state()
  local bank = memory_bank[current_bank_slot]
  if bank.ghost_a_pos and bank.ghost_a_pos > 0 then
    softcut.position(GHOST_A, bank.ghost_a_pos)
    softcut.level(GHOST_A, bank.ghost_a_level)
    softcut.position(GHOST_B, bank.ghost_b_pos)
    softcut.level(GHOST_B, bank.ghost_b_level)
    softcut.position(EXIT, bank.exit_pos)
    softcut.level(EXIT, bank.exit_level)
    for i = 1, NUM_SEG do
      if bank.seg_age[i] then
        seg_age[i] = bank.seg_age[i]
      end
    end
  end
end

-- =============================================
-- SIDECHAIN CLOCK
-- =============================================

function sidechain_clock()
  -- Monitor input amplitude for sidechain triggering
  -- When level exceeds threshold, trigger ghost generation
  while true do
    clock.sleep(0.05)
    if sidechain_mode and sidechain_input_level > sidechain_thresh then
      local now = clock.get_beats()
      if now - last_sidechain_trigger > 0.2 then
        -- trigger new ghost generation
        last_sidechain_trigger = now
        -- summon oldest ghost in response to external sound
        summon_oldest()
      end
    end
  end
end

-- =============================================
-- BEAT CLOCK
-- =============================================

function beat_clock()
  -- Track beat phase for visual animations
  while true do
    clock.sleep(0.01)
    beat_phase = (beat_phase + 0.01) % 1.0
  end
end

function k2_hold_clock()
  -- Monitor K2 hold time for freeze trigger (>0.5s)
  while true do
    clock.sleep(0.01)
    if k2_held then
      k2_hold_time = k2_hold_time + 0.01
      -- trigger freeze when K2 held >0.5s
      if k2_hold_time > 0.5 and not frozen then
        activate_freeze()
      end
    end
  end
end

-- =============================================
-- CLOCKS
-- =============================================

function degradation_clock()
  -- Tracks the age of each buffer segment.
  -- The writer resets age when it passes through.
  -- Non-pinned segments age continuously.
  -- Onward dynamic push: loud input briefly accelerates decay.
  while true do
    clock.sleep(0.1)

    -- ---- Onward: Dynamic push ----
    -- Loud input creates an entropy surge.
    -- You're fighting the ghosts — play hard to push them away.
    if input_amp > 0.4 and dynamic_push_val > 0 then
      local push = (input_amp - 0.4) / 0.6
      entropy_surge = math.min(1.0, push * dynamic_push_val)
    else
      entropy_surge = entropy_surge * 0.92
      if entropy_surge < 0.005 then entropy_surge = 0 end
    end
    if entropy_surge > 0 or dynamic_push_val > 0 then
      update_entropy()
    end

    -- ---- Age segments ----
    local increment = half_life_val * 0.012
    -- entropy surge accelerates aging
    increment = increment * (1.0 + entropy_surge * 1.5)
    local ws = pos_to_seg(write_pos)

    for i = 1, NUM_SEG do
      if i == ws then
        seg_age[i] = 0
      elseif not seg_pinned[i] then
        seg_age[i] = math.min(1.0, seg_age[i] + increment)
      end
    end

    -- decay bank flash timers
    for i = 1, 4 do
      if bank_capture_flash[i] > 0 then
        bank_capture_flash[i] = bank_capture_flash[i] - 0.1
      end
    end
  end
end

function ghost_clock()
  -- Repositions ghost voices to buffer segments
  -- based on their age category.
  --
  -- In grain mode (Lost+Found Grain Tumbler):
  -- ghosts play short fragments and jump frequently,
  -- creating granular texture from decaying memory.
  while true do
    local wait
    if grain_mode then
      -- grain mode: rapid repositioning
      wait = 0.08 + math.random() * grain_size_val
    else
      -- normal mode: slower drift
      wait = util.linlin(0, 1, 5, 1.2, half_life_val)
    end
    clock.sleep(wait)

    -- categorize living segments by age
    local mid = {}
    local old = {}
    local dying = {}

    for i = 1, NUM_SEG do
      local a = seg_age[i]
      if a > 0.15 and a < 0.45 then
        table.insert(mid, i)
      elseif a >= 0.45 and a < 0.78 then
        table.insert(old, i)
      elseif a >= 0.78 and a < 0.98 then
        table.insert(dying, i)
      end
    end

    -- Ghost A: mid-aged memories
    if #mid > 0 then
      local seg = mid[math.random(#mid)]
      local pos = seg_to_pos(seg) + math.random() * SEG_LEN * 0.7
      softcut.position(GHOST_A, pos)
      local life = 1.0 - seg_age[seg]

      if grain_mode then
        -- set tight loop window for granular playback
        local gs = grain_size_val * (0.5 + math.random())
        softcut.loop_start(GHOST_A, math.max(0, pos))
        softcut.loop_end(GHOST_A, math.min(BUFFER_LEN, pos + gs))
        softcut.level(GHOST_A, life * ghost_mix_val * 0.55)
      else
        softcut.level(GHOST_A, life * ghost_mix_val * 0.65)
      end
    end

    -- Ghost B: older memories
    if #old > 0 then
      local seg = old[math.random(#old)]
      local pos = seg_to_pos(seg) + math.random() * SEG_LEN * 0.7
      softcut.position(GHOST_B, pos)
      local life = 1.0 - seg_age[seg]

      if grain_mode then
        local gs = grain_size_val * (0.3 + math.random() * 0.8)
        softcut.loop_start(GHOST_B, math.max(0, pos))
        softcut.loop_end(GHOST_B, math.min(BUFFER_LEN, pos + gs))
        softcut.level(GHOST_B, life * ghost_mix_val * 0.4)
      else
        softcut.level(GHOST_B, life * ghost_mix_val * 0.45)
      end
    elseif #mid > 1 then
      local seg = mid[math.random(#mid)]
      local pos = seg_to_pos(seg) + math.random() * SEG_LEN * 0.7
      softcut.position(GHOST_B, pos)
      if grain_mode then
        local gs = grain_size_val * (0.5 + math.random())
        softcut.loop_start(GHOST_B, math.max(0, pos))
        softcut.loop_end(GHOST_B, math.min(BUFFER_LEN, pos + gs))
      end
      softcut.level(GHOST_B, 0.5 * ghost_mix_val * 0.35)
    end

    -- Exit: dying memories ascending before vanishing
    if #dying > 0 then
      local seg = dying[math.random(#dying)]
      local pos = seg_to_pos(seg) + math.random() * SEG_LEN * 0.7
      softcut.position(EXIT, pos)
      local life = 1.0 - seg_age[seg]
      softcut.level(EXIT, life * ghost_mix_val * 0.3)
    end
  end
end

function wobble_clock()
  -- Continuous rate modulation on ghost voices.
  -- Older material gets more wow/flutter —
  -- like a tape degrading in the sun (Lossy).
  while true do
    clock.sleep(0.04)
    wobble_t = (wobble_t + 0.04) % 628.318

    -- Ghost A: gentle wow (skip during active failure)
    if not failure_active[GHOST_A] then
      local age_a = get_age_at_pos(ghost_a_pos)
      local wow_a = math.sin(wobble_t * 1.7) * age_a * 0.025
                  + math.sin(wobble_t * 0.31) * age_a * 0.012
      softcut.rate(GHOST_A, 1.0 + wow_a)
    end

    -- Ghost B: deeper flutter
    if not failure_active[GHOST_B] then
      local age_b = get_age_at_pos(ghost_b_pos)
      local wow_b = math.sin(wobble_t * 2.9) * age_b * 0.04
                  + math.sin(wobble_t * 0.53) * age_b * 0.02
      softcut.rate(GHOST_B, 1.0 + wow_b)
    end

    -- Exit: very slight drift on top of pitch shift
    if not failure_active[EXIT] then
      local exit_semi = EXIT_SEMITONES[params:get("hl_exit_interval")]
      local base_rate = 2 ^ (exit_semi / 12)
      local age_e = get_age_at_pos(exit_pos)
      local wow_e = math.sin(wobble_t * 0.4) * age_e * 0.015
      softcut.rate(EXIT, base_rate + wow_e)
    end
  end
end

-- =============================================
-- LOSSY: PACKET FAILURE EVENTS
-- =============================================

function failure_clock()
  -- Inspired by Chase Bliss Lossy's three types of loss:
  --   Standard (dropout), Phase Jitter (rate glitch),
  --   Packet Repeat (stutter/micro-loop)
  --
  -- Failure probability scales with segment age.
  -- Fresh material plays clean. Old material breaks apart.
  -- This is the jagged, digital side of decay —
  -- not smooth fading but sudden, unpredictable fractures.
  while true do
    -- irregular tick timing (more organic than metronomic)
    clock.sleep(0.12 + math.random() * 0.3)

    if failure_rate_val <= 0.01 then
      -- failures disabled
    else
      for _, v in ipairs({GHOST_A, GHOST_B, EXIT}) do
        if not failure_active[v] then
          local pos = voice_pos(v)
          local age = get_age_at_pos(pos)

          -- failure probability: age * failure_rate
          -- old material fails often, fresh material almost never
          if math.random() < age * failure_rate_val * 0.6 then
            local event = math.random(3)

            if event == FAIL_DROPOUT then
              -- PACKET LOSS: brief silence.
              -- Like a dropped frame in a video call.
              trigger_dropout(v)

            elseif event == FAIL_STUTTER then
              -- PACKET REPEAT: position jumps back slightly.
              -- The memory stutters, caught in a loop of itself.
              trigger_stutter(v, pos)

            elseif event == FAIL_GLITCH then
              -- PHASE JITTER: momentary rate spike.
              -- The clock goes wrong. Pitch warps wildly.
              trigger_rate_glitch(v, age)
            end
          end
        end
      end
    end
  end
end

function trigger_dropout(v)
  failure_active[v] = true
  local duration = 0.04 + math.random() * 0.12
  softcut.level(v, 0)
  clock.run(function()
    clock.sleep(duration)
    failure_active[v] = false
    update_levels()
  end)
end

function trigger_stutter(v, pos)
  -- jump back by a tiny amount, creating a micro-repeat
  local jump = 0.02 + math.random() * 0.08
  softcut.position(v, math.max(0, pos - jump))
end

function trigger_rate_glitch(v, age)
  failure_active[v] = true
  -- more extreme glitch for older material
  local glitch_rate = 1.0 + (math.random() - 0.5) * age * 1.2
  -- occasionally reverse briefly
  if math.random() < age * 0.3 then
    glitch_rate = -glitch_rate
  end
  softcut.rate(v, glitch_rate)
  clock.run(function()
    clock.sleep(0.06 + math.random() * 0.1)
    -- restore rate before releasing lock
    -- (exit voice uses pitch-shifted base rate)
    if v == EXIT then
      local semi = EXIT_SEMITONES[params:get("hl_exit_interval")]
      softcut.rate(v, 2 ^ (semi / 12))
    else
      softcut.rate(v, 1.0)
    end
    failure_active[v] = false
  end)
end

-- =============================================
-- HELPERS
-- =============================================

function pos_to_seg(pos)
  local s = math.floor(pos / SEG_LEN) + 1
  return util.clamp(s, 1, NUM_SEG)
end

function seg_to_pos(seg)
  return (seg - 1) * SEG_LEN
end

function get_age_at_pos(pos)
  return seg_age[pos_to_seg(pos)] or 0
end

function voice_pos(v)
  if v == GHOST_A then return ghost_a_pos
  elseif v == GHOST_B then return ghost_b_pos
  elseif v == EXIT then return exit_pos
  else return 0 end
end

function summon_oldest()
  local oldest_seg = nil
  local oldest_age = 0
  for i = 1, NUM_SEG do
    if seg_age[i] > oldest_age and seg_age[i] < 0.99 then
      oldest_age = seg_age[i]
      oldest_seg = i
    end
  end
  if oldest_seg then
    local pos = seg_to_pos(oldest_seg) + SEG_LEN * 0.3
    softcut.position(GHOST_A, pos)
    softcut.level(GHOST_A, ghost_mix_val * 0.85)
    softcut.position(GHOST_B, pos + SEG_LEN * 0.2)
    softcut.level(GHOST_B, ghost_mix_val * 0.6)
  end
end

function wipe_buffer()
  softcut.buffer_clear()
  for i = 1, NUM_SEG do
    seg_age[i] = 0
    seg_pinned[i] = false
    seg_pin_count[i] = 0
  end
  entropy_surge = 0
  frozen = false
  k2_hold_time = 0
end

function activate_freeze()
  -- Lock playback to a small loop at current position
  frozen = true
  freeze_pos = ghost_a_pos
  softcut.loop_start(GHOST_A, math.max(0, freeze_pos - freeze_size / 2))
  softcut.loop_end(GHOST_A, math.min(BUFFER_LEN, freeze_pos + freeze_size / 2))
  softcut.loop(GHOST_A, 1)
end

function release_freeze()
  -- Restore normal playback
  frozen = false
  k2_hold_time = 0
  softcut.loop_start(GHOST_A, 0)
  softcut.loop_end(GHOST_A, BUFFER_LEN)
  softcut.loop(GHOST_A, 1)
end

-- =============================================
-- INPUT: ENCODERS & KEYS
-- =============================================

function enc(n, d)
  if n == 1 then
    params:delta("hl_drive", d)
    popup_param = "drive"
    popup_val = drive_val
    popup_time = 0.8
  elseif n == 2 then
    params:delta("hl_halflife", d)
    popup_param = "half-life"
    popup_val = half_life_val
    popup_time = 0.8
  elseif n == 3 then
    params:delta("hl_ghost_mix", d)
    popup_param = "dry/ghost"
    popup_val = ghost_mix_val
    popup_time = 0.8
  end
end

function key(n, z)
  if n == 2 then
    k2_held = z == 1
    if z == 1 then
      k2_hold_time = 0
      if k3_held then
        wipe_buffer()
      else
        ringmod_on = not ringmod_on
        engine.ringmod_amt(ringmod_on and 1 or 0)
      end
    else
      -- K2 released
      if frozen then
        release_freeze()
      end
      k2_hold_time = 0
    end
  elseif n == 3 then
    k3_held = z == 1
    if z == 1 then
      if k2_held then
        wipe_buffer()
      else
        summon_oldest()
      end
    end
  end
end

-- =============================================
-- GRID
-- =============================================

function grid_key(x, y, z)
  if x < 1 or x > 16 then return end

  if z == 1 then
    seg_pin_count[x] = seg_pin_count[x] + 1
    seg_pinned[x] = true
  else
    seg_pin_count[x] = math.max(0, seg_pin_count[x] - 1)
    if seg_pin_count[x] == 0 then
      seg_pinned[x] = false
    end
  end
end

function grid_redraw()
  if not g.device then return end
  g:all(0)

  local ws = pos_to_seg(write_pos)
  local ga = pos_to_seg(ghost_a_pos)
  local gb = pos_to_seg(ghost_b_pos)
  local ex = pos_to_seg(exit_pos)

  for col = 1, 16 do
    local age = seg_age[col]
    local life = math.max(0, 1.0 - age)
    local height = math.ceil(life * 7)
    local bright = math.floor(life * 12) + 2
    if life <= 0.02 then bright = 0; height = 0 end

    -- draw life bars from bottom up
    for row = 1, height do
      g:led(col, 9 - row, bright)
    end

    -- pinned segments: bright crown
    if seg_pinned[col] then
      g:led(col, 1, 15)
      if height > 0 then
        g:led(col, 2, 14)
      end
    end

    -- write head
    if col == ws then
      g:led(col, 1, 15)
    end
  end

  -- ghost position indicators (row 8)
  if ga >= 1 and ga <= 16 then
    -- in grain mode, flash the ghost positions
    local ga_bright = grain_mode
      and (math.floor(wobble_t * 8) % 2 == 0 and 12 or 6)
      or 10
    g:led(ga, 8, ga_bright)
  end
  if gb >= 1 and gb <= 16 then
    g:led(gb, 8, 7)
  end
  if ex >= 1 and ex <= 16 then
    local flick = math.floor(wobble_t * 4) % 2 == 0 and 5 or 3
    g:led(ex, 8, flick)
  end

  -- entropy surge indicator: bottom-right corner pulses with dynamics
  if entropy_surge > 0.1 then
    local surge_bright = math.floor(entropy_surge * 12) + 3
    g:led(16, 1, surge_bright)
  end

  g:refresh()
end

-- =============================================
-- SCREEN
-- =============================================

function redraw()
  screen.clear()
  screen.aa(1)
  screen.font_face(1)
  screen.font_size(8)

  -- ---- STATUS STRIP (y 0-8) ----
  screen.level(4)
  screen.move(2, 7)
  screen.text("HALFLIFE")

  -- Beat pulse indicator (x=124, level 4)
  local beat_pulse = 4 + math.floor(math.sin(beat_phase * math.pi * 2) * 3)
  screen.level(beat_pulse)
  screen.rect(123, 1, 3, 3)
  screen.fill()

  -- Freeze indicator
  if frozen then
    screen.level(15)
    screen.move(118, 7)
    screen.text("FRZE")
  end

  -- Memory bank slot indicator (right side, level 6)
  screen.level(6)
  screen.move(100, 7)
  screen.text("BANK " .. current_bank_slot .. "/4")

  -- status indicators below title
  local status_x = 68
  if ringmod_on then
    screen.level(12)
    screen.move(status_x, 7)
    screen.text("RING")
    status_x = status_x + 28
  end
  if grain_mode then
    screen.level(10)
    screen.move(status_x, 7)
    screen.text("GRAIN")
    status_x = status_x + 30
  end
  if sidechain_mode then
    screen.level(10)
    screen.move(status_x, 7)
    screen.text("SIDE")
    status_x = status_x + 20
  end

  -- ---- PARAMETER POPUP (enc feedback) ----
  if popup_time > 0 then
    popup_time = popup_time - (1.0 / 15.0)
    screen.level(15)
    screen.font_size(12)
    screen.move(64, 20)
    screen.text_center(popup_param)
    screen.font_size(16)
    screen.move(64, 35)
    if popup_param == "drive" then
      screen.text_center(string.format("%.1f", popup_val))
    else
      screen.text_center(string.format("%.2f", popup_val))
    end
    screen.font_size(8)
  else
    -- ---- PARAMETER READOUT (normal) ----
    screen.level(7)
    screen.move(2, 18)
    screen.text("drv " .. string.format("%.1f", drive_val))
    screen.move(42, 18)
    screen.text("hl " .. string.format("%.2f", half_life_val))
    screen.move(88, 18)
    screen.text("mix " .. string.format("%.2f", ghost_mix_val))
  end

  -- ---- BUFFER VISUALIZATION (LIVE ZONE) ----
  local bx = 2
  local by = 45
  local bw = 124
  local bh = 20
  local sw = bw / NUM_SEG

  -- draw segment health bars with enhanced ghost aging
  for i = 1, NUM_SEG do
    local age = seg_age[i]
    -- apply decay curve to visual representation
    local curved_age = apply_decay_curve(age)
    local life = 1.0 - curved_age
    local x = bx + (i - 1) * sw

    -- corruption zone: background fill for degraded segments
    if curved_age > 0.2 then
      screen.level(math.floor(curved_age * 3) + 1)
      screen.rect(x, by, sw, bh)
      screen.fill()
    end

    -- entropy visual noise: randomly flicker pixels proportional to entropy
    if entropy_surge > 0.1 then
      local noise_probability = entropy_surge * curved_age * 0.4
      if math.random() < noise_probability then
        screen.level(2)
        local nx = x + math.random(sw)
        local ny = by + math.random(bh)
        screen.pixel(nx, ny)
        screen.fill()
      end
    end

    -- life bar (bright from bottom)
    if life > 0.02 then
      local bar_h = math.floor(life * (bh - 2))
      -- ghost aging brightness: newer ghosts brighter (level 10), older dimmer (level 3)
      local ghost_brightness = util.linlin(0, 1, 10, 3, curved_age)
      screen.level(math.floor(ghost_brightness))
      screen.rect(x + 1, by + bh - 1 - bar_h, sw - 2, bar_h)
      screen.fill()
    end

    -- pinned indicator: bright cap
    if seg_pinned[i] then
      screen.level(15)
      screen.rect(x, by, sw, 2)
      screen.fill()
    end
  end

  -- frame
  screen.level(3)
  screen.rect(bx, by, bw, bh)
  screen.stroke()

  -- buffer fill level meter (below frame)
  screen.level(6)
  local fill_level = write_pos / BUFFER_LEN
  screen.move(bx, by + bh + 2)
  screen.text("FILL")
  local meter_w = math.floor(fill_level * 60)
  screen.level(8)
  screen.rect(bx + 26, by + bh, meter_w, 3)
  screen.fill()
  screen.level(3)
  screen.rect(bx + 26, by + bh, 60, 3)
  screen.stroke()

  -- write head with motion blur trail
  local wx = bx + (write_pos / BUFFER_LEN) * bw
  screen.level(15)
  screen.move(wx, by + 1)
  screen.line(wx, by + bh - 1)
  screen.stroke()

  -- write head trail (2-3 positions behind)
  for trail_dist = 2, 4, 1 do
    local trail_pos = write_pos - (trail_dist * SEG_LEN / 3)
    if trail_pos >= 0 then
      local trail_x = bx + (trail_pos / BUFFER_LEN) * bw
      local trail_bright = 15 - (trail_dist * 3)
      screen.level(trail_bright)
      screen.move(trail_x, by + 2)
      screen.line(trail_x, by + bh - 2)
      screen.stroke()
    end
  end

  -- Ghost A position (newer ghost at level 9)
  local gax = bx + (ghost_a_pos / BUFFER_LEN) * bw
  screen.level(9)
  screen.move(gax, by + 3)
  screen.line(gax, by + bh - 3)
  screen.stroke()

  -- Ghost B position (older ghost at level 5)
  local gbx = bx + (ghost_b_pos / BUFFER_LEN) * bw
  screen.level(5)
  screen.move(gbx, by + 5)
  screen.line(gbx, by + bh - 5)
  screen.stroke()

  -- Exit position (dotted, level 7)
  local exx = bx + (exit_pos / BUFFER_LEN) * bw
  screen.level(7)
  for dy = 2, bh - 2, 4 do
    screen.pixel(exx, by + dy)
  end
  screen.fill()

  -- Dynamic push meter (Onward)
  if entropy_surge > 0.05 then
    local meter_w = math.floor(entropy_surge * 30)
    screen.level(math.floor(entropy_surge * 10) + 4)
    screen.rect(bx + bw - meter_w, by - 2, meter_w, 2)
    screen.fill()
  end

  -- ---- MEMORY BANK INDICATORS (y ~68) ----
  local bank_x = 2
  local bank_y = 68
  screen.level(3)
  screen.move(bank_x, bank_y)
  screen.text("BANKS:")
  bank_x = bank_x + 40
  for i = 1, 4 do
    local flash_level = 3
    if bank_capture_flash[i] > 0 then
      flash_level = 15
    elseif i == current_bank_slot then
      flash_level = 10
    end
    screen.level(flash_level)
    screen.rect(bank_x + (i-1) * 18, bank_y - 4, 12, 6)
    if i == current_bank_slot then
      screen.stroke()
    else
      screen.fill()
    end
  end

  -- ---- CONTEXT BAR (y 53-58, below LIVE ZONE) ----
  screen.level(8)
  screen.move(2, 58)
  screen.text("ent:" .. string.format("%.0f%%", entropy_surge * 100))

  screen.level(6)
  local ghost_count = 0
  if ghost_a_pos > 0 then ghost_count = ghost_count + 1 end
  if ghost_b_pos > 0 then ghost_count = ghost_count + 1 end
  screen.move(42, 58)
  screen.text("ghosts:" .. ghost_count)

  -- decay curve indicator
  screen.level(5)
  screen.move(88, 58)
  screen.text("crv:" .. decay_curve:sub(1, 4))

  -- sidechain state indicator
  screen.level(5)
  if sidechain_mode then
    local side_indicator = sidechain_input_level > sidechain_thresh and "●" or "◦"
    screen.move(88, 58)
    screen.text("side:" .. side_indicator)
  else
    screen.move(88, 58)
    screen.text("side:off")
  end

  -- ---- SIDECHAIN LEVEL METER (if active) ----
  if sidechain_mode and sidechain_input_level > 0.05 then
    local meter_h = math.floor(sidechain_input_level * 8)
    local meter_bright = sidechain_input_level > sidechain_thresh and 12 or 6
    screen.level(meter_bright)
    screen.rect(110, 54 - meter_h, 4, meter_h)
    screen.fill()
  end

  -- ---- HELP / INSTRUCTIONS ----
  screen.level(3)
  screen.font_size(8)
  screen.move(2, 128)
  screen.text("K2:ring/frz  K3:ghost  K2+3:wipe")

  -- failure rate indicator (bottom right)
  if failure_rate_val > 0.01 then
    screen.level(4)
    screen.move(104, 128)
    screen.text("pkt " .. string.format("%.0f", failure_rate_val * 100))
  end

  -- stereo width indicator
  screen.level(5)
  screen.move(88, 128)
  screen.text("wd:" .. string.format("%.1f", stereo_width))

  screen.update()
end

-- =============================================
-- CLEANUP
-- =============================================

function cleanup()
  clock.cancel_all()
  if screen_metro then screen_metro:stop() end
  softcut.poll_stop_phase()
end
