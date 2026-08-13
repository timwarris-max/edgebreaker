// Drawing label gate: no text in the section drawing may land on the artwork,
// on another label, or outside the canvas.
//
//   node tests\check-drawing-labels.js
//
// Why this exists. Nothing looked inside the drawing. check-dialog-layout.js
// walks #Scroll's children and the whole scene is ONE <svg> to it, so a label
// sitting on top of the part view is invisible to it; check-strip.js looks at
// the control strip; check-scene.js checks that the handles' arithmetic agrees
// with the dialog's own functions, which is a different question entirely. On
// 2026-08-11 the part view was enlarged to 1.4 and the three side/sharp caption
// lines ended up underneath it. Every gate passed. Tim saw it in one glance.
//
// The measurement trap this gate was built around, worth keeping: getBBox()
// reports an element's box in its OWN user space and ignores ancestor
// transforms, so the part view -- which lives inside translate()+scale() -- gets
// measured as if it sat at the origin. The first version of this check reported
// the legend colliding with the part view on the far side of the canvas, which
// is nonsense. getBoundingClientRect() is in screen space and is comparable
// across transforms; use it.
//
// Same head-injection and report-through-<title> trick as check-scene.js, for
// the same reason: no browser-driver dependency, and the page under test is the
// shipped file rather than a copy.

var fs = require("fs");
var os = require("os");
var path = require("path");
var cp = require("child_process");

