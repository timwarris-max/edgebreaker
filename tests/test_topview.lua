local CO = EdgeBreaker

-- The union box of every loop's own bbox. nil when there is nothing to draw.
local function bb(x0, y0, x1, y1) return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end

CHECK(CO.outline_bbox({}) == nil, "outline_bbox: empty is nil")
CHECK(CO.outline_bbox(nil) == nil, "outline_bbox: nil is nil")

local u = CO.outline_bbox({ { bbox = bb(1, 1, 3, 4) }, { bbox = bb(-2, 2, 0, 9) } })
NEAR(u.x0, -2, 1e-9, "outline_bbox: x0")
NEAR(u.y0, 1, 1e-9, "outline_bbox: y0")
NEAR(u.x1, 3, 1e-9, "outline_bbox: x1")
NEAR(u.y1, 9, 1e-9, "outline_bbox: y1")

-- A loop with no bbox is skipped, not treated as a box at the origin.
local u2 = CO.outline_bbox({ { bbox = bb(5, 5, 6, 6) }, { obj = "x" } })
NEAR(u2.x0, 5, 1e-9, "outline_bbox: skips a loop with no bbox")

-- view_tolerance: half a display pixel, in job units, at the letterbox scale.
-- A 10x5 box into a 200x200 pane fits at 20 px per unit, so half a pixel is 0.025.
NEAR(CO.view_tolerance(10, 5, 200, 200), 0.025, 1e-9, "view_tolerance: width binds")
-- A 5x10 box into a 200x100 pane fits at 10 px per unit -> 0.05.
NEAR(CO.view_tolerance(5, 10, 200, 100), 0.05, 1e-9, "view_tolerance: height binds")
-- Degenerate inputs must not divide by zero or return something absurd.
CHECK(CO.view_tolerance(0, 0, 200, 200) == nil, "view_tolerance: zero box is nil")
CHECK(CO.view_tolerance(10, 5, 0, 200) == nil, "view_tolerance: zero pane is nil")

-- view_point_budget counts points and says whether the picture is affordable.
local small = { { pts = { {0,0}, {1,0}, {1,1} } }, { pts = { {0,0}, {2,0}, {2,2} } } }
local n, ok = CO.view_point_budget(small)
CHECK(n == 6, "view_point_budget: totals every loop")
CHECK(ok == true, "view_point_budget: small is affordable")

local huge = { { pts = {} } }
for i = 1, CO.VIEW_POINT_BUDGET + 1 do huge[1].pts[i] = { i, i } end
local n2, ok2 = CO.view_point_budget(huge)
CHECK(n2 == CO.VIEW_POINT_BUDGET + 1, "view_point_budget: totals past the cap")
CHECK(ok2 == false, "view_point_budget: over the cap is not affordable")

-- encode_outlines: one row per loop, points relative to the origin passed in.
local enc = CO.encode_outlines({ { pts = { {1,2}, {3,4} } }, { pts = { {5,6} } } }, nil, 1, 2)
CHECK(enc == "1=0.0000 0.0000 2.0000 2.0000;2=4.0000 4.0000",
      "encode_outlines: rows, keys and relative coords (got " .. tostring(enc) .. ")")
CHECK(CO.encode_outlines({}, nil, 0, 0) == "", "encode_outlines: empty is empty")
