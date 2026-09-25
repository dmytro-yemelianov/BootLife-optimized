# Frame time, FPS, and startup — 2026-09-25

These measurements use QEMU 11.0.1, a Pentium instruction-set model, single-thread
TCG, and an **Apple M5** host. They do not predict a physical Pentium's speed.
All durations are host wall **seconds**. FPS here means completed generations
with a full VGA memory update; the headless test has no window compositor or
monitor scanout, so these are not screen presentation timestamps.

## Correction to the earlier timing reports

The earlier benchmark placed its final breakpoint in the same 4 KiB code page
as the Life kernel. A controlled A/B experiment now shows that even a
never-executed breakpoint at `0x7dff` substantially slows QEMU in this workload.
Consequently, the earlier 0.058-second figure and its approximately 17-FPS
reciprocal describe the debugger-affected run, not the normal demo's capacity.
The earlier approximately 1.95× speedup and paired-write ranking are also not
reliable estimates of normal execution. Their raw reports remain as history.

The corrected benchmark has **no breakpoints on the boot-code page while the
batch executes**. Only after the last complete frame does it jump to a stop at
`0x9000`. The assembly algorithms and shipping boot-sector bytes are unchanged.
The benchmark also emits `median_seconds_per_generation` and
`equivalent_fps_from_median_period`, while retaining its legacy millisecond
fields for compatibility.

## Demo measurements

Five fresh-QEMU repetitions per variant and measurement, shuffled order; a fixed
seed of `0x1234`, six sparks and gliders enabled. Each batch measures 20 complete
generations after one warmup generation, and its final framebuffer must match
the independent byte-level Life/injection reference.

- **Unpaced update:** the normal seeded demo cycle with only the timer wait
  bypassed. Interrupts, injections, color aging, copies, and VGA writes remain.
- **Paced demo:** the original timer wait is retained. The loop waits for the
  next BIOS tick after finishing work, which currently determines the frame rate.
- **Seed frame:** the first fully populated initial VGA image, before evolution.
- **First evolved frame:** the first complete Life update, including injections,
  before its timer wait.
- **From CPU reset:** includes BIOS, mode setting, palette, RAM/table setup,
  seeding, and (where applicable) the first update. Excludes QEMU process launch
  and debugger setup. Startup samples run without intermediate stops.
- **From process launch:** also includes QEMU launch and test/debugger setup,
  so this is a harness launch latency, not an exact GUI launch measurement.

For startup only, a three-byte jump at the measurement boundary routes to the
external breakpoint. All code executed before that boundary is unchanged. For
batches, an external DEC/Jcc/JMP counter runs once per frame after the original
back edge; there are no per-frame debugger round trips. These observers are
not added to the shipping 512-byte images.

| Variant | Update without wait, s | Equivalent FPS | Paced period, s | Paced FPS |
|---|---:|---:|---:|---:|
| padded_deadcount | 0.001634 | 611.9 | 0.054894 | 18.22 |
| rolling_lut | 0.001143 | 875.2 | 0.054974 | 18.19 |
| rolling_bits | 0.001402 | 713.3 | 0.054914 | 18.21 |

| Variant | Reset → seed frame, s | Reset → first evolved frame, s | Launch/setup → first evolved frame, s |
|---|---:|---:|---:|
| padded_deadcount | 0.059552 | 0.060481 | 0.087270 |
| rolling_lut | 0.057705 | 0.057672 | 0.084936 |
| rolling_bits | 0.058703 | 0.060998 | 0.087140 |

Startup milestones use independent fresh processes; do not subtract their
medians to estimate kernel time. For example, a tiny reversal between seed and
first-evolved medians is sample variation, not a negative update duration.

The debugger control uses the same seeded workload and observer, adding only
a never-executed breakpoint on the boot-code page:

| Variant | No boot-page breakpoint, s/gen | With breakpoint, s/gen |
|---|---:|---:|
| padded_deadcount | 0.001634 | 0.067959 |
| rolling_lut | 0.001143 | 0.033110 |
| rolling_bits | 0.001402 | 0.036850 |

All timed and startup frame bytes matched the reference. Raw samples, image
hashes, observer details, and environment metadata:
[`pentium.latency.json`](results/pentium.latency.json).

## Corrected kernel comparison

Seven shuffled repetitions, 20 arbitrary-byte-corpus generations per sample,
without injections or timer waits; the stop is on a separate code page. Every
new timed final framebuffer matches the independent reference. Earlier full
correctness checks were reused only after all five image hashes, source hashes,
and NASM flags matched; the report records that provenance.

| Variant | Payload bytes | Work RAM bytes | Seconds/generation | Equivalent FPS |
|---|---:|---:|---:|---:|
| padded_deadcount | 414 | 65,536 | 0.001632 | 612.7 |
| rolling | 470 | 966 | 0.001898 | 526.9 |
| sliding | 408 | 65,536 | 0.001029 | 972.2 |
| rolling_sliding | 467 | 966 | 0.001310 | 763.4 |
| sliding_lut | 431 | 68,096 | 0.000875 | 1142.2 |
| rolling_lut | 490 | 3,526 | 0.001133 | 882.5 |
| sliding_bits | 455 | 65,536 | 0.001115 | 896.6 |
| sliding_lut_word | 473 | 68,096 | 0.000779 | 1284.4 |
| rolling_bits | 510 | 966 | 0.001365 | 732.4 |

The corrected rolling_lut improvement over padded_deadcount is 1.44× in this
workload. Paired VGA writes now **do win**: 1.12× the byte-write table variant,
with the fastest observed median at 0.000779 seconds/generation. That version
uses 68,096 bytes of work RAM, versus 3,526 for rolling_lut and 966 for
rolling_bits. The result supersedes the previous debugger-affected ranking.

Raw samples, checked output hashes, build metadata, and validation provenance:
[`pentium.external-stop.json`](results/pentium.external-stop.json).

## Reproduce

```sh
python3.13 bootlife/measure_latency.py
python3.13 bootlife/experiment.py --cpu pentium --variants padded_deadcount rolling sliding rolling_sliding sliding_lut rolling_lut sliding_bits sliding_lut_word rolling_bits --generations 5 --benchmark-generations 20 --repetitions 7 --output bootlife/results/pentium.external-stop.json
```

The second command uses the existing arbitrary-byte corpus without injections
or pacing; its workload differs from the seeded demo above. Keep their results
separate. Neither raw throughput nor BIOS-paced generation rate implies
tear-free display or a particular physical monitor refresh rate.
