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
- `wine-patches/0009-...` (sync non-vsub SUBSURFACE child positions on
  toplevel commit) - **fixed right-edge artifact echoes after horizontal-
  shrink resize.** Subsurface child positions only update via
  `reconfigure_subsurface`, gated on `processing.serial && processed` -
  set only on role-change paths. Non-role-change `WindowPosChanged` events
  during resize left the gate closed, so the wl_subsurface stayed at its
  last reconfigured local position. When main shrank horizontally, Browser
  / Comments / ribbon-area sibling subsurfaces remained at their OLD x
  positions past main's new right edge, visible as echo artifacts (xdg-shell
  doesn't clip subsurfaces at `set_window_geometry`). Patch extends patch
  0006's vsub iteration in `set_window_surface_contents` to also call
  `wl_subsurface_set_position` for non-vsub SUBSURFACE children using their
  current screen rect, plus a second `wl_surface_commit` on main at the end
  of iteration to flush the queued positions atomically. Verified
  2026-06-11; horizontal shrink artifacts now self-correct within a few
  frames instead of persisting until click. Does NOT fix vertical-shrink
  timeline disappearance or vertical-shrink navbar-blank-white (those have
  the same root cause but are Qt deferred-paint timing, not addressable
  from wine - see Open list).
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
- ~~**Horizontal window resize leaves echo / artifact trails on the right edge**~~
  **Fixed by patch 0009 (2026-06-11)** - artifacts now self-correct
  within a few frames after resize; click no longer required.
