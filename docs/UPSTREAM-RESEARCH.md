# Phase 0 - Upstream research findings

Research conducted 2026-06-06 across wine upstream, downstream wine forks, and the compositor/WSI layer to:

1. Confirm we are not duplicating an in-flight fix.
2. Identify whether the **soft-hide / decouple-lifecycle-from-visibility** direction we proposed is consistent with upstream design intent.
3. Refine the patch shape based on Wayland protocol spec and prior art.

## TL;DR

- **The bug is real, widespread, and not yet fixed upstream.** wine bug 45277 lists Fusion 360 explicitly and is still UNCONFIRMED. DXVK #4329 corroborates the wine 9.18+ KWin Wayland black-screen pattern.
- **MR !8468 (merged July 2025, present in wine 11.10)** added a `client->toplevel != toplevel` dedup check that only prevents redundant same-toplevel reattaches. It does NOT prevent the `wayland_client_surface_attach(client, NULL)` destruction path that visibility flaps trigger. Our diagnosis is consistent with upstream state.
- **Our fix direction is novel.** No existing MR pursues decoupling subsurface lifecycle from `NtUserIsWindowVisible`. The maintainers (Alexandros Frantzis, Rémi Bernon) have not publicly discussed this angle.
- **Refined fix shape**: the Wayland-canonical "transient hide" is **NULL-buffer-attach + commit on the wl_surface** (per wayland-book + spec), NOT `wp_viewport_set_destination(0,0)` as we'd originally sketched. Smaller, more conservative, protocol-conformant.
- **Inspect wine-tkg's childwindow-proton.patch before patching** - it modifies `winewayland.drv/vulkan.c` (we previously believed it was winex11-only). Understand what they did before we duplicate or contradict.

## Wine upstream

### Bug 45277 - "Multiple applications need Vulkan child window rendering"

