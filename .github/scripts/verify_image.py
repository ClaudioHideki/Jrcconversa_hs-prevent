import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ref, source_file = sys.argv[1:3]
source = json.loads(Path(source_file).read_text())
image = json.loads(subprocess.check_output(['docker', 'image', 'inspect', ref]))[0]
assert image['Os'] == 'linux' and image['Architecture'] == 'amd64'
assert image['Config']['Labels']['org.opencontainers.image.revision'] == source['source_revision']
assert image['Config']['Labels']['org.opencontainers.image.source'] == 'https://github.com/ClaudioHideki/Jrcconversa_hs-prevent'
stamp = subprocess.check_output(['docker', 'run', '--rm', '--read-only', '--network', 'none', '--entrypoint', 'cat', ref, '/app/.git_sha']).decode().strip()
assert stamp == source['source_revision']
raw = subprocess.check_output(['docker', 'run', '--rm', '--read-only', '--network', 'none', '--entrypoint', 'sh', ref,
                               '-c', 'find /app -type f -exec sha256sum {} +']).decode()
hashes = {}
for line in raw.splitlines():
    match = re.match(r'^([0-9a-f]{64})\s+/app/(.+)$', line)
    if match:
        hashes[match[2]] = match[1]

def excluded(path):
    return re.match(r'^(spec/|tests/|\.bundle/|output/|\.env(?:\.|$)|docker-compose\.|docker/Dockerfile$|docker/dockerfiles/|log/|storage/|public/system/|tmp/|\.codeclimate\.yml$|public/packs/|node_modules/|vendor/bundle/|\.gitignore$)', path)

expected = {entry['path'] for entry in source['files']}
checked = 0
for entry in source['files']:
    path = entry['path']
    if excluded(path) or entry['mode'] == '120000':
        continue
    assert hashes.get(path) == entry['sha256'], f'Image source mismatch: {path}'
    checked += 1
unexpected = [name for name in hashes if name.startswith(('app/', 'config/', 'enterprise/', 'lib/', 'db/', 'bin/', 'branding/')) and name not in expected]
assert not unexpected, unexpected
assert hashes['public/packs/js/sdk.js'] == source['sdk_sha256'], 'SDK differs from independent build of the checked out source'
result = {'image': ref, 'image_id': image['Id'], 'source_revision': stamp, 'git_tree': source['git_tree'],
          'checked_source_files': checked, 'sdk_sha256': source['sdk_sha256'], 'platform': 'linux/amd64',
          'vite_files': sum(name.startswith('public/vite/') for name in hashes), 'unexpected_sources': unexpected}
Path(source_file).with_name('image-verification.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
