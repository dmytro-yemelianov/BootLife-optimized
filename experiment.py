#!/usr/bin/env python3
"""Build and validate real BootLife machine code in QEMU. Python 3.10+."""
import argparse
import hashlib
import json
import platform
import random
import re
import shutil
import socket
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REVIEW = ROOT / 'legacy'
BUILD = ROOT / 'build'
COMMIT = '86dc8d932db282097fd157e2c65051af7a3dd118'
CELLS = 64000
SOURCES = {
    'original': REVIEW / 'life.original.compact.asm',
    'center_sum': REVIEW / 'life.center_sum_candidate.asm',
    'hotloop': REVIEW / 'life.hotloop_candidate.asm',
    'padded': ROOT / 'life.padded.asm',
    'dualram': ROOT / 'life.dualram.asm',
    'padded_deadcount': ROOT / 'life.padded_deadcount.asm',
    'rolling': ROOT / 'life.rolling.asm',
    'ring': ROOT / 'life.ring.asm',
    'rolling_dword': ROOT / 'life.rolling_dword.asm',
    'sliding': ROOT / 'life.sliding.asm',
    'rolling_sliding': ROOT / 'life.rolling_sliding.asm',
    'sliding_lut': ROOT / 'life.sliding_lut.asm',
    'sliding_bits': ROOT / 'life.sliding_bits.asm',
    'rolling_lut': ROOT / 'life.rolling_lut.asm',
    'sliding_lut_word': ROOT / 'life.sliding_lut_word.asm',
    'rolling_bits': ROOT / 'life.rolling_bits.asm',
}
FINITE = ('padded', 'dualram', 'padded_deadcount', 'rolling', 'ring', 'rolling_dword',
          'sliding', 'rolling_sliding', 'sliding_lut', 'sliding_bits', 'rolling_lut',
          'sliding_lut_word', 'rolling_bits')
SMALL_WORK = {'rolling': 966, 'ring': 1008, 'rolling_dword': 966,
              'rolling_sliding': 966, 'rolling_lut': 966, 'rolling_bits': 966}
TABLE_VARIANTS = ('sliding_lut', 'rolling_lut', 'sliding_lut_word')
BIT_TABLE_VARIANTS = ('sliding_bits', 'rolling_bits')



def work_ram_bytes(name):
    return SMALL_WORK.get(name, 131072 if name == 'dualram' else 65536) + (2560 if name in TABLE_VARIANTS else 0)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def assemble(name, source, flags=()):
    asm = BUILD / (name + '.asm')
    img = BUILD / (name + '.img')
    listing = BUILD / (name + '.lst')
    asm.write_text(source)
    command = ['nasm', '-f', 'bin', *flags, '-l', str(listing), '-o', str(img), str(asm)]
    subprocess.run(command, check=True)
    data = img.read_bytes()
    assert len(data) == 512 and data[-2:] == b'\x55\xaa', name
    # Labels occupy their own listing lines; the next emitted byte is their address.
    symbols, pending, scope = {}, [], ''
    for line in listing.read_text().splitlines():
        label = re.search(r'\s(\.?[A-Za-z_]\w*):\s*$', line)
        if label:
            symbol = label.group(1)
            if not symbol.startswith('.'):
                scope = symbol
            pending.append(scope + symbol if symbol.startswith('.') else symbol)
        address = re.match(r'\s*\d+\s+([0-9A-F]{8})\s+[0-9A-F]', line)
        if address:
            for symbol in pending:
                symbols[symbol] = 0x7c00 + int(address.group(1), 16)
            pending.clear()
    return {'image': str(img), 'symbols': symbols, 'sha256': digest(data),
            'source_sha256': digest(source.encode()), 'flags': ['-f', 'bin', *flags],
            'payload_bytes': symbols.get('payload_end', 0x7dfe) - 0x7c00}


