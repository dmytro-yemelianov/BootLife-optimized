#!/usr/bin/env python3
"""Build, test from a clean copy, and package the article and final BootLife variants."""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from experiment import ROOT, SOURCES, COMMIT, build, digest, work_ram_bytes

NAME = 'bootlife-optimizations-2026-09-25'
FINAL = ('sliding', 'rolling_sliding', 'rolling_lut', 'sliding_lut', 'sliding_lut_word', 'rolling_bits')
ROLES = ('Smallest finite-grid payload', 'Preferred low-RAM version', 'Low-RAM color table',
         'Fast table with smaller payload', 'Fastest observed kernel', 'Embedded bit-table demonstration')


def main():
    artifacts = build()
    timing = json.loads((ROOT / 'results/pentium.external-stop.json').read_text())
    target = ROOT / 'final'
    target.mkdir(exist_ok=True)
    manifest = {'upstream_commit': COMMIT, 'image_bytes': 512, 'timer_pacing': True,
                'default_sparks': 6, 'default_gliders': True, 'default_seed': 'RDTSC',
                'benchmark_report': '../results/pentium.external-stop.json', 'variants': {}}
    rows = []
    for name, role in zip(FINAL, ROLES):
        current, measured = artifacts[name], timing['builds'][name]
        assert current['sha256'] == measured['sha256'], name
        assert current['source_sha256'] == measured['source_sha256'], name
        shutil.copy2(SOURCES[name], target / SOURCES[name].name)
        shutil.copy2(current['image'], target / f'{name}.img')
        configs = {}
        for suffix in ('', '_seeded', '_no_injections', '_gliders_only'):
            artifact = artifacts[name + suffix]
            configs[suffix.removeprefix('_') or 'default'] = {
                'defines': artifact['flags'][2:], 'sha256': artifact['sha256']}
        manifest['variants'][name] = {
            'role': role, 'source': f'final/{SOURCES[name].name}', 'image': f'final/{name}.img',
            'source_sha256': current['source_sha256'], 'image_sha256': current['sha256'],
            'payload_bytes': current['payload_bytes'], 'work_ram_bytes': work_ram_bytes(name),
            'production_configurations': configs}
        v = timing['benchmark']['results'][name]
        rows.append(f"| {role} | [{name}]({SOURCES[name].name}) | [{name}.img]({name}.img) | {current['payload_bytes']} | {work_ram_bytes(name):,} | {v['median_seconds_per_generation']:.6f} |")
    (target / 'MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (target / 'README.md').write_text('''# Final BootLife versions

All supplied `.img` files are complete 512-byte BIOS boot sectors. Each `.asm`
file is standalone NASM source, with the original ISC notice. Every final binary
matches the image hash in the corrected benchmark report. These are finite
dead-border variants; their edge behavior intentionally differs from upstream.

| Priority | Standalone source | Ready image | Payload, B | Work RAM, B | Kernel seconds/generation |
|---|---|---|---:|---:|---:|
''' + '\n'.join(rows) + '''

Times are corrected QEMU/Apple M5 host measurements, not physical Pentium times.
The regular images keep the BIOS timer wait (approximately 18.2 FPS in the
measured demos). `rolling_bits` is included as the demonstrated bit-table
alternative; `rolling_sliding` is the preferred low-RAM choice in this run.

From the extracted package root:

```sh
qemu-system-i386 -cpu pentium -drive file=final/rolling_sliding.img,format=raw,if=floppy
nasm -f bin -o life.img final/life.sliding_lut_word.asm
python3.13 verify_release.py
```

Verification needs Python 3.10+ and NASM; running the images or machine-code
suite also needs QEMU. Use `python3.13 verify_release.py --hashes-only` to check
the package without NASM. A fixed seed (`-DSEED=0x1234`) removes RDTSC. The code
still uses 386-era instructions; default images require RDTSC support.

[Article](../ARTICLE.md) · [Full timing methodology](../LATENCY.md) ·
[Manifest](MANIFEST.json) · [Upstream license](../upstream/LICENSE)
''')
    # The stage is independent of the workspace and the original handover ZIP.
    with tempfile.TemporaryDirectory(prefix='bootlife-release-') as tmp:
        stage = Path(tmp) / NAME
        stage.mkdir()
        files = set(SOURCES.values())
        files.update(ROOT / name for name in ('ARTICLE.md', 'README.md', 'LATENCY.md',
                     'SLIDING_WINDOW.md', 'CONTRIBUTION_NOTES.md', 'experiment.py',
                     'measure_latency.py', 'check_palette.py', 'package_release.py',
                     'verify_release.py', 'life.rolling.compact.asm'))
        # Preserve the published fork's entry points when packaging from GitHub.
        files.update(ROOT / name for name in ('LICENSE', 'CONTRIBUTING.md', 'Makefile',
                     'EXPERIMENT_HISTORY.md', '.gitignore', 'life.asm', '.github/FUNDING.yml')
                     if (ROOT / name).is_file())
        for folder in ('upstream', 'results', 'article-assets', 'final'):
            files.update(p for p in (ROOT / folder).rglob('*') if p.is_file())
        for source in sorted(files):
            destination = stage / source.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        # Re-check all six delivered alternatives in the clean copy.
        subprocess.run([sys.executable, str(stage / 'experiment.py'), '--cpu', 'pentium',
                        '--variants', *FINAL, '--generations', '5', '--skip-benchmark',
                        '--output', str(stage / 'results/release.checks.json')], cwd=stage, check=True)
        subprocess.run([sys.executable, str(stage / 'check_palette.py')], cwd=stage, check=True)
        subprocess.run([sys.executable, str(stage / 'verify_release.py'), '--output',
                        str(stage / 'results/release-verification.json')], cwd=stage, check=True)
        for name in ('release.checks.json', 'release-verification.json'):
            shutil.copy2(stage / 'results' / name, ROOT / 'results' / name)
        # Runtime/build products are reproducible and are not part of the release.
        shutil.rmtree(stage / 'build')
        for cache in stage.rglob('__pycache__'):
            shutil.rmtree(cache)
        entries = sorted(p for p in stage.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
        (stage / 'SHA256SUMS').write_text(''.join(
            f'{digest(p.read_bytes())}  {p.relative_to(stage).as_posix()}\n' for p in entries))
        subprocess.run([sys.executable, str(stage / 'verify_release.py'), '--hashes-only'], cwd=stage, check=True)
        release = ROOT / 'releases'
        release.mkdir(exist_ok=True)
        archive = release / (NAME + '.zip')
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for path in sorted(stage.rglob('*')):
                if path.is_file():
                    z.write(path, Path(NAME) / path.relative_to(stage))
        (release / (NAME + '.zip.sha256')).write_text(f'{digest(archive.read_bytes())}  {archive.name}\n')
        print(f'Release: {archive}\nBytes: {archive.stat().st_size}\nSHA-256: {digest(archive.read_bytes())}')


if __name__ == '__main__':
    main()
