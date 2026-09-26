from pathlib import Path
import subprocess, sys, tempfile, re
root=Path(__file__).resolve().parent.parent
source=(root/"AutoPainterFinal.luau").read_text()
# Structural regression: active runtime contains no direct remote transport or input hooks.
for forbidden in [".OnClientInvoke =", "hookmetamethod(", "hookfunction(", "firesignal(", "fireclickdetector(", "getconnections("]:
    assert forbidden not in source, forbidden
assert not re.search(r"\b[Mm]ouse\.Target\s*=(?!=)", source)
assert not re.search(r"[:.]\s*(InvokeServer|FireServer)\s*\(", source)
assert not re.search(r"\brequire\s*\(", source)
assert not re.search(r'player\s*:\s*SetAttribute\s*\(', source)
with tempfile.NamedTemporaryFile("w",suffix=".luau",dir=root/"tests",delete=False) as f:
    path=Path(f.name)
    f.write("local SOURCE = [======[\n"+source+"\n]======]\n"+"local LOADER_SOURCE = [======[\n"+(root/"LoaderPublic.luau").read_text()+"\n]======]\n"+(root/"tests/native.spec.luau").read_text()+"\n"+(root/"tests/native_extra.spec.luau").read_text()+"\n"+(root/"tests/native_fast.spec.luau").read_text()+"\n"+(root/"tests/native_reliability.spec.luau").read_text()+'\nprint(string.format("%d native tests passed (mock engine; not live input/server verification)",passed))\n')
try:
    raise SystemExit(subprocess.call([sys.argv[1] if len(sys.argv)>1 else "luau",str(path)]))
finally:
    path.unlink()
