obj-m := snd-soc-tas2783-sdw.o
snd-soc-tas2783-sdw-y := tas2783-sdw.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

# --- target-kernel API probes -------------------------------------------------
# Two calls changed shape across 7.1 -> 7.2 -> 7.3, and LINUX_VERSION_CODE is
# not a reliable guide: distros backport, and @leepaulmann found Arch
# 7.1.9-arch1-2 carrying a different sdca_parse_function() than CachyOS 7.1.x
# with the same version code. So probe the headers of the kernel actually being
# built against. Inside kbuild $(srctree) is that tree; standalone it is unset
# and $(KDIR) is used.
KHDR := $(if $(srctree),$(srctree),$(KDIR))

# sdca_parse_function(): 7.1 (dev, sdw, desc, function), 7.2 (dev, sdw,
# function), 7.3 (dev, function). Read the whole prototype, not one line.
SDCA_PROTO := $(shell awk '/^int sdca_parse_function/,/;/' \
	$(KHDR)/include/sound/sdca_function.h 2>/dev/null | tr -d '\n')
ccflags-y += $(if $(findstring sdca_function_desc,$(SDCA_PROTO)),-DPX13_SDCA_PARSE_HAS_DESC)
ccflags-y += $(if $(findstring sdw_slave,$(SDCA_PROTO)),-DPX13_SDCA_PARSE_HAS_SDW)

# sdw_slave_wait_for_init(): static inline in <linux/soundwire/sdw.h> from 7.2.
ccflags-y += $(shell grep -q sdw_slave_wait_for_init \
	$(KHDR)/include/linux/soundwire/sdw.h 2>/dev/null \
	&& echo -DHAVE_SDW_SLAVE_WAIT_FOR_INIT)

ifneq ($(KERNELRELEASE),)
$(info px13 tas2783: kernel API probes ->$(if $(strip $(ccflags-y)), $(strip $(ccflags-y)), none))
endif

# Follow the toolchain the TARGET kernel was built with. CachyOS builds its
# kernels with clang, Arch stock and Fedora with gcc, and mixing the two fails
# on unknown compiler flags (-mpreferred-stack-boundary, -mrecord-mcount, ...).
# Override with LLVM=1 or LLVM= if the probe is ever wrong.
LLVM ?= $(shell grep -qs '^CONFIG_CC_IS_CLANG=y' $(KDIR)/.config && echo 1)
LLVMARG := $(if $(LLVM),LLVM=$(LLVM))

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVMARG) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVMARG) clean
