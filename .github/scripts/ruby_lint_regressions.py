"""Run Ruby lint and compare legacy Flux offenses with the published source."""
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess
import sys

BASE = '7b3377f6272797df8b1fb1786003bd3cc55beaff'
LEGACY_FILES = ('app/models/channel/sms.rb', 'app/services/sms/providers/flux_service.rb')


def signature(offense, source):
    line = source.splitlines()[offense['location']['start_line'] - 1].strip()
    message = '' if offense['cop_name'].startswith('Metrics/') else re.sub(r'line \d+', 'line N', offense['message'])
    return offense['cop_name'], line, message


def score(offense):
    match = re.search(r'(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)\]', offense['message'])
    return float(match[1]) if match else None


def regressions(current, baseline, current_source, baseline_source):
    available = defaultdict(list)
    for offense in baseline:
        available[signature(offense, baseline_source)].append(offense)
    new, existing = [], []
    for offense in current:
        candidates = available[signature(offense, current_source)]
        current_score = score(offense)
        match = next((old for old in candidates if current_score is None or
                      (score(old) is not None and current_score <= score(old))), None)
        if match is None:
            new.append(offense)
        else:
            candidates.remove(match)
            existing.append(offense)
    return new, existing


def main():
    out = Path(sys.argv[1])
    docker_args = sys.argv[2:]
    subprocess.run(['git', 'merge-base', '--is-ancestor', BASE, 'HEAD'], check=True)
    files = Path('.github/scripts/ruby-lint.txt').read_text().splitlines()

    def lint(paths, stdin=None):
        command = ['docker', 'run', '-i', *docker_args, 'jrc-validation-runtime',
                   'bundle', 'exec', 'rubocop', '--format', 'json', *paths]
        result = subprocess.run(command, input=stdin, capture_output=True)
        if result.returncode not in (0, 1):
            raise RuntimeError('RuboCop execution failed: ' + result.stderr.decode(errors='replace'))
        return json.loads(result.stdout)

    current = lint(files)
    (out / 'rubocop-current.json').write_text(json.dumps(current, indent=2))
    baseline_reports, new, existing = {}, [], []
    for file in current['files']:
        path, offenses = file['path'], file['offenses']
        if not offenses:
            continue
        if path not in LEGACY_FILES:
            new.extend({'path': path, **offense} for offense in offenses)
            continue
        old_source = subprocess.check_output(['git', 'show', f'{BASE}:{path}'])
        baseline = lint(['--stdin', path], old_source)
        baseline_reports[path] = baseline
        old_offenses = next(item['offenses'] for item in baseline['files'] if item['path'] == path)
        added, unchanged = regressions(offenses, old_offenses, Path(path).read_text(), old_source.decode())
        new.extend({'path': path, **offense} for offense in added)
        existing.extend({'path': path, **offense} for offense in unchanged)
    report = {'base': BASE, 'files_inspected': len(current['files']), 'new_offenses': new,
              'preexisting_not_worsened': existing, 'baseline_reports': baseline_reports}
    (out / 'rubocop-baseline-comparison.json').write_text(json.dumps(report, indent=2))
    summary = f"Ruby lint: {len(current['files'])} files; {len(new)} new offenses; {len(existing)} preexisting, not worsened."
    (out / 'rubocop.log').write_text(summary + '\n' + json.dumps(new, indent=2))
    print(summary)
    if new:
        print(json.dumps(new, indent=2))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
