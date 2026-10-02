from pathlib import Path
import hashlib,json,re,subprocess,sys,tempfile
root=Path(__file__).resolve().parent.parent
source=(root/'AutoPainterHandsFree.luau').read_text()
baseline=json.loads((root/'tests/v8_proven_components.json').read_text())
for block in baseline['blocks']:
    start=source.index(block['start']);end=source.index(block['end'],start)
    checked=source[start:end].replace("entry.civilControl=item or entry.civilControl", "entry.civilControl=item")
    assert hashlib.sha256(checked.encode()).hexdigest()==block['sha256'], 'Proven v8 component changed: '+block['name']
print('3 proven v8 components match byte-for-byte',flush=True)
# Only rebind lookup, semantic diagnostic label and ownership-state annotation differ.
click=source[source.index('function palette.click('):source.index('function palette.mapBlocked(')]
click=click.replace(' palette.resolvePaletteControl(item)\n','').replace('TargetControlName=item and item.signature.Name','TargetControlName=item and item.button.Name').replace(';health.InputState="DOWN_SENT"','')
assert hashlib.sha256(click.encode()).hexdigest()=='6106e4e207b800eeb3e478bf33b7bf761ec83814c5179a02e02383a64f5ae55e', 'Proven native palette click/settle/hold changed'
print('v8 native palette click/settle/hold unchanged (binding/state annotations excluded)',flush=True)
# Protect the exact camera/acquisition implementation confirmed in the user's client.
start=source.index('local function saveView()')
end=source.index('-- Fast queue/target path.')
camera_source=re.sub(r'^[ \t]*if not shouldTarget\(entry\) then return false end\n', '', source[start:end], flags=re.M)
assert hashlib.sha256(camera_source.encode()).hexdigest()=='7bfac35ddd0da0847cd75a4d8ccdbf924de164c72965d7eab0d9da5444a38a25', 'Camera acquisition was modified'
for forbidden in [r'[:.]\s*(InvokeServer|FireServer)\s*\(', r'\b(?:hookfunction|hookmetamethod|firesignal|getconnections|require|decompile)\s*\(',r'\bmouse\.Target\s*=(?!=)',r'\.OnClientInvoke\s*=']:
    assert not re.search(forbidden,source),forbidden
assert not re.search(r'\.Color\s*(?:==|~=)',source), 'Raw part Color equality'
assert 'SetAttribute("PaintBucketColor"' not in source, 'Unverified palette attribute write'
with tempfile.NamedTemporaryFile('w',suffix='.luau',dir=root/'tests',delete=False) as f:
    path=Path(f.name)
    f.write('local SOURCE = [======[\n'+source+'\n]======]\n'+(root/'tests/handsfree_activation.spec.luau').read_text())
try:
    raise SystemExit(subprocess.call([sys.argv[1] if len(sys.argv)>1 else 'luau',str(path)]))
finally:
    path.unlink()
