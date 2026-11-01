#!/usr/bin/env python3
"""Read hc's observe-only first paint; never send terminal data or resize.

Generation 1 uses channel/kind/length frames (<IBI). This deliberately accepts
only a linear full-screen repaint, not arbitrary terminal output. A concurrent
update, incomplete escape, changed labels, or disagreement with terminal.read
fails closed. The shared composer classifier remains the owner of UI semantics.
Python's standard library is the only dependency; plain captures need none.
"""
import json
import os
import re
import select
import struct
import subprocess
import sys
import time


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
    proc = subprocess.Popen([binary, "connect", "--session", session], env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
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
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    try:
        print(observe(*sys.argv[1:]), end="")
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"hc styled observation refused: {error}", file=sys.stderr)
        sys.exit(1)
