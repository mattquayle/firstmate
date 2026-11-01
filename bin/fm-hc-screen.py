#!/usr/bin/env python3
"""hc protocol adapter: bounded existing-core operations and observe-only paint.

Generation 1 uses channel/kind/length frames (<IBI). This deliberately accepts
only a linear full-screen repaint, not arbitrary terminal output. A concurrent
update, incomplete escape, changed labels, or disagreement with terminal.read
fails closed. The shared composer classifier remains the owner of UI semantics.
Python's standard library is the only dependency. Existing-core operations
validate the permanent core identity on the same socket before dispatch.
"""
import argparse
import json
import os
import re
import pathlib
import socket
import stat
import select
import struct
import subprocess
import sys
import time


class RpcError(ValueError):
    def __init__(self, error):
        super().__init__(error.get("message", "hc request refused"))
        self.kind = error.get("data", {}).get("kind")


class ExistingCore:
    """One existing Unix socket, identity checked before any requested operation.

    FM_HC_SOCKET is the explicit lab pin; otherwise the selected session's
    owned core.lock supplies the actual socket (including nondefault XDG paths).
    Never invokes hc or starts/reconnects a process, even after a lost response.
    """
    def __init__(self, session, expected, framed=False):
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*", session):
            raise ValueError("invalid hc session")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", expected):
            raise ValueError("missing permanent core identity")
        path = os.environ.get("FM_HC_SOCKET")
        if not path:
            state = pathlib.Path(os.environ.get("XDG_STATE_HOME") or pathlib.Path.home() / ".local/state")
            lock = state / "herdr-core" / session / "core.lock"
            info = lock.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("unsafe core lock")
            path = lock.read_text().strip()
        info = os.lstat(path)
        if not os.path.isabs(path) or not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("unsafe core socket")
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(10)
        self.socket.connect(path)
        self.stdin = self.stdout = self.socket.makefile("rwb", buffering=0)
        self.sequence = 0
        try:
            self.hello = self.call("hello", dict(generation=1, framed=framed))
            if self.hello.get("generation") != 1 or self.hello.get("core", {}).get("id") != expected:
                raise ValueError("hc core identity changed; preserving endpoint")
        except Exception:
            self.close()
            raise

    def call(self, method, params):
        self.sequence += 1
        self.socket.sendall((json.dumps(dict(jsonrpc="2.0", id=self.sequence, method=method, params=params)) + "\n").encode())
        line = self.stdout.readline(1048577)
        if not line.endswith(b"\n") or len(line) > 1048576:
            raise ValueError("incomplete or oversized hc reply; completion unknown")
        reply = json.loads(line)
        if reply.get("id") != self.sequence:
            raise ValueError("unexpected hc reply; completion unknown")
        if "error" in reply:
            raise RpcError(reply["error"])
        return reply["result"]

    def close(self):
        self.stdin.close()
        self.socket.close()


