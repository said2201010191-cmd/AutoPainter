from pathlib import Path
import hashlib,re,subprocess,sys,tempfile
root=Path(__file__).resolve().parent.parent
source=(root/'AutoPainterHandsFree.luau').read_text()
# Protect the exact camera/acquisition implementation confirmed in the user's client.
start=source.index('local function saveView()')
end=source.index('-- Fast queue/target path.')
assert hashlib.sha256(source[start:end].encode()).hexdigest()=='7bfac35ddd0da0847cd75a4d8ccdbf924de164c72965d7eab0d9da5444a38a25', 'Camera acquisition was modified'
for forbidden in [r'[:.]\s*(InvokeServer|FireServer)\s*\(', r'\b(?:hookfunction|hookmetamethod|firesignal|getconnections|require|decompile)\s*\(',r'\bmouse\.Target\s*=(?!=)',r'\.OnClientInvoke\s*=']:
    assert not re.search(forbidden,source),forbidden
with tempfile.NamedTemporaryFile('w',suffix='.luau',dir=root/'tests',delete=False) as f:
    path=Path(f.name)
    f.write('local SOURCE = [======[\n'+source+'\n]======]\n'+(root/'tests/handsfree_activation.spec.luau').read_text())
try:
    raise SystemExit(subprocess.call([sys.argv[1] if len(sys.argv)>1 else 'luau',str(path)]))
finally:
    path.unlink()
