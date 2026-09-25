#!/usr/bin/env python3
"""Read the actual VGA DAC after BIOS boot; verify palette-preserving size edits."""
import json
import subprocess

from experiment import BUILD, Guest, assemble, digest, SOURCES


def main():
    BUILD.mkdir(exist_ok=True)
    probe = BUILD / 'read_palette.asm'
    probe.write_text('''bits 16
org 0x9000
    cli
    cld
    xor ax, ax
    mov es, ax
    mov di, 0x9100
    mov dx, 0x3c7
    out dx, al
    mov dx, 0x3c9
    mov cx, 768
.read:
    in al, dx
    stosb
    loop .read
.done:
    hlt
    jmp .done
''')
    binary = probe.with_suffix('.bin')
    subprocess.run(['nasm', '-f', 'bin', '-o', str(binary), str(probe)], check=True)
    code = binary.read_bytes()
    expected = bytearray()
    for color in range(256):
        if color < 128:
            rgb = (color >> 4, color >> 5, (color >> 2) + (color >> 4))
        else:
            age = color - 128
            rgb = (age >> 1, (age >> 2) + 44, (age >> 1) + 16)
        expected.extend(min(component, 63) for component in rgb)
    results = {}
    for name in ('padded_deadcount', 'rolling_bits', 'sliding_lut_word'):
        artifact = assemble(name + '_palette_check', SOURCES[name].read_text(), ['-DSEED=0x1234'])
        with Guest(artifact, 'pentium') as guest:
            guest.boot()
            # The boot image has already set the palette. Only the observer is injected.
            guest.write(0x9000, code)
            registers = bytearray.fromhex(guest.request('g'))
            cs = int.from_bytes(registers[40:44], 'little')
            registers[32:36] = (0x9000 - (cs << 4)).to_bytes(4, 'little')
            assert guest.request('G' + registers.hex()) == 'OK'
            guest.stopped = False
            guest.breakpoint(0x9000 + len(code) - 3)
            guest.resume()
            palette = guest.read(0x9100, 768)
            assert palette == expected, name
        results[name] = {'pass': True, 'dac_sha256': digest(palette),
                         'source_sha256': artifact['source_sha256'],
                         'image_sha256': artifact['sha256']}
        print(f'PASS {name}: all 768 VGA DAC components match')
    path = BUILD.parent / 'results/sliding-palette-check.json'
    path.write_text(json.dumps({'cpu': 'pentium', 'results': results}, indent=2) + '\n')


if __name__ == '__main__':
    main()
