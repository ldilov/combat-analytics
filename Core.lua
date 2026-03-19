local ADDON_NAME, ns = ...

local Constants = ns.Constants

local Addon = {
    name = ADDON_NAME,
    version = "0.1.0",
    modules = {},
    coreInitialized = false,
    runtimeInitialized = false,
    initialized = false,
    runtime = {
        currentSession = nil,
        currentMatch = nil,
        pendingDuel = nil,
        reviewedSessionId = nil,
        latestSummarySessionId = nil,
        summaryOpenAt = nil,
        latestPlayerSnapshot = nil,
        totalRawEvents = 0,
        warnings = {},
        traceLog = {},
    },
}

ns.Addon = Addon

local PREFIX = "|cff35c7e5[CombatAnalytics]|r"
local WARNING_LOG_LIMIT = 100

local function chat(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    end
end

local function appendBounded(list, value, limit)
    list[#list + 1] = value
    while #list > limit do
        table.remove(list, 1)
    end
end

local function safeModuleCall(addon, moduleName, methodName)
    local module = addon:GetModule(moduleName)
    if not module or type(module[methodName]) ~= "function" then
        return true
    end

    local ok, err = xpcall(function()
        module[methodName](module)
    end, debugstack)
    if not ok then
        addon:Warn(string.format("%s initialization failed.", moduleName))
        addon:Debug("%s", err)
        return false
    end
    return true
end

local function registerSlashCommands(addon)
    if addon.slashRegistered then
        return true
    end

    if type(SlashCmdList) ~= "table" then
        addon:Warn("Slash command registration deferred because SlashCmdList is unavailable.")
        return false
    end

    SlashCmdList.COMBATANALYTICS = function(msg)
        addon:HandleCommand(msg)
    end
    _G.SLASH_COMBATANALYTICS1 = "/ca"
    _G.SLASH_COMBATANALYTICS2 = "/caa"
    _G.SLASH_COMBATANALYTICS3 = "/combatanalytics"
    addon.slashRegistered = true
    return true
end

local function stringifyTraceValue(value)
    if value == nil then
        return "nil"
    end
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    if type(value) == "number" then
        return string.format("%.3f", value)
    end
    return tostring(value)
end

local function formatTraceFields(fields)
    if fields == nil then
        return ""
    end
    if type(fields) ~= "table" then
        return tostring(fields)
    end

    local parts = {}
    for _, key in ipairs(ns.Helpers.ArrayKeys(fields)) do
        local value = fields[key]
        if type(value) ~= "table" then
            parts[#parts + 1] = string.format("%s=%s", tostring(key), stringifyTraceValue(value))
        end
    end
    return table.concat(parts, " ")
end

function Addon:RegisterModule(name, module)
    self.modules[name] = module
    module.name = name
    module.addon = self
    return module
end

function Addon:GetModule(name)
    return self.modules[name]
end

function Addon:GetDB()
    return CombatAnalyticsDB
end

function Addon:GetSetting(key)
    local db = self:GetDB()
    local settings = db and db.settings or nil
    if settings and settings[key] ~= nil then
        return settings[key]
    end
    return Constants.DEFAULT_SETTINGS[key]
end

function Addon:SetSetting(key, value)
    local db = self:GetDB()
    if not db then
        return
    end
    db.settings[key] = value
end

function Addon:IsDebugEnabled()
    return self:GetSetting("enableDebugLogging")
end

function Addon:IsTraceEnabled()
    return self:GetSetting("enableTraceLogging")
end

function Addon:Print(message)
    chat(string.format("%s %s", PREFIX, message))
end

function Addon:PrintSuccess(message)
    chat(string.format("%s |cff73d98b%s|r", PREFIX, message))
end

function Addon:PrintWarning(message)
    chat(string.format("%s |cffffb347%s|r", PREFIX, message))
end

function Addon:AppendTraceEntry(label, fields)
    local log = self:GetTraceLog()
    log[#log + 1] = {
        timestamp = ns.ApiCompat.GetServerTime(),
        relative = ns.Helpers.Now(),
        label = tostring(label or "trace"),
        detail = formatTraceFields(fields),
    }

    local limit = Constants.TRACE_LOG_LIMIT or 200
    while #log > limit do
        table.remove(log, 1)
    end
end

function Addon:RecordWarning(message)
    local entry = {
        timestamp = ns.ApiCompat.GetServerTime(),
        message = tostring(message or "unknown"),
    }

    appendBounded(self.runtime.warnings, entry, WARNING_LOG_LIMIT)

    local db = self:GetDB()
    local maintenance = db and db.maintenance or nil
    if maintenance then
        maintenance.warnings = maintenance.warnings or {}
        appendBounded(maintenance.warnings, entry, WARNING_LOG_LIMIT)
    end
end

function Addon:Debug(message, ...)
    if not self:IsDebugEnabled() then
        return
    end

    local formatted = message
    if select("#", ...) > 0 then
        formatted = string.format(message, ...)
    end
    self:AppendTraceEntry("debug", { message = formatted })
end

function Addon:Warn(message)
    self:RecordWarning(message)
    self:AppendTraceEntry("warn", { message = message })
end

function Addon:GetTraceLog()
    local db = self:GetDB()
    local maintenance = db and db.maintenance or nil
    if maintenance then
        maintenance.traceLog = maintenance.traceLog or {}
        return maintenance.traceLog
    end

    self.runtime.traceLog = self.runtime.traceLog or {}
    return self.runtime.traceLog
end

function Addon:Trace(label, fields)
    if not self:IsTraceEnabled() then
        return
    end
    self:AppendTraceEntry(label, fields)
end

function Addon:ClearTraceLog()
    local log = self:GetTraceLog()
    for index = #log, 1, -1 do
        log[index] = nil
    end
end

function Addon:DumpTraceLog(limit)
    local log = self:GetTraceLog()
    if #log == 0 then
        self:Print("Trace log is empty.")
        return
    end

    limit = math.floor(tonumber(limit) or 20)
    if limit < 1 then
        limit = 1
    elseif limit > (Constants.TRACE_LOG_LIMIT or 200) then
        limit = Constants.TRACE_LOG_LIMIT or 200
    end

    local startIndex = math.max(1, #log - limit + 1)
    self:Print(string.format("Trace dump (%d of %d entries):", #log - startIndex + 1, #log))
    for index = startIndex, #log do
        local entry = log[index]
        local timeText = date("%H:%M:%S", entry.timestamp or time())
        local detail = entry.detail ~= "" and (" " .. entry.detail) or ""
        self:Print(string.format("%s rel=%.3f %s%s", timeText, entry.relative or 0, entry.label or "trace", detail))
    end
end

function Addon:SetLatestPlayerSnapshot(snapshot)
    self.runtime.latestPlayerSnapshot = snapshot
end

function Addon:GetLatestPlayerSnapshot()
    return self.runtime.latestPlayerSnapshot
end

function Addon:SetReviewedSession(sessionId, source)
    self.runtime.reviewedSessionId = sessionId
    self:Trace("ui.reviewed_session.set", {
        sessionId = sessionId or "nil",
        source = source or "unknown",
    })
end

function Addon:GetReviewedSession()
    return self.runtime.reviewedSessionId
end

function Addon:ClearReviewedSession()
    self.runtime.reviewedSessionId = nil
    self:Trace("ui.reviewed_session.cleared")
end

function Addon:TryRegisterSlashCommands()
    return registerSlashCommands(self)
end

function Addon:PrintCommandHelp()
    self:Print("|cff73d98bReady|r  |cff35c7e5/ca|r opens the dashboard, |cff35c7e5/ca history|r shows sessions, |cff35c7e5/ca insights|r shows coaching.")
    self:Print("|cffd7e9ffUtilities|r  |cff35c7e5/ca detail|r, |cff35c7e5/ca cleanup|r, |cff35c7e5/ca settings|r, |cff35c7e5/ca trace|r.")
end

function Addon:OpenView(viewId, payload)
    if not self.runtimeInitialized then
        self:InitializeRuntime()
    end

    if InCombatLockdown and InCombatLockdown() then
        self:PrintWarning("CombatAnalytics UI cannot open during combat. Use /ca after combat ends.")
        return
    end

    local mainFrame = self:GetModule("MainFrame")
    if mainFrame then
        local ok, err = xpcall(function()
            mainFrame:ShowView(viewId, payload)
        end, debugstack)
        if not ok then
            self:Warn("CombatAnalytics UI failed to open.")
            self:PrintWarning("CombatAnalytics UI failed to open.")
            self:Debug("%s", err)
        end
    end
end

function Addon:ShowSummary(sessionId)
    self.runtime.latestSummarySessionId = sessionId
    self.runtime.summaryOpenAt = ns.Helpers.Now() + Constants.SUMMARY_AUTO_OPEN_DELAY
end

function Addon:HandleCommand(input)
    local tracker = self:GetModule("CombatTracker")
    if tracker and tracker.FlushSessionForInspection then
        tracker:FlushSessionForInspection()
    end

    local rawInput = ns.Helpers.Trim(input or "")
    if rawInput == "" then
        self:OpenView("summary")
        return
    end

    local command, argument = string.match(rawInput, "^(%S+)%s*(.-)$")
    command = string.lower(command or "")
    argument = string.lower(ns.Helpers.Trim(argument or ""))

    if command == "summary" then
        self:OpenView("summary")
        return
    end

    if command == "history" then
        self:OpenView("history")
        return
    end

    if command == "options" or command == "settings" then
        local settingsPanel = self:GetModule("SettingsPanel")
        if settingsPanel and settingsPanel.Open then
            settingsPanel:Open()
        else
            self:PrintWarning("CombatAnalytics settings panel is not available.")
        end
        return
    end

    if command == "insights" then
        self:OpenView("insights")
        return
    end

    if command == "cleanup" then
        self:OpenView("cleanup")
        return
    end

    if command == "trace" or command == "traces" then
        if argument == "on" then
            self:SetSetting("enableTraceLogging", true)
            self:PrintSuccess("Trace logging enabled.")
            return
        end
        if argument == "off" then
            self:SetSetting("enableTraceLogging", false)
            self:PrintSuccess("Trace logging disabled.")
            return
        end
        if argument == "clear" then
            self:ClearTraceLog()
            self:PrintSuccess("Trace log cleared.")
            return
        end

        self:DumpTraceLog(argument ~= "" and argument or nil)
        return
    end

    if command == "debug" then
        local enabled = not self:IsDebugEnabled()
        self:SetSetting("enableDebugLogging", enabled)
        self:PrintSuccess(string.format("Debug %s.", enabled and "enabled" or "disabled"))
        return
    end

    if command == "stats" then
        local store = self:GetModule("CombatStore")
        local dbStats = store and store:GetStorageStats() or {}
        local active = tracker and tracker:GetCurrentSession() or nil
        self:Print(string.format(
            "Stats: stored_sessions=%d stored_matches=%d raw_events=%d active_session=%s active_context=%s",
            dbStats.sessions or 0,
            dbStats.matches or 0,
            dbStats.totalRawEvents or 0,
            active and active.id or "none",
            active and active.context or "none"
        ))
        return
    end

    if command == "minimap" then
        self:SetSetting("showMinimapButton", false)
        local minimapButton = self:GetModule("MinimapButton")
        if minimapButton and minimapButton.button then
            minimapButton.button:Hide()
        end
        self:Print("Minimap button is disabled during taint stabilization. Use |cff35c7e5/ca|r to open the UI.")
        return
    end

    self:PrintCommandHelp()
end

function Addon:Initialize()
    self:InitializeCore()
    self:InitializeRuntime()
end

function Addon:InitializeCore()
    if self.coreInitialized then
        return
    end

    safeModuleCall(self, "CombatStore", "Initialize")
    self.coreInitialized = true
end

function Addon:InitializeRuntime()
    if self.runtimeInitialized then
        return
    end

    self:InitializeCore()

    self:TryRegisterSlashCommands()
    safeModuleCall(self, "ArenaRoundTracker", "Initialize")
    safeModuleCall(self, "SpellAttributionPipeline", "Initialize")
    safeModuleCall(self, "CombatTracker", "Initialize")
    safeModuleCall(self, "SnapshotService", "Initialize")
    safeModuleCall(self, "DamageMeterService", "Initialize")

    self.runtimeInitialized = true
    self.initialized = true

    if not self.runtime.loginBannerShown then
        self.runtime.loginBannerShown = true
        self:PrintCommandHelp()
    end
end

Addon:RegisterModule("Core", Addon)
