-- tests/tools/diff-templates.lua
-- List differing byte runs between two templates, each with the nearest
-- preceding UTF-16LE tag name (ASCII chars interleaved with NULs).
-- Usage: lua tests/tools/diff-templates.lua <fileA> <fileB>
local function slurp(p) local f = assert(io.open(p, "rb")); local b = f:read("*a"); f:close(); return b end
local A, B = slurp(arg[1]), slurp(arg[2])
print(string.format("sizes: %d vs %d", #A, #B))
local n = math.min(#A, #B)
local function tag_before(bytes, pos)
   -- walk back for a run of >=4 printable-ASCII UTF-16LE chars ending before pos
   for s = pos, 2, -1 do
      local run = {}
      local i = s
      while i >= 2 and bytes:byte(i) == 0 and bytes:byte(i - 1) >= 32 and bytes:byte(i - 1) < 127 do
         table.insert(run, 1, string.char(bytes:byte(i - 1)))
         i = i - 2
      end
      if #run >= 4 then return table.concat(run), i + 1 end
   end
   return "?", 0
end
local i = 1
while i <= n do
   if A:byte(i) ~= B:byte(i) then
      local j = i
      while j <= n and A:byte(j) ~= B:byte(j) do j = j + 1 end
      local tag = tag_before(A, i)
      print(string.format("diff %d..%d (len %d)  after tag '%s'", i, j - 1, j - i, tag))
      io.write("  A:")
      for k = i, math.min(j - 1, i + 15) do io.write(string.format(" %02X", A:byte(k))) end
      io.write("\n  B:")
      for k = i, math.min(j - 1, i + 15) do io.write(string.format(" %02X", B:byte(k))) end
      io.write("\n")
      i = j
   else
      i = i + 1
   end
end
