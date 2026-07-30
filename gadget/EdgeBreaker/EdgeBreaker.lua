-- VECTRIC LUA SCRIPT
require "strict"
-- ============================================================
-- EdgeBreaker — V-bit chamfer via offset-into-waste + cut On.
-- Spec:      docs/superpowers/specs/2026-07-26-edgebreaker-v1.5-design.md
--            (v1.0-1.4 spec: docs/superpowers/specs/2026-07-22-chamfer-offset-gadget-design.md)
-- SDK facts: docs/m0-results.md
-- Pure geometry lives in the CO table so plain Lua can load and
-- unit-test this file. Only main() and CO.sdk_* touch the SDK.
-- The gadget was called ChamferOffset through v1.4.x; that spelling now
-- survives ONLY where an older job's layers and toolpaths must still be
-- recognized (see CO.OLD_LAYER_PREFIX and the LEGACY_* constants).
-- ============================================================

EdgeBreaker = {}
local CO = EdgeBreaker

CO.SHOULDER_MARGIN = 0.90   -- top of safe band: depth <= 90% of D_max
CO.TIP_MARGIN      = 0.15   -- bottom of safe band: contact clears the tip
-- Positions ACROSS THE SAFE BAND, not across the physical flute: 0% is the
-- bottom of the band (contact still clears the tip by TIP_MARGIN), 100% the top
-- (SHOULDER_MARGIN). Keep in step with PRESETS in EdgeBreakerDialog.htm.
CO.PRESETS         = { 0, 20, 40, 60, 80, 100 }
CO.MODES           = { setback = true, face = true, leg = true }
CO.SIDES           = { auto = true, outside = true, inside = true }
CO.VERSION         = "1.9.1"

-- ONE template, not one per bit. The bit now comes from Aspire's tool library
-- (live-proven 2026-07-25), which supplies angle, diameter, feeds, speeds and
-- units; the template supplies only the STRATEGY (Profile, Machine Vectors On,
-- restricted to the offset layer) because that is the part Aspire will not let
-- us synthesize — see the "templates must be Aspire-authored" rule. After the
-- template loads, Toolpath:ReplaceTool swaps its tool for the one the user
-- picked. Its old name encoded the bit; a fixed name says it no longer does.
CO.TEMPLATE_NAME = "EdgeBreaker.ToolpathTemplate"

-- Registry section for ToolDBId Save/LoadDefaults, which is how Aspire itself
-- remembers a gadget's last-picked tool (Keyhole/Dragknife do the same).
CO.TOOL_SECTION = "EdgeBreaker"

-- A library tool stores its own units, which need not be the job's: a 6mm bit
-- is a legitimate choice in an inch job, and the material block's thickness can
-- disagree the same way. The angle is unitless; only lengths convert. Returns
-- nil for an unusable value rather than guessing.
function CO.length_in_job_units(len, src_in_mm, job_in_mm)
   if type(len) ~= "number" or len ~= len or len <= 0 then return nil end
   if src_in_mm == job_in_mm then return len end
   if src_in_mm then return len / 25.4 end
   return len * 25.4
end

-- Guard the two numbers the chamfer math depends on before they reach it. A
-- V-bit's included angle must leave a real half-angle (0 < a < 90 degrees).
function CO.check_tool_geometry(angle, dia)
   if type(angle) ~= "number" or angle ~= angle or angle <= 0 or angle >= 180 then
      return nil, "This bit reports an included angle of " .. tostring(angle)
                  .. ", which cannot be machined. Check the bit in Aspire's tool database."
   end
   if type(dia) ~= "number" or dia ~= dia or dia <= 0 then
      return nil, "This bit reports a diameter of " .. tostring(dia)
                  .. ". Check the bit in Aspire's tool database."
   end
   return true
end

-- Dialog window size, in physical pixels, per machine. The page is authored at
-- one fixed size and scales itself down to whatever window it is given (see
-- EdgeBreakerDialog.htm), so a machine with a smaller screen gets a smaller window
-- rather than a cramped layout.
-- A dialog cannot resize itself, so this must be right before it opens.
--
-- DESIGN_SIZE is what the LAYOUT is authored against -- keep it in step with
-- DESIGN_W/H in EdgeBreakerDialog.htm and WIN_W/H in the layout gate. It is
-- deliberately NOT the default window any more.
--
-- DEFAULT_SIZE is what an unlisted machine opens at, and every machine but ours
-- is unlisted. It has to fit a screen we have never seen, so it is sized for
-- 1366x768 -- the ordinary laptop. Until 2026-07-29 the default WAS the design
-- size, which is bigger than that screen in both directions, and because the
-- OK/Cancel bar is pinned to the bottom of the window the buttons went off the
-- bottom of the screen. Reported from the field by a VCarve Pro 12.510 user; the
-- table used to list the one small screen and default to the big one, and now
-- lists the big screens and defaults to small. Getting this wrong is invisible
-- here and unusable there, so it is pinned by tests/test_dialog_size.lua.
CO.DESIGN_SIZE  = { 1800, 1000 }        -- keep in step with EdgeBreakerDialog.htm
CO.DEFAULT_SIZE = { 1280, 700 }         -- anyone we do not know: fits 1366x768
CO.SCREEN_SIZES = {
   ["FASTTRACKS2026"] = { 1800, 1000 }, -- 5120x1440 ultrawide desktop
   ["HAAS-LAPTOP"]    = { 1280, 720 },  -- Acer A315-54, 1920x1080 @ 100%
}

-- Styled messages (see docs/superpowers/specs/2026-07-28-edgebreaker-styled-messages-design.md).
-- The class names are the setup dialog's own banner palette under different
-- names, so the two windows are visibly one product.
CO.MESSAGE_KINDS = { error = "m-error", warn = "m-warn", done = "m-done" }

-- Physical pixels, like every other dialog here, and a dialog cannot resize
-- itself. Two sizes, chosen by one rule: rows present -> tall. Both fit the
-- shop laptop's 1280x720, where the setup dialog already opens at the full
-- 1280x720.
--
-- These are WINDOW sizes, not client sizes: HTML_Dialog's frame costs 2x50
-- (live measured, session 023 -- an 1800x1000 window reports body.client
-- 1798x950), so the page really gets 898x450 and 898x650. The first pair of
-- numbers here was 460/640, chosen against the window size by mistake, which
-- left the longest message overflowing by 9px and the ordinary post-run report
-- clipped 43px behind the button bar. Found by rendering, 2026-07-28; the gate
-- now takes the frame off before it measures anything.
CO.MESSAGE_SIZE_SHORT = { 900, 500 }
CO.MESSAGE_SIZE_TALL  = { 900, 700 }

-- Rows travel as one string in a hidden field, the same shape as BannerFacts
-- (`sel=2;excluded=1:2,3:1;mem=4`), which is live-proven to survive the trip.
-- Values are escaped so a value containing a delimiter cannot split a row in
-- the wrong place; the page walks the string honouring the escapes.
local function escape_row_part(v)
   v = tostring(v or "")
   v = v:gsub("\\", "\\\\")
   v = v:gsub(";", "\\;")
   v = v:gsub("=", "\\=")
   return v
end

