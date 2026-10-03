from pathlib import Path
import hashlib,json,re,subprocess,sys,tempfile
root=Path(__file__).resolve().parent.parent
source=(root/'AutoPainterHandsFree.luau').read_text()
baseline=json.loads((root/'tests/v8_proven_components.json').read_text())
baseline=json.loads((root/'tests/v82_proven_components.json').read_text())
for block in baseline['blocks']:
    checked=source[source.index(block['start']):source.index(block['end'],source.index(block['start']))]
    checked=checked.replace('if mouse.Target~=entry.part or not guiClear(UserInputService:GetMouseLocation()) then', 'if mouse.Target~=entry.part then')
    assert hashlib.sha256(checked.encode()).hexdigest()==block['sha256'], 'Proven v8.1 component changed: '+block['name']
print('Normalized matcher and native cursor mover match v8.1 (post-palette GUI obstruction gate excepted)',flush=True)
click=source[source.index('function palette.click('):source.index('function palette.ensureOpen(')]
click=re.sub(r'^.*palette.currentEntry and not shouldTarget.*\n','',click,flags=re.M)
assert hashlib.sha256(click.encode()).hexdigest()=="15b6443094e923565cb8455c1289b59aab2e56a0684a6ac4376fea79e4268f31", 'Native palette click/settle/hold changed'
print('Native palette click sequence/timings unchanged; clean gate added',flush=True)
for start,end,digest in [
    ('function palette.prepareGenerated(', 'function palette.generatedResult(', '9fd9fb1241685a83144514b38a6c23fc4d6c4d3c7fe91387aa65b0704b09ce01'),
    ('local function acquireFast(', 'local function startOrRetainHold(', 'cc16f47ed51d9e6e82d50c12bfdf63de41b79b0a4d4cd26b9e41db78125b3ef1')]:
    block=source[source.index(start):source.index(end,source.index(start))]
    assert hashlib.sha256(block.encode()).hexdigest()==digest, 'Live-proven component changed: '+start
print('Generated native transport and acquireFast remain byte-identical to native-RGB main',flush=True)

for forbidden in [r'[:.]\s*(InvokeServer|FireServer)\s*\(', r'\b(?:hookfunction|hookmetamethod|firesignal|getconnections|require|decompile)\s*\(',r'\bmouse\.Target\s*=(?!=)',r'\.OnClientInvoke\s*=']:
    assert not re.search(forbidden,source),forbidden
assert not re.search(r'\.Color\s*(?:==|~=)',source), 'Raw part Color equality'
# The only new working-color write is inside the source-traced Civil equip transaction.
assert source.count('SetAttribute("PaintBucketColor"')==1
write=source.index('SetAttribute("PaintBucketColor"')
assert source.index('function palette.prepareGenerated(')<write<source.index('function palette.generatedResult(')

# This revision permits only the reviewed cadence/identity/report changes.
# Reverse that exact allowlist and compare the ENTIRE controller to main 9900a73.
# Civil, input, target/dwell/scheduler and benchmark algorithms cannot drift silently.
prior=source
master=json.loads((root/'tests/master_scope.json').read_text())
lines=prior.splitlines(True)
for change in reversed(master['allowedChanges']):
    assert ''.join(lines[change['start']:change['end']])==change['after'], 'Master scope changed after review'
    lines[change['start']:change['end']]=change['before'].splitlines(True)
prior=''.join(lines)
assert hashlib.sha256(prior.encode()).hexdigest()==master['baseSourceSHA256'], 'Unreviewed master changes'
print('Master edits reverse exactly to native-RGB baseline; historical freezes retained',flush=True)
native_scope=json.loads((root/'tests/native_rgb_scope.json').read_text())
for change in reversed(native_scope['allowedChanges']):
    assert prior.count(change['after'])==change['count'], 'Native RGB scope count changed'
    prior=prior.replace(change['after'],change['before'])
assert hashlib.sha256(prior.encode()).hexdigest()==native_scope['baseSourceSHA256'], 'Unreviewed change outside native RGB route'
print('Native RGB changes isolated by exact reverse patch; prior NORMAL/Civil swatches/benchmark preserved',flush=True)
scope=json.loads((root/'tests/public150_scope.json').read_text())
for change in reversed(scope['allowedChanges']):
    assert prior.count(change['after'])==change['count'], 'Scope allowlist count changed'
    prior=prior.replace(change['after'],change['before'])
assert hashlib.sha256(prior.encode()).hexdigest()==scope['baseSourceSHA256'], 'Unreviewed production/benchmark change beyond public150 scope'
print('Civil, native input/targeting/dwell/scheduler and benchmark match main 9900a73 after exact cadence/report allowlist',flush=True)
# Historical benchmark-only scope freeze: all production source, including pacing, Civil,
# generated-color diagnostics, camera/targeting and scheduler is byte-identical.
frozen=prior
start=frozen.index('-- Isolated resumable diagnostic.')
end=frozen.index('-- Explicit, bounded native-UI investigation.',start)
frozen=frozen[:start]+frozen[end:]
frozen=re.sub(r' if benchmark.active and not benchmark.finishing then\n.*?\n end\n', '',frozen,flags=re.S,count=1)
frozen=re.sub(r'^ benchmark.resumeButton.Visible=.*\n','',frozen,flags=re.M)
frozen=re.sub(r'^ PausePaintCooldownBenchmark=.*\n','',frozen,flags=re.M)
freeze=json.loads((root/'tests/benchmark_production_freeze.json').read_text())
assert hashlib.sha256(frozen.encode()).hexdigest()==freeze['sha256'], 'Benchmark-only scope: production source changed'
print('Entire production source matches e67a01b; benchmark-only implementation/bridges excepted',flush=True)
for suite in ['handsfree_activation.spec.luau', 'v82_regression.spec.luau', 'v82_livefix.spec.luau', 'combat.spec.luau', 'cooldown_benchmark.spec.luau', 'followup.spec.luau', 'public150.spec.luau', 'native_rgb.spec.luau', 'master_revision.spec.luau']:
    with tempfile.NamedTemporaryFile('w',suffix='.luau',dir=root/'tests',delete=False) as f:
        path=Path(f.name)
        f.write('local SOURCE = [======[\n'+source+'\n]======]\n'+(root/'tests'/suite).read_text())
    try:
        subprocess.run([sys.argv[1] if len(sys.argv)>1 else 'luau',str(path)],check=True)
    finally:
        path.unlink()
