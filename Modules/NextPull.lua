local MDT = MDT
local L = MDT.L
local db

local strsplit, tonumber, pairs, ipairs = strsplit, tonumber, pairs, ipairs
local GetTime, CombatLogGetCurrentEventInfo = GetTime, CombatLogGetCurrentEventInfo

local eventFrame = CreateFrame("Frame")
local nameplateFrame = CreateFrame("Frame") -- separate frame to avoid taint from CLEU
local STATE_COMPLETED = "completed"
local STATE_ACTIVE = "active"
local STATE_NEXT = "next"
local STATE_UPCOMING = "upcoming"

---Initializes the nextPullState data model from the current preset's pulls
---@param preset table The current preset
---@return table|nil state The initialized state, or nil if no pulls
local function buildStateFromPreset(preset)
  local pulls = preset.value.pulls
  if not pulls or #pulls == 0 then return nil end

  local dungeonIdx = preset.value.currentDungeonIdx or MDT:GetDB().currentDungeonIdx
  local enemies = MDT.dungeonEnemies[dungeonIdx]
  if not enemies then return nil end

  local state = {
    active = true,
    dungeonIdx = dungeonIdx,
    presetUID = preset.uid,
    pullStates = {},
    npcIdToPulls = {},
    seenGUIDs = {},
    currentNextPull = nil,
    authoritative = true,
    lastSyncTime = 0,
  }

  -- Build pullStates and npcIdToPulls reverse index
  for pullIdx, pull in ipairs(pulls) do
    local totalCount = 0
    local totalForces = 0
    for enemyIdx, clones in pairs(pull) do
      if tonumber(enemyIdx) then
        local enemyData = enemies[enemyIdx]
        if enemyData then
          local cloneCount = #clones
          totalCount = totalCount + cloneCount
          totalForces = totalForces + (enemyData.count or 0) * cloneCount

          -- Build reverse index: npcId -> list of pullIdx
          local npcId = enemyData.id
          if npcId then
            if not state.npcIdToPulls[npcId] then
              state.npcIdToPulls[npcId] = {}
            end
            -- Track how many of this NPC are in this pull
            local found = false
            for _, entry in ipairs(state.npcIdToPulls[npcId]) do
              if entry.pullIdx == pullIdx then
                entry.count = entry.count + cloneCount
                found = true
                break
              end
            end
            if not found then
              table.insert(state.npcIdToPulls[npcId], { pullIdx = pullIdx, count = cloneCount })
            end
          end
        end
      end
    end

    state.pullStates[pullIdx] = {
      state = STATE_UPCOMING,
      killedCount = 0,
      forcesKilled = 0,
      totalCount = totalCount,
      totalForces = totalForces,
      lastUpdate = 0,
    }
  end

  -- Set the first pull as "next"
  if #state.pullStates > 0 then
    state.pullStates[1].state = STATE_NEXT
    state.currentNextPull = 1
  end

  return state
end

---Recomputes which pull is "next" after a state change
local function recomputeNextPull(state)
  local oldNext = state.currentNextPull
  state.currentNextPull = nil

  for pullIdx, ps in ipairs(state.pullStates) do
    if ps.state == STATE_NEXT then
      -- Clear any stale "next" markers
      ps.state = STATE_UPCOMING
    end
  end

  -- Find the lowest-numbered pull that is neither completed nor active
  for pullIdx, ps in ipairs(state.pullStates) do
    if ps.state ~= STATE_COMPLETED and ps.state ~= STATE_ACTIVE then
      ps.state = STATE_NEXT
      state.currentNextPull = pullIdx
      break
    end
  end

  return state.currentNextPull ~= oldNext
end

---Finds the best pull to attribute a kill to
---Priority: active > next > lowest upcoming
---@param state table The nextPullState
---@param npcId number The NPC ID from the combat log
---@return number|nil pullIdx The pull index to attribute the kill to
local function findBestPullForKill(state, npcId)
  local candidates = state.npcIdToPulls[npcId]
  if not candidates then return nil end

  local activePull, nextPull, lowestUpcoming = nil, nil, nil

  for _, entry in ipairs(candidates) do
    local ps = state.pullStates[entry.pullIdx]
    if ps and ps.state ~= STATE_COMPLETED then
      -- Check if this pull still needs kills of this NPC type
      -- We track kills per pull globally, so just check total
      if ps.killedCount < ps.totalCount then
        if ps.state == STATE_ACTIVE and not activePull then
          activePull = entry.pullIdx
        elseif ps.state == STATE_NEXT and not nextPull then
          nextPull = entry.pullIdx
        elseif ps.state == STATE_UPCOMING and (not lowestUpcoming or entry.pullIdx < lowestUpcoming) then
          lowestUpcoming = entry.pullIdx
        end
      end
    end
  end

  return activePull or nextPull or lowestUpcoming
