local MDT = MDT
local L = MDT.L
local db

-- Beacon HUD - shows next pull info with a mini-map preview of the dungeon area
local Beacon = {}
MDT.NextPullBeacon = Beacon

local beaconFrame

-- Mini-map constants
local MINIMAP_SIZE = 150        -- viewport width/height
local MINIMAP_TILE_SIZE = 22    -- each scaled-down tile (original is ~56 at 840 map)
local MINIMAP_SCALE = MINIMAP_TILE_SIZE / (840 / 15) -- ~0.393

---Loads dungeon map textures into the mini-map tiles
local function loadMinimapTextures(dungeonIdx, sublevel)
  if not beaconFrame or not beaconFrame.minimapTiles then return end
  local dungeonMaps = MDT.dungeonMaps and MDT.dungeonMaps[dungeonIdx]
  if not dungeonMaps then return end
  local textureInfo = dungeonMaps[sublevel] or dungeonMaps[1]
  if not textureInfo then return end

  for i = 1, 10 do
    for j = 1, 15 do
      local tileIdx = (i - 1) * 15 + j
      local tile = beaconFrame.minimapTiles[tileIdx]
      if tile then
        local texName
        if type(textureInfo) == "string" then
          local mapName = MDT.mapInfo[dungeonIdx] and MDT.mapInfo[dungeonIdx].englishName or ""
          texName = "Interface\\WorldMap\\" .. mapName .. "\\" .. textureInfo .. tileIdx
        elseif type(textureInfo) == "table" then
          texName = textureInfo.customTextures .. "\\" .. (sublevel or 1) .. "_" .. tileIdx .. ".png"
        end
        if texName then
          tile:SetTexture(texName)
          tile:Show()
        else
          tile:Hide()
        end
      end
    end
  end
end

---Calculates the centroid of all enemy clones in a pull (on the current sublevel)
local function calculatePullCentroid(pull, dungeonIdx, sublevel)
  if not pull then return nil, nil end
  local enemies = MDT.dungeonEnemies[dungeonIdx]
  if not enemies then return nil, nil end
  local sumX, sumY, count = 0, 0, 0
  for enemyIdx, clones in pairs(pull) do
    if tonumber(enemyIdx) and enemies[enemyIdx] then
      for _, cloneIdx in ipairs(clones) do
        local clone = enemies[enemyIdx].clones and enemies[enemyIdx].clones[cloneIdx]
        if clone and (clone.sublevel == sublevel or not clone.sublevel) then
          sumX = sumX + clone.x
          sumY = sumY + clone.y
          count = count + 1
        end
      end
    end
  end
  if count == 0 then return nil, nil end
  return sumX / count, sumY / count
end

