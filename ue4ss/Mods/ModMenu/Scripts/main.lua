-- Loader for ModMenu.
--
-- The implementation lives in main_impl.lua, and every file it needs -- the
-- bridge included -- is resolved from this mod's own folder. UE4SS's entry
-- point therefore stays one unconditional dofile with no path routing.

local sourceInfo = debug.getinfo(1, "S")
if type(sourceInfo) ~= "table" or type(sourceInfo.source) ~= "string" then
    error("ModMenu loader could not resolve its script source")
end

local sourcePath = sourceInfo.source
if sourcePath:sub(1, 1) == "@" then sourcePath = sourcePath:sub(2) end
local SCRIPT_DIR = sourcePath:match("^(.*[\\/])")
if type(SCRIPT_DIR) ~= "string" or SCRIPT_DIR == "" then
    error("ModMenu loader could not resolve the Scripts directory")
end

-- main_impl owns the rail state, but EndSubMenu/ClosedMenu schedule delayed
-- reacquisition passes. The delayed callback can outlive the exact Start Menu
-- that raised the event, so guard those passes here while the hooks are being
-- registered: capture only the menu's primitive identity in the hook callback,
-- then require that same UObject to still be the component's mounted, visible
-- widget before the delayed action may touch the stored rail.
local originalRegisterHook = RegisterHook
local originalExecuteWithDelay = ExecuteWithDelay
local originalNotifyOnNewObject = NotifyOnNewObject
local originalDofile = dofile

local panelModule = nil
local panelHostKey = nil

local function isValid(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

local function objectName(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    if ok and name then return tostring(name) end
    return tostring(object)
end

local function dereferenceWeakObject(pointer)
    if isValid(pointer) then return pointer end
    if pointer == nil then return nil end
    local ok, object = pcall(function() return pointer:Get() end)
    if ok and isValid(object) then return object end
    return nil
end

local function canonicalMountedMenuKey(requireVisible, expectedKey)
    local ok, widgets = pcall(function()
        return FindAllOf("WBP_Console_MainMenu_C")
    end)
    if not ok or type(widgets) ~= "table" then return nil end

    for _, candidate in ipairs(widgets) do
        if isValid(candidate) then
            local candidateKey = objectName(candidate)
            if expectedKey == nil or candidateKey == expectedKey then
                local component = nil
                pcall(function()
                    component = dereferenceWeakObject(candidate.ParentComponent)
                end)
                local mounted = nil
                if isValid(component) then
                    pcall(function() mounted = component:GetWidget() end)
                end
                if isValid(mounted) and objectName(mounted) == candidateKey then
                    if not requireVisible then return candidateKey end
                    local visible = false
                    pcall(function() visible = candidate:IsVisible() == true end)
                    if visible then return candidateKey end
                end
            end
        end
    end
    return nil
end

local function unwrap(parameter)
    if parameter == nil then return nil end
    local ok, value = pcall(function() return parameter:get() end)
    if ok then return value end
    return parameter
end

-- Capture the panel table as main_impl loads it so the loader can release the
-- cache at the same moment a newly constructed Start Menu supersedes its host.
-- The wrapper keeps only the host's primitive name; it never retains a UObject.
dofile = function(path)
    local result = originalDofile(path)
    if type(path) == "string"
        and path:match("[\\/]panel%.lua$")
        and type(result) == "table" then
        panelModule = result

        local originalAttachTo = result.attachTo
        if type(originalAttachTo) == "function" then
            result.attachTo = function(liveMenu, icon)
                panelHostKey = isValid(liveMenu) and objectName(liveMenu) or nil
                return originalAttachTo(liveMenu, icon)
            end
        end

        local originalRelease = result.release
        if type(originalRelease) == "function" then
            result.release = function(...)
                panelHostKey = nil
                return originalRelease(...)
            end
        end
    end
    return result
end

-- main_impl already watches this class. Wrap only that registration so a new
-- canonical Start Menu releases widgets cached for the previous menu before the
-- implementation replaces activeContext. This closes the retention window that
-- otherwise lasted until the panel happened to open again.
NotifyOnNewObject = function(path, callback)
    if path ~= "/Script/ROD.RODConsoleMainMenuWidgetBase"
        or type(callback) ~= "function" then
        return originalNotifyOnNewObject(path, callback)
    end

    return originalNotifyOnNewObject(path, function(object)
        local candidate = unwrap(object)
        if isValid(candidate) then
            local candidateKey = objectName(candidate)
            if candidateKey:find("WBP_Console_MainMenu_C", 1, true)
                and panelHostKey ~= nil
                and panelHostKey ~= candidateKey
                and type(panelModule) == "table"
                and type(panelModule.release) == "function" then
                local released, releaseError = pcall(panelModule.release)
                if not released then
                    print("[ModMenu] stale panel cache release failed: " ..
                        tostring(releaseError) .. "\n")
                end
            end
        end
        return callback(object)
    end)
end

local reacquireHookPaths = {
    ["/Script/ROD.RODConsoleMainMenuWidgetBase:EndSubMenu"] = true,
    ["/Script/ROD.RODMenuWidgetBase:ClosedMenu"] = true,
}

local function guardReacquireCallback(callback)
    if type(callback) ~= "function" then return callback end

    return function(...)
        -- This hook callback is still on the game thread. Capture only the
        -- mounted Start Menu's primitive identity; no hook parameter or UObject
        -- crosses into ExecuteWithDelay.
        local expectedMenuKey = canonicalMountedMenuKey(false, nil)
        local callbackArgs = table.pack(...)
        local previousExecuteWithDelay = ExecuteWithDelay

        ExecuteWithDelay = function(delayMs, action)
            if type(action) ~= "function" then
                return originalExecuteWithDelay(delayMs, action)
            end
            return originalExecuteWithDelay(delayMs, function()
                -- ExecuteWithDelay is asynchronous. UObject discovery and the
                -- original rail action both happen only after dispatching back
                -- to the game thread.
                local scheduled, scheduleError = pcall(function()
                    ExecuteInGameThread(function()
                        if expectedMenuKey ~= nil
                            and canonicalMountedMenuKey(
                                true, expectedMenuKey) == expectedMenuKey then
                            action()
                        end
                    end)
                end)
                if not scheduled then
                    print("[ModMenu] rail reacquire guard dispatch failed: " ..
                        tostring(scheduleError) .. "\n")
                end
            end)
        end

        local results = nil
        local ok, callbackError = xpcall(function()
            results = table.pack(callback(
                table.unpack(callbackArgs, 1, callbackArgs.n)))
        end, debug.traceback)
        ExecuteWithDelay = previousExecuteWithDelay

        if not ok then error(callbackError) end
        return table.unpack(results, 1, results.n)
    end
end

RegisterHook = function(path, preCallback, postCallback)
    if reacquireHookPaths[path] then
        preCallback = guardReacquireCallback(preCallback)
        postCallback = guardReacquireCallback(postCallback)
    end
    if postCallback ~= nil then
        return originalRegisterHook(path, preCallback, postCallback)
    end
    return originalRegisterHook(path, preCallback)
end

local ok, result = xpcall(function()
    return originalDofile(SCRIPT_DIR .. "main_impl.lua")
end, debug.traceback)

-- Do not leak loader instrumentation to another mod or to a later RestartMod.
RegisterHook = originalRegisterHook
ExecuteWithDelay = originalExecuteWithDelay
NotifyOnNewObject = originalNotifyOnNewObject
dofile = originalDofile

if not ok then error(result) end
return result