def deterministic(source):
    # Keep the complete snapshot + cell kernel. Remove *both* injections and pacing.
    source = source.replace('    rdtsc\n    mov bp, ax', '    mov bp, 0x1234')
    begin = source.index('%if SPARKS > 0') if '%if SPARKS > 0' in source else source.index('    mov cx, SPARKS')
    end = source.index('\npout:', begin)
    # RAM candidates must still present every frame inside the timed interval.
    presentation = ''
    if '\npresent_frame:' in source:
        presentation = source[source.index('\npresent_frame:'):source.index('    mov bx, [fs:TICK]')]
    source = source[:begin] + presentation + '''    dec word [fs:0x500]
    jnz generation
benchmark_done:
    cli
    hlt
    jmp benchmark_done
''' + source[end:]
    # BIOS entry flags are not part of the measured kernel. Establish them for all.
    source = source.replace('generation:\n', 'generation:\n    cli\n    cld\n', 1)
    return source


def build():
    BUILD.mkdir(exist_ok=True)
    upstream = (ROOT / 'upstream/life.asm').read_bytes()
    blob = hashlib.sha1(b'blob ' + str(len(upstream)).encode() + b'\0' + upstream).hexdigest()
    assert blob == '249085132a7fd83806a8f8d37ed9b3efaf7db533'
    output = {'upstream': assemble('upstream', upstream.decode())}
    for name, path in SOURCES.items():
        source = path.read_text()
        output[name] = assemble(name, source)
        if name in BIT_TABLE_VARIANTS:
            offset = output[name]['symbols']['rule_bits'] - 0x7c00
            bits = int.from_bytes(Path(output[name]['image']).read_bytes()[offset:offset + 64], 'little')
            for pattern in range(512):
                neighbors = 8 - (pattern & ~16).bit_count()
                alive = neighbors == 3 or (neighbors == 2 and not pattern & 16)
                assert (bits >> pattern) & 1 == alive, pattern

        output[name + '_bench'] = assemble(name + '_bench', deterministic(source), ['-DSEED=0x1234'])
    assert Path(output['upstream']['image']).read_bytes() == Path(output['original']['image']).read_bytes()
    output['upstream']['payload_bytes'] = output['original']['payload_bytes']
    for name in FINITE:
        source = SOURCES[name].read_text()
        output[name + '_no_injections'] = assemble(name + '_no_injections', source,
                                                  ['-DSPARKS=0', '-DGLIDERS=0', '-DSEED=0x1234'])
        output[name + '_gliders_only'] = assemble(name + '_gliders_only', source,
                                                 ['-DSPARKS=0', '-DGLIDERS=1', '-DSEED=0x1234'])
        output[name + '_seeded'] = assemble(name + '_seeded', source, ['-DSEED=0x1234'])
    return output


