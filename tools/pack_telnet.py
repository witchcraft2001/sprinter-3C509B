#!/usr/bin/env python3
"""Build TELNET.EXE with the same WIN0-owner layout as Fido Editor."""

import struct
import sys

HEADER_SIZE = 512
LOAD_ADDR = 0x8100
STACK_ADDR = 0xBFFF


def read_blob(path: str) -> bytes:
    with open(path, "rb") as source:
        return source.read()


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        print(
            "usage: pack_telnet.py OUT.EXE loader.bin win0.bin win1.bin "
            "[overlay.bin ...]",
            file=sys.stderr,
        )
        return 2

    output = argv[1]
    loader = read_blob(argv[2])
    win0 = read_blob(argv[3])
    win1 = read_blob(argv[4])
    overlays = [read_blob(path) for path in argv[5:]]

    if not loader or len(loader) > STACK_ADDR - LOAD_ADDR + 1:
        raise SystemExit(f"TELNET loader has invalid size: {len(loader)}")
    if not win0 or len(win0) > 0x3FFF - 0x0180 + 1:
        raise SystemExit(f"TELNET WIN0 blob has invalid size: {len(win0)}")
    if not win1 or len(win1) > 0x4000:
        raise SystemExit(f"TELNET WIN1 blob has invalid size: {len(win1)}")
    for index, overlay in enumerate(overlays):
        if not overlay or len(overlay) > 0x4000:
            raise SystemExit(
                f"TELNET overlay {index} has invalid size: {len(overlay)}"
            )

    table = struct.pack("<HHB", len(win0), len(win1), len(overlays))
    table += b"".join(struct.pack("<H", len(blob)) for blob in overlays)

    header = bytearray(HEADER_SIZE)
    header[0:4] = b"EXE\x01"
    struct.pack_into("<I", header, 4, HEADER_SIZE)
    struct.pack_into("<H", header, 8, len(loader))
    struct.pack_into("<H", header, 16, LOAD_ADDR)
    struct.pack_into("<H", header, 18, LOAD_ADDR)
    struct.pack_into("<H", header, 20, STACK_ADDR)

    blob = bytes(header) + loader + table + win0 + win1 + b"".join(overlays)
    with open(output, "wb") as target:
        target.write(blob)

    print(
        f"pack_telnet: {output} loader={len(loader)} win0={len(win0)} "
        f"win1={len(win1)} overlays={[len(x) for x in overlays]} total={len(blob)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
