# EdgeBreaker

Break an edge with a V-bit in Aspire: select closed vectors, pick a bit, enter a
chamfer size, choose where on the flute to cut. The gadget draws offset vectors
into the waste and creates a Profile "On" toolpath at the exact depth — the
tip and its flat ride in air beside the wall instead of dragging through your cut.

**Requires Aspire 12.x.** (Not tested on V-Carve or earlier versions.)

> Through v1.4.x this gadget was called **ChamferOffset**. Same gadget, new name.
> Jobs built with the old version still work — see
> [Chamfers from older versions](#chamfers-from-older-versions).

## Quick start (60 seconds)

1. Double-click `EdgeBreaker-v*.vgadget` to install, then restart Aspire.
   Windows may warn you about the file when you download it. That's only because
   it's new and not many people have it yet — choose Keep, then open it.
2. Open a job, select the closed vector(s) to chamfer.
3. Gadgets menu → EdgeBreaker. The dialog opens with a coloured banner telling you
   what it's about to do. **Choose your V-bit** (it opens on the bit you used last),
   enter the chamfer size, pick a cut position, press OK.
4. The gadget draws orange offset vectors and creates a calculated
   `Chamfer ... [EdgeBreaker 01]` toolpath. A clean run shows you nothing at
   all — the toolpath in the Toolpaths panel and the orange offsets on the
   canvas are the confirmation. You only get a message when there is something
   to act on: a shape too narrow to chamfer, a vector skipped, a remembered
   shape that has gone, or a toolpath that could not be created.
5. Not what you wanted? Just run it again. Your vectors are still selected, so
   the banner says **Rebuilding Chamfer 1** and that chamfer's settings are
   already loaded.

**Stuck at the machine?** The **Help** button at the bottom of the dialog opens this
guide in a browser window. It's a copy that ships with the gadget, so it works with
no internet.

## How it decides what to build

**The selection decides.** Before it asks you anything, EdgeBreaker looks at what
you have selected and opens ready to do the obvious thing. The banner at the top
of the dialog names it, in colour, and the OK button repeats it — so a run that
would destroy something says so before you press anything.

| What you have selected | Banner | What OK does |
|---|---|---|
| Shapes no chamfer uses | **Green — Adding Chamfer N** | Creates a new chamfer. Nothing existing is touched. |
| Shapes an existing chamfer was built from | **Blue — Rebuilding Chamfer K** | Rebuilds K, with K's own size, side and cut position already loaded. Selecting *some* of its shapes is enough. |
| Nothing | **Blue — Rebuilding Chamfer K, nothing selected** | Rebuilds K from the shapes it remembers. |
| Shapes a chamfer *should* know but doesn't | **Amber — I don't know which shapes** | Rebuilds it on your selection, and this run teaches it. |
| A chamfer you picked by hand, holding different shapes | **Red — Replacing Chamfer K's shapes** | Removes K's offsets and toolpath and rebuilds them on the new shapes. Cannot be undone. |

Two more things it works out on its own:

- **A mixed selection** — some free shapes, some already owned by another
  chamfer — adds a new chamfer from the free ones and says how many it left out.
- **Your own orange offsets** caught up in a box-select are ignored, not refused.
  Box-selecting everything and re-running is the natural way to adjust a chamfer,
  and it works.

You are never stuck with its guess: the **Change** dropdown in the banner picks
any chamfer in the job (or "New chamfer"), and the banner re-colours to match.

**With nothing selected**, EdgeBreaker rebuilds the newest chamfer — unless you
single-click a chamfer's toolpath in the Toolpaths list first, which names the
one you mean. A selection always outranks a highlighted toolpath.

## Start depth

**Start depth is how far below the top of the stock the edge sits** — a pocket
floor, a second level, a top you have already skimmed. Leave it at **0** for an
edge at the top of the material, which is the usual case.

It does not change the chamfer itself. The size, the cut position and the bit
geometry all describe the bit against the edge, and that relationship is the same
wherever the edge happens to sit — a start depth simply moves the whole cut down.
So the machine reaches **start depth + cut depth** into the material, and that
total is what the depth-vs-stock warning measures and what the section view draws.

Each chamfer remembers its **own** start depth, and a **new** chamfer always opens
at 0. Unlike the chamfer size, it is deliberately not carried over from your last
run: a leftover 0.25 in from yesterday's pocket applied to today's flat job would
cut a quarter inch too deep without looking wrong on screen.

## What a chamfer remembers

Each chamfer stores, on its own toolpath, the shapes it was built from and the
settings that built them — size, mode, side, cut position, start depth and units.
That is what
makes the table above work: recognising your selection, reloading the right
numbers, rebuilding from memory when nothing is selected.

- It travels **inside the job file**, so it survives save/close/reopen and moves
  with the job to another machine. **Save the job** to keep it.
- Delete a chamfer's toolpath and it is forgotten — which is also how you free
  its number for reuse.
- Edit or move a remembered shape and the gadget stops recognising it (shapes are
  matched by size and position). You get the amber "teach me" banner; rebuilding
  from your selection fixes it.
- **The bit is the exception.** Aspire gives no way to store a tool identity in
  text, so each chamfer's bit is remembered in Aspire's own settings **on this
  PC**, not in the job. Open the same job on another machine and the picker
  offers the last bit you used there, not that chamfer's. Everything else travels.

## The section view

The right-hand side of the setup dialog draws the cut you are about to make, in
section, and redraws it as you type: the stock, the bevel it will leave, the
V-bit that cuts it, and the four numbers that describe it — `W` the chamfer
width, `D` the plunge depth, `G` the standoff, and `S` the start depth when the
edge sits below the top of the stock.

The stock is schematic, not to scale. Drawing a 0.02 in chamfer against 0.75 in
of real stock would make the chamfer 3% of the picture and tell you nothing;
whether the cut is too deep for the material is answered in words by the warning
directly above the drawing.

On any bit that isn't 90°, a small corner detail sits at the right-hand end of the
drawing. It's the corner blown up, with the edge you're sizing picked out in orange
and named underneath — `SETBACK` across the top face, `FACE` along the slant, `LEG`
down the side — and the number you typed below that.

It's a sketch, not a scale drawing. At the main drawing's scale your chamfer is a
sliver a few percent of the bit's reach, so all three edges land on top of each other
with nowhere to put a label. The true angle and every real number are on the drawing
right beside it.

A 90° bit doesn't get one — at 90° the setback and the leg are the same measurement,
so there's no choice to explain.

## More than one chamfer in a job

A job can hold up to 99 chamfers, each with its own bit, size and cut position —
a fine chamfer on the lettering and a heavier one on the outline, say.

Each chamfer keeps its own offset layer (`EdgeBreaker - Offset 01`, `02`, …) and
its own toolpath marker (`[EdgeBreaker 01]`). A run clears and rebuilds **only its
own number**; every other chamfer is left exactly as it was, and the banner says
which ones those are before you press OK.

## Chamfers from older versions

Chamfers built by **ChamferOffset v1.4.x** are adopted. They keep their number and
their size, but not their shapes — nothing recorded them at the time — so the first
time you rebuild one you get the amber "teach me" banner and your selection becomes
its shapes. That rebuild also renames its layer and toolpath to the EdgeBreaker
names, and removes the old ones.

Chamfers from **before v1.4.0** (the unnumbered `ChamferOffset - Offset` layer, or a
toolpath tagged plain `[ChamferOffset]`) are *not* adopted. The gadget says once
that it found one and then leaves it alone entirely — never listed, never replaced,
never deleted. Remove it by hand if you don't want it.

## Bits come from your tool database

There is nothing to add to this gadget. Any V-bit defined in Aspire's tool
database is offered, and its angle, diameter, **feeds, speeds and tool number
are used exactly as the database has them** — so a chamfer is cut with the same
numbers as the rest of your job, and you change them in one place.

A bit in millimetres is fine in an inch job (and vice versa); the diameter is
converted.

**If Select is greyed out** with a bit highlighted, that bit has no feeds and
speeds for the machine named at the top of the tool database dialog. Press
**Copy** under "Copy Settings From", then **Apply**. This is Aspire refusing to
hand over a tool it has no cutting data for — not a gadget fault.

## The strategy template

The gadget ships one file, `EdgeBreaker.ToolpathTemplate`, which supplies only
the *strategy*: Profile, **Machine Vectors: On**, restricted to the layer
`EdgeBreaker - Offset 01`. It exists because Aspire will not accept a template
this gadget wrote itself. The bit inside it is irrelevant — it is swapped for
the one you picked, and so is the depth.

So is the layer: building Chamfer 3 rewrites the restriction to
`EdgeBreaker - Offset 03` before the template is loaded — a two-character
change, nothing else in the file moves — and the gadget reads the name back out
to confirm it before handing it to Aspire. It refuses to build rather than cut a
layer it did not aim at.

You should never need to touch this file. If you do re-create it, it must be
restricted to **`EdgeBreaker - Offset 01`** — the `01` matters, because that is
the text the gadget rewrites. The **Selector ...** step is not optional either:
without it Aspire binds the toolpath to whatever is selected when it
recalculates, and loops silently drop out. It must also be saved from a job in
the same units you work in.

## Notes

- The layers `EdgeBreaker - Offset 01`, `02`, … are gadget-owned. Building a
  chamfer clears **its own** layer and no other, and gadget deletions cannot be
  undone — never keep your own work on one.
- Vectors must be **closed**. Outer boundaries offset outward, holes inward,
  automatically.
- A feature too narrow to chamfer at the size you asked for is **skipped**, not
  approximated: Aspire's offset collapses it to nothing, and it comes back with no
  orange offset beside it. A skip is one of the things that breaks the silence —
  you get a message naming the count. Ask for a smaller chamfer, or cut nearer
  the tip, and more of them will fit. Before v1.3.0 these came back inside-out and
  cut a slot down the middle of the feature.
- One vector can produce **more than one** offset vector. Where an inward offset
  pinches a neck closed, Aspire cuts the loop at the crossing and the valid
  pieces come back as separate closed loops — so the drawn count need not match
  what you selected.
- The gadget owns every toolpath whose name contains `[EdgeBreaker NN]`, and a
  run only touches its own number: building Chamfer 2 deletes and recreates
  `[EdgeBreaker 02]` and leaves `[EdgeBreaker 01]` alone.
  **Toolpath deletions cannot be undone.** To keep a chamfer toolpath forever,
  rename it so the marker is gone — the gadget will never touch it again, and it
  also forgets everything that chamfer remembered.
  Renaming it to a *different* number hands it to that chamfer instead.
- The gadget calculates its own toolpath and leaves your other toolpaths
  alone. If Aspire refuses the single-toolpath calculation, the message says
  so — then open the toolpath and click Calculate yourself.
- A chamfer with no memory of its own falls back to your **last run's** entries,
  kept in `%APPDATA%\EdgeBreaker-settings.txt` (a `ChamferOffset-settings.txt`
  left by an older version is still read). Anything that no longer applies falls
  back to the default — a size from an inch job when the open job is metric.
  Delete the file to start fresh.
- **Depth warning.** A shallow-angle V-bit plunges a long way for a small
  chamfer — a 12.4° bit needs 0.90 in of depth for a 0.020 in chamfer. If the
  cut would go deeper than the stock thickness in Job Setup, the dialog says so
  and names the flute position that fits. It warns, it does not block, and it
  stays quiet when Job Setup has no thickness.