end

---Records a kill against a pull and handles state transitions
local function recordKill(state, pullIdx)
  local ps = state.pullStates[pullIdx]
  if not ps then return false end

  ps.killedCount = ps.killedCount + 1
  ps.lastUpdate = GetTime()

  -- Transition next -> active on first kill
  if ps.state == STATE_NEXT then
    ps.state = STATE_ACTIVE
  end

  -- Transition active -> completed when all mobs are dead
  if ps.killedCount >= ps.totalCount then
    ps.state = STATE_COMPLETED
    recomputeNextPull(state)
    return true -- state changed significantly
  end

  return true
end

---Parse a value that might be a string or number, returning the first numeric token
local function parseNum(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v:match("(%d+%.?%d*)"))
    return n or 0
  end
  return 0
end

---Gets scenario step info, trying both legacy C_Scenario and modern C_ScenarioInfo APIs
local function getStepInfo()
  -- Modern API (WoW 10.0+)
  if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
    local info = C_ScenarioInfo.GetScenarioStepInfo()
    if info then return info.numCriteria or 0 end
  end
  -- Legacy API fallback
  if C_Scenario and C_Scenario.GetStepInfo then
    return select(3, C_Scenario.GetStepInfo()) or 0
  end
  return 0
end

---Gets criteria info, trying modern then legacy APIs
local function getCriteriaInfo(idx)
  if C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo then
    return C_ScenarioInfo.GetCriteriaInfo(idx)
  end
  if C_Scenario and C_Scenario.GetCriteriaInfo then
    return C_Scenario.GetCriteriaInfo(idx)
  end
  return nil
end

---Reads the current enemy forces from the scenario API, converted to absolute count.
---Scenario APIs report forces either as weighted percent (q=42, tq=100) or raw count
---(q=42, tq=460). Both are converted to the same absolute-count scale the preset pulls
---use, via (quantity / totalQuantity) * dungeonMax. Returns nil if we can't resolve a
---dungeon total — feeding raw percent into the consume loop stalls pull advancement.
local function getCurrentForces()
  local numCriteria = getStepInfo()
  if numCriteria == 0 then return nil end

  local state = MDT.nextPullState
  local dungeonMax = 0
  if state and state.dungeonIdx and MDT.dungeonTotalCount[state.dungeonIdx] then
    dungeonMax = MDT.dungeonTotalCount[state.dungeonIdx].normal or 0
  end
  if dungeonMax == 0 and MDT.GetDB then
    local db2 = MDT:GetDB()
    local idx = db2 and db2.currentDungeonIdx
    if idx and MDT.dungeonTotalCount[idx] then
      dungeonMax = MDT.dungeonTotalCount[idx].normal or 0
    end
  end
  if dungeonMax == 0 then return nil end

  local bestAbsolute = nil
  local bestTotal = 0

  for i = 1, numCriteria do
    local info = getCriteriaInfo(i)
    if info then
      local quantity = parseNum(info.quantity)
      local totalQuantity = parseNum(info.totalQuantity)

      -- Preferred: explicitly flagged as weighted progress (typically enemy forces).
      -- Blizzard reports `quantity` as a 0-100 percentage for weighted criteria
      -- regardless of what `totalQuantity` is (it may be 100 or the dungeon max).
      if info.isWeightedProgress and totalQuantity > 0 then
        return (quantity / 100) * dungeonMax
      end

      -- Fallback: largest totalQuantity criteria (skip tiny boss-kill criteria).
      -- For non-weighted criteria we assume (quantity, totalQuantity) is a raw
      -- count pair: absolute = quantity * (dungeonMax / totalQuantity).
      if totalQuantity > bestTotal and totalQuantity > 10 then
        bestTotal = totalQuantity
        bestAbsolute = (quantity / totalQuantity) * dungeonMax
      end
    end
  end

  return bestAbsolute
end

