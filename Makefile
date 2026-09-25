.DEFAULT_GOAL := all
VARIANT ?= rolling_sliding
NASM ?= nasm
QEMU ?= qemu-system-i386
PYTHON ?= python3
VARIANTS := sliding rolling_sliding rolling_lut sliding_lut sliding_lut_word rolling_bits

ifeq ($(filter $(VARIANT),$(VARIANTS)),)
$(error Unknown VARIANT: $(VARIANT). Choose one of $(VARIANTS))
endif

.PHONY: all run upstream verify check clean
all: build/$(VARIANT).img

build:
	mkdir -p build

build/%.img: final/life.%.asm | build
	$(NASM) -f bin -o $@ $<

build/upstream.img: life.asm | build
	$(NASM) -f bin -o $@ $<

upstream: build/upstream.img

run: all
	$(QEMU) -cpu pentium -drive file=build/$(VARIANT).img,format=raw,if=floppy

verify:
	$(PYTHON) verify_release.py

check: | build
	$(PYTHON) experiment.py --cpu pentium --variants $(VARIANTS) --generations 5 --skip-benchmark --output build/checks.json

clean:
	rm -rf build __pycache__
