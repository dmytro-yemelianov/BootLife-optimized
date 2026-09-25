;;------------------------------------------------------------------------------
;; Copyright 2026 Alex Kuleshov <kuleshovmail@gmail.com>
;;
;; Permission to use, copy, modify, and/or distribute this software for
;; any purpose with or without fee is hereby granted, provided that the
;; above copyright notice and this permission notice appear in all copies.
;;
;; THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
;; WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
;; WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
;; AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
;; DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
;; PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
;; TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
;; PERFORMANCE OF THIS SOFTWARE.
;;
;; life.asm -- Conway's Game of Life in a 512-byte boot sector
;;
;; Usage:
;;
;;      nasm -f bin -o life.img life.asm
;;      qemu-system-i386 -drive file=life.img,format=raw,if=floppy
;;------------------------------------------------------------------------------

        bits 16
        org 0x7C00

        ;; segment containing the work buffer to keep a copy of the previous
        ;; generation while we compute a new one because every cell in generation
        ;; N+1 must be calculated from generation N
WORK    equ 0x1000
        ;; Number of cells in 320x200
CELLS   equ 64000
        ;; segment containing the VGA framebuffer
VID     equ 0xA000
        ;; The number of alive cells randomly generated after each generation.
SPARKS  equ 6
        ;; BIOS timer counter in memory
TICK    equ 0x046C

start:
        ;; Reset ax to 0
        xor ax, ax
        ;;  Setup the stack segment to 0
        mov ss, ax
        ;; Setup the stack pointer so it grows down from just below us
        mov sp, 0x7000
        ;; fs stays at 0 so we can read the BIOS tick
        mov fs, ax

        ;; ah = 0    - BIOS function: set video mode
        ;; al = 0x13 - Video mode number: 320x200, 256 colors
        mov ax, 0x0013
        ;; Set video mode
        int 0x10

        ;; Define palette entry starting from 0. Each palette entry is a pixel on screen
        ;; which represents palete entry.
        ;;
        ;; The palette is a table that looks like this:
        ;;
        ;; palette entry     actual RGB color
        ;; ----------------------------------
        ;; 0                 (0, 0, 0)
        ;; 1                 (0, 0, 0)
        ;; 2                 (0, 0, 0)
        ;; ...
        ;; 64                (4, 2, 20)
        ;; ...
        ;; 128               (0, 44, 16)
        ;; 129               (...)
        ;; ...
        ;; 255               (63, 63, 63)

        ;; VGA palette index port
        mov dx, 0x3C8
        ;; Set the strting palette entry to 0
        xor al, al
        ;; Write the starting palete entry number to the VGA DAC
        out dx, al

        ;; Switch to VGA DAC data port where RGB data will be sent
        inc dx
        ;; Start with the entry 0
        xor bx, bx

.pal:
        ;; Check the (color) sign bit of al:
        ;;
        ;; - If it is set it is a living cell.
        ;; - If it is not set it is a fading out dead cell.
        mov al, bl
        or al, al
        js .live

        ;; The VGA DAC expects three values for each color index:
        ;;
        ;; - Red
        ;; - Green
        ;; - Blue
        ;;
        ;; We build these colors as:
        ;;
        ;; - color index / 16                   -> Red
        ;; - color index / 32                   -> Green
        ;; - color index / 4 + color index / 16 -> Blue
        ;;
        ;; Thus we get:
        ;;
        ;;         Color index	R	G	B	Result
        ;;                   0	0	0	0	black
        ;;                   1	0	0	0	black
        ;;                   2	0	0	0	black
        ;;                   3	0	0	0	black
        ;;                   4	0	0	1	dark blue
        ;;                   5	0	0	1	dark blue
        ;;                   6	0	0	1	dark blue
        ;;                   7	0	0	1	dark blue
        ;;
        ;; and so on...

        ;; Calculate red
        shr al, 4
        ;; Write it to VGA DAC data port
        call pout

        ;; Calculate green
        mov al, bl
        shr al, 5
        ;; Write it to VGA DAC data port
        call pout

        ;; Calculate blue
        mov al, bl
        shr al, 2
        mov ah, bl
        shr ah, 4
        add al, ah
        ;; Write it to VGA DAC data port
        call pout

        ;; Switch to the next color index
        jmp .next

