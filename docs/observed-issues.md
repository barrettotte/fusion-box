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
  `reconfigure_{client,subsurface}`) - restored visibility of bottom toolbar,
  comments panel, ribbon tooltips, splash dismissal, object browser stability.
  Per Wayland spec, `place_above(sub, parent)` puts `sub` IMMEDIATELY above
  the reference in the substack; multiple siblings all re-asserting against
  the same anchor on every frame meant only the last-called sibling stayed
  topmost. **Verified safe and load-bearing 2026-06-09.**
- `wine-patches/0003-...` (keep client subsurface alive across detach) -
  **verified 2026-06-09.** Half A: skips wine's destroy-on-soft-detach in
  `wayland_client_surface_attach`, preserving sibling z-order across
  focus/configure cycles. Half B: walks the wayland_win_data rb tree at
  `wayland_surface_destroy` time to tear down any client subsurfaces
  whose parent toplevel is dying, avoiding the `wl_subsurface error 0:
  no parent` KWin termination Fusion's comment-menu dismiss originally
  triggered. Originally bundled with 0002; split out 2026-06-09.
- `wine-patches/0004-...` (xdg_popup support) - CREATE dropdown, extrude menu,
  ribbon tooltips, sketch palette. WS_POPUP-with-owner windows now create an
  xdg_popup anchored to the owner's xdg_surface; without this they were
  free-floating xdg_toplevels that KWin placed arbitrarily. The patch also
  relaxes the WS_EX_LAYERED-without-attribs visibility gate for WS_POPUP (Qt6
  marks QMenu/tooltips layered for drop-shadow without ever calling
  SetLayeredWindowAttributes).
- `wine-patches/0005-...` (multimon coord fix) - fixed CREATE menu position,
  resolution-dependent ribbon click/hover dead zones, sketch palette cropping,
  viewport edge-resize cursor zones. Root cause was `wayland_add_device_modes`
  not stamping `dmPosition` on the modes array, so `win32u/sysparams.c`'s
  `physical = *modes` collapsed all monitor geometry to (0,0). Same bug class
  as winex11.drv's 2019 fix (commit `23b28323cb`, bug #37709).
- `wine-patches/0006-...` (virtual subsurface for occluded Qt6 WS_CHILD widgets)
  - **fixed the nav toolbar burial** documented in `docs/bottom-toolbar-burial.md`.
  The center-bottom navigation toolbar (orbit/pan/zoom/fit) is a Qt6
  WS_CHILD widget that paints into main's GDI buffer; sibling DXVK widgets
  present through their own wl_subsurfaces and bury it. Patch synthesizes a
  wl_subsurface for the toolbar (small WS_CHILD with no client_surface),
  attaches main's GDI buffer to it with a wp_viewport_set_source crop on
  every parent commit. Same buffer-extraction pattern Qt6's own native
  QtWaylandClient platform uses. Verified 2026-06-09 on Fusion 360.
- `wine-patches/0008-...` (raise overlay siblings above re-anchored
  client subsurface) - **fixed nav toolbar / Object Browser / Comment menu
  disappearing after sketch entry/exit, viewport scroll out/in, maximize,
  CREATE menu items, component activate, Browser undock**. When Qt6
  reanchors a DXVK swapchain to a new toplevel parent, wine's
  `wayland_client_surface_attach` destroys the old `wl_subsurface` and
  creates a fresh one via `wl_subcompositor.get_subsurface`. Per Wayland
  spec, the new subsurface lands at the TOP of the parent's substack,
  burying sibling overlay subsurfaces (patch 0006 vsubs, Browser /
  Comments docked panels). Patch walks the wayland_win_data rb tree
  after every re-anchor and `place_above`'s each overlay sibling on the
  freshly-anchored client. Same family as patch 0002 (which removed the
  per-frame `reconfigure_*` thrash) but covering the per-event re-attach
  path that 0002 left uncovered. Verified 2026-06-10 against Fusion
  v2703.1.11 on KDE Plasma 6 Wayland; 12 `(re)anchor` events per typical
  session, sketch cycle lifts raised=5 siblings each direction.
