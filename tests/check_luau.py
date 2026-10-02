"""Compile every repository Luau file, preserving Markdown-wrapped reference sources."""
from pathlib import Path
import re, subprocess, sys, tempfile
root = Path(__file__).resolve().parent.parent
compiler = sys.argv[1] if len(sys.argv) > 1 else 'luau-compile'
paths = sorted(root.rglob('*.luau'))
failures = []
with tempfile.TemporaryDirectory(prefix='autopainter-luau-') as directory:
    for path in paths:
        source = path.read_text()
        target = path
        if source.lstrip().startswith('```'):
            source = re.sub(r'^\s*```(?:lua|luau)?\s*\n', '', source, count=1)
            source = re.sub(r'\n```\s*$', '\n', source)
            target = Path(directory) / path.name
            target.write_text(source)
        result = subprocess.run([compiler, str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if result.returncode:
            failures.append((str(path.relative_to(root)), result.stderr))
print(f'{len(paths)-len(failures)}/{len(paths)} Luau files compiled')
for path, error in failures:
    print(path, error)
raise SystemExit(bool(failures))
