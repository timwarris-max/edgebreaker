-- tests/tools/dump-template.lua
-- Hex-dump N bytes after a UTF-16LE tag in a .ToolpathTemplate.
-- Usage: lua tests/tools/dump-template.lua <file> <asciiTag> [count]
local path, tag, count = arg[1], arg[2], tonumber(arg[3] or 64)
local f = assert(io.open(path, "rb"))
local bytes = f:read("*a"); f:close()
local needle = tag:gsub(".", "%0\0")
local s, e = string.find(bytes, needle, 1, true)
if s == nil then print("tag not found: " .. tag); os.exit(1) end
print(string.format("tag '%s' at byte %d..%d (1-based)", tag, s, e))
for i = e + 1, math.min(#bytes, e + count) do
   local b = bytes:byte(i)
   io.write(string.format("%5d: %02X %s\n", i, b,
      (b >= 32 and b < 127) and string.char(b) or "."))
end
