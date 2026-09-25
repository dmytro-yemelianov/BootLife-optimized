# Sliding windows and lookup tables — 2026-09-25

**Timing correction:** the original measurements below were slowed by a
breakpoint on the boot-code page. They are retained as historical records,
not as estimates of normal demo throughput. See [corrected seconds, FPS, startup,
and the breakpoint A/B test](LATENCY.md). The corrected comparison finds paired
VGA writes fastest; the previous negative result and approximately 1.95× claim
are superseded.


The previous speed/size choice was `padded_deadcount` (414-byte payload).
The previous low-RAM choice was `rolling` (470-byte payload, 966-byte buffer).
This experiment preserves the finite 320×200 topology, complete byte colors,
palette, seeding, sparks, gliders, and BIOS timer pacing.

Every production image is still **512 bytes**, including the `55 aa` signature.
“Payload” below includes embedded tables, but excludes zero padding and the
signature. Work RAM excludes the framebuffer, boot image, and common stack.

## Horizontal reuse

For each column, let `c(x)` count dead cells in the three vertically adjacent
positions. Cache the left and current counts in `DL` and `DH`. When advancing
one pixel, load only the three cells entering on the right:

```text
D = c(x-1) + c(x) + c(x+1)       # includes the center
next_alive = D == 6 or (D == 5 and old_color >= 128)
```

The missing left column starts with count 3. Initialize the current column at
each row boundary, then shift the cached counts after every cell. The vertical
halo or three-row buffer handles the top and bottom edges.

This changes neighbor-count comparisons from 512,000 to 192,600 per generation
(three per pixel, plus three per row). This is a static instruction-path count,
not a hardware performance-counter measurement; color reads, buffer copies, and
VGA writes still remain.

`life.sliding.asm` uses the full padded snapshot. `life.rolling_sliding.asm`
combines the same horizontal reuse with the existing 966-byte rolling buffer.
Startup shares the `WORK` segment load between DS and ES; the LCG updates BP
in place; the padded variant detects frame completion using the output offset.
These changes reduce the final payloads to 408 and 467 bytes respectively.

## Two different tables

### Complete color transition: 2,560 bytes in RAM

`life.sliding_lut.asm` and `life.rolling_lut.asm` generate a table at boot:

```text
table[D * 256 + old_color] = next_color
```

There are ten possible total-dead counts and 256 colors. The table contains the
Life decision and the exact saturated aging/fading behavior. A single lookup
replaces the decision and color branches in the hot loop. Table construction
uses a short loop in the boot sector, rather than embedding 2,560 bytes there.
Construction happens only at startup and is outside steady-state timings.

The table occupies physical `0x8000..0x89ff`, using GS=`0x0800`. It adds exactly
2,560 bytes to the work reservation: 68,096 bytes for the padded variant or
3,526 bytes for the rolling variant. The framebuffer remains authoritative;
there is no extra full output framebuffer.

### Complete binary rule: 64 bytes inside the boot sector

`life.sliding_bits.asm` and `life.rolling_bits.asm` retain a 9-bit neighborhood
in BX. Each step shifts in three dead/alive bits from the new right column,
then masks to nine bits. NASM constructs all 512 output bits at assembly time.
`BT [fs:rule_bits], bx` retrieves the next live state; the usual arithmetic
still updates the byte color. FS=0 makes the ORG-based address independent of
the BIOS entry CS convention.

This table consumes 64 payload bytes and no additional work RAM. `rolling_bits`
fits exactly: 510 bytes of payload plus the signature. It saves two bytes by
omitting a redundant zero-count jump inside `%if SPARKS > 0`, and two more by
simplifying the live blue palette calculation. Its SPARKS count is explicitly
restricted to 0..65535. For live colors 128..255,
`(color >> 1) - 48` equals `((color & 127) >> 1) + 16`; saturation is unchanged.

## Historical comparison — affected by debugger breakpoint

Seven shuffled samples per variant, 20 generations per sample; QEMU TCG,
Pentium model, macOS ARM64 host. Numbers are **host wall milliseconds per
generation**, not Pentium cycles or paced demo FPS. BIOS startup, table
construction, input transfer, and output checks are excluded; snapshot, complete
cell update, and VGA presentation are included. Samples have noticeable host
variance, so small differences do not establish a portable ranking.

| Variant | Payload bytes | Work RAM bytes | Median ms/gen | MAD |
|---|---:|---:|---:|---:|
| padded_deadcount | 414 | 65,536 | 110.848 | 3.418 |
| rolling | 470 | 966 | 116.541 | 1.866 |
| sliding | 408 | 65,536 | 93.308 | 2.326 |
| rolling_sliding | 467 | 966 | 93.201 | 2.880 |
| sliding_lut | 431 | 68,096 | 60.000 | 3.438 |
| rolling_lut | 490 | 3,526 | 56.979 | 0.972 |
| sliding_bits | 455 | 65,536 | 58.756 | 1.630 |

