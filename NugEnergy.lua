local _, ns = ...

-- API locals
local UnitClass = UnitClass
local UnitPowerMax = UnitPowerMax

-- States
local ST_ACTIVE = 1
local ST_IDLE = 2

-- Locals
local _state = {
    isEnabled = false,
    playerClass = nil,
    filterUnit = "player",
    isRogueOrDruid = nil,
    powerType = nil,
    maxPower = nil,
    currentPower = nil,
    currentPowerPercent = nil,
    isPowerFull = false,
    showState = ST_IDLE,
    targetHealthPercent = nil,
    wasJustEnabled = false,
    forceShow = false,
    isInCombat = false,
    isStealthed = false,
    isInVehicle = false
}

local stateListeners = {}
local state = ns.utils.observable(_state, stateListeners)

-- Create addon
NugEnergy = LibStub("AceAddon-3.0"):NewAddon("NugEnergy", "AceEvent-3.0")

-- Fields
NugEnergy.state = ns.utils.readonly(_state)
NugEnergy.behaviors = {}

function NugEnergy:OnState(key, listener)
    if (not stateListeners[key]) then
        stateListeners[key] = {}
    end
    tinsert(stateListeners[key], listener)
end

function NugEnergy:OffState(key, listener)
    local removeAt = nil
    for i, v in ipairs(stateListeners[key] or {}) do
        if (v == listener) then
            removeAt = i
            break
        end
    end
    if (removeAt) then
        tremove(stateListeners[key], removeAt)
    end
end

-- START EVENTS

function NugEnergy:PLAYER_LOGIN()
    if (not state.isEnabled) then
        return
    end

    state.wasJustEnabled = true

    C_Timer.After(
        10,
        function()
            state.wasJustEnabled = false
            self:UpdateVisibility()
        end
    )

    self:UpdateVisibility()
end

function NugEnergy:PLAYER_REGEN_ENABLED()
    state.isInCombat = false
    self:UpdateVisibility()
end

function NugEnergy:PLAYER_REGEN_DISABLED()
    state.isInCombat = true
    self:UpdateVisibility()
end

function NugEnergy:PLAYER_TARGET_CHANGED()
    if (UnitExists("target")) then
        self:UNIT_HEALTH("target")
    end
end

function NugEnergy:UNIT_HEALTH()
    if (not UnitExists("target")) then
        return
    end

    local unitHealth = UnitHealth("target")
    local maxHealth = UnitHealthMax("target")
    maxHealth = maxHealth == 0 and 1 or maxHealth
    state.targetHealthPercent = unitHealth / maxHealth
end

function NugEnergy:UNIT_DISPLAYPOWER(unit)
    state.powerType = UnitPowerType(unit)
    self:UNIT_MAXPOWER(unit)
end

function NugEnergy:UNIT_MAXPOWER(unit)
    state.maxPower = UnitPowerMax(unit, state.powerType)
    self.statusBar:SetMinMaxValues(0, state.maxPower)
    -- call this so we don't have to duplicate the code updating power state
    self:UNIT_POWER_FREQUENT(unit)
end

function NugEnergy:UNIT_POWER_FREQUENT(unit)
    state.currentPower = UnitPower(unit, state.powerType)
    state.currentPowerPercent = state.currentPower / state.maxPower

    self.statusBar:SetValue(state.currentPower)

    -- bar should show when player is missing any power
    local wasFull = state.isPowerFull
    state.isPowerFull = state.currentPower == state.maxPower
    if (state.isPowerFull ~= wasFull) then
        self:UpdateVisibility()
    end
end

function NugEnergy:UNIT_POWER_UPDATE(unit)
    self:UNIT_POWER_FREQUENT(unit)
end

function NugEnergy:UPDATE_STEALTH()
    state.isStealthed = IsStealthed()
    self:UpdateVisibility()
end

