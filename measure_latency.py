#!/usr/bin/env python3
"""Report cold BIOS startup and paced frame latency in host wall seconds."""
import argparse
import json
import platform
import random
import statistics
import subprocess
import time
from pathlib import Path

from experiment import BUILD, CELLS, ROOT, SOURCES, Guest, assemble, digest, reference


def summary(samples):
    median = statistics.median(samples)
    return {'samples': samples, 'median': median, 'min': min(samples), 'max': max(samples),
            'median_absolute_deviation': statistics.median(abs(v - median) for v in samples)}


def seeded_frames(count):
    state = 0x1234

    def rnd():
        nonlocal state
        state = (25173 * state + 13849) & 65535
        return state

    grid = bytes((rnd() >> 8) & 128 for _ in range(CELLS))
    frames = [grid]
    for _ in range(count):
        grid = bytearray(reference(grid))
        for _ in range(6):
            index = rnd()
            if index < CELLS:
                grid[index] = 128
        if ((rnd() >> 8) & 15) == 0:
            index = rnd()
            y, x = divmod(index, 320)
            if x <= 317 and y <= 197:
                for dx, dy in ((1, 0), (2, 1), (0, 2), (1, 2), (2, 2)):
                    grid[(y + dy) * 320 + x + dx] = 128
        frames.append(bytes(grid))
    return frames


def make_artifact(name):
    source = SOURCES[name].read_text()
    flags = ['-DSEED=0x1234']
    production = assemble(name + '_latency_production', source, flags)
    labeled = source.replace('    mov bx, [fs:TICK]\n', 'frame_ready:\n    mov bx, [fs:TICK]\n')
    labeled = labeled.replace('    jmp generation\npout:', 'frame_backedge:\n    jmp generation\npout:')
    artifact = assemble(name + '_latency', labeled, flags)
    assert production['sha256'] == artifact['sha256']  # Labels emit no bytes.
    artifact['production_source_sha256'] = production['source_sha256']
    artifact['production_payload_bytes'] = production['payload_bytes']
    return artifact


def startup(artifact, cpu, target, expected):
    # A breakpoint anywhere on the boot-code page slows TCG substantially.
    # Divert only at the measurement boundary, to a stop on another page.
    image = bytearray(Path(artifact['image']).read_bytes())
    address = artifact['symbols'][target]
    offset = address - 0x7c00
    image[offset:offset + 3] = b'\xe9' + ((0x9000 - address - 3) & 65535).to_bytes(2, 'little')
    path = BUILD / (Path(artifact['image']).stem + '_' + target + '.img')
    path.write_bytes(image)
    observed = dict(artifact, image=str(path))
    launch = time.perf_counter()
    with Guest(observed, cpu) as guest:
        # BIOS may overwrite low RAM. No observer instructions need to survive:
        # the breakpoint stops before anything at this address is executed.
        guest.breakpoint(0x9000)
        start = time.perf_counter()
        guest.resume()  # First resume from CPU reset; no intermediate debugger stops.
        end = time.perf_counter()
        assert guest.read(0xa0000, CELLS) == expected
    return {'reset_to_ready_seconds': end - start,
            'launch_with_debugger_setup_to_ready_seconds': end - launch,
            'output_sha256': digest(expected), 'observer_image_sha256': digest(image)}


