-- TestRunner.lua
-- Minimal Lua test harness for CombatAnalytics unit tests.
-- Usage (from Lua 5.1/5.2 CLI or WoW addon harness):
--
--   dofile("test/TestRunner.lua")
--   dofile("test/mocks/WowApi.lua")
--   dofile("test/test_ActorResolution.lua")
--   TestRunner.RunAll()
--
-- Output example:
--   [PASS] UnitGraphService / resolves known GUID for token
--   [FAIL] UnitGraphService / pet owner lookup: expected "Player-X", got nil
--   ---
--   Passed: 11 / 12   Failed: 1

TestRunner = TestRunner or {}

local suites        = {}   -- list of { name, tests[] }
local currentSuite  = nil  -- active suite during describe()

local passCount = 0
local failCount = 0
local failures  = {}  -- list of { suite, test, message }

-- ---------------------------------------------------------------------------
-- describe / it
-- ---------------------------------------------------------------------------

--- Open a new test suite.
---@param name string  Human-readable suite name
---@param fn   function  Body that registers `it()` calls
function describe(name, fn)
    local suite = { name = name, tests = {} }
    suites[#suites + 1] = suite
    local prev = currentSuite
    currentSuite = suite
    local ok, err = pcall(fn)
    currentSuite = prev
    if not ok then
        -- Treat a describe-level error as an immediate failure.
        local msg = tostring(err)
        failures[#failures + 1] = { suite = name, test = "<describe>", message = msg }
        failCount = failCount + 1
    end
end

--- Register a single test case inside the current describe block.
---@param name string    Human-readable test name
---@param fn   function  Test body; throw (error/assert) to fail
function it(name, fn)
    if not currentSuite then
        error("it() called outside of describe()")
    end
    currentSuite.tests[#currentSuite.tests + 1] = { name = name, fn = fn }
end

-- ---------------------------------------------------------------------------
-- expect
-- ---------------------------------------------------------------------------

---@class Expectation
local Expectation = {}
Expectation.__index = Expectation

--- Strict equality (==).
function Expectation:toBe(expected)
    if self.value ~= expected then
        error(string.format("Expected %s but got %s",
            tostring(expected), tostring(self.value)), 2)
    end
end

--- Deep equality for tables; falls back to == for scalars.
function Expectation:toEqual(expected)
    local function deepEq(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table"  then return a == b end
        for k, v in pairs(a) do
            if not deepEq(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end
    if not deepEq(self.value, expected) then
        error(string.format("toEqual failed: expected %s, got %s",
            tostring(expected), tostring(self.value)), 2)
    end
end

--- Assert the value is nil.
function Expectation:toBeNil()
    if self.value ~= nil then
        error(string.format("Expected nil but got %s", tostring(self.value)), 2)
    end
end

--- Assert the value is not nil.
function Expectation:toNotBeNil()
    if self.value == nil then
        error("Expected a non-nil value but got nil", 2)
    end
end

--- Assert the value is truthy (non-nil, non-false).
function Expectation:toBeTruthy()
    if not self.value then
        error(string.format("Expected truthy but got %s", tostring(self.value)), 2)
    end
end

--- Assert the value is falsy (nil or false).
function Expectation:toBeFalsy()
    if self.value then
        error(string.format("Expected falsy but got %s", tostring(self.value)), 2)
    end
end

--- Assert a numeric value is greater than `threshold`.
function Expectation:toBeGreaterThan(threshold)
    if type(self.value) ~= "number" or self.value <= threshold then
        error(string.format("Expected %s > %s", tostring(self.value), tostring(threshold)), 2)
    end
end

--- Assert a string value contains `substring`.
function Expectation:toContain(substring)
    if type(self.value) ~= "string" or not self.value:find(substring, 1, true) then
        error(string.format("Expected string containing %q, got %q",
            tostring(substring), tostring(self.value)), 2)
    end
end

--- Begin an expectation chain for `value`.
---@param value any
---@return Expectation
function expect(value)
    return setmetatable({ value = value }, Expectation)
end

-- ---------------------------------------------------------------------------
-- RunAll
-- ---------------------------------------------------------------------------

--- Execute all registered test suites and print PASS/FAIL lines.
function TestRunner.RunAll()
    passCount = 0
    failCount = 0
    failures  = {}

    for _, suite in ipairs(suites) do
        for _, test in ipairs(suite.tests) do
            local ok, err = pcall(test.fn)
            if ok then
                passCount = passCount + 1
                print(string.format("[PASS] %s / %s", suite.name, test.name))
            else
                failCount = failCount + 1
                local msg = tostring(err)
                failures[#failures + 1] = {
                    suite   = suite.name,
                    test    = test.name,
                    message = msg,
                }
                print(string.format("[FAIL] %s / %s: %s", suite.name, test.name, msg))
            end
        end
    end

    print("---")
    print(string.format("Passed: %d / %d   Failed: %d",
        passCount, passCount + failCount, failCount))

    if #failures > 0 then
        print("--- First failure detail:")
        local f = failures[1]
        print(string.format("  Suite : %s", f.suite))
        print(string.format("  Test  : %s", f.test))
        print(string.format("  Error : %s", f.message))
    end

    return failCount == 0
end

--- Reset all state (useful when re-running suites in the same Lua state).
function TestRunner.Reset()
    suites       = {}
    currentSuite = nil
    passCount    = 0
    failCount    = 0
    failures     = {}
end
