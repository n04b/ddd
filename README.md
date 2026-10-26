# DDD

A parametric 3D editor for macOS for quickly modeling parts for 3D printing. You build a model from primitives and groups with boolean operations, then export the finished parts to STL for your slicer.

Version 0.1.2. Units are millimeters, and Z points up, as on a printer.

## Features

- **Primitives:** box, sphere and cylinder, each with a position, rotation and size.
- **Solids, holes and masks.** A group is a boolean operation: (union of its solids − union of its holes) ∩ union of its masks. A mask is a 3D clipping mask: only the part of the group inside it remains. Holes and masks only act inside their own group.
- **Box fillets and chamfers.** Each of the 12 edges can be filleted or get a 45° chamfer, and each of the 8 corners is either auto or cut. You edit them with handles right on the model.
- **Parametric model.** A project stores parameters, not triangles, so you can change sizes and fillets at any time.
- **Background computation.** While you drag a value, a draft is shown; the exact geometry is computed when you release.
- **Number fields accept expressions:** `20+5`, `60/2-1,5`, `12 mm`.
- **Undo** up to 200 steps, autosave, JSON projects, binary STL export.

## Controls

### Viewport

| Action | Mouse | Trackpad |
|---|---|---|
| Select an object | Click | Click |
| Add to the selection | ⌘-click | ⌘-click |
| Select an object inside a group | Double-click | Double-click |
| Move along the bed | Drag the object (1 mm steps, ⌥ — no snapping) | Same |
| Move up or down | ⇧ + drag the object | Same |
| Orbit the camera | Drag empty space or use the right button | Two fingers |
| Pan | ⇧ + drag empty space or use the middle button | ⇧ + two fingers |
| Zoom | Scroll wheel | Pinch or ⌘ + two fingers |

### Keys

| Key | Action |
|---|---|
| B / S / C | Add a box, sphere or cylinder |
| H | Toggle solid / hole |
| M | Toggle solid / mask |
| G | Group the selection |
| F | Frame the selection |
| 1 / 2 / 3 / 4 | View: isometric, top, front, right |
| ← → ↑ ↓ | Move 1 mm along X and Y (⇧ — 10 mm, ⌥ — 0.1 mm) |
| ⌘↑ / ⌘↓, PgUp / PgDn | Move along Z |
| ⌫ | Delete |
| Esc | Clear the selection |

Keys work in any keyboard layout, because the app reads key codes rather than characters.

### Menu

| Shortcut | Action |
|---|---|
| ⌘N / ⌘O | New project / open |
| ⌘S / ⇧⌘S | Save / save as |
| ⌘E | Export STL |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Add a box, sphere or cylinder |
| ⌘G / ⇧⌘G | Group / ungroup |
| ⌥⌘H | Toggle solid / hole |
| ⌥⌘M | Toggle solid / mask |
| ⌘D | Duplicate |
| ⌥⌘F | Frame the selection |

### Object tree

- Drag a row onto a group to put the object inside it, or onto the empty space below the list to move it to the top level.
- Double-click a name to rename it.
- The eye hides or shows an object. ⌥-click the eye to show only that object; ⌥-click it again to show everything.
- The context menu has rename, solid, hole or mask, grouping, duplicate, delete and, for boxes, fillet presets.

### Inspector

- Drag a number field's label to change the value: ⇧ — faster, ⌥ — finer.
- ↑ / ↓ in a field change the value by one step.
- Values apply immediately, with no OK button.

## Fillets

To enter fillet mode, double-click a selected box or click **Edit** in the inspector's **FILLETS** row. The body turns translucent, a handle appears at the middle of every edge, and a ring appears at every corner.

| To | Do |
|---|---|
| Pick one edge or corner | Click its handle |
| Add or remove | ⇧-click |
| Pick all parallel edges | Double-click an edge handle |
| Pick a face's 4 edges | Click the face |
| Pick all edges or all corners | ⌥ + click or drag |
| Pick all 12 edges | ⌘A |
| Change the value | Drag a handle into the body (0.5 mm steps, ⇧ — 1 mm), or ↑ / ↓ |
| Type a number | Click the value on the badge, or type any digit |
| Choose the type | ▾ on the badge: fillet or chamfer; for a corner, auto or cut |
| Make sharp | ⌫ |
| Leave | Esc or click empty space |

