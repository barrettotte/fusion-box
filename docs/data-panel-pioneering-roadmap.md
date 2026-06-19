# Data Panel pioneering roadmap

Multi-phase plan for solving the Fusion 360 Data Panel render bug under
wine's native `winewayland.drv` — a problem with **no documented existing
solution** in any community (wine, GE-Proton, Lutris, Heroic, cryinkfly,
NullString1, KDE, Qt, Chromium), verified 2026-06-18 via 23-source
adversarial deep research.

The architectural root cause is fundamental: **Wayland protocol forbids
cross-process subsurface embedding by design** (per wl_subsurface
co-author Pekka Paalanen, 2013). Qt6WebEngine's renderer subprocesses
each become their own wine process under wine, each with its own
`winewayland.drv` instance and its own wayland connection. Subsurface
parent-references cannot cross connections. No fix exists anywhere — we
are pioneering.

This document plots the path. Each phase has clear entry/exit criteria
and a decision point on whether to continue. Bias is toward cheap
experiments before expensive ones — the goal is to learn maximum from
minimum effort at each stage.

See also:
- `docs/observed-issues.md` Data Panel section — full symptom history
- `docs/qt6webengine-binary-patch.md` — the dead-end DLL-binary-patch
  investigation that informed this roadmap
- `docs/data-panel-cross-process-toplevel-design.md` — Phase 0 design
  spec (already drafted)
- Memory: `project_data_panel_investigation` — running investigation log
- Memory: `project_qt_msvc_abi_blocker` — Phase A's prereq infrastructure

## Phase 0 — Cross-process xdg_toplevel proof-of-concept

**Goal:** answer the single most important question — can wine render a
cross-process HWND to its own `xdg_toplevel` AT ALL? If no, every
phase beyond this dies; if yes, we have a working (ugly) fallback AND
green light for the harder phases.

**Scope:** the wine patch designed in
`docs/data-panel-cross-process-toplevel-design.md`. Add a third branch
to patch 0006's `if (!surface)` block in
`dlls/winewayland.drv/window.c` `WAYLAND_WindowPosChanged`: when the
cross-process toplevel lookup fails AND the HWND is visible + sized
sensibly + WS_CHILD, create a wayland_surface with TOPLEVEL role
instead of destroying.

**Effort:** half-day. ~30 lines of C, one rebuild cycle (~2.5 min warm
ccache), test in Fusion, iterate gating if needed.

**Success criteria:**
- Data Panel appears as a floating window when toggled on
- Window contains rendered content (cloud projects browser UI)
- Clicks in the panel route correctly (input not dropped)
- Closing panel destroys the window cleanly
- Closing Fusion main closes the panel too
- No other Fusion features regress (notification center, sign-in WebView2)

**Failure modes and what they mean:**

| Symptom | Implication |
|---|---|
| Window appears, all black | Subprocess can't paint into its own surface — deeper rendering pipeline issue. Phase A/B unlikely to help; investigate why GDI surface isn't propagating to wayland buffer. |
| Window appears empty/transparent | Compositor sees the surface but no buffer attached. May need extra `commit` plumbing in patch 0006. Fixable. |
| Window doesn't appear at all | Either gating logic too strict (no HWND matched) OR `wayland_surface_make_toplevel` failed in subprocess. Check trace. |
| Window appears + renders + KWin places it wildly | Functional success. UX polish needed (app_id, KWin window rules). |
| Fusion crashes on panel open | New subprocess interaction broke an invariant. Revert immediately, capture trace. |
| Other Qt WebEngine features (notif center, etc.) also pop out as windows | Gating too permissive. Tighten by Qt class name or HWND size threshold. |

**Decision criteria for continuing to Phase A:**
- If Phase 0 PASSES → ship as patch 0011, then evaluate whether the UX is
  acceptable. If you accept the floating-window UX, Phase A becomes
  optional polish.
- If Phase 0 FAILS with "window appears, all black" → Phase A/B aren't
  guaranteed to fix the underlying issue. Investigate the rendering
  pipeline before committing weeks to MSVC infrastructure.
- If Phase 0 FAILS in any other way → fix and retry Phase 0; the
  cheap path is still worth the iteration before escalating.

## Phase A — MSVC cross-build + patch Qt WebEngine

**Goal:** produce an inline-rendered Data Panel. Replace Fusion's bundled
`Qt6WebEngineCore.dll` with our own build that runs all Chromium logic
in-process so HWNDs stay in the same wine process and patch 0006's
existing vsub logic works for the Data Panel out of the box.