def existing_cli(session, expected, args):
    """Only the hc CLI subset used by the adapter; unsupported flags refuse.

    Generation-1 method/parameter contract: hc 0.1.16 api/types.rs.
    No --on, arbitrary RPC, server lifecycle, reconnect or forced send surface.
    """
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", choices=["hello", "server", "ls", "run", "get", "read", "send", "keys", "kill", "rm"])
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--label", action="append", default=[])
    parser.add_argument("--cwd")
    parser.add_argument("--name")
    parser.add_argument("--parent")
    parser.add_argument("--no-parent", action="store_true")
    parser.add_argument("--outlive-parent", action="store_true")
    parser.add_argument("--no-notify", action="store_true")
    parser.add_argument("--bg", action="store_true")
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--lines", type=int, default=200)
    parser.add_argument("--timeout", type=float, default=5)
    # Parse only option-side argv. Payload after -- is opaque, including flags.
    split = args.index("--") if "--" in args else len(args)
    option_args, payload = args[:split], args[split + 1:]
    parser.add_argument("targets", nargs="*")
    a = parser.parse_intermixed_args(option_args)
    labels = {}
    for label in a.label:
        key, value = label.split("=", 1)
        if not key or key in labels:
            raise ValueError("invalid or duplicate label")
        labels[key] = value
    if not 0 < a.timeout <= 60 or a.lines < 0:
        raise ValueError("invalid timeout or line bound")
    params = {}
    command = a.command
    if command == "hello":
        if a.targets or payload:
            raise ValueError("unexpected hello argument")
        method = "hello"
    elif command == "server":
        if a.targets != ["status"] or payload:
            raise ValueError("server lifecycle is forbidden")
        method = "server.status"
    elif command == "ls":
        if a.targets or payload:
            raise ValueError("unexpected inventory argument")
        method, params = "terminal.list", dict(all=a.all, labels=labels)
    elif command == "run":
        if a.targets or payload or not a.bg or not a.cwd or not a.name:
            raise ValueError("only managed background shell creation is supported")
        method = "terminal.run"
        params = dict(cwd=a.cwd, name=a.name, labels=labels, parent=a.parent,
                      no_parent=a.no_parent, outlive_parent=a.outlive_parent,
                      no_notify=a.no_notify, argv=[], wait=False)
    else:
        if len(a.targets) != 1 or not re.fullmatch(r"t[0-9a-z]+", a.targets[0]):
            raise ValueError("one destination-local terminal address is required")
        method, params = "terminal." + command, dict(terminal=a.targets[0])
        if command == "read":
            params["lines"] = a.lines
        elif command == "send":
            if len(payload) != 1:
                raise ValueError("send requires one opaque payload")
            params.update(text=payload[0], wait=a.wait, timeout=a.timeout)
        elif command == "keys":
            if not payload:
                raise ValueError("keys requires a payload")
            params["keys"] = payload
        elif payload:
            raise ValueError("unexpected payload")
    core = ExistingCore(session, expected)
    try:
        core.socket.settimeout(a.timeout + 10)
        result = core.hello if method == "hello" else core.call(method, params)
        print(result["text"] if command == "read" and not a.json else json.dumps(result))
    finally:
        core.close()

