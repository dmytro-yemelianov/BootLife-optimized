; Finite grid with three rolling 322-byte rows and dead-neighbor counting.
; Derived from the handover hot-loop candidate; retains the age/fade palette.
; Unrolled hot-loop candidate derived from 0xAX/BootLife life.asm,
; commit 86dc8d932db282097fd157e2c65051af7a3dd118; comments condensed.
; Copyright 2026 Alex Kuleshov <kuleshovmail@gmail.com>
; Permission to use, copy, modify, and/or distribute this software for
; any purpose with or without fee is hereby granted, provided that the
; above copyright notice and this permission notice appear in all copies.
;
; THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
; WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
; WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
; AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
; DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
; PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
; TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
; PERFORMANCE OF THIS SOFTWARE.
; Compact instruction lists: each braced argument expands to one ASM line.
%macro seq 1-*
    %rep %0
        %1
        %rotate 1
    %endrep
%endmacro
bits 16
org 0x7c00
WORK equ 0x1000
; Only offsets 0..965 are used: previous/current/next rows, each with two halos.
; Before replacing a VGA row, snapshot the following row, then roll the cache.
CELLS equ 64000
VID equ 0xa000
%ifndef SPARKS
%define SPARKS 6
%endif
%ifndef GLIDERS
%define GLIDERS 1
%endif
TICK equ 0x046c
start:
    seq {cli}, {xor ax, ax}, {mov ss, ax}, {mov sp, 0x7000}, {sti}
    seq {mov fs, ax}, {mov ax, 0x0013}, {int 0x10}, {cld}, {mov dx, 0x3c8}
    seq {xor al, al}, {out dx, al}, {inc dx}, {xor bx, bx}
.pal:
    seq {mov al, bl}, {or al, al}, {js .live}, {shr al, 4}, {call pout}
    seq {mov al, bl}, {shr al, 5}, {call pout}, {mov al, bl}, {shr al, 2}
    seq {mov ah, bl}, {shr ah, 4}, {add al, ah}, {call pout}, {jmp .next}
.live:
    seq {and al, 0x7f}, {shr al, 1}, {call pout}, {mov al, bl}, {and al, 0x7f}
    seq {shr al, 2}, {add al, 44}, {call pout}, {mov al, bl}, {and al, 0x7f}
    seq {shr al, 1}, {add al, 16}, {call pout}
.next:
    seq {inc bl}, {jnz .pal}, {mov ax, WORK}, {mov es, ax}, {xor di, di}
    seq {xor ax, ax}, {mov cx, 966 / 2}, {rep stosw}, {mov ax, WORK}, {mov ds, ax}
    seq {mov ax, VID}, {mov es, ax}
%ifdef SEED
    seq {mov bp, SEED}
%else
    seq {rdtsc}, {mov bp, ax}
%endif
    seq {xor di, di}, {mov cx, CELLS}
.seed:
    seq {call rnd}, {mov al, ah}, {and al, 0x80}, {stosb}, {loop .seed}
generation:
    ; Reset the missing row above y=0; side halos were cleared at startup.
    seq {push es}, {push ds}, {pop es}, {xor di, di}, {xor ax, ax}
    seq {mov cx, 322 / 2}, {rep stosw}, {pop es}
    ; Load the first current row. DS=work and ES=VGA outside copies.
    seq {push ds}, {push es}, {pop ds}, {pop es}, {xor si, si}
    seq {mov di, 323}, {mov cx, 320 / 4}, {rep movsd}, {push ds}, {push es}
    seq {pop ds}, {pop es}, {xor di, di}
.row:
    ; Preserve the output offset while snapshotting the unmodified next row.
    seq {push di}, {mov si, di}, {add si, 320}, {push ds}, {push es}
    seq {pop ds}, {pop es}, {mov di, 645}, {mov cx, 320 / 4}, {cmp si, CELLS}
    seq {jae .bottom}, {rep movsd}, {jmp .loaded}
.bottom:
    ; At y=199, the missing lower row is permanently dead for this frame.
    seq {xor eax, eax}, {rep stosd}
.loaded:
    seq {push ds}, {push es}, {pop ds}, {pop es}, {pop di}
    seq {mov si, 323}, {mov cx, 320}
.cell:
    seq {xor bx, bx}, {cmp byte [si -323], 0x80}, {adc bl, bh}, {cmp byte [si -322], 0x80}, {adc bl, bh}
    seq {cmp byte [si -321], 0x80}, {adc bl, bh}, {cmp byte [si -1], 0x80}, {adc bl, bh}
    seq {cmp byte [si +1], 0x80}, {adc bl, bh}, {cmp byte [si +321], 0x80}, {adc bl, bh}
    seq {cmp byte [si +322], 0x80}, {adc bl, bh}, {cmp byte [si +323], 0x80}, {adc bl, bh}, {mov al, [si]}
    ; BH stays zero; BL = dead neighbors. Live counts 3/2 mean dead counts 5/6.
    seq {cmp bl, 5}, {je .on}, {cmp bl, 6}, {jne .off}, {or al, al}
    seq {jns .off}
.on:
    seq {or al, al}, {js .age}, {mov al, 0x80}, {jmp .store}
.off:
    seq {or al, al}, {jns .fade}, {mov al, 0x7f}, {jmp .store}
.age:
    seq {add al, 6}, {jnc .store}, {mov al, 0xff}, {jmp .store}
.fade:
    seq {sub al, 16}, {jnc .store}, {xor al, al}
.store:
    seq {stosb}, {inc si}, {dec cx}, {jnz .cell}, {cmp di, CELLS}
    seq {je .complete}
    ; Forward overlapping copy: old current/next become previous/current.
    seq {push es}, {push ds}, {pop es}, {push di}, {mov si, 322}
    seq {xor di, di}, {mov cx, 644 / 2}, {rep movsw}, {pop di}, {pop es}
    seq {jmp .row}
.complete:
%if SPARKS > 0
    seq {mov cx, SPARKS}, {jcxz .sparks_done}
.spark:
    seq {call rnd}, {mov di, ax}, {cmp di, CELLS}, {jae .nospark}, {mov byte [es:di], 0x80}
.nospark:
    seq {loop .spark}
.sparks_done:
%endif
%if GLIDERS
.glider:
    seq {call rnd}, {test ah, 0x0f}, {jnz .noglider}, {call rnd}, {mov di, ax}
    seq {cmp di, CELLS - 642}, {jae .noglider}
    ; The linear bound protects the bottom; this also forbids row straddling.
    seq {xor dx, dx}, {mov bx, 320}, {div bx}, {cmp dx, 317}, {ja .noglider}
    seq {mov byte [es:di + 1], 0x80}, {mov byte [es:di + 322], 0x80}, {mov byte [es:di + 640], 0x80}
    seq {mov byte [es:di + 641], 0x80}, {mov byte [es:di + 642], 0x80}
.noglider:
%endif
    seq {mov bx, [fs:TICK]}
.wait:
    seq {hlt}, {cmp bx, [fs:TICK]}, {je .wait}, {jmp generation}
pout:
    seq {cmp al, 64}, {jb .ok}, {mov al, 63}
.ok:
    seq {out dx, al}, {ret}
rnd:
    seq {mov ax, bp}, {imul ax, ax, 25173}, {add ax, 13849}, {mov bp, ax}, {ret}
payload_end:
times 510 - ($ - $$) db 0
dw 0xaa55
