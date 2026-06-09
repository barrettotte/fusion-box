# Fusion 360 on winewayland.drv - Observed Issues

Single canonical doc tracking what works, what doesn't, what we tried, and why.
Updated 2026-06-08.

## Architectural verdict (2026-06-08)

Web research (cryinkfly, GE-Proton, Lutris, Vinegar, ProtonDB, wine bug tracker)
turned up **zero documented success stories of Fusion 360 on winewayland.drv**.
Every working configuration in public - including the canonical
cryinkfly/Autodesk-Fusion-360-on-Linux project - uses **XWayland (winex11.drv)**,
either on an X11 session or by letting wine auto-pick X11 when `DISPLAY` is set.

The wine MRs that would plausibly fix our remaining symptom cluster are mostly
**already in wine 11.10** (!6323 child-window GL/VK, !6452 client surface
relocation, !8468 detach-storm guard, !9679 update-callback positioning, !9204
layered-window mouse passthrough). The single missing one, **!4641 (apply
surface configuration during Vulkan presentation)**, is a 9-line addition
targeting `check_queue_present` - a function that **no longer exists** in
11.10's heavily-refactored `vulkan.c`. Direct cherry-pick is not possible.

We are pioneering. The fusion-box pipeline keeps working on `winewayland.drv` as
a diagnostic / upstream-track build. For day-to-day Fusion use, route through
XWayland with a per-app override:

    wine reg add 'HKCU\Software\Wine\AppDefaults\Fusion360.exe\Drivers' /v Graphics /d x11 /f

## Current symptom state

### Fixed by our wine patches

- `wine-patches/0001-...` (SSD via wine MR !10259) - window drag / resize / title
  bar clicks. Without it KDE Plasma 6 draws decoration on top of wine's surface
  and clicks at the edge are eaten by KWin-as-resize.
- `wine-patches/0002-...` (stop `wl_subsurface_place_above` thrash in
  `reconfigure_subsurface`) - restored visibility of bottom toolbar, comments
  panel, and ribbon tooltips. Per Wayland spec, `place_above(sub, parent)` puts
  `sub` IMMEDIATELY above the reference in the substack; multiple siblings all
  re-asserting against the same anchor on every frame meant only the
  last-called sibling stayed topmost.
- `wine-patches/0003-...` (xdg_popup support) - CREATE dropdown, extrude menu,
  ribbon tooltips, sketch palette. WS_POPUP-with-owner windows now create an
  xdg_popup anchored to the owner's xdg_surface; without this they were
  free-floating xdg_toplevels that KWin placed arbitrarily. The patch also
  relaxes the WS_EX_LAYERED-without-attribs visibility gate for WS_POPUP (Qt6
  marks QMenu/tooltips layered for drop-shadow without ever calling
  SetLayeredWindowAttributes).
- `wine-patches/0004-...` (multimon coord fix) - fixed CREATE menu position,
  resolution-dependent ribbon click/hover dead zones, sketch palette cropping,
  viewport edge-resize cursor zones. Root cause was `wayland_add_device_modes`
  not stamping `dmPosition` on the modes array, so `win32u/sysparams.c`'s
  `physical = *modes` collapsed all monitor geometry to (0,0). Same bug class
  as winex11.drv's 2019 fix (commit `23b28323cb`, bug #37709).
- Sign-in pipeline (`adskidmgr://` callback -> IDM token exchange) - works
  end-to-end via a host browser MIME handler; see `scripts/adskidmgr-handler.sh`
  (registered by `scripts/install-host-handler.sh`).
- Sign-in dialog black-render - forcing `winewayland.drv` via WINEDLLOVERRIDES
  (instead of the default X11->XWayland chain that breaks Qt 6.8.3 raster paint
  on NVIDIA Open). Tradeoff: this is precisely the choice making us pioneers;
  XWayland would also paint correctly.

### Open - winewayland-specific

- **Navigation toolbar (bottom-center orbit/pan/zoom/fit) does not render
  after splash dismisses.** Widget identified 2026-06-08 as a
  Qt683QWindowIcon WS_CHILD at (1161,1285)-(1400,1309) 239x24, parented to
  another WS_CHILD container. Qt6 paints its pixels into **main's GDI
  window_surface** (Path A in the architectural model below). The widget
  itself does not have a wayland_surface - `wayland_win_data_create_wayland_surface`
  never fires for it because `surface == NULL` (Qt didn't allocate a GDI
  window_surface for this widget; it paints into the parent's). Each of
  the parent-chain Qt6 widgets (the viewport widget at (3,120)+2554x1195
  is the relevant one) has its own `wayland_client_surface` allocated via
  `wayland_vulkan_surface_create`, presenting an opaque DXVK swapchain as
  a sibling `wl_subsurface` of main. **Per Wayland protocol, every
  subsurface renders above its parent's buffer.** Main's buffer holds the
  nav toolbar's pixels but is always at the bottom of the tree, so the
  viewport widget's white swapchain (and the other parent-chain client
  subsurfaces) inherently cover the toolbar.
  No subsurface z-order shuffling can fix this - the protocol forbids
  main's buffer from being above its children. This is the architectural
  mismatch between Qt6's render model and wine's
  wayland_surface↔window_surface coupling. See `docs/bottom-toolbar-burial.md`
  "## 2026-06-08 follow-up - architectural root cause" for the
  diagnostic evidence (PPM captures, reconfigure_client trace, parent
  chain probe) and a discussion of why each of the candidate fix paths
  (Qt6 upstream, invasive wine change, XWayland fallback) is or isn't
  tractable.

