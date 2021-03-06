# main project for qemu-arm
TARGET := qemu-virt
ARCH := arm
ARM_CPU := cortex-a15

MEMSIZE := 0x1000000  # 16MB

MODULES += app/fletch-fixed lib/gfx lib/evlog

EXTRA_LINKER_SCRIPTS += fletch/project/add-fletch-snapshot-section.ld

GLOBAL_DEFINES += WITH_KERNEL_EVLOG=1

FLETCH_CONFIGURATION = LK
FLETCH_GYP_DEFINES = "LK_PROJECT=qemu-virt-fixed-snapshot LK_CPU=cortex-a15"

WITH_CPP_SUPPORT=true

#WITH_LINKER_GC := 0
