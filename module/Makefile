obj-m := snd-soc-tas2783-sdw.o
snd-soc-tas2783-sdw-y := tas2783-sdw.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

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
