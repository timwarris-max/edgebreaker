// Top view gate: seeds the operator's outlines and reads the RENDERED PICTURE.
//
//   node tests\check-topview.js
//
// Why this one exists, and why none of the others could do its job. The top
// view is drawn by PAINT ORDER -- a survivor fill, an eaten band stroked over
// it, a hairline on top -- so what survives is whatever colour is still showing
// at the end. That is a fact about pixels, not about the DOM, and every
// existing gate reads the DOM.
//
// Worse, all three of them leave the `Outlines` field EMPTY, so every case they
// have ever run measured the isometric FALLBACK and none of them has ever
// looked at the top view at all. Three real defects went through them green on
// 2026-08-12 and were caught only by rendering the page and putting eyes on it:
//
//   1. the part drawn UPSIDE DOWN (job Y runs up, SVG Y runs down) -- a flipped
//      T is still a valid T, so nothing overflowed, collided or disagreed;
//   2. the pocket's caption BURIED whole under the survivor slab;
//   3. the eaten band SPILLING outside the pocket window onto bare pane.
//
// So this gate seeds real outlines, rasterizes the scene into an offscreen
// canvas, and counts survivor- and eaten-coloured pixels inside probe boxes
// given in JOB UNITS. The boxes are mapped to pixels through the drawing's OWN
// transform (read off #TVBand with getScreenCTM), so they cannot drift from the
// picture the way a hard-coded pixel rectangle would.
//
// One trap in that, worth knowing before touching this file: mapping through
// the drawing's own transform is exactly WRONG for the orientation check,
// because a mirrored drawing mirrors the mapping too and the boxes chase the
// ink. The orientation case therefore measures against the rendered extent
// instead -- see TO below, and the mutation that proved it was needed.
//
// <canvas> is used here and ONLY here. The gate runs Chrome; the dialog runs
// Trident, where canvas is banned (spec 6). Rasterizing is a measurement
// technique, not a shipped drawing technique.
//
// Same Chrome invocation, seeding and report-through-<title> MEASURE line as
// tests\check-dialog-layout.js.

var fs = require("fs");
var os = require("os");
var path = require("path");
var cp = require("child_process");

var DIALOG = path.join(__dirname, "..", "gadget", "EdgeBreaker", "EdgeBreakerDialog.htm");

