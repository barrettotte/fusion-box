# Data Panel cross-process toplevel — design spec

Design for **option 3** of the Data Panel render bug (see `observed-issues.md`):
when a Chromium-subprocess HWND can't reach its Qt toplevel's
`wayland_surface` (because the toplevel lives in another wine process and
each process has its own `win_data_rb`), wine promotes the HWND to its own
`xdg_toplevel` instead of destroying it. The Data Panel becomes a floating
window adjacent to Fusion main.

This is the fallback if the Qt6WebEngineCore.dll binary patch (option 4a,
investigated in `docs/qt6webengine-binary-patch.md`) doesn't pan out.

**Status:** design only — not implemented. Filed here for future-self / future-
contributors to pick up.

## Why this works (theory)

Each Chromium subprocess (`QtWebEngineProcess.exe --type=renderer`) is its own
wine process with its own `winewayland.drv` instance, its own `win_data_rb`,
and its own wayland connection. When the subprocess creates HWND `0x1019e` and
that HWND's win32 parent chain walks up to Qt's main toplevel (`0x1b0166`)
which is in Fusion main's process, the subprocess's `wayland_win_data_get_
nolock(toplevel)` returns NULL. Cross-process subsurfaces aren't a thing in
Wayland — the subprocess can't `get_subsurface(parent_surface)` against a
surface that belongs to another connection.

But the subprocess CAN create its own `xdg_toplevel` from its own wayland
connection. KWin will display it as a separate window. The Data Panel will
render its pixels into that surface via the existing GDI / client-surface
path.

The cost is UX: the panel detaches from Fusion main. KWin places it
wherever, the user has to move it manually (or rely on KWin window rules).

## Detection gate (which HWNDs to promote)

Promote iff ALL of:

- `toplevel != hwnd` — the HWND has a win32 parent chain at all
- `toplevel_surface == NULL` AND `toplevel_data == NULL` — the toplevel
  lookup genuinely failed (cross-process). Distinguish from "in-process but
  not yet populated".