---Updates enemy dots on the mini-map
local function updateMinimapDots(state, pulls, dungeonIdx, sublevel)
  if not beaconFrame or not beaconFrame.dots then return end
  local enemies = MDT.dungeonEnemies[dungeonIdx]
  if not enemies then return end

  -- Hide all existing dots
  for _, dot in ipairs(beaconFrame.dots) do
    dot:Hide()
  end

  local dotIdx = 0
  local function getDot()
    dotIdx = dotIdx + 1
    local dot = beaconFrame.dots[dotIdx]
    if not dot then
      dot = beaconFrame.minimapContainer:CreateTexture(nil, "OVERLAY")
      dot:SetTexture("Interface\\AddOns\\MythicDungeonTools\\Textures\\Circle_White")
      dot:SetSize(6, 6)
      beaconFrame.dots[dotIdx] = dot
    end
    return dot
  end

  -- Draw dots for relevant pulls (next, +/-1 for context)
  local nextPull = state.currentNextPull
  if not nextPull then return end

  for pullIdx = math.max(1, nextPull - 1), math.min(#pulls, nextPull + 1) do
    local pull = pulls[pullIdx]
    if pull then
      local pullState = state.pullStates[pullIdx] and state.pullStates[pullIdx].state
      -- Color: next=green, active=orange, completed=gray, upcoming=yellow
      local r, g, b, a
      if pullState == "next" then
        r, g, b, a = 0, 1, 0.5, 1
      elseif pullState == "active" then
        r, g, b, a = 1, 0.5, 0, 1
      elseif pullState == "completed" then
        r, g, b, a = 0.4, 0.4, 0.4, 0.6
      else
        r, g, b, a = 1, 1, 0, 0.7
      end

      for enemyIdx, clones in pairs(pull) do
        if tonumber(enemyIdx) and enemies[enemyIdx] then
          for _, cloneIdx in ipairs(clones) do
            local clone = enemies[enemyIdx].clones and enemies[enemyIdx].clones[cloneIdx]
            if clone and (clone.sublevel == sublevel or not clone.sublevel) then
              local dot = getDot()
              dot:SetVertexColor(r, g, b, a)
              -- Position relative to the container (scaled from original coords)
              local sx = clone.x * MINIMAP_SCALE
              local sy = clone.y * MINIMAP_SCALE
              dot:ClearAllPoints()
              dot:SetPoint("CENTER", beaconFrame.minimapContainer, "TOPLEFT", sx, sy)
              -- Next pull dots are bigger
              if pullState == "next" or pullState == "active" then
                dot:SetSize(8, 8)
              else
                dot:SetSize(5, 5)
              end
              dot:Show()
            end
          end
        end
      end
    end
  end
end

---Centers the mini-map on the next pull's centroid
local function centerMinimapOnPull(centroidX, centroidY)
  if not beaconFrame or not beaconFrame.minimapContainer then return end
  -- Scale centroid to container coords
  local sx = centroidX * MINIMAP_SCALE
  local sy = centroidY * MINIMAP_SCALE
  -- Offset the container so the centroid is centered in the viewport
  beaconFrame.minimapContainer:ClearAllPoints()
  beaconFrame.minimapContainer:SetPoint("TOPLEFT", beaconFrame.minimapFrame, "TOPLEFT",
    -sx + MINIMAP_SIZE / 2, -sy - MINIMAP_SIZE / 2)
end

local function CreateBeaconFrame()
  if beaconFrame then return beaconFrame end

  db = MDT:GetDB()

  beaconFrame = CreateFrame("Frame", "MDTNextPullBeaconFrame", UIParent)
  beaconFrame:SetSize(360, 170)
  beaconFrame:SetFrameStrata("MEDIUM")
  beaconFrame:SetClampedToScreen(true)
  beaconFrame:SetMovable(true)
  beaconFrame:EnableMouse(true)
  beaconFrame:RegisterForDrag("LeftButton")

  local anchor = db.nextPull.beacon
  beaconFrame:SetPoint(anchor.anchorFrom, UIParent, anchor.anchorTo, anchor.xoffset, anchor.yoffset)
  beaconFrame:SetScale(anchor.scale)

  -- Background (matches MDT main frame color)
  local bg = beaconFrame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(unpack(MDT.BackdropColor or { 0.058, 0.058, 0.058, 0.9 }))

  -- Subtle border around the whole beacon (matches MDT accent)
  local function createBeaconEdge(anchor, w, h, offX, offY)
    local edge = beaconFrame:CreateTexture(nil, "BORDER")
    edge:SetSize(w, h)
    edge:SetPoint(anchor, beaconFrame, anchor, offX, offY)
    edge:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    return edge
  end
  createBeaconEdge("TOPLEFT", 360, 1, 0, 0)
  createBeaconEdge("BOTTOMLEFT", 360, 1, 0, 0)
  createBeaconEdge("TOPLEFT", 1, 170, 0, 0)
  createBeaconEdge("TOPRIGHT", 1, 170, 0, 0)

  -- ============ MINI-MAP ============
  beaconFrame.minimapFrame = CreateFrame("Frame", nil, beaconFrame)
  beaconFrame.minimapFrame:SetSize(MINIMAP_SIZE, MINIMAP_SIZE)
  beaconFrame.minimapFrame:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", 8, -8)
  beaconFrame.minimapFrame:SetClipsChildren(true)

  -- Minimap background (slightly darker than beacon to distinguish)
  local mmbg = beaconFrame.minimapFrame:CreateTexture(nil, "BACKGROUND")
  mmbg:SetAllPoints()
  mmbg:SetColorTexture(0.02, 0.02, 0.02, 1)

  -- Container that holds all tile textures (scrollable via position)
  beaconFrame.minimapContainer = CreateFrame("Frame", nil, beaconFrame.minimapFrame)
  beaconFrame.minimapContainer:SetSize(15 * MINIMAP_TILE_SIZE, 10 * MINIMAP_TILE_SIZE)
  beaconFrame.minimapContainer:SetPoint("TOPLEFT", beaconFrame.minimapFrame, "TOPLEFT", 0, 0)

  -- Create the 150 mini tile textures
  beaconFrame.minimapTiles = {}
  for i = 1, 10 do
    for j = 1, 15 do
      local tileIdx = (i - 1) * 15 + j
      local tile = beaconFrame.minimapContainer:CreateTexture(nil, "ARTWORK")
      tile:SetSize(MINIMAP_TILE_SIZE, MINIMAP_TILE_SIZE)
      tile:SetPoint("TOPLEFT", beaconFrame.minimapContainer, "TOPLEFT",
        (j - 1) * MINIMAP_TILE_SIZE, -(i - 1) * MINIMAP_TILE_SIZE)
      tile:Hide()
      beaconFrame.minimapTiles[tileIdx] = tile
    end
  end

  -- Dots table (for enemy positions)
  beaconFrame.dots = {}

  -- Minimap border overlay
  local mmborder = beaconFrame.minimapFrame:CreateTexture(nil, "OVERLAY")
  mmborder:SetAllPoints()
  mmborder:SetColorTexture(0, 1, 0.5, 0.5)
  -- Hollow rectangle effect using 4 thin textures is nicer but simpler to skip
  -- We'll just use a thin colored overlay that wraps - actually let's just do a thin border
  mmborder:Hide()

  -- Minimap border (subtle, matches beacon border)
  local function createEdge(edgeAnchor, w, h, offX, offY)
    local edge = beaconFrame.minimapFrame:CreateTexture(nil, "OVERLAY")
    edge:SetSize(w, h)
    edge:SetPoint(edgeAnchor, beaconFrame.minimapFrame, edgeAnchor, offX, offY)
    edge:SetColorTexture(0.4, 0.4, 0.4, 0.9)
    return edge
  end
  createEdge("TOPLEFT", MINIMAP_SIZE, 1, 0, 0)
  createEdge("BOTTOMLEFT", MINIMAP_SIZE, 1, 0, 0)
  createEdge("TOPLEFT", 1, MINIMAP_SIZE, 0, 0)
  createEdge("TOPRIGHT", 1, MINIMAP_SIZE, 0, 0)

  -- ============ INFO PANEL (right side) ============
  local infoX = MINIMAP_SIZE + 16
  local infoWidth = 360 - infoX - 10

  -- Pull number badge
  beaconFrame.pullBadge = beaconFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  beaconFrame.pullBadge:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoX, -10)
  beaconFrame.pullBadge:SetTextColor(0, 1, 0.5, 1)

  -- Status text (NEXT / IN COMBAT / ROUTE COMPLETE)
  beaconFrame.statusText = beaconFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  beaconFrame.statusText:SetPoint("TOPLEFT", beaconFrame.pullBadge, "BOTTOMLEFT", 0, -2)
  beaconFrame.statusText:SetTextColor(0.8, 0.8, 0.8, 1)

  -- Mob count + forces text
  beaconFrame.infoText = beaconFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  beaconFrame.infoText:SetPoint("TOPLEFT", beaconFrame.statusText, "BOTTOMLEFT", 0, -2)
  beaconFrame.infoText:SetTextColor(1, 1, 1, 1)

  -- Enemy portraits (up to 4)
  beaconFrame.portraits = {}
  for i = 1, 4 do
    local portrait = beaconFrame:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(22, 22)
    if i == 1 then
      portrait:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoX, -70)
    else
      portrait:SetPoint("LEFT", beaconFrame.portraits[i - 1], "RIGHT", 2, 0)
    end
    portrait:Hide()
    beaconFrame.portraits[i] = portrait
  end

  -- Progress bar (for active pull)
  beaconFrame.progressBar = CreateFrame("StatusBar", nil, beaconFrame)
  beaconFrame.progressBar:SetSize(infoWidth, 8)
  beaconFrame.progressBar:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoX, -102)
  beaconFrame.progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  beaconFrame.progressBar:SetStatusBarColor(0, 1, 0.5, 0.8)
  beaconFrame.progressBar:SetMinMaxValues(0, 1)
  beaconFrame.progressBar:SetValue(0)
  beaconFrame.progressBarWidth = infoWidth

  -- Preview overlay (yellow) showing what this pull will add
  beaconFrame.previewOverlay = beaconFrame.progressBar:CreateTexture(nil, "OVERLAY")
  beaconFrame.previewOverlay:SetColorTexture(1, 0.84, 0, 0.65) -- gold/yellow
  beaconFrame.previewOverlay:SetHeight(8)
  beaconFrame.previewOverlay:Hide()

  local progressBg = beaconFrame.progressBar:CreateTexture(nil, "BACKGROUND")
  progressBg:SetAllPoints()
  progressBg:SetColorTexture(0, 0, 0, 0.5)

  -- Upcoming preview (next+1 pull)
  beaconFrame.upcomingText = beaconFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  beaconFrame.upcomingText:SetPoint("TOPLEFT", beaconFrame.progressBar, "BOTTOMLEFT", 0, -4)
  beaconFrame.upcomingText:SetTextColor(0.6, 0.6, 0.6, 1)
  beaconFrame.upcomingText:SetScale(0.85)

  -- Drag handling
  beaconFrame:SetScript("OnDragStart", function(self)
    if not db.nextPull.beacon.locked then
      self:StartMoving()
    end
  end)
  beaconFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local _, _, _, x, y = self:GetPoint()
    db.nextPull.beacon.xoffset = x
    db.nextPull.beacon.yoffset = y
  end)

  beaconFrame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and IsShiftKeyDown() then
      db.nextPull.beacon.locked = not db.nextPull.beacon.locked
      local lockState = db.nextPull.beacon.locked and L["Locked"] or L["Unlocked"]
      print("|cFF00FF00MDT|r: Beacon " .. lockState)
    end
  end)

  beaconFrame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
      MenuUtil.CreateContextMenu(self, function(ownerRegion, rootDescription)
        rootDescription:CreateTitle(L["Next Pull Beacon"])
        rootDescription:CreateCheckbox(L["Locked"], function() return db.nextPull.beacon.locked end, function()
          db.nextPull.beacon.locked = not db.nextPull.beacon.locked
        end)
        rootDescription:CreateCheckbox(L["Show Upcoming"], function() return db.nextPull.beacon.showUpcoming end, function()
          db.nextPull.beacon.showUpcoming = not db.nextPull.beacon.showUpcoming
          Beacon:Update()
        end)
        rootDescription:CreateButton(L["Hide Beacon"], function()
          db.nextPull.beacon.enabled = false
          beaconFrame:Hide()
        end)
        rootDescription:CreateButton(L["Stop Tracking"], function()
          MDT:NextPull_Stop()
        end)
      end)
    end
  end)

  -- Manual control buttons (shown on hover)
  local function createControlButton(parent, texture, offsetX, tooltip, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", offsetX, -4)
    btn:SetNormalTexture(texture)
    btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    btn:SetAlpha(0)
    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self) self:SetAlpha(1) end)
    btn:SetScript("OnLeave", function(self) self:SetAlpha(0) end)
    return btn
  end

  beaconFrame.completeBtn = createControlButton(beaconFrame, "Interface\\RAIDFRAME\\ReadyCheck-Ready", -4,
    L["Mark Complete"], function()
      local state = MDT.nextPullState
      if state and state.active then
        for i, ps in ipairs(state.pullStates) do
          if ps.state == "active" or ps.state == "next" then
            MDT:NextPull_MarkComplete(i)
            return
          end
        end
      end
    end)

  beaconFrame.skipBtn = createControlButton(beaconFrame, "Interface\\MINIMAP\\MiniMap-VignetteArrow", -22,
    L["Skip Pull"], function()
      local state = MDT.nextPullState
      if state and state.active and state.currentNextPull then
        local nextIdx = state.currentNextPull + 1
        if nextIdx <= #state.pullStates then
          MDT:NextPull_SkipTo(nextIdx)
        end
      end
    end)

  beaconFrame.revertBtn = createControlButton(beaconFrame, "Interface\\BUTTONS\\UI-RefreshButton", -40,
    L["Revert Pull"], function()
      local state = MDT.nextPullState
      if state and state.active and state.currentNextPull then
        local prevIdx = state.currentNextPull - 1
        if prevIdx >= 1 then
          MDT:NextPull_MarkIncomplete(prevIdx)
        end
      end
    end)

  beaconFrame:SetScript("OnEnter", function(self)
    self.completeBtn:SetAlpha(0.7)
    self.skipBtn:SetAlpha(0.7)
    self.revertBtn:SetAlpha(0.7)
  end)
  beaconFrame:SetScript("OnLeave", function(self)
    if not MouseIsOver(self) then
      self.completeBtn:SetAlpha(0)
      self.skipBtn:SetAlpha(0)
      self.revertBtn:SetAlpha(0)
    end
  end)

  beaconFrame:Hide()
  return beaconFrame
