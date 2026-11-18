# Kernel + static busybox + rootfs/ (the ballpit submodule), packed into an initramfs.
# `make` builds out/bzImage and out/initramfs.cpio.gz; `make run` boots them in QEMU.

KVER     := 6.18.64
KSHA256  := 020d45510c539972e6f14c5c71566878d3b7ef56fb082b3e09134f2ebaade562
BBVER    := 1.38.0
BBSHA256 := 34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2

TOP   := $(CURDIR)
KSRC  := build/linux-$(KVER)
KOBJ  := $(TOP)/build/linux-obj
BBSRC := build/busybox-$(BBVER)
STAGE := $(TOP)/build/rootfs

all: out/bzImage out/initramfs.cpio.gz

dl/linux-$(KVER).tar.xz:
	mkdir -p dl
	curl -fL -o $@.part https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KVER).tar.xz
	echo "$(KSHA256)  $@.part" | sha256sum -c -
	mv $@.part $@

dl/busybox-$(BBVER).tar.bz2:
	mkdir -p dl
	curl -fL -o $@.part https://busybox.net/downloads/busybox-$(BBVER).tar.bz2
	echo "$(BBSHA256)  $@.part" | sha256sum -c -
	mv $@.part $@

$(KSRC)/.unpacked: dl/linux-$(KVER).tar.xz
$(BBSRC)/.unpacked: dl/busybox-$(BBVER).tar.bz2
%/.unpacked:
	mkdir -p build
	tar -C build -xf $<
	touch $@

# Kernel: x86_64_defconfig plus our fragment.
$(KOBJ)/.config: $(KSRC)/.unpacked config/kernel.fragment
	$(MAKE) -C $(KSRC) O=$(KOBJ) x86_64_defconfig
	cd $(KOBJ) && $(TOP)/$(KSRC)/scripts/kconfig/merge_config.sh -m .config $(TOP)/config/kernel.fragment
	$(MAKE) -C $(KSRC) O=$(KOBJ) olddefconfig

out/bzImage: $(KOBJ)/.config
	$(MAKE) -C $(KSRC) O=$(KOBJ) -j$(shell nproc) bzImage
	mkdir -p out
	cp $(KOBJ)/arch/x86/boot/bzImage $@

# Busybox: defconfig, static, minus `tc` (needs headers Linux dropped in 6.8).
$(BBSRC)/.config: $(BBSRC)/.unpacked
	$(MAKE) -C $(BBSRC) defconfig
	sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
	       -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' $@

$(BBSRC)/busybox: $(BBSRC)/.config
	$(MAKE) -C $(BBSRC) -j$(shell nproc)

rootfs/etc/inittab:
	@echo "rootfs/ is empty: run 'git submodule update --init'" >&2; exit 1

# Root filesystem: busybox install, then rootfs/ on top (minus the submodule's own files).
$(STAGE)/.stamp: $(BBSRC)/busybox rootfs/etc/inittab $(shell find rootfs -type f -not -name .git)
	rm -rf $(STAGE)
	$(MAKE) -C $(BBSRC) CONFIG_PREFIX=$(STAGE) install
	rm $(STAGE)/linuxrc
	mkdir -p $(addprefix $(STAGE)/,dev proc sys run tmp root mnt var/log)
	tar -C rootfs --exclude=./.git --exclude=./README.md -cf - . | tar -C $(STAGE) -xf -
	chmod 600 $(STAGE)/etc/shadow; chmod 700 $(STAGE)/root; chmod 1777 $(STAGE)/tmp
	ln -s sbin/init $(STAGE)/init
	touch $@

# gen_initramfs.sh must run from the kernel build dir (it calls usr/gen_init_cpio).
out/initramfs.cpio.gz: $(STAGE)/.stamp config/initramfs.list out/bzImage
	cd $(KOBJ) && sh $(TOP)/$(KSRC)/usr/gen_initramfs.sh -o $(TOP)/out/initramfs.cpio \
		-u squash -g squash $(STAGE) $(TOP)/config/initramfs.list
	gzip -9fn out/initramfs.cpio

run: all
	qemu-system-x86_64 $(if $(wildcard /dev/kvm),-enable-kvm) -m 256M -nographic \
		-kernel out/bzImage -initrd out/initramfs.cpio.gz \
		-append "console=ttyS0 quiet" -nic user,model=e1000

clean:
	rm -rf build out

.PHONY: all run clean
