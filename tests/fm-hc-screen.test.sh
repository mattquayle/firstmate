#!/usr/bin/env bash
# Read-only framed observation, complete repaint, and composer refusal guards.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-hc-screen)
cat > "$TMP_ROOT/hc" <<'PY'
#!/usr/bin/env python3
import json, os, struct, sys
src, dst = sys.stdin.buffer, sys.stdout.buffer
mode = os.environ.get('CASE', 'idle')
def emit(ch, kind, data):
    dst.write(struct.pack('<IBI', ch, kind, len(data)) + data)
    dst.flush()
def reply(i, result):
    emit(0, 0, json.dumps(dict(id=i, result=result)).encode())
def read(n):
    out=b''
    while len(out)<n:
        part=src.read(n-len(out))
        if not part: raise EOFError()
        out+=part
    return out
hello=json.loads(src.readline())
assert hello['params']==dict(generation=1,framed=True)
dst.write(b'{"result":{"generation":1,"framed":true}}\n'); dst.flush()
terminal=dict(address='t1',state='live',labels={'firstmate.home':'test','firstmate.task':'fm-mate'},cols=80,rows=24)
text='› Ask Codex to do anything\n\n  GPT-6.1-Sol low · /work\n  ? for shortcuts'
styled='› \x1b[2mAsk Codex to do anything\x1b[0m\r\n\r\n  GPT-6.1-Sol low · /work\r\n  ? for shortcuts'
if mode=='pending':
    styled=styled.replace('\x1b[2m','\x1b[1m')
if mode=='foreign':
    terminal['labels']['firstmate.home']='other'
try:
    while True:
        ch,kind,n=struct.unpack('<IBI',read(9)); data=read(n)
        if ch:
            assert ch==7 and kind==2 and data==b'', 'observer must send no input, resize, focus or display facts'
            emit(7,2,b'{}'); continue
        assert kind==0
        request=json.loads(data); method=request['method']; params=request['params']; ident=request['id']
        assert params.get('terminal')=='t1', 'exact endpoint required'
        if method=='terminal.get': reply(ident,terminal)
        elif method=='terminal.attach':
            assert params==dict(terminal='t1',cols=80,rows=24,history=0,observe=True)
            reply(ident,dict(channel=7,terminal=terminal))
            paint='\x18\x1b[!p\x1b[H\x1b[2J\x1b[3g\x1b[H'+styled+'\x1b[23;3H\x1b[0m'
            if mode=='update': paint+='\x1b[22;1Hnew turn'
            if mode=='truncated': paint=paint[:-2]
            emit(7,0,paint.encode())
        elif method=='terminal.read':
            reply(ident,dict(text=text if mode!='mismatch' else text+'changed',complete=True))
        else: raise AssertionError(method)
except EOFError:
    pass
PY
chmod +x "$TMP_ROOT/hc"
. "$ROOT/bin/fm-composer-lib.sh"
export FM_COMPOSER_HARNESS=codex
caps=$(printf 'styled=1\ncursor=0\nidentity=0\n')
capture=$(python3 "$ROOT/bin/fm-hc-screen.py" "$TMP_ROOT/hc" lab t1 test fm-mate)
assert_equals "$(fm_composer_classify_screen "$caps" "$capture")" empty 'styled placeholder is empty'
capture=$(CASE=pending python3 "$ROOT/bin/fm-hc-screen.py" "$TMP_ROOT/hc" lab t1 test fm-mate)
assert_equals "$(fm_composer_classify_screen "$caps" "$capture")" pending 'identical bright typed text stays pending'
for variant in foreign update truncated mismatch; do
  if CASE=$variant python3 "$ROOT/bin/fm-hc-screen.py" "$TMP_ROOT/hc" lab t1 test fm-mate > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
    fail "observer accepted $variant"
  fi
  [ ! -s "$TMP_ROOT/out" ] || fail 'refusal leaked a partial styled capture'
