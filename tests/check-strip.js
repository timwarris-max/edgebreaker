// check-strip.js -- the control strip fits its own box.
//
// WHY THIS EXISTS. The strip is pinned above the footer, OUTSIDE #Scroll, so
// tests\check-dialog-layout.js never walks it: that gate measures #Scroll's
// children and stops. The strip could overflow by any amount and every other
// check would still pass -- the surplus is simply clipped, and what gets
// clipped is the bottom caption of whichever cell is tallest.
//
// It was already overflowing before anyone looked. At 60 deg the SIZE cell
// needed 213px of a 210px box (measured 2026-08-11), so the last line of its
// caption sat on the border. Nothing reported it.
//
// v1.15 then cut the strip from 210px to 148px to give the height to the
// drawing -- the operator called the drawing too small -- which makes an
// unguarded strip a much worse bet than it already was. Hence this gate.
//
// It renders the real dialog in headless Chrome at the design window size and
// asserts, for every cell, in every state that changes a cell's height:
//
//   * the cell's own contents end at least BOTTOM_PAD px above the strip's
//     bottom edge, so nothing is clipped and nothing sits on the border;
//   * the two rows that were deliberately put ON ONE LINE stay on one line --
//     the size box beside setback/face/leg, and SIDE beside SHARP CORNERS.
//     Those two pairings ARE the height saving. A wrap does not always clip
//     anything (the cell may still be shorter than its neighbours), so the
//     bottom check above cannot see it: it has to be named directly.
//
// An earlier draft checked "no child reaches the cell's right edge" instead,
// on the theory that a row about to wrap is a row that has run out of width.
// Squeezing SIDE from 29% to 25% proved it useless: the row wrapped, and
// wrapping moved the contents AWAY from the right edge, so the check went
// quieter rather than louder. A check that relaxes when the thing it guards
// against happens is not a check.
//
// Chrome, not Trident, so treat the margins as a floor and not a promise:
// Trident rounds every child of a zoomed page separately and a dozen pixels
// can go missing (the 2026-07-27 failure). That is what BOTTOM_PAD is for.
//
//   node tests\check-strip.js

var fs = require("fs");
var cp = require("child_process");
var path = require("path");
var os = require("os");

var DIALOG = path.join(__dirname, "..", "gadget", "EdgeBreaker", "EdgeBreakerDialog.htm");

// The window the layout is authored against -- DESIGN_W/H in the dialog and
// CO.DESIGN_SIZE in the Lua. Every other window size is this one scaled, so a
// strip that fits here fits everywhere.
var WIN_W = 1798, WIN_H = 950;

// The strip does not get the whole window any more. #Rail takes RAIL_W off its
// right-hand end (v1.16), so a cell percentage is a percentage of what is left.
// Kept here as a named constant rather than folded into WIN_W: the WINDOW is
// still 1798 and the header and the button bar still use all of it.
var RAIL_W = 340;
var STRIP_W = WIN_W - RAIL_W;

// Clear space wanted under the lowest thing in a cell. 10 rather than the
// stylesheet's 12px bottom padding: the point is to catch a cell that has
// grown INTO its padding, while leaving 2px for Chrome/Trident text-metric
// disagreement that is not worth a red build.
var BOTTOM_PAD = 10;

// How far apart two things may sit vertically and still count as "on the same
// line". Not zero: the pairs are different heights and sit on a shared
// baseline rather than a shared centre, so SIDE and SHARP CORNERS measure 15px
// apart while plainly on one line. A wrap measures 42-43px. 24 sits clear of
// both -- it is a gap between two populations, not a tuned threshold.
var SAME_LINE = 24;

