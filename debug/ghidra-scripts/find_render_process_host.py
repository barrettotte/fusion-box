# Ghidra script: locate RenderProcessHost-related functions and key landmarks
# in the analyzed Qt6WebEngineCore.dll.
#
# Run via:
#   /opt/ghidra/support/analyzeHeadless \
#       ~/.cache/fusion-box/ghidra-projects fusion-box \
#       -process Qt6WebEngineCore.dll \
#       -scriptPath debug/ghidra-scripts \
#       -postScript find_render_process_host.py
#
# What it prints (in priority order):
#   1. Address + xref count of the "single-process" string.
#   2. Address + xref count of "render_process_host_impl.cc" file-path string.
#   3. Function containing the qFatal string "Single mode supports only single
#      profile." (this is Qt's addProfileAdapter; one of its callees IS
#      RenderProcessHost::run_renderer_in_process(), which is exactly the
#      function we want to patch).
#   4. All callees of that function — the small bool-returning one IS the
#      target getter.
#   5. Any auto-recovered function names matching RenderProcessHost*.
#
# This is a Jython 2 script (Ghidra's built-in interpreter). Standard library
# limited to Python 2.7. No external pip deps.

# @category fusion-box

from ghidra.program.model.symbol import SourceType, RefType
from ghidra.app.decompiler import DecompInterface, DecompileOptions
from ghidra.util.task import ConsoleTaskMonitor


def find_string_address(s):
    """Locate a defined ASCII string in memory; return its address or None."""
    mem = currentProgram.getMemory()
    listing = currentProgram.getListing()
    found = []
    for d in listing.getDefinedData(True):
        try:
            v = d.getValue()
        except Exception:
            continue
        if v is None:
            continue
        # Strings come back as Python str-likes for ascii types.
        sv = str(v)
        if sv == s or s in sv:
            found.append((d.getAddress(), sv))
    return found


def xref_count_to(addr):
    rm = currentProgram.getReferenceManager()
    return sum(1 for _ in rm.getReferencesTo(addr))


def function_containing(addr):
    fm = currentProgram.getFunctionManager()
    return fm.getFunctionContaining(addr)


def list_callees(func):
    """Return list of (callee_func, call_site_addr) tuples."""
    if func is None:
        return []
    out = []
    body = func.getBody()
    rm = currentProgram.getReferenceManager()
    for addr in body.getAddresses(True):
        for r in rm.getReferencesFrom(addr):
            if r.getReferenceType().isCall():
                callee = currentProgram.getFunctionManager().getFunctionAt(r.getToAddress())
                if callee is not None:
                    out.append((callee, addr))
    return out


def decompile(func, line_limit=40):
    """Return decompiled C-like pseudocode (first N lines), or '' on failure."""
    if func is None:
        return ""
    di = DecompInterface()
    di.openProgram(currentProgram)
    try:
        res = di.decompileFunction(func, 30, ConsoleTaskMonitor())
        if res is None or not res.decompileCompleted():
            return ""
        text = res.getDecompiledFunction().getC()
        lines = text.splitlines()[:line_limit]
        return "\n".join(lines)
    finally:
        di.dispose()


def hr(title):
    print("\n" + "=" * 78)
    print("== " + title)
    print("=" * 78)


# ----------------------------------------------------------------------------
hr("DLL info")
print("Program: %s" % currentProgram.getName())
print("Image base: %s" % currentProgram.getImageBase())
print("Function count: %d" % currentProgram.getFunctionManager().getFunctionCount())

# ----------------------------------------------------------------------------
hr("string: 'single-process'")
matches = find_string_address("single-process")
for addr, s in matches[:5]:
    n_xref = xref_count_to(addr)
    print("  %s  xrefs=%d  %r" % (addr, n_xref, s))

# ----------------------------------------------------------------------------
hr("string: 'render_process_host_impl.cc'")
matches = find_string_address("render_process_host_impl.cc")
for addr, s in matches[:5]:
    n_xref = xref_count_to(addr)
    print("  %s  xrefs=%d  %r" % (addr, n_xref, s))
    # First few xref source functions
    rm = currentProgram.getReferenceManager()
    refs = list(rm.getReferencesTo(addr))
    for r in refs[:10]:
        src = r.getFromAddress()
        f = function_containing(src)
        print("    ref @ %s  in func: %s" % (src, f.getName() if f else "<unnamed>"))

# ----------------------------------------------------------------------------
hr("string: 'Single mode supports only single profile.' (Qt's addProfileAdapter)")
matches = find_string_address("Single mode supports only single profile.")
for addr, s in matches[:3]:
    print("  string @ %s  xrefs=%d" % (addr, xref_count_to(addr)))
    rm = currentProgram.getReferenceManager()
    for r in list(rm.getReferencesTo(addr))[:3]:
        src = r.getFromAddress()
        f = function_containing(src)
        print("    ref @ %s  in func: %s" % (src, f.getName() if f else "<unnamed>"))
        if f is not None:
            print("    >>> CALLEES of this func (looking for run_renderer_in_process getter):")
            seen = set()
            for callee, _ in list_callees(f)[:60]:
                key = callee.getEntryPoint()
                if key in seen:
                    continue
                seen.add(key)
                # Small bool-returning functions are likely getters. Print body size.
                size = callee.getBody().getNumAddresses()
                print("      callee %s  size=%d  %s" % (callee.getEntryPoint(), size, callee.getName()))
            print("    >>> DECOMPILE (first 40 lines):")
            print(decompile(f))

# ----------------------------------------------------------------------------
hr("auto-recovered function names matching 'RenderProcessHost' or 'run_renderer'")
fm = currentProgram.getFunctionManager()
hits = []
for f in fm.getFunctions(True):
    n = f.getName() or ""
    if "RenderProcessHost" in n or "run_renderer" in n.lower() or "InProcessRenderer" in n:
        hits.append(f)
print("Found %d functions" % len(hits))
for f in hits[:30]:
    print("  %s  size=%d  %s" % (f.getEntryPoint(), f.getBody().getNumAddresses(), f.getName()))

print("\n[done]")
