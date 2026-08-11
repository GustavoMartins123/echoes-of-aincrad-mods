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

-- EndSubMenu and ClosedMenu both feed the implementation's delayed rail
-- reacquisition path. The latter belongs to a broad menu base class, and either
-- callback can outlive the Start Menu that scheduled it. Wrap only those hook
-- callbacks while main_impl registers them so every delayed reacquire pass
-- re-checks that a canonical Start Menu is still mounted and visible before it
-- can touch the old rail. Other ExecuteWithDelay users remain unchanged.
local originalRegisterHook = RegisterHook
local originalExecuteWithDelay = ExecuteWithDelay

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

local function hasMountedVisibleStartMenu()
    local ok, widgets = pcall(function()
        return FindAllOf("WBP_Console_MainMenu_C")
    end)
    if not ok or type(widgets) ~= "table" then return false end

    for _, candidate in ipairs(widgets) do
        if isValid(candidate) then
            local visible = false
            pcall(function() visible = candidate:IsVisible() == true end)
            if visible then
                local component = nil
                pcall(function()
                    component = dereferenceWeakObject(candidate.ParentComponent)
                end)
                local mounted = nil
                if isValid(component) then
                    pcall(function() mounted = component:GetWidget() end)
                end
                if isValid(mounted)
                    and objectName(mounted) == objectName(candidate) then
                    return true
                end
            end
        end
    end
    return false
end

local reacquireHookPaths = {
    ["/Script/ROD.RODConsoleMainMenuWidgetBase:EndSubMenu"] = true,
    ["/Script/ROD.RODMenuWidgetBase:ClosedMenu"] = true,
}

local function guardReacquireCallback(callback)
    if type(callback) ~= "function" then return callback end
    return function(...)
        local callbackArgs = table.pack(...)
        local previousExecuteWithDelay = ExecuteWithDelay
        ExecuteWithDelay = function(delayMs, action)
            return originalExecuteWithDelay(delayMs, function()
                -- ExecuteWithDelay runs on the async thread. The mounted-menu
                -- test dereferences UObjects, so dispatch the whole guarded pass
                -- to the game thread rather than inspecting the widget tree here.
                local scheduled, scheduleError = pcall(function()
                    ExecuteInGameThread(function()
                        if hasMountedVisibleStartMenu() then action() end
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
            results = table.pack(callback(table.unpack(callbackArgs, 1, callbackArgs.n)))
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
    return dofile(SCRIPT_DIR .. "main_impl.lua")
end, debug.traceback)

RegisterHook = originalRegisterHook
ExecuteWithDelay = originalExecuteWithDelay

if not ok then error(result) end
return result
