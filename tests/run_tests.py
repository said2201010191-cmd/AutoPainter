"""Run both current production entry points; retired direct-RPC tests are not active-runtime tests."""
from pathlib import Path
import subprocess, sys
tests=Path(__file__).resolve().parent
binary=sys.argv[1] if len(sys.argv)>1 else "luau"
for runner in ["run_native_tests.py", "run_diagnostic_tests.py"]:
    subprocess.run([sys.executable,str(tests/runner),binary],check=True)
