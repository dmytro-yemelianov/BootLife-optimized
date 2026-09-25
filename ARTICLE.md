# Optimizing BootLife inside a 512-byte boot sector

*Sliding windows, tiny rule tables, a three-row buffer—and the debugger effect that changed the results.*

BootLife turns a BIOS boot sector into a colored Conway’s Game of Life display.
The interesting constraint is not simply making Life run quickly: the complete
program, its constants, and the boot signature must fit in 512 bytes. The
experiment described here explored execution speed, working memory, and payload
size while retaining the original palette, cell aging, random activity, and
BIOS-paced animation.

The final result is a set of alternatives rather than one universal winner.
The smallest tested finite-grid implementation has a **408-byte payload**.
A three-row implementation needs just **966 bytes of work RAM**. The fastest
measured implementation updates a generation in **0.000779 seconds** under the
tested QEMU configuration, equivalent to about **1,284 updates per second**
without timer waits. The normal shipping demo remains paced at about **18.2 FPS**.

These are emulator measurements on an **Apple M5**, using **QEMU 11.0.1**, a
Pentium instruction-set model, and single-thread TCG. They are not physical
Pentium timings. An important part of this work was discovering and correcting
a large debugger-induced timing distortion.

![BootLife running in QEMU](article-assets/rolling-bits.png)

*The `rolling_bits` demo. The simulated field is 320×200 cells; the QEMU capture
shows its VGA output. Its small embedded table needs no additional work RAM.*

## Start with an explicit behavior contract

