# Bottom toolbar burial - focused investigation

Started 2026-06-08. Single open bug from `docs/observed-issues.md` we are now driving
to ground. Working file - update as evidence comes in. When the bug is closed,
fold the conclusions back into `docs/observed-issues.md` and delete this file.

Cross-reference: the umbrella view of all Fusion-on-wayland symptoms lives in
`docs/observed-issues.md`. This doc focuses on **only** the bottom-toolbar burial
and intentionally narrows scope so it stays usable.

> ## ⚠ Status (2026-06-08, multiple sessions)
>
> **This doc's body is misaimed.** Sections below "## The bug, restated"
> discuss the wrong widget. Read the trailing dated sections instead - they
> contain the correct picture in revision order:
>
> - **"## 2026-06-08 PM session - investigation pivot"** identifies the
>   actual missing widget (the center-bottom navigation toolbar, HWND varies
>   per launch, class `Qt683QWindowIcon WS_CHILD`, rect 239x24 at (1161,
>   1285)) and falsifies the original wayland-substack z-order model.
>
> - **"## 2026-06-08 follow-up - architectural root cause"** identifies
>   *why* the toolbar is buried at the actual mechanism level: each
>   QRhi-backed Qt6 widget (the viewport widget, ribbon icons, etc.) gets
>   its own `wayland_client_surface` attached to main as a sibling
>   subsurface, and main's wl_surface buffer (where the nav toolbar's
>   pixels live, painted there by Qt's parent paint cycle) is ALWAYS below
>   every subsurface by Wayland protocol. No subsurface z-ordering can
>   surface main's buffer above its children. The architectural mismatch
>   is structural and matches `docs/observed-issues.md`'s original verdict that
>   no winewayland.drv-only fix exists.
>
> Patches 0001–0004 stand and are still upstream-track. Patch 0005 was
> tested, failed, reverted via `BUILD_WINE_FORCE=1 build-wine.sh`. Don't
> resurrect it - it operated at the wrong layer.

## The bug, restated

Fusion 360's bottom toolbar (Qt683QWindowToolSaveBits, WS_POPUP non-LAYERED,
its own DXVK swapchain) does not appear over the viewport once the main window
is shown. Same disappearance pattern hits ribbon tooltips. Position is correct
when the toolbar's pixels are visible - it is **purely a stacking / occlusion
problem**, not a buffer or geometry problem. Confirmed by:

- **Resize flicker** (2026-06-08, this session): while dragging the main
  window edge, the toolbar briefly shows through. The overlay siblings'
  buffers fall out of sync with the parent during the configure storm, and
  for one frame the toolbar layer is uncovered.
- **Close-time unmask** (2026-06-08): on Fusion exit, the viewport
  swapchain tears down a beat before the rest of the window; the toolbar is
  visible in the gap for ~1 frame before the process is gone.

Both observations rule out the most pessimistic hypotheses: the toolbar's
`wl_surface` has real pixels, is positioned correctly, and is committed to
the compositor. It is just at the **bottom** of a stack of sibling
subsurfaces over the same screen area.

## Architectural recap (one paragraph, for context)