Status: **UNCONFIRMED / OPEN** (opened 2019). Lists Fusion 360 as an affected application alongside DxO PhotoLab, Affinity Photo, Google Earth Pro. Originally framed around `winex11.drv` (X11DRV_vkCreateWin32SurfaceKHR's "child window rendering not implemented" abort). MR !6323 (merged Aug 2024) provides the **winewayland** child-window GL/VK infrastructure - which is why our bug exists at all: without !6323, the viewport would simply abort instead of present-to-detached.

This bug is the umbrella to reference in our patch's commit message and MR description.

URL: https://bugs.winehq.org/show_bug.cgi?id=45277

### Relevant merged MRs (wine 11.10 baseline)

| MR | Title | Author | Merged | Effect on our bug |
|---|---|---|---|---|
| [!6323](https://gitlab.winehq.org/wine/wine/-/merge_requests/6323) | winewayland: Support GL/VK rendering in child windows (alt) | Bernon | Aug 2024 | **Created the infrastructure** that exposes our bug. Before this MR, Vulkan child windows would abort with "not implemented". |
| [!6452](https://gitlab.winehq.org/wine/wine/-/merge_requests/6452) | winewayland: Move client surface to wayland_win_data | Bernon | Sep 2024 | Restructured `wayland_client_surface` storage; current source layout is from this work. |
| [!4641](https://gitlab.winehq.org/wine/wine/-/merge_requests/4641) | winewayland.drv: Apply surface config during Vulkan presentation | Frantzis | Dec 2023 | Subsurface reconfigure during present. Sits adjacent to our bug but doesn't address lifecycle. |
| [!8468](https://gitlab.winehq.org/wine/wine/-/merge_requests/8468) | winewayland: Only detach/attach client surface if different | Bernon | Jul 2025 | **Closest existing optimization.** Added `client->toplevel != toplevel` dedup. Insufficient: visibility flaps trigger explicit `attach(NULL)` calls that aren't redundant by this check. **Confirmed present in our wine 11.10 source at `wayland_surface.c:1228`.** |
| [!9679](https://gitlab.winehq.org/wine/wine/-/merge_requests/9679) | winewayland: Update client surface position in update callback | Bernon | Dec 2025 | Surface position update mechanics. Adjacent. |
| [!9864](https://gitlab.winehq.org/wine/wine/-/merge_requests/9864) | win32u: Clear window surface with black on client surface creation | Gofman | Jan 2026 | **Confirms recent activity in this code path.** Fills client surface area with black on creation - independent of our bug but useful context. |

### Wine-devel mailing list

No threads in the last 18 months on:
- "decouple subsurface lifecycle from visibility"
- "winewayland transient hide / soft-hide"
- "wl_subsurface destroy synchronization"

Suggests our framing is novel and there's no in-flight design discussion to align with. Submit-ready patches with strong empirical evidence are likely well-received.

### Maintainers to engage

- **Alexandros Frantzis** - primary winewayland maintainer. Active in subsurface presentation work (MR !4641).
- **Rémi Bernon** - heavy contributor across winewayland.drv lifecycle and client-surface architecture (MR !6323, !6452, !8468, !9679). Most likely reviewer for our patch.

## Downstream wine forks

### wine-tkg-git - `childwindow-proton.patch` (Phase 0.5 result - does NOT help us)

Fetched and inspected 2026-06-06. Local copy at `/tmp/wine-tkg-research/childwindow-proton.patch` (608 lines).

**Architecture**: wine-tkg's patch is an **offscreen-DC + GDI-blit** mechanism, fundamentally orthogonal to wayland subsurfaces. Mechanism:

1. `win32u/vulkan.c` restructure: Vulkan surfaces are tracked per-window via a `vulkan_surfaces` list on the `WND` struct. New `p_vulkan_surface_attach` + `p_vulkan_surface_detach(HWND, void*, HDC*)` vtable contract.
2. When a child window becomes non-visible, `p_vulkan_surface_detach` is called and the driver populates `*hdc` with an offscreen DC.
3. On `vkQueuePresentKHR`, if the surface has an offscreen DC, `StretchBlt` copies from offscreen onto the child window's real DC.
4. **X11 implementation** uses XComposite to create the offscreen pixmap (`xcomposite.h` included; not in 11.10 stock).
5. **Wayland implementation is a complete no-op stub** - both `p_vulkan_surface_attach` and `p_vulkan_surface_detach` are empty functions whose only purpose is to satisfy the new vtable contract.

```c
+static void wayland_vulkan_surface_attach(HWND hwnd, void *private)
+{
+}
+
+static void wayland_vulkan_surface_detach(HWND hwnd, void *private, HDC *hdc)
+{
+}
```

**Conclusion**: this patch does NOT address the winewayland subsurface destroy/recreate race. It is solving the X11 child-window Vulkan problem via XComposite, with the wayland slots stubbed out. The wine-tkg build system disables the patch when wayland driver is active (consistent with their stubs being non-functional).

**No code from wine-tkg's patch is suitable to borrow for our fix.** Our patch will be entirely novel against the upstream winewayland.drv source. The vtable contract change (adding `p_vulkan_surface_attach`) is incompatible with upstream conventions and we don't need it for the soft-hide approach (which acts on the wayland surface directly inside `wayland_client_surface_attach`, not via a new vtable hook).

URL: https://github.com/Frogging-Family/wine-tkg-git/blob/master/wine-tkg-git/wine-tkg-patches/misc/childwindow/childwindow-proton.patch

### Vinegar - winex11-only (confirmed)

`childwindow.patch` modifies only `winex11.drv/vulkan.c`, `winex11.drv/window.c`, `winemac.drv/vulkan.c`. No winewayland work. Vinegar documents that wine's wayland driver doesn't support cursor constraints, making it unusable for their target app (Roblox).

URL: https://github.com/flathub/io.github.vinegarhq.Vinegar/blob/master/patches/wine/childwindow.patch

### varmd/wine-wayland - issue #28 closed, deferred

Closed unresolved. Project explicitly avoids X11-style XComposite workarounds. Their current stance: wait for upstream native subsurface solutions (which MR !6323 became). Not a source of reusable patches.

URL: https://github.com/varmd/wine-wayland/issues/28

### GE-Proton - no relevant patches

Has winewayland patches but for systray icon positioning (GE-Proton10-30 added, GE-Proton10-31 reverted due to game-breaking regressions). Nothing for child-window rendering.

### cryinkfly/Autodesk-Fusion-360-on-Linux - no wine patches

Archived on GitHub Feb 2026; continued at https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux. Ships only:
- `fix-navbar-flicker.sh` - hides NavToolbar via XML; symptom workaround, not a fix
- `wine-captionless-popups.patch` - winex11.drv only

User reports of the same viewport-black bug exist in their issue tracker (e.g., #311) without resolution.

### Lolig4/fusion-wine-build - NOT FINDABLE

GitHub search returned nothing. Project may be private, renamed, or hosted on a non-GitHub platform. We previously believed this was a known working wine build for Fusion 360. **Treat as unconfirmed.** Don't block our work on locating it.

### h0tc0d3/wine-wayland, Kron4ek/wine-wayland - maintenance forks

Patch collections for display mode / window scaling / configuration. No child-window or subsurface lifecycle work. Both acknowledge child window rendering as an open TODO.

### Bottles / Lutris / Heroic - none

Launcher integrations. No native wine patches of their own.

## Compositor side

### KWin

No public issues specifically describing the wl_subsurface destroy/recreate race. Related items:

- KWin MR !7804 - subsurfaces VRR scheduling fix (indicates KWin has subsurface-related timing complexity).
- KBug #477738 - NVIDIA KWin Wayland black-screen on resume (not our bug, but documents NVIDIA + KWin + Wayland sensitivity).

URL (KWin issues): https://invent.kde.org/plasma/kwin/-/issues

### Mutter (GNOME compositor)

Mutter has documented subsurface-related compositor bugs:

- Issue #1718 - Overview gets broken by subsurface changes (subsurface deletion confuses compositor's visual state).
- Issue #3335 - Compositor crash during nested subsurface animation.
- MR !3864 - Subsurface MetaSurfaceActor showing/hiding management (recent fix).

**Significant pattern**: community reports of the same Fusion 360 / DXVK + wine viewport-black symptom are predominantly on KWin, not Mutter. Suggests Mutter handles rapid destroy/recreate more gracefully. The bug is still in wine - but KWin's stricter handling exposes it more reliably than Mutter's.

## Vulkan WSI on Wayland

### NVIDIA Open driver

- Driver 595.71.05 (our version): no specific subsurface fixes documented in changelog.
- Driver 580.94.18 (Feb 2026): "Fixed inconsistent vkQueuePresentKHR times with VK_EXT_present_timing for Wayland."
- Forum reports: Vulkan Wayland WSI has presentation timing issues across NVIDIA Open versions.

When wine destroys the wl_subsurface, the underlying `wl_surface` (`client->wl_surface`) is NOT destroyed - only its parent link. NVIDIA WSI may not handle re-parenting cleanly. Documented gap.

### Mesa Vulkan WSI

Issue #10254 - `vkAcquireNextImageKHR`/`vkQueuePresentKHR` don't report `VK_SUBOPTIMAL_KHR` after Wayland surface state changes. DXVK can't detect that its swap chain has been invalidated by wine's subsurface manipulation. URL: https://gitlab.freedesktop.org/mesa/mesa/-/issues/10254

`VK_EXT_swapchain_maintenance1` minImageCount returned as 2 for FIFO only.

### DXVK

- DXVK #4329 - black screen with wine 9.18+ on KWin Wayland; 9.17 and below unaffected. This regression window aligns with **MR !6323 merging Aug 2024**, which was the wine release introducing winewayland child-window vulkan support. The infrastructure that exposed our bug.
- DXVK #806 - framerate capped on KWin Wayland even with vsync off (NVIDIA WSI quirk).

## Wayland protocol spec - refined fix shape

This is the highest-value finding for our actual patch design.

### `wl_subsurface` lifecycle (per wayland.freedesktop.org spec + wayland-book)

- Destroying a wl_subsurface unmaps the surface from the compositor tree and forgets position/z-order. **Legal** to create a new subsurface for the same `wl_surface` afterward.
- **For synchronized unmap**, the spec recommends:
  1. `wl_surface.attach(NULL)` on the wl_surface (or the wl_subsurface's wl_surface)
  2. `wl_surface.commit`
  3. THEN `wl_subsurface_destroy()` (if doing structural teardown)
- Without (1) and (2), the compositor may briefly retain a stale buffer attached to a now-orphaned surface. **Wine currently skips this synchronization** - the `wl_subsurface_destroy` at `wayland_client_surface_attach`'s NULL path fires with no preceding NULL-buffer commit.

### `wp_viewport` (viewporter spec, wayland.app/protocols/viewporter)

- `set_destination(width, height)` defines output size. Negative values unset destination.
- **There is NO "hide" function in wp_viewport.** `set_destination(0, 0)` is not specified as a hide; the spec doesn't bless it. Our earlier sketched "set_destination(0,0)" approach is non-canonical.

### **Refined fix direction**

Our original "soft-hide via wp_viewport_set_destination(0,0)" was non-canonical. The protocol-correct soft-hide is:

**For transient invisibility (the per-frame WS_VISIBLE flap):**
- `wl_surface_attach(client->wl_surface, NULL, 0, 0)`
- `wl_surface_commit(client->wl_surface)`
- DO NOT destroy the `wl_subsurface`
- The compositor draws parent surface through the empty hole - visually identical to subsurface-destroyed but without the protocol churn

**For structural teardown (HWND destroy, true toplevel change):**
- `wl_surface_attach(client->wl_surface, NULL, 0, 0)`
- `wl_surface_commit(client->wl_surface)` ← add this synchronization
- `wl_subsurface_destroy(client->wl_subsurface)`

The teardown path actually **also benefits** from adding the missing NULL-buffer-commit synchronization, addressing a separate latent bug we'd otherwise leave behind.

## Implication for patch 0003

Original sketch (in `wayland-subsurface-bug.md`):

> Soft-hide via `wp_viewport_set_destination(0, 0)`

**Revised**:

> Soft-hide via `wl_surface_attach(NULL) + wl_surface_commit` on the client's `wl_surface`. Reserves `wl_subsurface_destroy` for structural teardown only, where it gets the same NULL-buffer-attach + commit pre-step for protocol-correct synchronized unmap.

This is a smaller patch (one helper function), more conservative (uses an explicitly-spec-blessed mechanism), and incidentally fixes a second latent bug (unsynchronized teardown).

## Patch commit message references

To include in `0003-winewayland-decouple-subsurface-lifecycle-from-visibility.patch`:

- Wine bug 45277 - umbrella child-window vulkan bug, Fusion 360 explicitly listed
- Cc: Alexandros Frantzis, Rémi Bernon
- References MR !8468 as the dedup it builds on top of
- References MR !6323 as the infrastructure exposing the bug
- DXVK #4329 community corroboration

## Next-step ordering revision

Before Phase 1 instrumentation, **insert a Phase 0.5**: fetch wine-tkg's `childwindow-proton.patch` and inspect their `p_vulkan_surface_attach` mechanism for winewayland. Time-bounded to 15-20 minutes; if they're solving a different problem we proceed unchanged, if they're addressing our problem we align.

## Sources

### Wine upstream
- [Bug 45277](https://bugs.winehq.org/show_bug.cgi?id=45277)
- [MR !4641](https://gitlab.winehq.org/wine/wine/-/merge_requests/4641)
- [MR !6323](https://gitlab.winehq.org/wine/wine/-/merge_requests/6323)
- [MR !6452](https://gitlab.winehq.org/wine/wine/-/merge_requests/6452)
- [MR !8468](https://gitlab.winehq.org/wine/wine/-/merge_requests/8468)
- [MR !9679](https://gitlab.winehq.org/wine/wine/-/merge_requests/9679)
- [MR !9864](https://gitlab.winehq.org/wine/wine/-/merge_requests/9864)

### Downstream forks
- [wine-tkg childwindow-proton.patch](https://github.com/Frogging-Family/wine-tkg-git/blob/master/wine-tkg-git/wine-tkg-patches/misc/childwindow/childwindow-proton.patch)
- [Vinegar childwindow.patch](https://github.com/flathub/io.github.vinegarhq.Vinegar/blob/master/patches/wine/childwindow.patch)
- [varmd/wine-wayland #28](https://github.com/varmd/wine-wayland/issues/28)
- [cryinkfly (archived)](https://github.com/cryinkfly/Autodesk-Fusion-360-for-Linux), [cryinkfly (Codeberg)](https://codeberg.org/cryinkfly/Autodesk-Fusion-360-on-Linux)
- [h0tc0d3/wine-wayland](https://github.com/h0tc0d3/wine-wayland)

### Compositor
- [KWin invent](https://invent.kde.org/plasma/kwin)
- [Mutter #1718](https://gitlab.gnome.org/GNOME/mutter/-/issues/1718)
- [Mutter #3335](https://gitlab.gnome.org/GNOME/mutter/-/issues/3335)
- [Mutter MR !3864](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/3864)

### Vulkan WSI
- [Mesa #10254](https://gitlab.freedesktop.org/mesa/mesa/-/issues/10254)
- [DXVK #4329](https://github.com/doitsujin/dxvk/issues/4329)
- [DXVK #806](https://github.com/doitsujin/dxvk/issues/806)

### Protocol spec
- [wayland.freedesktop.org spec](https://wayland.freedesktop.org/docs/html/apa.html)
- [wayland-book subsurfaces](https://wayland-book.com/surfaces-in-depth/subsurfaces.html)
- [viewporter protocol](https://wayland.app/protocols/viewporter)