- **Object Browser, Comments menu, ribbon tooltips disappear after maximize.**
  Originally (pre-2026-06-08) this bullet was conflated with the bottom
  toolbar issue - re-attributed this session. Separate symptom from the
  navigation toolbar bug above; investigation has not focused on it.
- **Object Browser click flicker + cursor disappears.** Click on a tree item
  flickers the dock; cursor vanishes while pointer is over the dock. Suspect
  cursor-shape race in `wayland_pointer.c`.
- **Popups stay visible when parent toplevel is minimized.** xdg-shell has no
  minimize event, so wine doesn't propagate WM_SHOWWINDOW SW_PARENTCLOSING to
  owned popups - toolbar / dropdowns persist over other apps.
- **Horizontal window resize leaves echo / artifact trails.** Vertical resize
  clean. Likely subsurface buffer not invalidated promptly on width change.
- **Ribbon tooltip font issues.** Tooltips render but text looks wrong. Likely
  font fallback or DPI mismatch within Qt.
- **Window stretches across monitors when launched from non-primary 1080p
  display.** `SM_CXSCREEN`/`SM_CYSCREEN` report the primary's (Acer 2560×1440)
  dimensions; Fusion sizes to that even on a smaller monitor. Workaround: park
  cursor on the primary before launch.

### Open - Win32-side / Fusion-side, not winewayland

- **"Sign in Failure" dialog on first OAuth.** FremontJs health watchdog
  reports it can't be brought back up; clicking OK lets Fusion retry with the
  cached token and succeed. `NsFremontJs10.dll` loads cleanly. Noise, not
  blocker. (`WINEDEBUG=+seh,+module,+fixme` during the health-check window
  would catch the failing API.)
- **Dock click off by ~1 tree row.** Verified empirically: wine delivers
  correct screen coords to Win32, `NtUserGetCursorPos` matches wayland's last
  reported coord exactly. Downstream of wine - in Qt's hit-test or Fusion's
  widget logic.

## Architectural model - how Qt6 widgets land in winewayland

Qt6 windows in Fusion split into two disjoint render paths, distinguished by
`WS_EX_LAYERED`:

**Path A - LAYERED widgets (browser dock, sign-in dialog, ribbon child
widgets).** No DXVK swapchain. Qt paints them into MAIN window's GDI surface
as part of the parent's render. Their own per-HWND `wl_surface` (subsurface of
main) carries no visible pixels. Render correctly at the right screen position
because main paints everything.

**Path B - non-LAYERED dock/overlay widgets (bottom toolbar, viewport
children).** Has a DXVK swapchain -> `wayland_client_surface` (Vulkan WSI
target). The client's `wl_subsurface` is parented to the widget's own
`wl_surface`, which is itself a subsurface of main. SUBSURFACE wl_surfaces
have a position constraint: `wayland_surface_reconfigure_subsurface` only
updates position when `processing.serial && processing.processed` are set,
which `wayland_surface_update_state` does set (=1) for SUBSURFACE-role
surfaces. So position IS applied - both for the widget's wl_surface and for
the nested client wl_subsurface.

The remaining z-order problem: Fusion creates 5+ Qt683QWindowIcon WS_CHILD
windows at (3, 3, 2554, 1362) - all parented to main, all with their own
client_surface, all sibling subsurfaces of main. With our patch 0002 in place
(no `place_above` thrash), they retain their initial stacking order. But that
initial order is "newest on top," and the viewport children happen to be
created after the bottom toolbar. Result: toolbar buried.

We did NOT find a clean, targeted fix from inside winewayland.drv. The
plausible attempts all regressed something else (see Failed Attempts below).

## Failed attempts - don't repeat

Listed so future sessions don't loop through them again.

### Z-order / subsurface stacking

- **Skip `wl_subsurface_destroy` in `wayland_surface_clear_role` for the
  SUBSURFACE case** - broke browser and view navigator panels (those depend
  on the destroy as part of legitimate role transitions during dock/undock).
- **Remove the `NtUserIsWindowVisible(hwnd)` gate at `window.c:519`** - caused
  a system lockup (mouse died, audio kept playing, hard shutdown required).
  The gate is load-bearing in a KWin-side invariant; removing it creates an
  attach/commit storm that wedges KWin. **DO NOT TRY AGAIN.**
- **Naive occlusion check** - eliminating subsurface presentation for
  occluded widgets corrupted unrelated docks because Qt's paint model relies
  on its own visibility tracking, not on what's visually onscreen.
- **Promote a SUBSURFACE-role widget's client to attach directly to the
  toplevel HWND** - empirically works for positioning (`NtUserMapWindowPoints`
  goes from no-op to proper translation), but didn't help toolbar visibility
  because the stack order issue is one layer up.
