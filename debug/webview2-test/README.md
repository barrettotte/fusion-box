# debug/webview2-test — Minimal WebView2 host for DComp validation

Standalone WebView2 host app to bypass the Fusion Data Panel
chicken-and-egg loop (Data Panel can't render → Chromium GPU never
finalizes d3d11 device → never calls our patched dcomp.dll → can't
validate Phase D end-to-end under real Fusion).

This host spawns a WebView2 instance independently, navigates to a page
with CSS 3D transforms + canvas animation that forces Chromium's GPU
compositor → eventually `DCompositionCreateDevice3` → our dcomp.dll D-0
markers should appear in the trace.

## Build

```bash
bash build.sh
```

Produces `webview2_host.exe` + `webview2_host.exe.so` via winegcc.

## Run

```bash
bash run.sh                 # default: USE_STAGING=1 → wine-staging (renders content)
USE_STAGING=0 bash run.sh   # alt: fusion-box's mainline-wine build (white window)
```

Copies WebView2Loader.dll + test_content.html into the target wineprefix,
launches with full `+module,+process` trace.

After the window shows (animated balls + spinning gradient on dark
background), wait ~20s for Chromium GPU init to complete, then close
the window with X.

**Wineprefix per mode:**
- `USE_STAGING=1` → `~/.wine-staging-test` (one-time setup: wineboot init,
  copy Edge WebView2 runtime + Autodesk Identity Manager, import EdgeUpdate
  registry tree from a working Fusion prefix)
- `USE_STAGING=0` → `~/.wine-fusion` (Fusion's regular prefix)

**Output logs:**
- Trace: `debug/captures/webview2-{test,staging}-<TS>.log`
- App log: `$WINEPREFIX/drive_c/webview2_host.log`

## Validation

Check trace for our D-* markers:

```bash
LOG=$(ls -t ../captures/webview2-test-*.log | head -1)
grep -c 'fusion-box D-' "$LOG"            # should be > 0 if Edge calls our dcomp
grep -aE 'fusion-box D-' "$LOG" | head -20
```

If `fusion-box D-0` markers appear: Phase D dcomp.dll IS callable from
real Chromium under wine. Then the Fusion-specific issue is purely
about Data Panel content failing to load (separate problem).

If still 0 markers: Chromium's GPU init is failing for the same reason
as in Fusion. Look at the trace for:
  - `LdrGetProcedureAddress` failures on libegl.dll (ANGLE init)
  - `D3D11CreateDevice: Unsupported driver type` (DXVK rejecting WARP)
  - GPU subprocess crashes/early exits

## Files

| File | Purpose |
|------|---------|
| `webview2_host.c` | Win32 + COM scaffolding to spawn WebView2 |
| `webview2_minimal.h` | Minimal subset of WebView2 SDK interfaces (avoids vendoring full SDK) |
| `test_content.html` | GPU-compositing-eligible test page |
| `build.sh` | winegcc build |
| `run.sh` | Wineprefix setup + launch + trace capture. **Default: `USE_STAGING=1`** = system wine-staging (Zhang's DComp impl) → known-working. `USE_STAGING=0` = fusion-box's mainline-wine build → known-broken for rendering (useful only for A/B testing). |

## Reference links

- [Microsoft WebView2Samples — Win32 GettingStarted (HelloWebView.cpp)](https://github.com/MicrosoftEdge/WebView2Samples/tree/main/GettingStartedGuides/Win32_GettingStarted) — Cloned to `~/storage/code/github/WebView2Samples/`. The minimal Microsoft reference for embedding WebView2 in a Win32 app; our `webview2_host.c` follows the same WinMain → RegisterClassEx → CreateWindow → ShowWindow+UpdateWindow → CreateCoreWebView2Environment → CreateCoreWebView2Controller → put_Bounds → Navigate pattern (just in C with hand-rolled vtables instead of WRL/WIL C++).
- [Get started with WebView2 in Win32 apps](https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/win32) — Microsoft's walkthrough docs that the sample implements.
- [Wine-Staging DirectComposition patchset](https://github.com/wine-staging/wine-staging/commit/b70caa17726c3532b210a5ddf53af8024bc35b34) — 65-patch series by Zhiyi Zhang (CodeWeavers) adding ~15K lines of DComp impl. What `run-staging.sh` exercises.
- [Zhiyi Zhang's wine fork (directcomposition branch)](https://gitlab.winehq.org/zhiyi/wine/-/blob/directcomposition/README) — Active development branch.
- [Chromium `direct_composition_support.cc`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/gl/direct_composition_support.cc) — The Chromium side; `InitializeDirectComposition` early-returns silently if `d3d11_device` is null.
- [Bottles WebView2 fix writeup](https://dev.to/lionthehoon/fixing-webview2-issues-in-linux-bottles-how-i-got-it-working-1ab6) — Uses Proton GE + vcrun + dotnet48. Doesn't directly apply (uses XWayland implicitly).