class Guest:
    """Minimal GDB remote client; breakpoints delimit work without guest I/O."""
    def __init__(self, artifact, cpu):
        self.artifact = artifact
        self.socket = None
        self.breakpoints = set()
        self.stopped = False
        reservation = socket.socket()
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
        reservation.close()
        self.command = ['qemu-system-i386', '-machine', 'pc', '-accel', 'tcg,thread=single',
                        '-cpu', cpu, '-m', '16M', '-display', 'none', '-serial', 'none',
                        '-monitor', 'none', '-no-reboot', '-no-shutdown', '-nic', 'none',
                        '-drive', f"file={artifact['image']},format=raw,if=floppy,readonly=on",
                        '-S', '-gdb', f'tcp:127.0.0.1:{port}']
        self.log = open(BUILD / 'qemu.log', 'w')
        self.process = subprocess.Popen(self.command, stdout=self.log, stderr=self.log)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    self.socket = socket.create_connection(('127.0.0.1', port), timeout=1)
                    self.socket.settimeout(60)
                    self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    break
                except OSError:
                    if self.process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('QEMU startup failed; see build/qemu.log')
                    time.sleep(.02)
            self.request('qSupported')
        except BaseException:
            self.close()
            raise

    def packet(self):
        while True:
            char = self.socket.recv(1)
            if not char:
                raise RuntimeError('QEMU disconnected')
            if char == b'$':
                break
        data = bytearray()
        while True:
            char = self.socket.recv(1)
            if not char:
                raise RuntimeError('QEMU disconnected')
            if char == b'#':
                break
            data.extend(char)
        checksum = self.socket.recv(1) + self.socket.recv(1)
        assert int(checksum, 16) == sum(data) % 256
        self.socket.sendall(b'+')
        # GDB run-length encoding is allowed in memory replies.
        decoded, i = bytearray(), 0
        while i < len(data):
            if data[i] == ord('*'):
                decoded.extend(decoded[-1:] * (data[i + 1] - 29))
                i += 2
            elif data[i] == ord('}'):
                decoded.append(data[i + 1] ^ 0x20)
                i += 2
            else:
                decoded.append(data[i])
                i += 1
        return decoded.decode()

    def request(self, command):
        payload = command.encode()
        self.socket.sendall(b'$' + payload + b'#' + f'{sum(payload) % 256:02x}'.encode())
        return self.packet()

    def breakpoint(self, address, enabled=True):
        assert self.request(f'{"Z" if enabled else "z"}0,{address:x},1') == 'OK'
        if enabled:
            self.breakpoints.add(address)
        else:
            self.breakpoints.discard(address)

    def prepare_resume(self):
        # Like GDB itself, step off the current breakpoint before re-arming it.
        if self.stopped:
            addresses = list(self.breakpoints)
            for address in addresses:
                self.breakpoint(address, False)
            reply = self.request('s')
            assert reply.startswith(('T05', 'S05')), reply
            for address in addresses:
                self.breakpoint(address)
            self.stopped = False

    def resume(self):
        self.prepare_resume()
        reply = self.request('c')
        assert reply.startswith(('T05', 'S05')), reply
        self.stopped = True

    def read(self, address, size):
        data = bytearray()
        for offset in range(0, size, 1024):
            count = min(1024, size - offset)
            block = bytes.fromhex(self.request(f'm{address + offset:x},{count:x}'))
            assert len(block) == count
            data.extend(block)
        return bytes(data)

    def write(self, address, data):
        for offset in range(0, len(data), 1024):
            block = data[offset:offset + 1024]
            assert self.request(f'M{address + offset:x},{len(block):x}:{block.hex()}') == 'OK'

    def set_bp(self, value):
        # QEMU i386 GDB layout: EAX ECX EDX EBX ESP EBP ESI EDI ...
        registers = bytearray.fromhex(self.request('g'))
        registers[20:24] = value.to_bytes(4, 'little')
        assert self.request('G' + registers.hex()) == 'OK'

    def boot(self):
        address = self.artifact['symbols']['generation']
        self.breakpoint(address)
        self.resume()
        self.breakpoint(address, False)

    def close(self):
        if self.socket:
            self.socket.close()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def reference(grid, finite=True):
    """Independent coordinate-based B3/S23 with the original byte color semantics."""
    output = bytearray(CELLS)
    for y in range(200):
        for x in range(320):
            i = y * 320 + x
            count = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == dy == 0:
                        continue
                    if finite:
                        if not (0 <= x + dx < 320 and 0 <= y + dy < 200):
                            continue
                        j = (y + dy) * 320 + x + dx
                    else:
                        j = (i + dy * 320 + dx) & 0xffff
                        if j >= CELLS:
                            continue
                    count += grid[j] >> 7
            c = grid[i]
            alive = count == 3 or (count == 2 and c >= 128)
            output[i] = (min(c + 6, 255) if c >= 128 else 128) if alive else (127 if c >= 128 else max(c - 16, 0))
    return bytes(output)


def corpus():
    rng = random.Random(0xB007)
    grids = {'arbitrary_bytes': bytes(rng.randrange(256) for _ in range(CELLS)),
             'empty': bytes(CELLS), 'all_live': bytes([255]) * CELLS}
    grid = bytearray(CELLS)
    for x, y in [(0, 0), (0, 1), (0, 2), (319, 197), (319, 198), (319, 199),
                 (158, 100), (159, 100), (160, 100), (317, 0), (318, 1),
                 (316, 2), (317, 2), (318, 2)]:
        grid[y * 320 + x] = 128
    grids['edges_and_oscillator'] = bytes(grid)
    return grids


