#!/usr/bin/env python3
"""Convert a grayscale frame into .memh files consumable by tb_vcnpu_integrated.

Outputs:
- ref.memh   : FRAME_WIDTH*FRAME_HEIGHT 16-bit words, row-major (y-major then x)
- patch.memh : 256*16 16-bit words, patch-major where each patch is a 4x4 block.

The integrated TB expects 64x64 by default and 256 patches of 16 values.

Example (requires ffmpeg installed):
  ffmpeg -i input.mp4 -vf scale=64:64,format=gray -frames:v 1 frame64.raw
  python Prop/tools/frame_to_memh.py --raw frame64.raw --w 64 --h 64 --ref-out ref.memh --patch-out patch.memh

Then run:
  powershell -ExecutionPolicy Bypass -File Prop/run_tb.ps1 -RefMemh ref.memh -PatchMemh patch.memh
"""

from __future__ import annotations

import argparse
from pathlib import Path


def _scale_u8_to_u16(v: int, mode: str) -> int:
    if mode == "mul257":
        return (v & 0xFF) * 257  # 0..255 -> 0..65535
    if mode == "shift8":
        return (v & 0xFF) << 8
    if mode == "none":
        return v & 0xFF
    raise ValueError(f"unknown scale mode: {mode}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=Path, required=True, help="Input raw 8-bit grayscale bytes (W*H bytes)")
    ap.add_argument("--w", type=int, required=True, help="Frame width")
    ap.add_argument("--h", type=int, required=True, help="Frame height")
    ap.add_argument("--ref-out", type=Path, required=True, help="Output ref.memh path")
    ap.add_argument("--patch-out", type=Path, required=True, help="Output patch.memh path")
    ap.add_argument(
        "--scale",
        choices=["mul257", "shift8", "none"],
        default="mul257",
        help="How to map 8-bit pixels to 16-bit words",
    )
    ap.add_argument("--patch", type=int, default=4, help="Patch size (default 4 => 4x4 blocks)")
    args = ap.parse_args()

    raw = args.raw.read_bytes()
    expected = args.w * args.h
    if len(raw) != expected:
        raise SystemExit(f"Expected {expected} bytes for {args.w}x{args.h}, got {len(raw)}")

    # Convert to 16-bit words
    words = [_scale_u8_to_u16(b, args.scale) for b in raw]

    # Write reference frame, row-major
    args.ref_out.parent.mkdir(parents=True, exist_ok=True)
    with args.ref_out.open("w", newline="\n") as f:
        for w in words:
            f.write(f"{w & 0xFFFF:04x}\n")

    # Patch extraction: patch-major 4x4 blocks, row-major blocks.
    p = args.patch
    if (args.w % p) != 0 or (args.h % p) != 0:
        raise SystemExit(f"Frame size must be divisible by patch size {p}")

    blocks_x = args.w // p
    blocks_y = args.h // p

    args.patch_out.parent.mkdir(parents=True, exist_ok=True)
    with args.patch_out.open("w", newline="\n") as f:
        for by in range(blocks_y):
            for bx in range(blocks_x):
                for py in range(p):
                    for px in range(p):
                        x = bx * p + px
                        y = by * p + py
                        f.write(f"{words[y * args.w + x] & 0xFFFF:04x}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
