-- tests/tools/check-template.lua
-- Answer "is this .ToolpathTemplate the one we need?" with the gadget's OWN
-- readers, so the answer matches what the gadget will decide at run time.
-- Usage, from the repo root:
--   lua tests/tools/check-template.lua <file> [expected layer name]
-- dump-template.lua is the other half of this pair: it hex-dumps bytes after a
-- named tag and needs that tag as an argument -- use it when this one says
-- something is wrong and you need to see the actual bytes.
package.preload.strict = function() return true end
dofile("gadget/EdgeBreaker/EdgeBreaker.lua")
local CO = EdgeBreaker

local path = arg[1] or error("usage: check-template.lua <file> [expected layer]")
local want_layer = arg[2] or "EdgeBreaker - Offset 01"
local f = assert(io.open(path, "rb"))
local bytes = f:read("*a"); f:close()

print("file:  " .. path)
print("size:  " .. #bytes .. " bytes")

local problems = {}
local function want(label, got, expected)
   local ok = (got == expected)
   print(string.format("%-16s %-28s %s", label .. ":", tostring(got),
                       ok and "OK" or ("WANT " .. tostring(expected))))
   if not ok then problems[#problems + 1] = label end
end

local layers, lerr = CO.read_template_layers(bytes)
if layers == nil then
   print("layers:          ERROR " .. tostring(lerr))
   problems[#problems + 1] = "layers"
else
   want("layer count", #layers, 1)
   want("layer name", layers[1], want_layer)
end
want("machine vectors", CO.read_machine_vectors(bytes), "on")
want("units", CO.read_template_units(bytes), "in")
want("depth patchable", CO.find_depth_offset(bytes) ~= nil, true)

if #problems == 0 then
   print("\nRESULT: USABLE as the v1.5.0 shipped template.")
else
   print("\nRESULT: NOT USABLE - " .. table.concat(problems, ", ")
         .. "\nRe-save it from Aspire. Never patch a template by hand: Aspire"
         .. "\naccepts value edits of the same length but rejects anything that"
         .. "\nchanges a record's size.")
   os.exit(1)
end