def padded_bytes(grid):
    work = bytearray(65044)
    for y in range(200):
        work[(y + 1) * 322 + 1:(y + 1) * 322 + 321] = grid[y * 320:(y + 1) * 320]
    return bytes(work)


def load_grid(guest, name, grid):
    guest.write(0xa0000, grid)
    if name == 'dualram':
        # Load both roles so resetting after warmup does not depend on swap parity.
        for base in (0x10000, 0x20000):
            guest.write(base, padded_bytes(grid))


def check(artifacts, cpu, generations, names):
    grids = corpus()
    expected = {}
    for name, grid in grids.items():
        for finite in (False, True):
            frames = []
            for _ in range(generations):
                grid_next = reference(grid if not frames else frames[-1], finite)
                frames.append(grid_next)
            expected[name, finite] = frames
    results = {}
    for name in names:
        finite = name in FINITE
        bases = (0x10000, 0x20000) if name == 'dualram' else (0x10000,)
        after_work = bases[-1] + 65536
        rows = []
        for case, grid in grids.items():
            artifact = artifacts[name + '_bench']
            with Guest(artifact, cpu) as guest:
                guest.boot()
                load_grid(guest, name, grid)
                guest.write(0x500, generations.to_bytes(2, 'little'))
                # Guards cover neighboring RAM and unused work/VGA tails.
                guest.write(0xff00, b'\xa5' * 256)
                guest.write(after_work, b'\x5a' * 256)
                guest.write(0xa0000 + CELLS, b'\x69' * 1536)
                if name in SMALL_WORK:
                    size = SMALL_WORK[name]
                    guest.write(0x10000 + size, b'\x96' * (65536 - size))
                    if name == 'ring':
                        for slot in range(3):
                            guest.write(0x10000 + slot * 336 + 322, b'\x69' * 14)
                elif finite:
                    for base in bases:
                        guest.write(base + 65044, b'\x96' * 492)
                guest.breakpoint(artifact['symbols']['generation'])
                guest.breakpoint(artifact['symbols']['benchmark_done'])
                if name in TABLE_VARIANTS:
                    # Independently validate every generated (total-dead, color) entry.
                    table = bytearray()
                    for dead in range(10):
                        for color in range(256):
                            neighbors = 9 - dead - (color >> 7)
                            alive = neighbors == 3 or (neighbors == 2 and color >= 128)
                            table.append((min(color + 6, 255) if color >= 128 else 128)
                                         if alive else (127 if color >= 128 else max(color - 16, 0)))
                    assert guest.read(0x8000, 2560) == table
                    guest.write(0x7f00, b'\xa6' * 256)
                    guest.write(0x8a00, b'\x6a' * 256)
                hashes, finite_matches = [], []
                for step in range(generations):
                    if name == 'dualram':
                        # VGA corruption must not affect the authoritative RAM state.
                        guest.write(0xa0000, b'\x42' * CELLS)
                    guest.resume()
                    actual = guest.read(0xa0000, CELLS)
                    wanted = expected[case, finite][step]
                    if actual != wanted:
                        first = next(i for i, (a, b) in enumerate(zip(actual, wanted)) if a != b)
                        raise AssertionError(f'{name}/{case} generation {step + 1}: pixel {first}: {actual[first]} != {wanted[first]}')
                    hashes.append(digest(actual))
                    finite_matches.append(actual == expected[case, True][step])
                    if name in TABLE_VARIANTS:
                        assert guest.read(0x7f00, 256) == b'\xa6' * 256
                        assert guest.read(0x8a00, 256) == b'\x6a' * 256
                        assert guest.read(0x8000, 2560) == table
                    assert guest.read(0xff00, 256) == b'\xa5' * 256
                    assert guest.read(after_work, 256) == b'\x5a' * 256
                    assert guest.read(0xa0000 + CELLS, 1536) == b'\x69' * 1536
                    for base in bases:
                        work = guest.read(base, 65536)
                        if name in SMALL_WORK:
                            size = SMALL_WORK[name]
                            assert work[size:] == b'\x96' * (65536 - size)
                            previous = grid if step == 0 else expected[case, True][step - 1]
                            prev_row = b'\0' + previous[198 * 320:199 * 320] + b'\0'
                            last_row = b'\0' + previous[199 * 320:] + b'\0'
                            if name != 'ring':
                                assert work[:966] == prev_row + last_row + bytes(322)
                            else:
                                # 199 rotations: slots hold missing-next / row198 / row199.
                                for slot, row in enumerate((bytes(322), prev_row, last_row)):
                                    assert work[slot * 336:slot * 336 + 322] == row
                                    assert work[slot * 336 + 322:(slot + 1) * 336] == b'\x69' * 14
                        elif finite:
                            assert work[65044:] == b'\x96' * 492
                            assert not any(work[:322] + work[201 * 322:65044])
                            assert all(work[y * 322] == work[y * 322 + 321] == 0 for y in range(1, 201))
                            if name == 'dualram':
                                current_base = 0x20000 if step % 2 == 0 else 0x10000
                                previous = grid if step == 0 else expected[case, True][step - 1]
                                assert work[:65044] == padded_bytes(wanted if base == current_base else previous)
                        else:
                            assert not any(work[CELLS:])
                rows.append({'case': case, 'input_sha256': digest(grid), 'output_sha256_by_generation': hashes,
                             'finite_reference_matches': finite_matches, 'guards_and_halo_pass': True})
                print(f'PASS {cpu} {name}/{case}: {generations} machine-code generations', flush=True)
        results[name] = {'topology': 'finite_dead_border' if finite else 'legacy_row_seams',
                         'finite_eligible': all(all(row['finite_reference_matches']) for row in rows),
                         'cases': rows}
    # Boot the shipping images too; prove they pass their timer wait into frame two.
    shipping = list(names) + [n + '_no_injections' for n in names if n in FINITE]
    if 'original' in names:
        shipping.append('upstream')
    for name in shipping:
        with Guest(artifacts[name], cpu) as guest:
            guest.boot()
            guest.breakpoint(artifacts[name]['symbols']['generation'])
            guest.resume()
        print(f'PASS {cpu} normal boot + paced generation: {name}', flush=True)
    # The zero-injection production configuration must also match the finite model.
    for name in names:
        if name not in FINITE:
            continue
        with Guest(artifacts[name + '_no_injections'], cpu) as guest:
            guest.boot()
            grid = grids['edges_and_oscillator']
            load_grid(guest, name, grid)
            guest.breakpoint(artifacts[name + '_no_injections']['symbols']['generation'])
            for step in range(generations):
                guest.resume()
                assert guest.read(0xa0000, CELLS) == expected['edges_and_oscillator', True][step]
    return results