In this shared run, rolling_lut takes 48.6% less time than padded_deadcount
(1.95× throughput). Pure sliding takes 15.8% less time and saves six payload
bytes; rolling_sliding takes 20.0% less time than rolling and saves three bytes.
The full and bit tables have overlapping timing ranges. These are observed
tradeoffs, not a proof of optimality.

Raw samples, build/source hashes, and correctness results:
[`pentium.sliding-final.json`](results/pentium.sliding-final.json).
The earlier [`pentium.sliding-comparison.json`](results/pentium.sliding-comparison.json)
is an exploratory run before the final code-size edits; do not combine its
samples or build hashes with the final source.

## Historical follow-up — affected by debugger breakpoint

`life.sliding_lut_word.asm` unrolls the table kernel for two pixels, keeps the
first color in AH, and writes both using STOSW. This halves the number of VGA
store instructions, while retaining the same pixel bytes and finite edges.
`rolling_bits` tests the 64-byte table with the smallest existing row buffer.
Both are compared against unchanged sliding_lut and rolling_lut in a separate
shared seven-sample, 20-generation run:

| Variant | Payload bytes | Work RAM bytes | Median ms/gen | MAD |
|---|---:|---:|---:|---:|
| sliding_lut | 431 | 68,096 | 58.201 | 0.301 |
| rolling_lut | 490 | 3,526 | 57.535 | 0.781 |
| sliding_lut_word | 473 | 68,096 | 61.486 | 0.625 |
| rolling_bits | 510 | 966 | 58.652 | 1.247 |

In this debugger-affected run, paired VGA writes did not win: their median is 5.6% slower than the byte
version and the payload grows by 42 bytes. This conclusion is superseded by the corrected
measurement, where paired writes are faster. The breakpoint location distorted
the ranking as well as the absolute time.

The two rolling table variants had close timings in this debugger-affected
run. Use the corrected comparison for selection; it distinguishes their speed. `rolling_bits` is
the practical choice when 966 bytes of work RAM matters and a completely full
boot sector is acceptable. `rolling_lut` leaves 20 bytes free before the
signature and uses 3,526 bytes of work RAM. `sliding` remains the smallest
payload among the tested finite-grid variants, at 408 bytes.

Raw samples and checks:
[`pentium.sliding-table-followup.json`](results/pentium.sliding-table-followup.json).
Do not pool its timings with the main run. Palette results are in
[`sliding-palette-check.json`](results/sliding-palette-check.json).

## Validation and reproduction

Every new variant passes the actual BIOS-booted machine-code suite: four
64,000-byte inputs over five generations, all byte colors, finite borders,
work/VGA guards, cache/halo integrity, normal timer pacing, no-injection
production operation, six glider-boundary cases, and five fixed-seed frames
with both injection paths enabled. Every timed batch also checks its final
frame against the independent reference.

The harness additionally verifies all 512 embedded rule bits, all 2,560 runtime
table entries, table immutability, and guards before and after the RAM table.
`check_palette.py` reads all 768 actual VGA DAC components using an injected
observer after BIOS boot, comparing the palette to its mathematical reference.
The observer is separate from the production boot images and timings.

```sh
python3.13 bootlife/experiment.py --cpu pentium --variants padded_deadcount rolling sliding rolling_sliding sliding_lut rolling_lut sliding_bits --generations 5 --benchmark-generations 20 --repetitions 7 --output bootlife/results/pentium.sliding-final.json
python3.13 bootlife/experiment.py --cpu pentium --variants sliding_lut rolling_lut sliding_lut_word rolling_bits --generations 5 --benchmark-generations 20 --repetitions 7 --output bootlife/results/pentium.sliding-table-followup.json
python3.13 bootlife/check_palette.py
```

Images without an explicit SEED still use RDTSC and require a supporting CPU.
The results do not claim original 8086 compatibility. The tested CPU model is
Pentium; there are no physical x86 timings yet.

## Related work and remaining directions

Table-driven Life is established practice. [Alan Hensel's own algorithm
notes](https://www.ibiblio.org/lifepatterns/lifeapplet.html) describe looking up
4×4 blocks to compute their central 2×2 cells, plus skipping empty or dormant
blocks. [Golly's rule documentation](https://golly.sourceforge.io/Help/Algorithms/QuickLife.html)
explains the 512 possible binary 3×3 neighborhoods. The compact rule table here
uses that exhaustive neighborhood space, with dead bits and our chosen ordering.

Further candidates, **not established wins for this boot sector**:

- A 4×4 → 2×2 table computes four outputs per lookup. Its 65,536 four-bit results
  need 32 KiB packed, or 64 KiB at one byte per entry. Runtime generation,
  neighborhood assembly, and the separate color updates must all fit the
  sector and be measured; Hensel's larger engine does not prove a win here.
- Bit-parallel Life can update many binary cells per operation, but retaining
  byte colors adds packing and aging work. It needs a separate measured design.
- Skip regions only when both Life state and displayed colors are stable.
  A still-life shape alone is insufficient because aging/fading continues.
- Measure on physical target hardware or a cycle-accurate model before choosing
  instruction schedules or claiming Pentium-specific speedups. TCG host timing
  cannot resolve pipeline pairing, real VGA bus behavior, or hardware cache cost.