function NugEnergy:UNIT_ENTERED_VEHICLE()
    state.isInVehicle = true
    -- Set isPowerFull to false so that we update visibility in UNIT_POWER_FREQUENT
    state.isPowerFull = false
    state.filterUnit = "vehicle"
    self:UNIT_DISPLAYPOWER("vehicle")
end

function NugEnergy:UNIT_EXITED_VEHICLE()
    state.isInVehicle = false
    -- Set isPowerFull to false so that we update visibility in UNIT_POWER_FREQUENT
    state.isPowerFull = false
    state.filterUnit = "player"
    self:UNIT_DISPLAYPOWER("player")
end

-- END EVENTS

function NugEnergy:CreateFilterUnitEventHandler(filterUnit)
    local cb = type(filterUnit) == "function" and filterUnit or function (unit)
         return unit == filterUnit
        end
    return function(event, ...)
        local unit = ...
        if (unit and cb(unit)) then
            self[event](self, ...)
        end
    end
end

function NugEnergy:RegisterUnitEvent(event, ...)
    self:RegisterEvent(event, self:CreateFilterUnitEventHandler(...))
end

function NugEnergy:RegisterFilterUnitEvent(event)
    self:RegisterUnitEvent(event, function (unit) return unit == state.filterUnit end)
end

function NugEnergy:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("NugEnergyDB", NUGENERGY_DEFAULTS, true)
    state.playerClass = select(2, UnitClass("player"))
    state.isRogueOrDruid = state.playerClass == "ROGUE" or state.playerClass == "DRUID"
    state.isInCombat = InCombatLockdown()
    self:SetupOptions()
end

function NugEnergy:OnEnable()
    if state.isEnabled then
        return
    end

    -- Create all the UI components
    self:CreateComponents()

    -- Register all required events
    self:RegisterEvent("PLAYER_LOGIN")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterUnitEvent("UNIT_HEALTH", "target")
    self:RegisterFilterUnitEvent("UNIT_DISPLAYPOWER")
    self:RegisterFilterUnitEvent("UNIT_MAXPOWER")
    self:RegisterFilterUnitEvent("UNIT_POWER_UPDATE")
    self:RegisterFilterUnitEvent("UNIT_POWER_FREQUENT")
    self:RegisterUnitEvent("UNIT_ENTERED_VEHICLE", "player")
    self:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player")

    if (state.isRogueOrDruid) then
        self:RegisterEvent("UPDATE_STEALTH")
    end

    state.isInVehicle = UnitInVehicle("player")
    state.filterUnit = state.isInVehicle and "vehicle" or "player"

    self:UNIT_DISPLAYPOWER(state.filterUnit)
    self:UPDATE_STEALTH()

    state.isEnabled = true

    self:PLAYER_LOGIN()
end

function NugEnergy:OnDisable()
    if (not state.isEnabled) then
        return
    end
    self:UnregisterAllEvents()
    self.statusBar:Hide()
    state.isEnabled = false
end

function NugEnergy:ShouldShow()
    return (state.wasJustEnabled or
        state.forceShow or
        state.isInCombat or
        state.isStealthed or
        (not state.isPowerFull) or
        state.isInVehicle)
end

function NugEnergy:GetShowState()
    return self:ShouldShow() and ST_ACTIVE or ST_IDLE
end

function NugEnergy:UpdateVisibility()
    -- this should never be possible
    if (not state.isEnabled) then
        return
    end

    local previousState = state.showState
    state.showState = self:GetShowState()

    if (previousState == state.showState) then
        return
    end

    if (state.showState == ST_ACTIVE) then
        self.statusBar:Update()
        self.text:Update()
    elseif (state.showState == ST_IDLE) then
        if (self.fader.isEnabled) then
            self.fader:StartFade()
        end
    end
end

function NugEnergy:IsActive()
    return state.showState == ST_ACTIVE
end

function NugEnergy:Lock()
    self.statusBar:EnableMouse(false)
    state.forceShow = false
    self:UpdateVisibility()
end

function NugEnergy:Unlock()
    self.statusBar:EnableMouse(true)
    state.forceShow = true
    self:UpdateVisibility()
end
