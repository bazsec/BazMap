-- BazMap - A World of Warcraft Addon
-- Copyright (C) 2025 Baz4k
-- Licensed under GPL v2

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
-- BazCore Registration
---------------------------------------------------------------------------

local addon
addon = BazCore:RegisterAddon(ADDON_NAME, {
    title = "BazMap",
    savedVariable = "BazMapDB",
    profiles = true,
    defaults = {
        mapScale       = 100,
        mapDraggable   = true,
        questScale     = 100,
        questDraggable = true,
        clampToScreen  = true,
    },

    slash = { "/bazmap", "/bmap" },
    commands = {
        reset = {
            desc = "Reset all positions to defaults",
            handler = function()
                addon:SetSetting("mapPosition", nil)
                addon:SetSetting("questPosition", nil)
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
-- State
---------------------------------------------------------------------------

local initialized = false

---------------------------------------------------------------------------
-- Mode detection
---------------------------------------------------------------------------

local lastKnownMode = "map"

local function GetCurrentMode()
    if QuestMapFrame and QuestMapFrame:IsShown() then
        lastKnownMode = "quest"
        return "quest"
    end
    lastKnownMode = "map"
    return "map"
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
    elseif GetCurrentMode() == "quest" then
        WorldMapFrame:SetPoint("LEFT", UIParent, "LEFT", 0, 0)
    else
        WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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

function addon:ApplyAll()
    if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
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
                WorldMapFrame:StartMoving()
            end
        end)
        titleBar:HookScript("OnMouseUp", function(_, button)
            if button == "LeftButton" and GetModeDraggable() then
                WorldMapFrame:StopMovingOrSizing()
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

    -- Mode changes while open
    if QuestMapFrame then
        hooksecurefunc(QuestMapFrame, "Show", function()
            if WorldMapFrame:IsShown() then
                lastKnownMode = "quest"
                addon:ApplyAll()
            end
        end)
        hooksecurefunc(QuestMapFrame, "Hide", function()
            if WorldMapFrame:IsShown() then
                -- Save quest position before switching to map mode
                addon:SavePosition()
                lastKnownMode = "map"
                addon:ApplyAll()
            end
        end)
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

    -- BlizzMove compatibility
    if C_AddOns.IsAddOnLoaded("BlizzMove") then
        C_Timer.After(0.5, function()
            if BlizzMove and BlizzMove.DisableFrame then
                pcall(function() BlizzMove:DisableFrame("Blizzard_WorldMap", "WorldMapFrame") end)
                pcall(function() BlizzMove:DisableFrame("BlizzMove", "WorldMapFrame") end)
            end
        end)
    end
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
        description = "A resizable map and quest log window with independent settings per mode. " ..
            "Press M for the map, L for the quest log - each remembers its own size and position.",
        features = "Independent scale and position for map and quest log modes. " ..
            "Drag to resize via BazCore handle. " ..
            "Draggable and clamp-to-screen per mode. " ..
            "Replaces Blizzard's fullscreen map with a clean windowed experience.",
        guide = {
            { "Map", "Press M to open the map in a resizable window" },
            { "Quest Log", "Press L to open the quest log - separate position and size" },
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
                text = "Map mode and quest log mode each save their own size and position. Adjust the two layouts independently below.",
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
        },
    }
end

addon.config.onLoad = function(self)
    BazCore:RegisterOptionsTable(ADDON_NAME, GetLandingPage)
    BazCore:AddToSettings(ADDON_NAME, "BazMap")

    BazCore:RegisterOptionsTable(ADDON_NAME .. "-Settings", GetSettingsPage)
    BazCore:AddToSettings(ADDON_NAME .. "-Settings", "General Settings", ADDON_NAME)
end