def check_gliders(artifacts, cpu, variant):
    # LCG states selected to exercise both sides of the row/column boundaries.
    cases = [('last_valid_column', 2255, 33917, True),
             ('last_valid_row', 1116, 63202, True),
             ('reject_column_318', 6680, 3518, False),
             ('reject_column_319', 1953, 41279, False),
             ('reject_row_198', 5363, 63617, False),
             ('reject_outside_frame', 272, 64246, False)]
    artifact = artifacts[variant + '_gliders_only']
    results = []
    for name, seed, origin, accepted in cases:
        with Guest(artifact, cpu) as guest:
            guest.boot()
            load_grid(guest, variant, bytes(CELLS))
            guest.write(0xa0000 + CELLS, b'\x69' * 1536)
            guest.breakpoint(artifact['symbols']['generation.glider'])
            guest.resume()
            guest.set_bp(seed)
            guest.breakpoint(artifact['symbols']['generation.glider'], False)
            guest.breakpoint(artifact['symbols']['generation'])
            guest.resume()
            expected = bytearray(CELLS)
            if accepted:
                for offset in (1, 322, 640, 641, 642):
                    expected[origin + offset] = 128
            assert guest.read(0xa0000, CELLS + 1536) == expected + b'\x69' * 1536, name
        results.append({'case': name, 'rng_state': seed, 'origin': origin, 'accepted': accepted, 'pass': True})
        print(f'PASS {cpu} {variant} glider placement: {name}', flush=True)
    return results


