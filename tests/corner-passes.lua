-- Emit the real pass table for a run, straight out of EdgeBreaker's own
-- arithmetic, as JSON for the wedge model to consume.
-- Feeds tests/corner-model.js. Run from the repo root:
--   lua tests\corner-passes.lua setback 0.12 90 0.25 40 inside
package.preload.strict = function() return true end
dofile("gadget/EdgeBreaker/EdgeBreaker.lua")
local CO = EdgeBreaker

local mode, size, incl, dia, percent, side = ...
size    = tonumber(size)
incl    = tonumber(incl)
dia     = tonumber(dia)
percent = tonumber(percent)

local ev = CO.evaluate(mode, size, incl, dia)
if not ev.ok then error("refused: " .. tostring(ev.reason)) end

local s
for _, p in ipairs(ev.presets) do if p.percent == percent then s = p end end
if not s then error("no preset " .. tostring(percent)) end

local n   = ev.passes
local dir = (side == "outside") and "outward" or "inward"

local parts = {}
for k = 1, n do
   local pg   = CO.pass_geometry(k, n, ev.W, s.g, ev.a)
   local dist = CO.band_offset_distance(dir, pg.offset)
   parts[#parts + 1] = string.format('{"k":%d,"dist":%.10g,"depth":%.10g}', k, dist, pg.depth)
end

print(string.format(
   '{"mode":"%s","size":%.10g,"incl":%.10g,"dia":%.10g,"percent":%d,"side":"%s",'
   .. '"W":%.10g,"a":%.10g,"tan_a":%.10g,"n":%d,"band":%.10g,"g":%.10g,"d":%.10g,"passes":[%s]}',
   mode, size, incl, dia, percent, side,
   ev.W, ev.a, math.tan(ev.a), n, ev.band, s.g, s.d, table.concat(parts, ",")))