var DIALOG = path.join(__dirname, "..", "gadget", "EdgeBreaker", "EdgeBreakerDialog.htm");
var CHROME = [
  process.env["ProgramFiles"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Google\\Chrome\\Application\\chrome.exe"
].filter(function (p) { try { return fs.existsSync(p); } catch (e) { return false; } })[0];

if (!CHROME) {
  console.log("SKIP  no Chrome found - drawing label gate not run");
  process.exit(0);
}

// The states that move the drawing's furniture around: the side captions swap
// wording per side, the part view grows when it draws the outer chamfer, a wide
// bit pushes the D dimension right, and a big chamfer on a shallow bit switches
// the whole thing to tip mode.
// The cut position is in here on purpose. The bit cone walks LEFT as the
// position drops toward 0% and its furthest reach is x 242, right where the
// legend ends -- and the legend spans y 44..124 while the cone spans y 20..183,
// so the overlap is total once the x ranges meet. The first version of this
// gate had no 0% case at all and passed while the legend sat inside the bit.
var CASES = [
  { name: "90x0.5 small (as opened)", ang: 90,  dia: 0.5,   size: 0.058, pct: 75,  sharp: 0, side: "auto" },
  { name: "90x0.5 @0% (bit furthest left)", ang: 90, dia: 0.5, size: 0.040, pct: 0, sharp: 0, side: "auto" },
  { name: "90x0.5 @0%, bigger chamfer", ang: 90, dia: 0.5,   size: 0.072, pct: 0,   sharp: 0, side: "auto" },
  { name: "120 obtuse @0%",           ang: 120, dia: 0.5,   size: 0.090, pct: 0,   sharp: 0, side: "auto" },
  { name: "90x0.5 sharp + inside",    ang: 90,  dia: 0.5,   size: 0.120, pct: 75,  sharp: 1, side: "inside" },
  { name: "90x1.0 wide bit, outside", ang: 90,  dia: 1.0,   size: 0.120, pct: 75,  sharp: 1, side: "outside" },
  { name: "120 obtuse",               ang: 120, dia: 0.5,   size: 0.090, pct: 60,  sharp: 0, side: "auto" },
  { name: "60 deg mid",               ang: 60,  dia: 0.5,   size: 0.120, pct: 60,  sharp: 0, side: "auto" },
  { name: "30 deg big (tip mode)",    ang: 30,  dia: 0.5,   size: 0.220, pct: 100, sharp: 1, side: "inside" },
  { name: "mm job, long numbers",     ang: 90,  dia: 6,     size: 1.5,   pct: 75,  sharp: 0, side: "auto", units: "mm" },
  { name: "tiny bit, outside",        ang: 90,  dia: 0.125, size: 0.030, pct: 40,  sharp: 0, side: "outside" },

  // START DEPTH. Every case above leaves it at 0, so the step, the start-depth
  // dimension, its caption and (since v1.16) the yellow handle and its label
  // have NEVER been measured by this gate -- and the label's first placement,
  // beside its own handle at 140 + St, landed straight on the dimension's own
  // number. Three depths, because everything in that band moves with St and the
  // label does not.
  { name: "start depth, small",  ang: 60, dia: 0.5, size: 0.120, pct: 80, sharp: 0, side: "auto", start: 0.02 },
  { name: "start depth, mid",    ang: 60, dia: 0.5, size: 0.120, pct: 80, sharp: 0, side: "auto", start: 0.06 },
  { name: "start depth, deep",   ang: 90, dia: 0.5, size: 0.058, pct: 80, sharp: 0, side: "auto", start: 0.25 },

  // With the operator's own outlines the RIGHT-HAND COLUMN IS A DIFFERENT
  // DRAWING: the live top view takes the top of it and the isometric block moves
  // underneath, small. Every case above leaves Outlines empty and therefore
  // measures the block alone -- which is how a caption ended up buried under the
  // top view's band on 2026-08-12 with this gate green. Seeded cases are the fix.
  //
  // Tim's T, the same fixture check-topview.js uses. The band is a stroke
  // CENTRED on the outline, so it hangs W outside the part's own box: the raised
  // sides (auto, inside) are where that overhang reaches the caption below, and
  // the big-chamfer case is where it reaches furthest.
  { name: "top view, auto (band overhangs)", ang: 90, dia: 0.25, size: 0.20, pct: 80, sharp: 0, side: "auto",    tv: 1 },
  { name: "top view, outside (pocket)",      ang: 90, dia: 0.25, size: 0.20, pct: 80, sharp: 1, side: "outside", tv: 1 },
  { name: "top view, inside",                ang: 90, dia: 0.25, size: 0.12, pct: 80, sharp: 0, side: "inside",  tv: 1 },
  { name: "top view, big chamfer",           ang: 90, dia: 0.25, size: 0.35, pct: 80, sharp: 0, side: "outside", tv: 1 },
  // The worst case for the gap under the top view. A RAISED part paints no
  // surround, so the band's overhang -- half its width, outside the part's own
  // box -- is unbudgeted and walks further down the bigger the chamfer. This
  // case is the furthest it can walk on this bit, so it is what says the gap
  // below the pane is big enough.
  //
  // 0.74, because 0.75 is this bit's ceiling and past it the product refuses and
  // draws NOTHING -- a case with no drawing in it reports clean and proves
  // nothing. 0.9 was tried first and did exactly that (2026-08-12); the TVBand
  // assertion in run() is what now makes that failure loud instead of green.
  { name: "top view, raised, biggest chamfer", ang: 90, dia: 0.25, size: 0.74, pct: 80, sharp: 0, side: "auto",  tv: 1 }
];

// The T, in job units, relative to its box corner -- exactly what
// CO.encode_outlines produces. Arm along the BOTTOM (job Y runs up), leg rising.
var TV_ROW = "1=" + [0,0, 2.2,0, 2.2,0.35, 1.41,0.35, 1.41,1.95, 0.79,1.95, 0.79,0.35, 0,0.35]
  .map(function (n) { return n.toFixed(4); }).join(" ");
var TV_BOX = "0 0 2.2 1.95";

// Runs INSIDE the page; reports through document.title, which --dump-dom
// carries back out.
var PROBE = function () {
  var g = document.getElementById("SceneG");
  var scene = document.getElementById("Scene");
  if (!g || !scene) return "no-scene";
  var SR = scene.getBoundingClientRect();
  var all = g.getElementsByTagName("*");
  var texts = [], shapes = [];
  for (var i = 0; i < all.length; i++) {
    var e = all[i], tag = (e.tagName || "").toLowerCase();
    var b = e.getBoundingClientRect();
    if (!b || b.width <= 0 || b.height <= 0) continue;
    if (tag === "text") {
      texts.push({ t: (e.textContent || "").replace(/\s+/g, " "), b: b });
    } else if (e.getAttribute("id") === "TVBand") {
      // The eaten band is the single biggest piece of ink in the drawing and
      // this gate could not see it: it is drawn as a STROKE with fill "none",
      // and the fill test just below drops every stroke-only element, so a
      // caption could sit buried in the orange with every case reading clean
      // (2026-08-12). Taken by NAME rather than by counting strokes generally,
      // which would sweep in every dimension line in the section drawing and
      // turn this gate into a different gate.
      shapes.push({ tag: tag, fill: "the eaten band", b: b });
    } else if (tag === "rect" || tag === "polygon" || tag === "path" || tag === "circle") {
      var fill = e.getAttribute("fill") || "";
      if (!fill || fill === "none" || fill.indexOf("url(") === 0) continue;
      if (b.width > SR.width * 0.9) continue;        // the background grid
      // The pocket's trim panels: painted first, under everything, and five part
      // widths across, so on paper they sit under every caption while burying
      // nothing. Skipped by NAME, because they were skipped by SIZE until the
      // pane shrank and they fell under the threshold (2026-08-12).
      if ((e.getAttribute("class") || "") === "TVTrim") continue;
      if (b.width < 18 && b.height < 18) continue;   // arrow heads and the handles
      shapes.push({ tag: tag, fill: fill, b: b });
    }
  }
  // Labels that sit ON artwork by design: MATERIAL is stamped on the hatched
  // block, the flute scale numbers run down the bit, and "tip" replaces the
  // blue dot on the bit itself.
  function allowed(t) { return t === "MATERIAL" || /^\d+$/.test(t) || t === "tip"; }
  function ov(a, c) {
    var x = Math.min(a.right, c.right) - Math.max(a.left, c.left);
    var y = Math.min(a.bottom, c.bottom) - Math.max(a.top, c.top);
    return (x > 1 && y > 1) ? (x * y) : 0;
  }
  var hits = [];
  for (var t = 0; t < texts.length; t++) {
    var T = texts[t];
    if (allowed(T.t)) continue;
    var area = T.b.width * T.b.height;
    var worst = 0, who = "";
    for (var s = 0; s < shapes.length; s++) {
      var a = ov(T.b, shapes[s].b);
      if (a > worst) { worst = a; who = shapes[s].tag + " " + shapes[s].fill; }
    }
    // ANY overlap, not a percentage. The first version allowed a quarter of the
    // label to be buried and the legend sat 12% inside the bit -- under the bar,
    // over the gate, and plainly wrong on screen. A label either sits on artwork
    // or it does not; the allow-list above is where the exceptions are named, and
    // that is a categorical rule rather than a number tuned to today's drawing.
    // The 1 square unit is float slop, not tolerance.
    if (worst > 1)
      hits.push("ON-ART [" + T.t + "] " + Math.round(worst / area * 100) + "% into " + who);
    for (var u = t + 1; u < texts.length; u++) {
      if (allowed(texts[u].t)) continue;
      var a2 = ov(T.b, texts[u].b);
      if (a2 > Math.min(area, texts[u].b.width * texts[u].b.height) * 0.15)
        hits.push("ON-TEXT [" + T.t + "] x [" + texts[u].t + "]");
    }
    if (T.b.left < SR.left - 1 || T.b.right > SR.right + 1 ||
        T.b.top < SR.top - 1 || T.b.bottom > SR.bottom + 1)
      hits.push("CLIPPED [" + T.t + "]");
  }
  return hits.length ? hits.join(" ~ ") : "clean";
};

function run(c) {
  var html = fs.readFileSync(DIALOG, "utf8");
  function seed(id, v) {
    var re = new RegExp('(id="' + id + '"[^>]*value=")[^"]*(")');
    html = html.replace(re, "$1" + v + "$2");
  }
  seed("Units", c.units || "in");
  seed("ToolAngle", c.ang);
  seed("ToolDiameter", c.dia);
  seed("BitName", c.ang + " V-Bit");
  seed("Size", c.size);
  seed("StartDepth", String(c.start || 0));
  seed("Percent", c.pct);
  seed("Kind", "add");
  seed("Sharp", c.sharp);
  seed("Side", c.side);
  seed("Thickness", c.units === "mm" ? "19" : "0.75");
  // A seed that matches nothing renders a case that proves nothing, so these
  // two throw rather than silently doing nothing.
  if (c.tv) {
    ["Outlines", "OutlineBox"].forEach(function (id) {
      if (!new RegExp('id="' + id + '"[^>]*value="').test(html))
        throw new Error("seed anchor missing: #" + id);
    });
    seed("Outlines", TV_ROW);
    seed("OutlineBox", TV_BOX);
  }
  html = html.replace('<span id="BitGeom" style="display:none"></span>',
                      '<span id="BitGeom" style="display:none">' + c.ang + "|" + c.dia + "</span>");
  html = html.replace("</body>",
    "<script>setTimeout(function(){try{document.title='LBL '+(" + PROBE.toString() + ")();}" +
    "catch(e){document.title='LBL threw|'+e.message;}},1400);</script></body>");

  var f = path.join(os.tmpdir(), "eb-labels-" + c.name.replace(/[^0-9a-z]/gi, "") + ".html");
  fs.writeFileSync(f, html);
  var out = cp.execFileSync(CHROME, [
    "--headless=new", "--disable-gpu", "--virtual-time-budget=7000",
    "--window-size=1798,950", "--dump-dom", "file:///" + f.replace(/\\/g, "/")
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

  // A seeded case whose top view never drew measures the fallback block and
  // reports clean -- which is the failure this whole seeded group exists to
  // stop. #TVBand is the band, and it exists only when the top view drew.
  if (c.tv && out.indexOf('id="TVBand"') < 0)
    return "the top view never drew - this case measured nothing";

  var m = /<title>LBL ([^<]*)<\/title>/.exec(out);
  return m ? m[1] : "(no LBL line in the dumped page)";
}

var bad = 0;
CASES.forEach(function (c) {
  var r = run(c);
  if (r === "clean") { console.log("ok    " + c.name); return; }
  bad++;
  console.log("FAIL  " + c.name);
  r.split(" ~ ").forEach(function (h) { console.log("        " + h); });
});

if (bad) {
  console.log("\n" + bad + " of " + CASES.length + " states have a label on top of something.");
  process.exit(1);
}
console.log("\nEvery label in the drawing is clear of the artwork, in all " +
            CASES.length + " states.");