var CHROME = [
  process.env["ProgramFiles"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Microsoft\\Edge\\Application\\msedge.exe",
  process.env["ProgramFiles"] + "\\Microsoft\\Edge\\Application\\msedge.exe"
].filter(function (p) { try { return fs.existsSync(p); } catch (e) { return false; } })[0];
if (!CHROME) { console.error("No Chrome/Edge found - cannot verify the strip."); process.exit(2); }

// Every state that changes how tall or wide a cell gets.
//
// 90 deg hides the setback/face/leg control entirely; every other angle shows
// it, and the three modes carry captions of different lengths. `allCaps` forces
// the two lines that only appear in an aspire run to show AT THE SAME TIME --
// deliberately taller than the product can actually produce, so a future
// rewording is caught by the gate rather than by an operator.
var CASES = [
  { name: "90 deg - no mode control", ang: 90, dia: 0.5, size: "0.020", pct: 80 },
  { name: "60 deg - setback", ang: 60, dia: 0.5, size: "0.060", pct: 80 },
  { name: "60 deg - face", ang: 60, dia: 0.5, size: "0.060", pct: 80, mode: "face" },
  { name: "60 deg - leg", ang: 60, dia: 0.5, size: "0.060", pct: 80, mode: "leg" },
  { name: "45 deg - setback", ang: 45, dia: 0.5, size: "0.090", pct: 40 },
  { name: "120 deg obtuse", ang: 120, dia: 0.5, size: "0.040", pct: 60 },
  { name: "big bit, big chamfer", ang: 90, dia: 1.25, size: "0.2728", pct: 40 },
  { name: "mm job", ang: 60, dia: 12.7, size: "1.5", pct: 80, unit: "mm" },
  { name: "both aspire captions at once", ang: 60, dia: 0.5, size: "0.060", pct: 80, allCaps: true }
];

// Runs inside the page. Returns one line per cell: its lowest and rightmost
// ink, measured in the cell's own space.
var PROBE = function stripProbe() {
  var strip = document.getElementById("Strip");
  var sr = strip.getBoundingClientRect();
  var out = [];
  for (var i = 0; i < strip.children.length; i++) {
    var cell = strip.children[i];
    var cr = cell.getBoundingClientRect();
    var low = cr.top, right = cr.left;
    var kids = cell.getElementsByTagName("*");
    for (var j = 0; j < kids.length; j++) {
      var k = kids[j];
      // Skip what is not on the page: the retired preset buttons, the hidden
      // radios parked offscreen at left:-9999px, anything display:none.
      if (!k.offsetHeight && !k.offsetWidth) continue;
      var b = k.getBoundingClientRect();
      if (b.left < cr.left - 100) continue;      // parked offscreen
      if (b.bottom > low) low = b.bottom;
      if (b.right > right) right = b.right;
    }
    out.push([cell.id, Math.round(sr.bottom - low)].join(","));
  }
  // The two deliberate one-line pairings. A missing element is reported as
  // "gone" rather than skipped: if the size box or the SIDE buttons stop
  // existing, this gate should say so, not quietly pass.
  function pair(label, aId, bId) {
    var a = document.getElementById(aId), b = document.getElementById(bId);
    if (!a || !b) return out.push("PAIR," + label + ",gone");
    // An element that is hidden is not on any line, and 90 deg legitimately
    // hides the mode control.
    if (!a.offsetHeight || !b.offsetHeight) return out.push("PAIR," + label + ",hidden");
    // CENTRES, not tops. The two are different heights and are centred on each
    // other, so their tops legitimately differ by ~18px while sitting on the
    // same line; their centres differ by a couple. A wrap moves the centre a
    // whole row.
    var ar = a.getBoundingClientRect(), br = b.getBoundingClientRect();
    var ac = (ar.top + ar.bottom) / 2, bc = (br.top + br.bottom) / 2;
    out.push("PAIR," + label + "," + Math.round(Math.abs(ac - bc)));
  }
  // v1.16: the SIDE + SHARP CORNERS pairing is gone from here. Both controls
  // moved into the right-hand rail, where they are deliberately STACKED, so a
  // one-line assertion about them would now be asserting the opposite of the
  // design. The rail has its own overflow probe in check-dialog-layout.js.
  pair("size box + setback/face/leg", "Size", "ModeGroup");
  return out.join(" ~ ");
};

function run(c) {
  var html = fs.readFileSync(DIALOG, "utf8");
  function seed(id, v) {
    var re = new RegExp('(id="' + id + '"[^>]*value=")[^"]*(")');
    html = html.replace(re, "$1" + v + "$2");
  }
  seed("Units", c.unit || "in");
  seed("ToolAngle", c.ang);
  seed("ToolDiameter", c.dia);
  seed("BitName", c.ang + " V-Bit");
  seed("Size", c.size);
  seed("StartDepth", "0");
  seed("Percent", c.pct);
  seed("Kind", "add");
  seed("Sharp", "0");
  if (c.mode) seed("Mode", c.mode);
  html = html.replace('<span id="BitGeom" style="display:none"></span>',
                      '<span id="BitGeom" style="display:none">' + c.ang + "|" + c.dia + "</span>");

  // Pin the page to the design window. Headless Chrome's --window-size does not
  // map 1:1 to the viewport and the answer must not depend on that.
  html = html.replace("</head>", "<style>html,body{height:" + WIN_H + "px !important;" +
    "width:" + WIN_W + "px !important;} body{position:relative !important;}</style></head>");

  var force = c.allCaps
    ? "document.getElementById('SideCap').style.display='block';" +
      "document.getElementById('PresetCap').style.display='block';"
    : "";

  html = html.replace("</body>",
    "<script>setTimeout(function(){try{" + force +
    "document.title='STRIP '+(" + PROBE.toString() + ")();}" +
    "catch(e){document.title='STRIP FAIL|'+e.message;}},1200);</script></body>");

  var f = path.join(os.tmpdir(), "eb-strip-" + c.name.replace(/[^a-z0-9]+/gi, "-") + ".html");
  fs.writeFileSync(f, html);
  var out = cp.execFileSync(CHROME, [
    "--headless=new", "--disable-gpu", "--hide-scrollbars",
    "--force-device-scale-factor=1", "--window-size=" + WIN_W + "," + WIN_H,
    "--virtual-time-budget=6000", "--dump-dom", "file:///" + f.replace(/\\/g, "/")
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

  var m = /<title>STRIP ([^<]*)<\/title>/.exec(out);
  if (!m) return { bad: ["no STRIP line in the dumped page"] };
  if (/^FAIL\|/.test(m[1])) return { bad: ["probe threw: " + m[1].slice(5)] };

  var bad = [], rows = 0, pairs = 0;
  m[1].split(" ~ ").forEach(function (line) {
    var p = line.split(",");
    if (p[0] === "PAIR") {
      pairs++;
      if (p[2] === "gone") { bad.push(p[1] + ": one of the two is no longer on the page"); return; }
      if (p[2] === "hidden") return;          // 90 deg hides the mode control
      if (+p[2] > SAME_LINE)
        bad.push(p[1] + " are " + p[2] + "px apart vertically - they have wrapped onto " +
                 "two lines, which is the row this layout exists to remove");
      return;
    }
    rows++;
    var id = p[0], below = +p[1];
    if (below < BOTTOM_PAD)
      bad.push(id + " ends " + below + "px above the strip's bottom, want >= " + BOTTOM_PAD);
  });
  // Three cells, not four: SIDE moved to the rail with SHARP CORNERS in v1.16.
  if (rows !== 3) bad.push("expected 3 cells in the strip, saw " + rows);
  if (pairs !== 1) bad.push("expected 1 one-line pairing, saw " + pairs);
  return { bad: bad };
}

var failed = 0;
CASES.forEach(function (c) {
  var r = run(c);
  if (r.bad.length) {
    failed++;
    console.log("FAIL  " + c.name);
    r.bad.forEach(function (b) { console.log("        " + b); });
  } else {
    console.log("ok    " + c.name);
  }
});

console.log("");
if (failed) {
  console.log(failed + " strip case(s) failed - the control strip does not fit its box.");
  process.exit(1);
}
console.log("The control strip fits, in every state, with room to spare.");
