-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2025 Baz4k

local ADDON_NAME = "BazMap"

---------------------------------------------------------------------------
-- Taint mitigation: BazMap's SetAttribute calls on WorldMapFrame taint
-- the frame's attribute table. This taint propagates through GameTooltip
-- > UIWidgets when hovering Area POIs on the map. Specifically,
-- UIWidgetTemplateTextWithStateMixin:Setup reads textHeight via
-- GetStringHeight() which inherits the taint, then Clamp() does
-- arithmetic on it and errors. We wrap that Setup in a pcall so the
-- error is caught silently - the widget text may not render in that
-- specific tooltip but the tooltip itself still shows and the map is
-- fully functional. This is installed at file scope so it's in place
-- before WorldMapFrame even loads.
---------------------------------------------------------------------------

if UIWidgetTemplateTextWithStateMixin and UIWidgetTemplateTextWithStateMixin.Setup then
    local origSetup = UIWidgetTemplateTextWithStateMixin.Setup
    UIWidgetTemplateTextWithStateMixin.Setup = function(self, widgetInfo, widgetContainer)
        local ok, err = pcall(origSetup, self, widgetInfo, widgetContainer)
        -- Silently swallow taint errors; non-taint errors still propagate
    end
end

---------------------------------------------------------------------------
-- Same taint-mitigation pattern for SuperTrackablePinMixin:Update-
-- MousePropagation, which calls Frame:SetPropagateMouseClicks() - a
-- protected function. When the user opens the WorldMap (or it
-- refreshes via QUEST_LOG_UPDATE / SUPER_TRACKED_QUEST_CHANGED / etc.)
-- Blizzard's data providers iterate every quest / area POI / delve
-- entrance and Acquire pins; OnAcquired calls UpdateMousePropagation
-- on each, which hits the taint and BugSack throws ADDON_ACTION_BLOCKED.
-- Wrapping the call in pcall lets us swallow the protected-call error
-- silently. The pin loses correct mouse-pass-through behaviour for
-- that frame (a click on a pin might or might not also click through
-- to the map), but the map itself stays fully usable, no error spam.
---------------------------------------------------------------------------

if SuperTrackablePinMixin and SuperTrackablePinMixin.UpdateMousePropagation then
    local origUpdate = SuperTrackablePinMixin.UpdateMousePropagation
    SuperTrackablePinMixin.UpdateMousePropagation = function(self)
        pcall(origUpdate, self)
    end
end

---------------------------------------------------------------------------
-- And the MapCanvasPinMixin:CheckMouseButtonPassthrough path. When the
-- world map closes, Blizzard's UIPanelPanelManager fires a hide cascade
-- that re-acquires every quest pin via QuestDataProvider:AddQuest, and
-- AcquirePin calls CheckMouseButtonPassthrough on the new pin. That
-- method calls SetPassThroughButtons() directly, which is protected -
-- so once the WorldMapFrame's attribute table is tainted, the call is
-- blocked and BugSack catches an ADDON_ACTION_BLOCKED. Same pcall
-- shim swallows it: the pin loses correct passthrough behaviour for
-- that one frame, but the map closes cleanly with no error.
---------------------------------------------------------------------------

if MapCanvasPinMixin and MapCanvasPinMixin.CheckMouseButtonPassthrough then
    local origCheck = MapCanvasPinMixin.CheckMouseButtonPassthrough
    MapCanvasPinMixin.CheckMouseButtonPassthrough = function(self, ...)
        pcall(origCheck, self, ...)
    end
end

---------------------------------------------------------------------------
-- BazCore Registration
---------------------------------------------------------------------------

local addon
addon = BazCore:RegisterAddon(ADDON_NAME, {
    title = "BazMap",
    savedVariable = "BazMapDB",
    profiles = true,
    defaults = {
        mapScale        = 100,
        mapDraggable    = true,
        questScale      = 100,
        questDraggable  = true,
        detailScale     = 100,
        detailDraggable = true,
        clampToScreen   = true,
    },

    slash = { "/bazmap", "/bmap" },
    commands = {
        reset = {
            desc = "Reset all positions to defaults",
            handler = function()
                addon:SetSetting("mapPosition", nil)
                addon:SetSetting("questPosition", nil)
                addon:SetSetting("detailPosition", nil)
                addon:Print("Positions reset.")
            end,
        },
    },

    minimap = {
        label = "BazMap",
    },
})

