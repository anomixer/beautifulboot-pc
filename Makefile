# Beautiful Boot PC — builds a 1.44 MB bootable floppy image
# Requires: nasm, dd (GNU coreutils), qemu-system-i386 (for test)

IMG     = beautiful.img
BOOT    = boot.bin
STAGE2  = stage2.bin
GAMES   = $(shell find games/ -type f \( -iname "*.com" -o -iname "*.exe" -o -iname "*.bin" \) 2>/dev/null)

.PHONY: all clean test

all: $(IMG)

$(BOOT): boot.asm
	nasm -f bin -o $@ $<
	@test $$(stat -c%s $@) -eq 512 || (echo "boot sector != 512 B" && exit 1)

$(STAGE2): stage2.asm font.inc exe_reloc.asm
	nasm -f bin -o $@ $<
	@test $$(stat -c%s $@) -le 8704 || (echo "stage2 > 17 sectors (8704 B)" && exit 1)

$(IMG): $(BOOT) $(STAGE2)
	rm -f $@
	mkfs.fat -C $@ 1440
	dd if=$(BOOT) of=$@ bs=1 count=3 conv=notrunc status=none
	dd if=$(BOOT) of=$@ bs=1 skip=62 seek=62 count=450 conv=notrunc status=none
	mcopy -i $@ $(STAGE2) ::stage2.bin
	@find games/ -type f \( -iname "*.com" -o -iname "*.exe" -o -iname "*.bin" \) 2>/dev/null | while read -r game; do \
		target=$$(basename "$$game"); \
		mcopy -i $@ "$$game" "::$$target"; \
	done
	@echo "✅  $(IMG) ready"

test: $(IMG)
	PULSE_SERVER=unix:/mnt/wslg/PulseServer \
	qemu-system-i386 -fda $(IMG) -boot a -display gtk,gl=on \
		-audiodev pa,id=snd0,server=unix:/mnt/wslg/PulseServer \
		-machine pcspk-audiodev=snd0

clean:
	rm -f $(BOOT) $(STAGE2) $(IMG)