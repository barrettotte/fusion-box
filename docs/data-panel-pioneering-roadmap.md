# Data Panel rendering: roadmap

> **STATUS 2026-06-26: RESOLVED — and the actual fix was much simpler than
> we thought.**
>
> Weeks of investigation chased "wine doesn't implement DComp, must implement
> it" angles: cross-process subsurface fix attempts, custom Phase D dcomp.dll
> (~1500 lines), discovery of wine-staging's 15K-line DComp impl. The
> empirical fix turned out to be: **delete the polluted wineprefix and
> reinstall Fusion fresh.** Mainline wine 11.10 + our 10 fusion-box patches
> works fine in a clean prefix.
>
> See "What we got wrong" below for the lessons.

## The actual fix

```bash
# 1. Backup the prefix (optional, recoverable).
mv ~/.wine-fusion ~/.wine-fusion.backup-$(date +%Y%m%d-%H%M%S)

# 2. Reinstall Fusion fresh.
distrobox enter fusion-box -- bash scripts/install-fusion.sh

# 3. Launch.
distrobox enter fusion-box -- bash scripts/launch-fusion.sh
```

Data Panel renders. That's it.

## Why the fresh prefix worked

The polluted prefix had accumulated state from tonight's many experiments:
- Chromium-internal "DComp broken" cache (Edge tested DComp early, got
  E_NOTIMPL from wine's stub, cached the failure, never retried)
- Multiple `dcomp.dll` versions swapped in/out of `system32`
- `HKLM\Software\Policies\Microsoft\Edge\AdditionalLaunchParameters` registry
  entries we added then "removed" (may have left residue)
- `WINEDLLOVERRIDES` experiments
- Various `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` browser-flag tests
- Edge user-data-dir (`ADPWebView`) GPU/feature caches across multiple
  config attempts

Fresh install eliminated all of it AND the Fusion installer auto-updated
Edge WebView2 from `149.0.4022.62` → `149.0.4022.98`. Either or both made
the difference.

We never tested "does the same wine work without our experiments having
touched the prefix?" — because by the time we asked, the prefix was already
polluted.

## Wine-staging path (still supported, no longer required)

The `scripts/build-wine.sh` build script supports `USE_STAGING=1` for
opting into wine-staging's ~250 experimental patches (including Zhang's
DComp impl). Off by default since mainline + our patches is sufficient.
Useful as A/B comparison or as a fallback if a future Fusion bug genuinely
needs broader compat coverage.

```bash
# Mainline wine + our patches (default — known-good)
scripts/build-wine.sh

# Wine-staging + our patches (broader compat layer if needed)
USE_STAGING=1 scripts/build-wine.sh
```

## Validation harness

`debug/webview2-test/` — standalone WebView2 host built tonight as a
diagnostic tool. Bypasses Fusion's network/auth/content-load chain and
isolates "does wine + Edge render a webpage to a host HWND" question.

```bash
bash debug/webview2-test/build.sh
bash debug/webview2-test/run.sh                # default: wine-staging
USE_STAGING=0 bash debug/webview2-test/run.sh  # our built wine
```

Useful for: regression-testing wine builds, debugging Chromium/wine
interactions in future investigations.

## What we got wrong (lessons learned)

1. **Should have tried fresh prefix FIRST.** Standard troubleshooting:
   when an app stops rendering, test in a clean environment before
   instrumenting the dependency chain. We instead spent weeks tracing
   wine source, Chromium source, DXVK source. The fresh-prefix test
   would have answered "is this prefix-state or something deeper?" in
   30 minutes.

2. **Trace evidence pointed wrong-but-consistent.** Every trace showed:
   Edge loaded `dcomp.dll`, never called `DCompositionCreateDevice3`,
   `d3d11_device == NULL`, etc. ALL consistent with "wine missing DComp"
   theory. None of it would distinguish "polluted prefix made Edge cache
   the failure" from "wine's DComp implementation is missing". We needed
   the **counterfactual** (does it work with no polluting state?) and
   we never set up that experiment.

3. **The morning trace ambiguity.** The morning of 2026-06-23, an
   early trace showed Edge calling DComp 7+ times. By evening, Edge
   stopped. We attributed this to "Chromium internal policy
   decisions". The real cause was probably "Chromium cached the
   morning's failure and stopped retrying". The fresh prefix removes
   that cache.

4. **Our Phase D dcomp.dll work was unnecessary** for THIS bug, but
   was educationally valuable: we learned wine's PE DLL build system,
   the IDCompositionDevice/Visual/Target/Surface COM hierarchy, wine's
   test runner conventions. Code was deleted (`tmp/phase-d-sources/`)
   since wine-staging has a superset if ever needed.

5. **`debug/webview2-test/` IS valuable infrastructure.** It directly
   tests "wine + Edge → can render" without depending on Fusion. Keep
   it as a regression-test harness for any future wine work.

6. **Search upstream FIRST when implementing in-tree.** Even though
   wine-staging wasn't actually needed, the lesson stands: had we
   needed DComp, Zhang's 15K-line implementation already existed.
   We spent hours reimplementing 1500 lines of it.

## Cross-references

- `observed-issues.md` — umbrella view of all known Fusion-on-wine bugs
- `qt6webengine-binary-patch.md` — ABANDONED (Data Panel uses Edge WebView2, not Qt6WebEngine)
- `bottom-toolbar-burial.md` — separate toolbar-burial investigation
- `UPSTREAM-RESEARCH.md` — pre-investigation wine MR survey
- `debug/webview2-test/README.md` — validation harness usage
- Wine-Staging DComp patchset (kept as reference): <https://github.com/wine-staging/wine-staging/commit/b70caa17726c3532b210a5ddf53af8024bc35b34>