- `style & WS_VISIBLE` — the HWND wants to be shown
- `w >= 100 && h >= 100` — not a tiny `Chrome_MessageWindow` (those are
  size 0x0 or 100x30 and shouldn't pop out as windows)
- `!data->client_surface` — no DXVK swapchain attached (Chromium HWNDs
  with their own swapchains don't fit this code path; this guards against
  accidentally creating two competing wayland_surfaces for the same HWND)
- `!vsub_eligible` — patch 0006's existing virtual-subsurface check has
  already declined, so we're in the "would otherwise destroy" path

What this promotes (intended):
- `0x1019e` (`Chrome_WidgetWin_0`, 1273x1440, Data Panel main) — yes

What this DOESN'T promote (sanity):
- `0x201a6` (`Chrome_RenderWidgetHostHWND`, child of 0x1019e, same process)
  — fails because its toplevel IS in-process (toplevel_data lookup succeeds)
- Tiny `Chrome_MessageWindow` instances (size 0x0 or 100x30) — fails size gate
- HWNDs in Fusion main's process — toplevel_data lookup succeeds, falls
  through to patch 0006

## Patch placement

`dlls/winewayland.drv/window.c`, `WAYLAND_WindowPosChanged`, inside the
`if (!surface)` branch (where patch 0006 lives). Add a NEW branch BETWEEN
patch 0006's "vsub_eligible → create" and its "else → destroy". Conceptual
order:

```c
if (vsub_eligible) {
    /* existing patch 0006: virtual subsurface */
} else if (cross_process_toplevel_eligible) {
    /* NEW: promote to standalone xdg_toplevel */
} else if (data->wayland_surface) {
    /* existing destroy */
}
```

## Rough patch sketch

```c
/* fusion-box patch 0011: cross-process toplevel promotion.
 *
 * Qt6WebEngineCore spawns Chromium renderer subprocesses (each its own
 * wine process). HWNDs created in those subprocesses parent-chain up to
 * Qt toplevels in Fusion main, but the subprocess's win_data_rb doesn't
 * see those toplevels (per-process state). Without intervention these
 * HWNDs fall through to patch 0006's destroy branch and never render.
 *
 * Detection (all required):
 *   - has a non-self toplevel ancestor (toplevel != hwnd)
 *   - toplevel_data lookup returned NULL → cross-process
 *   - style & WS_VISIBLE
 *   - w >= 100 && h >= 100 (skip tiny message windows)
 *   - !data->client_surface (no DXVK swapchain conflict)
 *   - !vsub_eligible (patch 0006 declined)
 *
 * If eligible: create a wayland_surface with TOPLEVEL role. KWin renders
 * the HWND's GDI pixels as a separate floating window. Worse UX than
 * inline-docked (the goal), but the only Wayland-side option when the
 * parent surface lives in another process.
 *
 * NOT a fix for the "Fusion main content overflows right by panel-width"
 * symptom: Fusion's Win32 layout still reserves panel-width space inline
 * regardless of where the actual pixels land. That symptom needs a
 * separate workaround (KWin window rule to move the floating panel?).
 */
BOOL cross_process_toplevel_eligible =
    !vsub_eligible &&
    toplevel && toplevel != hwnd &&
    !toplevel_surface &&    /* implies toplevel_data == NULL */
    visible &&
    w >= 100 && h >= 100 &&
    !data->client_surface;

if (vsub_eligible) {
    /* existing patch 0006 */
} else if (cross_process_toplevel_eligible) {
    struct wayland_surface *vs = data->wayland_surface;
    if (!vs)
        vs = wayland_surface_create(hwnd);
    if (vs) {
        data->wayland_surface = vs;
        if (vs->role != WAYLAND_SURFACE_ROLE_TOPLEVEL)
            wayland_surface_make_toplevel(vs, get_mwm_decoration(data));
        TRACE("[fusion-box-cross-proc] CREATED toplevel hwnd=%p toplevel=%p "
              "rect=(%ld,%ld %dx%d)\n", hwnd, toplevel,
              (long)data->rects.window.left, (long)data->rects.window.top, w, h);
    }
} else if (data->wayland_surface) {
    /* existing destroy */
}
```

## Open questions

1. **Does the GDI window_surface actually commit pixels to a TOPLEVEL-role
   wayland_surface owned by a subprocess?** The existing
   `wayland_client_surface_attach` and `set_window_surface_contents` paths
   were written assuming same-process operation. Cross-process behavior is
   untested. The subprocess HAS its own wayland connection, so it should
   be able to attach buffers — but Qt's painting code paths in the
   subprocess need to actually push pixels into Fusion's GDI surface for
   that HWND. Verify by tracing
   `wayland_client_surface_attach` calls from the subprocess after applying
   the patch.

2. **KWin window grouping**. Without an explicit `app_id`, KWin will treat
   the new toplevel as an unrelated window. Setting `app_id` to match
   Fusion's main (Fusion's xdg_toplevel app_id is configured in patch
   0001's SSD code) would group them in the taskbar / Alt+Tab.

3. **Position persistence**. KWin places new toplevels per its default
   policy (often offset from the previous window or centered). A KWin
   `window rule` could pin the panel to a consistent position next to
   Fusion's main. This would be a one-time user setup, not part of the
   patch.

4. **The "content overflows right" symptom**. Fusion main's Win32 layout
   still reserves panel-width space inline regardless of where the panel
   actually renders. This patch doesn't fix that — separate problem,
   possibly fixable via a Fusion config option or a wine-side
   SetWindowPos interceptor that clamps main's rect.

5. **Other cross-process HWNDs unintentionally promoted?** Fusion uses
   Qt6WebEngine elsewhere (notification center, embedded help, possibly
   extensions). Each would also be cross-process and could get its own
   floating window. Need an explicit reproducer that covers ALL Fusion
   features that touch Qt WebEngine before declaring this patch safe.

## Testing plan

1. Apply patch as `patches/wine/0011-winewayland-cross-process-toplevel.patch`
2. `MAX_PATCH_NUM=11 scripts/build-wine.sh`
3. Launch Fusion, observe baseline (main UI loads as usual).
4. Open Data Panel.
   - Expected: a new floating window appears containing the panel content.
   - Likely placement: somewhere centered or offset from main.
5. Click items in the panel — verify input routes correctly.
6. Toggle panel off — verify window closes.
7. Toggle panel back on — verify window reappears (and ideally remembers
   position via KWin rules if user set one).
8. Sign out / sign back in (login uses different engine, WebView2, should
   be unaffected).
9. Open notification center, any other embedded webview — verify those
   either render correctly OR also pop out as separate windows
   (acceptable) but DO NOT crash Fusion.
10. Close Fusion main — verify panel window closes too.

## Comparison vs option 4a (DLL binary patch)

|                          | Option 3 (this) | Option 4a (DLL patch) |
|--------------------------|-----------------|-----------------------|
| Effort                   | Half-day patch  | Days of RE + risky byte edit |
| UX                       | Floating panel  | Inline-docked panel |
| Other Qt WebEngine usage | May also pop out | Inline like the panel |
| Survives Fusion update   | Yes             | No (offsets move per update) |
| Project ethos alignment  | Wayland-mission, wine-side | Binary patching is opposite of upstream |
| Code reviewability       | Easy (~30 lines wine C) | Hard (binary diff) |

Both are valid. Option 3 is the durable fallback; option 4a wins on UX.
Worth keeping option 3 designed even if 4a succeeds, in case Fusion
auto-updates regress the DLL patch and we need an immediate workaround.
