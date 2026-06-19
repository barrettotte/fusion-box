#!/usr/bin/env python3
"""
Locate the RenderProcessHost::run_renderer_in_process() getter in
Fusion's bundled Qt6WebEngineCore.dll using capstone disassembly.

Why this script: r2's /r xref search returned nothing and Ghidra's full
auto-analysis OOMs at 16 GB. We don't actually need full analysis to
find this one tiny function — we just need to:
  1. Find the qFatal string "Single mode supports only single profile."
     (located in Qt's `addProfileAdapter`, web_engine_context.cpp:663).
  2. Find LEA refs to that string in .text — those are inside
     `addProfileAdapter`.
  3. Identify the containing function via prologue scanning.
  4. Enumerate its CALL targets.
  5. The smallest bool-returning function among those callees IS
     `RenderProcessHost::run_renderer_in_process()` (it's a static method
     that just returns a global bool; body ~5-15 bytes).

Output: candidate getter function virtual addresses + their disassembly,
ready to feed into scripts/patch-qt6webengine.sh.

Requires: pefile, capstone (both in Containerfile).
Runtime: ~30 seconds on a 148 MB DLL.
"""

import os
import struct
import sys

import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86 import X86_OP_MEM, X86_OP_IMM, X86_REG_RIP

# ---------------------------------------------------------------------------

DEFAULT_DLL = os.path.expanduser(
    "~/.wine-fusion/drive_c/Program Files/Autodesk/webdeploy/production/"
    "441fa886a8bddbe651a2c8bfe18605e72308757a/Qt6WebEngineCore.dll"
)

QFATAL_STRING = b"Single mode supports only single profile.\x00"

# ---------------------------------------------------------------------------

def find_bytes(blob, needle):
    """Yield all file-offset occurrences of needle in blob."""
    i = 0
    while True:
        i = blob.find(needle, i)
        if i < 0:
            return
        yield i
        i += 1

def file_offset_to_va(pe, off):
    """Convert a PE file offset to its loaded virtual address."""
    for s in pe.sections:
        if s.PointerToRawData <= off < s.PointerToRawData + s.SizeOfRawData:
            return pe.OPTIONAL_HEADER.ImageBase + s.VirtualAddress + (off - s.PointerToRawData)
    return None

def va_to_file_offset(pe, va):
    """Convert a virtual address back to its file offset."""
    rva = va - pe.OPTIONAL_HEADER.ImageBase
    for s in pe.sections:
        if s.VirtualAddress <= rva < s.VirtualAddress + s.Misc_VirtualSize:
            return s.PointerToRawData + (rva - s.VirtualAddress)
    return None

def get_section(pe, name):
    """Return the named section's (data, va_base, file_offset_base)."""
    for s in pe.sections:
        sname = s.Name.rstrip(b"\x00").decode("ascii", errors="replace")
        if sname == name:
            return (
                s.get_data(),
                pe.OPTIONAL_HEADER.ImageBase + s.VirtualAddress,
                s.PointerToRawData,
            )
    raise KeyError("no %s section" % name)


def find_lea_refs(text_data, text_va_base, target_va):
    """Yield (instr_va, instr_size) of every `lea reg, [rip+disp]` whose
    effective address equals target_va. Capstone over all of .text is
    slow (~30 s) but fine for our purposes; we run this once."""
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    hits = []
    for ins in md.disasm(text_data, text_va_base):
        if ins.mnemonic != "lea":
            continue
        if len(ins.operands) != 2:
            continue
        op_dst, op_src = ins.operands
        if op_src.type != X86_OP_MEM:
            continue
        m = op_src.mem
        if m.base != X86_REG_RIP or m.index != 0:
            continue
        eff = ins.address + ins.size + m.disp
        if eff == target_va:
            hits.append((ins.address, ins.size))
    return hits


def find_function_start(text_data, text_va_base, instr_va, max_back=8192):
    """Walk backwards from instr_va looking for a function prologue
    (typical MSVC: int3 padding then `push rbp` / `sub rsp` / `mov [rsp+x],reg`)
    or aligned 0xCC fill. Returns the VA of the first non-padding instr
    after the most recent run of 0xCC bytes."""
    off = instr_va - text_va_base
    start = max(0, off - max_back)
    # Find the last run of 0xCC (int3) padding before our instr.
    region = text_data[start:off]
    # Walk backwards looking for 0xCC bytes (function alignment padding).
    i = len(region) - 1
    last_padding_end = None
    while i >= 0:
        if region[i] == 0xCC:
            # Found padding — function probably starts after this run.
            last_padding_end = i + 1
            break
        i -= 1
    if last_padding_end is None:
        return None
    return text_va_base + start + last_padding_end