**Prerequisites:** Phase 0 must have proven that cross-process rendering
isn't itself broken (otherwise this won't help either).

**Sub-phases:**

### A.1 msvc-wine infrastructure (~1-2 days)
- Install msvc-wine in container (or set up locally), validate `cl.exe`
  runs via wine, compiles a hello-world `.dll`.
- Update Containerfile + add helper script `scripts/build-msvc-tools.sh`.
- Document the MSVC redistributable license terms (msvc-wine downloads
  MS-licensed components).

### A.2 qtbase 6.8.3 MSVC cross-build (~1 day)
- Parameterize `scripts/build-qt.sh` with `BUILD_TOOLCHAIN={mingw,msvc}`.
- Cross-build qtbase 6.8.3 with MSVC.
- Drop-in test: replace Fusion's `Qt6Core/Gui/Widgets` with our MSVC
  build, verify `??0QString@@QEAA@PEBD@Z` resolves (was the original
  blocker per `qt-msvc-abi-blocker` memory).

### A.3 Chromium 122 source + build (multi-day, mostly compile-time)
- Install depot_tools, gn, ninja in container.
- Identify exact Chromium revision qtwebengine 6.8.3 pins (check
  qtwebengine submodules at v6.8.3 tag).
- Fetch (~30 GB source).
- Build (hours of compile, GBs of object files, careful disk-space
  management).

### A.4 qtwebengine 6.8.3 cross-build on top of Chromium (~1 day)
- Cross-build qtwebengine with our patched Chromium underneath.
- Drop-in test (no patch yet) — replace Fusion's
  `Qt6WebEngineCore.dll`, verify Fusion launches, sign-in works.

### A.5 Patch Chromium to robustly support --single-process (~variable)
- Critical: Chromium upstream considers `--single-process` "experimental"
  and known-broken in production. Just rebuilding won't fix this.
- Identify the spawn-decision in
  `content/browser/renderer_host/render_process_host_impl.cc` and force
  the in-process path unconditionally.
- Identify the GPU-process spawn-decision similarly and force in-process.
- Identify the utility-process spawn-decisions (network, audio).
- This is essentially porting LaCrOS's delegated-compositing assumptions
  back into a Windows-mode Chromium build.

### A.6 Patch Qt WebEngine adapter (~1-2 days)
- Qt6WebEngine has its own QtWebEngineProcess.exe spawn logic that's
  separate from Chromium's renderer spawning. Patch
  `src/process/main.cpp` and `src/core/process_main.cpp` to recognize
  in-process mode and skip the spawn.

### A.7 Integration test + ship (~1 week)
- Apply patches, build final DLL.
- Replace Fusion's DLL, validate Data Panel renders inline.
- Validate no regressions across Fusion features.
- Write `scripts/patch-qt6webengine.sh` to apply our build (already
  scaffolded; fill in PATCH_OFFSET/BYTES with our DLL hash).

**Total Phase A effort:** 2-3 weeks of focused work, depending on
Chromium build hurdles.

**Risks:**
- Chromium 122 source may not build cleanly with msvc-wine; subtle
  toolchain incompatibilities possible.
- `--single-process` may have so many embedded assumptions that
  patching it robustly is harder than expected.
- Fusion may update Qt6WebEngineCore.dll mid-effort, invalidating our
  patches.

**Decision criteria for continuing to Phase B:**
- If Phase A succeeds → ship it. Phase B unnecessary unless we want the
  upstream contribution value.
- If Phase A blocks on Chromium build infrastructure → Phase B's wine
  broker may be a tractable alternative that avoids the Chromium rebuild.
- If Phase A succeeds for Fusion but is fragile across updates → Phase B
  is the durable answer.

## Phase B — Wine wineserver-mediated wayland broker

**Goal:** generic architectural fix for ANY Qt WebEngine (or other
multi-process Win32 Chromium) application under wine, not just Fusion.
Largest upstream contribution value.

**Concept:** wineserver maintains ONE wayland connection per wineserver
session. Wine processes that would normally open their own connection
to the compositor instead make wayland requests via wineserver IPC. The
single connection's wl_surface objects can be referenced from any wine
process, enabling cross-process subsurfaces transparently.

**Effort estimate:** weeks-to-months. Touches wineserver internals,
`winewayland.drv` core architecture, the wayland protocol marshaling
layer. Significantly more code than Phase A.