Fusion's main window has on the order of ten sibling subsurfaces of the
main toplevel: the toolbar (small, low-left), several Qt683QWindowIcon
WS_CHILD widgets that each carry their own client_surface covering the
whole content area (Fusion's multi-renderer pattern), and the actual
viewport DXVK swapchain. Per `docs/observed-issues.md`, the WS_CHILD overlays
are created *after* the toolbar, so the toolbar lands at the bottom of the
initial substack. Per Wayland protocol, sibling order stays put until
someone calls `place_above`/`place_below` - so it remains buried for the
life of the window.

That much was already known. What this doc adds is the verification angle:
make sure our own patches aren't part of the problem, and pin down *which*
sibling is the actual occluder, before designing a fix.

## Hypothesis (working, falsifiable)

**H0** - The toolbar's subsurface is at the bottom of the parent's substack;
one or more Qt683QWindowIcon WS_CHILD subsurfaces (which each carry a
full-content-area client surface) sit above it and paint opaque pixels over
the toolbar's screen rect every frame.

**H0a** - The occluder is the viewport DXVK swapchain itself. (Consistent
with the close-time unmask, which is dominated by viewport teardown.)

**H0b** - The occluder is one of the Qt683QWindowIcon overlays, not the
viewport. (Consistent with the resize-flicker reveal, since the viewport
swapchain is typically more resilient through a configure storm than a Qt
overlay redrawn on every WM_SIZE.)

The two sub-hypotheses dictate **different fix shapes**, so distinguishing
them is the first concrete step.

## Are our own patches contributing?

**This is a real risk.** Earlier sessions iterated patches by symptom rather
than by mechanism, and patch 0002's prose specifically calls out a stacking
side-effect of the upstream code that it then turned off. Each patch needs
a one-line answer to "could this be making the toolbar worse?" before we
attribute the bug entirely to upstream.

### Patch 0001 (SSD via MR !10259 backport)

Touches `xdg_decoration` negotiation, `waylanddrv.h` drift. Does **not**
touch subsurface stacking, client_surface lifecycle, or wl_subsurface
ordering. **Plausibility of contribution: ~0.** Skip the rollback test.

### Patch 0002 (place_above thrash + transient detach skip)

This patch does two distinct things and we should be honest about both:

1. **Removes `wl_subsurface_place_above` from `reconfigure_subsurface` and
   from the client_surface_attach reconfigure path.** Upstream wine 11.10
   calls `place_above(sub, anchor)` on every reconfigure. Per protocol, that
   puts `sub` immediately above `anchor` - when many siblings share the same
   anchor (toplevel's wl_surface, or toplevel_data->client_surface), each
   reconfigure puts that sibling at the bottom of the "above-anchor" pile,
   and the previous reconfigurer ends up one step *higher*. Net effect: the
   call order in upstream is "last reconfigured ends up immediately above
   anchor, *not* topmost." Earliest reconfigurers end up topmost.
   Removing the calls leaves siblings in whatever order they were initially
   placed - which is the issue we now have.

2. **Removes the `wl_subsurface_destroy` from `wayland_client_surface_attach`'s
   `if (!toplevel)` path.** Wine upstream tears down the client subsurface
   on any "detach" call and recreates it later. Per protocol, the recreated
   subsurface lands at the **top** of the parent's substack. The patch
   keeps the subsurface alive, removing the natural recreation-promotes-to-top
   side effect.

**Both halves of patch 0002 plausibly contribute to the toolbar burial.**
The patch was written to fix a *different* symptom (toolbar/tooltips
disappearing during steady operation due to per-frame place_above thrash).
But what we removed may have been the only mechanism by which the toolbar
ever got promoted in upstream wine. **Plausibility of contribution: high.
Must do a rollback test.**

### Patch 0003 (xdg_popup support)

Detects WS_POPUP-without-WS_CHILD windows that have an owner and turns
them into `xdg_popup`s instead of `xdg_toplevel`s. The toolbar is
WS_POPUP-non-LAYERED. Does it take this path?

- Gate 1: `style & WS_POPUP` - toolbar passes.
- Gate 2: `!(style & WS_CHILD)` - **unverified.** Qt6's
  WindowToolSaveBits *may* set WS_CHILD; if so, the toolbar stays a
  subsurface and the popup path is irrelevant.
- Gate 3: `!toplevel_surface` - toolbar needs to NOT have a parent
  wayland_surface that's already a toplevel. If Qt makes the toolbar a
  child of main (typical Qt behavior), `toplevel_surface` is set and the
  popup path is skipped.
- Gate 4: owner via GW_OWNER, or WS_EX_TOOLWINDOW fallback to foreground.

The patch's commit prose claims "Bottom toolbar positions correctly when
main is on the user's primary monitor" was FIXED by this patch. But
`docs/observed-issues.md` lists the toolbar as still buried. Both can be true
if the patch only affects the toolbar's initial monitor placement, not its
subsequent burial.

**Plausibility of contribution: medium.** Need to check whether the
toolbar actually takes the xdg_popup path by reading wine's debug log. If
yes, this is *unrelated* to the burial bug because xdg_popups are not
subsurfaces and not in the main's substack at all. If no, the toolbar is
a subsurface - and our concern stays on patch 0002.

### Patch 0004 (multimon dmPosition)

Affects display reporting. The reproducer in patch 0004's prose triggers
OOM when stamped naively - present version preserves the original
primary-shift logic. Does not touch subsurface or client_surface code.
**Plausibility of contribution: ~0.** Skip the rollback test.

## What to do, in order

### Step 1 - Determine the toolbar's actual wayland role

This is the prerequisite for every other step. Without knowing whether
the toolbar is an `xdg_popup` (patch 0003 path) or a `wl_subsurface` of
main (patch 0002 path), we'll design the wrong fix.

Two artifacts answer this in combination:

- **`debug/wine-tests/probe-windows.c`** enumerates the live Win32 window tree
  visible to wineserver and dumps HWND, class name, full
  style/exstyle decoded, GW_OWNER, parent, screen rect for every Qt and
  every WS_POPUP window. It also explicitly evaluates patch 0003's gates
  (`WS_POPUP && !WS_CHILD`, has-owner, WS_EX_TOOLWINDOW) so the role
  decision is readable by hand. Target classes are
  `Qt683QWindowToolSaveBits` (toolbar) and `Qt683QWindowIcon` (overlay
  siblings).
- **`WINEDEBUG=+wayland`** capture during a fresh Fusion launch. Each
  surface's role-creation path emits a TRACE
  (`wayland_surface_make_subsurface`, `wayland_surface_make_toplevel`,
  `wayland_surface_make_popup` after patch 0003). Cross-reference the
  toolbar HWND found by the probe.

Run both at once with:

```bash
# From inside fusion-box. Fusion must NOT be currently running - the
# script launches a fresh tracing instance, waits 45s, runs the probe in
# the same wineserver, then tears down.
bash ~/repos/fusion-box/debug/diagnose-toolbar-role.sh both
```

Output lands in `debug/captures/probe-windows.txt` and
`debug/captures/wayland-trace.log`. The toolbar HWND from the probe
plugs into the trace log to confirm what role it actually took. If the
session needs sign-in, run `diagnose-toolbar-role.sh trace` first, sign
in by hand, then `diagnose-toolbar-role.sh probe` in a second terminal.

Expected discriminator:

- If the probe says **`WS_POPUP && !WS_CHILD` AND owner != NULL AND
  WS_EX_TOOLWINDOW (or fg fallback applies)**, AND the trace shows
  `wayland_surface_make_popup` for that HWND, the toolbar is an
  **xdg_popup**. Patch 0002 is out of scope; we look at patch 0003 or
  upstream.
- If the probe says **WS_POPUP|WS_CHILD or no qualifying owner**, AND the
  trace shows `wayland_surface_make_subsurface`, the toolbar is a
  **wl_subsurface of main**. Patch 0002 is in scope and Step 4's
  subtests are the next concrete move.

### Step 2 - Inventory the substack of main

Build the actual sibling list at three checkpoints: (a) right after Fusion
finishes its splash, (b) right after the first maximize, (c) at steady
state with viewport active. For each sibling: HWND, Qt window class,
style/exstyle, position, size, whether it has a client_surface.

Cheapest implementation: short patch to `wayland_surface.c` to dump a
trace line on every subsurface create/destroy and on every `place_above`
caller (file:line). No protocol calls added; just log.

### Step 3 - Identify which sibling is occluding

Once Step 2 produces the list, intersect each sibling's rect with the
toolbar's known rect (~(7, 1286, 307, 1311)). The occluders are the ones
whose rect contains the toolbar's rect AND who are above it in
substack order. Match against H0a (viewport) vs H0b (overlay) - pick the
sub-hypothesis.

### Step 4 - Test each plausibly-contributing patch in isolation

After Step 1's answer is in:

- **If toolbar takes xdg_popup path** (patch 0003 is in scope, patch 0002
  is not): roll back patch 0003 only and re-test. Confirm the toolbar
  position regresses (cf. patch 0003's stated FIXED-by-this-patch behavior)
  but observe whether burial behavior changes.
- **If toolbar is a subsurface** (patch 0002 is in scope, patch 0003 is
  not): roll back **each half** of patch 0002 independently:
  - Subtest 2A: restore the `place_above` calls, keep the detach-skip.
  - Subtest 2B: restore the destroy-on-detach, keep the `place_above`
    removal.
  - Subtest 2C: roll back the whole patch.
  For each subtest, record: (a) whether the toolbar appears, (b) whether
  the symptoms patch 0002 originally fixed regress, (c) whether anything
  else changes (browser, view navigator, splash, tooltips). The point is
  to find out whether we can have the toolbar visible AND keep the
  symptoms 0002 fixed - not just to roll back blindly.

### Step 5 - Design a fix that doesn't trigger any failed-attempts entry

Read `docs/observed-issues.md`'s "Failed attempts - don't repeat" section in
full before sketching any code. Specifically:

- Do **not** remove `NtUserIsWindowVisible(hwnd)` at `window.c:519` -
  that path caused a system lockup last time.
- Do **not** try `wl_subsurface_place_above(sub, parent_wl_surface)` - it
  puts `sub` at the BOTTOM of the substack per spec, not the top.
- Do **not** rely on `SetWindowRgn` as a "this is an overlay" signal - Qt
  uses it for every shaped window.
- Naïve occlusion checks broke unrelated docks. Skip them.

The promising direction not yet explored: discriminate by client_surface
ownership and use `place_below` (the opposite-direction primitive - there
is no risk of "puts sub at the BOTTOM of the substack" misreading
because place_below is unambiguous). Specifically: after all siblings
exist, walk the toplevel's tracked children list and call
`place_below(overlay, toolbar)` for each WS_CHILD overlay whose
client_surface covers the toolbar's rect. This is one-shot at first
configure rather than per-frame, sidesteps the place_above bottom-
of-pile spec gotcha, and survives 0002's "don't reorder on reconfigure"
invariant.

This is **not yet a proposal** - it's a sketch to validate after Steps 1-3
narrow the search.

## What's already ruled out (failed attempts, kept short here)

Full list in `docs/observed-issues.md`. Highlights worth keeping front-of-mind
because they look superficially relevant:

- Skipping `wl_subsurface_destroy` in `wayland_surface_clear_role` for the
  SUBSURFACE case - broke browser and view navigator.
- Removing the `NtUserIsWindowVisible(hwnd)` gate at `window.c:519` - hard
  lockup. Don't.
- Promoting a SUBSURFACE-role widget's client to attach directly to the
  toplevel HWND - works for position, but didn't help toolbar visibility.
- `wp_viewport_set_destination(0, 0)` as "soft-hide" - non-canonical per
  spec, broke other rendering.

## Patch hygiene - keep edits in sync

`build-wine-fast.sh` syncs source edits from `$WINE_WORK_TREE/dlls/winewayland.drv/`
into the extracted source at `$XDG_CACHE_HOME/fusion-box/wine-build/wine-11.10/`,
runs `make`, and copies `.so` files into the install prefix. Iterating happens
in the cached source tree (or wherever `WINE_WORK_TREE` points). **Patches
under `wine-patches/` are NOT regenerated automatically.** It is easy to spend
a session iterating on `wayland_surface.c` and end up with a working wine but
no diff captured anywhere durable.

Rule of thumb: any time we land an empirical fix and Fusion is happier, before
moving on to the next bug, regenerate the relevant patch from the cached source
tree against a clean `wine-${VERSION}` extracted from the upstream tarball.
Commit the regenerated patch with a short note in the patch header about what
empirical observation it's tied to.

A regen helper is overdue (something like `scripts/regen-patch.sh
<patch-name>` that diffs `$CACHE_DIR/wine-${VERSION}` vs. a fresh extraction
and overwrites the named patch). For now: do it by hand at session end with
`diff -ruN clean/dlls/winewayland.drv working/dlls/winewayland.drv > NEW.patch`
and reconcile against the existing patch's commentary.

This applies to the diagnostic instrumentation we add for this investigation
too - if anything earns its keep, capture it as a patch before the cache is
next blown away.

## Notes on cloned reference repos

The relevant trees the user has under `~/storage/code/github/`:

- `wine/` - at `wine-11.10-124-gb9f5aa42b15`, basically our build's base
  plus 124 commits. Useful for grounding patch line numbers against
  current upstream and checking whether anything we'd patch was already
  changed.
- `dxvk/` - `v2.7.1+`. Useful for understanding what the viewport
  swapchain is doing on `vkQueuePresentKHR` (does it implicitly affect
  parent surface state? probably not - DXVK presents to its own wl_surface
  via WSI).
- `kwin/` - `v6.6.90+`. Useful for confirming how KWin handles a
  sub-surface tree when an opaque sibling covers another. (Per KWin's
  rendering: each subsurface draws its own buffer; the compositor doesn't
  do "is this sibling occluded" optimization, but the topmost opaque pixel
  wins per fragment.)
- `qtbase/` - `v6.8.0-beta1+`. Useful for finding the QWindowToolSaveBits
  HWND-creation path and confirming the WS_POPUP/WS_CHILD/WS_EX_* mask we
  end up classifying.
- `Proton/` - useful for spot-checking whether GE-Proton has any
  Wayland-side toolbar/popup z-order tweak we missed in the earlier
  research pass. (Earlier pass said no, but reverify under the new framing.)
- `Autodesk-Fusion-360-on-Linux/` - cryinkfly's tree. The
  `fix-navbar-flicker.sh` does an XML-edit workaround on Fusion's own
  config; **not** a wine-side fix but worth reading for what UI element
  they identified as the trouble.

## Open questions / parking lot

- Does `wp_viewport` opacity hint exist on KWin's current
  zwp_viewport version? If yes, an "I am opaque over this rect"
  declaration from the toolbar could let the compositor draw it without
  fighting over z-order. (Probably no - viewporter has no opacity hint -
  but worth a 5-min check.)
- Does the toolbar's `wl_surface` have `wp_alpha_modifier` applied? If
  Fusion is rendering it with semi-transparency it could compound the
  problem.
- The "close-time unmask" observation: is it the *viewport's* swapchain
  tearing down that uncovers the toolbar, or is it the Qt overlays?
  Single-stepping the teardown with WINEDEBUG=+wayland,+timestamp should
  show the order of `wl_subsurface_destroy` calls and clearly answer
  which sibling was on top.

## Log

- 2026-06-08 - Doc created. Tasks 1-6 entered in the in-session task
  list. Step 1 is the next concrete action.

- 2026-06-08 - Step 1 complete. Diagnostic run via
  `debug/diagnose-toolbar-role.sh both` produced
  `debug/captures/probe-windows.txt` and `debug/captures/wayland-trace.log`.

  **Toolbar identification.** Bottom toolbar is HWND=0x3013a, class
  `Qt683QWindowToolSaveBits`, title "Fusion360", rect (7,1286)-(307,1311)
  (300x25). Style 0x9e000000 = WS_POPUP | WS_VISIBLE | WS_DISABLED |
  WS_CLIPCHILDREN | WS_CLIPSIBLINGS. Exstyle 0x00000080 = WS_EX_TOOLWINDOW
  (NO WS_EX_LAYERED). Owner=0x2900ea (main toplevel), Parent=0x10020
  (desktop). All three patch-0003 individual gates pass
  (popup&&!child=1, owner=1, toolwindow=1).

  **Toolbar's wayland role.** `wayland_surface_make_subsurface` was the
  path taken - trace log line 9552 shows
  `make_subsurface surface=0x7f7ec8012640 parent=0x55558b4bd920`, where
  0x7f7ec8012640 is the toolbar's surface (from the
  `wayland_win_data_create_wayland_surface hwnd=0x3013a surface=...`
  line at trace 9193) and 0x55558b4bd920 is Fusion main's toplevel
  (appears 8 times in `make_toplevel` calls). The toolbar is a
  **wl_subsurface of main, NOT an xdg_popup**.

  **Why patch 0003's path was skipped.** The outer gate is
  `if (visible && (style & WS_POPUP) && !(style & WS_CHILD) &&
  !toplevel_surface)`. When Qt makes the toolbar a child of main,
  `toplevel_surface` is already set -> popup path skipped -> fallback to
  subsurface. The three "patch 0003 gates" we evaluate in the probe
  evaluate individually true but the `!toplevel_surface` precondition
  short-circuits them. So patch 0003 IS NOT in scope for this bug.

  **Sibling order at create-time (only 3 captured in the 45s window).**

  | order | wayland surface | likely identity |
  |---|---|---|
  | 1 (bottom) | 0x7f7ec801d140 | first subsurface created |
  | 2          | 0x7f7ec8012640 | **toolbar** (HWND 0x3013a) |
  | 3 (top)    | 0x5555910124f0 | third subsurface created |

  Per Wayland spec, a newly-added sub-surface lands at the **top** of the
  parent's substack. Any subsurface created after the toolbar - including
  the viewport DXVK swapchain and the Qt683QWindowIcon overlays
  documented in `docs/observed-issues.md` - auto-sits above it. The toolbar
  is buried by construction order. Patch 0002 didn't introduce this; it
  exposed it.

  **Implication for patch 0002.** Upstream wine 11.10's per-reconfigure
  `place_above(sub, anchor)` calls would have driven each
  reconfigure-er to z=1 (just above the anchor), meaning the LAST
  reconfigure won. Since the viewport reconfigures every frame and the
  toolbar reconfigures only on state change, upstream wine *also* buries
  the toolbar (viewport is the last reconfigurer every frame). Patch 0002
  removed the thrash; it neither fixed nor caused this specific bug. The
  patch is still upstream-track for its other benefits (tooltip and
  popup-menu burial) but doesn't move us closer or further on the
  toolbar.

  **Rolled-up answer to "are our patches contributing?"** No, not in a
  causal sense. Skip the rollback tests in Step 4 - they would have
  measured noise. Patch 0001/0004 already out (no contact). Patch 0003
  out (path not taken). Patch 0002 out (upstream behavior is no better;
  see analysis above).

  **What this points to as Step 5 fix shape.** The toolbar needs explicit
  z-order promotion ONCE, at some defined moment after both itself and
  the viewport are present. Per the "don't repeat" list,
  `place_above(toolbar, parent_wl_surface)` is forbidden (puts toolbar
  at z=1, not topmost). The unambiguous primitive is
  `wl_subsurface_place_below(viewport_client_surface, toolbar)` - this
  always demotes `viewport_client_surface` to just below `toolbar` in
  the substack. Discriminator for "this is the toolbar" candidate that
  doesn't depend on Qt class names: WS_POPUP-non-LAYERED with WS_EX_TOOLWINDOW
  and a visible non-zero-area rect smaller than parent client area.
  Discriminator for "this is the viewport-style overlay": has a
  client_surface attached and rect covers >50% of parent client area.

  Two open questions to resolve before sketching the fix:

  1. The Qt683QWindowIcon WS_CHILD overlays observed-issues.md mentions
     ("5+ subsurfaces full-content-area, each with its own client_surface")
     did not appear in the 3-subsurface trace window. Either they're
     created later (after 45s, post-splash) or the doc's number was from
     a different observation. Re-run the diagnostic with a longer wait
     (~120s past sign-in) to capture the full mature window. Then
     finalize the occluder list before designing the place_below sweep.

  2. The toolbar's create-time rect was (1130,671)-(1430,696) per
     `WAYLAND_WindowPosChanging`, but the probe (after Qt layout
     completes) reports (7,1286)-(307,1311). The intermediate moves
     happen via `wayland_surface_reconfigure_subsurface` which (under
     our patch 0002) does NOT call place_above. Confirm that with
     patch 0002 the toolbar's substack position is unchanged from
     create-time across these moves - should be true by code reading,
     but verify against the trace.

  Tasks: #2 -> completed. #3 -> in_progress. #6 -> completed
  (audit answered: no patches in scope). #4 stays open as a
  sanity-check pass.

  Encoding note: the probe initially printed class names as garbage
  because `wprintf("%ls", ...)` writes raw UTF-16 to stdout. Fixed by
  converting via `WideCharToMultiByte(CP_UTF8, ...)` before printf.
  Channel-name note: `WINEDEBUG=+wayland` is wrong; the channel is
  `waylanddrv`. Both fixes in.

- 2026-06-08 - Step 3 mostly complete. 120s wait re-run captured the
  mature window state.

  **Full subsurface population of main toplevel (wayland_surface
  0x555570cabe70).** Five unique sibling subsurfaces, in creation order:

  | order | wayland surface | HWND | class | rect | notes |
  |---|---|---|---|---|---|
  | 1 (bot) | 0x555571a66200 | 0x4a0144 | Qt683QWindowToolSaveBits | (7,124)-(307,1286) 300x1162 | side panel, WS_POPUP+LAYERED+TOOLWINDOW |
  | 2 | 0x555571a66100 | 0x30152 | Qt683QWindowToolSaveBits | (7,1286)-(307,1311) 300x25 | **TOOLBAR**, WS_POPUP+TOOLWINDOW (non-LAYERED) |
  | 3 | 0x555571e40590 | 0x10160 | Qt683QWindowToolSaveBits | (2550,1310)-(2551,1311) 1x1 | MessageTray, WS_POPUP+LAYERED+TOOLWINDOW |
  | 4 | 0x5555701a05d0 | 0xc01b2 | (not in probe sweep) | n/a | likely Qt683QWindow content child |
  | 5 (top) | 0x5555701a03c0 | 0x701d2 | (not in probe sweep) | n/a | **prime occluder**, re-asserted 9× in trace |

  Surface 0x5555701a03c0 (HWND 0x701d2) calls `make_subsurface` nine
  times in the trace window. Each call goes through `clear_role` ->
  `wl_subcompositor_get_subsurface`, which per Wayland spec places the
  new subsurface at the **top** of the parent's substack. So this
  surface is persistently promoted to topmost - exactly the
  viewport-overlay pattern observed-issues.md described, and the most
  plausible identity is the DXVK viewport (heavy reconfigure cadence).

  The aggregate `wayland_surface_clear_role` call count was 366, which
  is a lot of role thrashing in a 2-minute window - mostly driven by
  the viewport and second-highest-cadence overlay. Patch 0002's
  detach-skip half didn't suppress it; the role thrashing is at a
  different code path (`wayland_win_data_create_wayland_surface` ->
  `wayland_surface_clear_role`, called whenever WindowPosChanged fires
  with a state change).

  **Why side panel & MessageTray don't suffer the same visual bug.**
  Side panel and MessageTray are LAYERED. Per the architectural model
  in observed-issues.md, LAYERED widgets are painted through main's GDI
  surface by Qt - the per-HWND wl_subsurface they own carries no
  visible pixels, so being buried doesn't visually matter. The toolbar
  is the only non-LAYERED Qt683QWindowToolSaveBits among the four; it
  paints into its OWN DXVK swapchain, and burial is visually fatal.

  **Discriminator for "this is the toolbar" with no Qt class
  dependency.** WS_POPUP set, WS_CHILD clear, WS_EX_TOOLWINDOW set,
  WS_EX_LAYERED clear, has-owner true. Matches exactly HWND=0x30152 in
  this run, exactly the bottom toolbar.

  **Refined fix sketch - see Step 5 below for the patch design.**

## 2026-06-08 PM session - investigation pivot

After hours implementing and testing patch 0005 (toolbar z-promotion targeting
`Qt683QWindowToolSaveBits` HWND 0x30152), an end-of-session screenshot
comparison revealed that **the widget we'd been investigating wasn't the one
the user reported missing**. This section documents the correction and the
new (also failed) hypothesis.

### What the missing widget actually is

Per a live screenshot from the user, the toolbar that's invisible is the
**Fusion navigation toolbar** - orbit / pan / zoom / fit / look-at /
display-style / grid / viewport-config buttons - at **bottom-center**, NOT
the timeline at bottom-left that we'd been chasing. The timeline (the
`Qt683QWindowToolSaveBits` HWND 0x30152 at left-bottom (7,1286)) is in fact
visible.

A re-probe in the post-splash live state identified the navigation toolbar:

```
HWND=0x2015c       (varies per launch; was 0x1015e in an earlier probe)
class:             Qt683QWindowIcon
style:             WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS
exstyle:           0
rect:              (1161,1285)-(1400,1309)  - 239x24, center-bottom
parent (Win32):    HWND=0x50134

HWND=0x50134       (varies per launch)
class:             Qt683QWindowIcon
style:             WS_CHILD | WS_VISIBLE
rect:              (3,120)-(2557,1315)  - 2554x1195, viewport-area-sized
```

### Why our entire patch-0005 model was wrong

Cross-referencing both HWNDs against a `WINEDEBUG=+waylanddrv` + `WAYLAND_DEBUG=1`
trace from the same live session:

- Both HWNDs hit `wayland_win_data_create` (struct allocated).
- Both fire `WAYLAND_WindowPosChanging` / `WindowPosChanged`.
- **Neither hits `wayland_win_data_create_wayland_surface`** - neither has
  a `wayland_surface` at all.

Both are pure Qt6 container widgets that render through a parent's surface.
There are no sibling subsurfaces in main's substack to place_above. The
entire premise of patch 0005 - that some sibling subsurface in main's
substack was burying the toolbar - does not apply to this widget.

### What we now believe is happening

During the splash phase, the navigation toolbar is drawn inside the big
2554x1362 swapchain (visible in `/tmp/dxvk-dump/173.ppm` from this session
- ribbon at top, splash logo center, navigation toolbar at center-bottom).
After splash dismisses, the swapchain showing the modeling viewport takes
over (rendered as white because no document is loaded), and the toolbar's
pixels stop being included in the rendered output.

This is a **Qt6 paint-target / DXVK render-target selection** problem, not
a wayland subsurface z-order problem. The wayland layer is doing what it's
told. The pixels for the toolbar were rendered into the big swapchain
once (during splash) but are not being re-rendered into whatever surface
the post-splash viewport uses.

### What was definitively proven during this attempt

- **Patch 0005 z-order calls succeeded at the wire layer.** A WAYLAND_DEBUG=1
  capture shows 19 `wl_subsurface.place_above` + 19 `wl_surface#83.commit()`
  calls. KWin acknowledged them (no protocol errors, pointer events routed
  to the patched-up surface per "newest topmost with input region" rule).
- **Patch 0005 did not change the visual outcome.** Toolbar still buried
  after the patch. After revert, same burial pattern. Patch 0005 had no
  observable effect - neither positive nor regressive.
- **Patch 0005's diagnostic infrastructure (probe-windows.c +
  diagnose-toolbar-role.sh) is keeper-quality** and is what enabled the
  pivot to identifying the correct widget.

