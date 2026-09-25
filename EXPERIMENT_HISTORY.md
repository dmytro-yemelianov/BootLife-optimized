# BootLife experiment

Read the [complete article](ARTICLE.md) or choose a [final source and boot image](final/README.md).

The latest experiment implements horizontal sliding windows and two lookup-table
strategies. `sliding` has the smallest tested finite-grid payload (408 bytes).
`rolling_bits` uses a 64-byte embedded rule table and 966 work bytes; its payload
is 510 bytes. `rolling_lut` uses 490 payload bytes and 3,526 work bytes. The fastest
observed kernel is `sliding_lut_word`: 473 payload bytes, 68,096 work bytes,
approximately 0.000779 seconds/generation (1284 equivalent FPS without pacing).

[Frame times, FPS, and startup](LATENCY.md) contains the corrected measurements
and a debugger-overhead A/B test. Earlier timing reports placed a breakpoint on
the boot-code page and substantially slowed QEMU; their throughput and ranking
claims are superseded. The normal paced demo remains approximately 18.2 FPS.
The tested host is Apple M5 with QEMU TCG's Pentium model, not a physical Pentium.

See [Sliding windows and lookup tables](SLIDING_WINDOW.md) for assembly design,
validation, related work, and historical results. All images remain 512-byte
BIOS boot sectors.

The finite-grid candidates implement a 320×200 Life grid in a 512-byte BIOS
boot sector. They preserve BootLife's B3/S23 rule, color aging/fading, palette,
random sparks, and timer pacing. Each 322×202 work grid has a permanently dead
halo, and glider origins must fit within a row.

- `life.padded.asm`: VGA holds the current state; one RAM grid holds its snapshot.
- `life.dualram.asm`: two RAM grids hold the state; VGA is only written.
- `life.padded_deadcount.asm`: padded layout with two instructions per neighbor,
  counting dead neighbors using `CMP`/`ADC` instead of extracting live bits.
- `life.rolling.asm`: three adjacent rows, shifted forward after each output row;
  966 bytes of working buffer RAM.
- `life.ring.asm`: three paragraph-aligned slots, rotated with segment registers;
  1,008 bytes of working buffer RAM, without copying rows between cache slots.
- `life.rolling_dword.asm`: the same 966-byte rolling layout with 32-bit cache
  copies instead of 16-bit copies.
- `life.sliding.asm` / `life.rolling_sliding.asm`: cache three vertical column
  counts, reading only the newly entering column at each horizontal step.
- `life.sliding_lut.asm` / `life.rolling_lut.asm`: generate a 2,560-byte color
  transition table at boot, replacing hot-loop rule and aging branches.
- `life.sliding_bits.asm` / `life.rolling_bits.asm`: a nine-bit sliding window
  and a 64-byte embedded rule table, with no extra work RAM for the table.
- `life.sliding_lut_word.asm`: paired VGA writes; the fastest observed kernel
  in the corrected benchmark, at the cost of a larger payload than sliding_lut.

