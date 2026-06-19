# Qt6WebEngineCore.dll binary patch investigation

Investigation log for the Data Panel render bug, pursuing the
binary-patch path (option 4a from `observed-issues.md`'s Data Panel
entry). Goal: locate and reverse a change Autodesk introduced in their
2026-06-12 auto-update to `Qt6WebEngineCore.dll` that broke Wayland
rendering of the Data Panel.

This is a working document. Methodology is the keeper; specific byte
offsets/sigs in here will rot when Autodesk updates the DLL again.

## Why binary patch (vs. rebuild from source)

See `observed-issues.md` Data Panel section for the full chain of
elimination. Short version:

- Cross-process Chromium subprocesses can't see Fusion main's
  `wayland_surface` (per-process win_data_rb in winewayland.drv) so the
  Data Panel HWND never gets a wayland role and KWin never sees it.
- `--single-process` env-var flag was tested in three variants
  (2026-06-18): all dead, multi-process subprocess spawn persists.
- Forward bisect of all fusion-box wine patches N=0..8 (2026-06-18):
  all dead. The bug is upstream wine + this specific DLL.
- Webdeploy mtime audit (2026-06-18): only `Qt6WebEngineCore.dll`
  changed on 2026-06-12; nothing else in the install. Strong
  correlation with the user's recollection of "Data Panel worked
  early in the project" (project started 2026-06-09; 3-day window
  with the original 2026-06-05 DLL).
- Pre-update DLL not locally recoverable (ext4, no snapshots, no
  installer cache).
- MSVC cross-build to rebuild from source is weeks of work
  ([[qt-msvc-abi-blocker]] for prereqs); binary patching the single
  DLL is days.

## Target identification

Run the reproducible probe:

```bash
distrobox enter fusion-box -- bash debug/probe-qt6webengine.sh
```

Output (snapshot 2026-06-18):

- Qt: **6.8.3** (`Qt 6.8.3 (x86_64-little_endian-llp64 shared
  (dynamic) release build; by MSVC 2022)`)
- Chromium: **122.0.6261.171** (bundled inside Qt6WebEngineCore.dll)
- DLL size: 148 MB, PE32+ x86-64, 10 sections
- Build path embedded in DLL: `C:/qt5/qtwebengine/src/core/...` —
  Autodesk built from upstream qtwebengine 6.8.3 source on Windows
  with MSVC 2022, RelWithDebInfo config.

The embedded source paths (`C:/qt5/qtwebengine/src/core/*.cpp`) act as
unique landmarks for radare2 — find an xref to one of these strings
and you're in the corresponding compiled function.

## Reference Qt source

We do NOT ship Qt source. For investigation, clone qtwebengine v6.8.3
elsewhere:

```bash
mkdir -p /tmp/qtwebengine-ref
cd /tmp/qtwebengine-ref
git clone --depth 1 --branch v6.8.3 https://code.qt.io/qt/qtwebengine.git
# v6.8.3 tag may resolve as a tag object; if `git checkout v6.8.3` fails,
# `git log --oneline -1` shows the dep-update commit which is close enough
# for our purposes.
cd qtwebengine && git checkout HEAD -- src/core/
```

Key files for this investigation:

- `src/core/web_engine_context.cpp` — `WebEngineContext::Initialize()`
  sets up command line for subprocesses. Most likely place where Qt
  manipulates `--single-process` behaviour.
- `src/core/content_main_delegate_qt.cpp` — `PreSandboxStartup()`
  references `switches::kSingleProcess` only to set locale, not to
  reject the flag. Suggests Qt does NOT strip `--single-process`.
- `src/core/net/system_network_context_manager.cpp` — emits the
  `"Cannot use V8 Proxy resolver in single process mode."` warning
  string visible in the DLL.

## Findings so far (2026-06-18)

### Single-process flag is NOT being stripped by Qt

Upstream Qt 6.8.3 source does not actively strip `--single-process`.
The handful of `kSingleProcess` references in qtwebengine source are
all conditional code paths that *support* single-process (locale
setup, profile-adapter rules) rather than reject it. `initCommandLine()`
in `web_engine_context.cpp:1161` correctly forwards everything in
`QTWEBENGINE_CHROMIUM_FLAGS` into Chromium's `base::CommandLine`.

### radare2 xref search came up empty (pivoted to Ghidra)

Initial attempt to find the patch site by xref-ing the string
`"single-process"` at virtual address `0x1876757f0` returned **zero
hits** after a 14-minute `r2 -A0 -e bin.cache=true -q -c "/r"`
session. Second attempt using a higher-yield landmark (the file path
string `"render_process_host_impl.cc"`, which every DCHECK in that
compilation unit references) ran 7+ minutes and likewise produced no
visible hits in the captured output. Two likely reasons:
- **LTO inlining**: Chromium 122 is built with link-time
  optimization, which can replace `lea reg, [rip+disp]` patterns
  with materialized immediates or table-of-pointer indirection that
  `/r` doesn't catch.