### Patches state after revert

`wine-patches/0001-…`, `0002-…`, `0003-…`, `0004-…` - unchanged from the start
of this session. Still upstream-track. Reverted patch 0005 means cache source
was forcibly re-extracted from tarball via `BUILD_WINE_FORCE=1 build-wine.sh`;
the resulting wine binary at `~/wine-versions/wine-11.10-fusion/bin/wine`
has only the 4 shipping patches applied.

### Failed-attempts list (additions from this session)

Add to the canonical list in `docs/observed-issues.md`:

- **Patch 0005 - toolbar z-promotion via place_above tracking** (rev. 1: 
  single-pointer toolbar tracking; rev. 2: parent-data->client_surface
  retroactive promote; rev. 3: full attached_client_subsurfaces list walked
  oldest-to-newest). All revisions correctly emitted `place_above` +
  parent commit at the wire layer. KWin acknowledged. Visual outcome:
  no change. Cause: targeted the wrong widget - the timeline (which was
  rendering fine), not the navigation toolbar (which has no wayland_surface
  at all so place_above can't affect it).

- **Cross-monitor resize freeze** reported during patch 0005 rev. 1 testing
  did NOT recur after revert - likely transient, unrelated to patch.

### Next steps for a future session

1. **Identify which DXVK swapchain is supposed to contain the navigation
   toolbar's pixels in the post-splash state.** The big 2554x1362 swapchain
   does during splash but not after. The post-splash viewport swapchain
   may not include the toolbar area at all (it might leave the navigation
   toolbar's region untouched, expecting a different render-target to
   provide it).

2. **Investigate Qt6's paint-target selection in the wine+winewayland.drv
   chain.** Specifically: when a WS_CHILD widget (like the nav toolbar's
   parent chain) is rendered, which target does Qt pick (the parent's
   DXVK swapchain? a separate buffer? the toplevel's GDI surface?).

3. **Check whether the navigation toolbar even paints in the post-splash
   state in Qt6's logic.** If Qt6 thinks the surface for that widget was
   destroyed during the splash transition, it might not be repainting at
   all. WindowPosChanging/Changed events imply Win32-side activity but
   not necessarily paint cycles.

4. **Consider this is upstream-Fusion territory.** observed-issues.md
   already says "no project in the public ecosystem (cryinkfly, GE-Proton,
   Lutris, Vinegar) successfully runs Fusion 360 on winewayland.drv." Our
   evidence is consistent with that. The bug may be Fusion's own paint
   logic interacting badly with winewayland.drv's render-target lifecycle
   in a way that's fundamentally different from x11.

5. **Diagnostic artifacts kept from this session:**
   - `debug/wine-tests/probe-windows.c` - Win32 window probe (UTF-8 fixed)
   - `debug/diagnose-toolbar-role.sh` - WAYLAND_DEBUG capture orchestration
   - `debug/captures/probe-windows.txt`, `wayland-trace.log`,
     `wayland-wlproto.log` - the trace data this session was based on
     (may be overwritten by future runs)

### Doc-hygiene fixes still TODO

- The body of this document (sections "## The bug, restated" through "##
  Open questions / parking lot") all reference the wrong widget. Either
  rewrite from scratch or leave as-is with this trailing section as the
  correction-of-record. Decided to leave for now; future-Barrett can
  decide.

- `docs/observed-issues.md` line "Bottom toolbar / ribbon tooltips disappear
  after maximize" was actually about the Object Browser and Comments
  menus, not the bottom toolbar. Per user note this session. Fix attribution
  on that line.

## 2026-06-08 follow-up - architectural root cause

Picking up the prior session's open thread ("identify which DXVK
swapchain owns the nav toolbar's area post-splash"). Captured 52 PPMs
via `VK_LAYER_LUNARG_screenshot` (`VK_SCREENSHOT_FRAMES=100-1500`,
counter saturated at frame 155 within the range - many fewer captured
than the requested 1400 because the global frame counter only ticks on
`vkQueuePresentKHR` and Fusion was relatively idle). Cross-referenced
with a fresh `WINEDEBUG=+waylanddrv` trace from the same wineserver
session.

### What's actually in main's substack

Filtered all `wayland_surface_reconfigure_client hwnd=0x2900e8
subsurface=X,Y+WxH` traces. The `hwnd=` is misleading: it prints
`surface->hwnd` (the toplevel), but the `subsurface=X,Y+WxH` reflects
the *client*'s own rect translated into toplevel coords. So each unique
position+size combo identifies a different `wayland_client_surface`
attached to main:

| subsurface= | likely owner | from probe rect |
|---|---|---|
| `0,0+300x25` | HWND 0x30152 (timeline `Qt683QWindowToolSaveBits`) | (7,1286)-(307,1311) |
| `(3,3)+2554x1362` | HWND 0x700e4 or 0x800be (deep parent-chain QWindowIcon) | (3,3)-(2557,1365) |
| `(3,120)+2554x1245` | HWND 0x900ee or 0xa00b8 | (3,120)-(2557,1365) |
| **`(3,120)+2554x1195`** | **HWND 0x40138 (the white modeling viewport widget)** | (3,120)-(2557,1315) |
| `(4,30)+2554x1362` | main's own client surface | (3,3)-(2557,1365)-ish, offset by border |
| `(4,30)+2560x1414` | main's own client at a different scale state | full window |

So the parent-chain widgets (0x700e4, 0x900ee, 0xa00b8, 0x40138 - the
exact HWND in any session varies, but the rect pattern is stable)
each have their **own DXVK swapchain** allocated via wine's
`wayland_vulkan_surface_create` -> `wayland_client_surface_create` ->
`set_client_surface`. Each presents into its own `wl_subsurface`
attached to main as a sibling of the others.

The `2554x1195` swapchain reads as solid white (255,255,255) at frame
101 - that's exactly what the user sees in the modeling viewport area.

### Why the nav toolbar is buried (the actual mechanism)

The nav toolbar (HWND 0x1015e in the current run) is a `Qt683QWindowIcon
WS_CHILD` that does NOT have a DXVK swapchain (no
`wayland_vulkan_surface_create` for it, no
`wayland_client_surface_attach`, no entry in the reconfigure_client
trace). Qt paints its pixels into main's GDI window_surface - same
"Path A" the architectural-model paragraph above documents for LAYERED
widgets.

Main's GDI surface is the buffer attached to main's wl_surface. Per the
Wayland subsurface protocol, **every subsurface is rendered above its
parent's buffer.** Main's buffer is always at the BOTTOM of the
composite tree. The viewport widget's white client_subsurface (and the
other client_subsurfaces of main) all render above main's buffer
unconditionally.

So the nav toolbar's pixels exist in main's buffer, but they're
inherently underneath the viewport's white pixels. No place_above /
place_below shuffling among the client_subsurfaces of main can elevate
main's own buffer above its children - the protocol forbids it.

This is consistent with everything we observed earlier:
- 19 `wl_subsurface.place_above` calls from patch 0005 went through
  KWin cleanly and re-ordered the client_subsurfaces among themselves -
  but the toolbar pixels in main's buffer were never going to be visible
  no matter what order the client_subsurfaces ended up in.
- The toolbar appears briefly during resize flicker because the
  reconfigure storm momentarily leaves a client_subsurface's buffer
  detached or 0x0-sized, exposing main's underlying pixels for a frame.
- The toolbar appears at Fusion exit because the viewport widget's
  client_subsurface tears down before main's, again exposing main's
  buffer for a frame.

### What this rules out as a wine-only fix

- **wl_subsurface z-order changes among client_subsurfaces of main** -
  any number of `place_above` / `place_below` calls between siblings
  can't make main's parent buffer visible above its children. Patch
  0005 was structurally impossible to make work.

- **`wp_alpha_modifier` / `wp_viewport`-based "soft-hide" of the
  viewport widget's client_subsurface** - would also hide the actual
  viewport content, defeating the purpose.

- **Forcing the nav toolbar to get its own wayland_surface (subsurface
  of main)** - this DOES land it as a sibling of the client_subsurfaces
  with z-order we control. But the nav toolbar has no buffer of its own
  (Qt paints into main's GDI, not into the nav toolbar's window_surface
  - the latter is NULL, which is why `wayland_win_data_create_wayland_surface`
  never fires). We'd need to also synthesize a buffer for it by extracting
  the nav-toolbar-shaped sub-rect from main's GDI buffer. That's
  feasible mechanically - Qt is painting those pixels somewhere - but
  it's a substantial wine architectural change (per-WS_CHILD-widget
  partial GDI-buffer extraction + presentation through a separate
  wl_surface).

