-- Unit-test harness. Run from the repo root:
--   & "$env:LOCALAPPDATA\Programs\Lua\bin\lua.exe" tests\run-tests.lua
-- Loads the gadget in plain Lua (Aspire's built-in `strict` is stubbed).
package.preload.strict = function() return true end
dofile("gadget/EdgeBreaker/EdgeBreaker.lua")

local passed, failed = 0, 0
local current_file = "?"

function CHECK(cond, label)
   if cond then passed = passed + 1
   else
      failed = failed + 1
      print(string.format("FAIL [%s] %s", current_file, label or "?"))
   end
end

function NEAR(a, b, tol, label)
   CHECK(type(a) == "number" and math.abs(a - b) <= (tol or 1e-6),
         string.format("%s (got %s, want %.6f +/-%g)", label or "?", tostring(a), b, tol or 1e-6))
end

local files = {
   "test_geometry.lua",
   "test_slots.lua",
   "test_sdk_offset.lua",
   "test_release.lua",
   "test_settings.lua",
   "test_classify.lua",
   "test_memory.lua",
   "test_messages.lua",
   "test_dialog_size.lua",
   "test_topview.lua",
}
for _, f in ipairs(files) do
   current_file = f
   dofile("tests/" .. f)
end
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
