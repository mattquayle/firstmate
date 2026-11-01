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
echo FM_TEST_COMPLETE