def check_seeded(artifacts, cpu, variant, generations):
    """Check normal bootstrap + all enabled injection paths against a model."""
    state = 0x1234

    def random_word():
        nonlocal state
        state = (25173 * state + 13849) % 65536
        return state

    grid = bytes((random_word() >> 8) & 128 for _ in range(CELLS))
    artifact = artifacts[variant + '_seeded']
    hashes = []
    with Guest(artifact, cpu) as guest:
        guest.boot()
        initial = guest.read(0x10000, 65044) if variant == 'dualram' else guest.read(0xa0000, CELLS)
        assert initial == (padded_bytes(grid) if variant == 'dualram' else grid)
        guest.breakpoint(artifact['symbols']['generation'])
        for step in range(generations):
            grid = bytearray(reference(grid))
            for _ in range(6):
                index = random_word()
                if index < CELLS:
                    grid[index] = 128
            if ((random_word() >> 8) & 15) == 0:
                index = random_word()
                y, x = divmod(index, 320)
                if x <= 317 and y <= 197:
                    for dx, dy in ((1, 0), (2, 1), (0, 2), (1, 2), (2, 2)):
                        grid[(y + dy) * 320 + x + dx] = 128
            guest.resume()
            assert guest.read(0xa0000, CELLS) == grid, (variant, step)
            if variant == 'dualram':
                base = 0x20000 if step % 2 == 0 else 0x10000
                assert guest.read(base, 65044) == padded_bytes(grid)
            hashes.append(digest(grid))
    print(f'PASS {cpu} {variant} seeded normal image, sparks/gliders enabled: {generations} generations', flush=True)
    return {'seed': 0x1234, 'sparks': 6, 'gliders_enabled': True,
            'output_sha256_by_generation': hashes, 'pass': True}