.live:
        ;; Remove the highest (alive) bit
        ;; So al is treated as an age from 0..127.
        and al, 0x7F

        ;; We build the RGB color from the age as:
        ;;
        ;; - age / 2        -> Red
        ;; - 44 + age / 4   -> Green
        ;; - 16 + age / 2   -> Blue
        ;;
        ;; Thus we get:
        ;;
        ;;   Color index  Age   R   G   B   Result
        ;;           128    0   0  44  16   green
        ;;           129    1   0  44  16   green
        ;;           130    2   1  44  17   slightly brighter
        ;;           132    4   2  45  18   brighter
        ;;           192   64  32  60  48   pale green
        ;;           255  127  63  63  63   white

        ;; Calculate red
        shr al, 1
        ;; Write it to VGA DAC data port
        call pout

        ;; Calculate green
        mov al, bl
        and al, 0x7F
        shr al, 2
        add al, 44
        ;; Write it to VGA DAC data port
        call pout

        ;; Calculate blue
        mov al, bl
        and al, 0x7F
        shr al, 1
        add al, 16
        ;; Write it to VGA DAC data port
        call pout

.next:
        ;; Switch to the next palete entry if they are not ended yet
        inc bl
        jnz .pal

        ;; Initialize work buffer to store copy of the previous generation
        ;;
        ;; Reset to 0 all memory in the work buffer after CELLS:
        ;;
        ;;         offset
        ;; 0000  +---------------------------+
        ;;       |                           |
        ;;       | 64000 bytes               |
        ;;       | reserved for cells        |
        ;;       |                           |
        ;; F9FF  +---------------------------+ CELLS
        ;; FA00  | 00                        |
        ;; FA01  | 00                        |
        ;; FA02  | 00                        |
        ;;       | ...                       |
        ;; FFFE  | 00                        |
        ;; FFFF  | 00                        |
        ;;       +---------------------------+
        mov ax, WORK
        mov es, ax
        mov di, CELLS
        xor ax, ax
        mov cx, (0x10000 - CELLS) / 2
        rep stosw

        ;; Setup the pointer to the buffer with the previous generation
        mov ax, WORK
        mov ds, ax

        ;; Setup the pointer to the current generation (VGA video memory)
        mov ax, VID
        mov es, ax

        ;; Read the CPUs time-stamp counter
        rdtsc
        ;; Save the current state of the pseudo-random number generator
        mov bp, ax

        ;; Start from the first pixel (es:di = A000:0000)
        xor di, di
        ;; Set counter for pixels
        mov cx, CELLS

        ;; Draw initial picture
.seed:
        ;; Call our randomizer and reutrn result in ax
        call rnd
        ;; Higher bits have statistical behavior
        mov al, ah
        ;; Keep only the highest bit:
        ;;
        ;; 0 - dead cell
        ;; 1 - alive cell
        ;;
        ;; Based on the palette:
        ;;
        ;; 0x00 -> palette[0]   -> black
        ;; 0x80 -> palette[128] -> green
        and al, 0x80
        ;; Write the cell to screen.
        ;;
        ;; The same as:
        ;;
        ;;      mov [es:di], al
        ;;      inc di
        stosb
        ;; Write next cells
        loop .seed

generation:
        ;; Copy current framebuffer from video memory into the work buffer
        ;;
        ;; Currently:
        ;;
        ;; ds - the pointer to the work buffer
        ;; es - the pointer to the video memory
        ;;
        ;; Exchange them, do copy, and switch back
        push ds
        push es
        pop ds
        pop es
        xor si, si
        xor di, di
        mov cx, CELLS / 2
        rep movsw
        push ds
        push es
        pop ds
        pop es

        ;; Set the current cell index
        xor si, si
.cell:
        ;; Set the live-neighbour counter around the current cell
        xor bx, bx

        ;; Our screen is 320x200 stored in a single array of memory.
        ;;
        ;; It can be represented as:
        ;;
        ;; row 0:     0      1      2    ...    319
        ;; row 1:   320    321    322    ...    639
        ;; row 2:   640    641    642    ...    959
        ;; ...
        ;; ...
        ;; ...
        ;; row 199: 63680  63681  63682  ...  63999
        ;;
        ;; The current cell index is stored in the si register, so:
        ;;
        ;; - To move horizontally is si + 1 or si - 1
        ;; - To move vertically is si + 320 or si - 320
        ;;
        ;; So the moving to any direction is:
        ;;
        ;;        offsets relative to si
        ;;
        ;;   -321        -320        -319
        ;; top-left       top        top-right
        ;;
        ;;     -1           0          +1
        ;;    left        cell        right
        ;;
        ;;    +319        +320        +321
        ;; bottom-left    bottom     bottom-right

        ;; Calculate top-left position of the 3x3 neighbourhood of the current cell
        mov di, si
        sub di, 321

        ;; Set the number of rows in the 3x3 block to inspect
        mov dl, 3
.row:
        ;; Set the number of cells in the current row to inspect
        mov cx, 3