def collect_calls(text_data, text_va_base, func_start_va, max_size=65536):
    """From func_start_va, disassemble until first ret/jmp-to-elsewhere
    or max_size, collecting all CALL targets."""
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    off = func_start_va - text_va_base
    region = text_data[off:off + max_size]
    calls = []
    end_va = func_start_va
    for ins in md.disasm(region, func_start_va):
        end_va = ins.address + ins.size
        if ins.mnemonic == "call":
            if len(ins.operands) == 1 and ins.operands[0].type == X86_OP_IMM:
                calls.append((ins.address, ins.operands[0].imm))
        elif ins.mnemonic == "ret":
            break
        # Don't break on jmp — early-out for if-arms within the function.
    return calls, end_va


def disasm_at(text_data, text_va_base, va, n_bytes=32):
    """Return list of (addr, mnemonic, op_str) for n_bytes from va."""
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    off = va - text_va_base
    if off < 0 or off + n_bytes > len(text_data):
        return []
    out = []
    for ins in md.disasm(text_data[off:off + n_bytes], va):
        out.append((ins.address, ins.mnemonic, ins.op_str, ins.size))
        if ins.mnemonic == "ret":
            break
    return out


def looks_like_bool_getter(disasm):
    """A static bool getter typically looks like:
        movzx eax, byte ptr [rip+disp]   ; load global
        ret
       or
        mov al, byte ptr [rip+disp]
        ret
       Total body <= 16 bytes."""
    if not disasm or len(disasm) > 4:
        return False
    # Last instruction must be ret.
    if disasm[-1][1] != "ret":
        return False
    # Some instruction loading al / eax from a RIP-relative memory.
    for addr, mnem, op_str, sz in disasm[:-1]:
        if mnem in ("mov", "movzx") and ("al," in op_str or "eax," in op_str) and "rip" in op_str:
            return True
    return False


# ---------------------------------------------------------------------------

def main():
    dll = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DLL
    print("[disasm-spawn] DLL: %s" % dll)

    with open(dll, "rb") as f:
        blob = f.read()

    pe = pefile.PE(data=blob, fast_load=True)
    text_data, text_va_base, _ = get_section(pe, ".text")
    rdata, rdata_va_base, rdata_paddr = get_section(pe, ".rdata")
    print("[disasm-spawn] .text @ 0x%x size=0x%x" % (text_va_base, len(text_data)))
    print("[disasm-spawn] .rdata @ 0x%x size=0x%x" % (rdata_va_base, len(rdata)))

    # Locate the qFatal string in the file.
    fposns = list(find_bytes(blob, QFATAL_STRING))
    if not fposns:
        print("[disasm-spawn] FATAL: qFatal string not found")
        sys.exit(1)
    qfatal_file_off = fposns[0]
    qfatal_va = file_offset_to_va(pe, qfatal_file_off)
    print("[disasm-spawn] qFatal string @ file 0x%x → VA 0x%x" %
          (qfatal_file_off, qfatal_va))

    # Find all LEA refs to that VA.
    print("[disasm-spawn] scanning .text for LEA refs (~30s)...")
    refs = find_lea_refs(text_data, text_va_base, qfatal_va)
    print("[disasm-spawn] found %d LEA refs:" % len(refs))
    for va, sz in refs:
        print("  LEA @ 0x%x (size %d)" % (va, sz))

    if not refs:
        print("[disasm-spawn] no LEA refs to qFatal string — Qt may use a different "
              "string-load pattern (e.g., MOV imm64). Try expanding the disassembly "
              "search to include MOV reg, imm64 instructions.")
        sys.exit(2)

    # For the first ref, find containing function.
    ref_va = refs[0][0]
    func_start = find_function_start(text_data, text_va_base, ref_va)
    if func_start is None:
        print("[disasm-spawn] could not locate function start before 0x%x" % ref_va)
        sys.exit(3)
    print("\n[disasm-spawn] addProfileAdapter starts at VA 0x%x" % func_start)

    # Enumerate call sites in that function.
    calls, end_va = collect_calls(text_data, text_va_base, func_start)
    print("[disasm-spawn] function spans 0x%x..0x%x  (%d call sites)" %
          (func_start, end_va, len(calls)))

    # Disassemble each callee and look for the bool-getter pattern.
    candidates = []
    for site_va, target_va in calls:
        disasm = disasm_at(text_data, text_va_base, target_va, n_bytes=32)
        if looks_like_bool_getter(disasm):
            candidates.append((site_va, target_va, disasm))

    print("\n[disasm-spawn] %d call sites point to candidate bool-getter functions:"
          % len(candidates))
    for site_va, target_va, disasm in candidates:
        print("\n  call site @ 0x%x  →  target 0x%x" % (site_va, target_va))
        target_file_off = va_to_file_offset(pe, target_va)
        print("    target file offset: 0x%x" % target_file_off)
        for addr, mnem, op_str, sz in disasm:
            print("      0x%x  (%d)  %-6s %s" % (addr, sz, mnem, op_str))

    print("\n[disasm-spawn] done. The target getter is "
          "RenderProcessHost::run_renderer_in_process(); the global it "
          "reads is g_run_renderer_in_process_. Patch suggestion: "
          "overwrite the getter body with `b0 01 c3` (mov al, 1; ret) "
          "padded with 0x90 to match original body length.")


if __name__ == "__main__":
    main()