- `wine-patches/0007-...` (Qt6 docked-panel role-thrash dampener + HCURSOR on
  `wayland_win_data`) - **fixed the Object Browser cursor-disappear and
  click-flicker bugs.** Qt6 reparents WS_POPUP docked panels between
  `Browser->main->desktop` and `Browser->desktop` chains across user
  interaction; the two chains return different `NtUserGetAncestor(GA_ROOT)`
  values, which made wine's role decision flip SUBSURFACE↔POPUP on every
  click, destroying and recreating the wayland_surface each time (visible
  flicker, lost cursor state). Two fixes: (a) moved `HCURSOR` from
  `wayland_surface` to `wayland_win_data` so it survives any future
  wayland_surface destroy/recreate; (b) dampened the role flip when the
  popup owner and existing toplevel_hwnd match - they're the same logical
  parent. Verified 2026-06-10 on Fusion 360.
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

- ~~**Object Browser, Comments menu, ribbon tooltips disappear after maximize.**~~
  **Fixed by patch 0008 (2026-06-10).** Same root cause as the sketch-exit
  bug below; the maximize trigger is just another path that calls
  `wayland_client_surface_attach` with a toplevel change.
- ~~**Navigation toolbar, Object Browser, Comment menu disappear after sketch
  entry/exit (and viewport scroll-out) and never reappear**~~ **Fixed by
  patch 0008 (2026-06-10).** Investigation arc and final diagnosis:
    - Initial (wrong) hypothesis 1: SWP_HIDEWINDOW not balanced by
      SWP_SHOWWINDOW. Tested via interception + forced re-show in
      `WAYLAND_WindowPosChanged`. Intercept fired, vsub was recreated, but
      visual outcome unchanged. Falsified.
    - Initial (wrong) hypothesis 2: destroy-without-recreate. Believed
      Fusion called `NtUserDestroyWindow` on the toolbar HWND mid-session.
      Falsified by a controlled 30-second-wait reproducer + stable-
      identifier logging (`fb_log_widget` at every destroy/hide event,
      keyed by widget class+text+rect not HWND ID): the destroys we'd
      attributed to sketch-exit were actually at 99% of run i.e. shutdown
      cascade. The navbar HWND committed buffers continuously during the
      30s wait, never destroyed mid-session.
    - User observation that broke the case open: "on shutdown sometimes I
      see our mystery UI components rendering" - the widgets exist,
      they're visually buried.
    - Final (correct) diagnosis: z-order. When Qt6 reanchors the
      viewport's DXVK swapchain to a new toplevel parent at sketch
      transitions (and similar events), wine's
      `wayland_client_surface_attach` takes the toplevel-change branch,
      destroys the old `wl_subsurface`, and creates a new one via
      `wl_subcompositor.get_subsurface`. Per Wayland spec, the new
      subsurface lands at the TOP of the parent's substack. Sibling
      overlay subsurfaces (navbar vsub from patch 0006, Browser /
      Comments docked panels in SUBSURFACE role parented to main) get
      pushed below the swapchain, which covers their screen positions.
      Patch 0008 walks the wayland_win_data rb tree after every
      client-subsurface re-anchor and calls `wl_subsurface_place_above`
      on every overlay sibling to lift them back. Verified: 12
      `[fusion-box patch 0008] client (re)anchor` events in a typical
      session; 2 of them (sketch entry + exit) raise raised=5 siblings
      each, exactly matching the 5 visible static UI elements that
      previously vanished. Same family of bug as patch 0002 (per-frame
      `reconfigure_*` thrash), which left the per-event re-attach path
      uncovered.
- ~~**Object Browser click flicker + cursor disappears.**~~ **Fixed by patch
  0007 (2026-06-10).** Root cause was Qt6 reparenting the WS_POPUP Browser
  between two parent chains across click, flipping the wine role decision
  SUBSURFACE↔POPUP and destroying+recreating the wayland_surface. See
  patch 0007's header for the full diagnosis.