done
pass 'hc observer is read-only and refuses foreign, changing, truncated, or disagreeing screens'
pass 'styled ghost text can prove empty while identical typed text stays pending'
# A real Unix socket boundary pins the generation-1 wire contract independently
# of CLI invocation. No installed hc process is used or reachable by this test.
python3 - "$ROOT/bin/fm-hc-screen.py" "$TMP_ROOT" <<'PYTEST'
import json, os, pathlib, socket, subprocess, sys, threading
helper, root = sys.argv[1], pathlib.Path(sys.argv[2])
path = root / "core.sock"
state = root / "state/herdr-core/lab"
state.mkdir(parents=True)
(state / "core.lock").write_text(str(path))
env = dict(os.environ, XDG_STATE_HOME=str(root / "state"))
for key in ("FM_HC_SOCKET", "FM_HC_EXPECT_CORE"):
    env.pop(key, None)

def call(args, core="coreA", result=None, disconnect=False, error=None):
    if path.exists(): path.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path)); server.listen(1); server.settimeout(5)
    seen, failures = [], []
    def serve():
        try:
            conn, _ = server.accept()
            with conn, conn.makefile("rwb", buffering=0) as stream:
                hello = json.loads(stream.readline())
                assert hello["method"] == "hello" and hello["params"] == dict(generation=1, framed=False)
                stream.write((json.dumps(dict(id=hello["id"], result=dict(generation=1, core=dict(id=core)))) + "\n").encode())
                line = stream.readline()
                if line:
                    request = json.loads(line); seen.append(request)
                    if not disconnect:
                        reply = dict(id=request["id"])
                        reply["error" if error else "result"] = error or result or {}
                        stream.write((json.dumps(reply) + "\n").encode())
        except Exception as exc: failures.append(exc)
        finally: server.close()
    thread = threading.Thread(target=serve); thread.start()
    proc = subprocess.run([sys.executable, helper, "--cli", "lab", "coreA", *args], env=env, capture_output=True, timeout=10)
    thread.join(6)
    assert not thread.is_alive() and not failures, failures
    path.unlink()
    return proc, seen

for args, method, fields in [
    (["server", "status", "--json"], "server.status", {}),
    (["ls", "--json", "--label", "firstmate.home=owned"], "terminal.list", dict(labels={"firstmate.home":"owned"}, all=False)),
    (["run", "--bg", "--json", "--cwd", "/scratch", "--name", "mate", "--no-parent", "--outlive-parent", "--no-notify"], "terminal.run", dict(argv=[], wait=False, no_parent=True, outlive_parent=True)),
    (["get", "--json", "t1"], "terminal.get", dict(terminal="t1")),
    (["read", "--json", "--lines", "0", "t1"], "terminal.read", dict(terminal="t1", lines=0)),
    (["send", "--json", "t1", "--wait", "--timeout", "2", "--", "--opaque\nline"], "terminal.send", dict(terminal="t1", text="--opaque\nline", wait=True, timeout=2)),
    (["keys", "--json", "t1", "--", "ctrl+c"], "terminal.keys", dict(terminal="t1", keys=["ctrl+c"])),
    (["kill", "--json", "t1"], "terminal.kill", dict(terminal="t1")),
    (["rm", "--json", "t1"], "terminal.rm", dict(terminal="t1")),
]:
    proc, seen = call(args)
    assert proc.returncode == 0, proc.stderr
    assert len(seen) == 1 and seen[0]["method"] == method, seen
    assert fields.items() <= seen[0]["params"].items(), seen
proc, seen = call(["send", "t1", "--", "never sent"], core="otherCore")
assert proc.returncode != 0 and not seen
proc, seen = call(["send", "t1", "--", "one send"], disconnect=True)
assert proc.returncode != 0 and len(seen) == 1 and b"unknown" in proc.stderr
proc, seen = call(["get", "t1"], error=dict(code=-32000, message="gone", data=dict(kind="not_found")))
assert proc.returncode == 3 and len(seen) == 1
# Replacement between a successful observation and mutation is a different
# connection to the same path; its new core must receive no operation.
assert call(["get", "t1"])[0].returncode == 0
proc, seen = call(["kill", "t1"], core="replacement")
assert proc.returncode != 0 and not seen
for args in (["get", "t1"], ["server", "stop"], ["run", "--bg", "--cwd", "/scratch", "--name", "x", "--", "arbitrary"], ["get", "alias/t1"]):
    proc = subprocess.run([sys.executable, helper, "--cli", "lab", "coreA", *args], env=env, capture_output=True, timeout=5)
    assert proc.returncode != 0 and not path.exists()
print("ok - existing-socket RPC pins identity per connection, refuses remote addresses/lifecycle, and never retries unknown completion")
PYTEST
echo FM_TEST_COMPLETE
