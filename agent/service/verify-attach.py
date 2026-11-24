#!/usr/bin/env python3
"""Proves, on a real device, that the daemon can attach and read memory.

Everything else in this workbench rests on one question - does `task_for_pid`
succeed for the daemon on this jailbreak - and nothing in CI can answer it: the
runner has no device and no RootHide. This script is the answer, in one call per
fact, so a failure names the step that failed instead of "it does not work".

Run it on the device, after `install.sh`:

    python3 verify-attach.py            # the first app in the allowlist
    python3 verify-attach.py <bundleId> # a specific one

It speaks the same JSON envelope the app sends, over the same Mach service, so
what it proves is what the app will get.
"""
from __future__ import annotations

import json
import sys

# The daemon's service name is the contract; nothing here is configurable,
# because a script that can be pointed at another service proves nothing about
# this one.
SERVICE = "io.github.ccch1mneyyy.dshgo.agentd"


def load_xpc() -> object:
    """The Mach connection, from the app's own mechanism.

    `NSXPCConnection` is not exposed to Python at all, so this goes through
    PyObjC when it is installed - the same Foundation class the app uses - and
    explains itself when it is not.
    """
    try:
        from Foundation import NSClassFromString  # type: ignore[import-not-found]
        from Foundation import NSData, NSXPCConnection, NSXPCInterface  # type: ignore[import-not-found]
    except ImportError as error:  # pragma: no cover - host dependent
        raise SystemExit(
            "PyObjC is required to speak XPC from Python:\n"
            "    pip3 install pyobjc-framework-Cocoa\n"
            f"({error})"
        ) from error
    return NSXPCConnection, NSXPCInterface, NSData, NSClassFromString


def main(argv: list[str]) -> int:
    if len(sys.argv) > 1 and argv[1] in {"-h", "--help"}:
        print(__doc__)
        return 0

    NSXPCConnection, NSXPCInterface, NSData, _ = load_xpc()

    connection = NSXPCConnection.alloc().initWithMachServiceName_options_(SERVICE, 0)
    if connection is None:
        print(f"✗ cannot create a connection to {SERVICE}")
        print("  the launchd job is not loaded: launchctl print system/" + SERVICE)
        return 1

    # A permissive interface: the daemon exposes one selector with Data in and
    # Data out, so the proxy only has to be shaped like it, not generated.
    interface = NSXPCInterface.interfaceWithProtocol_(None)
    connection.setRemoteObjectInterface_(interface)
    connection.resume()

    reply_box: dict[str, object] = {}

    def send(method: str, params: dict[str, object]) -> dict[str, object]:
        request = {"id": "verify", "method": method, "params": params, "confirmed": False}
        payload = NSData.dataWithData_(
            json.dumps(request).encode("utf-8")
        )
        service = connection.remoteObjectProxyWithErrorHandler_(
            lambda error: reply_box.setdefault("error", str(error))
        )
        if service is None:
            return {"ok": False, "error": {"message": "no proxy (is the daemon installed?)"}}
        done = {"value": False}

        def handler(data: object) -> None:
            done["value"] = True
            reply_box["reply"] = json.loads(bytes(data))

        service.call_reply_(payload, handler)
        # The reply arrives on the connection's own queue; wait for it plainly,
        # because a verification script that gives up early proves nothing.
        import time

        for _ in range(300):
            if done["value"]:
                break
            time.sleep(0.1)
        return reply_box.get("reply", {"ok": False, "error": {"message": "no reply"}})  # type: ignore[return-value]

    ping = send("probe.ping", {})
    if not ping.get("ok"):
        print("✗ the daemon did not answer probe.ping:", ping.get("error"))
        return 1
    result = ping["result"]
    print(f"✓ daemon pid {result['pid']}, version {result['version']}")
    print(f"  jailbreak root: {result.get('root') or '(rootful)'}")
    allowlist = result.get("allowlist") or []
    if not allowlist:
        print("✗ the allowlist is empty; add a bundle id to allowlist.json and restart the daemon")
        return 1
    print(f"  allowed: {', '.join(allowlist)}")

    wanted = argv[1] if len(argv) > 1 else allowlist[0]
    listing = send("probe.listProcesses", {})
    if not listing.get("ok"):
        print("✗ probe.listProcesses failed:", listing.get("error"))
        return 1
    match = [
        entry
        for entry in listing["result"]["processes"]
        if entry.get("bundleId") == wanted
    ]
    if not match:
        print(f"✗ {wanted} is not running; start it and try again")
        return 1
    pid = match[0]["pid"]
    print(f"✓ {wanted} is pid {pid}")

    info = send("proc.info", {"pid": pid})
    if not info.get("ok"):
        print("✗ proc.info failed:", info.get("error"))
        return 1
    detail = info["result"]
    print(f"  arch: {detail.get('arch')} ({', '.join(detail.get('archs') or [])})")
    if detail.get("entitlements") is not None:
        print(f"  entitlements: {', '.join(detail['entitlements']) or '(none)'}")
    for key in ("platformBinary", "hardened", "restricted", "debuggable"):
        if key in detail:
            print(f"  {key}: {detail[key]}")

    if detail.get("attachable") is not True:
        print("✗ task_for_pid failed:", detail.get("attachError") or "no reason given")
        print("  this is the gate: without it nothing below works.")
        print("  check, in order:")
        print("    1. the daemon's own signature carries the entitlements:")
        print("       python3 check-entitlements.py $(command -v dsh-go-agentd)")
        print("    2. the binary is in the trust cache: jbctl trustcache list")
        print("    3. the target is not hardened: hardened above should be false")
        return 1
    print("✓ task_for_pid succeeded (the port was handed straight back)")

    # A read that is certain to succeed: the Mach-O header of the target itself is
    # at the start of its first mapping, and every arm64 image begins with one of
    # two magics. Reading a guessed heap address would prove less.
    probe = send("probe.readMemory", {"pid": pid, "address": "100000000", "length": 4})
    if probe.get("ok"):
        print(f"✓ vm_read_overwrite: {probe['result']['hex']}")
    else:
        print("· the first page was not mapped (normal for a PIE app); trying the executable's base")
        base = detail.get("path")
        print(f"  base of {base} is what `probe.modules` would name; scan for the header instead:")
        magic = send("mem.scan", {"pid": pid, "pattern": "cffaedfe", "limit": 1})
        if magic.get("ok") and magic["result"]["count"]:
            print(f"✓ mem.scan found the Mach-O header at {magic['result']['matches'][0]}")
        else:
            print("✗ mem.scan found no Mach-O header; the read path is not working")
            return 1

    print()
    print("attach and read both work. The rest of the workbench can be built on this.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))