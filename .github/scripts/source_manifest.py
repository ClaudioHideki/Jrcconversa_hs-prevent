import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
sha = subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip()
assert sha == sys.argv[1]
entries = []
for item in subprocess.check_output(['git', 'ls-files', '-s', '-z']).split(b'\0'):
    if not item:
        continue
    metadata, name = item.split(b'\t', 1)
    path = name.decode()
    mode = metadata.decode().split()[0]
    data = subprocess.check_output(['git', 'show', f'{sha}:{path}'])
    entries.append({'path': path, 'mode': mode, 'sha256': hashlib.sha256(data).hexdigest()})
result = {'source_revision': sha,
          'git_tree': subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}']).decode().strip(),
          'sdk_sha256': hashlib.sha256((root / 'public/packs/js/sdk.js').read_bytes()).hexdigest(),
          'files': entries}
target = root / 'tmp/ci-evidence/source.json'
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(result, indent=2))
print(json.dumps({'source_revision': sha, 'files': len(entries), 'sdk_sha256': result['sdk_sha256']}))