var CHROME = [
  process.env["ProgramFiles"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Microsoft\\Edge\\Application\\msedge.exe"
].filter(function (p) { try { return fs.existsSync(p); } catch (e) { return false; } })[0];

// Not a SKIP. A gate that exits 0 when it could not run is a gate that reports
// a pass it never measured.
if (!CHROME) { console.error("No Chrome/Edge found - cannot render the top view."); process.exit(2); }

// ---- fixtures ------------------------------------------------------------
// Outlines are "x y x y ..." in job units, relative to the box corner, exactly
// as CO.encode_outlines produces them. Keys are 1-based loop indices.
function row(i, pts) {
  return i + "=" + pts.map(function (n) { return n.toFixed(4); }).join(" ");
}

// Tim's T, in job units. The ARM is the horizontal bar at y 0..0.35 -- which is
// the BOTTOM in job space, because job Y runs UP -- and the LEG rises from it,
// x 0.79..1.41, up to y 1.95. That asymmetry is the whole point: it is what
// makes an upside-down drawing detectable.
var T = [0,0, 2.2,0, 2.2,0.35, 1.41,0.35, 1.41,1.95, 0.79,1.95, 0.79,0.35, 0,0.35];
var T_BOX = "0 0 2.2 1.95";

// A 5-point star. Built rather than typed so the limb probe boxes are derived
// from the same numbers as the points and cannot drift from them.
var STAR = (function () {
  var R = 1.0, r = 0.45, tips = [], pts = [], i;
  for (i = 0; i < 5; i++) {
    var th = (90 + 72 * i) * Math.PI / 180;
    var ph = th + 36 * Math.PI / 180;
    tips.push(th);
    pts.push([R * Math.cos(th), R * Math.sin(th)]);
    pts.push([r * Math.cos(ph), r * Math.sin(ph)]);
  }
  var xs = pts.map(function (p) { return p[0]; }), ys = pts.map(function (p) { return p[1]; });
  var x0 = Math.min.apply(null, xs), y0 = Math.min.apply(null, ys);
  var x1 = Math.max.apply(null, xs), y1 = Math.max.apply(null, ys);
  var flat = [];
  pts.forEach(function (p) { flat.push(p[0] - x0, p[1] - y0); });

  // One box in the fat part of each limb, at 0.55 of the outer radius. The
  // nearest limb edge there is ~0.17 away, so at a 0.05 chamfer the flat
  // survives with room to spare -- this is the FALSE-ALARM case, the one that
  // says a pointed shape does not read as destroyed.
  var limbs = {};
  tips.forEach(function (th, n) {
    var cx = 0.55 * Math.cos(th) - x0, cy = 0.55 * Math.sin(th) - y0;
    limbs["limb" + (n + 1)] = { box: [cx - 0.04, cy - 0.04, cx + 0.04, cy + 0.04], want: "full" };
  });
  // And one box straddling a limb EDGE, which the band must have eaten. Without
  // it the star case would pass just as happily with no band at all.
  var th0 = tips[0], ph0 = th0 + 36 * Math.PI / 180;
  var mx = (R * Math.cos(th0) + r * Math.cos(ph0)) / 2 - x0;
  var my = (R * Math.sin(th0) + r * Math.sin(ph0)) / 2 - y0;
  limbs["limb-edge"] = { box: [mx - 0.03, my - 0.03, mx + 0.03, my + 0.03], want: "zero" };

  return { row: row(1, flat), box: "0 0 " + (x1 - x0).toFixed(4) + " " + (y1 - y0).toFixed(4),
           boxes: limbs };
})();

// A nested pair: a 2x2 square with a 0.8 square counterbored out of it. The
// survivor has to come out as an ANNULUS -- evenodd leaves the hole empty and
// the band eats both walls.
var RING = row(1, [0,0, 2,0, 2,2, 0,2]) + ";" + row(2, [0.6,0.6, 1.4,0.6, 1.4,1.4, 0.6,1.4]);

// A small square as a POCKET. Small on purpose: the surrounding flat the page
// draws is a fixed 8% of the part, so a 0.213 chamfer on a 0.6 part paints an
// eaten band far wider than that surround -- which is exactly the spill that
// used to run out onto bare pane.
var SQ = row(1, [0,0, 0.6,0, 0.6,0.6, 0,0.6]);

// The bit is a 1/2in 90 deg V-bit throughout, so setback size == W and every
// size below is comfortably buildable. `size` therefore IS the chamfer width.
var CASES = [
  // T1: the arm is 0.35 thick and the band eats 0.213 from each side, so it
  // cannot survive. The leg is 0.62 and keeps a 0.19 sliver. This is the whole
  // reason the feature exists.
  { name: "T1 arm dies (0.213 on a 0.35 arm)",
    outlines: row(1, T), box: T_BOX, size: 0.213, side: "auto",
    boxes: {
      arm: { box: [0.15, 0.08, 0.60, 0.28], want: "zero" },
      leg: { box: [1.05, 1.00, 1.15, 1.40], want: "full" },
      // OUTSIDE the part, in the notch between the leg and the arm's left end.
      // NOT below the arm, which was tried first and proved nothing: the part
      // fills the pane on its height, so anything below the box's bottom edge
      // is outside the pane and the letterbox paints it white whatever the band
      // did. The notch is inside the pane, inside the part's own bounding box,
      // and empty -- the only place the spill is actually visible.
      //
      // The band is a 2W stroke
      // centred on the operator's own vector, so half of it lands out here
      // where there is no material to eat -- the part read W bigger than it is
      // and the operator's own line sat under orange (Tim, 2026-08-12). The
      // trim paints that half back out.
      //
      // This box exists because the trim landed and EVERY EXISTING BOX STILL
      // PASSED: they all sit inside the part or inside a region the trim never
      // touches, so nothing here measured the change. A fix no check can fail
      // is not covered.
      "notch-is-empty": { box: [0.60, 0.40, 0.70, 0.50], want: "blank" }
    } },

  // T2: the same shape at an ordinary chamfer. Both limbs keep their flat. The
  // control for T1 -- without it, a picture that ate everything would pass.
  { name: "T2 both live (0.02 on the same T)",
    outlines: row(1, T), box: T_BOX, size: 0.02, side: "auto",
    boxes: {
      arm: { box: [0.15, 0.08, 0.60, 0.28], want: "full" },
      leg: { box: [1.05, 1.00, 1.15, 1.40], want: "full" }
    } },

  // TO: ORIENTATION. Job Y runs UP and SVG Y runs DOWN, and the drawing carries
  // a flip to reconcile them. Nothing else here can see that flip: an upside-
  // down T is a perfectly valid T. So this case asserts WHICH HALF the ink is
  // in -- material low (the arm, which is at job y 0), nothing at all
  // high-and-left (up there the T is only its 0.62 leg, in the middle).
  //
  // `space: "frac"` and it is NOT a convenience. Every other box here is given
  // in job units and mapped through the drawing's OWN transform, which is right
  // for them and USELESS here: mirror the drawing and the transform mirrors
  // with it, so the boxes follow the ink and the case still passes. Proved,
  // not argued -- the first version of this gate did exactly that and sailed
  // through an upside-down render (2026-08-12). These two are fractions of the
  // rendered extent instead: 0.86-0.95 of the way DOWN the drawn shape is low
  // on the screen whatever the transform says, so a mirror moves the ink and
  // leaves the boxes where they were.
  { name: "TO orientation (the arm is LOW, the leg is HIGH)",
    outlines: row(1, T), box: T_BOX, size: 0.02, side: "auto",
    boxes: {
      "arm-is-low":        { space: "frac", box: [0.08, 0.86, 0.28, 0.95], want: "full" },
      "high-left-is-void": { space: "frac", box: [0.08, 0.05, 0.28, 0.23], want: "blank" }
    } },

  // T3: the false-alarm case. A pointed shape blunts at its tips and must NOT
  // read as destroyed anywhere in the fat part of a limb.
  { name: "T3 star limbs survive (0.05)",
    outlines: STAR.row, box: STAR.box, size: 0.05, side: "auto",
    boxes: STAR.boxes },

  // T4: nested. The survivor is an annulus -- flat in the middle of the wall,
  // nothing in the counterbore, and nothing hard against either wall face
  // because the band ate both.
  { name: "T4 ring is an annulus (0.15 on a 0.6 wall)",
    outlines: RING, box: "0 0 2 2", size: 0.15, side: "auto",
    boxes: {
      wall:         { box: [0.25, 0.90, 0.38, 1.10], want: "full" },
      counterbore:  { box: [0.90, 0.90, 1.10, 1.10], want: "zero" },
      "inner-face": { box: [0.57, 0.97, 0.63, 1.03], want: "zero" }
    } },

  // T5: the same T read as a POCKET, which flips which side of the line is
  // material. Everything T1 asserts about the leg reverses: the leg's inside is
  // now a hole, and the flat is the surround. The notch between the arm and the
  // leg is the one place far enough from every edge to keep its flat.
  //
  // The pocket reading is side "inside" -- IN is the pockets-and-holes control,
  // and CH_INSIDE_FOR_DIR in EdgeBreaker.lua puts the material inside the vector
  // for OUT. This case said "outside" until 2026-08-12 and so asserted all of
  // the above against the wrong control value, which is what let the drawing's
  // own inversion pass. Not one assertion below changed: the physics of a T
  // read as a pocket is the same: only the value that asks for it was wrong.
  { name: "T5 pocket flips the side (0.213, inside)",
    outlines: row(1, T), box: T_BOX, size: 0.213, side: "inside",
    boxes: {
      "notch-flat":  { box: [0.15, 0.90, 0.50, 1.50], want: "full" },
      "leg-inside":  { box: [1.05, 1.00, 1.15, 1.40], want: "zero" },
      "arm-edge":    { box: [0.35, -0.05, 0.45, 0.05], want: "zero" }
    } },

  // P1: NOTHING PAINTED OUTSIDE THE POCKET WINDOW. The surround is a window
  // onto the flat; a band running past its edge onto bare pane reads as a
  // rendering fault rather than as "the flat here is gone". `window-edge` is
  // the control that stops `outside-window` passing for the wrong reason: it
  // proves the band really does reach the edge, so a blank strip beyond it is
  // a trim rather than a band that never got there.
  { name: "P1 pocket window holds the paint in (0.213 on a 0.6 square)",
    outlines: SQ, box: "0 0 0.6 0.6", size: 0.213, side: "inside",
    boxes: {
      "window-edge":    { box: [0.60, 0.25, 0.64, 0.35], want: "eaten" },
      "outside-window": { box: [0.70, 0.25, 0.80, 0.35], want: "blank" },
      "pocket-centre":  { box: [0.25, 0.25, 0.35, 0.35], want: "zero" }
    } },

  // T7: the OTHER half of the side rule, and the half nothing asserted until
  // 2026-08-12. T5 proves IN reads as a pocket; on its own that leaves the
  // inversion half-covered, because a build that drew EVERY forced side as a
  // pocket would still pass it. This says OUT reads as a RAISED shape -- the
  // same physical claims as T1, which gets the raised reading from auto, now
  // demanded of the forced control as well.
  { name: "T7 out reads as a raised shape (0.213, outside)",
    outlines: row(1, T), box: T_BOX, size: 0.213, side: "outside",
    boxes: {
      arm: { box: [0.15, 0.08, 0.60, 0.28], want: "zero" },
      leg: { box: [1.05, 1.00, 1.15, 1.40], want: "full" },
      // Empty in the raised reading, flat in the pocket reading. This is the
      // single box that tells the two apart, so it is the one that fails if the
      // side is ever inverted again.
      "notch-is-empty": { box: [0.60, 0.40, 0.70, 0.50], want: "blank" }
    } },

  // T6: the point budget blown, or a recall run, or any of spec 8a. Lua sends
  // "" and the page must fall back to the isometric block silently.
  { name: "T6 no payload falls back to the block",
    outlines: "", box: "", size: 0.05, side: "auto",
    fallback: true, boxes: {} }
];

// ---- the in-page probe ---------------------------------------------------
// Everything below runs INSIDE the page and reports one MEASURE line through
// document.title, which --dump-dom carries back out.
var PROBE = function (BOXES, EXPECT_FALLBACK) {
  var res = { err: "", why: "", drew: false, caps: {}, counts: {}, labels: [] };
  function report() {
    try { document.title = "MEASURE " + JSON.stringify(res); }
    catch (e) { document.title = "MEASURE {\"err\":\"stringify\"}"; }
  }

  var scg = document.getElementById("SceneG");
  var svg = document.getElementById("SceneSvg");
  var scene = document.getElementById("Scene");
  if (!scg || !svg || !scene) { res.err = "no scene"; report(); return; }

  res.why = (typeof TOPVIEW !== "undefined" && TOPVIEW) ? String(TOPVIEW.why || "") : "(no TOPVIEW)";
  res.drew = !!document.getElementById("TVBand");

  // Which caption is on the drawing says which arm of the fallback ran.
  var leaves = 0, lands = 0, tx = scg.getElementsByTagName("text"), i;
  for (i = 0; i < tx.length; i++) {
    var s = tx[i].textContent || "";
    // Renamed 2026-08-13 (Tim). The variable is still `leaves` -- it names the
    // arm of the fallback that ran, not the wording on the screen.
    if (s.indexOf("CHAMFER TOOLPATH PREVIEW") >= 0) leaves++;
    if (s.indexOf("WHERE THE CHAMFER LANDS") >= 0) lands++;
  }
  res.caps = { leaves: leaves, lands: lands };

  // ---- label overlap, on a SEEDED page ----------------------------------
  // Same categorical rule as tests\check-drawing-labels.js: no text may land on
  // artwork, on another label, or outside the canvas. That gate's eleven states
  // are ALL fallback states, so this rule has never once been applied to a page
  // with real outlines on it -- which is how a pocket caption came to be buried
  // whole under the survivor slab with every gate green.
  (function () {
    var SR = scene.getBoundingClientRect();
    var all = scg.getElementsByTagName("*"), texts = [], shapes = [], n;
    for (n = 0; n < all.length; n++) {
      var e = all[n], tag = (e.tagName || "").toLowerCase();
      var b = e.getBoundingClientRect();
      if (!b || b.width <= 0 || b.height <= 0) continue;
      if (tag === "text") {
        texts.push({ t: (e.textContent || "").replace(/\s+/g, " ").replace(/[^ -~]/g, "?"), b: b });
      } else if (tag === "rect" || tag === "polygon" || tag === "path" || tag === "circle") {
        var fill = e.getAttribute("fill") || "";
        if (!fill || fill === "none" || fill.indexOf("url(") === 0) continue;
        // Anything bigger than the canvas is BACKGROUND, not artwork. The
        // labels gate skips the grid on the width half of this rule; the
        // pocket's four trim rects need the height half too. They are drawn
        // FIRST, under the whole section, and they extend five part-widths in
        // every direction -- so geometrically they sit under every label on the
        // page while burying nothing at all. A shape that covers the canvas
        // cannot be what a label is lost in.
        if (b.width > SR.width * 0.9 || b.height > SR.height * 0.9) continue;
        // And the same panels by NAME, which is what the size rule above was
        // always reaching for. Since 2026-08-12 they also letterbox the top
        // view -- four rects that repaint the page's own background outside the
        // pane, so the band cannot spill onto the rest of the drawing. They are
        // painted before everything and are background by construction; sized
        // rules kept mistaking them for artwork as the pane changed shape.
        if ((e.getAttribute("class") || "") === "TVTrim") continue;
        if (b.width < 18 && b.height < 18) continue;   // arrow heads and the handles
        shapes.push({ tag: tag, fill: fill, b: b });
      }
    }
    function allowed(t) { return t === "MATERIAL" || /^\d+$/.test(t) || t === "tip"; }
    function ov(a, c) {
      var x = Math.min(a.right, c.right) - Math.max(a.left, c.left);
      var y = Math.min(a.bottom, c.bottom) - Math.max(a.top, c.top);
      return (x > 1 && y > 1) ? (x * y) : 0;
    }
    for (var t = 0; t < texts.length; t++) {
      var T = texts[t];
      if (allowed(T.t)) continue;
      var area = T.b.width * T.b.height, worst = 0, who = "";
      for (var s2 = 0; s2 < shapes.length; s2++) {
        var a = ov(T.b, shapes[s2].b);
        if (a > worst) { worst = a; who = shapes[s2].tag + " " + shapes[s2].fill; }
      }
      if (worst > 1)
        res.labels.push("ON-ART [" + T.t + "] " + Math.round(worst / area * 100) + "% into " + who);
      for (var u = t + 1; u < texts.length; u++) {
        if (allowed(texts[u].t)) continue;
        var a2 = ov(T.b, texts[u].b);
        if (a2 > Math.min(area, texts[u].b.width * texts[u].b.height) * 0.15)
          res.labels.push("ON-TEXT [" + T.t + "] x [" + texts[u].t + "]");
      }
      if (T.b.left < SR.left - 1 || T.b.right > SR.right + 1 ||
          T.b.top < SR.top - 1 || T.b.bottom > SR.bottom + 1)
        res.labels.push("CLIPPED [" + T.t + "]");
    }
  })();

  if (EXPECT_FALLBACK) { report(); return; }
  if (!res.drew) { res.err = "the top view did not draw (why: " + res.why + ")"; report(); return; }

  // ---- the raster --------------------------------------------------------
  // Reading the PICTURE, not the DOM. The whole design rests on paint order and
  // only a raster can say what paint order actually produced.
  //
  // The clone is forced back to its viewBox size, so one raster pixel is one
  // drawing unit and the probe boxes below need no second scale factor.
  var band = document.getElementById("TVBand");
  var M;
  try {
    var inv = svg.getScreenCTM().inverse();
    M = inv.multiply(band.getScreenCTM());     // job units -> viewBox units
  } catch (e) { res.err = "no CTM: " + e.message; report(); return; }

  function J(x, y) { return { x: M.a * x + M.c * y + M.e, y: M.b * x + M.d * y + M.f }; }

  // The rendered extent of the drawn shape, in viewBox units. A mirrored
  // drawing occupies the SAME rectangle -- only the ink inside it moves -- so
  // this is the one anchor a flip cannot drag along with it, and it is what the
  // orientation boxes are measured against.
  var E;
  try {
    var bb = band.getBBox();
    var e1 = J(bb.x, bb.y), e2 = J(bb.x + bb.width, bb.y + bb.height);
    E = { x: Math.min(e1.x, e2.x), y: Math.min(e1.y, e2.y),
          w: Math.abs(e2.x - e1.x), h: Math.abs(e2.y - e1.y) };
  } catch (e) { res.err = "no bbox: " + e.message; report(); return; }
  if (!(E.w > 0) || !(E.h > 0)) { res.err = "the drawn shape has no extent"; report(); return; }

  var VW = 950, VH = 380;
  var clone = svg.cloneNode(true);
  clone.setAttribute("width", VW);
  clone.setAttribute("height", VH);
  var xml = new XMLSerializer().serializeToString(clone);

  var img = new Image();
  img.onerror = function () { res.err = "the scene would not rasterize"; report(); };
  img.onload = function () {
    try {
      var c = document.createElement("canvas");
      c.width = VW; c.height = VH;
      var cx = c.getContext("2d");
      cx.drawImage(img, 0, 0, VW, VH);
      for (var name in BOXES) {
        if (!BOXES.hasOwnProperty(name)) continue;
        var jb = BOXES[name].box, p1, p2;
        if (BOXES[name].space === "frac") {
          p1 = { x: E.x + jb[0] * E.w, y: E.y + jb[1] * E.h };
          p2 = { x: E.x + jb[2] * E.w, y: E.y + jb[3] * E.h };
        } else {
          p1 = J(jb[0], jb[1]); p2 = J(jb[2], jb[3]);
        }
        var px = Math.round(Math.min(p1.x, p2.x)), py = Math.round(Math.min(p1.y, p2.y));
        var pw = Math.round(Math.abs(p2.x - p1.x)), ph = Math.round(Math.abs(p2.y - p1.y));
        if (pw < 2 || ph < 2 || px < 0 || py < 0 || px + pw > VW || py + ph > VH) {
          res.counts[name] = { off: 1, px: px, py: py, pw: pw, ph: ph };
          continue;
        }
        var d = cx.getImageData(px, py, pw, ph).data;
        var surv = 0, eat = 0, k;
        for (k = 0; k < d.length; k += 4) {
          if (d[k + 3] !== 255) continue;
          // TV_SURVIVOR #e7e1d6 and TV_EATEN #cf6d16, matched EXACTLY. The
          // boxes sit wholly inside their region, so the interior pixels are
          // the flat colour and anti-aliased edges cannot be mistaken for them.
          if (d[k] === 0xe7 && d[k + 1] === 0xe1 && d[k + 2] === 0xd6) surv++;
          else if (d[k] === 0xcf && d[k + 1] === 0x6d && d[k + 2] === 0x16) eat++;
        }
        res.counts[name] = { surv: surv, eat: eat, n: pw * ph, px: px, py: py, pw: pw, ph: ph };
      }
    } catch (e) {
      res.err = "raster read failed: " + e.message;
    }
    report();
  };
  img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(xml);
};

// ---- seeding -------------------------------------------------------------
// A seed that matches nothing is the dangerous kind of wrong: the case still
// renders, still passes, and proves nothing. Every one of these throws instead.
function seedField(html, id, value) {
  var re = new RegExp('(id="' + id + '"[^>]*value=")[^"]*(")');
  if (!re.test(html)) throw new Error("seed anchor missing: #" + id);
  return html.replace(re, "$1" + value + "$2");
}

function run(c) {
  var html = fs.readFileSync(DIALOG, "utf8");
  html = seedField(html, "Units", "in");
  html = seedField(html, "ToolAngle", "90");
  html = seedField(html, "ToolDiameter", "0.5");
  html = seedField(html, "BitName", "1/2in 90deg V-bit");
  html = seedField(html, "Size", String(c.size));
  html = seedField(html, "StartDepth", "0");
  html = seedField(html, "Percent", "80");
  html = seedField(html, "Kind", "add");
  html = seedField(html, "Sharp", "0");
  html = seedField(html, "Mode", "setback");
  html = seedField(html, "Side", c.side);
  html = seedField(html, "Thickness", "1.5");
  html = seedField(html, "Outlines", c.outlines);
  html = seedField(html, "OutlineBox", c.box);

  var before = html;
  html = html.replace('<span id="BitGeom" style="display:none"></span>',
                      '<span id="BitGeom" style="display:none">90|0.5</span>');
  if (html === before) throw new Error("seed anchor missing: #BitGeom");

  before = html;
  html = html.replace("</body>",
    "<script>setTimeout(function(){try{(" + PROBE.toString() + ")(" +
    JSON.stringify(c.boxes) + "," + (c.fallback ? "true" : "false") + ");}" +
    "catch(e){document.title='MEASURE {\"err\":\"threw: '+e.message+'\"}';}},1400);" +
    "</script></body>");
  if (html === before) throw new Error("probe injection matched nothing - </body> gone?");

  var f = path.join(os.tmpdir(), "eb-topview-" + c.name.replace(/[^0-9a-z]/gi, "") + ".html");
  fs.writeFileSync(f, html);
  var out = cp.execFileSync(CHROME, [
    "--headless=new", "--disable-gpu", "--hide-scrollbars",
    "--allow-file-access-from-files", "--virtual-time-budget=10000",
    "--window-size=1798,950", "--dump-dom", "file:///" + f.replace(/\\/g, "/")
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

  var m = /<title>MEASURE ([\s\S]*?)<\/title>/.exec(out);
  if (!m) return { err: "no MEASURE line in the dumped page" };
  try { return JSON.parse(m[1].replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")); }
  catch (e) { return { err: "unparsable MEASURE line: " + m[1].slice(0, 200) }; }
}

// ---- the verdict ---------------------------------------------------------
// "full" and "eaten" are half the box or more: every box is placed wholly
// inside the region it names, so the honest expectation is ~all of it, and half
// is the slack for the raster's edge pixels -- not a tuned threshold.
// "zero" and "blank" are exactly nothing. A single flat-coloured pixel where the
// chamfer should have taken the flat away is a wrong answer, not a rounding.
function judge(name, want, cnt) {
  if (!cnt) return name + ": not measured";
  if (cnt.off) return name + ": probe box fell outside the canvas (" +
      cnt.px + "," + cnt.py + " " + cnt.pw + "x" + cnt.ph + ")";
  var half = cnt.n / 2;
  if (want === "full" && !(cnt.surv >= half))
    return name + ": expected flat, got " + cnt.surv + "/" + cnt.n + " survivor px";
  if (want === "eaten" && !(cnt.eat >= half))
    return name + ": expected the eaten band, got " + cnt.eat + "/" + cnt.n + " eaten px";
  if (want === "zero" && cnt.surv !== 0)
    return name + ": expected no flat left, got " + cnt.surv + "/" + cnt.n + " survivor px";
  if (want === "blank" && (cnt.surv !== 0 || cnt.eat !== 0))
    return name + ": expected bare pane, got " + cnt.surv + " survivor and " +
           cnt.eat + " eaten px";
  return null;
}

var failed = 0;
CASES.forEach(function (c) {
  var r;
  try { r = run(c); } catch (e) { r = { err: e.message }; }
  var bad = [];

  if (r.err) bad.push(r.err);

  if (c.fallback) {
    // The isometric block is what ships today and it stays as the fallback.
    if (r.drew) bad.push("the top view drew with no payload");
    if (r.caps && r.caps.lands !== 1) bad.push("the isometric block is not on the drawing");
    if (r.caps && r.caps.leaves !== 0) bad.push("both pictures are on the drawing at once");
  } else {
    if (r.caps && r.caps.leaves !== 1) bad.push("the top view caption is missing");
    if (r.caps && r.caps.lands !== 0) bad.push("the isometric block drew as well");
    Object.keys(c.boxes).forEach(function (name) {
      var why = judge(name, c.boxes[name].want, r.counts ? r.counts[name] : null);
      if (why) bad.push(why);
    });
  }

  if (r.labels && r.labels.length) r.labels.forEach(function (h) { bad.push("label " + h); });

  if (bad.length) {
    failed++;
    console.log("FAIL  " + c.name);
    bad.forEach(function (b) { console.log("        " + b); });
  } else {
    console.log("ok    " + c.name + "  " +
      (c.fallback ? "fell back (" + r.why + ")"
                  : Object.keys(c.boxes).length + " probe box(es), labels clear"));
  }
});

console.log("");
if (failed) {
  console.log(failed + " of " + CASES.length + " top view case(s) FAILED.");
  process.exit(1);
}
console.log("All " + CASES.length + " top view cases draw what the chamfer really leaves.");
