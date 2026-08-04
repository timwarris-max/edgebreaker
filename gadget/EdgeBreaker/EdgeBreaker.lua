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

-- The most passes a single chamfer may take before the gadget refuses. It
-- catches a typo in the size box -- eight passes with a 1/4 in bit is already a
-- 0.75 in chamfer -- rather than rationing the feature.
--
-- It is load-bearing a SECOND time, and less obviously: it keeps the band number
-- a single digit, which is what keeps 'EdgeBreaker Offset NN-k' exactly 23
-- characters, which is what lets the template's layer restriction be patched IN
-- PLACE. Raising this past 9 is not a constant change; it is a template change.
CO.MAX_PASSES = 8

-- How close to "exactly filling the usable flute" still counts as fitting.
--
-- The interesting case is exactly ON the boundary: a 1/4 in 90 deg bit's window
-- is exactly 0.09375 wide and eight bands of a 0.75 chamfer are exactly 0.09375,
-- yet as doubles the two sides of the comparison differ by 3.5e-18. Without a
-- tolerance, a number with no physical meaning decides whether the gadget cuts,
-- and its sign changes from bit to bit.
--
-- A band that exactly fills the window is ACCEPTED, deliberately: the margins
-- are the safety. This is far below anything measurable and far above double
-- rounding error at any size either unit system produces.
CO.FIT_EPS = 1e-9
CO.MODES           = { setback = true, face = true, leg = true }
CO.SIDES           = { auto = true, outside = true, inside = true }
CO.VERSION         = "1.13.0"

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
                  .. ", which cannot be machined. Check the bit in your tool database."
   end
   if type(dia) ~= "number" or dia ~= dia or dia <= 0 then
      return nil, "This bit reports a diameter of " .. tostring(dia)
                  .. ". Check the bit in your tool database."
   end
   return true
end

-- Dialog window size, in physical pixels. The page is authored at one fixed
-- size and scales itself DOWN to whatever window it is given (see
-- EdgeBreakerDialog.htm), so a smaller screen gets a smaller window rather
-- than a cramped layout. A dialog cannot resize itself, so this must be right
-- before it opens.
--
-- Until v1.10.0 this was a guess keyed on COMPUTERNAME: our two machines were
-- listed and every other machine on earth got a default. Getting that wrong is
-- invisible here and unusable there -- it shipped, and a VCarve Pro user's OK
-- button landed off the bottom of his screen. Now the page MEASURES the screen
-- (CO.dialog_size below, fed by CO.load_screen) and the guess survives only as
-- the fallback for when there is no measurement to use.
--
-- DESIGN_SIZE is what the LAYOUT is authored against -- keep it in step with
-- DESIGN_W/H in EdgeBreakerDialog.htm and WIN_W/H in the layout gate. It is
-- also the cap: the page never scales UP, so a bigger window is dead space.
CO.DESIGN_SIZE  = { 1800, 1000 }        -- keep in step with EdgeBreakerDialog.htm
CO.DEFAULT_SIZE = { 1280, 700 }         -- no measurement: fits 1366x768
CO.SCREEN_MARGIN = 16                   -- so the window is not flush to the screen edge

-- v1.10.1: SCREEN_MARGIN alone only asks "does it fit". On a 1920x1080 screen
-- both axes reach DESIGN_SIZE, so the window covers ~93% of the screen and
-- reads as fullscreen rather than as a dialog (seen on the Acer, 2026-07-30).
-- SCREEN_FRACTION is the second cap: never more than this much of the screen.
-- DEFAULT_SIZE then acts as a FLOOR, because a fraction takes its biggest bite
-- exactly where there is least room -- 80% of a 1366-wide laptop is 1092, and
-- shrinking the machines that need every pixel would be backwards. Net effect:
-- only screens between roughly 1600 and 2250 wide change at all.
CO.SCREEN_FRACTION = 0.80

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
-- v1.10.1: the size is now clamped to the screen, the same defect class the
-- setup dialog fixed in v1.10.0 -- a 700-tall message window does not fit a
-- 1280x720 screen, so OK landed under the taskbar. Clamping is safe here for a
-- reason worth stating: MessageDialog.htm does NOT scale to its window the way
-- the setup dialog does. It has a pinned header, a pinned button bar and
-- `overflow:auto` between them, so a short window scrolls the middle and keeps
-- OK reachable. Shrinking costs a scrollbar; not shrinking costs the button.
--
-- No SCREEN_FRACTION here and no floor: this window is small enough already
-- that breathing room is not the problem, and a floor would defeat the point.
-- An unbelievable or absent screen leaves the size exactly as it was.
function CO.message_fields(msg, screen_w, screen_h)
   local cls = CO.MESSAGE_KINDS[msg.kind] or CO.MESSAGE_KINDS.error
   local has_rows = msg.rows ~= nil and #msg.rows > 0
   local size = has_rows and CO.MESSAGE_SIZE_TALL or CO.MESSAGE_SIZE_SHORT
   local w, h = size[1], size[2]
   if CO.believable_screen(screen_w, screen_h) then
      w = math.floor(math.min(w, tonumber(screen_w) - CO.SCREEN_MARGIN))
      h = math.floor(math.min(h, tonumber(screen_h) - CO.SCREEN_MARGIN))
   end
   size = { w, h }
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
      -- The screen this RUN is on, stashed by main() as CO.RUN_SCREEN, so the
      -- report fits the same monitor as the dialog did. A message with no run
      -- behind it (or one that landed off the primary) falls back to the
      -- stored measurement; a machine that has ever been off the primary
      -- cannot vouch for its stored numbers here, so they are discarded --
      -- the unclamped 900x700 fits any panel 768 tall or more, which is the
      -- smallest laptop screen there is.
      local sw, sh
      if CO.RUN_SCREEN ~= nil then
         sw, sh = CO.RUN_SCREEN[1], CO.RUN_SCREEN[2]
      else
         local store = CO.load_screen()
         if store ~= nil and not store.everoff then
            sw, sh = store.screen_w, store.screen_h
         end
      end
      local fields, w, h = CO.message_fields(msg, sw, sh)
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

-- The blink. It says nothing -- Tim's call: a wordless flicker rather than a
-- window with a sentence in it, because it fires on every run of a machine
-- that has ever reported itself off the primary -- a two-monitor machine
-- whose Aspire always sits on the primary never blinks at all.
--
-- An OUTER size, like every window size here, and the frame costs 2 x 50: 140x90
-- leaves the page 138x40. That is the floor, and it is set by the real OK button
-- rather than by the text -- if the auto-click ever fails, the operator must have
-- something to press instead of something stuck.
CO.MEASURE_SIZE = { 140, 90 }

-- Open the blink and read what it says. Two occasions, one function: on a
-- machine we have never sized this is the measuring run, and on a machine that
-- has ever reported itself off the primary it runs every time to answer the
-- one question Trident cannot answer afterwards -- is this window on the
-- primary?
--
-- Saves nothing. main() decides what is worth keeping, because what is worth
-- keeping differs between those two occasions.
--
-- Silent on every path, including its own failures. A cancelled blink, a
-- missing page, scripting turned off and a garbage value all return nil, and
-- nil means the caller falls back to a guess. Telling the operator would be
-- noise in the one gadget that worked hard to stay quiet, and there is nothing
-- they could do with the news.
function CO.sdk_ask_page(gadget_dir)
   local w, h, off
   pcall(function()
      local probe = io.open(gadget_dir .. "\\MeasureScreen.htm", "r")
      if probe == nil then return end
      probe:close()
      local dlg = HTML_Dialog(false, "file:" .. gadget_dir .. "\\MeasureScreen.htm",
                              CO.MEASURE_SIZE[1], CO.MEASURE_SIZE[2], "EdgeBreaker")
      dlg:AddTextField("Screen", "")
      -- The return value is ignored on purpose. The page dismisses itself by
      -- clicking OK, and a Cancel (or the X) is not a failure either -- what
      -- matters is whether a number came back.
      dlg:ShowDialog()
      w, h, off = CO.parse_screen_field(dlg:GetTextField("Screen"))
   end)
   return w, h, off
end

-- The most a window frame can plausibly cost on one axis. Measured on the
-- machine this defect was found on (2026-07-31): the dialog was asked for
-- 1800x1000 and the page reported a client box of 1796x868, so the frame was
-- 4 wide and 132 tall at 150% display scaling, with Trident reporting device
-- pixels. 132 is far more than a title bar and a border ought to account for
-- and we cannot fully explain it, so this is a generous absurdity check rather
-- than a model of window chrome: it is here to reject a "frame" that could only
-- come from Aspire ignoring the size we asked for, not to second-guess a real
-- one on a machine nobody has measured.
CO.FRAME_MAX = 400

-- Read the setup dialog's two report fields and remember them. Called after the
-- dialog closes, on BOTH the OK and Cancel paths: a run someone abandoned still
-- tells us how big their screen is and how big they want the window, and a
-- field's value survives Cancel (probed 2026-07-30).
--
-- asked_w/asked_h are the OUTER size this run handed HTML_Dialog. They are what
-- makes the window-size half work at all -- see the frame arithmetic below.
--
-- `everoff` is STICKY -- set here, never cleared. It is the only evidence we
-- have that this machine has ever reported itself off the primary now that
-- nothing asks Windows, and such a machine keeps paying for the blink even on
-- runs that land on the primary, because the next run might not.
function CO.remember_screen(dlg, asked_w, asked_h)
   pcall(function()
      local w, h, off = CO.parse_screen_field(dlg:GetTextField("Screen"))
      local ww, wh, lw, lh = CO.parse_window_field(dlg:GetTextField("WinSize"))
      -- The page reports CLIENT boxes -- current, then load-time -- because
      -- Trident's window.outerWidth/outerHeight are frozen at the size the
      -- window was CREATED at and never move on a resize (proved in Aspire
      -- 2026-07-31: the layout followed a drag, the remembered size did not).
      -- HTML_Dialog takes an OUTER size, so the frame has to go back on, and it
      -- is derived from this very run rather than assumed: we asked for
      -- asked_w x asked_h and the page came back with lw x lh, so the
      -- difference IS this machine's frame at this machine's DPI.
      --
      -- What that buys, and the reason the arithmetic is shaped this way: on a
      -- run nobody resized, current == load, so the stored size comes out
      -- exactly the size we asked for. Open and close the dialog a hundred
      -- times and it cannot drift by a pixel.
      --
      -- A frame we cannot believe means we store nothing at all. Keeping the
      -- client box and calling it an outer size would cost the window its own
      -- frame every run -- 132px of height a time on the machine above.
      if ww ~= nil and lw ~= nil then
         local aw, ah = tonumber(asked_w), tonumber(asked_h)
         local fw = aw and (aw - lw)
         local fh = ah and (ah - lh)
         if fw ~= nil and fh ~= nil and fw >= 0 and fh >= 0
            and fw <= CO.FRAME_MAX and fh <= CO.FRAME_MAX then
            ww, wh = ww + fw, wh + fh
         else
            ww, wh = nil, nil
         end
      end
      local store = CO.load_screen() or {}
      if w ~= nil then store.screen_w, store.screen_h = w, h end
      if off then store.everoff = true end
      -- `off` is nil, not false, when the Screen field failed to parse -- "we
      -- don't know" must not default to "on the primary". Guessing wrong here
      -- means a size measured on a second monitor permanently overwrites
      -- win_on, the slot every single-monitor machine relies on.
      if ww ~= nil and off ~= nil then
         if off then store.win_off = { ww, wh } else store.win_on = { ww, wh } end
      end
      CO.save_screen(store)
   end)
end

-- Is this pair of numbers a screen? Anything else is discarded rather than
-- repaired: a garbage value we silently clamp is a garbage value we keep.
-- NaN needs its own check -- every comparison on it is false, so without one
-- it would fall through to true; infinity is still caught by the comparisons.
function CO.believable_screen(w, h)
   w, h = tonumber(w), tonumber(h)
   if w == nil or h == nil then return false end
   if w ~= w or h ~= h then return false end
   if w < 640 or h < 480 then return false end
   if w > 30000 or h > 30000 then return false end
   return true
end

-- Is this pair a window someone could have left behind? Same rule as
-- believable_screen and the same reason: a garbage value we silently clamp is a
-- garbage value we keep. The floor is low because the operator is ALLOWED to
-- make it small -- a small window fully on screen beats a legible one with OK
-- off the bottom -- so this only has to reject things no real window could be.
function CO.believable_window(w, h)
   w, h = tonumber(w), tonumber(h)
   if w == nil or h == nil then return false end
   if w ~= w or h ~= h then return false end
   if w < 320 or h < 200 then return false end
   if w > 30000 or h > 30000 then return false end
   return true
