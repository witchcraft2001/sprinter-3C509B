#!/usr/bin/env python3
"""Run Battleship N3 or repeated N4 LISTEN against a frozen DLL.

Requires the built Battleship fixture, MAME, DSS ROM/disk assets, and the
existing feth0/feth1 pair (192.168.7.1 on feth1). Captures only the test IP.
No network configuration or emulator source is changed.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--battleship", type=Path,
                        default=repo.parent / "sources/games/battleship")
    parser.add_argument("--assets", type=Path,
                        default=repo.parent / "mame_images/mame_release_v306_25.05.2025")
    parser.add_argument("--mame", type=Path)
    parser.add_argument("--dll", type=Path, default=repo / "build/UNET509B.DLL")
    parser.add_argument("--output", type=Path, default=repo / "build/send-mame")
    parser.add_argument("--stall", type=int, nargs="+", default=[6, 15, 30])
    parser.add_argument("--port", type=int, default=17777)
    parser.add_argument("--client-ip", default="192.168.7.49",
                        help="private fixture IP, avoiding sibling emulators at .2")
    parser.add_argument("--client-timeout", type=int, default=60,
                        help="isolated BSTAND resume watchdog in seconds (original: 20)")
    parser.add_argument("--blocking", action="store_true",
                        help="set SENDSLICE=0 in the private BSTAND copy (R1)")
    parser.add_argument("--listen-repeats", type=int, default=0,
                        help="run N4 LISTEN this many times instead of N3 stalls")
    args = parser.parse_args()
    if not 0 <= args.listen_repeats <= 20 or (args.listen_repeats and args.blocking):
        parser.error("--listen-repeats must be 0..20 and cannot combine with --blocking")
    scenario = "n4" if args.listen_repeats else "n3"
    listen_port = 7778  # BSTAND's N4 LISTEN_PORT is a fixed fixture constant.
    if not 1 <= args.port <= 65534:
        parser.error("--port must leave room for the listening port at port+1")
    client_ip = str(ipaddress.IPv4Address(args.client_ip))
    assert ipaddress.IPv4Address(client_ip) in ipaddress.IPv4Network("192.168.7.0/24")
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("192.168.7.1", args.port))
    mame = (args.mame or args.assets / "mame").resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    # A concurrent build must not change the DLL halfway through the matrix.
    dll_bytes = args.dll.read_bytes()
    snapshot = out / "UNET509B.DLL"
    snapshot.write_bytes(dll_bytes)
    listing = run(str(mame), "-networkprovider", "pcap", "-listnetwork",
                  capture_output=True, text=True).stdout
    interfaces = listing.split("Available network interfaces:", 1)[1].splitlines()
    interfaces = [line.strip() for line in interfaces if line.strip()]
    interface = interfaces.index("feth0")
    hashes = {}
    for name in ["build/BSTAND_NET509.img", "build/bstand.sym",
                 "tools/mame_bstand.lua", "tools/echo_server.py", "tools/pad_runts.py",
                 "tools/tcp_poke.py"]:
        hashes[name] = hashlib.sha256((args.battleship / name).read_bytes()).hexdigest()
    hashes["UNET509B.DLL"] = hashlib.sha256(dll_bytes).hexdigest()
    assert 1 <= args.client_timeout <= 600
    symbols = dict((name, int(value, 16)) for name, value in re.findall(
        r"^(\S+): EQU 0x([0-9a-fA-F]+)",
        (args.battleship / "build/bstand.sym").read_text(), re.M))
    (out / "inputs.json").write_text(json.dumps(hashes, indent=2) + "\n")
    results = []
    runs = ([(f"listen-{n}", 0) for n in range(1, args.listen_repeats + 1)]
            if args.listen_repeats else [(f"stall-{s}", s) for s in args.stall])
    for run_name, stall in runs:
        work = out / run_name
        for directory in ["tools", "build/mame", "cfg", "nvram", "diff", "shots"]:
            (work / directory).mkdir(parents=True, exist_ok=True)
        for name in ["mame_bstand.lua", "echo_server.py", "pad_runts.py", "tcp_poke.py"]:
            shutil.copy2(args.battleship / "tools" / name, work / "tools" / name)
        # Record the full stream digest; the original fixture prints 16 digits.
        server = work / "tools/echo_server.py"
        server.write_text(server.read_text().replace("h.hexdigest()[:16]", "h.hexdigest()"))
        padding = work / "tools/pad_runts.py"
        marker = '            os.write(fd, frame + b"\\0" * (60 - len(frame)))'
        padding_source = padding.read_text()
        assert padding_source.count(marker) == 1
        address = repr(ipaddress.IPv4Address(client_ip).packed)
        padding.write_text(padding_source.replace(marker,
            f'            if frame[12:14] == b"\\x08\\x00" and frame[30:34] != {address}:\n'
            '                continue\n'
            f'            if frame[12:14] == b"\\x08\\x06" and frame[38:42] != {address}:\n'
            '                continue\n' + marker))
        driver = work / "tools/mame_bstand.lua"
        driver_source = driver.read_text().replace("--port 7777 --log",
                                                   f"--port {args.port} --log")
        if args.listen_repeats:
            poke_target = "192.168.7.2 7778 --deadline 150"
            assert driver_source.count(poke_target) == 1
            driver_source = driver_source.replace(
                poke_target, f"{client_ip} {listen_port} --deadline 150")
        driver.write_text(driver_source)
        image = work / "BSTAND.img"
        shutil.copy2(args.battleship / "build/BSTAND_NET509.img", image)
        run("mcopy", "-o", "-i", str(image), str(snapshot), "::BSHIP/UNET509B.DLL")
        config = run("mtype", "-i", str(image), "::BSHIP/NET.CFG",
                     capture_output=True).stdout
        assert b"\r\nIP=192.168.7.2\r\n" in config
        (work / "NET.CFG").write_bytes(config.replace(
            b"\r\nIP=192.168.7.2\r\n", f"\r\nIP={client_ip}\r\n".encode()))
        run("mcopy", "-o", "-i", str(image), str(work / "NET.CFG"), "::BSHIP/NET.CFG")
        # The original fixture abandons SAME-call resumes after 20 seconds.
        # Change only its verified immediate (50 Hz ticks) in the private copy.
        # Symbols, instruction addresses, SENDSLICE and all checks stay intact.
        client = work / "BSTAND.EXE"
        run("mcopy", "-o", "-i", str(image), "::BSHIP/BSTAND.EXE", str(client))
        original = client.read_bytes()
        watchdog = b"\x11\xe8\x03\x19\x22" + struct.pack("<H", symbols["nt_end"]) + b"\xfb"
        assert original.count(watchdog) == 1, "BSTAND watchdog signature changed"
        replacement = b"\x11" + struct.pack("<H", 50 * args.client_timeout) + watchdog[3:]
        patched = original.replace(watchdog, replacement)
        if args.blocking:
            slice_option = bytes.fromhex("3e031132000611cd") + struct.pack("<H", symbols["ng_call"])
            assert patched.count(slice_option) == 1, "BSTAND SENDSLICE signature changed"
            patched = patched.replace(slice_option, slice_option[:3] + b"\0\0" + slice_option[5:])
        client.write_bytes(patched)
        (work / "fixture.json").write_text(json.dumps(dict(
            original_sha256=hashlib.sha256(original).hexdigest(),
            patched_sha256=hashlib.sha256(client.read_bytes()).hexdigest(),
            watchdog_offset=original.index(watchdog),
            original_seconds=20, client_seconds=args.client_timeout,
            sendslice=0 if args.blocking else 50), indent=2) + "\n")
        run("mcopy", "-o", "-i", str(image), str(client), "::BSHIP/BSTAND.EXE")
        batch_name = scenario.upper() + ".BAT"
        batch = run("mtype", "-i", str(image), "::BSHIP/" + batch_name,
                    capture_output=True).stdout
        batch_marker = f"-batch -n={scenario[1:]}".encode()
        assert batch.count(batch_marker) == 1
        (work / batch_name).write_bytes(batch.replace(
            batch_marker, batch_marker + f" -port={args.port}".encode()))
        run("mcopy", "-o", "-i", str(image), str(work / batch_name), "::BSHIP/" + batch_name)
        (work / "cfg/sprinter.cfg").write_text(
            '<?xml version="1.0"?><mameconfig version="10"><system name="sprinter">'
            f'<network><device tag=":isa1:3c509b" interface="{interface}" '
            'mac="02:60:8c:12:34:56"/></network></system></mameconfig>\n')
        env = dict(os.environ, BS_SYM=str((args.battleship / "build/bstand.sym").resolve()),
                   BS_ROOT=str(work), BS_BUILD=str(work / "build"), BS_MODE="net",
                   BS_REPORT=str(work / "report.txt"), BS_BAT=scenario, BS_STALL=str(stall),
                   MAME_NET="509b")
        command = [str(mame), "sprinter", "-skip_gameinfo", "-bios", "v3.06",
                   "-rompath", str(args.assets / "roms"),
                   "-hard1", str(args.assets / "IMG/sp_hdd_sys.chd"),
                   "-diff_directory", str(work / "diff"),
                   "-cfg_directory", str(work / "cfg"),
                   "-nvram_directory", str(work / "nvram"),
                   "-beta:wd179x:1", "35hd", "-flop2", str(image),
                   "-isa0", "zxbus_adapter", "-isa0:zxbus_adapter:card", "neogs",
                   "-isa1", "3c509b", "-networkprovider", "pcap",
                   "-video", "none", "-sound", "none",
                   "-snapshot_directory", str(work / "shots"),
                   "-autoboot_script", str(work / "tools/mame_bstand.lua"),
                   "-seconds_to_run", "300"]
        print(f"Battleship {scenario.upper()}: {run_name}, DLL={hashes['UNET509B.DLL']}", flush=True)
        with (work / "capture.log").open("w") as capture_log:
            capture = subprocess.Popen(
                ["/usr/sbin/tcpdump", "-U", "-i", "feth1", "-w", str(work / "test.pcap"),
                 f"(host {client_ip} and (tcp port {args.port} or tcp port {listen_port})) or "
                 f"(arp and (arp[14:4] = {int(ipaddress.IPv4Address(client_ip))} or "
                 f"arp[24:4] = {int(ipaddress.IPv4Address(client_ip))}))"],
                stdout=capture_log, stderr=subprocess.STDOUT)
            try:
                with (work / "mame.log").open("w") as log:
                    run(*command, cwd=args.assets, env=env, stdout=log,
                        stderr=subprocess.STDOUT, timeout=360)
            finally:
                pids = work / "build/mame/host.pids"
                if pids.exists():
                    for pid in pids.read_text().split():
                        try:
                            os.kill(int(pid), signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    pids.unlink()
                capture.send_signal(signal.SIGINT)
                capture.wait(timeout=10)
        assert capture.returncode == 0, (work / "capture.log").read_text()
        report = (work / "report.txt").read_text()
        def metric(name):
            return int(re.search(rf"^\s*{name}\s+\w+\s+(\d+)", report, re.M)[1])
        assert "RESULT: PASS" in report, report
        failures = re.findall(r"^\s*(NT_\w+)\s+FAIL", report, re.M)
        if args.listen_repeats:
            assert not failures, report
            checks = ["NT_ACCEPT1", "NT_SILENT", "NT_ACCEPT2", "NT_UNLISTEN_A"]
            assert all(re.search(rf"^\s*{name}\s+PASS\s+0\b", report, re.M)
                       for name in checks), report
            assert "connected, sending HELLO1" in report, report
            assert "connected, sending HELLO2" in report, report
            result = dict(scenario="n4", run=run_name, listen_port=listen_port,
                          checks={name: metric(name) for name in checks})
            results.append(result)
            (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(result), flush=True)
            continue
        if args.blocking:
            # N3 normally requires AGAIN; only that expectation is inapplicable
            # to this explicit blocking variant. Byte counts/error checks remain.
            assert set(failures) <= {"NT_AGAIN"}, report
            assert metric("NT_AGAINS") == 0, report
            assert metric("NT_SEND_MAX") >= max(0, stall - 4) * 1000, report
        else:
            assert not failures, report
            assert metric("NT_AGAINS") > 0, report
            assert metric("NT_SEND_MAX") <= 100, report
        digest = re.search(r"done, 48800 bytes received, sha256 (acc7ecb1abac0482[0-9a-f]+)",
                           report)
        assert digest, report
        result = dict(stall=stall, blocking=args.blocking,
                      again=metric("NT_AGAINS"),
                      send_max_ms=metric("NT_SEND_MAX"), bytes=48800, sha256=digest[1])
        results.append(result)
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