def benchmark(artifacts, checks, cpu, generations, repetitions, names):
    grid = corpus()['arbitrary_bytes']
    order = [name for name in names for _ in range(repetitions)]
    random.Random(20260924).shuffle(order)
    results = {name: [] for name in names}
    expected = {finite: grid for finite in (False, True)}
    for _ in range(generations):
        expected = {finite: reference(frame, finite) for finite, frame in expected.items()}
    for name in order:
        artifact = artifacts[name + '_bench']
        with Guest(artifact, cpu) as guest:
            guest.boot()
            load_grid(guest, name, grid)
            guest.write(0x500, (generations + 1).to_bytes(2, 'little'))
            # Warm one whole generation to translate the kernel; reset the corpus.
            guest.breakpoint(artifact['symbols']['generation'])
            guest.resume()
            guest.breakpoint(artifact['symbols']['generation'], False)
            load_grid(guest, name, grid)
            # Even a never-executed breakpoint on the boot-code page heavily
            # slows TCG. Stop outside that page, after the complete batch.
            done = artifact['symbols']['benchmark_done']
            guest.write(0x9000, b'\xf4\xeb\xfd')
            guest.write(done, b'\xe9' + ((0x9000 - done - 3) & 65535).to_bytes(2, 'little'))
            guest.breakpoint(0x9000)
            guest.prepare_resume()
            start = time.perf_counter_ns()
            guest.resume()
            elapsed = time.perf_counter_ns() - start
            assert guest.read(0xa0000, CELLS) == expected[name in FINITE]
            results[name].append(elapsed / 1e6 / generations)
        print(f'TIMING {cpu} {name}: {results[name][-1] / 1000:.6f} host seconds/generation; '
              f'{1000 / results[name][-1]:.1f} equivalent FPS (unpaced)', flush=True)
    # Keep topology groups separate and include the RAM cost in selection.
    costs = {name: (statistics.median(results[name]), artifacts[name]['payload_bytes'],
                    work_ram_bytes(name)) for name in names}
    fronts = {}
    for name in names:
        topology = checks[name]['topology']
        fronts.setdefault(topology, [])
        dominated = any(other != name and checks[other]['topology'] == topology
                        and all(a <= b for a, b in zip(costs[other], costs[name]))
                        and any(a < b for a, b in zip(costs[other], costs[name])) for other in names)
        if not dominated:
            fronts[topology].append(name)
    return {'metric': 'host_wall_ms_per_generation_including_one_GDB_resume_stop_roundtrip_per_batch',
            'stop_location': 'external_0x9000_no_breakpoints_on_boot_code_page_during_batch',
            'not_guest_cycles': True, 'generations_per_sample': generations, 'warmup_generations': 1,
            'order_seed': 20260924, 'repetitions': repetitions,
            'pareto_axes': ['median_host_ms_per_generation', 'normal_payload_bytes', 'reserved_work_ram_bytes'],
            'observed_pareto_fronts_by_topology': fronts,
            'input_sha256': digest(grid), 'execution_order': order,
            'results': {name: {'samples': samples, 'median': statistics.median(samples),
                               'median_seconds_per_generation': statistics.median(samples) / 1000,
                               'equivalent_fps_from_median_period': 1000 / statistics.median(samples),
                               'min': min(samples), 'max': max(samples),
                               'median_absolute_deviation': statistics.median(abs(x - statistics.median(samples)) for x in samples),
                               'normal_payload_bytes': costs[name][1], 'reserved_work_ram_bytes': costs[name][2],
                               'finite_eligible': checks[name]['finite_eligible'],
                               'comparison_group': checks[name]['topology']}
                        for name, samples in results.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cpu', default='pentium', help='QEMU CPU; full suite needs RDTSC for upstream boot checks')
    parser.add_argument('--generations', type=int, default=3)
    parser.add_argument('--benchmark-generations', type=int, default=20)
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--skip-benchmark', action='store_true')
    parser.add_argument('--variants', nargs='+', choices=SOURCES, default=list(SOURCES))
    parser.add_argument('--output', type=Path, help='Result path; defaults to results/<cpu>.<variants>.json')
    args = parser.parse_args()
    if not (1 <= args.generations <= 65535 and 1 <= args.benchmark_generations <= 65534 and args.repetitions >= 1):
        parser.error('positive counts required; generation counters are 16-bit')
    for tool in ('nasm', 'qemu-system-i386'):
        if not shutil.which(tool):
            parser.error(f'{tool} is required')
    artifacts = build()
    report = {'upstream_commit': COMMIT, 'builds': artifacts, 'cpu': args.cpu,
              'harness_sha256': digest(Path(__file__).read_bytes()), 'variants': args.variants,
              'host': platform.platform(), 'python': platform.python_version(),
              'nasm': subprocess.check_output(['nasm', '-v'], text=True).strip(),
              'qemu': subprocess.check_output(['qemu-system-i386', '--version'], text=True).splitlines()[0],
              'emulator_configuration': 'pc; tcg,thread=single; 16M; display=none; nic=none; BIOS floppy boot',
              'qemu_command_template': ['qemu-system-i386', '-machine', 'pc', '-accel', 'tcg,thread=single',
                                        '-cpu', args.cpu, '-m', '16M', '-display', 'none', '-serial', 'none',
                                        '-monitor', 'none', '-no-reboot', '-no-shutdown', '-nic', 'none',
                                        '-drive', 'file=<image>,format=raw,if=floppy,readonly=on',
                                        '-S', '-gdb', 'tcp:127.0.0.1:<ephemeral-port>'],
              'created_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    if not args.build_only:
        report['checks'] = check(artifacts, args.cpu, args.generations, args.variants)
        report['glider_checks'] = {n: check_gliders(artifacts, args.cpu, n) for n in args.variants if n in FINITE}
        report['seeded_checks'] = {n: check_seeded(artifacts, args.cpu, n, args.generations)
                                   for n in args.variants if n in FINITE}
        if not args.skip_benchmark:
            report['benchmark'] = benchmark(artifacts, report['checks'], args.cpu, args.benchmark_generations, args.repetitions, args.variants)
    suffix = '.build' if args.build_only else ('.checks' if args.skip_benchmark else '')
    target = args.output or ROOT / 'results' / (args.cpu + '.' + '-'.join(args.variants) + suffix + '.json')
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Results: {target}')


if __name__ == '__main__':
    main()