---Dumps all scenario criteria to chat for debugging
local function dumpScenarioInfo()
  print("|cFF00FF00MDT|r: C_Scenario available = " .. tostring(C_Scenario ~= nil))
  print("|cFF00FF00MDT|r: C_ScenarioInfo available = " .. tostring(C_ScenarioInfo ~= nil))

  -- Try legacy API
  if C_Scenario and C_Scenario.GetStepInfo then
    local stepName, _, numCriteria = C_Scenario.GetStepInfo()
    print("Legacy C_Scenario.GetStepInfo: step = '" .. tostring(stepName) .. "', numCriteria = " .. tostring(numCriteria))
  end

  -- Try modern API
  if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
    local info = C_ScenarioInfo.GetScenarioStepInfo()
    if info then
      print("Modern C_ScenarioInfo.GetScenarioStepInfo: title = '" .. tostring(info.title) ..
        "', numCriteria = " .. tostring(info.numCriteria))
    else
      print("Modern C_ScenarioInfo.GetScenarioStepInfo: nil (not in scenario?)")
    end
  end

  -- Print scenario overall info
  if C_ScenarioInfo and C_ScenarioInfo.GetScenarioInfo then
    local scenario = C_ScenarioInfo.GetScenarioInfo()
    if scenario then
      print("Scenario: '" .. tostring(scenario.name) .. "', stage " ..
        tostring(scenario.currentStage) .. "/" .. tostring(scenario.numStages))
    end
  end

  local numCriteria = getStepInfo()
  print("Using numCriteria = " .. tostring(numCriteria))
  for i = 1, numCriteria do
    local info = getCriteriaInfo(i)
    if info then
      print(string.format("  [%d] %s | q=%s/%s | isWP=%s | completed=%s",
        i, tostring(info.description), tostring(info.quantity),
        tostring(info.totalQuantity), tostring(info.isWeightedProgress),
        tostring(info.completed)))
    end
  end
end

-- Debug flag - enable with /mdt nextpull debug
local debugForces = false
local function debugPrint(msg)
  if debugForces then
    print("|cFF00FF00MDT-debug|r: " .. tostring(msg))
  end
end