-- addon.db is auto-wired by BazCore:CreateDBProxy() in RegisterAddon

---------------------------------------------------------------------------
-- BlizzMove compatibility
--
-- BlizzMove registers WorldMapFrame under its own addon namespace (the
-- BlizzMoveAPI:RegisterFrames call doesn't pass an addOnName, which
-- defaults to BlizzMove's own self.name = "BlizzMove"). It then attaches
-- a PanelDragBarTemplate overlay that covers the entire frame and hooks
-- its own OnMouseDown to a separate StartMoving call. The result is two
-- competing move systems on the same frame: BazMap's title-bar drag and
-- BlizzMove's overlay drag both fire on click, and BlizzMove's ignores
-- BazMap's scale - so the visual jump is proportionally larger the more
-- BazMap has scaled the frame down.
--
-- Old code called BlizzMove:DisableFrame directly with the wrong addon
-- namespace ("Blizzard_WorldMap" - silently no-op) plus the right one
-- ("BlizzMove") but no persistence. We now use the public BlizzMoveAPI
-- with permanent=true so the disable survives /reload, and call it from
-- multiple entry points to win whichever load-order race happens.
---------------------------------------------------------------------------

local blizzMoveDisabled = false

local function DisableBlizzMoveWorldMap()
    if blizzMoveDisabled then return end
    if not (BlizzMoveAPI or BlizzMove) then return end

    -- Public API path. UnregisterFrame with addOnName=nil falls through
    -- to BlizzMove.name internally, matching how the frame was originally
    -- registered. permanent=true persists to BlizzMove's SV so a later
    -- session doesn't re-acquire the conflict. UnprocessFrame inside
    -- recurses through SubFrames, so this single call also covers
    -- QuestMapFrame and the rewards/scroll sub-frames.
    if BlizzMoveAPI and BlizzMoveAPI.UnregisterFrame then
        local ok = pcall(BlizzMoveAPI.UnregisterFrame, BlizzMoveAPI, nil, "WorldMapFrame", true)
        if ok then blizzMoveDisabled = true end
    end

    -- Legacy fallback for very old BlizzMove builds without the API.
    if not blizzMoveDisabled and BlizzMove and BlizzMove.DisableFrame then
        pcall(BlizzMove.DisableFrame, BlizzMove, "BlizzMove", "WorldMapFrame")
        blizzMoveDisabled = true
    end
end

-- Attempt 1: file scope, in case BlizzMove is already loaded when BazMap
-- loads (common since both are typically loaded at login).
DisableBlizzMoveWorldMap()

-- Attempt 2: BlizzMove ADDON_LOADED, in case BlizzMove loads after
-- BazMap. Covers the rarer load order. The helper is idempotent.
local blizzMoveWatch = CreateFrame("Frame")
blizzMoveWatch:RegisterEvent("ADDON_LOADED")
blizzMoveWatch:SetScript("OnEvent", function(self, _, loadedAddon)
    if loadedAddon == "BlizzMove" then
        DisableBlizzMoveWorldMap()
        if blizzMoveDisabled then
            self:UnregisterEvent("ADDON_LOADED")
        end
    end
end)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local initialized = false

---------------------------------------------------------------------------
-- Mode detection
--
-- The World Map shows up in three distinct shapes depending on what the
-- player is doing, all sharing the same WorldMapFrame:
--
--   "map"    - M key, full map only, no side panel
--   "quest"  - L key, map + quest log list down the side
--   "detail" - clicking a tracked quest in the objective tracker (or any
--              other path that funnels through QuestMapFrame_ShowQuest-
--              Details), map + quest detail panel down the side
--
-- The detail mode is a third state that the addon used to collapse into
-- "quest" because it only checked QuestMapFrame:IsShown(). Result: clicking
-- a tracked quest applied quest-log-mode size/position to a frame whose
-- internal layout was the larger detail view, leaving a big empty area
-- inside the window. Probing DetailsFrame.questID (via the public helper
-- QuestMapFrame_GetDetailQuestID) tells us cleanly which sub-state we're
-- actually in.
---------------------------------------------------------------------------

local lastKnownMode = "map"

local function IsDetailQuestActive()
    if QuestMapFrame_GetDetailQuestID then
        return QuestMapFrame_GetDetailQuestID() ~= nil
    end
    if QuestMapFrame and QuestMapFrame.DetailsFrame then
        return QuestMapFrame.DetailsFrame:IsShown()
            and QuestMapFrame.DetailsFrame.questID ~= nil
    end
    return false
end

local function GetCurrentMode()
    if not QuestMapFrame or not QuestMapFrame:IsShown() then
        lastKnownMode = "map"
        return "map"
    end
    if IsDetailQuestActive() then
        lastKnownMode = "detail"
        return "detail"
    end
    lastKnownMode = "quest"
    return "quest"
end

-- ProbeMode is GetCurrentMode without the lastKnownMode side effect. Used
-- by the transition guards to compare "what mode are we becoming?" against
-- "what mode were we?" so we only do save+apply work on real transitions,
-- not on every cascade hook fire (clicking a tracked quest fires the
-- WorldMapFrame:Show, QuestMapFrame:Show, and ShowQuestDetails hooks all
-- in one tick - without this guard we'd save+load three times and the
-- intermediate states can persist if anything races).
local function ProbeMode()
    if not QuestMapFrame or not QuestMapFrame:IsShown() then return "map" end
    if IsDetailQuestActive() then return "detail" end
    return "quest"
end

local function GetModeKey(suffix)
    return GetCurrentMode() .. suffix
end

local function GetModeScale()
    return addon:GetSetting(GetModeKey("Scale")) or 100
end

local function GetModeDraggable()
    return addon:GetSetting(GetModeKey("Draggable")) ~= false
end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------

function addon:SavePosition()
    if not WorldMapFrame then return end
    -- Use lastKnownMode so we save to the right key even during Hide when QuestMapFrame is already gone
    local mode = lastKnownMode
    if not addon:GetSetting(mode .. "Draggable") then return end
    local point, _, relativePoint, x, y = WorldMapFrame:GetPoint()
    if point then
        addon:SetSetting(mode .. "Position", { point = point, relativePoint = relativePoint, x = x, y = y })
    end
end

function addon:LoadPosition()
    if not WorldMapFrame then return end
    WorldMapFrame:ClearAllPoints()
    local pos = addon:GetSetting(GetModeKey("Position"))
    if GetModeDraggable() and pos then
        WorldMapFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    else
        local mode = GetCurrentMode()
        if mode == "quest" then
            WorldMapFrame:SetPoint("LEFT", UIParent, "LEFT", 0, 0)
        else
            -- "map" and "detail" both render the full map - centre is sensible
            WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end
end

---------------------------------------------------------------------------
-- Scaling
---------------------------------------------------------------------------

function addon:ApplyScale()
    if not WorldMapFrame then return end

    -- Capture top-left position before scaling (anchor point for resize)
    local left = WorldMapFrame:GetLeft()
    local top = WorldMapFrame:GetTop()
    local oldScale = WorldMapFrame:GetScale()
    if left and top then
        left = left * oldScale
        top = top * oldScale
    end

    -- Get native windowed size at scale 1
    WorldMapFrame:SetScale(1)
    local nativeW, nativeH = WorldMapFrame:GetSize()
    if nativeW == 0 or nativeH == 0 then return end

    local pct = GetModeScale() / 100

    -- Cap to screen
    local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
    local maxPct = math.min(screenW / nativeW, screenH / nativeH)
    if pct > maxPct then
        pct = maxPct
        addon:SetSetting(GetModeKey("Scale"), math.floor(pct * 100 + 0.5))
    end

    WorldMapFrame:SetScale(pct)

    -- Re-anchor to TOPLEFT so resizing grows downward-right (handle stays with cursor)
    if left and top then
        WorldMapFrame:ClearAllPoints()
        WorldMapFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / pct, top / pct)
    end

    -- Notify the map to refresh pin positions
    if WorldMapFrame.OnFrameSizeChanged then
        WorldMapFrame:OnFrameSizeChanged()
    end
