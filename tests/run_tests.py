"""Run the actual final source in a deterministic mock using the official Luau CLI."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "AutoPainterFinal.luau").read_text()
loader = (root / "LoaderPublic.luau").read_text()
suite = (root / "tests" / "scheduler.spec.luau").read_text()
suite += "\n" + (root / "tests" / "selection.spec.luau").read_text()
suite += '\nprint(string.format("%d tests passed (mock engine; no live throughput claim)", passed))\n'
with tempfile.NamedTemporaryFile("w", suffix=".luau", dir=root / "tests", delete=False) as f:
    path = Path(f.name)
    f.write("local SOURCE = [====[\n" + source + "\n]====]\n"
            + "local LOADER_SOURCE = [====[\n" + loader + "\n]====]\n" + suite)
try:
    raise SystemExit(subprocess.call([sys.argv[1] if len(sys.argv) > 1 else "luau", str(path)]))
finally:
    path.unlink()