- **Table indirection**: the bytes near `single-process` in the DLL
  show the surrounding Chromium switches array
  (`disable-...-access-allowed`, `single-process`, `site-per-process`,
  `disable-site-isolation-trials`, etc.). The switch constant
  `switches::kSingleProcess` IS this string by address — but the only
  direct reference is likely from a switch table lookup, not a LEA
  on the string itself.

**Pivoted to Ghidra** 2026-06-18:
- Better decompiler than r2, persistent project model (analysis
  cached across sessions instead of re-run on every invocation),
  better xref resolution against LTO-optimized code.
- `debug/ghidra-analyze-qt6webengine.sh` runs the headless import +
  auto-analysis once (1-2 hours for 148MB). Subsequent queries
  re-use the project under `~/ghidra-projects/fusion-box.gpr` and
  are fast.
- `debug/ghidra-scripts/find_render_process_host.py` is the first
  discovery script — finds the `"single-process"` string, the
  `render_process_host_impl.cc` file-path string, the qFatal
  `"Single mode supports only single profile."` (which lives in
  Qt's `addProfileAdapter` and calls
  `RenderProcessHost::run_renderer_in_process()`), and lists that
  function's callees. The small bool-returning callee IS the getter
  we want to patch.
- Containerfile updated: `ghidra` + `jdk21-openjdk` added to the
  reverse-engineering toolchain RUN block (~1 GB added). Note that
  Ghidra rejects project paths containing `.`-prefixed elements
  (e.g., `~/.cache/`), so projects live under plain `$HOME` instead.

### Process-tree capture (the smoking gun)

`debug/capture-process-tree.sh` runs Fusion twice (with and without
`--single-process`) and captures both wine `+process` traces and
OS-level `ps` snapshots. Comparison of the two runs shows:

| Subprocess type | baseline count | `--single-process` count |
|-----------------|---------------:|-------------------------:|
| `--type=renderer` | 14 | 14 |
| `--type=gpu-process` | 12 | 10 |
| `--type=utility` | 4 | 4 |
| `--type=crashpad-handler` | 2 | 2 |
| `--single-process` anywhere in any subprocess cmdline | 0 | 0 |
| `--no-sandbox` propagating to subprocess cmdlines | 0 | many |

Key observations:

1. **No `--type=browser` spawn ever happens**: Fusion main IS the
   Chromium browser process (loads `Qt6WebEngineCore.dll` inline).
   So `--single-process` only needs to affect Fusion main's
   spawn-renderer decision.
2. **`--no-sandbox` propagates correctly** from
   `QTWEBENGINE_CHROMIUM_FLAGS` env → Qt → Chromium → subprocess
   cmdlines. So Qt's command-line handling IS working in general.
3. **Renderer count is identical** with or without `--single-process`.
   This narrows the patch target: somewhere in this DLL,
   `RenderProcessHostImpl::Init()` (or its caller) checks
   `RenderProcessHost::run_renderer_in_process()` and the check is
   either being skipped, returning false unconditionally, or there's
   a separate code path that forces the spawn.
4. The 2-count drop in `gpu-process` (12 → 10) with `--single-process`
   is the only behavioural difference observed. Possibly Chromium's
   GPU-process restart logic is influenced by the flag, but renderer
   spawning is not.

The reproducer script + comparison method is the keeper here even
when the byte offsets in this DLL rot — future Fusion updates can be
re-tested with the same harness.

## Patch artifact format (TBD)

When the patch is identified, it'll live in `patches/qt/` as a
metadata file describing the binary patch (offsets, original bytes,
new bytes) plus an idempotent `scripts/patch-qt6webengine.sh` that
applies it with a backup. Reasoning: we can't ship the DLL itself,
and the patch will need to be re-applied after every Fusion
auto-update.

## Reproducibility checklist

Anyone following this investigation should be able to:

- [x] Run `debug/probe-qt6webengine.sh` and get the version/build
      info dump.
- [x] Reproduce the trace showing renderer subprocess spawning under
      `--single-process` via `debug/capture-process-tree.sh`. Compare
      `ptree-baseline-*.log` vs `ptree-sp-*.log` for the
      `--type=renderer` count.
- [ ] Locate the patch site in the DLL via radare2 (recipe pending,
      will live here once verified). Note: searching xrefs to the
      `single-process` string returns nothing due to LTO/table
      indirection; better target is `RenderProcessHostImpl::Init` or
      `RenderProcessHost::run_renderer_in_process`.
- [ ] Apply the patch via `scripts/patch-qt6webengine.sh` (script
      pending). Will live in `scripts/` (production path) because
      users will run it post-Fusion-install.
- [ ] Re-run the Data Panel test to confirm the patch fixes the bug.