The upstream source is pinned to
[`0xAX/BootLife@86dc8d9`](https://github.com/0xAX/BootLife/tree/86dc8d932db282097fd157e2c65051af7a3dd118).
`upstream/life.asm` has Git blob `249085132a7fd83806a8f8d37ed9b3efaf7db533`.
Its NASM image is byte-for-byte identical to the handover's compact transcription.
The original ISC notice is retained in the sources.

## Build and run

Requirements: Python 3.10+, NASM, and `qemu-system-i386`. This workspace uses
Python 3.13, NASM 3.02 and QEMU 11.0.1 on macOS ARM64.

From this directory (`bootlife/` in the workspace, or the extracted package root):

```sh
python3.13 experiment.py --build-only
qemu-system-i386 -drive file=build/rolling_bits.img,format=raw,if=floppy
```

This runs the 966-byte-buffer, embedded-table version. Use
`build/rolling_lut.img` for the runtime color-table variant, or
`build/sliding.img` for the smallest tested finite-grid payload.

For a denser source representation, use
[`life.rolling.compact.asm`](life.rolling.compact.asm). Its `seq` macro expands
each braced instruction into an ordinary NASM line, allowing groups such as:

```nasm
seq {xor ax, ax}, {mov ss, ax}, {mov sp, 0x7000}
```

This reduces the displayed source from 276 to 135 lines while preserving the
license, labels, conditional settings, and instruction order. The added syntax
makes the text file slightly larger in bytes. The assembled program is unchanged:
all six tested seed/injection configurations produce byte-identical 512-byte
images. Verification hashes are in
[`results/compact-source-check.json`](results/compact-source-check.json).

```sh
nasm -f bin -o build/rolling.compact.img life.rolling.compact.asm
```

Or build the candidate directly:

```sh
mkdir -p build
nasm -f bin -o build/padded_deadcount.img life.padded_deadcount.asm
```

Use `-DSPARKS=0 -DGLIDERS=0 -DSEED=0x1234` to disable both injections and fix the
startup seed. Timer pacing remains enabled in this normal boot image. `SPARKS=0`
omits the spark loop entirely. A specified seed removes `RDTSC`; default images
still require a CPU that supports that instruction.

## Reproduce validation and timing

```sh
python3.13 experiment.py --cpu pentium --variants padded dualram --generations 5 --benchmark-generations 20 --repetitions 7 --output results/pentium.finite-ram-comparison.json
python3.13 experiment.py --cpu pentium --variants padded padded_deadcount --generations 5 --benchmark-generations 20 --repetitions 7 --output results/pentium.finite-deadcount-comparison.json
python3.13 experiment.py --cpu pentium --variants padded_deadcount rolling ring --generations 5 --benchmark-generations 20 --repetitions 7 --output results/pentium.three-row-comparison.json
python3.13 experiment.py --cpu pentium --variants padded_deadcount rolling rolling_dword --generations 5 --benchmark-generations 20 --repetitions 7 --output results/pentium.three-row-dword-comparison.json
```

`--skip-benchmark` runs only the correctness suite. Without `--output`, files
are named `results/<cpu>.<variants>[.checks|.build].json`, preserving the first
experiment's reports. Omit `--variants` to include the legacy candidates too.
Different CPU names get separate files.
The complete suite boots the unmodified upstream, so select a CPU with `RDTSC`.
All QEMU instances are headless, use TCG with one thread, and are closed after
each case. The harness requires no Python packages.

The harness:

- Assembles each normal and deterministic image and checks its size/signature.
- Boots through BIOS and captures actual VGA memory via QEMU's GDB stub.
- Compares every byte after each of five generations on four 64,000-byte inputs:
  arbitrary color bytes, empty, all-live, and edge/oscillator/glider patterns.
- Checks guard regions beside the work segment and framebuffer, the unused
  segment tails, and every padded halo byte after each generation. Both RAM
  grids are checked against the expected current/previous states, and VGA is
  deliberately corrupted before each dual-RAM generation to test independence.
- For small buffers, checks the complete unused remainder of the 64 KiB segment
  for writes, validates the cached old rows against the reference, and checks
  each ring slot's halos and alignment padding.
- Boots normal images through a paced generation and checks the no-injection
  production image against the finite reference.
- Exercises actual glider machine code at the last valid column/row, invalid
  columns 318/319, row 198, and an origin beyond the framebuffer.
- Checks fixed-seed normal images with sparks/gliders enabled against an
  independent injection model, including the initial seeded grid.

The original, center-sum, and hot-loop variants pass their **legacy row-seam**
reference and fail the finite-grid gate. The finite-grid candidates are eligible
for finite-grid selection. The handover's independent 65,536-case transition
model checks also pass under Python 3.13.

For timing, deterministic variants retain the snapshot and complete cell kernel,
fix the seed, remove both injection paths and the timer wait, and disable
interrupts during computation. The GDB harness loads the same arbitrary-byte
corpus into each candidate's authoritative storage, warms one generation,
reloads the corpus, then measures a 20-generation batch. Both RAM roles are
reset after warmup; every timed dual-RAM generation includes the VGA copy.
Each sample uses a fresh QEMU process. Execution order is
shuffled with a recorded seed; all raw samples are retained. The final output
of every timed batch must match its topology's reference.

## First experiment — QEMU TCG, Pentium model

These are **host wall milliseconds per generation**, including one debugger
resume/stop round trip per batch. They are not emulated Pentium cycles or
physical CPU timings. Setup, BIOS, corpus transfer, and output checks are outside
the measured interval. Work includes RAM snapshot, rule computation, and VGA writes.

| Variant | Normal payload bytes | Median ms/gen | Median absolute deviation | Finite-grid gate |
|---|---:|---:|---:|---|
| Original | 355 | 261.72 | 2.74 | Fail |
| Center-sum | 348 | 245.08 | 2.27 | Fail |
| Unrolled hot-loop | 395 | 148.24 | 1.69 | Fail |
| Padded, unrolled | 432 | 144.86 | 3.85 | Pass |

The padded samples range from 133.49 to 205.90 ms/gen. That variation, and the
different edge semantics, prevent a claim that it is faster than the legacy
hot-loop candidate. Within the legacy topology, center-sum and hot-loop form the
observed payload/time Pareto front; center-sum dominates the original in this
run. Padded was the only finite-grid candidate in that first experiment.

All variants in the first experiment reserve a 65,536-byte work segment.
The padded layout uses 65,044
bytes of it; it still reads the prior frame from VGA and writes the next frame
to VGA. There are no hardware cycle, dynamic instruction, or bus-traffic
measurements in this result set.

Raw timing/build metadata and per-generation hashes are in
[`results/pentium.json`](results/pentium.json). Final source/build metadata and
the additional glider regressions are in
[`results/pentium.checks.json`](results/pentium.checks.json). Comments and debugger
labels were added after timing; the final tested boot/benchmark image hashes
match the timed images. The checks report corrects upstream payload metadata
to 355 bytes; the initial timing report used 510 because upstream has no
`payload_end` label.

## Two authoritative RAM grids

Both candidates passed five generations on all four inputs, normal boot and
timer pacing, no-injection operation, six glider boundary cases, and five
fixed-seed generations with sparks/gliders enabled. The two-RAM version also
passed with VGA overwritten before every generation; both RAM roles and their
halos matched the reference after every swap.

| Variant | Payload bytes | Reserved RAM | Median ms/gen | Median absolute deviation |
|---|---:|---:|---:|---:|
| Padded | 432 | 64 KiB | 135.00 | 1.76 |
| Dual-RAM | 479 | 128 KiB | 138.44 | 1.58 |

These are seven samples per candidate, 20 generations per sample, in shuffled
order under the same QEMU TCG/Pentium configuration. The previous demo was no
longer running. Padded has the better observed median, smaller payload, and
half the reserved RAM. The small timing difference and overlapping sample
ranges do not establish that dual-RAM is inherently slower on other targets.
It does not earn a place on this run's observed payload/RAM/time Pareto front.

Dual-RAM eliminates VGA reads and presents using `rep movsd`, but that alone
does not establish a runtime improvement. Rendering is included in the timing;
neither candidate provides synchronized or tear-free presentation.
Raw samples, image hashes, source/harness hashes, and the selection axes are in
[`results/pentium.finite-ram-comparison.json`](results/pentium.finite-ram-comparison.json).

## Direct dead-neighbor comparisons

`life.padded_deadcount.asm` keeps the same padded layout and VGA snapshot.
For each of the eight neighbors, `cmp byte [address], 0x80` sets carry when
the neighbor is dead. `adc bl, bh` accumulates that carry; `BH` remains zero
from the cell's initial `xor bx, bx`. Three live neighbors therefore mean
five dead neighbors, and two live neighbors mean six dead neighbors. The
existing color/age/fade transition remains unchanged.

This replaces three instructions per neighbor with two, removing 512,000
executed instructions from each full generation's neighbor-counting code.
That is a static control-flow count, not a measured guest instruction profile.
NASM also fits the shorter cell loop's back edge into a short jump.

| Variant | Payload bytes | Reserved RAM | Median ms/gen | Median absolute deviation |
|---|---:|---:|---:|---:|
| Padded | 432 | 64 KiB | 136.75 | 3.38 |
| Padded, dead-neighbor count | 414 | 64 KiB | 102.28 | 1.49 |

Both variants ran in the same shuffled seven-repetition experiment, with 20
generations per sample. Deadcount's samples ranged from 97.53 to 107.56 ms/gen;
padded's ranged from 132.59 to 157.77 ms/gen. The median reduction is 25.2%.
The complete boot sector remains 512 bytes; deadcount has 96 bytes of padding
before the signature. It dominates padded on this experiment's observed
payload/RAM/time axes.

Both passed the full checks described above. All per-generation output hashes
match between padded and deadcount, including fixed-seed normal operation with
both injection paths enabled. The final files match the recorded build and
harness hashes. Details are in
[`results/pentium.finite-deadcount-comparison.json`](results/pentium.finite-deadcount-comparison.json).

These two experiments each remeasure their padded baseline; do not combine
their sample sets. Timings cover one deterministic workload and one emulator
configuration. They do not establish the best design for real 386/486/P5 CPUs,
all input distributions, or minimum RAM. Cycle-aware profiling remains separate.

## Three-row buffers

The two first small-buffer implementations retain only the previous, current,
and next old rows. Each row has a dead byte on both sides. Before a VGA row is
overwritten, the following unmodified VGA row is copied into the cache. The
missing top and bottom rows are explicitly zeroed each generation. Rendering,
sparks, gliders, color behavior, and finite edges remain the same.

`rolling` uses three adjacent 322-byte rows (966 bytes total). Between output
rows, a forward overlapping copy shifts the cached current and next rows into
the previous and current positions. `ring` uses three 336-byte slots, including
14 alignment bytes per slot (1,008 bytes total). It rotates `DS`/`FS`/`GS` to
recycle the oldest slot, restoring `FS=0` before the timer or benchmark counter.
Neither implementation accesses the unused rest of its work segment for
storage. These counts are working buffers; BIOS, framebuffer, boot code, and
stack are additional memory common to the experiment.

| Variant | Payload bytes | Work buffer bytes | Median ms/gen | Median absolute deviation |
|---|---:|---:|---:|---:|
| Padded deadcount | 414 | 65,536 | 110.96 | 4.56 |
| Rolling, word copies | 470 | 966 | 119.63 | 4.51 |
| Rotating segments | 483 | 1,008 | 123.32 | 1.26 |

All three pass five generations on all four inputs, normal boot/pacing,
no-injection operation, six glider boundary cases, and seeded operation with
both injection paths enabled. The small-buffer tests check the cached old rows,
side halos, all unused work-segment bytes, and the ring's alignment padding.
They validate memory writes for the tested executions, not every possible
machine state or every memory read.

The 966-byte design cuts buffer RAM by 98.53%, with an observed 7.81% increase
in median time in this first comparison. Padded deadcount and rolling both
remain on the observed payload/RAM/time frontier. The rotating-segment version
does not: its code, buffer, and median time are all larger than rolling's in
this run. This does not establish how segment rotation would perform on real
x86 hardware.

Seven shuffled samples per candidate, 20 generations per sample, are recorded
in [`results/pentium.three-row-comparison.json`](results/pentium.three-row-comparison.json).

## Word versus dword cache copies

`rolling_dword` changes the 644-byte cache advance from `322 × movsw` to
`161 × movsd`. The forward overlap remains safe and the byte results are
identical. This costs one extra boot-code byte without changing buffer RAM.

| Variant | Payload bytes | Work buffer bytes | Median ms/gen | Median absolute deviation |
|---|---:|---:|---:|---:|
| Padded deadcount | 414 | 65,536 | 108.72 | 1.41 |
| Rolling, word copies | 470 | 966 | 115.25 | 1.67 |
| Rolling, dword copies | 471 | 966 | 115.40 | 1.23 |

All variants passed the full correctness suite again, and all recorded frame
hashes agree, including normal seeded operation with injections. The complete
images, benchmark images, and harness match the final report's hashes.

The dword-copy change did not establish a speed improvement. Its 0.16 ms/gen
median difference from word copies is smaller than either sample set's median
absolute deviation; word copies also use one less payload byte. Retain the
word-copy version as the low-RAM candidate. It leaves 40 bytes before the boot
signature and takes 6.0% more time than padded deadcount in this run. Padded
deadcount retains the better observed speed and smaller payload, while rolling
uses 98.53% less buffer RAM. Both remain on the observed frontier.

Seven shuffled samples per candidate, 20 generations per sample, are recorded
in [`results/pentium.three-row-dword-comparison.json`](results/pentium.three-row-dword-comparison.json).
Keep these historical timings separate from later runs. The planned horizontal
reuse and table experiments are now implemented and measured in
[Sliding windows and lookup tables](SLIDING_WINDOW.md).
