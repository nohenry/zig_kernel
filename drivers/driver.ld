DRIVER_ADDRR_OFFSET = 0x2000000000;
KERNEL_OFFSET = 0x3000000000;

MEMORY {
    DRIVER_MEM : ORIGIN = DRIVER_ADDRR_OFFSET, LENGTH = 10000M
    KERNEL_MEM : ORIGIN = KERNEL_OFFSET, LENGTH = 10000M
}

SECTIONS {
	. = DRIVER_ADDRR_OFFSET;

	.text ALIGN(4K) : AT (ADDR(.text) - DRIVER_ADDRR_OFFSET) {
		*(.text)
	} > DRIVER_MEM

	.rodata ALIGN(4K) : AT (ADDR(.rodata) - DRIVER_ADDRR_OFFSET) {
		*(.rodata)
		*(.rodata.*)
	} > DRIVER_MEM

	.data ALIGN(4K) : AT (ADDR(.data) - DRIVER_ADDRR_OFFSET) {
		*(.data)
		*(.data.*)
	} > DRIVER_MEM

	.bss ALIGN(4K) : AT (ADDR(.bss) - DRIVER_ADDRR_OFFSET) {
		*(COMMON)
		*(.bss)
	} > DRIVER_MEM

	.bss.stack ALIGN(4K) : AT (ADDR(.bss.stack) - DRIVER_ADDRR_OFFSET) {
		DRIVER_STACK_START = .;
		KEEP(*(.bss.stack))
		DRIVER_STACK_END = .;
	} > DRIVER_MEM

	DRIVER_VADDR_END = .;
	DRIVER_PHYSADDR_END = . - DRIVER_ADDRR_OFFSET;


    /* .text.kernel : {
        poo = KERNEL_OFFSET;
    } > KERNEL_MEM */
}