end

---------------------------------------------------------------------------
-- Apply all settings
---------------------------------------------------------------------------

-- Drag state flag (toggled by titleBar OnMouseDown/OnMouseUp). Used by
-- ApplyAll to skip its ClearAllPoints+SetPoint while the user is mid-
-- drag - otherwise any caller that fires ApplyAll mid-drag (Blizzard's
-- SynchronizeDisplayState refresh, a stale BlizzMove handler, an
-- OnSizeChanged) teleports the frame and the user ends up holding a
-- different part of the window. WorldMapFrame doesn't expose
-- IsMovingOrSizing on its class so we can't query the engine flag
-- directly - hence this manual marker.
local isDragging = false

function addon:ApplyAll()
    if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    if isDragging then return end
    self:ApplyScale()
    self:LoadPosition()
    WorldMapFrame:SetMovable(GetModeDraggable())
    WorldMapFrame:SetClampedToScreen(self:GetSetting("clampToScreen") ~= false)
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

local function InitMap()
    if initialized then return end
    if not WorldMapFrame then return end
    initialized = true

    -- Remove Blizzard's panel layout management so WorldMapFrame can
    -- be freely positioned and scaled. SetAttribute from addon code
    -- taints the frame's attribute table, but this is unavoidable -
    -- modifying the UIPanelWindows table instead causes SetPoint errors
    -- in MaximizeUIPanel because the panel-maximize secure handler
    -- reads attributes directly off the frame, not the table. We
    -- accept the taint and mitigate its downstream effects (the POI
    -- tooltip UIWidget error) via the Compat.lua shim.
    C_Timer.After(0.1, function()
        WorldMapFrame:SetAttribute("UIPanelLayout-area", nil)
        WorldMapFrame:SetAttribute("UIPanelLayout-enabled", false)
        WorldMapFrame:SetAttribute("UIPanelLayout-allowOtherPanels", true)
    end)

    -- Hide blackout overlay
    if WorldMapFrame.BlackoutFrame then
        WorldMapFrame.BlackoutFrame:Hide()
        WorldMapFrame.BlackoutFrame:SetAlpha(0)
        WorldMapFrame.BlackoutFrame:SetScript("OnShow", function(self) self:Hide() end)
    end

    -- Hide tiled background that extends beyond the map
    local scrollChild = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if scrollChild and scrollChild.TiledBackground then
        scrollChild.TiledBackground:Hide()
        scrollChild.TiledBackground:SetScript("OnShow", function(self) self:Hide() end)
    end

    -- Make draggable via title bar
    WorldMapFrame:SetMovable(true)
    WorldMapFrame:EnableMouse(true)
    WorldMapFrame:RegisterForDrag("LeftButton")

    local titleBar = WorldMapFrame.BorderFrame and WorldMapFrame.BorderFrame.TitleContainer
    if titleBar then
        titleBar:HookScript("OnMouseDown", function(_, button)
            if button == "LeftButton" and GetModeDraggable() then
                isDragging = true
                WorldMapFrame:StartMoving()
            end
        end)
        titleBar:HookScript("OnMouseUp", function(_, button)
            if button == "LeftButton" and GetModeDraggable() then
                WorldMapFrame:StopMovingOrSizing()
                isDragging = false
                addon:SavePosition()
            end
        end)
    end

    -- Hook SynchronizeDisplayState to re-apply after Blizzard state changes
    hooksecurefunc(WorldMapFrame, "SynchronizeDisplayState", function()
        if WorldMapFrame:IsShown() then
            addon:ApplyAll()
        end
    end)

    -- Hook Show to apply settings immediately
    hooksecurefunc(WorldMapFrame, "Show", function()
        addon:ApplyAll()
    end)

    -- Hook Hide to save position
    hooksecurefunc(WorldMapFrame, "Hide", function()
        addon:SavePosition()
    end)

    -- Mode-change handler: shared by every hook that can flip the mode
    -- (QuestMapFrame Show/Hide for M<->L, and the three quest-detail
    -- globals for L<->detail and entry into detail from the objective
    -- tracker click path).
    --
    -- The mode-change guard is essential. Clicking a tracked quest
    -- fires WorldMapFrame:Show, QuestMapFrame:Show, and
    -- QuestMapFrame_ShowQuestDetails all in the same tick. Without the
    -- guard we'd save+apply three times, and any intermediate state
    -- that races with another caller (BlizzMove, an OnUpdate, the
    -- title-bar drag's mouse handlers) can persist a wrong save into
    -- the wrong mode's slot. Result: "the log opens in a different
    -- place than last time." The guard short-circuits no-op calls so
    -- only one real transition does work per cascade.
    --
    -- Order: SavePosition first (uses lastKnownMode = OLD mode), then
    -- ApplyAll (its GetCurrentMode call updates lastKnownMode to NEW).
    local function HandleModeChange()
        if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
        local newMode = ProbeMode()
        if newMode == lastKnownMode then return end
        addon:SavePosition()
        addon:ApplyAll()
    end

    if QuestMapFrame then
        hooksecurefunc(QuestMapFrame, "Show", HandleModeChange)
        hooksecurefunc(QuestMapFrame, "Hide", HandleModeChange)
    end

    -- Quest detail transitions: clicking a tracked quest in the
    -- objective tracker, hitting Back on the detail panel, ESC, or
    -- super-tracking a different quest all funnel through these three
    -- globals. Hooking them covers every Blizzard entry point that can
    -- enter or leave the map+detail hybrid view (objective tracker
    -- click, side-panel quest list click, Adventure Journal "View in
    -- Quest Log", etc.) without chasing each caller individually.
    if QuestMapFrame_ShowQuestDetails then
        hooksecurefunc("QuestMapFrame_ShowQuestDetails", HandleModeChange)
    end
    if QuestMapFrame_CloseQuestDetails then
        hooksecurefunc("QuestMapFrame_CloseQuestDetails", HandleModeChange)
    end
    if QuestMapFrame_ReturnFromQuestDetails then
        hooksecurefunc("QuestMapFrame_ReturnFromQuestDetails", HandleModeChange)
    end

    -- Resize handle (via BazCore)
    BazCore:MakeResizable(WorldMapFrame, {
        parent = WorldMapFrame.BorderFrame or WorldMapFrame,
        getScale = GetModeScale,
        setScale = function(pct)
            addon:SetSetting(GetModeKey("Scale"), pct)
            addon:ApplyScale()
        end,
    })

    -- Screen resize
    UIParent:HookScript("OnSizeChanged", function()
        if WorldMapFrame:IsShown() then addon:ApplyScale() end
    end)

    -- BlizzMove compatibility (see DisableBlizzMoveWorldMap below).
    -- This is a belt-and-suspenders call alongside the file-scope and
    -- BlizzMove-ADDON_LOADED attempts; the helper short-circuits if it
    -- has already disabled successfully.
    DisableBlizzMoveWorldMap()
end

---------------------------------------------------------------------------
-- Bootstrap
---------------------------------------------------------------------------

local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("ADDON_LOADED")
bootstrap:SetScript("OnEvent", function(self, _, loadedAddon)
    if loadedAddon == "Blizzard_WorldMap" then
        self:UnregisterEvent("ADDON_LOADED")
        C_Timer.After(0, function()
            InitMap()
            if WorldMapFrame and WorldMapFrame:IsShown() then
                addon:ApplyAll()
            end
        end)
    end
end)

if C_AddOns.IsAddOnLoaded("Blizzard_WorldMap") and WorldMapFrame then
    InitMap()
end

---------------------------------------------------------------------------
-- Options (BazCore OptionsPanel)
---------------------------------------------------------------------------

local function GetLandingPage()
    return BazCore:CreateLandingPage("BazMap", {
        subtitle = "Resizable map and quest log",
        description = "A resizable map and quest log window with independent settings for each view. " ..
            "Press M for the map, L for the quest log, or click a tracked quest to bring up the quest detail view - each remembers its own size and position.",
        features = "Independent scale and position for map, quest log, and quest detail views. " ..
            "Drag to resize via BazCore handle. " ..
            "Draggable and clamp-to-screen per mode. " ..
            "Replaces Blizzard's fullscreen map with a clean windowed experience.",
        guide = {
            { "Map", "Press M to open the map in a resizable window" },
            { "Quest Log", "Press L to open the quest log - separate position and size" },
            { "Quest Detail", "Click a tracked quest to read its full details - own size and position" },
            { "Resize", "Drag the handle at the bottom-right corner" },
        },
    })
end

local function GetSettingsPage()
    return {
        name = "Settings",
        type = "group",
        args = {
            intro = {
                order = 0.1,
                type = "lead",
                text = "Map mode, quest log mode, and quest detail view each save their own size and position. Adjust the three layouts independently below.",
            },
            mapHeader = {
                order = 1,
                type = "header",
                name = "Map Mode",
            },
            mapScale = {
                order = 2,
                type = "range",
                name = "Map Size",
                min = 30, max = 150, step = 5,
                get = function() return addon:GetSetting("mapScale") or 100 end,
                set = function(_, val)
                    addon:SetSetting("mapScale", val)
                    if WorldMapFrame and WorldMapFrame:IsShown() and GetCurrentMode() == "map" then
                        addon:ApplyScale()
                    end
                end,
            },
            mapDraggable = {
                order = 3,
                type = "toggle",
                name = "Enable Dragging (Map)",
                get = function() return addon:GetSetting("mapDraggable") ~= false end,
                set = function(_, val)
                    addon:SetSetting("mapDraggable", val)
                    if WorldMapFrame and GetCurrentMode() == "map" then
                        WorldMapFrame:SetMovable(val)
                        if not val then addon:LoadPosition() end
                    end
                end,
            },
            resetMap = {
                order = 4,
                type = "execute",
                name = "Reset Map Position",
                func = function()
                    addon:SetSetting("mapPosition", nil)
                    if WorldMapFrame and WorldMapFrame:IsShown() and GetCurrentMode() == "map" then
                        addon:LoadPosition()
                    end
                    addon:Print("Map position reset.")
                end,
            },
            clampToScreen = {
                order = 5,
                type = "toggle",
                name = "Clamp to Screen",
                get = function() return addon:GetSetting("clampToScreen") ~= false end,
                set = function(_, val)
                    addon:SetSetting("clampToScreen", val)
                    if WorldMapFrame then WorldMapFrame:SetClampedToScreen(val) end
                end,
            },

            questHeader = {
                order = 10,
                type = "header",
                name = "Quest Log Mode",
            },
            questScale = {
                order = 11,
                type = "range",
                name = "Quest Log Size",
                min = 30, max = 150, step = 5,
                get = function() return addon:GetSetting("questScale") or 100 end,
                set = function(_, val)
                    addon:SetSetting("questScale", val)
                    if WorldMapFrame and WorldMapFrame:IsShown() and GetCurrentMode() == "quest" then
                        addon:ApplyScale()
                    end
                end,
            },
            questDraggable = {
                order = 12,
                type = "toggle",
                name = "Enable Dragging (Quest Log)",
                get = function() return addon:GetSetting("questDraggable") ~= false end,
                set = function(_, val)
                    addon:SetSetting("questDraggable", val)
                    if WorldMapFrame and GetCurrentMode() == "quest" then
                        WorldMapFrame:SetMovable(val)
                        if not val then addon:LoadPosition() end
                    end
                end,
            },
            resetQuest = {
                order = 13,
                type = "execute",
                name = "Reset Quest Log Position",
                func = function()
                    addon:SetSetting("questPosition", nil)
                    if WorldMapFrame and WorldMapFrame:IsShown() and GetCurrentMode() == "quest" then
                        addon:LoadPosition()
                    end
                    addon:Print("Quest log position reset.")
                end,
            },

            detailHeader = {
                order = 20,
                type = "header",
                name = "Quest Detail View",
            },
            detailIntro = {
                order = 20.5,
                type = "description",
                name = "Clicking a quest in the objective tracker opens the map with the quest's details panel attached. This view sits between map and quest log mode and remembers its own size and position.",
                fontSize = "small",
            },
            detailScale = {
                order = 21,
                type = "range",
                name = "Quest Detail Size",
                min = 30, max = 150, step = 5,
                get = function() return addon:GetSetting("detailScale") or 100 end,
                set = function(_, val)
                    addon:SetSetting("detailScale", val)
                    if WorldMapFrame and WorldMapFrame:IsShown() and GetCurrentMode() == "detail" then
                        addon:ApplyScale()
                    end
                end,
            },
            detailDraggable = {
                order = 22,
                type = "toggle",
                name = "Enable Dragging (Quest Detail)",
                get = function() return addon:GetSetting("detailDraggable") ~= false end,
                set = function(_, val)
                    addon:SetSetting("detailDraggable", val)
                    if WorldMapFrame and GetCurrentMode() == "detail" then
                        WorldMapFrame:SetMovable(val)
                        if not val then addon:LoadPosition() end
                    end
                end,
            },
            resetDetail = {
                order = 23,
                type = "execute",
                name = "Reset Quest Detail Position",
                func = function()
                    addon:SetSetting("detailPosition", nil)
                    if WorldMapFrame and WorldMapFrame:IsShown() and GetCurrentMode() == "detail" then
                        addon:LoadPosition()
                    end
                    addon:Print("Quest detail position reset.")
                end,
            },
        },
    }
end

addon.config.onLoad = function(self)
    BazCore:RegisterOptionsTable(ADDON_NAME, GetLandingPage)
    BazCore:AddToSettings(ADDON_NAME, "BazMap")

    BazCore:RegisterOptionsTable(ADDON_NAME .. "-Settings", GetSettingsPage)
    BazCore:AddToSettings(ADDON_NAME .. "-Settings", "General Settings", ADDON_NAME)
end