---Advances pulls based on forces delta (scenario-based tracking, 12.0 compatible)
---When forces increase, we consume the delta by marking pulls as complete in order
local function onForcesUpdate()
  local state = MDT.nextPullState
  if not state or not state.active then
    debugPrint("skipped: no state or not active")
    return
  end

  local currentForces = getCurrentForces()
  debugPrint("poll: currentForces=" .. tostring(currentForces) ..
    " lastForces=" .. tostring(state.lastForces) ..
    " nextPull=" .. tostring(state.currentNextPull))
  if not currentForces then return end

  -- If the baseline was never seeded, treat it as 0 so this first poll
  -- attributes all pre-existing scenario forces across the route. This lets
  -- the addon catch up to reality when tracking starts mid-key.
  if state.lastForces == nil then
    state.lastForces = 0
    debugPrint("baseline set to 0 (will consume existing forces=" .. currentForces .. ")")
  end

  local delta = currentForces - state.lastForces
  if delta <= 0 then
    state.lastForces = currentForces
    return
  end
  debugPrint("DELTA " .. delta .. " detected - consuming...")

  -- Scenario rounding tolerance: Blizzard reports weighted progress as integer
  -- percentages, so the absolute-count estimate can lag actual kills by up to
  -- 1% of dungeonMax. When a delta lands within this tolerance of completing
  -- a pull, treat the pull as complete — otherwise the indicator stalls at the
  -- tick boundary for pulls that end at a high-fraction % (e.g. 42.17%).
  local dungeonMax = 0
  if state.dungeonIdx and MDT.dungeonTotalCount[state.dungeonIdx] then
    dungeonMax = MDT.dungeonTotalCount[state.dungeonIdx].normal or 0
  end
  local tolerance = dungeonMax * 0.005

  -- Consume the forces delta across pulls
  local changed = false
  local remaining = delta
  while remaining > 0 do
    local nextPull = state.currentNextPull
    if not nextPull then break end
    local ps = state.pullStates[nextPull]
    if not ps then break end

    -- First forces gain on this pull transitions it next -> active
    if ps.state == STATE_NEXT then
      ps.state = STATE_ACTIVE
      changed = true
    end

    local remainingInPull = (ps.totalForces or 0) - (ps.forcesKilled or 0)
    debugPrint("  pull " .. nextPull .. ": totalForces=" .. tostring(ps.totalForces) ..
      " forcesKilled=" .. tostring(ps.forcesKilled) ..
      " remainingInPull=" .. remainingInPull .. " remaining=" .. remaining)
    if remainingInPull <= 0 then
      -- This pull has no forces to consume (shouldn't happen), skip
      debugPrint("  pull has no forces - skipping to completed")
      ps.state = STATE_COMPLETED
      recomputeNextPull(state)
      changed = true
      -- Avoid infinite loop if a pull with 0 forces gets stuck
      if not state.currentNextPull or state.currentNextPull == nextPull then break end
    elseif remaining + tolerance >= remainingInPull then
      -- Fully completed (within scenario-integer tolerance)
      ps.forcesKilled = ps.totalForces
      ps.state = STATE_COMPLETED
      ps.lastUpdate = GetTime()
      remaining = math.max(0, remaining - remainingInPull)
      recomputeNextPull(state)
      changed = true
    else
      -- Partial kill in this pull
      ps.forcesKilled = (ps.forcesKilled or 0) + remaining
      ps.lastUpdate = GetTime()
      remaining = 0
      changed = true
    end
  end

  state.lastForces = currentForces

  if changed then
    debugPrint("State changed - currentNextPull = " .. tostring(state.currentNextPull))
    MDT:NextPull_UpdateAll()
    if state.authoritative and MDT.LiveSession_SendPullStates then
      MDT:LiveSession_SendPullStates()
    end
  end
end

---Returns a set of localized enemy names that belong to a given pull
local function getPullEnemyNames(state, pullIdx)
  if not state or not pullIdx then return nil end
  local L = MDT.L
  local dungeonIdx = state.dungeonIdx
  local enemies = MDT.dungeonEnemies[dungeonIdx]
  if not enemies then return nil end

  local preset = MDT:GetCurrentPreset()
  local pulls = preset and preset.value and preset.value.pulls
  if not pulls or not pulls[pullIdx] then return nil end

  local names = {}
  for enemyIdx, clones in pairs(pulls[pullIdx]) do
    if tonumber(enemyIdx) and enemies[enemyIdx] then
      local englishName = enemies[enemyIdx].name
      if englishName then
        local localizedName = L[englishName] or englishName
        names[localizedName] = true
        names[englishName] = true
      end
    end
  end
  return names
end

-- Raid marker index to use for next-pull mobs (1=star, 2=circle, 3=diamond,
-- 4=triangle, 5=moon, 6=square, 7=cross, 8=skull)
local NEXT_PULL_MARKER = 1 -- star
local markedUnits = {} -- unit token -> true (tracks which units we marked)

-- WoW 12.0 secret-value guard (Blizzard restricts NPC info in instances)
local function isSecret(value)
  if issecretvalue and issecretvalue(value) then return true end
  return false
end

---Safely gets a unit's name, returns nil if the value is secret (12.0 instanced content)
local function safeUnitName(unit)
  local name = UnitName(unit)
  if name == nil or isSecret(name) then return nil end
  return name
end

---Safely checks if unit is dead, returns false if the value is secret
local function safeUnitIsDead(unit)
  local dead = UnitIsDead(unit)
  if isSecret(dead) then return false end
  return dead and true or false
end

---Scans visible nameplates and sets raid markers on next-pull mobs
---In 12.0 instances, UnitName returns secret values so this is a no-op there
function MDT:NextPull_UpdateNameplates()
  -- Step 1: Gather nameplate unit info BEFORE accessing MDT state (avoids taint)
  -- Use safe wrappers that return nil for secret values (12.0 instanced content)
  local unitData = {} -- { unit, unitName, isDead, currentMarker }
  local nameplates = C_NamePlate.GetNamePlates()
  for _, nameplate in ipairs(nameplates) do
    local unit = nameplate.namePlateUnitToken
    if unit then
      local unitName = safeUnitName(unit)
      local isDead = safeUnitIsDead(unit)
      local currentMarker = GetRaidTargetIndex(unit)
      if isSecret(currentMarker) then currentMarker = nil end
      unitData[#unitData + 1] = { unit = unit, unitName = unitName, isDead = isDead, currentMarker = currentMarker }
    end
  end

  -- Step 2: Access MDT state to get next pull names
  local state = self.nextPullState
  local nextPullNames = state and getPullEnemyNames(state, state.currentNextPull) or nil

  -- Step 3: Apply/remove markers using pre-fetched data
  for _, data in ipairs(unitData) do
    if nextPullNames and data.unitName and nextPullNames[data.unitName] and not data.isDead then
      -- Mark this mob if it's not already marked
      if data.currentMarker ~= NEXT_PULL_MARKER then
        SetRaidTarget(data.unit, NEXT_PULL_MARKER)
      end
      markedUnits[data.unit] = true
    else
      -- Clear our marker if we set it
      if markedUnits[data.unit] and data.currentMarker == NEXT_PULL_MARKER then
        SetRaidTarget(data.unit, 0)
      end
      markedUnits[data.unit] = nil
    end
  end
end

---Clears all raid markers that we set
function MDT:NextPull_ClearNameplates()
  -- Gather unit data before accessing MDT state
  local nameplates = C_NamePlate.GetNamePlates()
  for _, nameplate in ipairs(nameplates) do
    local unit = nameplate.namePlateUnitToken
    if unit and markedUnits[unit] then
      local currentMarker = GetRaidTargetIndex(unit)
      if currentMarker == NEXT_PULL_MARKER then
        SetRaidTarget(unit, 0)
      end
    end
  end
  table.wipe(markedUnits)
end

-- Separate handler for nameplate events
-- In 12.0 instances, UnitName returns secret values - safeUnitName returns nil then
nameplateFrame:SetScript("OnEvent", function(_, event, unit)
  if event == "NAME_PLATE_UNIT_ADDED" then
    -- Step 1: Query WoW APIs with secret-value guards (clean context)
    local unitName = safeUnitName(unit)
    local isDead = safeUnitIsDead(unit)
    if not unitName then return end -- 12.0 instance: info is secret, skip
    -- Step 2: Access MDT state
    local state = MDT.nextPullState
    if state and state.active then
      local nextPullNames = getPullEnemyNames(state, state.currentNextPull)
      if nextPullNames and nextPullNames[unitName] and not isDead then
        SetRaidTarget(unit, NEXT_PULL_MARKER)
        markedUnits[unit] = true
      end
    end
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    markedUnits[unit] = nil
  end
end)

---Popup dialog for prompting non-tanks on dungeon start
StaticPopupDialogs["MDT_NEXTPULL_BEACON_ASK"] = {
  text = "Mythic+ started. Display the MDT Next Pull Beacon on your screen?",
  button1 = YES,
  button2 = NO,
  button3 = "Never ask",
  OnAccept = function()
    local db2 = MDT:GetDB()
    db2.nextPull.beacon.showForNonTank = true
    MDT:NextPull_UpdateAll()
  end,
  OnCancel = function()
    local db2 = MDT:GetDB()
    db2.nextPull.beacon.showForNonTank = false
  end,
  OnAlt = function()
    local db2 = MDT:GetDB()
    db2.nextPull.beacon.showForNonTank = false
    db2.nextPull.beacon.askOnStart = false
  end,
  timeout = 30,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

---Maybe show the non-tank prompt on dungeon start
local function maybePromptForBeacon()
  if not db then db = MDT:GetDB() end
  if not db.nextPull.beacon.askOnStart then return end
  if db.nextPull.beacon.showForNonTank then return end -- already opted in
  local spec = GetSpecialization and GetSpecialization() or 0
  local role = spec and GetSpecializationRole and GetSpecializationRole(spec) or nil
  if role == "TANK" then return end -- tanks don't need to be asked
  -- Delay the popup slightly so it appears after UI is stable
  C_Timer.After(1, function()
    StaticPopup_Show("MDT_NEXTPULL_BEACON_ASK")
  end)
end

---Event handler for scenario/challenge mode events
local function onEvent(self, event, ...)
  if event == "SCENARIO_CRITERIA_UPDATE" or event == "SCENARIO_UPDATE" then
    onForcesUpdate()
  elseif event == "CHALLENGE_MODE_START" then
    if not db then db = MDT:GetDB() end
    if db.nextPull.enabled and db.nextPull.autoStartInKey then
      MDT:NextPull_Start()
    end
    maybePromptForBeacon()
  elseif event == "CHALLENGE_MODE_COMPLETED" then
    MDT:NextPull_Stop()
  elseif event == "PLAYER_ENTERING_WORLD" then
    if not db then db = MDT:GetDB() end
  end
end

eventFrame:SetScript("OnEvent", onEvent)
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

---Starts next pull tracking for the current preset
---@param manual boolean|nil if true, bypass role-based beacon hiding (explicit user intent)
function MDT:NextPull_Start(manual)
  if not db then db = self:GetDB() end
  if not db.nextPull.enabled then return end

  local preset = self:GetCurrentPreset()
  if not preset then return end

  local state = buildStateFromPreset(preset)
  if not state then
    print("|cFF00FF00MDT|r: Cannot start Next Pull tracking - no pulls in current preset.")
    return
  end

  -- Explicit manual start: force the beacon to show regardless of role
  if manual then state.manuallyStarted = true end

  -- Determine authority based on settings
  if db.nextPull.sync.authority == "auto" then
    local role = GetSpecializationRole and GetSpecializationRole(GetSpecialization() or 0) or nil
    state.authoritative = (role == "TANK")
  elseif db.nextPull.sync.authority == "self" then
    state.authoritative = true
  else
    state.authoritative = false
  end

  self.nextPullState = state

  -- Register scenario and nameplate events (scenario tracking works in 12.0)
  eventFrame:RegisterEvent("SCENARIO_CRITERIA_UPDATE")
  eventFrame:RegisterEvent("SCENARIO_UPDATE")
  eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
  eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
  eventFrame:RegisterEvent("PLAYER_DEAD")
  eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
  nameplateFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
  nameplateFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

  -- Seed the baseline at 0 so the first poll attributes any pre-existing
  -- scenario forces across the route. This matters when starting tracking
  -- mid-key (manual start after reload, joining an in-progress key): the
  -- consume-loop will advance currentNextPull to wherever the forces counter
  -- says we actually are, instead of stalling on pull 1.
  state.lastForces = 0

  -- Start a polling timer as a fallback in case SCENARIO_CRITERIA_UPDATE doesn't fire
  if self.nextPullPollTimer then self.nextPullPollTimer:Cancel() end
  self.nextPullPollTimer = C_Timer.NewTicker(1.0, function()
    if MDT.nextPullState and MDT.nextPullState.active then
      onForcesUpdate()
    end
  end)

  self:NextPull_UpdateAll()
  print("|cFF00FF00MDT|r: Next Pull tracking started. Pull 1 is next.")
end

---Stops next pull tracking
function MDT:NextPull_Stop()
  self.nextPullState = nil

  eventFrame:UnregisterEvent("SCENARIO_CRITERIA_UPDATE")
  eventFrame:UnregisterEvent("SCENARIO_UPDATE")
  eventFrame:UnregisterEvent("PLAYER_REGEN_DISABLED")
  eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
  eventFrame:UnregisterEvent("PLAYER_DEAD")

  if self.nextPullPollTimer then
    self.nextPullPollTimer:Cancel()
    self.nextPullPollTimer = nil
  end
  nameplateFrame:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
  nameplateFrame:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")

  self:NextPull_ClearNameplates()
  self:NextPull_UpdateAll()
  print("|cFF00FF00MDT|r: Next Pull tracking stopped.")
end

---Returns the current next pull index, or nil if tracking is inactive
---@return number|nil
function MDT:NextPull_GetNextPull()
  local state = self.nextPullState
  if not state or not state.active then return nil end
  return state.currentNextPull
end

---Returns the state of a specific pull, or nil
---@param pullIdx number
---@return string|nil state One of "completed", "active", "next", "upcoming"
function MDT:NextPull_GetPullState(pullIdx)
  local state = self.nextPullState
  if not state or not state.active then return nil end
  local ps = state.pullStates[pullIdx]
  if not ps then return nil end
  return ps.state
end

---Returns the pull state data for a specific pull
---@param pullIdx number
---@return table|nil pullState The pull state struct
function MDT:NextPull_GetPullStateData(pullIdx)
  local state = self.nextPullState
  if not state or not state.active then return nil end
  return state.pullStates[pullIdx]
end

---Returns whether next pull tracking is active
---@return boolean
function MDT:NextPull_IsActive()
  return self.nextPullState ~= nil and self.nextPullState.active
end

---Mark a specific pull as completed
---@param pullIdx number
function MDT:NextPull_MarkComplete(pullIdx)
  local state = self.nextPullState
  if not state or not state.active then return end
  local ps = state.pullStates[pullIdx]
  if not ps then return end

  ps.state = STATE_COMPLETED
  ps.killedCount = ps.totalCount
  ps.forcesKilled = ps.totalForces
  ps.lastUpdate = GetTime()
  recomputeNextPull(state)
  self:NextPull_UpdateAll()

  if state.authoritative and MDT.LiveSession_SendPullStates then
    MDT:LiveSession_SendPullStates()
  end
end

---Mark a specific pull as not yet completed (revert to upcoming/next)
---@param pullIdx number
function MDT:NextPull_MarkIncomplete(pullIdx)
  local state = self.nextPullState
  if not state or not state.active then return end
  local ps = state.pullStates[pullIdx]
  if not ps then return end

  ps.state = STATE_UPCOMING
  ps.killedCount = 0
  ps.forcesKilled = 0
  ps.lastUpdate = GetTime()
  recomputeNextPull(state)
  self:NextPull_UpdateAll()

  if state.authoritative and MDT.LiveSession_SendPullStates then
    MDT:LiveSession_SendPullStates()
  end
end

---Skip directly to a specific pull (mark all prior as completed)
---@param pullIdx number
function MDT:NextPull_SkipTo(pullIdx)
  local state = self.nextPullState
  if not state or not state.active then return end
  if not state.pullStates[pullIdx] then return end

  for i, ps in ipairs(state.pullStates) do
    if i < pullIdx then
      ps.state = STATE_COMPLETED
      ps.killedCount = ps.totalCount
      ps.forcesKilled = ps.totalForces
    elseif i == pullIdx then
      ps.state = STATE_NEXT
      ps.killedCount = 0
      ps.forcesKilled = 0
    else
      if ps.state ~= STATE_COMPLETED then
        ps.state = STATE_UPCOMING
        ps.killedCount = 0
        ps.forcesKilled = 0
      end
    end
    ps.lastUpdate = GetTime()
  end
  state.currentNextPull = pullIdx
  -- Reset forces baseline so we don't over-consume next update
  state.lastForces = getCurrentForces()
  self:NextPull_UpdateAll()

  if state.authoritative and MDT.LiveSession_SendPullStates then
    MDT:LiveSession_SendPullStates()
  end
end

---Notifies all visual consumers to update
function MDT:NextPull_UpdateAll()
  -- Update blip glows
  if self.DungeonEnemies_UpdateNextPullGlow then
    self:DungeonEnemies_UpdateNextPullGlow()
  end
  -- Redraw hull outlines (they check next-pull state internally)
  if self.DrawAllHulls and self.main_frame and self.main_frame.mapPanelFrame then
    self:DrawAllHulls(nil, true)
  end
  -- Update pull button state icons
  if self.UpdatePullButtonStates then
    self:UpdatePullButtonStates()
  end
  -- Update nameplate glows in the game world
  if self.NextPull_UpdateNameplates then
    self:NextPull_UpdateNameplates()
  end
  -- Update beacon (pcall to prevent taint errors from breaking other updates)
  if self.NextPullBeacon and self.NextPullBeacon.Update then
    local ok, err = pcall(self.NextPullBeacon.Update, self.NextPullBeacon)
    if not ok then
      print("|cFF00FF00MDT|r: Beacon error: " .. tostring(err))
    end
  end
end

---Slash command handler for /mdt nextpull
function MDT:NextPull_SlashCommand(args)
  if not db then db = self:GetDB() end
  local cmd, param = args:match("^(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower() or ""

  if cmd == "start" then
    self:NextPull_Start(true) -- manual = true (bypass role filter)
  elseif cmd == "stop" then
    self:NextPull_Stop()
  elseif cmd == "skip" then
    local pullNum = tonumber(param)
    if pullNum then
      self:NextPull_SkipTo(pullNum)
      print("|cFF00FF00MDT|r: Skipped to pull " .. pullNum)
    else
      print("|cFF00FF00MDT|r: Usage: /mdt nextpull skip <number>")
    end
  elseif cmd == "complete" then
    local state = self.nextPullState
    if state and state.active and state.currentNextPull then
      -- Find the lowest active or next pull and complete it
      for i, ps in ipairs(state.pullStates) do
        if ps.state == STATE_ACTIVE or ps.state == STATE_NEXT then
          self:NextPull_MarkComplete(i)
          print("|cFF00FF00MDT|r: Marked pull " .. i .. " as completed.")
          return
        end
      end
    end
    print("|cFF00FF00MDT|r: No active pull to complete.")
  elseif cmd == "status" then
    local state = self.nextPullState
    if state and state.active then
      local nextPull = state.currentNextPull
      if nextPull then
        local ps = state.pullStates[nextPull]
        print("|cFF00FF00MDT|r: Next pull is #" .. nextPull ..
          " (mobs " .. ps.killedCount .. "/" .. ps.totalCount ..
          ", forces " .. tostring(ps.forcesKilled) .. "/" .. tostring(ps.totalForces) ..
          ", state=" .. tostring(ps.state) .. ")")
      else
        print("|cFF00FF00MDT|r: Route complete!")
      end
      local cf = getCurrentForces()
      local dbIdx = (self.GetDB and self:GetDB().currentDungeonIdx) or "?"
      local dmax = (state.dungeonIdx and MDT.dungeonTotalCount[state.dungeonIdx]
        and MDT.dungeonTotalCount[state.dungeonIdx].normal) or 0
      print("|cFF00FF00MDT|r: scenario forces (absolute) = " .. tostring(cf) ..
        ", lastForces = " .. tostring(state.lastForces) ..
        ", dungeonIdx = " .. tostring(state.dungeonIdx) .. " (db=" .. tostring(dbIdx) .. ")" ..
        ", dungeonMax = " .. tostring(dmax))
      local numCriteria = getStepInfo()
      for i = 1, numCriteria do
        local info = getCriteriaInfo(i)
        if info then
          print(string.format("  criterion[%d]: q=%s tq=%s isWP=%s",
            i, tostring(info.quantity), tostring(info.totalQuantity),
            tostring(info.isWeightedProgress)))
        end
      end
    else
      print("|cFF00FF00MDT|r: Next Pull tracking is not active.")
    end
  elseif cmd == "debug" then
    debugForces = not debugForces
    print("|cFF00FF00MDT|r: Debug logging " .. (debugForces and "ON" or "OFF"))
  elseif cmd == "poll" then
    onForcesUpdate()
    print("|cFF00FF00MDT|r: Forced scenario poll.")
  elseif cmd == "info" then
    -- Comprehensive diagnostics
    if not db then db = self:GetDB() end
    print("|cFF00FF00MDT diagnostics|r:")
    print("  Feature enabled: " .. tostring(db.nextPull.enabled))
    print("  Auto-start in key: " .. tostring(db.nextPull.autoStartInKey))
    print("  Beacon enabled: " .. tostring(db.nextPull.beacon.enabled))
    print("  Show for non-tank: " .. tostring(db.nextPull.beacon.showForNonTank))
    local spec = GetSpecialization and GetSpecialization() or 0
    local role = spec and GetSpecializationRole and GetSpecializationRole(spec) or "?"
    print("  Your spec role: " .. tostring(role))
    print("  Current dungeon idx: " .. tostring(db.currentDungeonIdx))
    local preset = self:GetCurrentPreset()
    local pulls = preset and preset.value and preset.value.pulls
    print("  Current preset: " .. tostring(preset and preset.text or "?"))
    print("  Preset pull count: " .. tostring(pulls and #pulls or 0))
    print("  Tracking active: " .. tostring(self:NextPull_IsActive()))
    print("  In challenge mode: " .. tostring(C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive()))
    local cf = getCurrentForces()
    print("  Scenario forces (absolute): " .. tostring(cf))
    if role ~= "TANK" and not db.nextPull.beacon.showForNonTank then
      print("  |cFFFF6060WARNING: Beacon hidden because you are not TANK. Run '/mdt nextpull alltanks' to show for all roles.|r")
    end
    print("--- Raw scenario criteria ---")
    dumpScenarioInfo()
  elseif cmd == "alltanks" or cmd == "allroles" then
    if not db then db = self:GetDB() end
    db.nextPull.beacon.showForNonTank = not db.nextPull.beacon.showForNonTank
    print("|cFF00FF00MDT|r: Beacon showForNonTank = " ..
      tostring(db.nextPull.beacon.showForNonTank) ..
      (db.nextPull.beacon.showForNonTank and " (visible for all roles)" or " (tank only)"))
    self:NextPull_UpdateAll()
  else
    print("|cFF00FF00MDT|r: Usage: /mdt nextpull <start|stop|skip N|complete|status|debug|poll|info|alltanks>")
  end
end

-- Register CHALLENGE_MODE_START for auto-start
eventFrame:RegisterEvent("CHALLENGE_MODE_START")