function CO.encode_rows(rows)
   if rows == nil or #rows == 0 then return "" end
   local out = {}
   for _, r in ipairs(rows) do
      out[#out + 1] = escape_row_part(r[1]) .. "=" .. escape_row_part(r[2])
   end
   return table.concat(out, ";")
end

-- Pure: no SDK contact, so the whole of the logic is exercised by the unit
-- suite. Returns the flat field set the page reads, plus the window size.
function CO.message_fields(msg)
   local cls = CO.MESSAGE_KINDS[msg.kind] or CO.MESSAGE_KINDS.error
   local has_rows = msg.rows ~= nil and #msg.rows > 0
   local size = has_rows and CO.MESSAGE_SIZE_TALL or CO.MESSAGE_SIZE_SHORT
   return {
      MKind    = cls,
      MHead    = msg.headline or "",
      MBody    = msg.body or "",
      MRows    = CO.encode_rows(msg.rows),
      MNote    = msg.note or "",
      MVersion = "v" .. CO.VERSION,
   }, size[1], size[2]
end

CO.MESSAGE_FIELD_NAMES = { "MKind", "MHead", "MBody", "MRows", "MNote", "MVersion" }

-- Display-only, and it can never fail a run: no caller branches on it and it
-- always returns. Every way it can go wrong lands on the plain message box --
-- including a bad or missing msg.plain, which is why that fallback has its
-- own fallbacks rather than trusting the one field nothing here validates.
--
-- The file probe is not defensive padding -- it is the receipt's own hard-won
-- lesson. The realistic failure here is a sync that did not copy the new page,
-- and without the probe Aspire renders the file path as text and calls it a
-- report.
function CO.show_message(gadget_dir, msg)
   local shown = false
   pcall(function()
      local probe = io.open(gadget_dir .. "\\MessageDialog.htm", "r")
      if probe == nil then return end
      probe:close()
      local fields, w, h = CO.message_fields(msg)
      local dlg = HTML_Dialog(false, "file:" .. gadget_dir .. "\\MessageDialog.htm",
                              w, h, "EdgeBreaker v" .. CO.VERSION)
      for _, k in ipairs(CO.MESSAGE_FIELD_NAMES) do
         dlg:AddTextField(k, fields[k] or "")
      end
      -- Closing with the X returns false, which is not a failure: the operator
      -- saw the message and dismissed it. Nothing is read back.
      dlg:ShowDialog()
      shown = true
   end)
   if not shown then
      DisplayMessageBox(msg.plain or msg.headline
         or "EdgeBreaker ran into a problem.")
   end
end

-- Unknown machine -> the design size, i.e. exactly what shipped before. Sizes
-- must never exceed the design size: the page only ever scales down.
function CO.dialog_size(computer_name)
   local s = CO.SCREEN_SIZES[string.upper(computer_name or "")]
   s = s or CO.DEFAULT_SIZE
   return s[1], s[2]
end

-- Display units follow the open job (job.InMM). ~0.5mm and 0.020in are
-- equivalent everyday chamfer defaults.
function CO.unit_info(is_mm)
   if is_mm then return { suffix = "mm", default_size = 0.5 } end
   return { suffix = "in", default_size = 0.020 }
end

function CO.half_angle(included_deg)
   return math.rad(included_deg / 2)
end

function CO.w_from_size(mode, size, a)
   if mode == "setback" then return size
   elseif mode == "face" then return size * math.sin(a)
   elseif mode == "leg"  then return size * math.tan(a)
   end
   error("unknown size mode: " .. tostring(mode))
end

function CO.safe_band(dia, W, a)
   local r = dia / 2
   local d_max = r / math.tan(a)
   local g_lo  = CO.TIP_MARGIN * r
   local g_hi  = CO.SHOULDER_MARGIN * r - W
   return g_lo, g_hi, d_max
end

function CO.solve(percent, dia, W, a)
   local g_lo, g_hi = CO.safe_band(dia, W, a)
   local g = g_lo + (percent / 100) * (g_hi - g_lo)
   local d = (W + g) / math.tan(a)
   return { g = g, d = d, band_lo = g / math.tan(a), band_hi = d, standoff = g }
end

function CO.evaluate(mode, size, included_deg, dia)
   local a = CO.half_angle(included_deg)
   local W = CO.w_from_size(mode, size, a)
   local g_lo, g_hi, d_max = CO.safe_band(dia, W, a)
   local ok = g_hi > g_lo
   local presets = {}
   if ok then
      for _, p in ipairs(CO.PRESETS) do
         local s = CO.solve(p, dia, W, a)
         s.percent = p
         presets[#presets + 1] = s
      end
   end
   local reason = nil
   if not ok then
      reason = "Chamfer too big for a safe cut with this bit: it would force the "
             .. "cut onto the tip or the shoulder. Use a larger bit or a smaller chamfer."
   end
   return {
      W = W, a = a, g_lo = g_lo, g_hi = g_hi, d_max = d_max,
      ok = ok, presets = presets,
      reason = reason,
      tip_flat_advisory =
         "Low presets cut nearer the tip; if the tip flat widens the chamfer, "
       .. "reduce depth by delta/tan(a). High presets bury the flat in waste (no correction).",
   }
end

-- Aspire's embedded Lua version is unconfirmed; guard version-specific names.
local atan2 = math.atan2 or math.atan   -- 5.1 has atan2; 5.3+ folds it into atan(y, x)

local function circle_through(x1, y1, x2, y2, x3, y3)
   local d = 2 * (x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2))
   if math.abs(d) < 1e-12 then return nil end          -- collinear
   local s1, s2, s3 = x1 * x1 + y1 * y1, x2 * x2 + y2 * y2, x3 * x3 + y3 * y3
   local cx = (s1 * (y2 - y3) + s2 * (y3 - y1) + s3 * (y1 - y2)) / d
   local cy = (s1 * (x3 - x2) + s2 * (x1 - x3) + s3 * (x2 - x1)) / d
   return cx, cy, math.sqrt((x1 - cx) ^ 2 + (y1 - cy) ^ 2)
end

function CO.polygonize_span(rec, tol)
   if rec.type == "line" then
      return { { rec.x1, rec.y1 }, { rec.x2, rec.y2 } }
   elseif rec.type == "arc" then
      local cx, cy, r = circle_through(rec.x1, rec.y1, rec.mx, rec.my, rec.x2, rec.y2)
      if cx == nil then                                 -- degenerate: treat as line
         return { { rec.x1, rec.y1 }, { rec.x2, rec.y2 } }
      end
      local a1 = atan2(rec.y1 - cy, rec.x1 - cx)
      local am = atan2(rec.my - cy, rec.mx - cx)
      local a2 = atan2(rec.y2 - cy, rec.x2 - cx)
      -- sweep from a1 to a2 passing through am
      local TWO_PI = 2 * math.pi
      local da_m = (am - a1) % TWO_PI
      local da_e = (a2 - a1) % TWO_PI
      local sweep = (da_m <= da_e) and da_e or (da_e - TWO_PI)
      -- chord-deviation step: cos(step/2) = 1 - tol/r
      local step = 2 * math.acos(math.max(-1, 1 - tol / r))
      local n = math.max(8, math.ceil(math.abs(sweep) / step))
      local pts = {}
      for i = 0, n do
         local a = a1 + sweep * (i / n)
         pts[#pts + 1] = { cx + r * math.cos(a), cy + r * math.sin(a) }
      end
      -- pin exact endpoints (float drift)
      pts[1] = { rec.x1, rec.y1 }; pts[#pts] = { rec.x2, rec.y2 }
      return pts
   elseif rec.type == "bezier" then
      local N = 32   -- plenty at chamfer scale; chamfer contours rarely carry beziers
      local pts = {}
      for i = 0, N do
         local t, u = i / N, 1 - i / N
         pts[#pts + 1] = {
            u^3 * rec.x1 + 3 * u^2 * t * rec.c1x + 3 * u * t^2 * rec.c2x + t^3 * rec.x2,
            u^3 * rec.y1 + 3 * u^2 * t * rec.c1y + 3 * u * t^2 * rec.c2y + t^3 * rec.y2,
         }
      end
      return pts
   end
   error("unknown span type: " .. tostring(rec.type))
end

function CO.polygonize(spans, tol)
   local loop = {}
   local function push(p)
      local last = loop[#loop]
      if last and math.abs(last[1] - p[1]) < 1e-9 and math.abs(last[2] - p[2]) < 1e-9 then
         return   -- drop consecutive duplicates (shared span endpoints)
      end
      loop[#loop + 1] = p
   end
   for _, rec in ipairs(spans) do
      for _, p in ipairs(CO.polygonize_span(rec, tol)) do push(p) end
   end
   -- drop the closing point if the loop returned to its start
   if #loop > 1 then
      local a, b = loop[1], loop[#loop]
      if math.abs(a[1] - b[1]) < 1e-9 and math.abs(a[2] - b[2]) < 1e-9 then
         loop[#loop] = nil
      end
   end
   return loop
end

function CO.signed_area(pts)
   local a, n = 0, #pts
   for i = 1, n do
      local j = i % n + 1
      a = a + pts[i][1] * pts[j][2] - pts[j][1] * pts[i][2]
   end
   return a / 2
end

function CO.point_in_poly(x, y, pts)
   local inside, n = false, #pts
   local j = n
   for i = 1, n do
      local xi, yi = pts[i][1], pts[i][2]
      local xj, yj = pts[j][1], pts[j][2]
      if ((yi > y) ~= (yj > y)) and
         (x < (xj - xi) * (y - yi) / ((yj - yi) ~= 0 and (yj - yi) or 1e-12) + xi) then
         inside = not inside
      end
      j = i
   end
   return inside
end

local function loop_bbox(pts)
   local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
   for _, p in ipairs(pts) do
      x0 = math.min(x0, p[1]); y0 = math.min(y0, p[2])
      x1 = math.max(x1, p[1]); y1 = math.max(y1, p[2])
   end
   return x0, y0, x1, y1
end

function CO.classify_directions(loops)
   local out = {}
   for i, li in ipairs(loops) do
      local ax0, ay0, ax1, ay1 = loop_bbox(li.pts)
      local inner = false
      for k, lk in ipairs(loops) do
         if k ~= i then
            local bx0, by0, bx1, by1 = loop_bbox(lk.pts)
            if ax0 >= bx0 and ay0 >= by0 and ax1 <= bx1 and ay1 <= by1
               and CO.point_in_poly(li.pts[1][1], li.pts[1][2], lk.pts) then
               inner = true; break
            end
         end
      end
      out[i] = inner and "inward" or "outward"
   end
   return out
end

-- Per-run chamfer side override (spec 2026-07-25). The dialog's Side field
-- sends "auto"/"outside"/"inside"; only the two explicit values force a
-- direction — anything else (auto, nil, garbage) falls back to nesting, so
-- the worst failure mode is the old automatic behavior.
function CO.resolve_directions(loops, side)
   if side == "outside" or side == "inside" then
      local dir = (side == "outside") and "outward" or "inward"
      local out = {}
      for i = 1, #loops do out[i] = dir end
      return out
   end
   return CO.classify_directions(loops)
end

-- Pure-Lua IEEE-754 little-endian double encoder. No frexp (removed in 5.4),
-- no string.pack (absent before 5.3) — works on any Lua Aspire might embed.
function CO.encode_double_pure(x)
   local sign = 0
   if x < 0 then sign = 1; x = -x end
   local mant, exp
   if x == 0 then
      mant, exp = 0, 0
   else
      exp = 0
      while x >= 2 do x = x / 2; exp = exp + 1 end
      while x < 1 do x = x * 2; exp = exp - 1 end
      exp = exp + 1023
      mant = math.floor((x - 1) * 2 ^ 52 + 0.5)
      if mant >= 2 ^ 52 then mant = 0; exp = exp + 1 end   -- rounding carried over
   end
   local bytes = {}
   for i = 1, 6 do
      bytes[i] = math.floor(mant % 256)
      mant = math.floor(mant / 256)
   end
   bytes[7] = (exp % 16) * 16 + math.floor(mant % 16)
   bytes[8] = sign * 128 + math.floor(exp / 16)
   local s = ""
   for i = 1, 8 do s = s .. string.char(bytes[i]) end
   return s
end

function CO.encode_double(x)
   if string.pack then return string.pack("<d", x) end
   return CO.encode_double_pure(x)
end

-- The cut depth in a .ToolpathTemplate is an 8-byte LE double, 4 bytes after
-- the UTF-16LE parameter name "_ppdCutDepth". Verified against a real template:
-- the value occurs exactly once; "_ppdCutDepthFormula" shares the prefix and
-- must be skipped. We patch bytes in place — same length, same structure.
local DEPTH_NEEDLE = ("_ppdCutDepth"):gsub(".", "%0\0")   -- ASCII -> UTF-16LE

function CO.find_depth_offset(bytes)
   local hits, init = {}, 1
   while true do
      local s, e = string.find(bytes, DEPTH_NEEDLE, init, true)
      if s == nil then break end
      if bytes:sub(e + 1, e + 2) ~= "F\0" then hits[#hits + 1] = e end
      init = e + 1
   end
   if #hits ~= 1 then
      return nil, "expected exactly one _ppdCutDepth in template, found " .. #hits
   end
   return hits[1] + 5   -- skip the 4-byte tag between name and value (1-based)
end

-- A template states its depth TWICE. _ppdCutDepth (above) is what the toolpath
-- form displays; "_mctddDepthValues" is the pass list behind Edit Passes, one
-- "%.6f;" entry per pass. Aspire cuts the PASS LIST: patching only the double
-- left the form reading 0.1098 while Specify Pass Depths said "Total Depth Of
-- Cut: 0.05" - the depth the shipped template was saved at - so every chamfer
-- came out undersized (live-confirmed 2026-07-25). Same string layout
-- read_template_layers documents: 4-byte type tag, FF FE FF, 1-byte character
-- count, then that many UTF-16LE characters. The count is one byte, so the
-- replacement text must stay short - "%.6f;" of a plausible depth always is.
local DEPTHVALS_NEEDLE = ("_mctddDepthValues"):gsub(".", "%0\0")
local NUMPASSES_NEEDLE = ("_mctddNumPasses"):gsub(".", "%0\0")

function CO.patch_pass_depths(bytes, depth)
   local _, e = string.find(bytes, DEPTHVALS_NEEDLE, 1, true)
   if e == nil then return bytes end     -- no pass list: the cut depth stands alone
   local count_at = e + 8
   local len = bytes:byte(count_at)
   if len == nil or len <= 0 or len > 250 then
      return nil, "implausible pass-depth list length: " .. tostring(len)
   end
   local last = count_at + len * 2
   if last > #bytes then return nil, "pass-depth list truncated" end
   local text = string.format("%.6f;", depth)
   if #text > 250 then return nil, "pass-depth value too long: " .. text end
   return bytes:sub(1, count_at - 1) .. string.char(#text)
          .. (text:gsub(".", "%0\0")) .. bytes:sub(last + 1)
end

-- One full-depth V pass. A user template saved with several passes would keep
-- its old count and misread the single value we just wrote.
function CO.patch_num_passes(bytes, n)
   local _, e = string.find(bytes, NUMPASSES_NEEDLE, 1, true)
   if e == nil then return bytes end
   local at = e + 5                      -- skip the 4-byte type tag
   if at + 3 > #bytes then return nil, "pass count truncated" end
   local u32 = string.char(n % 256, math.floor(n / 256) % 256,
                           math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
   return bytes:sub(1, at - 1) .. u32 .. bytes:sub(at + 4)
end

function CO.patch_template_depth(bytes, depth)
   local off, err = CO.find_depth_offset(bytes)
   if off == nil then return nil, err end
   local out = bytes:sub(1, off - 1) .. CO.encode_double(depth) .. bytes:sub(off + 8)
   local perr
   out, perr = CO.patch_pass_depths(out, depth)
   if out == nil then return nil, perr end
   return CO.patch_num_passes(out, 1)
end

-- Aspire's START depth: where the cut begins, measured down from the top of
-- the stock. The chamfer maths does not change with it -- W, G and D describe
-- the bit's cone against the edge, and that is the same relationship wherever
-- the edge happens to sit -- so a start depth simply translates the whole cut
-- down, and the total reach into the stock becomes start + depth.
--
-- Same layout as the cut depth above: an 8-byte LE double 4 bytes after the
-- UTF-16LE name, with "_ppdStartDepthFormula" sharing the prefix and skipped
-- by the same test. Verified 2026-07-27 against all five templates in the
-- repo: each carries exactly one _ppdStartDepth and one _mctddStartDepth.
local START_NEEDLE = ("_ppdStartDepth"):gsub(".", "%0\0")
local MCTDD_START_NEEDLE = ("_mctddStartDepth"):gsub(".", "%0\0")

function CO.find_start_depth_offset(bytes)
   local hits, init = {}, 1
   while true do
      local s, e = string.find(bytes, START_NEEDLE, init, true)
      if s == nil then break end
      if bytes:sub(e + 1, e + 2) ~= "F\0" then hits[#hits + 1] = e end
      init = e + 1
   end
   if #hits ~= 1 then
      return nil, "expected exactly one _ppdStartDepth in template, found " .. #hits
   end
   return hits[1] + 5   -- skip the 4-byte tag between name and value (1-based)
end

function CO.patch_template_start_depth(bytes, start)
   local off, err = CO.find_start_depth_offset(bytes)
   if off == nil then return nil, err end
   local out = bytes:sub(1, off - 1) .. CO.encode_double(start) .. bytes:sub(off + 8)
   -- The pass list keeps its own copy, and the pass list is what Aspire cuts
   -- (see patch_pass_depths). An ABSENT mirror means the template has no pass
   -- list at all, which is that function's "the cut depth stands alone" case:
   -- unchanged bytes, not an error.
   local _, me = string.find(out, MCTDD_START_NEEDLE, 1, true)
   if me == nil then return out end
   local at = me + 5
   if at + 7 > #out then return nil, "start-depth mirror truncated" end
   return out:sub(1, at - 1) .. CO.encode_double(start) .. out:sub(at + 8)
end

-- A template's layer restriction is OPTIONAL: "_vcgfNumLayers" may be 0, in which
-- case no "_vcgfLayerName<i>" tags exist at all (confirmed against a real template
-- saved without layer scoping). Layout (tests/tools/dump-template.lua — see
-- docs/m0-results.md):
--   _vcgfNumLayers: tag, 4-byte type tag (01 00 00 00), u32 LE count.
--   _vcgfLayerName<i>: tag, 4-byte type tag (03 00 00 00), 3 marker bytes
--     (FF FE FF), 1-byte character count, then that many UTF-16LE characters.
local NUMLAYERS_NEEDLE = ("_vcgfNumLayers"):gsub(".", "%0\0")

local function utf16le_needle(s)
   return (s):gsub(".", "%0\0")
end

function CO.read_template_layers(bytes)
   local _, ne = string.find(bytes, NUMLAYERS_NEEDLE, 1, true)
   if ne == nil then return nil, "no _vcgfNumLayers tag in template" end
   if ne + 8 > #bytes then return nil, "_vcgfNumLayers count truncated" end
   local n = bytes:byte(ne + 5) + bytes:byte(ne + 6) * 256
           + bytes:byte(ne + 7) * 65536 + bytes:byte(ne + 8) * 16777216
   if n > 32 then return nil, "implausible layer count: " .. tostring(n) end
   local layers = {}
   -- Per-index lookup relies on Aspire writing indices in ascending order --
   -- otherwise "_vcgfLayerName1" would prefix-match inside "_vcgfLayerName10"
   -- and misread past 9 layers.
   for i = 0, n - 1 do
      local needle = utf16le_needle("_vcgfLayerName" .. i)
      local _, e = string.find(bytes, needle, 1, true)
      if e == nil then return nil, "missing _vcgfLayerName" .. i .. " tag in template" end
      if e + 8 > #bytes then return nil, "_vcgfLayerName" .. i .. " header truncated" end
      local len = bytes:byte(e + 8)
      if len <= 0 or len > 256 then
         return nil, "implausible layer-name length: " .. tostring(len)
      end
      if e + 8 + len * 2 > #bytes then   -- guard against string.byte's silent zero past EOF
         return nil, "_vcgfLayerName" .. i .. " name truncated"
      end
      local out = {}
      for c = 0, len - 1 do
         out[#out + 1] = string.char(bytes:byte(e + 9 + c * 2))   -- ASCII from UTF-16LE
      end
      layers[#layers + 1] = table.concat(out)
   end
   return layers
end

-- Point the shipped template at one chamfer's layer. The replacement is the
-- same length as what it replaces -- two ASCII digits, four UTF-16LE bytes --
-- so the length prefix, the record and every offset in the file are untouched.
-- That is the same class of edit as the depth patch; inserting or resizing a
-- record is what Aspire rejects.
--
-- Only the name we shipped is accepted as a starting point. Patching a
-- template restricted to something else would aim the cut at a layer nobody
-- validated, which is exactly the failure the restriction exists to prevent.
function CO.patch_template_layer(bytes, slot)
   if type(bytes) ~= "string" then return nil, "no template bytes" end
   if type(slot) ~= "number" or slot < 1 or slot > 99 or slot % 1 ~= 0 then
      return nil, "slot out of range: " .. tostring(slot)
   end
   local shipped = CO.offset_layer_name(1)
   local needle = utf16le_needle(shipped)
   local _, e = string.find(bytes, needle, 1, true)
   if e == nil then
      return nil, "template is not restricted to '" .. shipped .. "'"
   end
   if string.find(bytes, needle, e + 1, true) ~= nil then
      return nil, "template names '" .. shipped .. "' more than once"
   end
   -- The two digits are the last two characters of the match: 4 bytes ending at e.
   local at = e - 3
   return bytes:sub(1, at - 1) .. utf16le_needle(string.format("%02d", slot))
          .. bytes:sub(at + 4)
end

-- Machine Vectors strategy, stored after the UTF-16LE tag "_ppdProfileType".
-- Codes verified against fixtures: 2=On, 0=Outside (1=Inside inferred, no
-- Inside fixture exists). See docs/m0-results.md.
local MV_NEEDLE = ("_ppdProfileType"):gsub(".", "%0\0")
local MV_CODES = { [0] = "outside", [1] = "inside", [2] = "on" }

function CO.read_machine_vectors(bytes)
   local _, e = string.find(bytes, MV_NEEDLE, 1, true)
   if e == nil then return nil, "no Machine Vectors tag in template" end
   local code = bytes:byte(e + 5)        -- first value byte after the 4-byte type tag
   local name = MV_CODES[code]
   if name == nil then return nil, "unknown Machine Vectors code: " .. tostring(code) end
   return name
end

-- Job-units flag the template was saved from, stored after the UTF-16LE tag
-- "_vcgfInMM" (1=mm, 0=in). Verified against fixtures: reads 1 in
-- mm-sample.ToolpathTemplate, 0 in mv-on/mv-outside/wrong-layer/sample.
local INMM_NEEDLE = ("_vcgfInMM"):gsub(".", "%0\0")

function CO.read_template_units(bytes)
   local _, e = string.find(bytes, INMM_NEEDLE, 1, true)
   if e == nil then return nil, "no _vcgfInMM tag in template" end
   local code = bytes:byte(e + 5)        -- first value byte after the 4-byte type tag
   if code == 1 then return "mm" end
   if code == 0 then return "in" end
   return nil, "unknown _vcgfInMM code: " .. tostring(code)
end

-- Check the single strategy template. The bit no longer comes from here, so
-- nothing is read from the filename any more — only the four things Aspire
-- bakes into the file that we cannot set ourselves: that it has a cut depth
-- and a start depth we can patch, that it is scoped to our offset layer, and
-- that it machines On rather than Outside/Inside. Returns true, or nil + a
-- reason written for the summary box.
function CO.validate_template(bytes, job_units)
   if bytes == nil then
      return nil, "The template file '" .. CO.TEMPLATE_NAME .. "' could not be read."
   end
   local _, derr = CO.find_depth_offset(bytes)
   if derr then
      return nil, "'" .. CO.TEMPLATE_NAME .. "' is not a usable toolpath template - "
                  .. "re-save it from Aspire (see Help)."
   end
   -- v1.6.0: a template we cannot aim in Z is as unusable as one we cannot
   -- aim in a layer. Required, not optional -- every Aspire profile template
   -- has one, so this only ever catches a genuinely broken file.
   local _, serr = CO.find_start_depth_offset(bytes)
   if serr then
      return nil, "'" .. CO.TEMPLATE_NAME .. "' has no start depth we can set - "
                  .. "re-save it from Aspire (see Help)."
   end
   -- The restriction is REQUIRED as of v1.4.0: it is what the per-slot patch
   -- rewrites, so an unscoped template has nothing to aim and would cut every
   -- chamfer's offsets at this run's depth.
   local layers, lerr = CO.read_template_layers(bytes)
   if layers == nil then
      return nil, "'" .. CO.TEMPLATE_NAME .. "' is not a usable toolpath template ("
                  .. tostring(lerr) .. ") - re-save it from Aspire (see Help)."
   end
   local want = CO.offset_layer_name(1)
   if #layers ~= 1 or layers[1] ~= want then
      return nil, "The template must be restricted to layer '" .. want .. "' but names "
                  .. (#layers == 0 and "no layer" or ("'" .. layers[1] .. "'"))
                  .. " - re-save it (see Help)."
   end
   local mv = CO.read_machine_vectors(bytes)
   if mv ~= "on" then
      return nil, "The template was saved with Machine Vectors = " .. tostring(mv)
                  .. " - re-save it with Machine Vectors 'On' (see Help)."
   end
   -- The depth we patch is in job units, so a template saved from the other
   -- unit system would be patched with a number it reads differently. Only a
   -- successful, contradicting read blocks it: an absent tag is not evidence.
   local template_units = CO.read_template_units(bytes)
   if template_units ~= nil and job_units ~= nil and template_units ~= job_units then
      local t_word = (template_units == "mm") and "mm" or "inch"
      local j_word = (job_units == "mm") and "mm" or "inch"
      return nil, "The template was saved from a " .. t_word .. " job but this job is in "
                  .. j_word .. ". Re-save the template from a " .. j_word
                  .. " job (see Help)."
   end
   return true
end

-- ==================== Last-used settings ====================
-- The dialog reopens with whatever was entered last run. Stored as one
-- key=value file per Windows user (see CO.settings_path), NOT in the gadget
-- folder: sync-gadgets.bat mirrors that folder with robocopy /MIR, which
-- deletes anything the repo doesn't have. Every remembered value is re-checked
-- against the current job before use — a value that no longer makes sense is
-- dropped, never corrected — so the worst a stale or hand-mangled file can do
-- is give back today's defaults.
-- "template" was dropped in 1.1.0: there is only one template now, and the BIT
-- is remembered by Aspire itself via ToolDBId (see CO.TOOL_SECTION). An old
-- file still containing template= parses fine and the key is simply ignored.
CO.SETTINGS_KEYS = { "units", "mode", "side", "percent", "size" }

function CO.serialize_settings(s)
   local out = { "# EdgeBreaker last-used settings - safe to delete" }
   for _, k in ipairs(CO.SETTINGS_KEYS) do
      local v = s[k]
      if type(v) == "number" then v = string.format("%.10g", v) end
      -- A value with a newline would be read back as a truncated line, so skip
      -- it rather than write a file we cannot parse. Filenames can't contain
      -- one; this only guards against a caller passing something exotic.
      if v ~= nil and not tostring(v):find("[\r\n]") then
         out[#out + 1] = k .. "=" .. tostring(v)
      end
   end
   return table.concat(out, "\n") .. "\n"
end

-- Text -> flat table of strings. Unknown keys are kept (harmless) and comment
-- or junk lines are ignored. Values keep any inner "=" so a filename survives.
function CO.parse_settings(text)
   if type(text) ~= "string" then return nil end
   local t, any = {}, false
   for line in text:gmatch("[^\r\n]+") do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k then t[k] = v; any = true end
   end
   if not any then return nil end
   return t
end

-- Decide what the dialog opens with. `enabled` is the list of templates valid
-- for THIS job's units, so a remembered bit that has been deleted, broken, or
-- belongs to the other unit system simply doesn't match and the first valid bit
-- wins — exactly the pre-1.0.6 behavior. Size is the one value that is unsafe
-- to carry across unit systems: 0.020 means a sane inch chamfer and an absurd
-- 0.020mm one, so it is only reused when the saved job units match.
-- The BIT is no longer remembered here: Aspire remembers it natively through
-- ToolDBId Save/LoadDefaults, which pre-selects it in the picker. This only
-- restores what the user typed on the setup dialog.
-- Start depth is the one value that is per-CHAMFER only: it reaches this
-- function from a memory blob but never from the settings file, which is
-- what makes adding a chamfer default to 0 without a special case.
function CO.apply_settings(saved, unit)
   saved = saved or {}
   local seed = {}
   seed.mode = CO.MODES[saved.mode] and saved.mode or "setback"
   seed.side = CO.SIDES[saved.side] and saved.side or "auto"
   seed.percent = 80
   local p = tonumber(saved.percent)
   for _, v in ipairs(CO.PRESETS) do
      if p == v then seed.percent = v end       -- only the ones the dialog offers
   end
   local sz = tonumber(saved.size)
   if sz and sz > 0 and saved.units == unit.suffix then seed.size = sz
   else seed.size = unit.default_size end
   -- Start depth is a length, so like size it is meaningless without the units
   -- it was typed in: dropped when they no longer match, never converted. It
   -- is absent from CO.SETTINGS_KEYS on purpose, so only a chamfer's own
   -- memory ever supplies one and a NEW chamfer always opens at 0.
   local st = tonumber(saved.start)
   if st and st >= 0 and saved.units == unit.suffix then seed.start = st
   else seed.start = 0 end
   return seed
end

-- ==================== Chamfer memory blob ====================
-- What ONE chamfer remembers (its shapes' fingerprints, size, mode, side,
-- percent, bit) — unlike the last-used settings above, which are per-user
-- and job-blind. The memory travels as a single framed line of |-separated
-- key=value pairs embedded in the blessed store's free text, so anything
-- the user wrote around it survives every rewrite. Unknown keys are
-- ignored on read (a future version may add some); a malformed fp entry is
-- dropped alone, never the whole memory. Where the blob lives is the
-- Task 1 live verdict; the SDK read/write glue is Task 7.
CO.MEMORY_OPEN = "[EdgeBreaker-DATA]"
CO.MEMORY_CLOSE = "[/EdgeBreaker-DATA]"
CO.MEMORY_VERSION = "EB1"

-- Shortest round-trippable text for a number: 0.02 stays "0.02" rather than
-- becoming "0.020000". Shared with the dropdown seeds, which are read back out
-- of the same blob.
local function num(v) return string.format("%.10g", v) end

function CO.encode_memory(mem)
   -- The tool id is free text inside a |-separated line: a | or newline in
   -- it would shear the blob, so both become spaces (ids never need them).
   local tool = tostring(mem.tool or ""):gsub("[|\r\n]", " ")
   local out = { CO.MEMORY_VERSION,
                 "size=" .. num(mem.size), "mode=" .. tostring(mem.mode),
                 "side=" .. tostring(mem.side), "percent=" .. num(mem.percent),
                 -- The size is a length, so it is meaningless without the units
                 -- it was typed in: apply_settings drops a remembered size whose
                 -- units no longer match the job's, exactly as it does for the
                 -- last-used settings file.
                 "units=" .. tostring(mem.units or ""),
                 "start=" .. num(mem.start or 0), "tool=" .. tool }
   for _, fp in ipairs(mem.fps or {}) do
      out[#out + 1] = string.format("fp=%s,%s,%s,%s",
         num(fp.cx), num(fp.cy), num(fp.xlen), num(fp.ylen))
   end
   return CO.MEMORY_OPEN .. table.concat(out, "|") .. CO.MEMORY_CLOSE
end

-- Framed line found ANYWHERE in the text -> mem table, or nil when there is
-- no complete frame. Plain-text find: the frame brackets are pattern magic.
function CO.decode_memory(text)
   if type(text) ~= "string" then return nil end
   local s = text:find(CO.MEMORY_OPEN, 1, true)
   if not s then return nil end
   local body_start = s + #CO.MEMORY_OPEN
   local e = text:find(CO.MEMORY_CLOSE, body_start, true)
   if not e then return nil end
   local mem = { fps = {} }
   for field in text:sub(body_start, e - 1):gmatch("[^|]+") do
      local k, v = field:match("^([%w_]+)=(.*)$")
      if k == "size" then mem.size = tonumber(v)
      elseif k == "percent" then mem.percent = tonumber(v)
      elseif k == "mode" then mem.mode = v
      elseif k == "side" then mem.side = v
      elseif k == "units" then mem.units = v
      elseif k == "start" then mem.start = tonumber(v)
      elseif k == "tool" then mem.tool = v
      elseif k == "fp" then
         local cx, cy, xl, yl = v:match("^([^,]+),([^,]+),([^,]+),([^,]+)$")
         cx, cy, xl, yl = tonumber(cx), tonumber(cy), tonumber(xl), tonumber(yl)
         if cx and cy and xl and yl then
            mem.fps[#mem.fps + 1] = { cx = cx, cy = cy, xlen = xl, ylen = yl }
         end
      end
      -- the version segment has no "=" and unknown keys fall through: ignored
   end
   return mem
end

-- New store text: an existing framed line is replaced in place, otherwise
-- the frame is appended on its own line. Surrounding user text untouched.
function CO.embed_memory(existing_text, mem)
   local line = CO.encode_memory(mem)
   local text = type(existing_text) == "string" and existing_text or ""
   local s = text:find(CO.MEMORY_OPEN, 1, true)
   if s then
      local e = text:find(CO.MEMORY_CLOSE, s, true)
      if e then
         return text:sub(1, s - 1) .. line .. text:sub(e + #CO.MEMORY_CLOSE)
      end
   end
   if text == "" then return line end
   if text:sub(-1) ~= "\n" then return text .. "\n" .. line end
   return text .. line
end

-- ==================== Toolpath ownership marker ====================
-- Re-running the gadget REPLACES that chamfer's toolpath instead of piling up
-- duplicates. Ownership is a marker in the toolpath NAME, so it lives in the
-- job file itself (works across machines, no state file): the gadget renames
-- every toolpath it creates to carry the marker, and deletes toolpaths marked
-- WITH THE SAME SLOT on the next run -- the same rule as that slot's offset
-- layer, which is wiped and redrawn every run. Other slots are never touched.
-- Escape hatch: rename a toolpath to drop the marker and the gadget will never
-- touch it again.
CO.LEGACY_TOOLPATH_MARKER = "[ChamferOffset]"    -- pre-1.4.0, reported but never rebuilt

CO.TOOLPATH_MARKER_HEAD = "[EdgeBreaker "
CO.OLD_TOOLPATH_MARKER_HEAD = "[ChamferOffset "   -- v1.4.x, recognized for adoption

function CO.toolpath_marker(slot)
   return string.format("[EdgeBreaker %02d]", slot)
end

function CO.toolpath_name(size, suffix, slot)
   return string.format("Chamfer %g %s %s", size, suffix, CO.toolpath_marker(slot))
end

-- Plain-text find: the marker's [ ] are Lua pattern magic, so never
-- pattern-match it. The two digits after the space ARE matched as a pattern,
-- but only on the remainder, after the brackets are out of the way.
-- ONE parser serves both name generations -- the v1.5.0 marker and the v1.4.x
-- one differ only in the head string they are handed.
local function slot_from_marked_toolpath(name, head)
   if type(name) ~= "string" then return nil end
   local at = name:find(head, 1, true)
   if at == nil then return nil end
   local digits = name:sub(at + #head):match("^(%d%d)%]")
   if digits == nil then return nil end
   local n = tonumber(digits)
   if n < 1 or n > 99 then return nil end
   return n
end

function CO.slot_from_toolpath_name(name)
   return slot_from_marked_toolpath(name, CO.TOOLPATH_MARKER_HEAD)
end

function CO.old_slot_from_toolpath_name(name)
   return slot_from_marked_toolpath(name, CO.OLD_TOOLPATH_MARKER_HEAD)
end

-- "Chamfer 0.06 in [EdgeBreaker 01]" -> "0.06 in", for the dropdown label.
-- The size is not stored anywhere else, so an unmarked or hand-renamed
-- toolpath simply has no label text and the dropdown says "offsets only".
-- Reads either generation, so an adopted v1.4.x chamfer still shows its size.
function CO.size_text_from_toolpath_name(name)
   local head = "Chamfer "
   if type(name) ~= "string" or name:sub(1, #head) ~= head then return nil end
   local at
   if CO.slot_from_toolpath_name(name) ~= nil then
      at = name:find(" " .. CO.TOOLPATH_MARKER_HEAD, 1, true)
   elseif CO.old_slot_from_toolpath_name(name) ~= nil then
      at = name:find(" " .. CO.OLD_TOOLPATH_MARKER_HEAD, 1, true)
   end
   if at == nil then return nil end
   local text = name:sub(#head + 1, at - 1)
   if text == "" then return nil end
   return text
end

-- v1.3.0 reporting. Aspire's offset returns NOTHING for a feature narrower than
-- the offset distance -- the correct answer, and the one our own offset used to
-- get wrong by returning an inside-out loop that cut a slot down the middle of a
-- letter. Nothing is drawn for those, so the summary has to say so or the user
-- reads silence as success. Pure, so this stays unit-testable now that the
-- geometry itself lives inside Aspire.
function CO.offset_count_phrase(total, offset_count)
   if offset_count == total then return string.format("%d vector(s)", total) end
   return string.format("%d of %d vector(s)", offset_count, total)
end

-- nil when nothing was skipped: an absent line is the right report for
-- "nothing to report", and the summary is already long.
function CO.skip_summary(skipped)
   if type(skipped) ~= "number" or skipped <= 0 then return nil end
   return string.format(
      "Note: %d vector(s) were too narrow to chamfer at this size and were skipped"
      .. " - they are the ones with no orange offset beside them.", skipped)
end

-- v1.7.0: does this run have anything to say? A clean run says NOTHING -- no
-- dialog to dismiss -- because the toolpath in the panel, the orange offsets on
-- the canvas and the restored selection already are the report, and the setup
-- dialog drew the cut before it was made.
--
-- Silence is only honest if it can never hide something. `notes` is sel_notes,
-- which by construction carries exactly the facts the user should act on: a
-- shape too narrow to chamfer, an open vector dropped, a remembered shape that
-- has gone, a layer that would not delete. Any of them breaks the silence, as
-- does any of the failures that set `trouble`.
--
-- Deliberately NOT triggers: replaced_note (routine on every rebuild) and
-- tip_flat_advisory (a constant string, always present).
function CO.should_report(trouble, notes)
   if trouble then return true end
   return type(notes) == "string" and notes:match("%S") ~= nil
end

-- What the toolpath delete MEANS, split from the SDK call so it can be tested.
-- `ok` is pcall's own verdict: false means sdk_delete_marked_toolpaths THREW, so
-- nothing was removed and `deleted`/`failed` are not counts at all.
--
-- That case used to fall straight through with trouble still false. Harmless
-- while every run ended in a message box; under v1.7.0's silence it leaves a
-- SECOND toolpath cutting the same chamfer and says nothing at all -- the one
-- path that defeats "no run ends with something worth saying and no way to say
-- it" (found by the v1.7.0 whole-branch review; the guard's own failure, not a
-- branch inside it, which is why tracing the trouble sites missed it).
function CO.delete_outcome(ok, deleted, failed, slot)
   if not ok then
      return true, "Could not remove the previous chamfer toolpath(s) - "
         .. "check the Toolpaths panel for duplicates."
   end
   local note = ""
   if deleted > 0 then
      note = string.format("Replaced Chamfer %d (removed %d previous toolpath(s)).",
                           slot, deleted)
   end
   if failed > 0 then
      return true, note .. string.format(
         " %d old chamfer toolpath(s) could not be removed - delete them in the Toolpaths panel.",
         failed)
   end
   return false, note
end

-- Notes for the two ways a loop can be dropped from the input before the
-- per-loop offset even runs: an open vector (skipped_open) or one of the
-- gadget's own orange offsets caught up in the selection (skipped_own).
-- #loops downstream is the count AFTER both drops, so any message reporting
-- against #loops needs this text too or a "None of the 12" can understate
-- what the user actually selected. Shared so the all-collapsed early return
-- in main() and the normal success report say the same thing the same way.
function CO.selection_skip_notes(skipped_open, skipped_own)
   local notes = ""
   if type(skipped_open) == "number" and skipped_open > 0 then
      notes = notes .. string.format("\n\nNote: %d open vector(s) skipped.", skipped_open)
   end
   if type(skipped_own) == "number" and skipped_own > 0 then
      notes = notes .. string.format(
         "\n\nNote: ignored %d selected vector(s) that are EdgeBreaker's own offsets.", skipped_own)
   end
   return notes
end

-- A label's size text comes from a toolpath NAME, which the user can rename in
-- Aspire -- so it is free text, and a stray ";" or "|" would split into a
-- spurious, selectable dropdown entry pointing at a slot nobody chose. Replace
-- rather than strip, so a mangled name still reads as mangled.
local function safe_label(text)
   return (tostring(text):gsub("[;|]", " "))
end

-- The Chamfer dropdown, as one string for the dialog: seven |-separated fields
-- "slot|label|relation|size|mode|side|percent" per record, records joined by
-- ";". The relation badges each entry against the CURRENT selection, so
-- changing chamfer in the dialog re-colours the banner without another trip
-- into Lua; the four seeds let it re-seed the form at the same moment. A
-- chamfer with no memory carries empty seeds and the dialog keeps whatever
-- Lua put in the Mode/Side/Percent/Size fields. next_slot is nil only when all
-- 99 are in use, and then no "New chamfer" entry is offered -- existing ones
-- can still be replaced.
--
-- missing_all is main()'s verdict (it needs the job to answer it): the chamfer
-- remembers shapes and NONE of them are still in the job. Spec 8 makes that
-- the amber teach state -- there is nothing left to rebuild from -- so the
-- relation is forced even though the seeds are still worth carrying.
function CO.encode_chamfer_list(chamfers, next_slot, sel_fps, eps)
   local out = {}
   for _, c in ipairs(chamfers or {}) do
      local label
      if c.size then label = string.format("Chamfer %d - %s", c.slot, safe_label(c.size))
      else label = string.format("Chamfer %d - offsets only", c.slot) end
      if c.missing_all then label = label .. " - shapes missing or moved" end
      local relation = CO.chamfer_relation(sel_fps or {}, c, eps)
      if c.missing_all then relation = "nomem" end
      local size, mode, side, percent = "", "", "", ""
      if c.memory then
         size    = num(c.memory.size or 0)
         mode    = safe_label(c.memory.mode or "")
         side    = safe_label(c.memory.side or "")
         percent = num(c.memory.percent or 0)
      end
      out[#out + 1] = string.format("%d|%s|%s|%s|%s|%s|%s",
                                    c.slot, label, relation, size, mode, side, percent)
   end
   if next_slot ~= nil then
      out[#out + 1] = string.format("%d|New chamfer (%d)|new||||", next_slot, next_slot)
   end
   return table.concat(out, ";")
end

-- "Chamfer 2" / "Chamfers 1 and 3" / "Chamfers 1, 2 and 4" — the refusals name
-- the chamfers they are talking about, and a list that reads like a sentence is
-- the difference between guidance and a diagnostic.
function CO.name_slots(slots)
   local n = #slots
   if n == 0 then return "" end
   if n == 1 then return "Chamfer " .. slots[1] end
   local head = {}
   for i = 1, n - 1 do head[i] = tostring(slots[i]) end
   return "Chamfers " .. table.concat(head, ", ") .. " and " .. slots[n]
end

-- The counts the banner quotes, as one field: how many shapes are selected,
-- which chamfers own the ones an add is leaving out, and how many the target
-- chamfer remembers. Every key is always present, so the dialog can parse
-- positionally without guarding each one.
function CO.encode_banner_facts(cls, sel_count, mem_count)
   local ex = {}
   for _, e in ipairs((cls and cls.excluded) or {}) do
      ex[#ex + 1] = string.format("%d:%d", e.slot, e.count)
   end
   return string.format("sel=%d;excluded=%s;mem=%d",
                        sel_count or 0, table.concat(ex, ","), mem_count or 0)
end

-- ==================== Aspire-only: SDK glue ====================
-- script_path may or may not include the gadget subfolder (a documented,
-- live-verified SDK gotcha — Inlay Doctor hit the same thing). Probe for
-- EdgeBreakerDialog.htm rather than assume script_path is a file path.
local function resolve_gadget_dir(script_path)
   local probe = io.open(script_path .. "\\EdgeBreakerDialog.htm", "r")
   if probe then probe:close(); return script_path end
   local sub = script_path .. "\\EdgeBreaker"
   probe = io.open(sub .. "\\EdgeBreakerDialog.htm", "r")
   if probe then probe:close(); return sub end
   return nil
end

-- One offset layer PER CHAMFER (v1.4.0). The number is padded so the layers
-- sort in Aspire's panel; everything the user reads says "Chamfer 1", not 01.
CO.OFFSET_LAYER_PREFIX = "EdgeBreaker - Offset "
CO.OLD_LAYER_PREFIX    = "ChamferOffset - Offset "   -- v1.4.x, recognized for adoption
CO.LEGACY_OFFSET_LAYER = "ChamferOffset - Offset"    -- pre-1.4.0 unnumbered, never adopted

function CO.offset_layer_name(slot)
   return string.format("%s%02d", CO.OFFSET_LAYER_PREFIX, slot)
end

-- nil for anything that is not one of ours, INCLUDING the unnumbered pre-1.4.0
-- layer: that one is reported to the user, never wiped or rebuilt.
-- ONE parser for both name generations, as with the toolpath markers above.
local function slot_from_prefixed_layer(name, prefix)
   if type(name) ~= "string" then return nil end
   if name:sub(1, #prefix) ~= prefix then return nil end
   local digits = name:sub(#prefix + 1)
   if digits:match("^%d%d$") == nil then return nil end
   local n = tonumber(digits)
   if n < 1 or n > 99 then return nil end
   return n
end

function CO.slot_from_layer_name(name)
   return slot_from_prefixed_layer(name, CO.OFFSET_LAYER_PREFIX)
end

function CO.old_slot_from_layer_name(name)
   return slot_from_prefixed_layer(name, CO.OLD_LAYER_PREFIX)
end

-- Where Aspire remembers the bit a given chamfer was built with. The empty key
-- is the gadget's global last-used bit (unchanged from v1.4.0); a per-slot key
-- alongside it is the only way back to a chamfer's own bit, since a ToolDBId
-- has no text form that could live in the memory blob.
function CO.tool_defaults_key(slot)
   return string.format("slot%02d", slot)
end

function CO.next_free_slot(used)
   local taken = {}
   for _, s in ipairs(used or {}) do taken[s] = true end
   for n = 1, 99 do
      if not taken[n] then return n end
   end
   return nil                                   -- all 99 in use; no new chamfer offered
end

-- %APPDATA% always exists on Windows, so no folder has to be created; a single
-- file there is per Windows user and per machine (the desktop and the shop
-- laptop each keep their own last-used bit, which is what we want).
local function settings_path_for(filename)
   local dir = os.getenv("APPDATA")
   if dir == nil or dir == "" then return nil end
   return dir .. "\\" .. filename
end

function CO.settings_path()
   return settings_path_for("EdgeBreaker-settings.txt")
end

-- v1.4.x wrote its settings under the old gadget name. Read-only fallback, so
-- an existing user's last-used size and mode survive the rename; the next save
-- writes the new file and the old one is simply left alone.
function CO.old_settings_path()
   return settings_path_for("ChamferOffset-settings.txt")
end

-- Both halves are best-effort and silent: remembering is a convenience, and a
-- locked, missing, or unreadable file must never interrupt a run.
function CO.load_settings()
   local function read(path)
      if path == nil then return nil end
      local ok, res = pcall(function()
         local f = io.open(path, "r")
         if f == nil then return nil end
         local text = f:read("*a"); f:close()
         return CO.parse_settings(text)
      end)
      if ok then return res end
      return nil
   end
   local res = read(CO.settings_path())
   if res ~= nil then return res end
   return read(CO.old_settings_path())
end

function CO.save_settings(s)
   local path = CO.settings_path()
   if path == nil then return false end
   return (pcall(function()
      local f = assert(io.open(path, "w"))
      f:write(CO.serialize_settings(s)); f:close()
   end))
end

-- Bbox fingerprint {cx, cy, xlen, ylen} of a CAD object, nil when unreadable.
-- (Box2D members live-proven in the Mastercam import gadget.)
local function bbox_fingerprint(obj)
   local ok, fp = pcall(function()
      local box = obj:GetBoundingBox()
      if box.IsInvalid then return nil end
      return { cx = box.Centre.x, cy = box.Centre.y,
               xlen = box.XLength, ylen = box.YLength }
   end)
   if ok then return fp end
   return nil
end

-- One contour -> plain span records, for the selection walk below. Until
-- v1.7.0 this was shared with sdk_object_loops, which read the offsets back off
-- the drawing for the run receipt's top view; that reading is gone.
local function contour_spans(c)
   local spans = {}
   local pos = c:GetHeadPosition()
   while pos ~= nil do
      local span
      span, pos = c:GetNext(pos)
      local s, e = span.StartPoint2D, span.EndPoint2D
      if span.Type == 1 then
         spans[#spans + 1] = { type = "line", x1 = s.x, y1 = s.y, x2 = e.x, y2 = e.y }
      elseif span.Type == 0 then
         local m = span:GetControlPointPosition(0)
         spans[#spans + 1] = { type = "arc", x1 = s.x, y1 = s.y, x2 = e.x, y2 = e.y,
                               mx = m.x, my = m.y }
      elseif span.Type == 6 then
         local c1 = span:GetControlPointPosition(0)
         local c2 = span:GetControlPointPosition(1)
         spans[#spans + 1] = { type = "bezier", x1 = s.x, y1 = s.y, x2 = e.x, y2 = e.y,
                               c1x = c1.x, c1y = c1.y, c2x = c2.x, c2y = c2.y }
      end
   end
   return spans
end

-- Selection -> plain span records (pure code does the rest). Groups recursed.
-- Each loop also carries the source OBJECT (so main() can re-select the
-- user's input at the end) and its bbox fingerprint (so the gadget's own
-- offsets can be recognized and dropped from the input — see partition_loops).
function CO.sdk_selection_spans(job)
   local loops, skipped_open = {}, 0
   local function add_object(obj)
      if obj.ClassName == "vcCadObjectGroup" then
         local pos = obj:GetHeadPosition()
         while pos ~= nil do
            local child
            child, pos = obj:GetNext(pos)
            add_object(child)
         end
         return
      end
      if obj.ClassName ~= "vcCadContour" and obj.ClassName ~= "vcCadPolyline" then return end
      local c = obj:GetContour()
      if c == nil or c.IsEmpty then return end
      if c.IsOpen then skipped_open = skipped_open + 1; return end
      local spans = contour_spans(c)
      if #spans > 0 then
         loops[#loops + 1] = { spans = spans, obj = obj, bbox = bbox_fingerprint(obj) }
      end
   end
   local sel = job.Selection
   local pos = sel:GetHeadPosition()
   while pos ~= nil do
      local obj
      obj, pos = sel:GetNext(pos)
      add_object(obj)
   end
   return loops, skipped_open
end

-- True when two bbox fingerprints {cx, cy, xlen, ylen} agree within eps.
-- The SAME underlying object always yields the same bounding box, so a
-- non-match PROVES two wrappers are different objects — the sound direction
-- for partition_loops below. A coincidental match between different objects
-- merely drops a loop from the input (and the summary says so), never deletes
-- anything the wipe would not have deleted anyway.
function CO.same_bbox(a, b, eps)
   return math.abs(a.cx - b.cx) <= eps and math.abs(a.cy - b.cy) <= eps
      and math.abs(a.xlen - b.xlen) <= eps and math.abs(a.ylen - b.ylen) <= eps
end

-- Sort the gadget's own output OUT of the selection instead of refusing the
-- run: box-selecting everything (originals + the orange offsets) is the
-- natural way to re-run, and v1.0.7's refusal there blocked the whole
-- adjust-and-rerun loop (live-hit 2026-07-25). A selected loop whose bbox
-- matches an object on the offset layer IS one of the gadget's own offsets —
-- regenerated every run — so it is dropped as input, not a reason to stop.
-- Matching is by VALUE (bbox fingerprint) because wrapper identity is
-- live-disproven: a wrapper from job.Selection is never == the wrapper for
-- the SAME object iterated from the layer, and obj.LayerName reads nil on
-- Aspire 12.5 (both live-disproven 2026-07-24, see 7c1af84).
-- Returns (kept, skipped, unknown); main() fails closed on unknown > 0.
function CO.partition_loops(loops, layer_fps, eps)
   local kept, skipped, unknown = {}, 0, 0
   for _, loop in ipairs(loops) do
      if loop.bbox == nil then
         unknown = unknown + 1
      else
         local matched = false
         for _, fp in ipairs(layer_fps) do
            if CO.same_bbox(loop.bbox, fp, eps) then matched = true; break end
         end
         if matched then skipped = skipped + 1
         else kept[#kept + 1] = loop end
      end
   end
   return kept, skipped, unknown
end

-- ==================== Selection classification ====================
-- The spec's decision table: what does this selection MEAN? Each selected
-- loop's bbox fingerprint either matches a fingerprint some chamfer
-- remembers (owned) or matches none (free). Free-only means add; owned by
-- exactly one chamfer means rebuild it (a subset still counts -- selection
-- wins); a mix adds the free loops and reports what was excluded; owned by
-- two or more with nothing free is ambiguous and refuses; an empty
-- selection recalls the newest chamfer that remembers anything.

-- Slot whose memory holds this fingerprint, or nil when no chamfer does.
function CO.owner_of(fp, chamfers, eps)
   for _, c in ipairs(chamfers) do
      if c.memory then
         for _, own in ipairs(c.memory.fps) do
            if CO.same_bbox(fp, own, eps) then return c.slot end
         end
      end
   end
   return nil
end

-- sel_fps = selected fingerprints; chamfers ascending by slot (the scan's
-- shape); next_slot = where an add would land; hint_slot = the slot whose
-- toolpath is HIGHLIGHTED in Aspire's toolpath list, or nil. Returns
-- { kind, slot, free_idx (indices into sel_fps to keep), excluded ({slot,
-- count} per owner dropped from an add), owners (ascending slots seen) }.
--
-- The hint is a tie-breaker, never an override (spec 2a): it is consulted
-- ONLY when nothing usable is selected. Selecting shapes is the more
-- deliberate act, so a stale highlight must not silently re-aim a run.
function CO.classify_selection(sel_fps, chamfers, next_slot, eps, hint_slot)
   local free_idx, owned_count, owners = {}, {}, {}
   for i, fp in ipairs(sel_fps) do
      local slot = CO.owner_of(fp, chamfers, eps)
      if slot == nil then
         free_idx[#free_idx + 1] = i
      else
         if owned_count[slot] == nil then owners[#owners + 1] = slot end
         owned_count[slot] = (owned_count[slot] or 0) + 1
      end
   end
   table.sort(owners)
   local excluded = {}
   for _, slot in ipairs(owners) do
      excluded[#excluded + 1] = { slot = slot, count = owned_count[slot] }
   end

   if #sel_fps == 0 then
      -- A highlighted chamfer wins the empty case. If it has no memory there
      -- is nothing to rebuild from and nothing selected to teach it with, so
      -- refuse NAMING it rather than quietly rebuilding one the user did not
      -- point at.
      if hint_slot ~= nil then
         for _, c in ipairs(chamfers) do
            if c.slot == hint_slot then
               if c.memory then
                  return { kind = "recall", slot = c.slot,
                           free_idx = {}, excluded = {}, owners = {} }
               end
               return { kind = "refuse_empty", slot = c.slot,
                        free_idx = {}, excluded = {}, owners = {} }
            end
         end
         -- a highlight naming no chamfer of ours: ignored, not an error
      end
      for i = #chamfers, 1, -1 do   -- backward = newest slot first
         if chamfers[i].memory then
            return { kind = "recall", slot = chamfers[i].slot,
                     free_idx = {}, excluded = {}, owners = {} }
         end
      end
      return { kind = "refuse_empty", free_idx = {}, excluded = {}, owners = {} }
   end
   if #free_idx > 0 then
      return { kind = "add", slot = next_slot,
               free_idx = free_idx, excluded = excluded, owners = owners }
   end
   if #owners == 1 then
      local all = {}
      for i = 1, #sel_fps do all[i] = i end
      return { kind = "rebuild", slot = owners[1],
               free_idx = all, excluded = {}, owners = owners }
   end
   return { kind = "refuse_multi", free_idx = {}, excluded = excluded, owners = owners }
end

-- Dropdown badge for one chamfer against the current selection. nomem has
-- nothing to compare; match needs at least one selected loop and every one
-- remembered by THIS chamfer; anything else differs.
function CO.chamfer_relation(sel_fps, chamfer, eps)
   if chamfer.memory == nil then return "nomem" end
   if #sel_fps == 0 then return "differs" end
   for _, fp in ipairs(sel_fps) do
      local matched = false
      for _, own in ipairs(chamfer.memory.fps) do
         if CO.same_bbox(fp, own, eps) then matched = true; break end
      end
      if not matched then return "differs" end
   end
   return "match"
end

-- Bbox fingerprints of everything on EVERY chamfer layer -- every numbered
-- 'EdgeBreaker - Offset NN' plus the pre-1.4.0 unnumbered one -- not just
-- the layer for the chamfer being built. Groups are recursed and fingerprinted
-- both as themselves and as children, so a selected child can match whichever
-- side of a grouping the offsets ended up on. unknown counts objects whose
-- bbox could not be read — the caller fails closed. The offsets of a chamfer
-- you are not building right now are still the gadget's own output and must
-- never be fed back in as input, or building chamfer 3 on a whole-job
-- selection offsets chamfers 1 and 2's offsets and cuts them.
function CO.sdk_offset_layer_fingerprints(job)
   local fps, unknown = {}, 0
   local function visit(obj)
      local fp = bbox_fingerprint(obj)
      if fp then fps[#fps + 1] = fp else unknown = unknown + 1 end
      if obj.ClassName == "vcCadObjectGroup" then
         local pos = obj:GetHeadPosition()
         while pos ~= nil do
            local child
            child, pos = obj:GetNext(pos)
            visit(child)
         end
      end
   end
   local lpos = job.LayerManager:GetHeadPosition()
   while lpos ~= nil do
      local layer
      layer, lpos = job.LayerManager:GetNext(lpos)
      local ok, name = pcall(function() return layer.Name end)
      if not ok then
         -- Could be one of ours; we cannot tell. Fail closed: main() refuses
         -- when unknown > 0, which is the right answer for a wiped layer.
         unknown = unknown + 1
      elseif CO.slot_from_layer_name(name) ~= nil or name == CO.LEGACY_OFFSET_LAYER then
         local pos = layer:GetHeadPosition()
         while pos ~= nil do
            local obj
            obj, pos = layer:GetNext(pos)
            visit(obj)
         end
      end
   end
   return fps, unknown
end

-- What chamfers does this job already hold? Layers give the offsets, toolpath
-- names give the sizes for the dropdown labels, and a slot counts if EITHER
-- shows it -- a chamfer whose toolpath was deleted by hand must still be
-- selectable, or its orphaned offsets can never be cleaned up.
--
-- Layers are ENUMERATED, never probed with GetLayerWithName: that call creates
-- the layer when it is missing and would litter the job with empty layers on
-- every run.
--
-- Returns an ascending array of { slot, size, origin, memory, tp } plus a
-- legacy flag. v1.4.x chamfers are ADOPTED: they keep their number and are
-- listed with origin = "old", so rebuilding one migrates it to the new names
-- instead of stranding it. They never carry memory -- nothing wrote any.
--
-- Pure core of the clash rule, so it can be tested without a job: a slot
-- claimed under BOTH generations keeps its "new" entry and raises legacy.
-- Adopting both would give one chamfer two layers and two toolpaths.
function CO.merge_scan(new_by_slot, old_slots)
   local merged, legacy = {}, false
   for slot, entry in pairs(new_by_slot) do merged[slot] = entry end
   for slot in pairs(old_slots) do
      if merged[slot] ~= nil then legacy = true
      else merged[slot] = { origin = "old" } end
   end
   return merged, legacy
end

function CO.sdk_scan_chamfers(job)
   local new_by_slot, old_slots, old_sizes, legacy = {}, {}, {}, false
   local pos = job.LayerManager:GetHeadPosition()
   while pos ~= nil do
      local layer
      layer, pos = job.LayerManager:GetNext(pos)
      local name = layer.Name
      local slot = CO.slot_from_layer_name(name)
      local old = CO.old_slot_from_layer_name(name)
      if slot then
         new_by_slot[slot] = new_by_slot[slot] or { origin = "new" }
      elseif old then old_slots[old] = true
      elseif name == CO.LEGACY_OFFSET_LAYER then legacy = true end
   end
   local tpm = ToolpathManager()
   local tpos = tpm:GetHeadPosition()
   while tpos ~= nil do
      local tp
      tp, tpos = tpm:GetNext(tpos)
      local ok, name = pcall(function() return tp.Name end)
      if ok then
         local slot = CO.slot_from_toolpath_name(name)
         local old = CO.old_slot_from_toolpath_name(name)
         if slot then
            local e = new_by_slot[slot] or { origin = "new" }
            e.size = CO.size_text_from_toolpath_name(name)
            e.tp = tp                     -- kept: memory is read from it below
            new_by_slot[slot] = e
         elseif old then
            old_slots[old] = true
            old_sizes[old] = CO.size_text_from_toolpath_name(name)
         elseif type(name) == "string"
                and name:find(CO.LEGACY_TOOLPATH_MARKER, 1, true) ~= nil then
            legacy = true
         end
      end
   end
   local merged, clash = CO.merge_scan(new_by_slot, old_slots)
   if clash then legacy = true end
   local found = {}
   for n = 1, 99 do
      local e = merged[n]
      if e then
         if e.origin == "old" then e.size = old_sizes[n] end
         -- Memory rides on the toolpath, so a chamfer whose toolpath was
         -- deleted by hand is still listed -- just without memory.
         if e.origin == "new" and e.tp ~= nil then
            e.memory = CO.sdk_read_memory(e.tp)
         end
         e.slot = n
         found[#found + 1] = e
      end
   end
   return found, legacy
end

-- ==================== Chamfer memory: the store ====================
-- Toolpath Notes, chosen by live probe 2026-07-26: of every candidate it was
-- the only TOOLPATH-level store whose value survived save -> close -> reopen
-- (job.Notes accepted a write and lost it; JobParameters survived but outlives
-- the toolpath, which is the wrong lifecycle -- deleting a chamfer must forget
-- it). Both halves are best-effort: memory is a convenience, and no failure
-- here may ever block or fail a run.
function CO.sdk_read_memory(tp)
   local ok, text = pcall(function() return tp.Notes end)
   if not ok or type(text) ~= "string" then return nil end
   return CO.decode_memory(text)
end

function CO.sdk_write_memory(tp, mem)
   local ok = pcall(function()
      local existing = tp.Notes
      if type(existing) ~= "string" then existing = "" end
      tp.Notes = CO.embed_memory(existing, mem)
      ToolpathManager():ToolpathModified(tp)   -- required for a Notes write to take
   end)
   return ok == true
end

-- Which chamfer's toolpath is HIGHLIGHTED in Aspire's toolpath list, if any?
-- Live-proven 2026-07-26 in a two-chamfer job, both directions: clicking 01
-- returned 01 and clicking 02 returned 02, which is what rules out the call
-- merely reporting the first or last toolpath. Reads either name generation,
-- so highlighting an adopted v1.4.x chamfer works too. nil for "nothing
-- highlighted", "not one of ours", or any failure -- it is only ever a
-- tie-breaker, so being wrong here must cost nothing.
function CO.sdk_selected_slot()
   local ok, name = pcall(function()
      local tp = ToolpathManager():GetSelectedToolpath()
      if tp == nil then return nil end
      return tp.Name
   end)
   if not ok or type(name) ~= "string" then return nil end
   return CO.slot_from_toolpath_name(name) or CO.old_slot_from_toolpath_name(name)
end

-- Find the job objects a chamfer remembers, so main() can tell "rebuild what
-- is still there" from "these shapes are gone". Our own offset layers are
-- skipped under BOTH name generations: an offset ring can share a bbox with
-- nothing but itself, but a remembered shape must never resolve to the copy
-- we drew from it. Groups recurse exactly as sdk_offset_layer_fingerprints.
function CO.sdk_find_objects_by_fps(job, fps, eps)
   local objs, seen = {}, {}
   local function visit(obj)
      local fp = bbox_fingerprint(obj)
      if fp then
         for i, want in ipairs(fps) do
            if not seen[i] and CO.same_bbox(fp, want, eps) then
               seen[i] = true; objs[#objs + 1] = obj; break
            end
         end
      end
      if obj.ClassName == "vcCadObjectGroup" then
         local pos = obj:GetHeadPosition()
         while pos ~= nil do
            local child
            child, pos = obj:GetNext(pos)
            visit(child)
         end
      end
   end
   local pos = job.LayerManager:GetHeadPosition()
   while pos ~= nil do
      local layer
      layer, pos = job.LayerManager:GetNext(pos)
      local name = layer.Name
      local ours = CO.slot_from_layer_name(name) ~= nil
                or CO.old_slot_from_layer_name(name) ~= nil
                or name == CO.LEGACY_OFFSET_LAYER
      if not ours then
         local lpos = layer:GetHeadPosition()
         while lpos ~= nil do
            local obj
            obj, lpos = layer:GetNext(lpos)
            visit(obj)
         end
      end
   end
   local found = 0
   for _ in pairs(seen) do found = found + 1 end
   return { objs = objs, found = found, missing = #fps - found }
end

-- Get-or-create THIS chamfer's output layer and clear stale offsets from its
-- previous run. Wiping is safe because partition_loops has already dropped
-- anything selected on this layer from the input, and the layer is documented
-- as gadget-owned (wiped every run) — nothing durable belongs here. Other
-- chamfers' layers are never touched.
--
-- migrate (v1.5.0) additionally clears the SAME slot's v1.4.x layer, for the
-- first rebuild of an adopted chamfer: without it the job keeps two sets of
-- offsets under one number — the stale one still drawn, no longer cut, and
-- indistinguishable by eye from the live one. It is a flag rather than
-- automatic because a slot that exists under BOTH names is a clash the scan
-- reports (merge_scan), not a licence to delete. The old layer is found by
-- ENUMERATION: GetLayerWithName would create the very layer we came to remove.
function CO.sdk_prepare_layer(job, slot, migrate)
   local old_left = false
   if migrate then
      local old = nil
      local lpos = job.LayerManager:GetHeadPosition()
      while lpos ~= nil and old == nil do
         local layer
         layer, lpos = job.LayerManager:GetNext(lpos)
         local ok, name = pcall(function() return layer.Name end)
         if ok and CO.old_slot_from_layer_name(name) == slot then old = layer end
      end
      if old ~= nil then
         local doomed = {}
         local pos = old:GetHeadPosition()
         while pos ~= nil do
            local obj
            obj, pos = old:GetNext(pos)
            doomed[#doomed + 1] = obj
         end
         for _, obj in ipairs(doomed) do old:RemoveObject(obj) end
         -- RemoveLayer is documented but has never been run here, so the
         -- emptied layer is the guaranteed part and its disappearance is not.
         old_left = not pcall(function() job.LayerManager:RemoveLayer(old) end)
      end
   end
   local layer = job.LayerManager:GetLayerWithName(CO.offset_layer_name(slot))
   local doomed = {}
   local pos = layer:GetHeadPosition()
   while pos ~= nil do
      local obj
      obj, pos = layer:GetNext(pos)
      doomed[#doomed + 1] = obj
   end
   for _, obj in ipairs(doomed) do layer:RemoveObject(obj) end
   -- Orange, not magenta: Vectric highlights selected vectors and toolpaths in
   -- magenta, so an offset drawn in it competes with Aspire's own UI state and
   -- "check the offsets before you cut" gets harder to do (live 2026-07-26).
   -- Blue and cyan were tried and rejected: blue reads as black at thin line
   -- widths, cyan washes out on the white background.
   layer:SetColour(0x008CFF)   -- orange (BGR)
   return layer, old_left
end

-- Creating/drawing onto an 'EdgeBreaker - Offset NN' layer leaves it as Aspire's ACTIVE
-- layer (live-observed 2026-07-23): every vector the user draws afterward
-- silently lands on the wipe target, and the guard then refuses the next run.
-- Capture the active layer's name before we touch layers; put it back at the
-- end. Restore only a real, different name - nil/empty means the capture
-- failed, and our own layer means there is nothing worth restoring.
function CO.should_restore_layer(name)
   if type(name) ~= "string" or name == "" then return false end
   if name == CO.LEGACY_OFFSET_LAYER then return false end
   return CO.slot_from_layer_name(name) == nil
end

-- Aspire 12.5 gives no way to READ the active layer -- GetActiveLayerName is not
-- in the SDK reference and returned nil every time live (2026-07-27) -- so a run
-- cannot put back the exact layer it found. It can still refuse to leave one of
-- OURS active, which is the part that costs the user work: offset layers are
-- wiped on every run, and Aspire puts new drawing onto whatever is active,
-- including Convert Text to Curves output. Live-hit three times in one sitting:
-- a square and a text object both landed on 'EdgeBreaker - Offset NN' and were
-- then invisible to the gadget (its own guard skipped them).
--
-- So: walk the layers and activate the first one that is not ours. Fails soft --
-- a job with no user layer at all leaves the active layer alone, i.e. today's
-- behavior, which is the worst case rather than an error.
function CO.sdk_leave_user_layer(job)
   return (pcall(function()
      local lm = job.LayerManager
      local pos = lm:GetHeadPosition()
      while pos do
         local layer
         layer, pos = lm:GetNext(pos)
         if layer and CO.should_restore_layer(layer.Name) then
            lm:SetActiveLayer(layer)
            return
         end
      end
   end))
end

-- One loop, offset by Aspire's own engine instead of ours (v1.3.0).
--
-- Selection surgery is the route with no unproven SDK step: select exactly this
-- one vector, take a ContourGroup copy of it, offset the copy. Walking the
-- selection into a fresh ContourGroup raises an ownership question no shipped
-- gadget answers, and splitting one big group needs group iteration nothing
-- attests. The gadget already does selection surgery a few lines below in main().
--
-- Aspire does the self-intersection cleanup ours never had, so ONE input loop can
-- come back as SEVERAL output loops (live: 8 in -> 15 out inward) -- and a feature
-- narrower than the offset comes back as NONE. An empty result is the "too narrow
-- to chamfer at this size" answer, not a failure: that is exactly the case where
-- our own offset returned an inside-out loop and quietly cut a full-depth slot.
--
-- Only the 4-argument form of :Offset binds; the other arities raise "No matching
-- overload found" (live-proven 2026-07-25). Negative distance is inward.
--
-- Returns  group        on success
--          nil          too narrow -- skip it and count it
--          nil, err     an SDK call failed -- the caller stops
--
-- Leaves obj as the only selected object. main() MUST clear the selection before
-- doing anything else with it.
function CO.sdk_offset_loop(job, obj, dist)
   local ok, res, err = pcall(function()
      job.Selection:Clear()
      job.Selection:Add(obj, true, true)
      -- sdk_selection_spans recurses into groups, so obj can be a CHILD living
      -- inside a group the user selected -- whether Add(child) even takes on
      -- Aspire 12.5 is unattested here (shipped gadgets treat the group as the
      -- selectable unit). Both failure directions are silent: a no-op Add
      -- leaves the selection empty, which would misreport downstream as "too
      -- narrow to chamfer" with no way for the user to see the real cause; a
      -- promotion to the parent group would instead sweep every sibling into
      -- the copy and offset them all as one. Count ~= 1 catches both before
      -- either can masquerade as a normal result.
      if job.Selection.Count ~= 1 then
         return nil, "could not select this vector on its own (is it inside a group? ungroup and retry)"
      end
      -- smash_beziers/smash_arcs false: preserve_arcs below is pointless if the
      -- copy has already been reduced to line segments.
      local src = CreateCopyOfSelectedContours(false, false, 0.01)
      -- Live 2026-07-26: on a grouped child the Count guard above does NOT
      -- fire -- Selection:Add(child) works and reports exactly 1 -- and it is
      -- the COPY that refuses. So the "ungroup and retry" hint belongs here
      -- too, or the user gets a symptom with no cause and no fix.
      if src == nil then
         return nil, "could not copy the selected vector (is it inside a group? ungroup and retry)"
      end
      local g = src:Offset(dist, math.abs(dist), 1, true)
      if g == nil then return nil end
      -- A zero count is the "too narrow" answer; an unreadable one is a wrong
      -- property name (luabind returns nil rather than raising) -- reporting
      -- that as a geometry problem would send the next reader at the chamfer
      -- size instead of the property name.
      local n = g.Count
      if type(n) ~= "number" then
         return nil, "could not read the offset result (Count)"
      end
      if n < 1 then return nil end
      return g
   end)
   if not ok then return nil, tostring(res) end
   return res, err
end

-- Draw a returned offset group. CreateCadGroup + layer:AddObject is the attested
-- group draw path (Celtic_Weave_Creator.lua:515/521). AddObject's bool does NOT
-- select. The shipped template is layer-restricted (README.md), but this guards
-- the case of a hand-re-created, UNRESTRICTED one: that kind attaches to the
-- SELECTION at load time (live-proven 2026-07-24 -- the toolpath grabbed the
-- original vector), so main() must Selection:Add what this returns before
-- loading the template no matter which kind is on disk.
function CO.sdk_draw_group(layer, group)
   local cad = CreateCadGroup(group)
   layer:AddObject(cad, true)
   return cad
end

-- Pull the numbers the chamfer math needs off a picked tool, converting the
-- diameter if the bit and the job disagree about units. Every read is guarded:
-- these property names are live-proven, but a nil here must produce an
-- explanation rather than an arithmetic error deep in the geometry.
function CO.sdk_tool_geometry(tool, job_in_mm)
   local function get(name)
      local ok, v = pcall(function() return tool[name] end)
      if not ok then return nil end
      return v
   end
   local angle = get("VBit_Angle")
   local raw_dia = get("ToolDia")
   local dia = CO.length_in_job_units(raw_dia, get("InMM") and true or false,
                                      job_in_mm and true or false)
   local ok, err = CO.check_tool_geometry(angle, dia)
   if not ok then return nil, err end
   local name = get("Name")
   return { angle = angle, diameter = dia,
            name = (type(name) == "string" and name ~= "") and name or "the selected bit" }
end

-- Stock thickness, for the depth warning only. MaterialBlock() is how Vectric's
-- own gadgets read job setup -- Setup_Sheet, Dragknife_Toolpath and
-- Create_Rounding_Toolpath all use it, which is the strongest evidence tier
-- available. Every read is guarded and every failure returns nil, because nil
-- means "say nothing": a warning that fires on job setup nobody filled in would
-- just train the user to ignore it.
function CO.sdk_material_thickness(job_in_mm)
   local ok, mb = pcall(function() return MaterialBlock() end)
   if not ok or mb == nil then return nil end
   local function get(name)
      local got, v = pcall(function() return mb[name] end)
      if not got then return nil end
      return v
   end
   return CO.length_in_job_units(get("Thickness"), get("InMM") and true or false,
                                 job_in_mm and true or false)
end

-- Fallback rule when the per-toolpath recalc is unavailable: recalc-all only
-- when the job had no toolpaths before we loaded, so work that is not ours is
-- never recomputed behind the user's back.
function CO.should_recalc_all(count_before)
   return count_before == 0
end

-- Delete every toolpath carrying THIS slot's ownership marker. Collect first,
-- delete after — never delete while iterating (same doomed[] pattern as
-- sdk_prepare_layer). DeleteToolpath(tp) with an OBJECT argument is
-- live-proven on Aspire 12.5 (mastercam-tooling session 054 probe); an
-- unreadable Name just means that toolpath is left alone, and so does one
-- marked for a different slot. A non-number slot raises rather than matching
-- anything.
-- include_old (v1.5.0) additionally takes the same slot's v1.4.x-marked
-- toolpath, the toolpath half of sdk_prepare_layer's migration and gated the
-- same way: one chamfer must not end up with a toolpath under each generation.
function CO.sdk_delete_marked_toolpaths(slot, include_old)
   -- A nil slot would make the ownership test below read `nil == nil`, which is
   -- TRUE for every unmarked and every pre-1.4.0 toolpath -- exactly the ones
   -- the gadget must never delete. Fail loudly instead, the way
   -- sdk_prepare_layer already does when its slot is nil.
   if type(slot) ~= "number" then
      error("sdk_delete_marked_toolpaths: slot must be a number, got " .. type(slot))
   end
   local tpm = ToolpathManager()
   local doomed = {}
   local pos = tpm:GetHeadPosition()
   while pos ~= nil do
      local tp
      tp, pos = tpm:GetNext(pos)
      local ok, name = pcall(function() return tp.Name end)
      local mine = ok and (CO.slot_from_toolpath_name(name) == slot
                           or (include_old and CO.old_slot_from_toolpath_name(name) == slot))
      if mine then doomed[#doomed + 1] = tp end
   end
   local deleted, failed = 0, 0
   for _, tp in ipairs(doomed) do
      if pcall(function() tpm:DeleteToolpath(tp) end) then deleted = deleted + 1
      else failed = failed + 1 end
   end
   return deleted, failed
end

-- The toolpath this slot's marker names, re-read from the manager. The wrapper
-- sdk_apply_template held is stale once RecalculateToolpath has run (Aspire
-- recreates the toolpath), so the run's memory is written to a freshly found
-- one instead of to a dead handle. nil when nothing carries the marker --
-- which is also what a failed rename looks like, and is why the caller falls
-- back rather than reporting a problem.
function CO.sdk_find_toolpath_by_slot(slot)
   local ok, found = pcall(function()
      local tpm = ToolpathManager()
      local pos = tpm:GetHeadPosition()
      while pos ~= nil do
         local tp
         tp, pos = tpm:GetNext(pos)
         local okn, name = pcall(function() return tp.Name end)
         if okn and CO.slot_from_toolpath_name(name) == slot then return tp end
      end
      return nil
   end)
   if ok then return found end
   return nil
end

-- Read template -> patch depth -> patch layer -> temp copy -> load -> tag +
-- recalc ours.
-- The template is saved targeting slot 1's layer by name; the layer patch
-- re-aims it at THIS chamfer's layer and the result is read back before Aspire
-- ever sees it. Each toolpath the load created is renamed to new_name (the
-- marker the next run's delete pass keys on) and recalculated
-- INDIVIDUALLY. Rename
-- (.Name= + ToolpathModified) and RecalculateToolpath are in 12.5's binding
-- table and in Vectric's own Apply_Template_To_All_Sheets sample, but are not
-- yet live-proven here, so both fail soft:
--   rename fails -> no marker -> next run cannot auto-replace (pre-1.0.7)
--   recalc fails -> old rule: recalc-all only when the job had no toolpaths
-- Success returns a table { n, renamed, status = "calculated" | "loaded" };
-- failure returns nil, err.
function CO.sdk_apply_template(dir, filename, depth, start, slot, new_name, tool)
   local src = dir .. "\\" .. filename
   local f = io.open(src, "rb")
   if f == nil then return nil, "cannot read template: " .. src end
   local bytes = f:read("*a"); f:close()
   local patched, perr = CO.patch_template_depth(bytes, depth)
   if patched == nil then return nil, perr .. " (" .. filename .. ")" end
   local serr
   patched, serr = CO.patch_template_start_depth(patched, start or 0)
   if patched == nil then return nil, serr .. " (" .. filename .. ")" end
   local lerr
   patched, lerr = CO.patch_template_layer(patched, slot)
   if patched == nil then return nil, lerr .. " (" .. filename .. ")" end
   -- Read the restriction back out of the bytes we are about to hand Aspire.
   -- A template aimed at the wrong layer cuts the wrong vectors at the wrong
   -- depth without complaining, so this is checked, never assumed.
   local want = CO.offset_layer_name(slot)
   local back = CO.read_template_layers(patched)
   if back == nil or #back ~= 1 or back[1] ~= want then
      return nil, "patched template does not target '" .. want .. "' - nothing was loaded"
   end
   local tmp = dir .. "\\_EdgeBreaker_patched.ToolpathTemplate"
   local o = io.open(tmp, "wb")
   if o == nil then return nil, "cannot write temp template: " .. tmp end
   o:write(patched); o:close()
   local tpm = ToolpathManager()
   local before = tpm.Count
   tpm:LoadToolpathTemplate(tmp)
   pcall(os.remove, tmp)                 -- best-effort cleanup; a leftover is harmless
   if tpm.Count <= before then
      return nil, "Aspire did not load the patched template (Count unchanged)"
   end
   -- The new toolpaths are the TAIL of the list (Vectric's sample gadget
   -- relies on the same append order after LoadToolpathTemplate).
   local news, idx = {}, 0
   local pos = tpm:GetHeadPosition()
   while pos ~= nil do
      local tp
      tp, pos = tpm:GetNext(pos)
      idx = idx + 1
      if idx > before then news[#news + 1] = tp end
   end
   -- Swap in the bit the user picked, so the template no longer decides which
   -- tool cuts. The tool brings its own feeds, speeds, stepdown and tool NUMBER
   -- (live-proven 2026-07-25: 90 deg/T9/20ipm became 30 deg/T1/60ipm), which is
   -- why the template only has to carry the strategy. Both this and the rename
   -- must happen BEFORE any recalc, which recreates the toolpath and
   -- invalidates the wrapper we hold. Fails soft: the template's own bit stays.
   local retooled = true
   if tool ~= nil then
      for _, tp in ipairs(news) do
         local ok = pcall(function() tp:ReplaceTool(tool); tpm:ToolpathModified(tp) end)
         if not ok then retooled = false end
      end
   end
   local renamed = true
   for _, tp in ipairs(news) do
      local ok = pcall(function() tp.Name = new_name; tpm:ToolpathModified(tp) end)
      local okr, back = pcall(function() return tp.Name end)
      if not (ok and okr and back == new_name) then renamed = false end
   end
   local calced = true
   for _, tp in ipairs(news) do
      local ok, res = pcall(function() return tpm:RecalculateToolpath(tp) end)
      -- tp must not be touched past this line (recreated on success)
      if not (ok and res == true) then calced = false end
   end
   if not calced and CO.should_recalc_all(before) then
      tpm:RecalculateAllToolpaths()
      calced = true
   end
   -- tp is the wrapper the run's memory is written to. On the recalc path it
   -- may already be stale (RecalculateToolpath recreates the toolpath), so the
   -- caller re-finds it by name rather than trusting this one.
   return { n = #news, renamed = renamed, retooled = retooled, tp = news[1],
            status = calced and "calculated" or "loaded" }
end

-- Whether THIS run's job is in millimetres. The picker callback is a global
-- Aspire calls with no access to main()'s locals, and the diameter it reports
-- has to be converted the same way the seeded one was. A local, not a global:
-- the test harness stubs `strict`, so a stray global would be a silent liberty
-- rather than a caught one.
local job_is_mm = false

-- Aspire calls this the moment a bit is chosen, and hands over the dialog that
-- is STILL OPEN (live-proven 2026-07-28; Vectric's own Dragknife_Toolpath does
-- the same). It reports and nothing else -- no validation, no saving, no
-- refusing -- because a callback that only reports cannot break a run. The
-- real check happens on OK, where the cut is built.
function OnToolPicker_ToolChooseButton(dialog)
   local ok_get, tool = pcall(function() return dialog:GetTool("ToolChooseButton") end)
   if ok_get and tool ~= nil then
      local geom = CO.sdk_tool_geometry(tool, job_is_mm)
      if geom ~= nil then
         -- ASCII, numbers only, fixed format: no exponent for Trident's
         -- parseFloat to trip over, and no character the operator ever sees.
         pcall(function()
            dialog:UpdateLabelField("BitGeom",
               string.format("%.6f|%.6f", geom.angle, geom.diameter))
         end)
      end
   end
   return true
end

function main(script_path)
   local job = VectricJob()
   if not job.Exists then
      DisplayMessageBox("No job is open.\n\nOpen your job, select the edge vectors, then re-run EdgeBreaker.")
      return false
   end

   local gadget_dir = resolve_gadget_dir(script_path)
   if gadget_dir == nil then
      DisplayMessageBox("Cannot find EdgeBreakerDialog.htm under:\n" .. script_path ..
         "\n\nRe-run sync-gadgets.bat and restart Aspire.")
      return false
   end

   local is_mm = job.InMM
   if is_mm == nil then
      DisplayMessageBox("EdgeBreaker couldn't determine whether this job uses mm or inches, "
         .. "so it can't safely continue. Please report this message.")
      return false
   end
   local unit = CO.unit_info(is_mm)

   -- Which chamfers does this job already hold? Read BEFORE the bit picker so a
   -- job we cannot read refuses without making the user choose a bit first.
   -- Fail closed: the dropdown and the own-offsets guard share this scan, and a
   -- half-read job would offer a chamfer list that quietly omits one.
   local ok_scan, chamfers, legacy = pcall(CO.sdk_scan_chamfers, job)
   if not ok_scan then
      DisplayMessageBox("EdgeBreaker could not read this job's layers and toolpaths, so it "
         .. "can't tell which chamfers already exist.\n\nNothing was changed. "
         .. "Please report this message.")
      return false
   end
   if legacy then
      DisplayMessageBox("This job contains a chamfer made by an older version of ChamferOffset "
         .. "(layer '" .. CO.LEGACY_OFFSET_LAYER .. "', or a toolpath named '"
         .. CO.LEGACY_TOOLPATH_MARKER .. "').\n\nIt is not tracked: it won't be listed, "
         .. "replaced or deleted. Remove it by hand if you don't want it.")
   end
   local used, by_slot = {}, {}
   for _, c in ipairs(chamfers) do used[#used + 1] = c.slot; by_slot[c.slot] = c end
   local next_slot = CO.next_free_slot(used)

   -- v1.5.0: THE SELECTION DECIDES. Everything from here to the bit picker
   -- answers one question — what does this run mean? — because the answer sets
   -- which chamfer is built, which settings seed the dialog and which bit the
   -- picker opens on. It has to happen before the picker for that last reason
   -- (spec 4, "order unchanged"), and the two refusals it can reach are worth
   -- reaching before the user is made to choose a bit.
   local raw_loops, skipped_open = CO.sdk_selection_spans(job)
   -- Drop the gadget's own offsets from the input instead of refusing:
   -- box-selecting originals + orange offsets together is the natural way
   -- to re-run (live-hit 2026-07-25).
   local ok_guard, layer_fps, layer_unknown = pcall(CO.sdk_offset_layer_fingerprints, job)
   if not ok_guard then
      DisplayMessageBox("EdgeBreaker could not examine its working layers ('"
         .. CO.OFFSET_LAYER_PREFIX .. "NN'):\n" .. tostring(layer_fps)
         .. "\n\nNothing was changed. Please report this message.")
      return false
   end
   local kept, skipped_own, bbox_unknown = CO.partition_loops(raw_loops, layer_fps, 1e-6)
   if layer_unknown > 0 or bbox_unknown > 0 then
      DisplayMessageBox(string.format("EdgeBreaker couldn't compare %d vector(s) against its "
         .. "own offset layers ('%sNN'), so it can't safely continue (those layers are wiped "
         .. "on every run).\n\nNothing was changed. Please report this message.",
         layer_unknown + bbox_unknown, CO.OFFSET_LAYER_PREFIX))
      return false
   end
   -- Selecting only open vectors is a mistake with an obvious fix, not the
   -- empty selection that means "rebuild the last chamfer" — so it keeps its
   -- own refusal rather than falling through to recall.
   if #kept == 0 and skipped_open > 0 then
      DisplayMessageBox("Only open vectors were selected, and a chamfer needs closed ones.\n\n"
         .. "Close them (or select closed vectors) and run EdgeBreaker again.\n\nNothing was changed.")
      return false
   end
   local sel_fps = {}
   for i, loop in ipairs(kept) do sel_fps[i] = loop.bbox end

   -- Which remembered shapes are still in this job? A chamfer whose shapes have
   -- all been moved, edited or deleted cannot be rebuilt FROM memory, so for
   -- every decision below it counts as memory-less: it is offered as the amber
   -- "teach me" state instead of silently rebuilding nothing. (It can never own
   -- a SELECTED shape either — a selected shape is by definition still in the
   -- job — so hiding its memory here cannot change who owns what.)
   for _, c in ipairs(chamfers) do
      if c.memory then
         local ok_find, res = pcall(CO.sdk_find_objects_by_fps, job, c.memory.fps, 1e-6)
         if ok_find then
            c.resolved = res
            c.missing_all = (res.found == 0)
         end
      end
   end
   local for_classify = {}
   for _, c in ipairs(chamfers) do
      if c.missing_all then
         for_classify[#for_classify + 1] = { slot = c.slot, origin = c.origin, size = c.size }
      else
         for_classify[#for_classify + 1] = c
      end
   end

   local cls = CO.classify_selection(sel_fps, for_classify, next_slot, 1e-6,
                                     CO.sdk_selected_slot())
   if cls.kind == "refuse_multi" then
      local owners = {}
      for _, e in ipairs(cls.excluded) do owners[#owners + 1] = e.slot end
      DisplayMessageBox("The selected shapes belong to " .. CO.name_slots(owners)
         .. ", so EdgeBreaker can't tell which one you mean.\n\n"
         .. "Select one chamfer's shapes to rebuild that chamfer, or shapes no chamfer "
         .. "uses to add a new one.\n\nNothing was changed.")
      return false
   end
   if cls.kind == "refuse_empty" then
      if cls.slot ~= nil then
         DisplayMessageBox("Chamfer " .. cls.slot .. " doesn't remember which shapes it was "
            .. "built from - it was made before EdgeBreaker started remembering, or its "
            .. "shapes have been moved or edited.\n\nSelect the shapes it should cut and run "
            .. "again: that run teaches it.\n\nNothing was changed.")
         return false
      end
      local stale = {}
      for _, c in ipairs(chamfers) do
         if c.missing_all then stale[#stale + 1] = c.slot end
      end
      DisplayMessageBox("Select the closed vectors to chamfer, then re-run EdgeBreaker.\n\n"
         .. "To rebuild a chamfer you already have, select its shapes - or click its toolpath "
         .. "in the Toolpaths list first and run with nothing selected."
         .. (#stale > 0 and ("\n\n" .. CO.name_slots(stale)
             .. " remembers shapes that are no longer in the job.") or ""))
      return false
   end

   -- Which remembered bit this run opens on: the bit THIS chamfer was built
   -- with when we know it (spec 4 seeding), otherwise the global last-used.
   local target = by_slot[cls.slot]
   local tool_key = ""
   if target and target.memory and target.memory.tool and target.memory.tool ~= "" then
      tool_key = CO.tool_defaults_key(cls.slot)
   end

   -- The single strategy template. Its bit is irrelevant now (ReplaceTool swaps
   -- in the picked one), so only the strategy is checked.
   local template_ok, template_err = nil, nil
   local tbytes = nil
   local tf = io.open(gadget_dir .. "\\" .. CO.TEMPLATE_NAME, "rb")
   if tf then tbytes = tf:read("*a"); tf:close() end
   template_ok, template_err = CO.validate_template(tbytes, unit.suffix)

   -- A chamfer we are rebuilding seeds the dialog with ITS OWN settings, not
   -- with whatever was typed last: "adjust chamfer 2" should open showing
   -- chamfer 2. Everything else reopens with last run's entries, each one
   -- dropped if it no longer fits this job (see CO.apply_settings) -- and a
   -- remembered setting goes through exactly the same validation, so a blob
   -- from another job's units cannot seed a nonsense size.
   local seed
   if target and target.memory then
      seed = CO.apply_settings(target.memory, unit)
   else
      seed = CO.apply_settings(CO.load_settings(), unit)
   end

   -- First arg is local_html, NOT modal: false is required with a file: URL
   -- (Aspire renders the URL as text otherwise) — same as Inlay Doctor's dialogs.
   -- Physical pixels, NOT scaled by Windows DPI — the stylesheet is px-only for
   -- exactly that reason, so the dialog is the same block of pixels on every
   -- machine. That makes the size a per-screen choice: see CO.dialog_size.
   local win_w, win_h = CO.dialog_size(os.getenv("COMPUTERNAME"))
   local dlg = HTML_Dialog(false, "file:" .. gadget_dir .. "\\EdgeBreakerDialog.htm",
                           win_w, win_h, "EdgeBreaker v" .. CO.VERSION)

   job_is_mm = is_mm and true or false

   -- The bit this run should open on: this chamfer's own bit when it has one,
   -- otherwise the global last-used. Unchanged from v1.5.0 -- only where it is
   -- consumed has moved.
   local remembered = nil
   pcall(function()
      remembered = ToolDBId()
      remembered:LoadDefaults(CO.TOOL_SECTION, tool_key)
   end)
   -- Declared EMPTY on purpose. Aspire owns this label from AddToolPicker on,
   -- and the page owns the empty-state word in its own #BitBadgeNone span, so
   -- seeding any text here is a second writer of the same words: with nothing
   -- remembered both land and the badge reads "No bit yetNo bit yet" (seen in
   -- Aspire, 2026-07-28). Nothing offline can catch it -- the layout gate never
   -- runs the Lua -- so the two writers must simply stay apart.
   dlg:AddLabelField("BitBadgeName", "")
   dlg:AddLabelField("BitGeom", "")
   local ok_add = pcall(function()
      dlg:AddToolPicker("ToolChooseButton", "BitBadgeName", remembered or ToolDBId())
   end)
   if not ok_add then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Nothing was changed",
         body = "EdgeBreaker couldn't open Aspire's tool picker, so it can't "
             .. "ask which bit to use.\n\nPlease report this message.",
         plain = "EdgeBreaker couldn't open Aspire's tool picker, so it can't "
             .. "ask which bit to use.\n\nNothing was changed. Please report this message.",
      })
      return false
   end
   -- Without the filter the picker lists drills and end mills too; losing it is
   -- untidy but not dangerous, since the chosen tool is re-checked after OK.
   pcall(function() dlg:AddToolPickerValidToolType("ToolChooseButton", Tool.VBIT) end)

   -- Read the seeded bit back off a dialog that has not been shown. This is the
   -- ONLY route to a remembered bit's geometry: ToolDatabase:GetTool returns nil
   -- for every id LoadDefaults produces (probe run 2, 2026-07-28). Nil here is
   -- not an error -- it is a machine that has never picked a bit.
   local seed_geom = nil
   pcall(function()
      local t = dlg:GetTool("ToolChooseButton")
      if t ~= nil then seed_geom = CO.sdk_tool_geometry(t, is_mm) end
   end)

   dlg:AddTextField("Units", unit.suffix)
   -- The chart and presets are driven by these two. Text, not double, because
   -- AddDoubleField has no way to express "no bit yet" -- the same reason
   -- Thickness is already text.
   dlg:AddTextField("ToolAngle", seed_geom and tostring(seed_geom.angle) or "")
   dlg:AddTextField("ToolDiameter", seed_geom and tostring(seed_geom.diameter) or "")
   dlg:AddTextField("BitName", seed_geom and seed_geom.name or "")
   -- Advisory only: "" means the job did not tell us, and the dialog then says
   -- nothing about depth. Text rather than double, because AddDoubleField has
   -- no way to express "unknown".
   local thickness = CO.sdk_material_thickness(is_mm)
   dlg:AddTextField("Thickness", thickness and tostring(thickness) or "")
   dlg:AddTextField("HiddenNote", template_ok and "" or template_err)
   dlg:AddTextField("Mode", seed.mode)
   dlg:AddTextField("Side", seed.side)
   dlg:AddDoubleField("Percent", seed.percent)
   dlg:AddDoubleField("Size", seed.size)
   dlg:AddDoubleField("StartDepth", seed.start)
   dlg:AddTextField("Chamfers", CO.encode_chamfer_list(chamfers, next_slot, sel_fps, 1e-6))
   -- What the selection means, and the counts the banner quotes. Slot and Kind
   -- are what the dialog OPENS on; the user can change either, and KindOut
   -- reads back the state that was actually on screen when OK was pressed.
   dlg:AddTextField("Slot", tostring(cls.slot))
   dlg:AddTextField("Kind", cls.kind)
   dlg:AddTextField("KindOut", cls.kind)
   dlg:AddTextField("BannerFacts", CO.encode_banner_facts(cls, #sel_fps,
      (target and target.memory) and #target.memory.fps or 0))

   if not dlg:ShowDialog() then return false end   -- user cancelled

   -- The cut is built from the bit the picker is holding when OK is pressed,
   -- never from whatever the preview happened to draw. Same sequence main() has
   -- always run; only the dialog it reads from has changed.
   local ok_tool, tool = pcall(function() return dlg:GetTool("ToolChooseButton") end)
   if not ok_tool or tool == nil then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Nothing was changed",
         body = "Pick a bit first - the Choose bit button is at the top right."
             .. "\n\nIf Aspire's Select button stayed GREYED with a bit highlighted, that "
             .. "bit has no feeds and speeds for the machine shown at the top of that "
             .. "dialog. Press Copy under 'Copy Settings From', then Apply.",
         plain = "Pick a bit first - the Choose bit button is at the top right."
             .. "\n\nNothing was changed.\n\n"
             .. "If Aspire's Select button stayed GREYED with a bit highlighted, that bit has "
             .. "no feeds and speeds for the machine shown at the top of that dialog. Press "
             .. "Copy under 'Copy Settings From', then Apply.",
      })
      return false
   end
   local geom, gerr = CO.sdk_tool_geometry(tool, is_mm)
   if geom == nil then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "That bit can't be used",
         body = gerr,
         plain = gerr .. "\n\nNothing was changed.",
      })
      return false
   end
   -- Remember this bit for next run. On the OK path on purpose: the global
   -- last-used bit used to be written the instant the separate picker dialog
   -- was OK'd, so a run cancelled at the setup dialog still changed remembered
   -- state. It cannot now.
   pcall(function() tool.ToolDBId:SaveDefaults(CO.TOOL_SECTION, "") end)

   local mode    = dlg:GetTextField("Mode")
   local side    = dlg:GetTextField("Side")
   local size    = dlg:GetDoubleField("Size")
   local percent = dlg:GetDoubleField("Percent")
   local angle   = geom.angle
   local dia     = geom.diameter

   -- The state the dialog was showing when OK was pressed (the user may have
   -- changed chamfer since it opened). Read nil-tolerantly: a dialog file that
   -- never sets it must degrade to the inferred state, never break the run.
   local kind_out = cls.kind
   local ok_kind, kind_read = pcall(function() return dlg:GetTextField("KindOut") end)
   if ok_kind and type(kind_read) == "string" and kind_read ~= "" then kind_out = kind_read end

   -- The dialog hands back a slot number and nothing else: replacing a slot
   -- that does not exist yet IS creating it, so "new" needs no separate case.
   local slot = tonumber(dlg:GetTextField("Slot"))
   if slot == nil or slot % 1 ~= 0 or slot < 1 or slot > 99 then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Nothing was changed",
         body = "EdgeBreaker couldn't read which chamfer you chose. Please report this message.",
         plain = "EdgeBreaker could not read which chamfer you chose.\n\n"
             .. "Nothing was changed. Please report this message.",
      })
      return false
   end

   -- GetDoubleField's return type is undocumented; tonumber accepts a numeric
   -- string too, so a string-typed SDK return can't refuse every run.
   size = tonumber(size)
   if size == nil or size <= 0 then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Chamfer size must be a positive number",
         plain = "Chamfer size must be a positive number.",
      })
      return false
   end

   -- Start depth: how far below the top of the stock the edge sits. Zero is
   -- both the safe value and the common one, so a blank field means 0 (the
   -- dialog normalises it before OK) -- but a value we cannot read at all is
   -- refused rather than silently treated as zero, which would cut a recessed
   -- chamfer at the wrong height without saying so.
   local start = tonumber(dlg:GetDoubleField("StartDepth"))
   if start == nil then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Start depth must be a number",
         plain = "Start depth must be a number.",
      })
      return false
   end
   if start < 0 then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Start depth cannot be negative",
         body = "It's how far below the top of the stock the edge sits. Use 0 for an edge at the top.",
         plain = "Start depth cannot be negative - it is how far BELOW "
             .. "the top of the stock the edge sits. Use 0 for an edge at the top.",
      })
      return false
   end

   -- Remember what was entered, whatever happens next: a run that then fails a
   -- safety check is exactly when reopening with the same bit and size helps.
   CO.save_settings({ units = unit.suffix, mode = mode,
                      side = side, percent = tonumber(percent), size = size })

   local r = CO.evaluate(mode, size, angle, dia)
   if not r.ok then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Chamfer too big for a safe cut",
         body = "It would force the cut onto the tip or the shoulder. Use a larger bit "
             .. "or a smaller chamfer.",
         plain = r.reason,
      })
      return false
   end

   local s
   for _, p in ipairs(r.presets) do if p.percent == percent then s = p end end
   if not s then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Internal error",
         body = "No preset matched " .. tostring(percent) .. ". Please report this message.",
         plain = "Internal error: no preset matched " .. tostring(percent),
      })
      return false
   end
   -- What actually gets chamfered. A selection is always the input; only when
   -- nothing usable was selected does the chosen chamfer rebuild from what it
   -- remembers (spec 2, last row -- this is what fixes the old refusal when the
   -- only thing easy to click was the gadget's own orange ring). Shapes owned
   -- by ANOTHER chamfer are left out only while the run is still doing what the
   -- selection implied: deliberately aiming at an existing chamfer means "these
   -- shapes, that chamfer" (the red replace state) and takes the whole
   -- selection.
   local input, recalled_missing = {}, 0
   if #kept > 0 then
      if slot == cls.slot and cls.kind == "add" then
         for _, i in ipairs(cls.free_idx) do input[#input + 1] = kept[i] end
      else
         input = kept
      end
   else
      local c = by_slot[slot]
      local res = c and c.resolved
      if not (res and res.found > 0) then
         CO.show_message(gadget_dir, {
            kind = "error",
            headline = "Nothing was changed",
            body = "Nothing is selected, and Chamfer " .. slot .. " has no remembered "
               .. "shapes still in this job to rebuild from.\n\nSelect the shapes to chamfer and "
               .. "run again.",
            plain = "Nothing is selected, and Chamfer " .. slot .. " has no remembered "
               .. "shapes still in this job to rebuild from.\n\nSelect the shapes to chamfer and "
               .. "run again.\n\nNothing was changed.",
         })
         return false
      end
      -- Put the remembered shapes INTO the selection and read them back the
      -- normal way: sdk_selection_spans is what turns objects into geometry,
      -- and going through it keeps the recall path identical to every other.
      pcall(function()
         job.Selection:Clear()
         for _, obj in ipairs(res.objs) do job.Selection:Add(obj, true, true) end
      end)
      input = CO.sdk_selection_spans(job)
      recalled_missing = res.missing
      if #input == 0 then
         CO.show_message(gadget_dir, {
            kind = "error",
            headline = "Nothing was changed",
            body = "Chamfer " .. slot .. "'s remembered shapes could not be read back "
               .. "from this job.\n\nSelect the shapes to chamfer and run again.",
            plain = "Chamfer " .. slot .. "'s remembered shapes could not be read back "
               .. "from this job.\n\nSelect the shapes to chamfer and run again.\n\n"
               .. "Nothing was changed.",
         })
         return false
      end
   end

   -- pts still feed the outward/inward classification; obj is what v1.3.0's
   -- offset selects to hand Aspire one loop at a time; bbox is what this
   -- chamfer will remember about the shape afterwards.
   local loops = {}
   for _, rl in ipairs(input) do
      loops[#loops + 1] = { pts = CO.polygonize(rl.spans, 0.001), obj = rl.obj, bbox = rl.bbox }
   end
   local dirs = CO.resolve_directions(loops, side)
   -- Rebuilding an ADOPTED v1.4.x chamfer migrates it: this run replaces its
   -- layer and its toolpath with the EdgeBreaker-named pair, so the old ones
   -- have to go with it or the number owns two of each.
   local migrating = (by_slot[slot] ~= nil and by_slot[slot].origin == "old")
   local ok_layer, layer, old_layer_left = pcall(CO.sdk_prepare_layer, job, slot, migrating)
   if not ok_layer then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Couldn't prepare the offset layer",
         body = "Layer '" .. CO.offset_layer_name(slot) .. "':\n" .. tostring(layer),
         plain = "Could not prepare layer '" .. CO.offset_layer_name(slot)
             .. "':\n" .. tostring(layer),
      })
      return false
   end
   -- The layer wipe just made any previous chamfer toolpath meaningless (its
   -- vectors are gone), so this is the moment to delete marked toolpaths.
   -- A failure here still leaves duplicates, as pre-1.0.7, but it no longer does
   -- so quietly -- CO.delete_outcome turns every way this can fail into trouble.
   -- `trouble` is set wherever this run has something to EXPLAIN rather than
   -- merely report. It decides, together with sel_notes, whether the run stays
   -- silent or falls back to v1.4.0's message box (CO.should_report).
   local ok_del, deleted, del_failed = pcall(CO.sdk_delete_marked_toolpaths, slot, migrating)
   local trouble, replaced_note = CO.delete_outcome(ok_del, deleted, del_failed, slot)
   -- Hand exactly the INPUT vectors back at the end (not the whole selection:
   -- it may have included our own offsets, whose wrappers die in the wipe).
   local orig_sel = {}
   for _, rl in ipairs(input) do
      if rl.obj ~= nil then orig_sel[#orig_sel + 1] = rl.obj end
   end
   -- One :Offset call per loop, not one for the whole selection: a group offsets
   -- uniformly by a single signed distance, but outer boundaries go outward and
   -- holes go inward. Per-loop also preserves which input produced which output,
   -- which is what makes the skip count possible. N calls on a 17-vector job is
   -- not worth optimising.
   -- built_fps is what this chamfer will REMEMBER: the fingerprint of every
   -- input shape that actually produced an offset. A shape too narrow to
   -- chamfer at this size produced nothing, so remembering it would promise a
   -- rebuild the gadget cannot deliver.
   local n_out, n_in, skipped_narrow, drawn, built_fps = 0, 0, 0, {}, {}
   for i, loop in ipairs(loops) do
      local dist = (dirs[i] == "outward") and s.g or -s.g
      local group, oerr = CO.sdk_offset_loop(job, loop.obj, dist)
      if oerr then
         CO.sdk_leave_user_layer(job)
         CO.show_message(gadget_dir, {
            kind = "error",
            headline = "Couldn't offset a vector",
            body = "Failed offsetting vector " .. i .. ":\n" .. tostring(oerr),
            plain = "Failed offsetting vector " .. i .. ":\n" .. tostring(oerr),
         })
         return false
      elseif group == nil then
         -- Too narrow to chamfer at this G: Aspire collapsed it to nothing.
         -- Counted and reported below; never drawn, never a phantom loop.
         skipped_narrow = skipped_narrow + 1
      else
         local ok_draw, cad, derr = pcall(CO.sdk_draw_group, layer, group)
         if not (ok_draw and cad) then
            CO.sdk_leave_user_layer(job)
            CO.show_message(gadget_dir, {
               kind = "error",
               headline = "Couldn't draw an offset vector",
               body = "Failed drawing offset vector " .. i .. ":\n"
                   .. tostring(ok_draw and derr or cad),
               plain = "Failed drawing offset vector " .. i .. ":\n"
                   .. tostring(ok_draw and derr or cad),
            })
            return false
         end
         drawn[#drawn + 1] = cad
         if loop.bbox ~= nil then built_fps[#built_fps + 1] = loop.bbox end
         -- Count directions only for loops that produced an offset, so the
         -- outward+inward figures add up to the "14 of 17" count.
         if dirs[i] == "outward" then n_out = n_out + 1 else n_in = n_in + 1 end
      end
   end

   -- Every loop collapsed. The layer wipe already happened unconditionally
   -- (above), so the offset vectors really are gone -- say so. The old-toolpath
   -- delete was only ATTEMPTED, though: replaced_note already carries whether
   -- it fully succeeded (see the success report below), so it has to travel
   -- here too or a partial delete failure reads as a clean one. #loops is the
   -- KEPT count (open vectors and the gadget's own offsets already dropped by
   -- this point), so selection_skip_notes has to ride along too, or "None of
   -- the 12" understates what was actually selected.
   if #drawn == 0 then
      CO.sdk_leave_user_layer(job)
      pcall(function() job.Selection:Clear() end)
      for _, obj in ipairs(orig_sel) do
         pcall(function() job.Selection:Add(obj, true, true) end)
      end
      job:Refresh2DView()
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Nothing was wide enough to chamfer",
         body = string.format(
            "No offset vectors were drawn and no toolpath was created. The previous"
            .. " run's offset vectors were already cleared.%s\n\n"
            .. "Try a smaller chamfer size, or a cut position nearer the tip.%s",
            replaced_note ~= "" and ("\n" .. replaced_note) or "",
            CO.selection_skip_notes(skipped_open, skipped_own)),
         rows = {
            { "Selected", CO.offset_count_phrase(#loops, #loops) },
            { "G", string.format("%.4f %s", s.g, unit.suffix) },
         },
         plain = string.format(
            "None of the %d selected vector(s) are wide enough to chamfer at G %.4f %s"
            .. " - Aspire's offset collapsed every one of them to nothing.\n\n"
            .. "No offset vectors were drawn and no toolpath was created. The previous"
            .. " run's offset vectors were already cleared.%s\n\n"
            .. "Try a smaller chamfer size, or a cut position nearer the tip.%s",
            #loops, s.g, unit.suffix,
            replaced_note ~= "" and ("\n" .. replaced_note) or "",
            CO.selection_skip_notes(skipped_open, skipped_own)),
      })
      return false
   end
   -- sdk_offset_loop left the LAST input vector selected (selection surgery). The
   -- shipped template is layer-restricted (README.md), but a hand-re-created,
   -- UNRESTRICTED one attaches to the SELECTION at load time -- with an original
   -- still in it the toolpath would bind to the original, not the offsets
   -- (live-proven 2026-07-24). Clear first, then Add: same call the Mastercam
   -- import gadgets use to pre-select vectors.
   local sel_ok, sel_err = pcall(function()
      job.Selection:Clear()
      for _, obj in ipairs(drawn) do job.Selection:Add(obj, true, true) end
   end)
   CO.sdk_leave_user_layer(job)
   job:Refresh2DView()

   local toolpath_note
   if not sel_ok then
      trouble = true
      -- Clear() is now INSIDE this pcall, so a throw here is NOT guaranteed to
      -- leave the selection empty: a throw AT Clear() leaves the stale selection
      -- from sdk_offset_loop's last call in place, and a throw partway through
      -- the Add loop below leaves only some of the drawn offsets selected.
      -- Either way it is not reliably the full set of drawn offsets, so loading
      -- the template now could bind to the wrong thing -- still safe (the
      -- template is never loaded on this path), but draw-only and say why.
      toolpath_note = "TOOLPATH NOT CREATED: could not select the drawn offsets ("
                      .. tostring(sel_err) .. ")."
   elseif template_ok then
      -- pcall shapes: (true,table)=success, (true,nil,err)=soft failure, (false,errstr)=raw throw
      -- depth stored in job units (docs/m0-results.md, mm-sample)
      local tp_name = CO.toolpath_name(size, unit.suffix, slot)
      local ok_tp, res, terr = pcall(CO.sdk_apply_template, gadget_dir, CO.TEMPLATE_NAME,
                                     s.d, start, slot, tp_name, tool)
      if ok_tp and type(res) == "table" then
         local shown = res.renamed and ("'" .. tp_name .. "' ") or ""
         if res.status == "calculated" then
            toolpath_note = string.format("Toolpath %screated and calculated (Profile On, depth %.4f %s)\nusing %s.",
                                          shown, s.d, unit.suffix, geom.name)
         else
            trouble = true
            toolpath_note = string.format("Toolpath %screated (Profile On, depth %.4f %s)\nusing %s.",
                                          shown, s.d, unit.suffix, geom.name)
               .. "\n\nYour other toolpaths were left untouched, and the chamfer toolpath "
               .. "could not be calculated on its own - open it and click Calculate."
         end
         if not res.retooled then
            trouble = true
            -- The offsets and depth are right for the bit you picked, but the
            -- toolpath is still cutting with the template's bit: wrong feeds,
            -- wrong tool number, and a chamfer that won't match the preview.
            toolpath_note = toolpath_note
               .. "\n\nWARNING: couldn't put your chosen bit on the toolpath, so it still "
               .. "uses the template's bit. Change the tool on it in the Toolpaths panel "
               .. "before cutting."
         end
         if not res.renamed then
            trouble = true
            toolpath_note = toolpath_note
               .. "\n\nCouldn't tag the toolpath as EdgeBreaker's, so the next run "
               .. "will NOT replace it automatically - delete it by hand when you re-run."
         end
         -- TEACH: the chamfer now remembers the shapes it was built from and
         -- the settings that built them, so selecting any of them again means
         -- "rebuild this chamfer" and an empty selection can recall it. The
         -- toolpath is re-found by marker rather than reusing the wrapper the
         -- template load returned -- a recalculate recreates the toolpath and
         -- leaves that one pointing at nothing. Best-effort throughout: a
         -- chamfer with no memory is v1.4.0 behaviour, not a broken cut.
         local tp = CO.sdk_find_toolpath_by_slot(slot) or res.tp
         local taught = tp ~= nil and CO.sdk_write_memory(tp, {
            fps = built_fps, size = size, mode = mode, side = side,
            percent = tonumber(percent), units = unit.suffix, start = start,
            tool = geom.name })
         if taught then
            -- The bit itself cannot go in the blob (a ToolDBId has no text
            -- form), so it is parked in Aspire's own tool defaults under this
            -- chamfer's key and the picker opens on it next time.
            pcall(function()
               tool.ToolDBId:SaveDefaults(CO.TOOL_SECTION, CO.tool_defaults_key(slot))
            end)
         else
            trouble = true
            toolpath_note = toolpath_note
               .. "\n\n(Couldn't store this chamfer's shapes on the toolpath, so the next "
               .. "run won't recognise them - select them again to rebuild it.)"
         end
      else
         trouble = true
         toolpath_note = "TOOLPATH NOT CREATED: " .. tostring(ok_tp and terr or res)
      end
   else
      trouble = true
      toolpath_note = "TOOLPATH NOT CREATED: " .. tostring(template_err)
         .. "\n\nThe offset vectors were still drawn."
   end
   if replaced_note ~= "" then
      toolpath_note = replaced_note .. "\n" .. toolpath_note
   end

   -- The offsets had to stay selected through template load AND recalc (an
   -- unrestricted template would bind to the selection; the one that SHIPS is
   -- layer-restricted, so this is belt-and-braces). Only now is it safe to
   -- hand the selection back to the user's original vectors. Per-object
   -- pcall: one stale wrapper must not spoil the rest.
   if #orig_sel > 0 then
      pcall(function() job.Selection:Clear() end)
      local restored = 0
      for _, obj in ipairs(orig_sel) do
         if pcall(function() job.Selection:Add(obj, true, true) end) then
            restored = restored + 1
         end
      end
      if restored == 0 then
         trouble = true
         toolpath_note = toolpath_note
            .. "\n\n(Couldn't re-select your original vectors - re-select them before the next run.)"
      end
      job:Refresh2DView()
   end

   local sel_notes = CO.selection_skip_notes(skipped_open, skipped_own)
   local narrow_note = CO.skip_summary(skipped_narrow)
   if narrow_note then sel_notes = sel_notes .. "\n\n" .. narrow_note end
   -- Spec 8: a rebuild from memory says what it could not find, rather than
   -- quietly cutting a smaller chamfer than the one that was there before.
   if recalled_missing > 0 then
      sel_notes = sel_notes .. string.format(
         "\n\nNote: rebuilt from %d of its %d remembered shape(s) - the others are no longer "
         .. "in this job (moved, edited or deleted).", #loops, #loops + recalled_missing)
   end
   if old_layer_left then
      sel_notes = sel_notes .. string.format(
         "\n\nNote: the old '%s%02d' layer was emptied but could not be removed - delete it "
         .. "in the Layers panel.", CO.OLD_LAYER_PREFIX, slot)
   end
   -- Every run names the chamfer it built AND what it did to it. With several
   -- in a job the summary is otherwise indistinguishable between them, and
   -- "which one did I just cut?" is the question the whole feature creates.
   local DID = { add = "added", rebuild = "rebuilt", recall = "rebuilt from memory",
                 teach = "rebuilt - it now remembers these shapes", replace = "shapes replaced" }

   -- v1.7.0: silence means it worked. Everything the receipt used to restate --
   -- the banner, the size, the bit, the layer and toolpath names -- was already
   -- on the setup dialog before OK was pressed, and the section view it drew is
   -- now there too, live. What is left is only worth a dialog when there is
   -- something to act on.
   if not CO.should_report(trouble, sel_notes) then return true end

   -- This is now the ONLY report the gadget produces, and it appears only when
   -- there is something to say: it has to state the reach too, for the same
   -- reason the dialog's warning does.
   local start_txt = (start > 0) and string.format(
      "\nStart depth: %.4f %s (total reach %.4f %s)",
      start, unit.suffix, start + s.d, unit.suffix) or ""

   local rows = {
      { "Offset", string.format("%s (%d outward, %d inward)",
           CO.offset_count_phrase(#loops, n_out + n_in), n_out, n_in) },
      { "G", string.format("%.4f %s", s.g, unit.suffix) },
      { "Plunge D", string.format("%.4f %s", s.d, unit.suffix) },
      { "Standoff", string.format("%.4f %s", s.standoff, unit.suffix) },
   }
   if start > 0 then
      rows[#rows + 1] = { "Start depth", string.format("%.4f %s (total reach %.4f %s)",
         start, unit.suffix, start + s.d, unit.suffix) }
   end
   rows[#rows + 1] = { "Layer", CO.offset_layer_name(slot) }

   -- The report is only reached when there is something to say (should_report
   -- above), so it is never plain "done": either a note reached sel_notes or
   -- something went wrong. Amber unless nothing did.
   -- sel_notes is built to be APPENDED (every contributor prefixes its own
   -- "\n\n"), which is right when it lands after the old format string's last
   -- line but wrong as the FIRST thing in #Note's pre-wrap box -- strip the
   -- leading break here, in the styled box only. plain still uses sel_notes
   -- directly, unchanged, so the fallback text does not move.
   local note_text = (sel_notes:gsub("^%s+", ""))
   if toolpath_note ~= "" then
      note_text = (note_text ~= "" and (note_text .. "\n\n") or "") .. toolpath_note
   end

   CO.show_message(gadget_dir, {
      kind = (trouble or note_text ~= "") and "warn" or "done",
      headline = string.format("Chamfer %d %s", slot, DID[kind_out] or "built"),
      rows = rows,
      note = note_text,
      plain = string.format(
         "EdgeBreaker - Chamfer %d %s\n\nOffset %s (%d outward, %d inward) by G %.4f %s\nonto layer '%s'.\n\nPlunge depth D: %.4f %s%s\nStandoff from wall: %.4f %s%s\n\n%s\n\n%s",
         slot, DID[kind_out] or "built",
         CO.offset_count_phrase(#loops, n_out + n_in), n_out, n_in, s.g, unit.suffix,
         CO.offset_layer_name(slot), s.d, unit.suffix, start_txt, s.standoff, unit.suffix,
         sel_notes, r.tip_flat_advisory, toolpath_note),
   })
   return true
end
