#!/usr/bin/env python3
"""
Inspect a region of a PPM P6 file. Used to check whether the nav toolbar pixels (x=1161-1400, y=1285-1309)
appear in main's swapchain PPMs across the splash -> post-splash transition.

Usage:
    inspect-ppm-region.py FRAME_NUMBER [x0 y0 x1 y1]
    inspect-ppm-region.py 100               # default region = nav toolbar
    inspect-ppm-region.py 100 0 0 100 100   # custom region
"""

import sys
from pathlib import Path


def read_ppm(path):
    """Read PPM P6, return (width, height, maxval, pixels) where pixels is a bytes object of width*height*3 (RGB)."""
    with open(path, "rb") as f:
        magic = f.readline().strip()
        assert magic == b"P6", f"not P6: {magic}"

        # PPM headers can have comments; skip them.
        while True:
            line = f.readline()
            if not line.startswith(b"#"):
                break

        dims = line.split()
        if len(dims) == 1:
            dims = dims + f.readline().split()

        width, height = int(dims[0]), int(dims[1])
        maxval = int(f.readline().strip())
        pixels = f.read()

        expected = width * height * 3
        assert len(pixels) == expected, (
            f"pixel data {len(pixels)} != expected {expected}"
        )
    return width, height, maxval, pixels


def region_stats(width, height, pixels, x0, y0, x1, y1):
    """Compute pixel stats for a region. Returns dict with count, non_zero, avg_r, avg_g, avg_b."""
    x0 = max(0, x0)
    y0 = max(0, y0)
    x1 = min(width, x1)
    y1 = min(height, y1)
    rs, gs, bs = 0, 0, 0
    nz = 0
    n = 0

    for y in range(y0, y1):
        row_start = y * width * 3
        for x in range(x0, x1):
            i = row_start + x * 3
            r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
            rs += r
            gs += g
            bs += b
            if r or g or b:
                nz += 1
            n += 1

    if n == 0:
        return {
            "count": 0,
            "non_zero": 0,
            "non_zero_pct": 0.0,
            "avg_r": 0.0,
            "avg_g": 0.0,
            "avg_b": 0.0,
        }
    return {
        "count": n,
        "non_zero": nz,
        "non_zero_pct": 100.0 * nz / n,
        "avg_r": rs / n,
        "avg_g": gs / n,
        "avg_b": bs / n,
    }


def write_region_ppm(width, pixels, x0, y0, x1, y1, out_path):
    """Extract a sub-region and write it as a new PPM P6."""
    rw = x1 - x0
    rh = y1 - y0
    buf = bytearray()

    for y in range(y0, y1):
        row_start = y * width * 3
        buf.extend(pixels[row_start + x0 * 3 : row_start + x1 * 3])

    with open(out_path, "wb") as f:
        f.write(f"P6\n{rw} {rh}\n255\n".encode())
        f.write(buf)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    frame = int(sys.argv[1])
    path = Path(f"/tmp/dxvk-dump/{frame}.ppm")
    if not path.exists():
        print(f"missing: {path}")
        sys.exit(1)

    # nav toolbar default region (Win32 coords from probe)
    if len(sys.argv) >= 6:
        x0, y0, x1, y1 = (int(a) for a in sys.argv[2:6])
    else:
        x0, y0, x1, y1 = 1161, 1285, 1400, 1309

    width, height, _, pixels = read_ppm(path)
    print(f"frame {frame}: {width}x{height}")
    print(f"region: ({x0},{y0})-({x1},{y1})  {x1 - x0}x{y1 - y0}")

    stats = region_stats(width, height, pixels, x0, y0, x1, y1)
    print(f"  pixels:    {stats['count']}")
    print(f"  non_zero:  {stats['non_zero']} ({stats['non_zero_pct']:.1f}%)")
    print(
        f"  avg color: ({stats['avg_r']:.1f}, {stats['avg_g']:.1f}, {stats['avg_b']:.1f})"
    )

    out = f"/tmp/dxvk-dump/region_{frame}.ppm"
    write_region_ppm(width, pixels, x0, y0, x1, y1, out)
    print(f"  wrote: {out}")


if __name__ == "__main__":
    main()