end

---Updates the Beacon HUD with current next pull state
function Beacon:Update()
  if not db then db = MDT:GetDB() end
  if not db.nextPull.beacon.enabled then
    if beaconFrame then beaconFrame:Hide() end
    return
  end

  local state = MDT.nextPullState
  if not state or not state.active then
    if beaconFrame then beaconFrame:Hide() end
    return
  end

  -- Role check: hide for non-tanks unless overridden or user manually started tracking
  if not db.nextPull.beacon.showForNonTank and not state.manuallyStarted then
    local role = GetSpecializationRole and GetSpecializationRole(GetSpecialization() or 0) or nil
    if role ~= "TANK" then
      if beaconFrame then beaconFrame:Hide() end
      return
    end
  end

  if not beaconFrame then CreateBeaconFrame() end

  local dungeonIdx = state.dungeonIdx
  local enemies = MDT.dungeonEnemies[dungeonIdx]
  local totalForcesMax = MDT.dungeonTotalCount[dungeonIdx] and MDT.dungeonTotalCount[dungeonIdx].normal or 1
  local preset = MDT:GetCurrentPreset()
  local pulls = preset and preset.value and preset.value.pulls
  local sublevel = (preset and preset.value and preset.value.currentSublevel) or 1

  local nextPull = state.currentNextPull

  if not nextPull then
    -- Route complete
    local totalKilled = 0
    for _, ps in ipairs(state.pullStates) do
      totalKilled = totalKilled + ps.totalForces
    end
    local overUnder = totalKilled - totalForcesMax
    local pctText = string.format("%.1f%%", (overUnder / totalForcesMax) * 100)
    beaconFrame.pullBadge:SetText(L["Done"])
    beaconFrame.statusText:SetText(L["Route Complete"])
    beaconFrame.infoText:SetText((overUnder >= 0 and "+" or "") .. pctText .. " " .. L["forces"])
    beaconFrame.progressBar:SetValue(1)
    beaconFrame.previewOverlay:Hide()
    beaconFrame.upcomingText:SetText("")
    for i = 1, 4 do beaconFrame.portraits[i]:Hide() end
    for _, dot in ipairs(beaconFrame.dots) do dot:Hide() end
    beaconFrame:Show()
    return
  end

  local ps = state.pullStates[nextPull]
  local pull = pulls and pulls[nextPull]

  -- Pull badge
  beaconFrame.pullBadge:SetText(L["Pull"] .. " " .. nextPull)

  -- Status
  if ps.state == "active" then
    beaconFrame.statusText:SetText(L["In Combat"])
    beaconFrame.statusText:SetTextColor(1, 0.3, 0.3, 1)
  else
    beaconFrame.statusText:SetText(L["Next"])
    beaconFrame.statusText:SetTextColor(0, 1, 0.5, 1)
  end

  -- Mob count and forces: show "12 mobs | Current: 15.2% + 8.0% (pull)"
  -- Current forces % read from scenario API (tries both modern and legacy APIs)
  local function parseQty(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v:match("(%d+%.?%d*)")) or 0 end
    return 0
  end
  local function getStepInfo2()
    if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
      local i = C_ScenarioInfo.GetScenarioStepInfo()
      if i then return i.numCriteria or 0 end
    end
    if C_Scenario and C_Scenario.GetStepInfo then
      return select(3, C_Scenario.GetStepInfo()) or 0
    end
    return 0
  end
  local function getCritInfo2(idx)
    if C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo then
      return C_ScenarioInfo.GetCriteriaInfo(idx)
    end
    if C_Scenario and C_Scenario.GetCriteriaInfo then
      return C_Scenario.GetCriteriaInfo(idx)
    end
    return nil
  end
  local currentPct
  local numCriteria = getStepInfo2()
  local bestPct, bestTotal = nil, 0
  for i = 1, numCriteria do
    local info = getCritInfo2(i)
    if info then
      local q = parseQty(info.quantity)
      local tq = parseQty(info.totalQuantity)
      -- Weighted progress: quantity is already the 0-100 percentage shown in-game.
      if info.isWeightedProgress and tq > 0 then
        currentPct = q
        break
      end
      if tq > bestTotal and tq > 10 then
        bestTotal = tq
        bestPct = (q / tq) * 100
      end
    end
  end
  if currentPct == nil then currentPct = bestPct end

  local pullPct = (ps.totalForces / totalForcesMax) * 100
  local basePctForText = currentPct or 0

  -- Route target: cumulative forces % from pull 1 through this pull (from MDT preset)
  local cumulativeForces = 0
  for i = 1, nextPull do
    local sps = state.pullStates[i]
    if sps then cumulativeForces = cumulativeForces + (sps.totalForces or 0) end
  end
  local targetPct = (cumulativeForces / totalForcesMax) * 100

  local currentStr = string.format("|cFF00BFFF%.1f%%|r", basePctForText)
  local pullStr = string.format("|cFFFFD700+%.1f%%|r", pullPct)
  local targetStr = string.format("|cFF00FF7F%.1f%%|r", targetPct)
  beaconFrame.infoText:SetText(ps.totalCount .. " " .. L["mobs"] .. "  " ..
    currentStr .. " " .. pullStr .. " / " .. targetStr)

  -- Progress bar: blue fill = current dungeon forces, yellow overlay = this pull preview
  local barWidth = beaconFrame.progressBarWidth or 180
  local basePct = currentPct or 0
  beaconFrame.progressBar:SetValue(basePct / 100)
  beaconFrame.progressBar:SetStatusBarColor(0, 0.75, 1, 0.8) -- blue

  -- Yellow overlay showing this pull's contribution (always visible while a pull exists)
  local startPct = math.min(basePct, 100)
  local endPct = math.min(basePct + pullPct, 100)
  local overlayWidth = (endPct - startPct) / 100 * barWidth
  if overlayWidth > 0.5 then
    beaconFrame.previewOverlay:ClearAllPoints()
    beaconFrame.previewOverlay:SetPoint("LEFT", beaconFrame.progressBar, "LEFT",
      (startPct / 100) * barWidth, 0)
    beaconFrame.previewOverlay:SetSize(overlayWidth, 8)
    beaconFrame.previewOverlay:Show()
  else
    beaconFrame.previewOverlay:Hide()
  end

  -- Enemy portraits
  local portraitIdx = 0
  if pull and enemies then
    for enemyIdx, clones in pairs(pull) do
      if tonumber(enemyIdx) and enemies[enemyIdx] and portraitIdx < 4 then
        portraitIdx = portraitIdx + 1
        local displayId = enemies[enemyIdx].displayId or 39490
        SetPortraitTextureFromCreatureDisplayID(beaconFrame.portraits[portraitIdx], displayId)
        beaconFrame.portraits[portraitIdx]:Show()
      end
    end
  end
  for i = portraitIdx + 1, 4 do
    beaconFrame.portraits[i]:Hide()
  end

  -- Upcoming preview (next+1)
  if db.nextPull.beacon.showUpcoming and nextPull + 1 <= #state.pullStates then
    local upPs = state.pullStates[nextPull + 1]
    if upPs and upPs.state ~= "completed" then
      local upForcePct = string.format("%.1f%%", (upPs.totalForces / totalForcesMax) * 100)
      beaconFrame.upcomingText:SetText(L["Then"] ..
        ": " .. L["Pull"] .. " " .. (nextPull + 1) .. " - " .. upPs.totalCount .. " " .. L["mobs"] .. " - " .. upForcePct)
      beaconFrame.upcomingText:Show()
    else
      beaconFrame.upcomingText:Hide()
    end
  else
    beaconFrame.upcomingText:Hide()
  end

  -- ========== MINI-MAP UPDATE ==========
  loadMinimapTextures(dungeonIdx, sublevel)
  -- Find centroid of next pull
  local cx, cy = calculatePullCentroid(pull, dungeonIdx, sublevel)
  if cx and cy then
    centerMinimapOnPull(cx, cy)
  end
  updateMinimapDots(state, pulls, dungeonIdx, sublevel)

  beaconFrame:Show()
end

---Hides the Beacon
function Beacon:Hide()
  if beaconFrame then beaconFrame:Hide() end
end

---Shows the Beacon
function Beacon:Show()
  if not beaconFrame then CreateBeaconFrame() end
  beaconFrame:Show()
end