end

-- The whole rule: usable screen, less a margin, capped at the design size and
-- at SCREEN_FRACTION of the screen. Pure -- no SDK, no environment, no file --
-- so tests/test_dialog_size.lua covers every case. Each dimension is worked out
-- independently.
--
-- v1.10.4 REMOVED the DEFAULT_SIZE floor that v1.10.1 added here. The floor
-- existed so small screens would not be shrunk below 1280x700 -- and then Tim
-- looked at exactly that window on the Acer's 1366-wide panel and called it
-- comically large (94% of the screen), while calling the same 1280x700 at 67%
-- of the big monitor perfect. The verdict is that PROPORTION is the product,
-- so the fraction now rules at every size. A 1366x720 panel gets 1092x576;
-- legibility comes from the page scaling down, and the smallest believable
-- screen (640x480) gets 512x384, which no real machine has.
function CO.dialog_size(screen_w, screen_h)
   if not CO.believable_screen(screen_w, screen_h) then
      return CO.DEFAULT_SIZE[1], CO.DEFAULT_SIZE[2]
   end
   local function axis(screen, design)
      return math.floor(math.min(screen - CO.SCREEN_MARGIN, design,
                                 screen * CO.SCREEN_FRACTION))
   end
   return axis(tonumber(screen_w), CO.DESIGN_SIZE[1]),
          axis(tonumber(screen_h), CO.DESIGN_SIZE[2])
end

-- The screen we fall back to when we know nothing about the monitor the dialog
-- is opening on: the smallest panel anyone is realistically running Aspire on.
-- Written as a SCREEN and passed through the ordinary rule rather than written
-- down as a window size, so it cannot drift from CO.dialog_size.
--
-- 1366x720, NOT 1366x768: dialog_size is fed the USABLE screen -- taskbar
-- already excluded, which is what availWidth/availHeight report and what the
-- Acer's panel actually measured. The full 768 would give 1092x614.
CO.SAFE_SCREEN = { 1366, 720 }

