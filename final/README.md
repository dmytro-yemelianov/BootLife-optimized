# Final BootLife versions

All supplied `.img` files are complete 512-byte BIOS boot sectors. Each `.asm`
file is standalone NASM source, with the original ISC notice. Every final binary
matches the image hash in the corrected benchmark report. These are finite
dead-border variants; their edge behavior intentionally differs from upstream.

| Priority | Standalone source | Ready image | Payload, B | Work RAM, B | Kernel seconds/generation |
|---|---|---|---:|---:|---:|
| Smallest finite-grid payload | [sliding](life.sliding.asm) | [sliding.img](sliding.img) | 408 | 65,536 | 0.001029 |
| Preferred low-RAM version | [rolling_sliding](life.rolling_sliding.asm) | [rolling_sliding.img](rolling_sliding.img) | 467 | 966 | 0.001310 |
| Low-RAM color table | [rolling_lut](life.rolling_lut.asm) | [rolling_lut.img](rolling_lut.img) | 490 | 3,526 | 0.001133 |
| Fast table with smaller payload | [sliding_lut](life.sliding_lut.asm) | [sliding_lut.img](sliding_lut.img) | 431 | 68,096 | 0.000875 |
| Fastest observed kernel | [sliding_lut_word](life.sliding_lut_word.asm) | [sliding_lut_word.img](sliding_lut_word.img) | 473 | 68,096 | 0.000779 |
| Embedded bit-table demonstration | [rolling_bits](life.rolling_bits.asm) | [rolling_bits.img](rolling_bits.img) | 510 | 966 | 0.001365 |

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