def linear_screen(raw):
    text = raw.decode("utf-8")
    # The full repaint resets the terminal, sets tabs, then homes before cells.
    if "\x1b[!p" not in text or "\x1b[2J" not in text:
        raise ValueError("no full repaint")
    text = text.split("\x1b[2J", 1)[1]
    start = text.index("\x1b[H") + 3
    text = text[start:]
    out = []
    restored = False
    while text:
        if text.startswith("\x1b["):
            match = re.match(r"\x1b\[([0-9;?=:]*)([A-Za-z])", text)
            if not match:
                raise ValueError("incomplete or unsupported CSI")
            args, op = match.groups()
            if op == "m" and not restored:
                out.append(match[0])
            elif op == "H" and re.fullmatch(r"[0-9]+;[0-9]+", args):
                restored = True
            elif op in ("h", "l", "u") or (op == "m" and restored):
                pass
            else:
                raise ValueError("nonlinear repaint")
            text = text[len(match[0]):]
        elif text.startswith("\x1b]"):
            match = re.match(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", text)
            if not match:
                raise ValueError("incomplete OSC")
            text = text[len(match[0]):]
        else:
            ch, text = text[0], text[1:]
            if restored or (ord(ch) < 32 and ch not in "\r\n"):
                raise ValueError("output beyond first paint")
            out.append(ch)
    if not restored:
        raise ValueError("incomplete first paint")
    return "".join(out).replace("\r\n", "\n")


def normalized(text):
    return "\n".join(line.rstrip() for line in text.splitlines()).strip("\n")


def observe(binary, session, terminal, home, task):
    env = os.environ.copy()
    for key in ("HC_SCOPE", "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SOCKET"):
        env.pop(key, None)
    env["HC_SESSION"] = session
    if env.get("FM_HC_SOCKET"):
        env["HC_SOCKET"] = env["FM_HC_SOCKET"]
    existing = os.environ.get("FM_HC_EXPECT_CORE")
    proc = ExistingCore(session, existing, framed=True) if existing else subprocess.Popen(
        [binary, "connect", "--session", session], env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 4
    def read(n):
        result = b""
        while len(result) < n:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([proc.stdout], [], [], remaining)[0]:
                raise ValueError("observation timed out")
            chunk = os.read(proc.stdout.fileno(), n - len(result))
            if not chunk:
                raise ValueError("incomplete observation")
            result += chunk
        return result
    def send(channel, kind, payload):
        proc.stdin.write(struct.pack("<IBI", channel, kind, len(payload)) + payload)
        proc.stdin.flush()
    def frame():
        channel, kind, size = struct.unpack("<IBI", read(9))
        if size > 1024 * 1024:
            raise ValueError("oversized observation")
        return channel, kind, read(size)
    def rpc(ident, method, params):
        send(0, 0, json.dumps(dict(jsonrpc="2.0", id=ident, method=method, params=params)).encode())
        channel, kind, data = frame()
        reply = json.loads(data)
        if channel != 0 or kind != 0 or reply.get("id") != ident or "error" in reply:
            raise ValueError("unexpected observation reply")
        return reply["result"]
    def owned(info):
        labels = info.get("labels", {})
        if info.get("address") != terminal or info.get("state") != "live" or labels.get("firstmate.home") != home or labels.get("firstmate.task") != task:
            raise ValueError("foreign observation")
    try:
        if existing:
            hello = proc.hello
        else:
            proc.stdin.write(b'{"jsonrpc":"2.0","id":0,"method":"hello","params":{"generation":1,"framed":true}}\n')
            proc.stdin.flush()
            line = b""
            while not line.endswith(b"\n") and len(line) < 65536:
                line += read(1)
            hello = json.loads(line)["result"]
        if hello.get("generation") != 1 or hello.get("framed") is not True:
            raise ValueError("unsupported observation protocol")
        info = rpc(1, "terminal.get", {"terminal": terminal})
        owned(info)
        attached = rpc(2, "terminal.attach", dict(terminal=terminal, cols=info["cols"], rows=info["rows"], history=0, observe=True))
        owned(attached["terminal"])
        channel = attached["channel"]
        paint = b""
        while True:
            ch, kind, data = frame()
            if ch != channel or kind != 0:
                raise ValueError("observation stream closed")
            paint += data
            if len(paint) > 128 * 1024:
                raise ValueError("oversized repaint")
            if not select.select([proc.stdout], [], [], 0.1)[0]:
                break
        styled = linear_screen(paint)
        # Stop the stream before reading plain text, so there can be no unseen
        # terminal bytes interleaved with the validating RPC reply.
        send(channel, 2, b"")
        ch, kind, _ = frame()
        if ch != channel or kind != 2:
            raise ValueError("terminal changed during observation")
        plain = rpc(3, "terminal.read", {"terminal": terminal, "lines": 0})
        owned(rpc(4, "terminal.get", {"terminal": terminal}))
        unstyled = re.sub(r"\x1b\[[0-9;:]*m", "", styled)
        if not plain.get("complete") or normalized(unstyled) != normalized(plain["text"]):
            raise ValueError("styled and plain screens disagree")
        return styled
    finally:
        if existing:
            proc.close()
        else:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--cli"]:
            existing_cli(sys.argv[2], sys.argv[3], sys.argv[4:])
        else:
            print(observe(*sys.argv[1:]), end="")
    except RpcError as error:
        print(f"hc request refused: {error}", file=sys.stderr)
        sys.exit({"not_found": 3, "blocked": 9, "finished": 11}.get(error.kind, 1))
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"hc protocol operation refused: {error}", file=sys.stderr)
        sys.exit(1)