- **Popups stay visible when parent toplevel is minimized.** xdg-shell has no
  minimize event, so wine doesn't propagate WM_SHOWWINDOW SW_PARENTCLOSING to
  owned popups - toolbar / dropdowns persist over other apps.
- **Horizontal window resize leaves echo / artifact trails.** Vertical resize
  clean. Likely subsurface buffer not invalidated promptly on width change.
- **Bottom timeline disappears on window resize** (noticed 2026-06-10 during
  patch 0008 validation). The timeline (small Qt683QWindowToolSaveBits at
  left-bottom of the viewport) vanishes when the Fusion window is resized.
  Patch 0008 doesn't cover it: the timeline is a selfroot TOPLEVEL/POPUP-
  role widget (not a SUBSURFACE child of main's wl_surface), so it's not
  a sibling in main's substack and the sibling-raise walk doesn't reach
  it. Separate code path; needs its own investigation.
- **Workspace switch (Design ↔ Render ↔ Drawing dropdown)** - patch 0008
  validation deferred this; some looked promising, others surfaced
  additional rendering bugs. Future investigation.
- **Section analysis** - deferred during patch 0008 validation.
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
- **Intercept `SWP_HIDEWINDOW` in `WAYLAND_WindowPosChanged` and force
  re-show via `NtUserSetWindowPos(SWP_SHOWWINDOW)` for vsub-tracked
  children** (tested 2026-06-10, reverted same session). Built on the
  belief that the sketch-exit navbar disappearance was a
  hide-not-restored bug. The intercept fired but the visual outcome was
  unchanged; trace then misread shutdown destroys as sketch-exit destroys
  ("destroy-without-recreate" diagnosis - also wrong). The actual bug
  was z-order, not lifecycle - fixed by patch 0008. Lesson: when a
  symptom only manifests visually but tooling shows no
  lifecycle/visibility change, suspect stacking; controlled reproducers
  with explicit gaps between phases (e.g. 30s wait between sketch-exit
  and close) are essential for disambiguating "this destroy is part of
  the bug" from "this destroy is shutdown cleanup".

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
  version of patch 0005) - caused an OOM during Fusion startup
  (`err:virtual:map_view anon mmap error Cannot allocate memory, size
  0x6ffff0700000`). Patch 0005 takes a more elaborate route (preserve position
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
  X11-via-XWayland routing; no `winewayland.drv` configuration. The
  patched DLLs shipped under `files/extras/patched-dlls/` (audited
  2026-06-10) are scoped narrowly and do NOT touch the QPA / QtWidgets
  paths we care about:
    - `Qt6WebEngineCore.dll` (140 MB binary, no source) - per install
      script comment line 1685 "fix the login issue and other issues":
      patches the embedded Chromium / Blink renderer used for Fusion's
      OAuth sign-in HTML page and asset library marketing UI. Likely
      sandbox / namespace / seccomp workarounds for Chromium under wine.
      **Does not affect nav toolbar, Browser, Comments, or any QtWidgets
      rendering** - those live in `Qt6Widgets.dll` / `Qt6Gui.dll` which
      cryinkfly ships unmodified.
    - `siappdll.dll` - 3DConnexion SpaceMouse driver shim. Unrelated to
      Qt or rendering; "fix the SpaceMouse issue" per script comment.
    - `bcp47langs.zip` - registry override (set as empty
      `DllOverrides`), not a binary patch.
    - `files/setup/data/wine-captionless-popups.patch` - one-line
      `winex11.drv` patch making captionless `WS_POPUP` windows
      unmanaged. Doesn't apply to `winewayland.drv` (we don't have the
      same window-manager-wrapping model). No analogous fix needed.
    - `files/setup/data/fix-navbar-flicker.sh` - **not a code patch,
      a user-prefs editor**. Sets `Contents="NavToolbar" Visible="False"`
      in Fusion's `NULastDisplayedLayout.xml`. This is cryinkfly's
      workaround for the navbar burial bug - they hide the toolbar in
      Fusion's settings rather than fix the wine layer. We fixed the
      underlying cause in patch 0008 (z-order at client-subsurface
      re-anchor), so the workaround isn't needed here.
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
