# DDD

A parametric 3D editor for macOS for quickly modeling parts for 3D printing. You build a model from primitives and groups with boolean operations, then export the finished parts to STL for your slicer.

Version 0.1.2. Units are millimeters, and Z points up, as on a printer.

## Features

- **Primitives:** box, sphere and cylinder, each with a position, rotation and size.
- **Solids, holes and masks.** A group is a boolean operation: (union of its solids − union of its holes) ∩ union of its masks. A mask is a 3D clipping mask: only the part of the group inside it remains. Holes and masks only act inside their own group.
- **Box fillets and chamfers.** Each of the 12 edges can be filleted or get a 45° chamfer, and each of the 8 corners is either auto or cut. You edit them with handles right on the model.
- **Smooth joins and blend operations (SDF groups).** A group can fillet or chamfer every edge its boolean operations create — where solids meet, around hole rims, along mask cuts — with one size. Its objects can also Push, Avoid, Emboss, Deboss or Shell the objects above them, as in SDF Modeler. Such a group is built from a signed distance field instead of BSP.
- **Reference images.** A photo, drawing or PDF lies on the top, front or right plane as a backdrop to model over. Its scale comes from the file's DPI and can be calibrated by two points of a known distance; points marked on it show their coordinates in millimeters.
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
| Space | Outline mode: holes and masks are drawn as a single outline; the objects next to the selection in its group are drawn filled |
| ← → ↑ ↓ | Move 1 mm along X and Y (⇧ — 10 mm, ⌥ — 0.1 mm) |
| ⌘↑ / ⌘↓, PgUp / PgDn | Move along Z |
| ⌫ | Delete |
| Esc | Clear the selection |
| P / R | With a reference image selected: place points / calibrate the scale |

Keys work in any keyboard layout, because the app reads key codes rather than characters.

### Menu

| Shortcut | Action |
|---|---|
| ⌘N / ⌘O | New project / open |
| ⇧⌘I | Import a reference image |
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
- The cube to the left of the eye always draws an object and its children as an outline, whatever the outline mode. The flag is saved with the project.
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

## Smooth joins

Select a group and choose **Fillet** or **Chamfer** in the inspector's **JOINS** row (or **Joins** in the tree's context menu), then set the size. **Sharp** turns it back into an ordinary group; the objects and their parameters are kept. In the tree such a group has a filled icon and its size after the object count: "3 · R2" or "3 · ◢1.5".

- **Order matters.** As in SDF Modeler, the objects of an SDF group apply top to bottom: each one acts on what the objects above it in the tree have made. A hole above every solid cuts nothing; drag it below them.
- **What is rounded.** Every edge the group's operations create. Where solids meet, material is added into the inner corner; hole rims and mask cuts are rounded off. A fillet is a smooth blend that reaches the given size along each face of a right angle; a chamfer is a 45° cut with the given leg.
- **What is not.** The objects' own edges stay as they are (box fillets still work on them).
- **Blend operations.** Select an object inside a group: next to **Solid**, **Hole** and **Mask** (Union, Subtract and Intersect in SDF Modeler) the inspector offers five operations, each with its own size:
  - **Push** — the object is inserted with a gap: the objects above are cut back around it by **Gap**. Good for print-in-place parts.
  - **Avoid** — the object is cut back by **Gap** around the objects above, which stay as they are.
  - **Emboss** — the surface of the objects above is raised by **Height** where the object covers it.
  - **Deboss** — the surface of the objects above is engraved by **Depth** where the object covers it.
  - **Shell** — inside the object the objects above become a hollow wall of thickness **Wall**; outside it nothing remains.

  A group with such an object is an SDF group even with **Sharp** joins. Outside an SDF group the object acts as a solid (Push, Avoid, Emboss), a hole (Deboss) or a mask (Shell). Paint from SDF Modeler is not here: objects have no colours.
- **Nested groups** inside an SDF group are part of the same field: with their own joins size, or with sharp joins if they have none. To round only one joint, put those objects into their own SDF group.
- **Mesh.** The field is meshed with a grid step of about a third of the smallest detail (the joint size, box fillets, half the thinnest object), from 0.15 to 0.6 mm. While you drag a value, a draft on a 2.5 times coarser grid is shown. The STL contains the same mesh.

## Reference images

Import a picture with **File → Import Reference Image…** (⇧⌘I), the photo button in the toolbar, or by dropping a file on the viewport. PNG, JPEG, HEIC, TIFF and the first page of a PDF are supported. The image lies on the plane that faces the camera: the bed in the isometric and top views, the front or right plane in those views. On a vertical plane it stands on the bed.

**Scale.** By default the size comes from the DPI stored in the file; without it, 72 dpi is assumed. A PDF page keeps its exact paper size. In the inspector you can type the DPI, the width or the height, or **Calibrate by two points** (R): click both ends of a distance you know on the image, type its real length and press Return. The first point stays in place. **Reset** returns the file's DPI.