- **Bottom timeline disappears AND navbar renders blank-white on vertical
  shrink** (investigated 2026-06-10 evening + 2026-06-11; partial fix
  shipped as patch 0009 for horizontal artifacts; vertical shrink remains
  open). Top-to-bottom vertical shrink (drag the top edge down, OR pull
  bottom edge up): bottom timeline (Qt683QWindowToolSaveBits at left-bottom
  of viewport) vanishes, AND navbar (Qt683QWindowIcon vsub from patch 0006)
  renders as a blank white rectangle at the correct position with no
  buttons visible. Grow direction is clean for both. Two related but
  separable mechanisms:
  - **Timeline mechanism**: timeline is a Qt6 native widget (selfroot in
    Win32 but a SUBSURFACE child of main in Wayland terms). Its Win32 rect
    is set by Qt's deferred-layout system in response to WM_SIZE. Qt
    DOESN'T necessarily call SetWindowPos on every pixel of resize - layout
    is batched. So even with patch 0009's atomic position-sync at main's
    commit, we read `NtUserGetWindowRect(timeline)` and get Qt's last-set
    position, which may be slightly stale relative to main's current
    height. We faithfully position the wl_subsurface there → KWin clips
    via window_geometry → timeline disappears.
  - **Navbar-blank-white mechanism**: navbar is patch 0006's vsub - it has
    no own buffer; instead, main's GDI shm_buffer is attached to the
    navbar's wl_surface with a `wp_viewport_set_source` crop at the
    navbar's screen-rect-within-toplevel. During rapid vertical shrink,
    Qt hasn't fully painted widgets to main's new (smaller) GDI buffer
    yet when wine flushes it. The crop region for the navbar in main's
    buffer is empty (white default) → navbar renders blank white at the
    correct position.
  - **Both mechanisms** point to Qt's deferred paint/layout timing as the
    actual root cause. Wine-side spikes exhausted (see Failed Attempts
    below): patch 0009 v1-v8 wine-side attempts + 2026-06-11 Qt env-var
    spike (`QT_USE_NATIVE_WINDOWS=1`, `QT_QPA_UPDATE_IDLE_TIME=0`,
    `QT_NO_FAST_MOVE=1`) all failed to move the needle. Plateau reached;
    further progress likely needs Qt build infrastructure to patch
    Qt's WM_SIZE handler for synchronous-layout, OR a careful patch 0006
    refactor to detect "Qt hasn't painted yet" and defer the vsub commit
    until Qt has flushed. Both are multi-day projects.
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
- **Various "update child subsurface positions during resize" patches**
  (tested 2026-06-10 evening, all reverted). Attempted fixes for the
  horizontal artifacts + timeline-on-vertical-shrink bugs. All seven
  iterations correctly identified the gating issue in
  `wayland_surface_reconfigure_subsurface` (`processing.serial && processed`
  set only on role changes) but none landed cleanly:
    1. Set `processing.serial = 1` on every WindowPosChanged for any
       SUBSURFACE-role surface. Broke the navbar because patch 0006's
       virtual_buffer vsubs use a separate position path
       (`NtUserGetWindowRect` minus `toplevel_rect` inside
       `set_window_surface_contents`'s vsub iteration) and our path raced
       with theirs.
    2. Same as 1, but excluded `virtual_buffer` surfaces. Navbar OK, but
       timeline only intermittently survived shrink - the
       `processing.serial` flag we set was overwritten before the next
       `reconfigure_subsurface` call.
    3. Same as 2, plus explicit `wayland_surface_reconfigure(surface)`
       call after setting the flags. The reconfigure_subsurface path
       does `wl_surface_commit(toplevel_surface->wl_surface)` at the end,
       which prematurely committed main BEFORE patch 0006's vsub buffer
       attach ran in the same `set_window_surface_contents` cycle. Result:
       navbar's wl_surface had no buffer attached at main commit time →
       rendered blank white.
    4. Same as 2, but called `wl_subsurface_set_position` directly without
       going through `wayland_surface_reconfigure` (no parent commit, just
       queue the position request). Still didn't fix horizontal artifacts;
       hover-race confound made navbar evaluation unreliable.
    5. Pre-commit walk: a helper `update_subsurface_positions_for_toplevel`
       called from `set_window_surface_contents` JUST BEFORE
       `wayland_surface_attach_shm` and `wl_surface_commit` on main, walking
       the wayland_win_data rb tree and queuing position requests for all
       SUBSURFACE children. Position calc used `entry->rects.window.left`
       directly - which is PARENT-relative (per patch 0006's own comment)
       and wrong for deeply nested WS_CHILDren like the navbar. Navbar
       oscillated visibly as our walk set it to wrong pos, then patch 0006
       set it to correct pos one frame later.
    6. Same as 5 but using `NtUserGetWindowRect` for screen-relative
       coords, AND excluding `virtual_buffer` surfaces so patch 0006's
       handling for the navbar is undisturbed. Walked every paint cycle
       (~100 times/session). User reported navbar black at start, possibly
       hover-race confound, possibly walk fighting state too aggressively.
    7. Same as 6 but gated to fire only when the toplevel buffer SIZE
       actually changed (added `last_committed_buffer_{width,height}` to
       wayland_win_data). Reduced walk to resize events only. Still saw
       timeline disappearing on shrink and navbar white (under hover-race).
    8. `NtUserExposeWindowSurface(hwnd, 0, NULL, 0)` at the end of
       `wayland_configure_window` (force a buffer flush on every configure,
       not just initial). 36 configure invocations per session - no
       improvement on right-edge artifacts. Confirms the bug isn't a
       missed repaint; it's stale subsurface positions.
  Lessons: (a) the fix needs to fully respect patch 0006's vsub timing -
  vsubs use NtUserGetWindowRect inside `set_window_surface_contents` and
  set wl_subsurface_set_position AFTER main's commit (one-frame lag that
  was working). Any fix that commits main earlier or fights for the same
  control breaks vsubs. (b) The hover-race (patch 0007 dampener fires
  60+ times in a bad startup) heavily confounds visual evaluation. Future
  attempts should isolate from it. (c) The "click dismisses artifacts"
  pattern is real but isn't from a missed repaint - main commits 65+ times
  per session; the artifacts are subsurfaces stuck at OLD x positions,
  visible because xdg_surface.set_window_geometry doesn't clip subsurfaces
  per xdg-shell spec.
  Iteration 9 of the design (the one that shipped as patch 0009) finally
  landed for horizontal artifacts by unifying patch 0006's vsub iteration
  with a non-vsub branch (just position update, no buffer attach) plus a
  second wl_surface_commit on main at end of iteration to flush the queue.
  Vertical-shrink timeline + navbar-white still fail because they're
  bounded by Qt's deferred paint/layout, not by the gate this patch
  addresses - see Qt env-var spike below.
- **Qt env-var spike** (tested 2026-06-11). Three Qt 6.8.3 env vars
  expected to unlock more eager paint/layout behavior, all tested in
  combination with patch 0009 active:
    - `QT_USE_NATIVE_WINDOWS=1` (sets Qt::AA_NativeWindows, makes every
      QWidget a real Win32 HWND with own winId) - no observable effect on
      timeline disappearance OR navbar-blank-white. Same HWND-create count
      as baseline (~126), suggesting either Fusion's QPA already creates
      most widgets as native, OR the env var didn't reach Fusion's Qt
      instance, OR Qt's deferred layout doesn't change with native windows.
    - `QT_QPA_UPDATE_IDLE_TIME=0` (reduce paint-idle delay from default 5ms
      to 0) + `QT_NO_FAST_MOVE=1` (disable move-without-repaint optimization
      in QWidgetRepaintManager) - no observable effect. Tested in combination
      with patch 0009 active + a clean (no hover-race) startup.
  Verdict: env-var path to Qt-side fixes is exhausted. To address the
  vertical-shrink class of bugs would need actual Qt build infrastructure
  (mingw-w64 cross-build of qtbase in distrobox; ~1 day infra investment;
  then targeted patch to QWindowsWindow's WM_SIZE handler to force-
  synchronous layout).
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