How values work:
- **Limit.** An edge's radius is limited by the width of its two faces minus the radii of the opposite edges. The handle stops at a limit mark.
- **When it doesn't fit.** A typed value above the limit is kept as typed, but the allowed size is built. The badge shows "12 → 8", and the box gets a yellow dot in the tree.
- **An auto corner** is built from its three edges; with equal radii it becomes a sphere.
- **Print hint.** If an edge on the bed has a fillet larger than 1 mm, the badge suggests replacing it with a 45° chamfer, which prints without supports.

Presets are in the inspector, in **Object → Fillets** and in the tree's context menu: All Edges, Top + Vertical, Vertical, Top Only, For Printing (45° chamfer on the bottom) and Reset Fillets.

## Requirements and building

- macOS 26.5 or later.
- Xcode with the macOS 26.5 SDK.

Open `DDD.xcodeproj`, choose the **DDD** scheme and press ⌘R. To build from the terminal:

```bash
xcodebuild -project DDD.xcodeproj -scheme DDD -destination 'platform=macOS' build
```

There are no external dependencies: rendering is Metal, the interface is SwiftUI, and the geometry kernel is written in Swift.

## Files

- **Project:** JSON with the node tree and its parameters.
- **Autosave:** `autosave.json` in the app container's Application Support folder, written 0.6 s after each edit.
- **STL:** binary, in millimeters. It contains the visible top-level solids with exact geometry; if a computation is running, the export waits for it.

## How it works

```
DDD/
├── DDDApp.swift            entry point and menus
├── ContentView.swift       full-window viewport with floating panels
├── App/
│   ├── EditorModel.swift   state, selection, history, fillet mode, files
│   └── Persistence.swift   autosave
├── Core/                   geometry in Double, no Apple frameworks
│   ├── Scene.swift         the document: a tree of nodes
│   ├── Math.swift          vectors, matrices, poses, bounding boxes
│   ├── Tessellator.swift   primitives to polygons
│   ├── RoundedBox.swift    box fillets, chamfers and corner cuts
│   ├── CSG.swift           boolean operations on BSP trees
│   ├── GeometryKernel.swift background computation and cache
│   ├── Picking.swift       ray picking
│   ├── Expression.swift    expressions in number fields
│   └── STLWriter.swift     export
├── Viewport/               Metal renderer, camera, mouse and keyboard, fillet handles
└── UI/                     toolbar, tree, inspector, theme
```

How geometry is computed:
- **Every edit** goes through `EditorModel.mutate`, which also records history and starts a recomputation.
- **Computation** runs on its own thread. If edits arrive faster than it can keep up, intermediate versions are skipped.
- **Cache.** Results are cached by a node's shape, without its name or position. Moving a top-level object recomputes nothing; its mesh is moved by a matrix.
- **The draft pass** during a drag coarsens fillets and merges a group's solids without boolean operations. Unchanged nodes come from the exact cache.
- **A filleted box** is convex, so it's built by clipping the box with planes rather than with boolean operations. The resulting mesh is closed.
- **Boolean operations** are a port of csg.js. Only polygons that touch the other body's bounding box go into the BSP; the rest pass through unchanged.

The kernel in `Core/` doesn't depend on Apple frameworks, so it can later be built for other platforms or replaced with OpenCascade or Manifold.

## Limitations

- Curved surfaces are approximated by polygons with a chord of about 1 mm.
- Boolean results can contain T-junctions between polygons; slicers usually tolerate them.
- Fillets exist only on boxes and only on their original edges. Edges created by boolean operations can't be filleted.
- There is no soft corner with a variable radius and no curvature-continuous fillet profile.
- Click selection treats a box as sharp even when it's filleted.