def generation_batch(artifact, cpu, count, expected, mode):
    # The observer lives outside the 512-byte image. Patch only the final JMP,
    # after the unchanged timer wait; count an entire batch without per-frame stops.
    probe_source = f'''bits 16
org 0x9000
    dec word [fs:0x500]
    jz .done
    jmp near {artifact['symbols']['generation']}
.done:
    hlt
    jmp .done
'''
    probe = BUILD / 'paced_observer.asm'
    probe.write_text(probe_source)
    binary = probe.with_suffix('.bin')
    subprocess.run(['nasm', '-f', 'bin', '-o', str(binary), str(probe)], check=True)
    code = binary.read_bytes()
    backedge = artifact['symbols']['frame_backedge']
    image = Path(artifact['image']).read_bytes()
    offset = backedge - 0x7c00
    original_jump = image[offset:offset + 3]
    assert original_jump[0] == 0xe9
    destination = (backedge + 3 + int.from_bytes(original_jump[1:], 'little', signed=True)) & 65535
    assert destination == artifact['symbols']['generation']
    with Guest(artifact, cpu) as guest:
        guest.boot()
        guest.breakpoint(artifact['symbols']['generation'])
        guest.resume()  # One production generation and its normal timer wait as warmup.
        guest.breakpoint(artifact['symbols']['generation'], False)
        guest.write(0x9000, code)
        guest.write(0x500, count.to_bytes(2, 'little'))
        guest.write(backedge, b'\xe9' + ((0x9000 - backedge - 3) & 65535).to_bytes(2, 'little'))
        if mode != 'paced':
            wait = artifact['symbols']['frame_ready']
            guest.write(wait, b'\xe9' + ((backedge - wait - 3) & 65535).to_bytes(2, 'little'))
        if mode == 'unpaced_with_boot_breakpoint':
            # Never executed: isolates debugger overhead on the kernel's code page.
            guest.breakpoint(0x7dff)

        guest.breakpoint(0x9000 + len(code) - 3)
        before_ticks = int.from_bytes(guest.read(0x46c, 4), 'little')
        guest.prepare_resume()
        start = time.perf_counter()
        guest.resume()
        elapsed = time.perf_counter() - start
        after_ticks = int.from_bytes(guest.read(0x46c, 4), 'little')
        assert guest.read(0x500, 2) == bytes(2)
        assert guest.read(0xa0000, CELLS) == expected
    return {'batch_seconds': elapsed, 'seconds_per_generation': elapsed / count,
            'generations_per_second': count / elapsed,
            'bios_ticks_in_batch': after_ticks - before_ticks,
            'output_sha256': digest(expected), 'observer_sha256': digest(code)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variants', nargs='+', choices=('padded_deadcount', 'rolling_lut', 'rolling_bits'),
                        default=['padded_deadcount', 'rolling_lut', 'rolling_bits'])
    parser.add_argument('--cpu', default='pentium')
    parser.add_argument('--generations', type=int, default=20)
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--output', type=Path, default=ROOT / 'results/pentium.latency.json')
    args = parser.parse_args()
    if not (1 <= args.generations <= 65535 and args.repetitions >= 1):
        parser.error('positive repetitions and a 16-bit generation count required')
    BUILD.mkdir(exist_ok=True)
    frames = seeded_frames(args.generations + 1)
    artifacts = {name: make_artifact(name) for name in args.variants}
    results = {name: {'seed_frame': [], 'first_evolved_frame': [], 'paced': [],
                      'unpaced': [], 'unpaced_with_boot_breakpoint': []} for name in args.variants}
    order = [(name, kind) for name in args.variants for kind in results[name]
             for _ in range(args.repetitions)]
    random.Random(20260925).shuffle(order)
    for name, kind in order:
        if kind in ('paced', 'unpaced', 'unpaced_with_boot_breakpoint'):
            sample = generation_batch(artifacts[name], args.cpu, args.generations, frames[-1], kind)
            display = sample['seconds_per_generation']
        else:
            first = kind == 'first_evolved_frame'
            sample = startup(artifacts[name], args.cpu, 'frame_ready' if first else 'generation', frames[int(first)])
            display = sample['reset_to_ready_seconds']
        results[name][kind].append(sample)
        print(f'{name} {kind}: {display:.6f} seconds', flush=True)
    for rows in results.values():
        for kind in ('seed_frame', 'first_evolved_frame'):
            rows[kind + '_summary'] = {
                field: summary([sample[field] for sample in rows[kind]])
                for field in ('reset_to_ready_seconds', 'launch_with_debugger_setup_to_ready_seconds')}
        for kind in ('paced', 'unpaced', 'unpaced_with_boot_breakpoint'):
            rows[kind + '_seconds_per_generation'] = summary([sample['seconds_per_generation'] for sample in rows[kind]])
            rows[kind + '_fps_from_median_period'] = 1 / rows[kind + '_seconds_per_generation']['median']
    report = {'created_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'metric': 'host_wall_seconds', 'cpu': args.cpu, 'host': platform.platform(),
              'host_cpu': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()
                          if platform.system() == 'Darwin' else platform.processor(),
              'qemu': subprocess.check_output(['qemu-system-i386', '--version'], text=True).splitlines()[0],
              'configuration': 'pc; tcg,thread=single; 16M; display=none; nic=none; BIOS floppy boot',
              'seed': 0x1234, 'sparks': 6, 'gliders_enabled': True,
              'generations_per_batch': args.generations, 'warmup_generations': 1,
              'repetitions': args.repetitions, 'execution_order': order,
              'script_sha256': digest(Path(__file__).read_bytes()),
              'harness_sha256': digest((ROOT / 'experiment.py').read_bytes()),
              'artifacts': artifacts, 'results': results,
              'limitations': ['Not physical Pentium cycles or monitor presentation timestamps.',
                              'Startup ends at a complete VGA memory frame, with no GUI display.',
                              'Reset timing excludes launch/setup; launch timing includes debugger setup.',
                              'Startup images jump to an external stop only at the measured frame boundary.',
                              'All batches add an external DEC/Jcc/JMP observer once per frame.',
                              'Unpaced mode skips only the timer wait; injections and interrupts remain enabled.',
                              'The breakpoint diagnostic adds a never-executed breakpoint at 0x7dff.',
                              'Paced input is normal seeded evolution with injections, not the earlier arbitrary-byte corpus.']}
    args.output.parent.mkdir(exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Results: {args.output}')


if __name__ == '__main__':
    main()
