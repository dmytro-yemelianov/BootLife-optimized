.DEFAULT_GOAL := life.img

life.img: life.asm
	nasm -f bin -o $@ $<

.PHONY: run
run: life.img
	qemu-system-i386 -drive file=life.img,format=raw,if=floppy

.PHONY: clean
clean:
	rm -f life.img