**Architectural sketch:**
- New wineserver request: `wayland_marshal(opcode, args)`. Wine processes
  forward all wayland protocol traffic through this.
- wineserver multiplexes incoming traffic from all wine processes onto
  the single shared wayland connection.
- Replies and events from the compositor are routed back to the
  originating wine process.
- IDs (wl_object IDs) must be made globally unique across wine processes;
  this likely needs an ID translation layer.
- `winewayland.drv`'s `win_data_rb` becomes a shared structure in
  wineserver (or a coherent view across processes via IPC).

**Risks:**
- Wine maintainer buy-in uncertain. The change is invasive enough that
  it might not be accepted without significant upstream discussion.
- Performance regression risk — wayland traffic going through an extra
  IPC hop. Especially bad for high-frequency events (pointer motion,
  frame callbacks).
- Mojo-style proxying may conflict with existing wine design assumptions.

**Decision criteria:** only pursue if Phase A succeeds for Fusion but
fails generically (i.e., other Qt WebEngine apps still break), or if
phase A's MSVC infrastructure proves too brittle.

## Phase C — Chromium "detect wine, use Linux IPC" patch

**Goal:** make upstream Chromium recognize it's running under wine and
use its native Linux compositor architecture (LaCrOS-style delegated
compositing) instead of Windows HWND parenting.

**Why it works:** Chromium ALREADY has a single-connection-to-compositor
architecture for native Linux (LaCrOS). The browser process owns the
sole wayland connection; renderer processes never touch wayland. If we
can convince Chromium running under wine to use that path instead of
the Windows HWND path, the cross-process problem evaporates.

**Effort estimate:** months. Requires deep Chromium expertise. Would be
a massive upstream PR.

**Why not start here:** highest-effort, highest-uncertainty path. Only
worth pursuing if Phases A and B both prove infeasible and we want to
solve this at the upstream Chromium layer (huge contribution).

## Upstream contribution opportunities

Each phase produces something potentially worth upstreaming:

| Phase | Upstream candidate | Likelihood of acceptance |
|---|---|---|
| 0 | Wine MR for cross-process toplevel fallback | Medium — narrow scope but useful for any wine wayland Chromium-app scenario |
| A.5 | Chromium MR forcing in-process renderer | Low — Chromium upstream considers --single-process broken-by-design |
| A.6 | Qt MR documenting/fixing --single-process under wine | Medium — Qt may accept if framed as a wine compat patch |
| B | Wine MR for wayland broker | High value, uncertain acceptance — would need wine-devel discussion first |
| C | Chromium MR for wine detection | Highest impact, hardest sell |

## Decision flow

```
START
  ↓
Phase 0 (half-day)
  ├─ FAILS (deep render bug) → investigate rendering pipeline before escalating
  └─ SUCCEEDS
       ↓
   Is floating-window UX acceptable?
       ├─ YES → ship Phase 0 as patch 0011, done (for now)
       └─ NO ─ ↓
              Phase A.1-A.4 (week+) — MSVC + Chromium + qtwebengine build
                ├─ FAILS (build infra) → consider Phase B instead
                └─ SUCCEEDS
                     ↓
                 Phase A.5-A.7 (week+) — patch + integrate
                     ├─ FAILS (--single-process unfixable) → Phase B or C
                     └─ SUCCEEDS → ship inline Data Panel, done
```

## Open questions to settle before committing

1. **Is the Phase 0 outcome predictive of Phase A?** If a cross-process
   HWND can't render to its own toplevel, can a same-process HWND render
   in-process? May want to test by inserting a deliberate cross-process
   call in a controlled Qt WebEngine test app.
2. **What is the actual Chromium revision pinned by qtwebengine 6.8.3?**
   Needed before Phase A.3.
3. **Is Fusion 360 the right reference for this work?** Other Qt
   WebEngine apps under wine (Spotify, Discord clones, etc.) may be
   easier to iterate against and provide upstream credibility.
4. **What's the test plan for upstream contribution?** Each MR will need
   a minimal-reproducer app and a clean issue write-up.

## Status as of 2026-06-18

- Phase 0 design: documented in
  `docs/data-panel-cross-process-toplevel-design.md`.
- Phase 0 implementation: not started.
- All later phases: planned only.
- Day-to-day Fusion use: works under winewayland.drv except for the
  Data Panel. XWayland (`FUSION_FORCE_X11=1`) is NOT a viable
  workaround on KDE Plasma 6 wayland sessions (viewport + panel both
  render black).
