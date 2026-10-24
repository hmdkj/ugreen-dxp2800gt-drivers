# SPDX-License-Identifier: GPL-2.0-only

obj-m += ugreen-cs201x.o
obj-m += ugreen-cs201x-leds.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# Same build with the extra warnings the kernel only enables on request.
# The port is expected to be clean under this target.
check:
	$(MAKE) -C $(KDIR) M=$(CURDIR) W=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

modules_install install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install
	depmod -a $(KVER)

.PHONY: all modules check clean modules_install install