-- What window does this run open at? See tests/test_dialog_size.lua for the
-- table in full.
--
--   rem              {w,h} the operator left this slot at, or nil
--   screen_w/_h      the measured PRIMARY screen, or nil
--   off              is this run on a monitor that is NOT the primary?
--
-- Pure -- no SDK, no file, no environment.
function CO.window_size(rem, screen_w, screen_h, off)
   if type(rem) == "table" and CO.believable_window(rem[1], rem[2]) then
      local w = math.floor(tonumber(rem[1]))
      local h = math.floor(tonumber(rem[2]))
      -- Clamped on the primary only. Off the primary these numbers describe a
      -- different monitor, and clamping to them is how a perfectly good
      -- remembered size gets cut down to a screen it is not on.
      --
      -- On the primary with an UNBELIEVABLE screen, this condition is also
      -- false, and the clamp is skipped -- the remembered size comes back
      -- untouched, the same "as-is" the table only names for off-primary. That
      -- is safe, not accidental: a remembered size and its screen measurement
      -- always travel together out of ONE store. CO.parse_screen_store's very
      -- first check after parsing is `believable_screen` on the stored screen
      -- line, and it returns nil for the WHOLE store -- win_on and win_off
      -- included -- right there, before a window size is ever read out of the
      -- text (pinned by test_settings.lua's "an unbelievable measurement voids
      -- the whole store"). So a real `rem` can never arrive here paired with
      -- an unbelievable screen_w/screen_h from the same load_screen() call.
      -- This stops being true, and this cell needs a real decision instead of
      -- a comment, the day rem and screen_w/screen_h are ever sourced
      -- independently -- two different stores, or a screen number read at a
      -- different moment than the remembered size.
      if not off and CO.believable_screen(screen_w, screen_h) then
         w = math.min(w, math.floor(tonumber(screen_w)) - CO.SCREEN_MARGIN)
         h = math.min(h, math.floor(tonumber(screen_h)) - CO.SCREEN_MARGIN)
      end
      return w, h
   end
   if off then return CO.dialog_size(CO.SAFE_SCREEN[1], CO.SAFE_SCREEN[2]) end
   return CO.dialog_size(screen_w, screen_h)
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

-- Displayed capacity figures round in a FIXED direction, never to nearest: the
-- stated maximum must be a size that is actually accepted if the user types it
-- back in, and the suggested diameter must be a bit that actually works. The
-- 1e-9 absorbs binary representation error (0.0925 * 10000 is 924.99999999999996
-- in a double) without reaching any difference a person could measure.
function CO.floor4(x)
   return math.floor(x * 10000 + 1e-9) / 10000
end

function CO.ceil4(x)
   return math.ceil(x * 10000 - 1e-9) / 10000
end

-- Four decimals, trailing zeros stripped -- the same shape as the page's fnum,
-- because the two copies of this message have to read identically.
function CO.fmt_len(x)
   local s = string.format("%.4f", x)
   s = s:gsub("0+$", "")
   s = s:gsub("%.$", "")
   return s
end

-- Contact spans exactly one band, between TIP_MARGIN and SHOULDER_MARGIN of the
-- radius, so a pass is possible only while band <= (SHOULDER - TIP) * radius.
-- Derived from the two constants on purpose: hardcoding the 0.75 would let a
-- margin change leave the message lying.
function CO.capacity_fraction()
   return CO.SHOULDER_MARGIN - CO.TIP_MARGIN
end

-- The inverse of CO.w_from_size: given a chamfer width, what number does the
-- user type in this mode to get it? Returns nil where the conversion divides by
-- ~0 rather than returning an absurd finite number.
function CO.size_from_w(mode, W, a)
   if mode == "setback" then return W end
   local k
   if mode == "face" then k = math.sin(a)
   elseif mode == "leg" then k = math.tan(a)
   else error("unknown size mode: " .. tostring(mode)) end
   if k == nil or k ~= k or k <= 1e-9 then return nil end
   return W / k
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

-- ============================================================
-- Multi-pass (v1.13.0)
-- ============================================================
-- A chamfer wider than the bit's usable flute is cut in N equal bands, top
-- down. The geometry follows from one fact: a V-bit's flank has exactly the
-- slope of the chamfer face, so ANY pass whose flank lies on that face has its
-- apex somewhere ON the face. Where along it is the only free parameter.
--
-- Top-down is mandatory, not preferable. Cut bottom-up, the uncut material
-- above would lie against the flute for the whole length of the flank -- the
-- exact constraint multi-pass exists to escape. Each pass's flute is cleared by
-- the material the pass above already removed.

function CO.band_width(W, n)
   return W / n
end

-- The smallest number of passes the EXISTING solver accepts. Deliberately a
-- search over safe_band rather than an inequality of its own: one rule in one
-- place, so a change to TIP_MARGIN or SHOULDER_MARGIN can never leave two
-- places disagreeing about what fits. (The closed form is
-- floor(W / ((SHOULDER_MARGIN - TIP_MARGIN) * r)) + 1 -- a note, not the
-- implementation.)
--
-- The comparison carries CO.FIT_EPS so that a band which exactly fills the
-- window counts as fitting. See that constant for why the bare > is not safe to
-- rely on here.
-- nil means "more than CO.MAX_PASSES", which the caller turns into a refusal.
function CO.pass_count(dia, W, a)
   for n = 1, CO.MAX_PASSES do
      local g_lo, g_hi = CO.safe_band(dia, CO.band_width(W, n), a)
      if g_hi > g_lo - CO.FIT_EPS then return n end
   end
   return nil
end

-- Where pass k sits and how deep it goes.
--   k < n:  apex at k*b - W  (NEGATIVE -- the tool axis is over the part and
--           the tip is buried at the band boundary), depth k*b / tan a
--   k = n:  apex at +G, out in the waste, depth (W + G) / tan a
-- At n = 1 the first branch never runs and this returns (G, (W+G)/tan a) --
-- v1.12.0's arithmetic, unchanged.
function CO.pass_geometry(k, n, W, G, a)
   if k == n then return { offset = G, depth = (W + G) / math.tan(a) } end
   local q = k * CO.band_width(W, n) - W
   return { offset = q, depth = (q + W) / math.tan(a) }
end

-- A pass's offset is measured from the wall, positive into the waste. Which way
-- that is on the canvas depends on the loop: an outer boundary's waste is
-- outside it, a pocket's is inside. Pulled out of main()'s loop so the sign rule
-- can be tested without a job.
function CO.band_offset_distance(dir, offset)
   if dir == "outward" then return offset end
   return -offset
end

-- How far a relief band is offset FROM THE FINISHING BAND'S LOOP -- which is
-- what it is actually cut from, so that its corners are the finishing pass's
-- corners backed off rather than the original vector's corners.
--
-- It is just the difference of the two distances, which means the relief band
-- still LANDS where it always did: finishing distance + this = dist_k, the
-- same number v1.13.0 offset the original vector by. Straight walls cannot
-- move; only the corner treatment does. Magnitude is (W - k*b) + G, and the
-- sign is always "back into the part" relative to the finishing loop, whichever
-- way round the loop runs.
function CO.relief_offset_distance(k, n, W, G, a, dir)
   local dk = CO.band_offset_distance(dir, CO.pass_geometry(k, n, W, G, a).offset)
   local dn = CO.band_offset_distance(dir, CO.pass_geometry(n, n, W, G, a).offset)
   return dk - dn
end

-- CO.solve is the FLUTE solver: it places G so that contact spans G..G+band
-- inside the safe window, and its `d` is the depth of a chamfer that wide. In
-- multi-pass those are two different chamfers -- the band decides G, the whole
-- chamfer decides the depth, because the final pass's apex sits on the face at
-- x = G. Overriding `d` here rather than inside CO.solve keeps the flute solver
-- honest about what it computes. At b == W the override is a no-op.
function CO.solve_band(percent, dia, W, b, a)
   local s = CO.solve(percent, dia, b, a)
   s.d = (W + s.g) / math.tan(a)
   s.band_hi = s.d
   return s
end

-- The biggest chamfer this bit can cut within the pass ceiling, in the mode the
-- user is typing in, as a number they can actually type back in.
--
-- Rounding DOWN is what makes that true: the exact bound is the most the bit can
-- take, so any four-decimal number at or below it fits, and a bound that lands
-- exactly on four decimals is stated as-is because a band that exactly fills the
-- flute is accepted (CO.FIT_EPS). The check before returning is not a formality
-- -- it is the promise this function makes -- and it returns nil rather than
-- print a maximum the gadget would then refuse.
function CO.display_max_size(mode, included_deg, dia)
   if type(dia) ~= "number" or dia ~= dia or dia <= 0 then return nil end
   local a = CO.half_angle(included_deg)
   local raw = CO.size_from_w(mode, CO.MAX_PASSES * CO.capacity_fraction() * (dia / 2), a)
   if raw == nil or raw ~= raw or raw <= 0 then return nil end
   local s = CO.floor4(raw)
   if s <= 0 then return nil end
   if CO.pass_count(dia, CO.w_from_size(mode, s, a), a) == nil then return nil end
   return s
end

-- The smallest bit that could cut the size they asked for within the ceiling.
-- Ceiled, for the mirror-image reason the maximum is floored: a bit rounded DOWN
-- is a bit that does not work. Same promise, same check before returning.
function CO.display_min_dia(mode, size, included_deg)
   if type(size) ~= "number" or size ~= size or size <= 0 then return nil end
   local a = CO.half_angle(included_deg)
   local W = CO.w_from_size(mode, size, a)
   if W == nil or W ~= W or W <= 0 then return nil end
   if CO.size_from_w(mode, W, a) == nil then return nil end
   local raw = W / (CO.MAX_PASSES * CO.capacity_fraction()) * 2
   local d = CO.ceil4(raw)
   if CO.pass_count(d, W, a) == nil then return nil end
   return d
end

-- The one writer of the too-big wording, so the page and the Lua cannot drift
-- into saying different things. Returns nil where either number would be
-- nonsense, and the caller falls back to the generic sentence rather than
-- printing "the most it'll take off is 0".
function CO.too_big_message(mode, size, included_deg, dia)
   local max_size = CO.display_max_size(mode, included_deg, dia)
   local min_dia = CO.display_min_dia(mode, size, included_deg)
   if max_size == nil or min_dia == nil then return nil end
   return string.format(
      "Too big for this bit, even in %d passes. The most it'll take off is %s. "
      .. "A %s bit would do the %s you asked for.",
      CO.MAX_PASSES, CO.fmt_len(max_size), CO.fmt_len(min_dia), CO.fmt_len(size))
end

function CO.evaluate(mode, size, included_deg, dia)
   local a = CO.half_angle(included_deg)
   local W = CO.w_from_size(mode, size, a)
   -- A chamfer too wide for one bite is cut in N bands, so what the safe band
   -- has to accept is the BAND, not the whole chamfer. Everything below is the
   -- v1.12.0 code with `b` where `W` used to be -- except the depth, which
   -- solve_band takes from the whole chamfer (see its comment).
   local n = CO.pass_count(dia, W, a)
   local b = (n ~= nil) and CO.band_width(W, n) or W
   local g_lo, g_hi, d_max = CO.safe_band(dia, b, a)
   local ok = n ~= nil
   local presets = {}
   if ok then
      for _, p in ipairs(CO.PRESETS) do
         local s = CO.solve_band(p, dia, W, b, a)
         s.percent = p
         s.passes = n
         s.band = b
         presets[#presets + 1] = s
      end
   end
   local reason = nil
   if not ok then
      -- Past the ceiling the numbered message is the useful one; the generic
      -- sentence survives only for a bit whose figures cannot be stated.
      reason = CO.too_big_message(mode, size, included_deg, dia)
         or ("Chamfer too big for a safe cut with this bit, even in "
             .. CO.MAX_PASSES .. " passes. Use a larger bit or a smaller chamfer.")
   end
   return {
      W = W, a = a, g_lo = g_lo, g_hi = g_hi, d_max = d_max,
      passes = n, band = b,
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

-- How deep each loop sits: how many of the OTHER loops contain it (2026-08-03,
-- spec section 3c). Bounding box first, then a point test on the loop's first
-- point -- the same predicate classify_directions has always used, factored out
-- so there is one implementation of "inside" in the file rather than two.
--
-- Nothing here stops at the first container, and that is the whole point.
-- classify_directions only ever needed "any", but a sharp run needs the COUNT:
-- once Machine Vectors leaves "On" it is ASPIRE that picks each loop's
-- displacement direction, from the nesting, and we have only measured its answer
-- as far as depth 1 (spec section 2). Depth is what lets CO.sharp_nesting_ok
-- refuse the rest instead of guessing.
function CO.nesting_depths(loops)
   local out = {}
   for i, li in ipairs(loops) do
      local ax0, ay0, ax1, ay1 = loop_bbox(li.pts)
      local depth = 0
      for k, lk in ipairs(loops) do
         if k ~= i then
            local bx0, by0, bx1, by1 = loop_bbox(lk.pts)
            if ax0 >= bx0 and ay0 >= by0 and ax1 <= bx1 and ay1 <= by1
               and CO.point_in_poly(li.pts[1][1], li.pts[1][2], lk.pts) then
               depth = depth + 1
            end
         end
      end
      out[i] = depth
   end
   return out
end

-- Two-level, deliberately and unchanged: outermost outward, everything nested
-- inward, however deep. This is what Auto has always done and what the operator
-- expects from "outlines outward, holes inward". Depth beyond 1 is where it
-- stops agreeing with Aspire, which is CO.sharp_nesting_ok's problem, not this
-- function's.
function CO.classify_directions(loops)
   local out = {}
   for i, depth in ipairs(CO.nesting_depths(loops)) do
      out[i] = (depth == 0) and "outward" or "inward"
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

-- Sharp corners: is the box ticked, and is the cut shallow enough?
--
-- Only within the bit's cutting-edge depth (2026-08-03). Aspire refuses to
-- sharpen a pass deeper than that, which a two-pass run hit live on 2026-08-02
-- -- multi-pass is the first thing this gadget has ever built that can plunge
-- past it. The deepest pass is always the finishing one, so one test on the
-- whole chamfer's d covers every pass.
--
-- The SIDE is not here any more (2026-08-03, spec section 5a). It used to refuse
-- anything but Inside or Outside, on the reasoning that one template patch
-- serves every loop in a run so the run needs one known direction. That premise
-- is gone: Aspire supplies the per-loop direction itself, from the nesting.
-- Whether ours and Aspire's agree is CO.sharp_nesting_ok's question, and it is a
-- strictly better detector than the side ever was -- it PERMITS Auto, which is
-- the only side that can sharpen a letter set, and it REFUSES a forced side over
-- a nested selection, which used to build a wrong cut in silence. The argument
-- is dropped rather than ignored: a parameter this no longer consults would be a
-- standing invitation to believe it still gates something.
--
-- The arguments have NO DEFAULTS on purpose: a caller that forgot the depth
-- would otherwise sharpen silently, and permissive is the wrong way for this
-- particular guard to fail.
--
-- Note this gate does NOT re-solve the cut position. The dialog lowers it where
-- it has to (CO.sharp_max_percent) so the operator watches the preset move and
-- the section redraw; Lua judges the depth it was handed. Re-solving here would
-- cut something other than the picture the operator pressed OK on.
function CO.sharp_applies(sharp, d, d_max)
   return tonumber(sharp) == 1 and d <= d_max
end

-- Can this selection be sharpened, and if so which way does the template point?
-- (2026-08-03, spec section 3c.)
--
-- A normal run cuts ON the drawn vector, so Aspire displaces nothing and nesting
-- never enters into it. A sharp run sets Machine Vectors to Inside or Outside --
-- that is what _ppdCornerSharpen needs to mean anything -- and from that moment
-- ASPIRE picks each loop's displacement direction, from the nesting of the loops
-- we drew. Measured live 2026-08-03 on a hand-built toolpath over a letter B:
-- Outside/Right machined outside the outline and inside both counters.
--
-- So the run has two opinions about every loop and is only correct when they
-- agree. Ours is in `dirs`; Aspire's is "the template's setting at depth 0, the
-- opposite at depth 1, unmeasured below that".
--
-- Returns the direction to write into the template, or nil plus a reason. The
-- reason is a token for CO.sharp_nesting_note, not a sentence -- the words live
-- in one place, next to each other, where they can be compared.
function CO.sharp_nesting_ok(dirs, depths)
   local outer = nil
   for i = 1, #dirs do
      -- Deeper than we have measured. Refuse rather than guess: at depth 2
      -- Aspire either alternates (and disagrees with us, because
      -- classify_directions is two-level) or matches us, and picking wrong
      -- machines the wrong side of every vector at that depth.
      if (depths[i] or 0) > 1 then return nil, "deep" end
      if (depths[i] or 0) == 0 then
         if outer == nil then outer = dirs[i]
         elseif outer ~= dirs[i] then return nil, "mixed" end
      end
   end
   -- No outermost loop at all. Cannot happen with real vectors -- something is
   -- always outside everything else -- but identical duplicated loops each
   -- contain the other, and a direction guessed here would be a coin toss.
   if outer == nil then return nil, "empty" end
   local want = (outer == "outward") and "inward" or "outward"
   for i = 1, #dirs do
      if (depths[i] or 0) == 1 and dirs[i] ~= want then return nil, "nested" end
   end
   return outer
end

-- What the operator reads when they asked for sharp corners and did not get
-- them. The chamfer is still built, correctly, with rounded corners: a sharp run
-- that cannot sharpen has a safe answer, and the gadget's manner is to give it
-- and say so, never to fail the run over it.
--
-- "nested" is the only one anybody will meet in practice, and it is the one that
-- has to name the remedy.
function CO.sharp_nesting_note(reason)
   if reason == "nested" then
      return "Sharp corners didn't run. One of your shapes sits inside another - a letter "
          .. "and its counter, say - and that only sharpens with Chamfer side on Auto. "
          .. "Switch it and run again."
   elseif reason == "deep" then
      return "Sharp corners didn't run. Your shapes are nested more than one deep, and "
          .. "that's further than this goes."
   elseif reason == "mixed" then
      return "Sharp corners didn't run. Your outermost shapes don't all chamfer the same "
          .. "way, and sharpening needs them to."
   end
   return "Sharp corners didn't run - this selection nests in a way it can't work out."
end

-- The highest preset cut position that still sharpens, or nil if none does.
--
-- Sharpening needs d <= d_max, i.e. (W + g)/tan a <= r/tan a, i.e. W + g <= r
-- -- the bit angle cancels, which is why this is arithmetic and not a search.
-- g rises with the cut position, so lowering the position is the only lever,
-- and it bottoms out at g_lo. Hence sharpening is possible at all exactly when
-- W <= r - g_lo, which on the standard margins is 0.85r.
--
-- Presets only: the operator picks from buttons, so an arbitrary percentage
-- would be a number they could not reproduce or type back in.
function CO.sharp_max_percent(dia, W, b, a)
   local g_lo, g_hi = CO.safe_band(dia, b, a)
   local room = (dia / 2) - W
   if g_lo > room then return nil end
   local best = nil
   for _, p in ipairs(CO.PRESETS) do
      local g = g_lo + (p / 100) * (g_hi - g_lo)
      if g <= room and (best == nil or p > best) then best = p end
   end
   return best
end

-- Sharp corners: Aspire discards any allowance while sharpening is on
-- (proven live 2026-07-31), so on a sharp run compensation moves to the offset
-- loops themselves -- drawn shifted by the bit's own radius at the cut depth,
-- the same amount the machine will shift back (spec 15a fact 7, measured
-- 2026-07-31 on two bits).
function CO.sharp_offset_shift(depth, included_deg)
   return depth * math.tan(CO.half_angle(included_deg))
end

-- Where a sharp run actually DRAWS a band, signed the way the canvas is.
--
-- One function, not a sign inlined at each call site, because the sign is the
-- whole difference between the two sides and two copies of it is two chances to
-- disagree. It also makes the rule testable without a job.
--
-- Off "On", Aspire displaces the tool toward the WASTE by the bit's radius at
-- that pass's cut depth, so the loop is drawn displaced back toward the
-- MATERIAL by the same amount and the tool lands on today's cut line. Inward
-- runs subtract from a negative distance, outward runs from a positive one --
-- which is band_offset_distance's whole job, so it does it here too.
--
-- What comes out is always the same loop: depth is (offset + W)/tan a for BOTH
-- branches of CO.pass_geometry, so offset - depth*tan a is -W identically. The
-- tan cancels; bit angle, cut position, pass count and band index all drop out,
-- and every band of a sharp run is drawn at W from the wall on the material
-- side. Measured over 1740 band x direction cases at 8.3e-17 and pinned in
-- tests/test_geometry.lua -- it is what lets main() skip nesting on a sharp run
-- (there is one loop, drawn n times) and it is what the 2026-08-03 corner-
-- nesting spec's section 7e rests on. Both survive the outward case unchanged.
function CO.sharp_offset_distance(dir, offset, depth, included_deg)
   return CO.band_offset_distance(dir, offset - CO.sharp_offset_shift(depth, included_deg))
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

-- Point the shipped template at one BAND of one chamfer. The replacement is the
-- same length as what it replaces -- 23 characters, 46 UTF-16LE bytes -- so the
-- length prefix, the record and every offset in the file are untouched. That is
-- the same class of edit as the depth patch; inserting or RESIZING a record is
-- what Aspire rejects.
--
-- v1.13.0 rewrites the whole name rather than two digits, because the band
-- suffix moved the separator (see CO.OFFSET_LAYER_PREFIX). The length check
-- below is what makes that safe: if anyone ever edits the prefix to a different
-- length this REFUSES, rather than writing a string the length prefix no longer
-- describes and handing Aspire a corrupt file.
--
-- Only the name we shipped is accepted as a starting point. Patching a template
-- restricted to something else would aim the cut at a layer nobody validated,
-- which is exactly the failure the restriction exists to prevent.
function CO.patch_template_layer(bytes, slot, band)
   if type(bytes) ~= "string" then return nil, "no template bytes" end
   if type(slot) ~= "number" or slot < 1 or slot > 99 or slot % 1 ~= 0 then
      return nil, "slot out of range: " .. tostring(slot)
   end
   if type(band) ~= "number" or band < 1 or band > 9 or band % 1 ~= 0 then
      return nil, "band out of range: " .. tostring(band)
   end
   local want = CO.offset_layer_name(slot, band)
   if #want ~= #CO.TEMPLATE_LAYER then
      return nil, "layer name length changed (" .. #want .. " vs " .. #CO.TEMPLATE_LAYER
                  .. ") - the template cannot be patched in place"
   end
   local needle = utf16le_needle(CO.TEMPLATE_LAYER)
   local s, e = string.find(bytes, needle, 1, true)
   if s == nil then
      return nil, "template is not restricted to '" .. CO.TEMPLATE_LAYER .. "'"
   end
   if string.find(bytes, needle, e + 1, true) ~= nil then
      return nil, "template names '" .. CO.TEMPLATE_LAYER .. "' more than once"
   end
   return bytes:sub(1, s - 1) .. utf16le_needle(want) .. bytes:sub(e + 1)
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

-- Sharp corners (v1.11.0). Two fixed-size fields, patched in memory
-- only for a run that applies the feature -- the depth-patch class of edit
-- (same length, same offsets), which is the class Aspire provably accepts.
-- The file on disk never changes, and a run with the feature off never calls
-- this at all: that is the byte-identical contract, pinned in
-- tests/test_geometry.lua.
-- Both codes are pinned by the Aspire-authored fixture
-- tests/fixtures/mv-inside-sharp.ToolpathTemplate (test_release.lua), not
-- inferred. The allowance field is deliberately NOT patched here: the
-- 2026-07-31 sitting (spec 15) found Aspire LOCKS and discards the Allowance
-- offset while Sharpen Corners is on -- the fixture itself stores 0 there
-- regardless of the bit -- so patching it would be dead code. Compensation
-- for the lost allowance lives in the offset geometry instead: see
-- CO.sharp_offset_distance and its two call sites in main().
-- _ppdCutDirection is deliberately untouched.
local SHARPEN_NEEDLE   = ("_ppdCornerSharpen"):gsub(".", "%0\0")
local ALLOWANCE_NEEDLE = ("_ppdAllowance"):gsub(".", "%0\0")
-- v1.13.0, and it is Aspire's "Sharp external corners". The 2026-08-03 spec
-- (section 3b) argued this one was unnecessary -- that a toolpath rolling
-- around a convex corner at radius r_d passes through the vertex on every
-- position, so the uncut wedge comes to a point for free. The sitting
-- disproved it: with the guide loop provably square at its convex corners
-- (measured in the 2D view), the CUT still came out rounded by about the
-- chamfer width. Whatever Aspire does at an external corner, it is not that.
-- So we ask for the mitre explicitly. Same 1-byte bool as the sharpen flag
-- (tag 02, reads 00 in the shipped template).
local SQUARE_NEEDLE    = ("_ppdSquareCorners"):gsub(".", "%0\0")
-- Both codes are fixture-pinned, not inferred: 1 by
-- tests/fixtures/mv-inside-sharp.ToolpathTemplate, 0 by
-- tests/fixtures/mv-outside.ToolpathTemplate.
local MV_FOR_SIDE = { inside = 1, outside = 0 }

local function find_value_once(bytes, needle, tag, skip_formula)
   local hits, init = {}, 1
   while true do
      local s, e = string.find(bytes, needle, init, true)
      if s == nil then break end
      if not (skip_formula and bytes:sub(e + 1, e + 2) == "F\0") then
         hits[#hits + 1] = e
      end
      init = e + 1
   end
   if #hits ~= 1 then
      return nil, "expected exactly one " .. tag .. " in template, found " .. #hits
   end
   return hits[1] + 5   -- skip the 4-byte tag between name and value (1-based)
end

function CO.find_mv_value_offset(bytes)
   return find_value_once(bytes, MV_NEEDLE, "_ppdProfileType", false)
end

function CO.find_sharpen_offset(bytes)
   return find_value_once(bytes, SHARPEN_NEEDLE, "_ppdCornerSharpen", false)
end

function CO.find_allowance_offset(bytes)
   return find_value_once(bytes, ALLOWANCE_NEEDLE, "_ppdAllowance", true)
end

function CO.find_square_offset(bytes)
   return find_value_once(bytes, SQUARE_NEEDLE, "_ppdSquareCorners", false)
end

function CO.patch_template_sharp(bytes, side)
   -- No default. A side we do not recognise refuses rather than picking one:
   -- the two codes aim the cut at opposite sides of the line, so a silent
   -- fallback here would machine the wrong side of every vector in the job.
   local mv_code = MV_FOR_SIDE[side]
   if mv_code == nil then
      return nil, "sharp corners need Side set to Inside or Outside, not " .. tostring(side)
   end
   local mv_at, mverr = CO.find_mv_value_offset(bytes)
   if mv_at == nil then return nil, mverr end
   local sh_at, sherr = CO.find_sharpen_offset(bytes)
   if sh_at == nil then return nil, sherr end
   -- Both corner treatments, on every sharp run and on BOTH sides. They cover
   -- opposite corners and neither substitutes for the other: sharpening dives
   -- into the internal ones, squaring runs out to the mitre on the external
   -- ones. Not outside-only, because the mechanism does not care which side --
   -- v1.11.0's inside sitting measured leg widths and never zoomed a corner,
   -- so there is no measured inside behaviour being overturned here, only an
   -- unmeasured one. Sitting check B6 settles it.
   local sq_at, sqerr = CO.find_square_offset(bytes)
   if sq_at == nil then return nil, sqerr end
   -- Same-length writes: every offset found above stays valid throughout.
   local out = bytes:sub(1, mv_at - 1) .. string.char(mv_code, 0, 0, 0)
             .. bytes:sub(mv_at + 4)
   out = out:sub(1, sh_at - 1) .. string.char(1) .. out:sub(sh_at + 1)
   out = out:sub(1, sq_at - 1) .. string.char(1) .. out:sub(sq_at + 1)
   return out
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
-- nothing is read from the filename any more — only the six things Aspire
-- bakes into the file that we cannot set ourselves: that it has a cut depth
-- and a start depth we can patch, that it is scoped to our offset layer, that
-- it machines On rather than Outside/Inside, and that it carries the two
-- sharp-corner fields patched per run (Machine Vectors value, Sharpen
-- Corners). Allowance is deliberately not one of them -- Aspire discards it
-- under sharpening (see CO.patch_template_sharp), so nothing requires it.
-- Returns true, or nil + a reason written for the summary box.
function CO.validate_template(bytes, job_units)
   if bytes == nil then
      return nil, "The template file '" .. CO.TEMPLATE_NAME .. "' could not be read."
   end
   local _, derr = CO.find_depth_offset(bytes)
   if derr then
      return nil, "'" .. CO.TEMPLATE_NAME .. "' is not a usable toolpath template - "
                  .. "re-save it from Aspire or VCarve (see Help)."
   end
   -- v1.6.0: a template we cannot aim in Z is as unusable as one we cannot
   -- aim in a layer. Required, not optional -- every Aspire profile template
   -- has one, so this only ever catches a genuinely broken file.
   local _, serr = CO.find_start_depth_offset(bytes)
   if serr then
      return nil, "'" .. CO.TEMPLATE_NAME .. "' has no start depth we can set - "
                  .. "re-save it from Aspire or VCarve (see Help)."
   end
   -- v1.11.0: sharp corners patch more fields per run (three as of v1.13.0,
   -- which added _ppdSquareCorners), so a template missing any of them would
   -- fail at first use of the checkbox instead of here.
   -- Required, not optional -- the shipped template has both, so this only
   -- ever catches a genuinely broken re-save. Allowance is NOT required: R1
   -- dropped the allowance patch (Aspire discards it under sharpening, spec
   -- 15), so a template with no readable allowance offset is still usable.
   local _, mverr2 = CO.find_mv_value_offset(bytes)
   local _, sherr2 = CO.find_sharpen_offset(bytes)
   local _, sqerr2 = CO.find_square_offset(bytes)
   if mverr2 or sherr2 or sqerr2 then
      return nil, "'" .. CO.TEMPLATE_NAME .. "' is missing a setting EdgeBreaker "
                  .. "needs for sharp corners - re-save it from Aspire or VCarve (see Help)."
   end
   -- The restriction is REQUIRED as of v1.4.0: it is what the per-slot patch
   -- rewrites, so an unscoped template has nothing to aim and would cut every
   -- chamfer's offsets at this run's depth.
   local layers, lerr = CO.read_template_layers(bytes)
   if layers == nil then
      return nil, "'" .. CO.TEMPLATE_NAME .. "' is not a usable toolpath template ("
                  .. tostring(lerr) .. ") - re-save it from Aspire or VCarve (see Help)."
   end
   local want = CO.TEMPLATE_LAYER
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
CO.SETTINGS_KEYS = { "units", "mode", "side", "percent", "size", "sharp" }

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
   -- Sharp is unitless and safe to carry (unlike start depth): visible on the
   -- dialog and gated by CO.sharp_applies at run time regardless.
   seed.sharp = (tonumber(saved.sharp) == 1) and 1 or 0
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
                 "start=" .. num(mem.start or 0), "sharp=" .. num(mem.sharp or 0),
                 "tool=" .. tool }
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
      elseif k == "sharp" then mem.sharp = tonumber(v)
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

-- The pass suffix goes AFTER the marker, so the marker parser (which finds the
-- head and then two digits and a bracket) is untouched and every pass of a
-- chamfer carries the same slot -- which is what makes one rebuild take the
-- whole set, including bands a bigger bit no longer needs.
-- One pass gets NO suffix: a single-pass chamfer's name has to stay exactly what
-- v1.12.0 wrote, or an existing job's chamfer stops being recognized.
function CO.toolpath_name(size, suffix, slot, band, passes)
   local base = string.format("Chamfer %g %s %s", size, suffix, CO.toolpath_marker(slot))
   if passes == nil or passes <= 1 then return base end
   return string.format("%s pass %d of %d", base, band, passes)
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

-- The Chamfer dropdown, as one string for the dialog: eight |-separated fields
-- "slot|label|relation|size|mode|side|percent|sharp" per record, records joined
-- by ";". The relation badges each entry against the CURRENT selection, so
-- changing chamfer in the dialog re-colours the banner without another trip
-- into Lua; the five seeds let it re-seed the form at the same moment. A
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
      local size, mode, side, percent, sharp = "", "", "", "", ""
      if c.memory then
         size    = num(c.memory.size or 0)
         mode    = safe_label(c.memory.mode or "")
         side    = safe_label(c.memory.side or "")
         percent = num(c.memory.percent or 0)
         sharp   = num(c.memory.sharp or 0)
      end
      out[#out + 1] = string.format("%d|%s|%s|%s|%s|%s|%s|%s",
                                    c.slot, label, relation, size, mode, side, percent, sharp)
   end
   if next_slot ~= nil then
      out[#out + 1] = string.format("%d|New chamfer (%d)|new|||||", next_slot, next_slot)
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

-- One offset layer PER BAND, per chamfer (v1.13.0). The slot number is padded so
-- the layers sort in Aspire's panel; everything the user reads says "Chamfer 1",
-- not 01.
--
-- The " - " separator is gone on purpose, and it is not cosmetic. The template
-- stores its layer restriction as a length-prefixed string and we may only
-- overwrite it IN PLACE -- Aspire rejects a resized record. Dropping the three
-- separator characters for " " pays for the "-k" suffix exactly, so
-- 'EdgeBreaker Offset 01-1' is the same 23 characters as the
-- 'EdgeBreaker - Offset 01' the shipped template was authored with. That is the
-- whole reason this feature needed no new template file.
CO.OFFSET_LAYER_PREFIX = "EdgeBreaker Offset "        -- v1.13.0, banded
CO.V112_LAYER_PREFIX   = "EdgeBreaker - Offset "      -- v1.5.0-1.12.0, recognized
CO.OLD_LAYER_PREFIX    = "ChamferOffset - Offset "    -- v1.4.x, recognized for adoption
CO.LEGACY_OFFSET_LAYER = "ChamferOffset - Offset"     -- pre-1.4.0 unnumbered, never adopted

-- What the template file on disk is restricted to. Unchanged since v1.5.0, and
-- deliberately NOT derived from the prefix above: it describes a file we do not
-- write, and the README's re-save instructions quote it.
CO.TEMPLATE_LAYER = "EdgeBreaker - Offset 01"

function CO.offset_layer_name(slot, band)
   return string.format("%s%02d-%d", CO.OFFSET_LAYER_PREFIX, slot, band or 1)
end

-- One writer for "which layers did this run touch". A multi-pass run makes one
-- layer per band, and naming only band 1 sends the operator looking for their
-- geometry on one of three layers -- which is exactly what the success report
-- did until 2026-08-03. Quoted, because both callers quote.
function CO.offset_layer_phrase(slot, n_passes)
   local first = "'" .. CO.offset_layer_name(slot, 1) .. "'"
   if (n_passes or 1) <= 1 then return first end
   return first .. " to '" .. CO.offset_layer_name(slot, n_passes) .. "'"
end

-- nil for anything that is not one of ours, INCLUDING the unnumbered pre-1.4.0
-- layer: that one is reported to the user, never wiped or rebuilt.
-- ONE parser for every name generation; `banded` says whether to expect a band.
local function slot_from_prefixed_layer(name, prefix, banded)
   if type(name) ~= "string" then return nil end
   if name:sub(1, #prefix) ~= prefix then return nil end
   local tail = name:sub(#prefix + 1)
   local digits, band
   if banded then digits, band = tail:match("^(%d%d)%-(%d)$")
   else digits = tail:match("^(%d%d)$") end
   if digits == nil then return nil end
   local n = tonumber(digits)
   if n < 1 or n > 99 then return nil end
   if not banded then return n end
   local k = tonumber(band)
   -- 1..9, not 1..MAX_PASSES: a layer from a build with a higher ceiling is
   -- still OURS, and failing to recognize it would leave it as user geometry
   -- for the next run to offset and cut.
   if k < 1 then return nil end
   return n, k
end

-- Returns slot, band. Band is nil for a v1.12.0-and-earlier layer -- that is how
-- a caller can tell the two generations apart, e.g. to migrate the old form
-- away (not yet wired to anything; that is Task 5's job).
function CO.slot_from_layer_name(name)
   local n, k = slot_from_prefixed_layer(name, CO.OFFSET_LAYER_PREFIX, true)
   if n ~= nil then return n, k end
   return slot_from_prefixed_layer(name, CO.V112_LAYER_PREFIX, false)
end

function CO.v112_slot_from_layer_name(name)
   return slot_from_prefixed_layer(name, CO.V112_LAYER_PREFIX, false)
end

function CO.old_slot_from_layer_name(name)
   return slot_from_prefixed_layer(name, CO.OLD_LAYER_PREFIX, false)
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

-- The measured screen size, in its own file beside the settings. Its own file
-- on purpose: CO.save_settings writes exactly the keys in CO.SETTINGS_KEYS from
-- the table its caller passes, so a screen size stored there would be wiped by
-- every ordinary save unless every call site carried it. Deleting this file is
-- also the whole remedy if a value ever gets stuck -- the next run measures again.
function CO.screen_path()
   return settings_path_for("EdgeBreaker-screen.txt")
end

-- "1920x1040" -> 1920, 1040, false. "1920x1040 off" -> 1920, 1040, true.
-- These are the only two shapes either dialog ever sends. The numbers are
-- always the PRIMARY monitor's -- the 2026-07-30 ScreenProbe sitting proved
-- Trident reports the primary no matter which monitor the window is on -- so a
-- page that can tell it is NOT on the primary (window.screenLeft, which the
-- same sitting proved live and truthful) appends " off" instead of sending
-- numbers it cannot get. Anything else is nothing at all: nonsense is
-- discarded here so it can never reach the file.
function CO.parse_screen_field(text)
   if type(text) ~= "string" then return nil end
   local w, h = text:match("^%s*(%d+)%s*[xX]%s*(%d+)%s*$")
   local off = false
   if w == nil then
      w, h = text:match("^%s*(%d+)%s*[xX]%s*(%d+)%s+off%s*$")
      off = true
   end
   if w == nil then return nil end
   w, h = tonumber(w), tonumber(h)
   if not CO.believable_screen(w, h) then return nil end
   return w, h, off
end

-- "1796x868|1796x868" -> 1796, 868, 1796, 868: the page's own client box as it
-- is NOW, then as it was at load. Both are CLIENT boxes, not outer sizes -- see
-- CO.remember_screen for why, and for the arithmetic that turns the pair back
-- into the outer size HTML_Dialog wants.
--
-- "1800x1000" on its own is the pre-fix shape, kept working: a page sending one
-- pair is reporting an outer size, so the load box comes back nil.
--
-- Those two shapes and nothing else. The " off" suffix belongs to the Screen
-- field and a WinSize carrying it is a page that has gone wrong. Deliberately
-- NOT lenient about a garbled trailer either: falling back to "the first pair
-- is the outer size" would store a client box as an outer one, and the window
-- would then lose the height of its own frame on every single run.
function CO.parse_window_field(text)
   if type(text) ~= "string" then return nil end
   local w, h, lw, lh =
      text:match("^%s*(%d+)%s*[xX]%s*(%d+)%s*|%s*(%d+)%s*[xX]%s*(%d+)%s*$")
   if w == nil then
      w, h = text:match("^%s*(%d+)%s*[xX]%s*(%d+)%s*$")
   end
   if w == nil then return nil end
   w, h = tonumber(w), tonumber(h)
   if not CO.believable_window(w, h) then return nil end
   if lw == nil then return w, h end
   lw, lh = tonumber(lw), tonumber(lh)
   if not CO.believable_window(lw, lh) then return nil end
   return w, h, lw, lh
end

-- The store is a TABLE now, not four positional returns -- it had already
-- reached four and v1.12.0 adds two slots. Shape:
--   .screen_w/.screen_h  the measured PRIMARY screen, in Trident's unit
--   .everoff             has any window of ours EVER reported itself off the
--                        primary? Sticky, never cleared: it is what decides
--                        whether this machine pays for the blink.
--   .win_on / .win_off   {w,h} the operator left the dialog at, per slot, or nil
--
-- Pure, so the whole file format is tested offline. Anything unbelievable is
-- discarded rather than repaired, and an unbelievable MEASUREMENT voids the
-- whole store -- without it we cannot clamp, and a remembered size with nothing
-- to clamp against is how a window ends up off the screen.
function CO.parse_screen_store(text)
   if type(text) ~= "string" then return nil end
   local t = CO.parse_settings(text)
   if t == nil then return nil end
   if not CO.believable_screen(t.screenw, t.screenh) then return nil end
   local s = { screen_w = tonumber(t.screenw), screen_h = tonumber(t.screenh) }
   -- A pre-v1.12.0 file's offprimary=1 seeds the sticky flag, so a machine that
   -- already knows it has a second monitor does not have to learn it twice.
   -- `monitors` is read by nothing now and simply falls away on the next write.
   s.everoff = (t.everoff == "1") or (t.offprimary == "1")
   if CO.believable_window(t.win_on_w, t.win_on_h) then
      s.win_on = { tonumber(t.win_on_w), tonumber(t.win_on_h) }
   end
   if CO.believable_window(t.win_off_w, t.win_off_h) then
      s.win_off = { tonumber(t.win_off_w), tonumber(t.win_off_h) }
   end
   return s
end

-- The inverse. Returns nil for anything parse_screen_store would refuse, so we
-- can never write a file we would then throw away on read.
function CO.format_screen_store(store)
   if type(store) ~= "table" then return nil end
   if not CO.believable_screen(store.screen_w, store.screen_h) then return nil end
   local out = { "# EdgeBreaker window sizes - safe to delete" }
   out[#out+1] = string.format("screenw=%d", math.floor(tonumber(store.screen_w)))
   out[#out+1] = string.format("screenh=%d", math.floor(tonumber(store.screen_h)))
   out[#out+1] = string.format("everoff=%d", store.everoff and 1 or 0)
   local function slot(key, pair)
      if type(pair) ~= "table" then return end
      if not CO.believable_window(pair[1], pair[2]) then return end
      out[#out+1] = string.format("%s_w=%d", key, math.floor(tonumber(pair[1])))
      out[#out+1] = string.format("%s_h=%d", key, math.floor(tonumber(pair[2])))
   end
   slot("win_on", store.win_on)
   slot("win_off", store.win_off)
   return table.concat(out, "\n") .. "\n"
end

-- Both halves are best-effort and silent, exactly like the settings pair: a
-- locked, missing or unreadable file must never interrupt a run. Sizing is a
-- convenience -- it can make the dialog awkward, it can never make a wrong cut.
function CO.load_screen()
   local path = CO.screen_path()
   if path == nil then return nil end
   local ok, store = pcall(function()
      local f = io.open(path, "r")
      if f == nil then return nil end
      local text = f:read("*a"); f:close()
      return CO.parse_screen_store(text)
   end)
   if ok then return store end
   return nil
end

function CO.save_screen(store)
   local text = CO.format_screen_store(store)
   if text == nil then return false end
   local path = CO.screen_path()
   if path == nil then return false end
   return (pcall(function()
      local f = assert(io.open(path, "w"))
      f:write(text)
      f:close()
   end))
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

-- Which of this slot's old layers a rebuild deletes outright. Pure, so the rule
-- can be tested without a job -- and it is the rule worth testing, because a
-- false negative leaves orange vectors on the canvas that are no longer cut and
-- look exactly like ones that are.
--
-- Deleted: this slot's v1.12.0-and-earlier unbanded layer (always -- we are
-- rebuilding this slot and nothing else can claim it), its v1.4.x layer when
-- adopting, and any of its band layers past the new pass count. Bands 1..n are
-- NOT deleted; they are emptied and reused below.
function CO.doomed_layer(name, slot, n, migrate)
   if type(name) ~= "string" then return false end
   if migrate and CO.old_slot_from_layer_name(name) == slot then return true end
   if CO.v112_slot_from_layer_name(name) == slot then return true end
   local s, k = CO.slot_from_layer_name(name)
   return s == slot and k ~= nil and k > n
end

-- Get-or-create THIS chamfer's n output layers and clear stale offsets from the
-- previous run. Wiping is safe because partition_loops has already dropped
-- anything selected on these layers from the input, and they are documented as
-- gadget-owned (wiped every run) -- nothing durable belongs here. Other
-- chamfers' layers are never touched.
--
-- Layers are found by ENUMERATION, never by GetLayerWithName: that call CREATES
-- the layer when it is missing, and we are here to remove some of them.
function CO.sdk_prepare_layers(job, slot, n, migrate)
   local old_left = false
   local doomed = {}
   local lpos = job.LayerManager:GetHeadPosition()
   while lpos ~= nil do
      local layer
      layer, lpos = job.LayerManager:GetNext(lpos)
      local ok, name = pcall(function() return layer.Name end)
      if ok and CO.doomed_layer(name, slot, n, migrate) then
         doomed[#doomed + 1] = layer
      end
   end
   for _, layer in ipairs(doomed) do
      local objs = {}
      local pos = layer:GetHeadPosition()
      while pos ~= nil do
         local obj
         obj, pos = layer:GetNext(pos)
         objs[#objs + 1] = obj
      end
      for _, obj in ipairs(objs) do layer:RemoveObject(obj) end
      -- RemoveLayer is documented but has never been run here, so the emptied
      -- layer is the guaranteed part and its disappearance is not.
      if not pcall(function() job.LayerManager:RemoveLayer(layer) end) then
         old_left = true
      end
   end
   local layers = {}
   for k = 1, n do
      local layer = job.LayerManager:GetLayerWithName(CO.offset_layer_name(slot, k))
      local objs = {}
      local pos = layer:GetHeadPosition()
      while pos ~= nil do
         local obj
         obj, pos = layer:GetNext(pos)
         objs[#objs + 1] = obj
      end
      for _, obj in ipairs(objs) do layer:RemoveObject(obj) end
      -- Orange, not magenta: Vectric highlights selected vectors and toolpaths
      -- in magenta, so an offset drawn in it competes with Aspire's own UI state
      -- and "check the offsets before you cut" gets harder to do (live
      -- 2026-07-26). Blue and cyan were tried and rejected: blue reads as black
      -- at thin line widths, cyan washes out on the white background.
      layer:SetColour(0x008CFF)   -- orange (BGR)
      layers[k] = layer
   end
   return layers, old_left
end

-- Creating/drawing onto an 'EdgeBreaker Offset NN-K' layer leaves it as Aspire's ACTIVE
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
--
-- sharp_dist (v1.11.0): nil on a normal run. On a sharp run it carries the
-- shifted offset distance, and the result is passed through Aspire's
-- MakeOffsetsSquare before being returned -- a rounded loop cuts rounded
-- corners (live fact 11), so a sharp run refuses rather than draw one
-- silently. dist is ALWAYS the plain, unshifted distance, offset first purely
-- as a viability probe -- its group is thrown away -- and only when that probe
-- comes back non-empty does the real sharp offset at sharp_dist happen. That
-- ordering exists so the too-narrow safety net cannot go structurally silent
-- (Finding 1, 2026-07-31 review).
--
-- EITHER can collapse, and which one does is the side (2026-08-03). The sharp
-- loop is always drawn W toward the MATERIAL: outside a pocket wall on an
-- inside run, where nothing can collapse it -- but INTO the shape on an outside
-- run, where a stem narrower than two chamfers has no top edge left to draw.
-- That is a real limit of the chamfer, not a fault, so an empty sharp offset is
-- the same bare-nil "too narrow, skip it and count it" answer as an empty
-- probe. Reporting it as an internal failure (which it was until the outward
-- case existed) would abort a whole letter set over one thin stem.
-- The half of an offset that does not care where the source came from: run the
-- 4-arg Offset and interpret the result. Shared by sdk_offset_loop (source = a
-- fresh copy of a document object) and sdk_offset_group (source = the finishing
-- pass's group), so the two can never drift apart about what an empty offset
-- MEANS. Tri-state, and the distinction is the whole contract: bare nil is
-- "too narrow to chamfer, skip this shape and count it", nil + message is "an
-- SDK call actually failed, stop the run".
local function offset_and_check(src, dist)
   local g = src:Offset(dist, math.abs(dist), 1, true)
   if g == nil then return nil end
   -- A zero count is the "too narrow" answer; an unreadable one is a wrong
   -- property name (luabind returns nil rather than raising) -- reporting that
   -- as a geometry problem would send the next reader at the chamfer size
   -- instead of the property name.
   local n = g.Count
   if type(n) ~= "number" then
      return nil, "could not read the offset result (Count)"
   end
   if n < 1 then return nil end
   return g
end

function CO.sdk_offset_loop(job, obj, dist, sharp_dist)
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
      local g, gerr = offset_and_check(src, dist)
      if g == nil then return nil, gerr end
      if sharp_dist == nil then return g end
      -- The probe above passed (this loop is wide enough at the normal
      -- distance), so now do the real sharp offset at the shifted distance
      -- and square its corners. An empty result here is the too-narrow answer
      -- again, not a failure: on an outside run this distance points into the
      -- shape and a narrow one really can have nothing left to draw.
      local sg, serr = offset_and_check(src, sharp_dist)
      if sg == nil then return nil, serr end
      -- Signature, from the luabind overload error raised by every wrong arity
      -- (OffsetSquareProbe, 2026-07-31):
      --    bool MakeOffsetsSquare(ContourGroup*, double, bool, double)
      --
      -- THE BOOL IS THE OFFSET'S DIRECTION, not a squaring switch: true means
      -- "I offset outward", false means "I offset inward". Measured by
      -- SquareProbe on 2026-08-03, seven trials on one notched rectangle
      -- (8 corners: an inward offset rounds the 2 reflex ones, an outward
      -- offset rounds the other 6):
      --
      --    inward  + false -> 8 spans, 0 arcs   squared
      --    inward  + true  -> 10 spans, 2 arcs  UNTOUCHED
      --    outward + true  -> 8 spans, 0 arcs   squared
      --    outward + false -> rounded           (2026-07-31, 4 arcs)
      --
      -- Tell it the truth and it squares; lie to it and it does nothing and
      -- still returns true. That is why v1.11.0 shipping `false` squared
      -- nothing -- an INSIDE run's sharp distance is +W, i.e. OUTWARD -- and
      -- why flipping it to a hardcoded `true` looked like the whole answer for
      -- three months. It was, for as long as every run was an inside one.
      -- Outside runs are the first inward offsets this gadget has ever made.
      --
      -- Signing the first argument instead was tried live the same night and
      -- changed nothing: the magnitude is right, the direction rides on the
      -- bool. Third argument is a limit and stays a magnitude.
      -- Returns a plain bool, so the userdata branch below is dead in practice;
      -- it stays because the guard costs nothing and a future Aspire could
      -- return the group instead. A false return is a real failure: refuse,
      -- never a silent round-cornered cut.
      -- (A false RETURN is a failure of the call. It cannot report "squared
      -- nothing" -- that is what the direction bool is for.)
      local sq = sg:MakeOffsetsSquare(math.abs(sharp_dist), sharp_dist > 0,
                                      math.abs(sharp_dist) * 2)
      if type(sq) == "userdata" or type(sq) == "table" then
         local sqn = sq.Count
         if type(sqn) == "number" and sqn >= 1 then
            sg = sq
         else
            return nil, "could not square the offset corners (MakeOffsetsSquare gave "
                .. "an unreadable result)"
         end
      elseif sq == true then
         -- kept sg: post-process worked in place
      else
         return nil, "could not square the offset corners (MakeOffsetsSquare gave "
             .. tostring(sq) .. ")"
      end
      return sg
   end)
   if not ok then return nil, tostring(res) end
   return res, err
end

-- Offset a group we already hold, rather than a document object. This is what
-- makes the relief passes nest: a relief loop is cut from the FINISHING pass's
-- loop, so it is literally "the finishing path, backed off" and physically
-- cannot reach past it. Offsetting each band from the original vector instead
-- is what left a ridge standing at every mitred corner in v1.13.0 -- see the
-- 2026-08-03 corner-nesting spec.
--
-- No selection, no copy: the group handed in is already a detached copy from
-- CreateCopyOfSelectedContours, which is why this is cheap and deposits
-- nothing in the document.
--
-- No sharp path here yet. Whether a sharpened corner can ride on a multi-pass
-- run at all is an OPEN design question as of 2026-08-03 -- Aspire refuses to
-- sharpen any pass deeper than the tool's cutting-edge depth, and what
-- MakeOffsetsSquare does to a NESTED corner has never been modelled. Do not
-- read the absence of a sharp branch as a decision that there will never be
-- one.
--
-- ContourGroup:Offset returning a ContourGroup is DEDUCED, not attested: the
-- MakeOffsetsSquare signature recorded above is called as a method on the
-- result of src:Offset(...), so the result is a ContourGroup and :Offset is
-- available on it. First thing to verify at the sitting.
function CO.sdk_offset_group(g, dist)
   local ok, res, err = pcall(offset_and_check, g, dist)
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
-- sdk_prepare_layers). DeleteToolpath(tp) with an OBJECT argument is
-- live-proven on Aspire 12.5 (mastercam-tooling session 054 probe); an
-- unreadable Name just means that toolpath is left alone, and so does one
-- marked for a different slot. A non-number slot raises rather than matching
-- anything.
-- include_old (v1.5.0) additionally takes the same slot's v1.4.x-marked
-- toolpath, the toolpath half of sdk_prepare_layers' migration and gated the
-- same way: one chamfer must not end up with a toolpath under each generation.
function CO.sdk_delete_marked_toolpaths(slot, include_old)
   -- A nil slot would make the ownership test below read `nil == nil`, which is
   -- TRUE for every unmarked and every pre-1.4.0 toolpath -- exactly the ones
   -- the gadget must never delete. Fail loudly instead, the way
   -- sdk_prepare_layers already does when its slot is nil.
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

-- Every pass of a chamfer carries the same slot marker, so this returns the
-- whole set in list order -- which is cut order, because the passes are created
-- top-down and new toolpaths append to the tail.
--
-- The WHOLE walk is pcall'd, not just the tp.Name read. Guarding only the read
-- was the first version and it was wrong: ToolpathManager(), GetHeadPosition()
-- and GetNext() can all throw too, and nothing above catches -- not
-- sdk_write_memory_all, not main(), which has no top-level pcall. This is
-- best-effort bookkeeping that runs AFTER the toolpaths are built, so an Aspire
-- throw here must never abort the run. Failure returns {}, never nil: the caller
-- does #tps on it.
function CO.sdk_find_toolpaths_by_slot(slot)
   local ok, found = pcall(function()
      local out = {}
      local tpm = ToolpathManager()
      local pos = tpm:GetHeadPosition()
      while pos ~= nil do
         local tp
         tp, pos = tpm:GetNext(pos)
         local okn, name = pcall(function() return tp.Name end)
         if okn and CO.slot_from_toolpath_name(name) == slot then out[#out + 1] = tp end
      end
      return out
   end)
   if ok then return found end
   return {}
end

-- Write the chamfer's memory to every one of its passes. Identical content, so
-- the read side can take whichever it finds first; writing all of them means an
-- operator who deletes one pass by hand still has a chamfer the gadget
-- recognizes. Best-effort as before: a chamfer with no memory is v1.4.0
-- behaviour, not a broken cut.
function CO.sdk_write_memory_all(slot, memory)
   local tps = CO.sdk_find_toolpaths_by_slot(slot)
   if #tps == 0 then return false end
   local all = true
   for _, tp in ipairs(tps) do
      if not CO.sdk_write_memory(tp, memory) then all = false end
   end
   return all
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
-- The whole per-run patch set, pure so the off path is testable offline:
-- with sharp nil/false the output is BYTE-IDENTICAL to what v1.10.x
-- produced (spec 9's contract, pinned in tests/test_geometry.lua). A chamfer
-- that never ticks the box cannot change in any way.
--
-- `sharp` carries the SIDE from 2026-08-03, not a bare yes: "inside" and
-- "outside" write different Machine Vectors codes, and nil is still off. A
-- caller that passes true rather than a side now gets a refusal instead of an
-- inside cut on an outside chamfer.
function CO.patch_template_run(bytes, depth, start, slot, band, sharp)
   local patched, err = CO.patch_template_depth(bytes, depth)
   if patched == nil then return nil, err end
   patched, err = CO.patch_template_start_depth(patched, start or 0)
   if patched == nil then return nil, err end
   patched, err = CO.patch_template_layer(patched, slot, band)
   if patched == nil then return nil, err end
   if sharp then
      patched, err = CO.patch_template_sharp(patched, sharp)
      if patched == nil then return nil, err end
   end
   return patched
end

function CO.sdk_apply_template(dir, filename, depth, start, slot, band, new_name, tool, sharp)
   local src = dir .. "\\" .. filename
   local f = io.open(src, "rb")
   if f == nil then return nil, "cannot read template: " .. src end
   local bytes = f:read("*a"); f:close()
   local patched, perr = CO.patch_template_run(bytes, depth, start, slot, band, sharp)
   if patched == nil then return nil, perr .. " (" .. filename .. ")" end
   -- Read the restriction back out of the bytes we are about to hand Aspire.
   -- A template aimed at the wrong layer cuts the wrong vectors at the wrong
   -- depth without complaining, so this is checked, never assumed.
   local want = CO.offset_layer_name(slot, band)
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
      return nil, "The patched template did not load (Count unchanged)"
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
         "\n\nSome of EdgeBreaker's files are missing. Install EdgeBreaker.vgadget"
         .. " again, then restart Aspire or VCarve.")
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
         .. CO.OFFSET_LAYER_PREFIX .. "NN-K'):\n" .. tostring(layer_fps)
         .. "\n\nNothing was changed. Please report this message.")
      return false
   end
   local kept, skipped_own, bbox_unknown = CO.partition_loops(raw_loops, layer_fps, 1e-6)
   if layer_unknown > 0 or bbox_unknown > 0 then
      DisplayMessageBox(string.format("EdgeBreaker couldn't compare %d vector(s) against its "
         .. "own offset layers ('%sNN-K'), so it can't safely continue (those layers are wiped "
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
   -- Physical pixels, NOT scaled by Windows DPI -- the stylesheet is px-only for
   -- exactly that reason, so the dialog is the same block of pixels on every
   -- machine. Which makes the size a per-SCREEN choice, and the screen is
   -- something only a page can measure: see CO.sdk_ask_page. The blink fires
   -- once on a machine we have never sized, and after that only on a machine
   -- that has ever reported itself off the primary -- a two-monitor machine
   -- where Aspire always sits on the primary never blinks at all, because the
   -- setup dialog reports its own screen (and now its own window size) on the
   -- way out.
   local store = CO.load_screen()
   local screen_w = store ~= nil and store.screen_w or nil
   local screen_h = store ~= nil and store.screen_h or nil
   local off = false

   -- The blink, and the whole decision about whether to pay for it. It answers
   -- ONE question -- is this run on the primary? -- and the machine has to have
   -- earned it: either we have never sized this machine (in which case this IS
   -- the measuring run, and its answer sizes this very run), or something of
   -- ours has reported itself off the primary before.
   --
   -- A machine that has only ever seen one monitor pays NOTHING: no blink, no
   -- spawn, no delay. That is v1.10.5's principle, and keeping it is why the
   -- flag is sticky rather than a live count -- nothing asks Windows any more.
   if store == nil then
      local w, h, o = CO.sdk_ask_page(gadget_dir)
      if w ~= nil then
         screen_w, screen_h, off = w, h, o and true or false
         pcall(function()
            CO.save_screen({ screen_w = w, screen_h = h, everoff = off })
         end)
      end
   elseif store.everoff then
      local _, _, o = CO.sdk_ask_page(gadget_dir)
      off = o and true or false
   end

   -- Which slot this run reads. Written as a plain if rather than `off and
   -- store.win_off or store.win_on`, because that idiom silently falls through
   -- to win_on whenever win_off is nil -- which is exactly the first run on a
   -- second monitor, the case this whole feature exists for.
   local rem
   if store ~= nil then
      if off then rem = store.win_off else rem = store.win_on end
   end

   -- Stashed for show_message, so the post-run report fits the same monitor.
   -- Off the primary we know nothing about this screen, so we vouch for nothing.
   CO.RUN_SCREEN = nil
   if not off and screen_w ~= nil then CO.RUN_SCREEN = { screen_w, screen_h } end

   local win_w, win_h = CO.window_size(rem, screen_w, screen_h, off)
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
         body = "EdgeBreaker couldn't open the tool picker, so it can't "
             .. "ask which bit to use.\n\nPlease report this message.",
         plain = "EdgeBreaker couldn't open the tool picker, so it can't "
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
   dlg:AddTextField("Sharp", tostring(seed.sharp or 0))
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
   -- Seeded empty; the page fills it in with the real screen size after Aspire's
   -- own field injection runs, and CO.remember_screen reads it back below.
   dlg:AddTextField("Screen", "")
   -- Seeded empty, same as Screen: the page fills it in after Aspire's own
   -- field injection runs, and CO.remember_screen reads it back below.
   dlg:AddTextField("WinSize", "")

   -- Remember the screen and the window size whichever way this went. A
   -- cancelled run is still a run that told us both, which is why the blink
   -- never has to appear more than once on a machine that stays on one monitor.
   local pressed_ok = dlg:ShowDialog()
   -- win_w/win_h go along because the page can only report its own client box:
   -- the size we ASKED for is the other half of the frame arithmetic.
   CO.remember_screen(dlg, win_w, win_h)
   if not pressed_ok then return false end         -- user cancelled

   -- The cut is built from the bit the picker is holding when OK is pressed,
   -- never from whatever the preview happened to draw. Same sequence main() has
   -- always run; only the dialog it reads from has changed.
   local ok_tool, tool = pcall(function() return dlg:GetTool("ToolChooseButton") end)
   if not ok_tool or tool == nil then
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Nothing was changed",
         body = "Pick a bit first - the Choose bit button is at the top right."
             .. "\n\nIf the Select button stayed GREYED with a bit highlighted, that "
             .. "bit has no feeds and speeds for the machine shown at the top of that "
             .. "dialog. Press Copy under 'Copy Settings From', then Apply.",
         plain = "Pick a bit first - the Choose bit button is at the top right."
             .. "\n\nNothing was changed.\n\n"
             .. "If the Select button stayed GREYED with a bit highlighted, that bit has "
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

   -- Sharp corners: read nil-tolerantly, same shape as KindOut -- a
   -- dialog file that never sets it must degrade to off, never break the run.
   local sharp = 0
   local ok_sharp, sharp_read = pcall(function() return dlg:GetTextField("Sharp") end)
   if ok_sharp and tonumber(sharp_read) == 1 then sharp = 1 end

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
                      side = side, percent = tonumber(percent), size = size,
                      sharp = sharp })

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
   -- Measured on the INPUT loops, before anything is offset, because the sharp
   -- distance is what gets drawn and so sharp_run has to be settled first.
   --
   -- Safe, and the reason is containment (spec section 3d). The only skip that
   -- could change the answer is a depth-0 loop collapsing while a depth-1 loop
   -- inside it SURVIVES -- the survivor would become outermost in the drawn set
   -- and Aspire would aim the wrong way at it. A loop collapses when its largest
   -- inscribed circle is smaller than the offset distance; a contained loop's is
   -- no bigger than its container's; both are offset by the same distance. So
   -- the inner one always collapses first, and the dangerous case cannot arise.
   local depths = CO.nesting_depths(loops)
   -- Rebuilding an ADOPTED v1.4.x chamfer migrates it: this run replaces its
   -- layer and its toolpath with the EdgeBreaker-named pair, so the old ones
   -- have to go with it or the number owns two of each.
   local migrating = (by_slot[slot] ~= nil and by_slot[slot].origin == "old")
   local n_passes = s.passes or 1
   -- Two gates, computed once and reused at the offset site below and at the
   -- template-patch call further down -- one answer, not two chances to
   -- disagree. sharp_ok is the box and the depth; sharp_nesting_ok is whether
   -- our direction for every loop matches what Aspire's nesting will do to it
   -- once Machine Vectors leaves "On" (spec section 3a).
   local sharp_ok = CO.sharp_applies(sharp, s.d, r.d_max)
   local sharp_dir, sharp_why = nil, nil
   if sharp_ok then sharp_dir, sharp_why = CO.sharp_nesting_ok(dirs, depths) end
   local sharp_run = sharp_ok and sharp_dir ~= nil
   -- The template patch needs to know WHICH side, because the two write
   -- different Machine Vectors codes. It comes from the GATE's answer, mapped
   -- into Aspire's words -- NEVER from `side`. On a nested selection the forced
   -- side is precisely the direction Aspire will not use, which is the defect
   -- this gate closes; and a run that is not sharpening can never hand the
   -- patcher a side and turn sharpening on behind the gate's back.
   local sharp_side = sharp_run and ((sharp_dir == "outward") and "outside" or "inside") or nil
   -- Asked for and not given. Only when the box was actually ticked AND shallow
   -- enough: a box the dialog already greyed and unticked for depth has been
   -- explained on the dialog, and saying it a second time here is worse than
   -- saying it once.
   local sharp_refused = (sharp_ok and not sharp_run) and CO.sharp_nesting_note(sharp_why) or nil
   local ok_layer, layers, old_layer_left =
      pcall(CO.sdk_prepare_layers, job, slot, n_passes, migrating)
   if not ok_layer then
      -- One layer per band now, so an error naming only band 1 points at the
      -- wrong layer on every multi-pass run.
      local layer_word = (n_passes > 1) and "Layers" or "Layer"
      local layer_names = CO.offset_layer_phrase(slot, n_passes)
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = (n_passes > 1) and "Couldn't prepare the offset layers"
                    or "Couldn't prepare the offset layer",
         body = layer_word .. " " .. layer_names .. ":\n" .. tostring(layers),
         plain = "Could not prepare " .. layer_word:lower() .. " " .. layer_names
             .. ":\n" .. tostring(layers),
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
   -- Phase 1: work out which shapes survive EVERY band before drawing any of
   -- them. Upper bands offset INTO the part, so a narrow feature can collapse on
   -- band 1 while band 4 is fine -- which would leave a chamfer on part of its
   -- face and nothing on the rest. Skip the shape whole and count it in the
   -- existing too-narrow note. This costs only time: the finishing band's probe
   -- (sdk_offset_loop) works on a CreateCopyOfSelectedContours copy, and every
   -- relief band's probe (sdk_offset_group) offsets that same in-memory group --
   -- neither deposits anything in the document.
   local n_out, n_in, skipped_narrow, drawn, built_fps = 0, 0, 0, {}, {}
   local viable = {}                      -- ordered { i, dir, groups = {1..n} }
   for i, loop in ipairs(loops) do
      local groups, dead, oerr = {}, false, nil
      -- The finishing band FIRST, and from the document object -- it is the one
      -- that shapes the chamfer face, so every relief band is cut from it. Its
      -- corners are then the corners of the whole chamfer, and a relief band,
      -- being that loop backed off, physically cannot reach past it. Offsetting
      -- each band from the original vector instead is v1.13.0's hook: at a
      -- corner the finishing band mitres and under-reaches while a shallower
      -- band rounds and over-reaches, and the material between them stands.
      local pg_n = CO.pass_geometry(n_passes, n_passes, r.W, s.g, r.a)
      local dist_n = CO.band_offset_distance(dirs[i], pg_n.offset)
      -- sharp runs shift the drawn loop against Aspire's own off-"On"
      -- displacement, which it computes from THAT pass's cut depth -- so the
      -- shift is per band, not per chamfer (proved live 2026-07-31), which is
      -- why this uses pg_n.depth and not the whole chamfer's s.d. At one pass
      -- the two are the same number. dirs[i] puts the sign on: the loop goes
      -- toward the material either way, which is outside a pocket wall and
      -- inside an outline.
      -- sdk_offset_loop still gets the plain dist as its viability probe.
      local sharp_dist = sharp_run
         and CO.sharp_offset_distance(dirs[i], pg_n.offset, pg_n.depth, angle) or nil
      local group
      group, oerr = CO.sdk_offset_loop(job, loop.obj, dist_n, sharp_dist)
      if group ~= nil then
         groups[n_passes] = group
         -- Then the relief bands, each from the finishing group. Order within
         -- this loop does not matter -- every one is cut from the same source --
         -- but they must ALL be built before phase 2 draws anything, because
         -- handing a group to CreateCadGroup and then offsetting it again is
         -- untested and there is no reason to risk it.
         --
         -- NOT on a sharp run -- where there is nothing to nest, because every
         -- band is already the SAME loop. A sharpened band is drawn at
         -- CO.sharp_offset_distance(dir, offset_k, depth_k), and depth_k is
         -- (offset_k + W)/tan a on BOTH branches of pass_geometry, so the
         -- inner term is offset_k - (offset_k + W) = -W whatever the band. The
         -- tan cancels exactly and every band lands W from the wall on the
         -- material side -- any bit angle, any pass count, any preset, and
         -- either side (pinned in tests/test_geometry.lua). sharp_applies only
         -- ever fires on a FORCED side, and resolve_directions then sends every
         -- loop the same way, so dir is one value for the whole run and the
         -- sign it applies is common to all of them. The nested relief offset
         -- is therefore identically ZERO: nesting and not nesting produce the
         -- same loop. The branch exists because offsetting by zero and squaring
         -- the result again is a meaningless operation, and re-deriving the
         -- identical loop from the source object is the honest spelling of it.
         -- v1.13.0's hook needs two differently-treated corners to mismatch,
         -- and a sharp run has one loop and one corner treatment, so the
         -- mechanism is absent by construction. What Aspire then does with that
         -- loop -- sharpening as a depth-parametrised sweep along the same legs
         -- -- is inference from the recorded mechanism, the same inference the
         -- shipped one-pass sharp feature already runs on; the 2026-08-03
         -- corner-nesting spec, section 7e, is where that gets settled at a
         -- sitting.
         for k = 1, n_passes - 1 do
            local rg, rerr
            if sharp_run then
               local pg = CO.pass_geometry(k, n_passes, r.W, s.g, r.a)
               local dk = CO.band_offset_distance(dirs[i], pg.offset)
               rg, rerr = CO.sdk_offset_loop(job, loop.obj, dk,
                             CO.sharp_offset_distance(dirs[i], pg.offset, pg.depth, angle))
            else
               local delta = CO.relief_offset_distance(k, n_passes, r.W, s.g, r.a, dirs[i])
               -- This calls Offset on the SAME groups[n_passes] handle up to
               -- n_passes-1 times. That Offset returns a group at all is already
               -- deduced-not-attested (offset_and_check); calling it repeatedly
               -- on one receiver rests on a second, stronger assumption nothing
               -- offline can test: that Offset reads groups[n_passes] rather than
               -- consuming or mutating it. If that assumption is wrong, every
               -- relief band after the first would be silently wrong on a
               -- 3-or-more-pass run. UNTESTED -- the sitting must confirm it:
               -- offset the same group twice and check both results are right.
               rg, rerr = CO.sdk_offset_group(groups[n_passes], delta)
            end
            if rerr then
               oerr = rerr
               break
            elseif rg == nil then
               -- Too narrow to chamfer on this band: Aspire collapsed it to
               -- nothing. One dead band kills the whole shape, exactly as
               -- before -- a chamfer on part of a face and nothing on the rest
               -- is worse than a skip the user is told about.
               dead = true
               break
            end
            groups[k] = rg
         end
      elseif oerr == nil then
         dead = true
      end
      -- One failure report for both offset calls: which of the two could not
      -- offset the vector is not something the operator can act on differently.
      if oerr then
         CO.sdk_leave_user_layer(job)
         CO.show_message(gadget_dir, {
            kind = "error",
            headline = "Couldn't offset a vector",
            body = "Failed offsetting vector " .. i .. ":\n" .. tostring(oerr),
            plain = "Failed offsetting vector " .. i .. ":\n" .. tostring(oerr),
         })
         return false
      end
      if dead then
         skipped_narrow = skipped_narrow + 1
      else
         viable[#viable + 1] = { i = i, dir = dirs[i], groups = groups, loop = loop }
      end
   end
   -- Phase 2: draw. Band by band, so each band's layer holds exactly its own
   -- vectors and the toolpath restricted to it can find nothing else.
   local band_drawn = {}
   for k = 1, n_passes do band_drawn[k] = {} end
   for _, v in ipairs(viable) do
      for k = 1, n_passes do
         local ok_draw, cad, derr = pcall(CO.sdk_draw_group, layers[k], v.groups[k])
         if not (ok_draw and cad) then
            CO.sdk_leave_user_layer(job)
            CO.show_message(gadget_dir, {
               kind = "error",
               headline = "Couldn't draw an offset vector",
               body = "Failed drawing offset vector " .. v.i .. ":\n"
                   .. tostring(ok_draw and derr or cad),
               plain = "Failed drawing offset vector " .. v.i .. ":\n"
                   .. tostring(ok_draw and derr or cad),
            })
            return false
         end
         band_drawn[k][#band_drawn[k] + 1] = cad
         drawn[#drawn + 1] = cad
      end
      if v.loop.bbox ~= nil then built_fps[#built_fps + 1] = v.loop.bbox end
      -- Count directions only for loops that produced offsets, so the
      -- outward+inward figures add up to the "14 of 17" count.
      if v.dir == "outward" then n_out = n_out + 1 else n_in = n_in + 1 end
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
      -- The cut position moves G, and G is only what the FINAL band's offset is
      -- made of. Above one pass a shape can collapse on an UPPER band instead,
      -- whose offset comes from the chamfer width and the pass count -- so
      -- "nearer the tip" would be advice that cannot help. A smaller chamfer is
      -- the only remedy true in both cases.
      local remedy = (n_passes > 1)
         and "Try a smaller chamfer size."
         or "Try a smaller chamfer size, or a cut position nearer the tip."
      CO.show_message(gadget_dir, {
         kind = "error",
         headline = "Nothing was wide enough to chamfer",
         body = string.format(
            "No offset vectors were drawn and no toolpath was created. The previous"
            .. " run's offset vectors were already cleared.%s\n\n%s%s",
            replaced_note ~= "" and ("\n" .. replaced_note) or "", remedy,
            CO.selection_skip_notes(skipped_open, skipped_own)),
         rows = {
            { "Selected", CO.offset_count_phrase(#loops, #loops) },
            { "G", string.format("%.4f %s", s.g, unit.suffix) },
         },
         plain = string.format(
            "None of the %d selected vector(s) are wide enough to chamfer at G %.4f %s"
            .. " - the offset collapsed every one of them to nothing.\n\n"
            .. "No offset vectors were drawn and no toolpath was created. The previous"
            .. " run's offset vectors were already cleared.%s\n\n%s%s",
            #loops, s.g, unit.suffix,
            replaced_note ~= "" and ("\n" .. replaced_note) or "", remedy,
            CO.selection_skip_notes(skipped_open, skipped_own)),
      })
      return false
   end
   CO.sdk_leave_user_layer(job)
   job:Refresh2DView()

   local toolpath_note
   if template_ok then
      -- pcall shapes: (true,table)=success, (true,nil,err)=soft failure, (false,errstr)=raw throw
      -- depth stored in job units (docs/m0-results.md, mm-sample)
      local built, fail_at, fail_why = 0, nil, nil
      local last_res = nil
      -- Per-pass warnings are collected rather than appended to toolpath_note as
      -- they happen: both branches below OVERWRITE toolpath_note with the run's
      -- headline sentence, which would swallow them.
      --
      -- TWO accumulators, split by LIFETIME rather than by wording, because the
      -- teardown branch may carry only one of them. A pass that could not be
      -- TAGGED carries no marker, so sdk_delete_marked_toolpaths cannot see it
      -- and it is still in the job after the sweep -- that warning has to
      -- survive a teardown, and is the only hint the operator gets that
      -- something is loose. A pass that could not be RETOOLED was renamed, so it
      -- DOES carry the marker, so the sweep does delete it -- carrying that
      -- warning past a teardown would tell the operator to go and change the
      -- tool on a toolpath the same message has just said was removed.
      local retool_warnings, tag_warnings = "", ""
      for k = 1, n_passes do
         -- Select this band's offsets before its template loads. The shipped
         -- template is layer-restricted, but a hand-re-created, UNRESTRICTED one
         -- attaches to the SELECTION at load time (live-proven 2026-07-24), so
         -- the selection has to be right for every band, not just the first.
         local ok_sel = pcall(function()
            job.Selection:Clear()
            for _, obj in ipairs(band_drawn[k]) do job.Selection:Add(obj, true, true) end
         end)
         if not ok_sel then
            fail_at, fail_why = k, (n_passes > 1)
               and ("could not select band " .. k .. "'s offsets")
               or "could not select the drawn offsets"
            break
         end
         local pg = CO.pass_geometry(k, n_passes, r.W, s.g, r.a)
         local tp_name = CO.toolpath_name(size, unit.suffix, slot, k, n_passes)
         local ok_tp, res, terr = pcall(CO.sdk_apply_template, gadget_dir, CO.TEMPLATE_NAME,
                                        pg.depth, start, slot, k, tp_name, tool, sharp_side)
         if not (ok_tp and type(res) == "table") then
            fail_at, fail_why = k, tostring(ok_tp and terr or res)
            break
         end
         built = built + 1
         last_res = res
         -- One pass and the operator has one toolpath, so naming a pass number
         -- would be v1.12.0's words changed for nothing. The N = 1 path is meant
         -- to be indistinguishable, right down to the strings.
         local which = (n_passes > 1) and ("pass " .. k) or "the toolpath"
         if not res.retooled then
            trouble = true
            retool_warnings = retool_warnings
               .. "\n\nWARNING: couldn't put your chosen bit on " .. which
               .. ", so it still uses the template's bit. Change the tool on it in the "
               .. "Toolpaths panel before cutting."
         end
         if not res.renamed then
            trouble = true
            tag_warnings = tag_warnings
               .. "\n\nCouldn't tag " .. which .. " as EdgeBreaker's, so the next run "
               .. "will NOT replace it automatically - delete it by hand when you re-run."
         end
      end
      if fail_at ~= nil then
         -- A half-built chamfer is the one genuinely dangerous outcome here: it
         -- looks complete in the Toolpaths panel and cuts a partial face. Tear
         -- the whole set down rather than leave it, and say plainly what is left
         -- if the teardown itself fails.
         trouble = true
         local ok_undo, removed, undo_failed =
            pcall(CO.sdk_delete_marked_toolpaths, slot, false)
         -- COUNT the removals against what was built, never just the failures.
         -- The sweep dooms toolpaths by MARKER, so one that loaded but never got
         -- renamed (res.renamed false, or a throw inside sdk_apply_template after
         -- the template load) is invisible to it -- and an invisible toolpath
         -- adds nothing to `failed`, so a bare `undo_failed == 0` would call that
         -- a clean sweep while a live, unmarked, one-band toolpath sat in the
         -- job. `built` is the honest floor: fewer removed than built means
         -- something is still there.
         local cleaned = ok_undo and undo_failed == 0 and (removed or 0) >= built
         -- "pass 1 of 1 failed" is not something to say to somebody cutting a
         -- one-pass chamfer: at one pass there are no passes to number.
         -- Ends on tag_warnings ALONE, deliberately: those describe passes the
         -- sweep above could not see and has therefore left in the job. The
         -- retool warnings describe passes it did delete.
         toolpath_note = "TOOLPATH NOT CREATED: "
            .. ((n_passes > 1)
                and ("pass " .. fail_at .. " of " .. n_passes .. " failed - ") or "")
            .. tostring(fail_why)
            .. ((cleaned and built > 0)
                and "\n\nThe passes that had already been built were removed."
                or "")
            .. ((not cleaned)
                and ("\n\nSome of the earlier passes are still in the Toolpaths panel. "
                     .. "Delete every toolpath marked " .. CO.toolpath_marker(slot)
                     .. " before cutting, and any profile toolpath this run left untagged.")
                or "")
            .. "\n\nThe offset vectors were still drawn."
            .. tag_warnings
      else
         -- Above one pass the quoted name would name ONE toolpath while the
         -- sentence counts N -- "6 passes 'Chamfer 0.25 in [EdgeBreaker 01] pass
         -- 6 of 6' created" reads as a contradiction and says it twice. The names
         -- are in the Toolpaths panel; the count is what this line is for.
         local how
         if n_passes > 1 then
            how = string.format("%d passes created", n_passes)
         else
            local shown = last_res.renamed
               and ("'" .. CO.toolpath_name(size, unit.suffix, slot, 1, 1) .. "' ") or ""
            how = string.format("Toolpath %screated", shown)
         end
         if last_res.status == "calculated" then
            toolpath_note = string.format("%s and calculated (Profile On, depth %.4f %s)\nusing %s.",
                                          how, s.d, unit.suffix, geom.name)
         else
            trouble = true
            toolpath_note = string.format("%s (Profile On, depth %.4f %s)\nusing %s.",
                                          how, s.d, unit.suffix, geom.name)
               .. "\n\nYour other toolpaths were left untouched, and the chamfer toolpath "
               .. "could not be calculated on its own - open it and click Calculate."
         end
         toolpath_note = toolpath_note .. retool_warnings .. tag_warnings
         -- TEACH: the chamfer now remembers the shapes it was built from and the
         -- settings that built them. Written to EVERY pass (Task 7) so deleting
         -- one by hand does not lose the chamfer's memory.
         local taught = CO.sdk_write_memory_all(slot, {
            fps = built_fps, size = size, mode = mode, side = side,
            percent = tonumber(percent), units = unit.suffix, start = start,
            sharp = sharp, tool = geom.name })
         if taught then
            pcall(function()
               tool.ToolDBId:SaveDefaults(CO.TOOL_SECTION, CO.tool_defaults_key(slot))
            end)
         else
            trouble = true
            toolpath_note = toolpath_note
               .. "\n\n(Couldn't store this chamfer's shapes on the toolpath, so the next "
               .. "run won't recognise them - select them again to rebuild it.)"
         end
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
   -- The chamfer was still built, correctly, with rounded corners -- a sharp run
   -- that cannot sharpen has a safe answer and takes it. But the operator ticked
   -- something and did not get it, so this alone has to break the silence, and
   -- should_report lifts the box on any sel_notes content.
   if sharp_refused then sel_notes = sel_notes .. "\n\n" .. sharp_refused end
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
   -- Plural and a range on a multi-pass run: one layer per band, and the
   -- operator is going to go looking for all of them. The phrase is quoted, so
   -- the quotes come off for the styled row's value column -- the label already
   -- tells the reader it is a layer name.
   rows[#rows + 1] = { (n_passes > 1) and "Layers" or "Layer",
                       (CO.offset_layer_phrase(slot, n_passes):gsub("'", "")) }

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
         "EdgeBreaker - Chamfer %d %s\n\nOffset %s (%d outward, %d inward) by G %.4f %s\nonto %s %s.\n\nPlunge depth D: %.4f %s%s\nStandoff from wall: %.4f %s%s\n\n%s\n\n%s",
         slot, DID[kind_out] or "built",
         CO.offset_count_phrase(#loops, n_out + n_in), n_out, n_in, s.g, unit.suffix,
         ((n_passes > 1) and "layers" or "layer"), CO.offset_layer_phrase(slot, n_passes),
         s.d, unit.suffix, start_txt, s.standoff, unit.suffix,
         sel_notes, r.tip_flat_advisory, toolpath_note),
   })
   return true
end
