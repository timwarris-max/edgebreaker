// Render the setup dialog to a PNG so it can be LOOKED at. Not a gate: the gates
// count and measure, and five sessions running the defects that mattered were
// found by opening the picture instead. Written from scratch three times in
// three sessions (107, 108, 109) before it was allowed to live in the repo.
//
//   node tests\tools\look.js out.png [width] [height] [Field=value ...]
//
// Any hidden field of the dialog can be seeded by name, e.g.
//   node tests\tools\look.js C:\tmp\shot.png 1798 950 Percent=100 Side=inside tv=1
//
// tv=1 seeds a real selection so the LIVE TOP VIEW draws rather than the
// isometric fallback -- the one thing that made three earlier gate cases measure
// the wrong picture entirely.
var fs = require("fs"), path = require("path"), cp = require("child_process"), os = require("os");

var DIALOG = path.join(__dirname, "..", "..", "gadget", "EdgeBreaker", "EdgeBreakerDialog.htm");
var CHROME = [
  process.env["ProgramFiles"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Microsoft\\Edge\\Application\\msedge.exe"
].filter(fs.existsSync)[0];

// The same T-shaped fixture the label and top view gates use, so a picture taken
// here and a gate failure are talking about the same part.
var TV_ROW = "1=" + [0, 0, 2.2, 0, 2.2, 0.35, 1.41, 0.35, 1.41, 1.95, 0.79, 1.95,
                     0.79, 0.35, 0, 0.35].map(function (n) { return n.toFixed(4); }).join(" ");
var TV_BOX = "0 0 2.2 1.95";

var argv = process.argv.slice(2);
var out = argv.shift() || path.join(os.tmpdir(), "eb-look.png");
var W = parseInt(argv[0], 10) > 0 ? parseInt(argv.shift(), 10) : 1798;
var H = parseInt(argv[0], 10) > 0 ? parseInt(argv.shift(), 10) : 950;

var seeds = { Units: "in", ToolAngle: "90", ToolDiameter: "0.25", BitName: "90 V-Bit",
              Size: "0.020", StartDepth: "0", Percent: "60", Kind: "add", Sharp: "0",
              Side: "auto", Thickness: "0.75" };
var tv = false;
argv.forEach(function (a) {
  var i = a.indexOf("=");
  if (i < 0) throw new Error("arguments are Field=value, got: " + a);
  var k = a.slice(0, i), v = a.slice(i + 1);
  if (k === "tv") { tv = (v !== "0"); return; }
  seeds[k] = v;
});

var html = fs.readFileSync(DIALOG, "utf8");
function seed(id, v) {
  var re = new RegExp('(id="' + id + '"[^>]*value=")[^"]*(")');
  if (!re.test(html)) throw new Error("no such field to seed: #" + id);
  html = html.replace(re, "$1" + v + "$2");
}
Object.keys(seeds).forEach(function (k) { seed(k, seeds[k]); });
if (tv) { seed("Outlines", TV_ROW); seed("OutlineBox", TV_BOX); }
html = html.replace('<span id="BitGeom" style="display:none"></span>',
  '<span id="BitGeom" style="display:none">' + seeds.ToolAngle + "|" + seeds.ToolDiameter + "</span>");

var f = path.join(os.tmpdir(), "eb-look-" + path.basename(out, ".png") + ".html");
fs.writeFileSync(f, html);
cp.execFileSync(CHROME, [
  "--headless=new", "--disable-gpu", "--hide-scrollbars",
  "--virtual-time-budget=7000", "--window-size=" + W + "," + H,
  "--screenshot=" + out, "file:///" + f.replace(/\\/g, "/")
], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
console.log("wrote " + out + "  (" + W + "x" + H + (tv ? ", live top view" : ", fallback block") + ")");