### What this implies for the fix

The real fix paths are:

1. **Upstream Qt6** - make QRhi-backed widgets' siblings (non-RHI Qt
   widgets that paint via the normal QPainter chain) get their own
   platform window when running on a wayland platform plugin that
   exposes per-widget surfaces. This is the X11 model carried forward.
   Long lead time, big surface area.

2. **Invasive winewayland.drv change** - detect "small non-DXVK
   WS_CHILD overlapping a sibling DXVK WS_CHILD" at WindowPosChanged
   time, allocate a wayland_surface for the small widget anyway (even
   though `surface == NULL` - Qt didn't allocate a GDI), extract its
   subregion from main's GDI buffer on every paint cycle, attach as
   that subsurface's buffer, place above all DXVK client_subsurfaces.
   Mechanically possible, but it's a fundamental departure from wine's
   existing "wayland_surface follows GDI window_surface" invariant.
   Risk of breaking many other widgets.

3. **Stay on XWayland for day-to-day** - the documented escape hatch in
   `docs/observed-issues.md`. Each Qt6 widget gets its own X11 window with
   its own swapchain; the X11 server composites them naturally. This
   is the path every public Fusion-on-Linux project takes.

Path 1 is the principled answer; Path 3 is the practical answer; Path 2
is upstream-track but probably too invasive to land without a
multi-MR redesign of wine's window_surface ↔ wayland_surface coupling.

### Data preserved

- `debug/captures/probe-windows.txt` - parent chain trace from current
  session (HWND values for this run; structure stable across runs).
- `debug/captures/wayland-trace.log` - `wayland_surface_reconfigure_client`
  trace showing the multiple client_subsurfaces of main.
- `/tmp/dxvk-dump/*.ppm` - 52 PPMs at the three main-child swapchain
  sizes including the all-white `2554x1195` viewport-widget surface.
  Will be lost on next reboot or `rm -rf /tmp`.
- `debug/inspect-ppm-region.py` - Python utility to extract pixel
  stats from a region of a PPM. Reusable for future swapchain
  introspection.

### Failed-attempts list (additions from this follow-up)

- **Z-order ordering of main's client_subsurfaces** (any direction) - by
  Wayland protocol, parent's buffer is always below its subsurfaces.
  Main's buffer holds the nav toolbar pixels. No client_subsurface
  ordering exposes them.

- **`grim`-style screen capture as "buffer dump"** - captures KWin's
  composited output, which is what you already see. Doesn't reveal the
  per-surface buffer contents pre-composite. Only `VK_LAYER_LUNARG_screenshot`
  (or renderdoc) sees the per-swapchain pixels.