.col:
        ;; Inspect all the neighbouring cells around the current one
        ;; and count the number of alive starting from di.
        ;;
        ;; For now we have:
        ;;
        ;;                 3 cells
        ;;       +---+---+---+
        ;; row 1 |   |   |   |  <- di starts here, top-left
        ;;       +---+---+---+
        ;; row 2 |   | X |   |  <- x is the current cell, si
        ;;       +---+---+---+
        ;; row 3 |   |   |   |
        ;;       +---+---+---+
        mov al, [di]
        ;; Double the value of the cell since we have:
        ;;
        ;;  - 0x80 .. 0xFF alive cells
        ;;  - 0x00 .. 0x7F dead cells
        ;;
        ;; So after addition we will have:
        ;;
        ;; CF = 0 -> dead
        ;; CF = 1 -> alive
        add al, al
        ;; Increase the counter of alive cells around if need
        ;;
        ;; bl = bl + 0 + CF
        adc bl, 0
        ;; Move to the next cell
        inc di
        ;; Repeat the check for current row
        loop .col

        ;; Move to the next row.
        ;; On the previous iteration we already increased di 3 times by 1
        ;; and now to move to the next row we need cell + 320 - 3
        add di, 317
        ;; Set the number of rows left to inspect.
        dec dl
        ;; Start the check for new row.
        jnz .row

        ;; On the previous step we calculated the number of alive cells around
        ;; the current including the current. We need to remove the current
        ;; from the counter if it was alive.
        mov al, [si]
        add al, al
        sbb bl, 0

        ;; Apply Conway's rule to the current cell
        ;;
        ;; 1. If the current cell has 3 alive neighbours - make it live
        mov al, [si]
        cmp bl, 3
        je .on

        ;; 2. If the current cell has not 2 or more than 3 alive neighbours - mark it dead as overpopulated.
        cmp bl, 2
        jne .off

        ;; For exactly 2 alive neighbours the cell stays as is.
        or al, al
        jns .off

.on:
        ;; If the cell already was alive, cell survives
        or al, al
        js .age
        ;; If the cell was not alive, mark it alive
        mov al, 0x80
        jmp .store

.off:
        ;; If the cell was dead, fade it
        or al, al
        jns .fade
        ;; If the cell was alive, mark it as dead
        mov al, 0x7F
        jmp .store

.age:
        ;; Make the alive cell brighter if we do not overflow.
        add al, 6
        jnc .store
        ;; Make the cell as bright as possible.
        mov al, 0xFF
        jmp .store

.fade:
        ;; The dead cell was somewhere between 0x00..0x7F. Try to fade it by 16.
        sub al, 16
        jnc .store
        ;; If we went below 0 above, make the cell fully black.
        xor al, al

.store:
        ;; Draw the newly calculated color of the current cell on the screen.
        mov [es:si], al
        ;; Move to the next cell if we did not proceed all of them yet.
        inc si
        cmp si, CELLS
        jne .cell

        ;; Generate "sparks" - randomly chosen cells that become newly alive.
        mov cx, SPARKS
.spark:
        ;; Get random value and store it in ax.
        call rnd
        ;; If the value is not outside our cells mark it as alve.
        mov di, ax
        cmp di, CELLS
        jae .nospark
        mov byte [es:di], 0x80

.nospark:
        loop .spark

        ;; Decide should we generate a glider or not based on random number.
        call rnd
        test ah, 0x0F
        jnz .noglider

        ;; Make sure our glider will not end-up outside the framebuffer.
        call rnd
        mov di, ax
        cmp di, CELLS - 642
        jae .noglider

        ;; Draw the glider:
        ;;
        ;;   . X .
        ;;   . . X
        ;;   X X X
        ;;
        ;; For the more information about the cells positioning see .cell
        mov byte [es:di + 1],   0x80
        mov byte [es:di + 322], 0x80
        mov byte [es:di + 640], 0x80
        mov byte [es:di + 641], 0x80
        mov byte [es:di + 642], 0x80

.noglider:
        ;; Store the current timer counter value.
        mov bx, [fs:TICK]

.wait:
        ;; Sleep until an interrupt occurs, then check whether the timer tick changed.
        hlt
        cmp bx, [fs:TICK]
        je .wait

        ;; One timer tick passed, start the next generation.
        jmp generation

pout:
        ;; Check that al has a valid value.
        ;; RGB components are 0..63.
        ;;
        ;; If it is bigger, set to the max intensity of this color component.
        cmp al, 64
        jb .ok
        mov al, 63
.ok:
        ;; Write the RGB compoment to the port.
        out dx, al
        ret

rnd:
        ;; copy the current PRNG state from bp into ax
        mov ax, bp
        ;; LCG multiplier
        imul ax, ax, 25173
        ;; LCG increment
        add ax, 13849
        ;; save the new PRNG state back into bp
        mov bp, ax
        ;; return; ax contains the generated 16-bit value
        ret

        ;; Pad the boot sector with zeroes up to byte 510
        times 510 - ($ - $$) db 0
        ;; Boot-sector signature
        dw 0xAA55
