# Ghidra preScript: disable expensive analyzers before auto-analysis.
#
# Run via:
#   analyzeHeadless ... -preScript preanalysis_disable_slow.py
#
# Rationale: a full auto-analysis of the 148 MB Qt6WebEngineCore.dll
# (Chromium 122 embedded) takes 4-8 hours and tends to OOM the JVM. For
# the patch-site investigation (find RenderProcessHostImpl::Init and
# friends) we don't need parameter-type recovery or aggressive instruction
# search — we just need functions discovered + cross-references resolved
# + on-demand decompile via separate postScripts. Disabling the slowest
# analyzers cuts analysis time to ~30-90 min.
#
# Disabled analyzers:
#   - Decompiler Parameter ID: re-decompiles every function to infer
#     parameter types. Single slowest analyzer; we don't need typed sigs.
#   - Aggressive Instruction Finder: scans gaps in .text for missed code.
#     Useful for obfuscated/packed binaries; this is a normal MSVC build.
#   - Stack: stack-pointer simulation. Needed for accurate locals but not
#     for finding function boundaries / xrefs.
#   - DWARF: not present in this DLL (no debug info), so a no-op for us;
#     listed for completeness.
#   - Embedded Media: scans for GIF/PNG/JPEG byte signatures. Generates
#     thousands of false-positive ERROR lines in the log on Chromium
#     binaries (we already saw 100+ "Invalid GIF data" entries before).
#
# Kept (cheap + useful):
#   - ASCII Strings, Demangler Microsoft, Function Start Search,
#     Reference/Call analysis, Decompiler Switch Analysis, C++ Class
#     Analyzer, Stack-allocated variables.

# @category fusion-box

DISABLE = [
    "Decompiler Parameter ID",
    "Aggressive Instruction Finder",
    "Stack",
    "DWARF",
    "Embedded Media",
]

print("[preanalysis_disable_slow] Disabling slow analyzers:")
for name in DISABLE:
    try:
        setAnalysisOption(currentProgram, name, "false")
        print("  - %s: disabled" % name)
    except Exception as e:
        # Some analyzer names vary between Ghidra versions; warn but don't fail.
        print("  - %s: WARN failed to disable (%s)" % (name, e))

print("[preanalysis_disable_slow] done")