**Points.** Press P (or **Add** in the inspector's **POINTS** row) and click the image to mark corners, hole centers and other key spots. Points are labeled A, B, C…, always drawn on top of the model, and listed in the inspector with their world coordinates. Hovering a point shows its X, Y and Z.

| To | Do |
|---|---|
| Select the image | Click its row in the tree, double-click it in the viewport, or click one of its points |
| Move it | Drag the selected image along its plane (1 mm steps, ⌥ — no snapping); the arrow keys move it like an object |
| Move a point | Drag it |
| Select several points | ⇧- or ⌘-click; ⌘A selects all |
| Measure | Select two points: the inspector shows the distance between them. Type the real distance to scale the image |
| Put a point at the origin | The ⌖ button in the point's row: on the bed the point goes to X 0, Y 0; on a vertical plane it stands on the bed at 0 |
| Delete points | ⌫ deletes the selected points; with no points selected, it deletes the image |

A single click on an unselected image works like a click on empty space, so the backdrop doesn't get in the way of modeling. **Lock in the viewport** keeps a selected image from moving when you drag it. **Show over the model** draws the image on top of the bodies, so its outline shows through them; otherwise the image is a translucent sheet and bodies in front of it hide it. The plane, rotation in the plane (with 90° buttons and a mirror), center and opacity are in the inspector.

## Requirements and building

- macOS 26.5 or later.
- Xcode with the macOS 26.5 SDK.

Open `DDD.xcodeproj`, choose the **DDD** scheme and press ⌘R. To build from the terminal:

```bash
xcodebuild -project DDD.xcodeproj -scheme DDD -destination 'platform=macOS' build
```

There are no external dependencies: rendering is Metal, the interface is SwiftUI, and the geometry kernel is written in Swift.

## Files

- **Project:** JSON with the node tree and its parameters. Reference images are embedded in it, so a project opens on another computer.
- **Autosave:** `autosave.json` in the app container's Application Support folder, written 0.6 s after each edit. Reference images are kept next to it in `references/`, one file per image content; files the document no longer uses are removed at launch.
- **STL:** binary, in millimeters. It contains the visible top-level solids with exact geometry; if a computation is running, the export waits for it.

## How it works

```
DDD/
├── DDDApp.swift            entry point and menus
├── ContentView.swift       full-window viewport with floating panels
├── App/
│   ├── EditorModel.swift   state, selection, history, fillet mode, files
│   ├── EditorModel+References.swift  reference images: import, scale, points
│   ├── ImageAssets.swift   image store, DPI and orientation, PDF pages
│   └── Persistence.swift   autosave
├── Core/                   geometry in Double, no Apple frameworks
│   ├── Scene.swift         the document: a tree of nodes
│   ├── Reference.swift     reference image on a plane, its points and scale
│   ├── Math.swift          vectors, matrices, poses, bounding boxes
│   ├── Tessellator.swift   primitives to polygons
│   ├── RoundedBox.swift    box fillets, chamfers and corner cuts
│   ├── CSG.swift           boolean operations on BSP trees
│   ├── SDF.swift           distance fields of groups with smooth joins
│   ├── SDFMesher.swift     distance field to triangles (Dual Contouring)
│   ├── GeometryKernel.swift background computation and cache
│   ├── Picking.swift       ray picking
│   ├── Expression.swift    expressions in number fields
│   └── STLWriter.swift     export
├── Viewport/               Metal renderer, camera, mouse and keyboard, fillet handles, reference images
└── UI/                     toolbar, tree, inspector, theme
```

How geometry is computed:
- **Every edit** goes through `EditorModel.mutate`, which also records history and starts a recomputation.
- **Computation** runs on its own thread. If edits arrive faster than it can keep up, intermediate versions are skipped.
- **Cache.** Results are cached by a node's shape, without its name or position. Moving a top-level object recomputes nothing; its mesh is moved by a matrix.
- **The draft pass** during a drag coarsens fillets and merges a group's solids without boolean operations. Unchanged nodes come from the exact cache.
- **A filleted box** is convex, so it's built by clipping the box with planes rather than with boolean operations. The resulting mesh is closed.
- **Boolean operations** are a port of csg.js. Only polygons that touch the other body's bounding box go into the BSP; the rest pass through unchanged.
- **An SDF group** is evaluated as one distance field carrying its gradient, child after child, as SDF Modeler does: primitives have exact fields, union is the quadratic smooth minimum by Inigo Quilez (or a 45° chamfer plane), difference and intersection are the same through negation, and Push, Avoid, Emboss, Deboss and Shell are built from them and offsets of the field. Every formula is continuous, so the mesh has no tears.
- **Meshing** uses Dual Contouring: one vertex per cell, placed by a QEF solved with a truncated eigen decomposition, so sharp edges and corners stay sharp. Cells are processed in 4×4×4 blocks on all cores, and empty space is skipped by the distance bound.

The kernel in `Core/` doesn't depend on Apple frameworks, so it can later be built for other platforms or replaced with OpenCascade or Manifold.

## Limitations

- Curved surfaces are approximated by polygons with a chord of about 1 mm.
- Boolean results can contain T-junctions between polygons; slicers usually tolerate them.
- Fillets exist only on boxes and only on their original edges. Edges created by boolean operations can be filleted only in SDF groups, with one size per group.
- An SDF group is a fine mesh: flat faces get many triangles. A parent group cuts it with BSP slowly, so keep the holes that cut such a part inside the SDF group itself.
- In an SDF group, objects closer than the joint size merge with a smooth web, faces flush with each other get a low ridge along their seam, and a fillet is a smooth blend rather than an exact circular arc.
- SDF groups compute about 40 times slower in a Debug build than in Release.
- There is no soft corner with a variable radius and no curvature-continuous fillet profile.
- Click selection treats a box as sharp even when it's filleted.
