import os
from pathlib import Path
import subprocess
import tempfile

script = Path('.github/scripts/publish_once.sh').resolve()
ref = 'ghcr.io/example/project:sha-exclusive'
digest = 'sha256:' + 'a' * 64
for case in ('existing', 'missing', 'unauthorized', 'network', 'auth_not_found', 'unexpected_not_found'):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        docker = root / 'docker'
        docker.write_text('''#!/usr/bin/env bash
set -eu
if [ "$1" = push ]; then echo push >> "$CALLS"; exit 0; fi
if [[ " $* " == *" --format "* ]]; then printf '%s\\n' "$DIGEST"; exit 0; fi
case "$CASE" in
existing) exit 0;;
missing) echo "ERROR: $IMAGE_REF: not found" >&2;;
unauthorized) echo 'ERROR: unauthorized' >&2;;
network) echo 'ERROR: connection timed out' >&2;;
auth_not_found) echo 'ERROR: unauthorized: not found' >&2;;
unexpected_not_found) echo 'ERROR: ghcr.io/another/image:tag: not found' >&2;;
esac
exit 1
''')
        docker.chmod(0o755)
        env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], CASE=case,
                   IMAGE_REF=ref, DIGEST=digest, CALLS=str(root / 'calls'), GITHUB_OUTPUT=str(root / 'output'))
        result = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)
        pushed = (root / 'calls').read_text().splitlines() if (root / 'calls').exists() else []
        if case == 'missing':
            assert result.returncode == 0 and pushed == ['push'], (case, result.stderr)
            assert (root / 'output').read_text().strip() == 'digest=' + digest
        else:
            assert result.returncode != 0 and not pushed, (case, result.stderr)
        print('PASS:', case)
print('PASS: six guard scenarios; no real registry operations')
