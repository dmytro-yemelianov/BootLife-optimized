#!/usr/bin/env python3
"""Verify a release's checksums and rebuild every supplied final configuration."""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hashes-only', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    checked = 0
    sums = ROOT / 'SHA256SUMS'
    if sums.exists():
        for line in sums.read_text().splitlines():
            expected, name = line.split('  ', 1)
            path = ROOT / name
            assert path.resolve().is_relative_to(ROOT), name
            assert sha(path) == expected, name
            checked += 1
        print(f'PASS {checked} package file checksums', flush=True)
    elif args.hashes_only:
        raise SystemExit('SHA256SUMS is missing')
    report = {'package_checksums_checked': checked, 'variants': {}}
    if not args.hashes_only:
        manifest = json.loads((ROOT / 'final/MANIFEST.json').read_text())
        with tempfile.TemporaryDirectory(prefix='bootlife-rebuild-') as tmp:
            for name, item in manifest['variants'].items():
                source, image = ROOT / item['source'], ROOT / item['image']
                assert sha(source) == item['source_sha256'], name
                assert sha(image) == item['image_sha256'], name
                assert len(image.read_bytes()) == 512 and image.read_bytes()[-2:] == b'\x55\xaa'
                configurations = {}
                for config, expected in item['production_configurations'].items():
                    output = Path(tmp) / f'{name}-{config}.img'
                    subprocess.run(['nasm', '-f', 'bin', *expected['defines'], '-o', str(output), str(source)], check=True)
                    assert len(output.read_bytes()) == 512 and output.read_bytes()[-2:] == b'\x55\xaa'
                    assert sha(output) == expected['sha256'], (name, config)
                    configurations[config] = {'pass': True, 'sha256': sha(output)}
                report['variants'][name] = configurations
                print(f'PASS {name}: supplied image and {len(configurations)} reproducible production configurations', flush=True)
        report['nasm'] = subprocess.check_output(['nasm', '-v'], text=True).strip()
        report['verifier_sha256'] = sha(Path(__file__))
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