- **`wl_subsurface_place_above(sub, parent_wl_surface)` to promote** - per
  Wayland spec, ref=parent puts sub at the BOTTOM of the substack
  (z=1 = "immediately above parent"). Sank Comments and tooltips instead of
  promoting toolbar.
- **`wl_subsurface_place_above(viewport_client, parent_wl_surface)` to sink
  the viewport to the bottom** - broke tooltip rendering. Tooltips and the
  viewport hit the same code path through `wayland_client_surface_attach`,
  and the sink-on-self-attach heuristic moved tooltips below other siblings.
- **Use SetWindowRgn as a "this is an overlay, promote it" signal** - Qt
  calls `SetWindowRgn` on every Qt window for shaped-window support; not a
  useful discriminator.

- **Patch 0005 - toolbar z-promotion via place_above + parent commit**
  (tested 2026-06-08, three revisions; reverted same day). Maintained a
  list of "toolbar" wayland_surfaces per parent_data plus a list of
  attached wayland_client_surfaces, walked them at toolbar registration
  and on every new sibling's make_subsurface to keep the toolbar above
  every client. WAYLAND_DEBUG=1 capture confirmed 19 `wl_subsurface.place_above`
  + parent `wl_surface.commit` calls hit the wire correctly, KWin
  acknowledged (no protocol errors, pointer.enter delivered to toolbar's
  wl_surface). **Visual outcome: zero change.** Cause: targeted the wrong
  widget - `Qt683QWindowToolSaveBits` HWND at left-bottom (the timeline,
  which renders fine) instead of the actual missing navigation toolbar
  (`Qt683QWindowIcon WS_CHILD` at center-bottom, which has no
  wayland_surface at all). Don't try the patch again as-written. If
  re-attempted, target a fundamentally different widget AND verify the
  widget has a wayland_surface (run probe-windows.c + grep
  `create_wayland_surface` for the candidate HWND first).

### DXVK / viewport black-flap (from earlier session)

- **`dxvk.conf` `dxgi.syncInterval=1, dxgi.numBackBuffers=1`** - violates
  Vulkan FIFO minimum and breaks Qt rendering too.
- **Cherry-pick MR !4641** - `check_queue_present` no longer exists in 11.10's
  refactored `vulkan.c`; the patch's anchor point is gone.

### Multi-monitor / display enum

- **One-line `dmPosition` stamp in `wayland_add_device_modes`** (the clean
  version of patch 0004) - caused an OOM during Fusion startup
  (`err:virtual:map_view anon mmap error Cannot allocate memory, size
  0x6ffff0700000`). Patch 0004 takes a more elaborate route (preserve position
  in primary-shift path) that avoids the OOM.

## Reference - upstream wine MRs touched on

Already merged into wine 11.10 (verified by inspecting our build's source):

- !6323 - winewayland: Support GL/VK rendering in child windows (alt) -
  foundational MR for child-window GL/VK via `wl_subsurface`.
- !6452 - Move client surface to wayland_win_data.
- !6248 - Add missing default surface fallback in WindowPosChanging().
- !8468 - Only detach/attach client surface if it is different (bug 58423).
- !9679 - Update client surface position in update callback (bugs 57393,
  59061).
- !9204 - Pass through mouse events for transparent, layered windows.
- !10259 - zxdg_decoration_v1 SSD support (backported manually as our patch
  0001 before it landed upstream).

Targeted, not in 11.10:

- !4641 - Apply surface configuration during Vulkan presentation. Anchor
  function `check_queue_present` no longer exists in 11.10's `vulkan.c`;
  direct cherry-pick fails. Equivalent functionality may have been folded
  into `ensure_window_surface_contents` (which DOES do
  `wayland_surface_reconfigure` when `processing.serial && processed` -
  identical guard, different call site). Worth re-checking against wine 12.x
  if we revisit.

## Reference - third-party precedent

Confirmed via web research that the following projects all bypass
`winewayland.drv` for Fusion-class apps:

- **cryinkfly** (`Autodesk-Fusion-360-on-Linux`, archived GitHub ->
  migrated to Codeberg) - recommends X11 session or Wayland with default
  X11-via-XWayland routing; no `winewayland.drv` configuration.
- **GE-Proton 10.x** - Wayland enabled via the em10 patch series, but
  GE-Proton10-31 reverted a Wayland systray patch from 10-30 due to crashes.
  Stability bar is "play games, not run CAD".
- **Lutris's Fusion installer** - uses Gallium Nine in DX9 mode, sidestepping
  both DXVK and Wayland.
- **Vinegar (Roblox under wine)** - the only mainstream multi-swapchain
  Qt-ish app surviving on wine. Uses an X11-side `childwindow.patch`
  (XComposite), not a Wayland equivalent.

There is no `WINE_FORCE_X11` env var. The per-app override path is:

    HKCU\Software\Wine\AppDefaults\Fusion360.exe\Drivers\Graphics = "x11"

Setting `Graphics=x11,wayland` makes wine choose X11 first and fall back to
Wayland - preserving Wayland for other apps in the same prefix.