The starting point is [0xAX/BootLife at commit
`86dc8d9`](https://github.com/0xAX/BootLife/tree/86dc8d932db282097fd157e2c65051af7a3dd118).
At the time of preparing this article, `master` still resolved to that commit,
and its `life.asm` matched the local upstream copy byte for byte. The original
ISC license and copyright notice are preserved in every derived assembly file.

Each pixel is also a cell. Bit 7 of its byte says whether the cell is alive;
the remaining bits participate in the visible age and fading effect. Correctness
therefore requires matching all 64,000 output bytes, not just the binary pattern.
For an old color `c`, the next color is:

| Next Life state | Previously alive | Previously dead |
|---|---|---|
| Alive | `min(c + 6, 255)` | `128` |
| Dead | `127` | `max(c - 16, 0)` |

One intentional behavior change must be separated from optimization. The
upstream linear-address neighbor calculation connects cells across row seams.
The new finite-grid variants use permanently dead cells beyond all four edges.
Glider injection also checks the horizontal coordinate so a glider cannot
straddle two rows. These variants are not byte-identical replacements for the
upstream boundary behavior; adopting the topology change upstream is a design
decision for the maintainer.

The harness retains both reference models. The original and early legacy
candidates are checked against the original address semantics; the final
variants must pass the finite-grid reference. This prevents a faster program
with different boundary behavior from winning an invalid comparison.

## First simplify the cell calculation

The first legacy experiment summed all nine cells, including the center, so
there was no need to omit the center inside the counting loop. If `S` is that
live total, the next cell is alive when `S == 3`, or when `S == 4` and the center
was alive. This reduced the original 355-byte payload to 348 bytes, but retained
the original row seams. It is an archived experiment, not a final finite-grid
choice.

An unrolled kernel then replaced the nested neighbor loops with fixed memory
addresses. This removed loop administration at the cost of additional code.
The finite-grid version uses a **322×202** padded snapshot: a 320×200 interior
surrounded by a one-cell dead halo. It uses 65,044 bytes inside a reserved
65,536-byte segment. Fixed offsets now remain valid at every visible edge,
without a branch for each neighbor.

A useful instruction-level simplification came from counting **dead** neighbors:

```nasm
xor bx, bx                 ; BL = count, BH = zero
cmp byte [si - 323], 0x80  ; carry is set when the neighbor is dead
adc bl, bh
```

Repeat the comparison/add pair for all eight neighbors. Five dead neighbors
mean three live neighbors; six dead neighbors mean two live neighbors. This
replaced live-bit extraction with two instructions per neighbor and produced
`padded_deadcount`, the 414-byte finite-grid baseline used in the corrected
comparison below.

The finite variants also explicitly establish stack/interrupt and string-copy
state during startup. Optional `SEED`, `SPARKS`, and `GLIDERS` assembly settings
make deterministic validation possible. A zero spark count removes the spark
loop entirely instead of allowing a zero `LOOP` count to wrap.

## Replace the full snapshot with three rows

A generation needs the previous, current, and next rows. It does not need the
whole old field simultaneously if rows are processed in order.

The rolling implementation keeps three 322-byte rows, including their left and
right halos. Before overwriting a VGA row, it saves the next untouched row.
After completing the output row, it moves the cached current/next rows forward
and reuses the last slot. The missing rows above and below the field are zero.

This reduces the work buffer from **65,536 to 966 bytes**, a **98.53% reduction**.
The original rolling implementation occupies 470 payload bytes. The final
rolling variant with horizontal reuse occupies 467 bytes.

Other layouts were implemented too:

- **Dual RAM grids:** keep the authoritative state in RAM and copy the result to
  VGA. This reserves 128 KiB and uses a 479-byte payload.
- **Segment-rotated ring:** rotate three paragraph-aligned row slots using segment
  registers instead of moving row contents. This uses 1,008 work bytes and a
  483-byte payload.
- **Dword cache copies:** replace the rolling cache’s word copies with dword
  copies, using 471 payload bytes with the same 966-byte buffer.

They remain available as experiments. Their older timings were collected with
the debugger effect described below, and they were not included in the corrected
nine-variant timing run. That evidence does not justify a fresh performance
ranking for these three layouts.

## Reuse the horizontal window as well

For a fixed output row, let `C(x)` be the number of dead cells in a three-cell
vertical column. A 3×3 neighborhood can then be expressed as:

```text
    left       current       entering
   column       column        column
      |            |             |
    C(x-1)       C(x)          C(x+1)
         \         |          /
          D = C(x-1) + C(x) + C(x+1)
```

`DL` and `DH` cache the left and current totals. Moving one pixel to the right
requires reading only the three cells of the entering column. The totals then
shift forward. Each new row starts with a dead left halo, whose total is three.

Because `D` includes the center, the Life rule becomes:

```text
next_alive = (D == 6) or (D == 5 and old_color >= 128)
```

The counting work falls from 512,000 neighbor comparisons per generation to
192,600: three per pixel plus three to initialize each row. This is a static
instruction-path count, not a hardware counter measurement. Snapshot copies,
old-color reads, and VGA stores still have to happen.

Two implementations use this idea directly:

- [`life.sliding.asm`](final/life.sliding.asm): full padded snapshot, **408-byte
  payload**, 65,536 reserved work bytes.
- [`life.rolling_sliding.asm`](final/life.rolling_sliding.asm): three rolling rows,
  **467-byte payload**, 966 work bytes.

Sharing the work-segment setup between DS and ES, updating the random generator
in BP directly, and using the output offset to detect completion in the padded
version saved additional bytes. The payload reduction is real machine-code
reduction, not merely shorter source text.

## Two kinds of lookup table

### Generate a complete color transition table at startup

The next color depends on just two values: the total dead count `D` and the old
color byte. There are ten possible counts and 256 possible bytes:

```text
table[(D << 8) | old_color] = next_color
```

A **2,560-byte** table therefore replaces both the Life decision and all aging
and fading branches with a single lookup. It would not fit inside the boot
sector, so a short startup loop generates it in RAM at `0x8000..0x89ff`.
Construction is a one-time cost; it is included in startup measurements and
excluded from steady-state kernel measurements.

[`life.sliding_lut.asm`](final/life.sliding_lut.asm) combines the table with a full
snapshot: 431 payload bytes and 68,096 work bytes.
[`life.rolling_lut.asm`](final/life.rolling_lut.asm) combines it with the three-row
buffer: 490 payload bytes and **3,526 work bytes**.

### Embed the binary rule in only 64 bytes

A binary 3×3 neighborhood has 512 possibilities. Its next state needs only one
bit, so the complete rule occupies **64 bytes**.

The bit-table implementations keep a nine-bit neighborhood in BX. Three
`CMP`/`RCL` pairs shift in the entering column; masking retains nine bits.
`BT` reads the next state from a table generated by NASM. The original arithmetic
still computes the next color, because this table describes only the live/dead
rule.

`sliding_bits` uses 455 payload bytes and a full work segment. The supplied
[`rolling_bits`](final/life.rolling_bits.asm) uses only 966 work bytes, but fills
all **510 payload bytes** before the signature. To fit, it removes a redundant
zero-count branch under a compile-time positive spark count and simplifies one
palette expression. Its spark count is explicitly limited to 0..65535.
The palette equivalence was checked by reading all 768 VGA DAC components after
actual BIOS boot.

This is a useful compact-table demonstration, but it is not the preferred
low-RAM choice in the corrected run: `rolling_sliding` uses the same work RAM,
43 fewer payload bytes, and has a lower observed median generation time.
The bit-table version is included because it was built, tested, and demonstrated,
and a different CPU may change the tradeoff.

## Compute two colors before writing to VGA

[`life.sliding_lut_word.asm`](final/life.sliding_lut_word.asm) unrolls the table
kernel for two pixels. It keeps the first color in AH, computes the second,
orders the bytes, and writes both with `STOSW`. This halves the number of VGA
store instructions.

The payload grows from 431 to **473 bytes**, with the same 68,096 work bytes.
In the corrected comparison, it is **1.12× as fast** as the single-byte-store
version and **2.10× as fast** as `padded_deadcount`. These are throughput ratios
for the same finite-grid workload, not comparisons against the upstream program
with its different boundary semantics.

## The debugger changed the apparent answer

The first timing harness stopped at a label inside the boot sector after a
batch of generations. Although it stopped only once per batch, that breakpoint
was on the same code page as the kernel. QEMU ran this workload much more slowly.

A controlled experiment kept the same seeded workload and external observer,
then added one never-executed breakpoint at `0x7dff`:

| Variant | Without boot-page breakpoint, s/gen | With breakpoint, s/gen |
|---|---:|---:|
| padded_deadcount | 0.001634 | 0.067959 |
| rolling_lut | 0.001143 | 0.033110 |
| rolling_bits | 0.001402 | 0.036850 |

The experiment establishes the effect in this configuration; it does not claim
a universal debugger overhead or a hardware pipeline explanation.

The corrected harness removes all breakpoints from the boot-code page during
timing. After the final generation, execution jumps to a breakpoint at `0x9000`.
No per-frame debugger round trip is required. Every timed final framebuffer is
still compared with the independent reference.

This correction changed both the absolute timings and the ranking. Earlier
claims of roughly 17 unpaced FPS and a 1.95× improvement are superseded. The
initial conclusion that paired VGA stores were slower is also superseded:
they are the fastest measured implementation in the corrected run.

## Corrected results and the final choices

The following is one shared run: seven shuffled repetitions per candidate,
20 generations per sample, the same arbitrary-byte input, no random injections
or timer waits, and interrupts disabled during kernel work. Snapshotting,
computation, color updates, and VGA writes are all included. BIOS startup,
input transfer, and output checking are outside the timed interval.

“Payload” includes embedded tables but excludes padding and the signature.
Every complete image is **512 bytes**. Work RAM excludes the common framebuffer,
boot image, and stack. Equivalent FPS is the reciprocal of median generation
time; it is not a monitor presentation rate.

| Variant | Payload, B | Work RAM, B | Seconds/generation | Equivalent FPS |
|---|---:|---:|---:|---:|
| padded_deadcount | 414 | 65,536 | 0.001632 | 612.7 |
| rolling | 470 | 966 | 0.001898 | 526.9 |
| sliding | **408** | 65,536 | 0.001029 | 972.2 |
| rolling_sliding | 467 | **966** | 0.001310 | 763.4 |
| sliding_lut | 431 | 68,096 | 0.000875 | 1142.2 |
| rolling_lut | 490 | 3,526 | 0.001133 | 882.5 |
| sliding_bits | 455 | 65,536 | 0.001115 | 896.6 |
| sliding_lut_word | 473 | 68,096 | **0.000779** | **1284.4** |
| rolling_bits | 510 | **966** | 0.001365 | 732.4 |

The final directory supplies these five tradeoffs plus the tested bit-table demo:

| Priority | Source | Matching boot image |
|---|---|---|
| Smallest finite-grid payload | [sliding](final/life.sliding.asm) | [sliding.img](final/sliding.img) |
| Smallest work buffer, with code space left | [rolling_sliding](final/life.rolling_sliding.asm) | [rolling_sliding.img](final/rolling_sliding.img) |
| Low-RAM color-table version | [rolling_lut](final/life.rolling_lut.asm) | [rolling_lut.img](final/rolling_lut.img) |
| Fast table kernel with a smaller payload | [sliding_lut](final/life.sliding_lut.asm) | [sliding_lut.img](final/sliding_lut.img) |
| Fastest observed kernel | [sliding_lut_word](final/life.sliding_lut_word.asm) | [sliding_lut_word.img](final/sliding_lut_word.img) |
| Embedded bit-table demonstration | [rolling_bits](final/life.rolling_bits.asm) | [rolling_bits.img](final/rolling_bits.img) |

“Smallest” and “fastest” refer to the tested finite-grid candidates. The smaller
upstream and legacy payloads have different edge semantics. No global optimum
or physical-Pentium speed record is claimed.

## Frame rate and time to the first frame

The shipping programs retain the original BIOS wait after completing a frame.
For the tested seeded demos, this produces approximately **0.055 seconds per
frame**, or **18.2 FPS**, despite much higher unpaced throughput.

Startup was measured separately with a fixed seed, five fresh QEMU processes
per measurement, and no intermediate debugger stops. The observer is outside
the boot-code page. The first evolved frame includes a complete Life update
and enabled injections, but ends before its subsequent timer wait.

| Variant | Reset → initial seeded frame, s | Reset → first evolved frame, s | Process launch/setup → first evolved frame, s |
|---|---:|---:|---:|
| padded_deadcount | 0.059552 | 0.060481 | 0.087270 |
| rolling_lut | 0.057705 | 0.057672 | 0.084936 |
| rolling_bits | 0.058703 | 0.060998 | 0.087140 |

Each milestone uses independent runs, so subtracting these medians does not
measure kernel time; small reversals are sampling variation. Reset-to-frame
includes BIOS, mode setting, palette, table/buffer setup, and seeding.
Process-launch figures additionally include debugger setup. The tests are
headless and measure a complete VGA memory image, not the first visible scanout
in a desktop window. Startup was not separately measured for every final variant.

## Verification and reproducibility

The harness assembles real boot images, boots them through BIOS, and observes
VGA memory through QEMU’s GDB interface. Its checks cover:

- Every output byte for five generations on arbitrary color bytes, an empty
  field, an all-live field, and edge/oscillator/glider fixtures.
- Dead halos, untouched work/VGA tails, guard regions, and exact cached old rows.
- Normal paced operation, production builds without injections, and seeded
  builds with both sparks and gliders enabled.
- Six glider-placement cases around the last valid and first invalid rows and
  columns, including an origin beyond the framebuffer.
- All 512 embedded rule bits and all 2,560 generated color-table entries,
  plus table immutability and surrounding guards.
- Actual VGA palette bytes for the baseline, the palette-shortened bit-table
  implementation, and the paired-write implementation.

The corrected timing run reused earlier full checks only after all five build
configurations’ image hashes, source hashes, and flags matched. It independently
checked every newly timed final frame. The release also includes a clean-copy
verification report. Exact payload sizes, source/image hashes, and raw samples
are retained; historical reports are not silently rewritten.

There is also a source-density experiment:
[`life.rolling.compact.asm`](life.rolling.compact.asm) groups instructions with a
NASM macro. It reduces the displayed source from 276 to 135 lines, but makes
the text file slightly larger. Six configurations assemble byte for byte to the
original rolling image. This changes presentation, not binary size or speed.

Build and run a final version with NASM and QEMU:

```sh
nasm -f bin -o life.img final/life.sliding_lut_word.asm
qemu-system-i386 -cpu pentium -drive file=life.img,format=raw,if=floppy
```

For the smaller work buffer, substitute `final/life.rolling_sliding.asm`.
To reproduce checks and corrected timing from the extracted package root:

```sh
python3.13 experiment.py --cpu pentium --variants sliding rolling_sliding sliding_lut rolling_lut sliding_lut_word rolling_bits --generations 5 --benchmark-generations 20 --repetitions 7
python3.13 measure_latency.py
python3.13 check_palette.py
```

Default images use `RDTSC` for seeding and need a supporting CPU. A specified
`-DSEED=0x1234` removes that instruction; the implementations still use 386-era
instructions and segment registers, so they are not original-8086 programs.
`-DSPARKS=0 -DGLIDERS=0` disables injections. All supplied production images
retain timer pacing; the external timing observers are not shipped inside them.

The package is self-contained: the early assembly candidates are included in
`legacy/`, so the harness no longer depends on the separate handover archive.
Recorded historical harness hashes identify the versions used for those runs;
the release manifest identifies the portable packaged version.

## Contributing this work upstream

BootLife’s [contribution guide](https://github.com/0xAX/BootLife/blob/master/CONTRIBUTING.md)
permits a direct PR, asks contributors to work from an updated fork rebased on
`master`, explain their changes, link a related issue when applicable, and
address maintainer feedback. It does not require opening an issue first or
prescribe an article format.

A reviewable contribution should separate the finite-boundary behavior decision
from the optimization choices. The package’s [contribution notes](CONTRIBUTION_NOTES.md)
provide a proposed explanation and validation commands. The included final files
are alternatives for review, not a request to replace upstream with six entry
points at once.

## What remains worth testing

Table-driven Life is established practice. [Alan Hensel’s algorithm
notes](https://www.ibiblio.org/lifepatterns/lifeapplet.html) describe looking up a
4×4 block to compute its inner 2×2 cells. [Golly’s rule
documentation](https://golly.sourceforge.io/Help/Algorithms/QuickLife.html)
describes the 512 binary 3×3 neighborhoods underlying the small table here.

A 4×4-to-2×2 table needs 65,536 four-bit results: 32 KiB packed, or 64 KiB using
one byte per result. Constructing its index, retaining the color updates, and
fitting the generator in a boot sector still need measurement. Bit-parallel
updates are another candidate, but conversion and aging costs matter for byte
pixels. Region skipping must account for colors still aging or fading, not
just stable live/dead shapes.

Physical x86 measurements remain the most important missing evidence before
making CPU-specific claims. Within this experiment, the useful result is a
reproducible set of tradeoffs—and a timing method that no longer mistakes a
debugger effect for the cost of the algorithm.

### Evidence

- [Corrected kernel timings and validation provenance](results/pentium.external-stop.json)
- [Startup, pacing, and debugger A/B measurements](results/pentium.latency.json)
- [VGA palette verification](results/sliding-palette-check.json)
- [Source-density equivalence checks](results/compact-source-check.json)
- [Frame-time methodology](LATENCY.md)
- [Final source/image manifest](final/MANIFEST.json)
- [Clean-copy release verification](results/release-verification.json)
