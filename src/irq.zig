const std = @import("std");

const regs = @import("./registers.zig");
const acpi = @import("./acpi/acpi.zig");
const log = @import("./logger.zig");
const paging = @import("./paging.zig");
const gdt = @import("./gdt.zig");
const apic = @import("./lapic.zig");
const schedular = @import("./schedular.zig");

const GateType = enum(u4) {
    Interrupt = 0xE,
    Trap = 0xF,
};

const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3 = 0,
    reserved1: u5 = 0,
    gate_type: GateType = .Interrupt,
    reserved2: u1 = 0,
    dpl: enum(u2) {
        kernel = 0,
        user = 3,
    } = .kernel,
    present: bool = false,
    offset_high: u48,
    reserved3: u32 = 0,
};

const IDT align(16) = struct {
    entries: [256]IDTEntry = .{.{ .offset_low = 0, .selector = 0, .offset_high = 0 }} ** 256,

    pub fn kernelErrorISR(self: *IDT, index: u8, isr: *const fn () callconv(.Naked) void) void {
        const isr_val = @intFromPtr(isr);
        self.entries[index] = .{
            .offset_low = @truncate(isr_val & 0xFFFF),
            .offset_high = @truncate(isr_val >> 16),
            .present = true,
            .selector = gdt.Entry.kernel_code_selector(),
        };
    }

    pub fn kernelISR(self: *IDT, index: u8, isr: *const fn () callconv(.Naked) void) void {
        const isr_val = @intFromPtr(isr);
        self.entries[index] = .{
            .offset_low = @truncate(isr_val & 0xFFFF),
            .offset_high = @truncate(isr_val >> 16),
            .present = true,
            .selector = gdt.Entry.kernel_code_selector(),
            .ist = @truncate(gdt.getIstInterruptVec()),
        };
    }
};

var GLOBAL_IDT = IDT{};
var IDT_DESCRIPTOR: packed struct { size: u16, base: u64 } = .{ .base = 0, .size = 0 };

/// x86_64 interrupt frame along with saved registers
pub const ISRFrame = extern struct {
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    rbp: u64,

    // We push these for useful information
    vector: u64,
    error_code: u64,

    // These come from x86_64 interrupt specification
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Callback function called when an interrupt occurs
pub const IRQHandlerCallback = *const fn (*ISRFrame) bool;

/// Represents the configuration of an irq handler
pub const IRQHandler = struct {
    /// The callback to call
    callback: IRQHandlerCallback,
    /// If not null, this process's address space will be loaded. Then, the callback will be called
    process: ?*schedular.List.Node,
};

var irq_handlers: [256]?std.ArrayList(IRQHandler) = .{null} ** 256;

/// Handle/dispatch interrupt requests and exceptions.
/// 
/// See `irq.register_handler` and `irq.register_handler_callback` to register an interrupt handler
export fn isr_handler(frame: *ISRFrame) callconv(.C) u64 {
    switch (frame.vector) {
        0x3 => {
            log.panic("Breakpoint", .{}, @src());
        },
        0xD => {
            log.panic("GPF", .{}, @src());
        },
        0xE => {
            var buf = [_]u8{0} ** 64;

            var fba = std.heap.FixedBufferAllocator.init(&buf);
            var error_format = std.ArrayList(u8).init(fba.allocator());

            if (frame.error_code & 1 > 0) {
                error_format.appendSlice(", Page Protection") catch {};
            }
            if (frame.error_code & 0b10 > 0) {
                error_format.appendSlice(", Write") catch {};
            } else {
                error_format.appendSlice(", Read") catch {};
            }
            if (frame.error_code & 0b100 > 0) {
                error_format.appendSlice(", CPL=3") catch {};
            }
            if (frame.error_code & 0b1000 > 0) {
                error_format.appendSlice(", Reserved Write") catch {};
            }
            if (frame.error_code & 0b10000 > 0) {
                error_format.appendSlice(", Executed") catch {};
            }

            log.panic("Page fault: 0x{x}{s}", .{ regs.CR2.get().value, error_format.items }, @src());
        },
        else => {
            log.info("Interrupt: 0x{x} 0x{x} 0x{x}", .{ frame.ss, frame.vector, frame.rflags }, @src());

            var handler = &irq_handlers[frame.vector];
            var handled = false;

            if (handler.*) |handlers| {
                for (handlers.items) |hand| {
                    var old_proc: ?*schedular.List.Node = null;

                    if (hand.process) |proc| {
                        old_proc = schedular.instance().current_process;
                        proc.data.context.address_space.load();
                    }

                    defer if (old_proc) |proc| {
                        proc.data.context.address_space.load();
                    };

                    if (hand.callback(frame)) {
                        handled = true;
                        break;
                    }
                }
            }

            if (!handled) {
                log.warn("Unhandled interrupt 0x{x}", .{frame.ss}, @src());
            }

            apic.instance().write(.EOI, @as(u32, 0));
        },
    }
    // frame.rflags &= ~@as(u64, 0x200);

    return @intFromPtr(frame);
}

const PIC1: u16 = 0x20;
const PIC2: u16 = 0xA0;
const PIC1_COMMAND: u16 = PIC1;
const PIC1_DATA: u16 = (PIC1 + 1);
const PIC2_COMMAND: u16 = PIC2;
const PIC2_DATA: u16 = (PIC2 + 1);

const ICW1_ICW4: u8 = 0x01;
const ICW1_SINGLE: u8 = 0x02;
const ICW1_INTERVAL4: u8 = 0x04;
const ICW1_LEVEL: u8 = 0x08;
const ICW1_INIT: u8 = 0x10;

const ICW4_8086: u8 = 0x01;
const ICW4_AUTO: u8 = 0x02;
const ICW4_BUF_SLAVE: u8 = 0x08;
const ICW4_BUF_MASTER: u8 = 0x0C;
const ICW4_SFNM: u8 = 0x10;

pub fn init_idt() void {
    init_idt_impl();

    IDT_DESCRIPTOR.base = @intFromPtr(&GLOBAL_IDT);
    IDT_DESCRIPTOR.size = 256 * @sizeOf(IDTEntry) - 1;
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&IDT_DESCRIPTOR),
        : "memory"
    );
}

const ioapic = @import("./ioapic.zig");

/// Register a simple callback function for `vector`
pub fn register_handler_callback(handler: IRQHandlerCallback, vector: u8) void {
    if (irq_handlers[vector]) |*vector_handler| {
        vector_handler.append(.{
            .callback = handler,
            .process = null,
        }) catch {};
    } else {
        var allocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false, .safety = false }){};

        irq_handlers[vector] = std.ArrayList(IRQHandler).init(allocator.allocator());
        irq_handlers[vector].?.append(.{
            .callback = handler,
            .process = null,
        }) catch {};
    }
}

/// Register an interrupt handler for `vector`
pub fn register_handler(handler: IRQHandler, vector: u8) void {

    if (irq_handlers[vector]) |*vector_handler| {
        vector_handler.append(handler) catch {};
    } else {
        var allocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false, .safety = false }){};

        irq_handlers[vector] = std.ArrayList(IRQHandler).init(allocator.allocator());
        irq_handlers[vector].?.append(handler) catch {};
    }
}

fn init_idt_impl() void {
    GLOBAL_IDT.kernelISR(0, isr0);
    GLOBAL_IDT.kernelISR(1, isr1);
    GLOBAL_IDT.kernelISR(2, isr2);
    GLOBAL_IDT.kernelISR(3, isr3);
    GLOBAL_IDT.kernelISR(4, isr4);
    GLOBAL_IDT.kernelISR(5, isr5);
    GLOBAL_IDT.kernelISR(6, isr6);
    GLOBAL_IDT.kernelISR(7, isr7);
    GLOBAL_IDT.kernelErrorISR(8, isr8);
    GLOBAL_IDT.kernelISR(9, isr9);
    GLOBAL_IDT.kernelErrorISR(10, isr10);
    GLOBAL_IDT.kernelErrorISR(11, isr11);
    GLOBAL_IDT.kernelErrorISR(12, isr12);
    GLOBAL_IDT.kernelErrorISR(13, isr13);
    GLOBAL_IDT.kernelErrorISR(14, isr14);
    GLOBAL_IDT.kernelISR(15, isr15);
    GLOBAL_IDT.kernelISR(16, isr16);
    GLOBAL_IDT.kernelErrorISR(17, isr17);
    GLOBAL_IDT.kernelISR(18, isr18);
    GLOBAL_IDT.kernelISR(19, isr19);
    GLOBAL_IDT.kernelISR(20, isr20);
    GLOBAL_IDT.kernelISR(21, isr21);
    GLOBAL_IDT.kernelISR(22, isr22);
    GLOBAL_IDT.kernelISR(23, isr23);
    GLOBAL_IDT.kernelISR(24, isr24);
    GLOBAL_IDT.kernelISR(25, isr25);
    GLOBAL_IDT.kernelISR(26, isr26);
    GLOBAL_IDT.kernelISR(27, isr27);
    GLOBAL_IDT.kernelISR(28, isr28);
    GLOBAL_IDT.kernelISR(29, isr29);
    GLOBAL_IDT.kernelErrorISR(30, isr30);
    GLOBAL_IDT.kernelISR(31, isr31);
    GLOBAL_IDT.kernelISR(32, isr32);
    GLOBAL_IDT.kernelISR(33, isr33);
    GLOBAL_IDT.kernelISR(34, isr34);
    GLOBAL_IDT.kernelISR(35, isr35);
    GLOBAL_IDT.kernelISR(36, isr36);
    GLOBAL_IDT.kernelISR(37, isr37);
    GLOBAL_IDT.kernelISR(38, isr38);
    GLOBAL_IDT.kernelISR(39, isr39);
    GLOBAL_IDT.kernelISR(40, isr40);
    GLOBAL_IDT.kernelISR(41, isr41);
    GLOBAL_IDT.kernelISR(42, isr42);
    GLOBAL_IDT.kernelISR(43, isr43);
    GLOBAL_IDT.kernelISR(44, isr44);
    GLOBAL_IDT.kernelISR(45, isr45);
    GLOBAL_IDT.kernelISR(46, isr46);
    GLOBAL_IDT.kernelISR(47, isr47);
    GLOBAL_IDT.kernelISR(48, isr48);
    GLOBAL_IDT.kernelISR(49, isr49);
    GLOBAL_IDT.kernelISR(50, isr50);
    GLOBAL_IDT.kernelISR(51, isr51);
    GLOBAL_IDT.kernelISR(52, isr52);
    GLOBAL_IDT.kernelISR(53, isr53);
    GLOBAL_IDT.kernelISR(54, isr54);
    GLOBAL_IDT.kernelISR(55, isr55);
    GLOBAL_IDT.kernelISR(56, isr56);
    GLOBAL_IDT.kernelISR(57, isr57);
    GLOBAL_IDT.kernelISR(58, isr58);
    GLOBAL_IDT.kernelISR(59, isr59);
    GLOBAL_IDT.kernelISR(60, isr60);
    GLOBAL_IDT.kernelISR(61, isr61);
    GLOBAL_IDT.kernelISR(62, isr62);
    GLOBAL_IDT.kernelISR(63, isr63);
    GLOBAL_IDT.kernelISR(64, isr64);
    GLOBAL_IDT.kernelISR(65, isr65);
    GLOBAL_IDT.kernelISR(66, isr66);
    GLOBAL_IDT.kernelISR(67, isr67);
    GLOBAL_IDT.kernelISR(68, isr68);
    GLOBAL_IDT.kernelISR(69, isr69);
    GLOBAL_IDT.kernelISR(70, isr70);
    GLOBAL_IDT.kernelISR(71, isr71);
    GLOBAL_IDT.kernelISR(72, isr72);
    GLOBAL_IDT.kernelISR(73, isr73);
    GLOBAL_IDT.kernelISR(74, isr74);
    GLOBAL_IDT.kernelISR(75, isr75);
    GLOBAL_IDT.kernelISR(76, isr76);
    GLOBAL_IDT.kernelISR(77, isr77);
    GLOBAL_IDT.kernelISR(78, isr78);
    GLOBAL_IDT.kernelISR(79, isr79);
    GLOBAL_IDT.kernelISR(80, isr80);
    GLOBAL_IDT.kernelISR(81, isr81);
    GLOBAL_IDT.kernelISR(82, isr82);
    GLOBAL_IDT.kernelISR(83, isr83);
    GLOBAL_IDT.kernelISR(84, isr84);
    GLOBAL_IDT.kernelISR(85, isr85);
    GLOBAL_IDT.kernelISR(86, isr86);
    GLOBAL_IDT.kernelISR(87, isr87);
    GLOBAL_IDT.kernelISR(88, isr88);
    GLOBAL_IDT.kernelISR(89, isr89);
    GLOBAL_IDT.kernelISR(90, isr90);
    GLOBAL_IDT.kernelISR(91, isr91);
    GLOBAL_IDT.kernelISR(92, isr92);
    GLOBAL_IDT.kernelISR(93, isr93);
    GLOBAL_IDT.kernelISR(94, isr94);
    GLOBAL_IDT.kernelISR(95, isr95);
    GLOBAL_IDT.kernelISR(96, isr96);
    GLOBAL_IDT.kernelISR(97, isr97);
    GLOBAL_IDT.kernelISR(98, isr98);
    GLOBAL_IDT.kernelISR(99, isr99);
    GLOBAL_IDT.kernelISR(100, isr100);
    GLOBAL_IDT.kernelISR(101, isr101);
    GLOBAL_IDT.kernelISR(102, isr102);
    GLOBAL_IDT.kernelISR(103, isr103);
    GLOBAL_IDT.kernelISR(104, isr104);
    GLOBAL_IDT.kernelISR(105, isr105);
    GLOBAL_IDT.kernelISR(106, isr106);
    GLOBAL_IDT.kernelISR(107, isr107);
    GLOBAL_IDT.kernelISR(108, isr108);
    GLOBAL_IDT.kernelISR(109, isr109);
    GLOBAL_IDT.kernelISR(110, isr110);
    GLOBAL_IDT.kernelISR(111, isr111);
    GLOBAL_IDT.kernelISR(112, isr112);
    GLOBAL_IDT.kernelISR(113, isr113);
    GLOBAL_IDT.kernelISR(114, isr114);
    GLOBAL_IDT.kernelISR(115, isr115);
    GLOBAL_IDT.kernelISR(116, isr116);
    GLOBAL_IDT.kernelISR(117, isr117);
    GLOBAL_IDT.kernelISR(118, isr118);
    GLOBAL_IDT.kernelISR(119, isr119);
    GLOBAL_IDT.kernelISR(120, isr120);
    GLOBAL_IDT.kernelISR(121, isr121);
    GLOBAL_IDT.kernelISR(122, isr122);
    GLOBAL_IDT.kernelISR(123, isr123);
    GLOBAL_IDT.kernelISR(124, isr124);
    GLOBAL_IDT.kernelISR(125, isr125);
    GLOBAL_IDT.kernelISR(126, isr126);
    GLOBAL_IDT.kernelISR(127, isr127);
    GLOBAL_IDT.kernelISR(128, isr128);
    GLOBAL_IDT.kernelISR(129, isr129);
    GLOBAL_IDT.kernelISR(130, isr130);
    GLOBAL_IDT.kernelISR(131, isr131);
    GLOBAL_IDT.kernelISR(132, isr132);
    GLOBAL_IDT.kernelISR(133, isr133);
    GLOBAL_IDT.kernelISR(134, isr134);
    GLOBAL_IDT.kernelISR(135, isr135);
    GLOBAL_IDT.kernelISR(136, isr136);
    GLOBAL_IDT.kernelISR(137, isr137);
    GLOBAL_IDT.kernelISR(138, isr138);
    GLOBAL_IDT.kernelISR(139, isr139);
    GLOBAL_IDT.kernelISR(140, isr140);
    GLOBAL_IDT.kernelISR(141, isr141);
    GLOBAL_IDT.kernelISR(142, isr142);
    GLOBAL_IDT.kernelISR(143, isr143);
    GLOBAL_IDT.kernelISR(144, isr144);
    GLOBAL_IDT.kernelISR(145, isr145);
    GLOBAL_IDT.kernelISR(146, isr146);
    GLOBAL_IDT.kernelISR(147, isr147);
    GLOBAL_IDT.kernelISR(148, isr148);
    GLOBAL_IDT.kernelISR(149, isr149);
    GLOBAL_IDT.kernelISR(150, isr150);
    GLOBAL_IDT.kernelISR(151, isr151);
    GLOBAL_IDT.kernelISR(152, isr152);
    GLOBAL_IDT.kernelISR(153, isr153);
    GLOBAL_IDT.kernelISR(154, isr154);
    GLOBAL_IDT.kernelISR(155, isr155);
    GLOBAL_IDT.kernelISR(156, isr156);
    GLOBAL_IDT.kernelISR(157, isr157);
    GLOBAL_IDT.kernelISR(158, isr158);
    GLOBAL_IDT.kernelISR(159, isr159);
    GLOBAL_IDT.kernelISR(160, isr160);
    GLOBAL_IDT.kernelISR(161, isr161);
    GLOBAL_IDT.kernelISR(162, isr162);
    GLOBAL_IDT.kernelISR(163, isr163);
    GLOBAL_IDT.kernelISR(164, isr164);
    GLOBAL_IDT.kernelISR(165, isr165);
    GLOBAL_IDT.kernelISR(166, isr166);
    GLOBAL_IDT.kernelISR(167, isr167);
    GLOBAL_IDT.kernelISR(168, isr168);
    GLOBAL_IDT.kernelISR(169, isr169);
    GLOBAL_IDT.kernelISR(170, isr170);
    GLOBAL_IDT.kernelISR(171, isr171);
    GLOBAL_IDT.kernelISR(172, isr172);
    GLOBAL_IDT.kernelISR(173, isr173);
    GLOBAL_IDT.kernelISR(174, isr174);
    GLOBAL_IDT.kernelISR(175, isr175);
    GLOBAL_IDT.kernelISR(176, isr176);
    GLOBAL_IDT.kernelISR(177, isr177);
    GLOBAL_IDT.kernelISR(178, isr178);
    GLOBAL_IDT.kernelISR(179, isr179);
    GLOBAL_IDT.kernelISR(180, isr180);
    GLOBAL_IDT.kernelISR(181, isr181);
    GLOBAL_IDT.kernelISR(182, isr182);
    GLOBAL_IDT.kernelISR(183, isr183);
    GLOBAL_IDT.kernelISR(184, isr184);
    GLOBAL_IDT.kernelISR(185, isr185);
    GLOBAL_IDT.kernelISR(186, isr186);
    GLOBAL_IDT.kernelISR(187, isr187);
    GLOBAL_IDT.kernelISR(188, isr188);
    GLOBAL_IDT.kernelISR(189, isr189);
    GLOBAL_IDT.kernelISR(190, isr190);
    GLOBAL_IDT.kernelISR(191, isr191);
    GLOBAL_IDT.kernelISR(192, isr192);
    GLOBAL_IDT.kernelISR(193, isr193);
    GLOBAL_IDT.kernelISR(194, isr194);
    GLOBAL_IDT.kernelISR(195, isr195);
    GLOBAL_IDT.kernelISR(196, isr196);
    GLOBAL_IDT.kernelISR(197, isr197);
    GLOBAL_IDT.kernelISR(198, isr198);
    GLOBAL_IDT.kernelISR(199, isr199);
    GLOBAL_IDT.kernelISR(200, isr200);
    GLOBAL_IDT.kernelISR(201, isr201);
    GLOBAL_IDT.kernelISR(202, isr202);
    GLOBAL_IDT.kernelISR(203, isr203);
    GLOBAL_IDT.kernelISR(204, isr204);
    GLOBAL_IDT.kernelISR(205, isr205);
    GLOBAL_IDT.kernelISR(206, isr206);
    GLOBAL_IDT.kernelISR(207, isr207);
    GLOBAL_IDT.kernelISR(208, isr208);
    GLOBAL_IDT.kernelISR(209, isr209);
    GLOBAL_IDT.kernelISR(210, isr210);
    GLOBAL_IDT.kernelISR(211, isr211);
    GLOBAL_IDT.kernelISR(212, isr212);
    GLOBAL_IDT.kernelISR(213, isr213);
    GLOBAL_IDT.kernelISR(214, isr214);
    GLOBAL_IDT.kernelISR(215, isr215);
    GLOBAL_IDT.kernelISR(216, isr216);
    GLOBAL_IDT.kernelISR(217, isr217);
    GLOBAL_IDT.kernelISR(218, isr218);
    GLOBAL_IDT.kernelISR(219, isr219);
    GLOBAL_IDT.kernelISR(220, isr220);
    GLOBAL_IDT.kernelISR(221, isr221);
    GLOBAL_IDT.kernelISR(222, isr222);
    GLOBAL_IDT.kernelISR(223, isr223);
    GLOBAL_IDT.kernelISR(224, isr224);
    GLOBAL_IDT.kernelISR(225, isr225);
    GLOBAL_IDT.kernelISR(226, isr226);
    GLOBAL_IDT.kernelISR(227, isr227);
    GLOBAL_IDT.kernelISR(228, isr228);
    GLOBAL_IDT.kernelISR(229, isr229);
    GLOBAL_IDT.kernelISR(230, isr230);
    GLOBAL_IDT.kernelISR(231, isr231);
    GLOBAL_IDT.kernelISR(232, isr232);
    GLOBAL_IDT.kernelISR(233, isr233);
    GLOBAL_IDT.kernelISR(234, isr234);
    GLOBAL_IDT.kernelISR(235, isr235);
    GLOBAL_IDT.kernelISR(236, isr236);
    GLOBAL_IDT.kernelISR(237, isr237);
    GLOBAL_IDT.kernelISR(238, isr238);
    GLOBAL_IDT.kernelISR(239, isr239);
    GLOBAL_IDT.kernelISR(240, isr240);
    GLOBAL_IDT.kernelISR(241, isr241);
    GLOBAL_IDT.kernelISR(242, isr242);
    GLOBAL_IDT.kernelISR(243, isr243);
    GLOBAL_IDT.kernelISR(244, isr244);
    GLOBAL_IDT.kernelISR(245, isr245);
    GLOBAL_IDT.kernelISR(246, isr246);
    GLOBAL_IDT.kernelISR(247, isr247);
    GLOBAL_IDT.kernelISR(248, isr248);
    GLOBAL_IDT.kernelISR(249, isr249);
    GLOBAL_IDT.kernelISR(250, isr250);
    GLOBAL_IDT.kernelISR(251, isr251);
    GLOBAL_IDT.kernelISR(252, isr252);
    GLOBAL_IDT.kernelISR(253, isr253);
    GLOBAL_IDT.kernelISR(254, isr254);
    GLOBAL_IDT.kernelISR(255, isr255);
}

// TODO: Use callconv(.Interrupt) functions when they work
comptime {
    // isr_stub_next saves cpu state on stack which is used as an `irq.ISRFrame` pointer
    asm (
        \\.global isr_stub_next
        \\isr_stub_next:
        \\    push %rbp  
        \\    push %rax   
        \\    push %rbx   
        \\    push %rcx   
        \\    push %rdx   
        \\    push %rsi   
        \\    push %rdi   
        \\    mov %rsp, %rdi
        // \\    pushq $0 // Align stack
        \\    call isr_handler
        \\    mov %rax, %rsp
        \\    pop %rdi
        \\    pop %rsi
        \\    pop %rdx
        \\    pop %rcx
        \\    pop %rbx
        \\    pop %rax  
        \\    pop %rbp
        //    account for the vector and dummy error code we pushed in `irq.isr_stub`
        \\    add $16, %rsp
        \\    iretq
    );

    asm (
        \\.global isr_stub_next_err
        \\isr_stub_next_err:
        \\    push %rbp  
        \\    push %rax   
        \\    push %rbx   
        \\    push %rcx   
        \\    push %rdx   
        \\    push %rsi   
        \\    push %rdi   
        \\    mov %rsp, %rdi
        // \\    pushq $0 // Align stack
        \\    call isr_handler
        \\    mov %rax, %rsp
        \\    pop %rdi
        \\    pop %rsi
        \\    pop %rdx
        \\    pop %rcx
        \\    pop %rbx
        \\    pop %rax  
        \\    pop %rbp
        //    account for the vector we pushed in `irq.isr_stub_err`
        \\    add $8, %rsp
        \\    iretq
    );
}

/// Pushes vector number and dummy error code on stack.
/// Interrupts are also cleared so we don't have to handle nested interrupts.
/// 
/// This should never be called directly and is jmped to in asm
inline fn isr_stub(comptime vector: u64) void {
    asm volatile (
    // Interrupts will be restored on iretq
        \\cli
        \\pushq $0   
        \\pushq %[vector]
        \\jmp isr_stub_next
        :
        : [vector] "n" (vector),
    );
}

/// Pushes vector number and on stack.
/// Interrupts are also cleared so we don't have to handle nested interrupts.
/// 
/// This should never be called directly and is jmped to in asm
inline fn isr_stub_err(comptime vector: u64) void {
    asm volatile (
        \\cli
        \\pushq %[vector]
        \\jmp isr_stub_next_err
        :
        : [vector] "n" (vector),
    );
}

// Functions generated by virt.js

fn isr0() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (0)); }
fn isr1() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (1)); }
fn isr2() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (2)); }
fn isr3() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (3)); }
fn isr4() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (4)); }
fn isr5() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (5)); }
fn isr6() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (6)); }
fn isr7() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (7)); }
fn isr8() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (8)); }
fn isr9() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (9)); }
fn isr10() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (10)); }
fn isr11() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (11)); }
fn isr12() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (12)); }
fn isr13() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (13)); }
fn isr14() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (14)); }
fn isr15() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (15)); }
fn isr16() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (16)); }
fn isr17() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (17)); }
fn isr18() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (18)); }
fn isr19() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (19)); }
fn isr20() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (20)); }
fn isr21() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (21)); }
fn isr22() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (22)); }
fn isr23() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (23)); }
fn isr24() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (24)); }
fn isr25() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (25)); }
fn isr26() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (26)); }
fn isr27() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (27)); }
fn isr28() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (28)); }
fn isr29() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (29)); }
fn isr30() callconv(.Naked) void { asm volatile ("cli; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (30)); }
fn isr31() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (31)); }
fn isr32() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (32)); }
fn isr33() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (33)); }
fn isr34() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (34)); }
fn isr35() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (35)); }
fn isr36() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (36)); }
fn isr37() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (37)); }
fn isr38() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (38)); }
fn isr39() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (39)); }
fn isr40() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (40)); }
fn isr41() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (41)); }
fn isr42() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (42)); }
fn isr43() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (43)); }
fn isr44() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (44)); }
fn isr45() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (45)); }
fn isr46() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (46)); }
fn isr47() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (47)); }
fn isr48() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (48)); }
fn isr49() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (49)); }
fn isr50() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (50)); }
fn isr51() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (51)); }
fn isr52() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (52)); }
fn isr53() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (53)); }
fn isr54() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (54)); }
fn isr55() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (55)); }
fn isr56() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (56)); }
fn isr57() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (57)); }
fn isr58() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (58)); }
fn isr59() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (59)); }
fn isr60() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (60)); }
fn isr61() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (61)); }
fn isr62() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (62)); }
fn isr63() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (63)); }
fn isr64() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (64)); }
fn isr65() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (65)); }
fn isr66() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (66)); }
fn isr67() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (67)); }
fn isr68() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (68)); }
fn isr69() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (69)); }
fn isr70() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (70)); }
fn isr71() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (71)); }
fn isr72() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (72)); }
fn isr73() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (73)); }
fn isr74() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (74)); }
fn isr75() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (75)); }
fn isr76() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (76)); }
fn isr77() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (77)); }
fn isr78() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (78)); }
fn isr79() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (79)); }
fn isr80() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (80)); }
fn isr81() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (81)); }
fn isr82() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (82)); }
fn isr83() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (83)); }
fn isr84() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (84)); }
fn isr85() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (85)); }
fn isr86() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (86)); }
fn isr87() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (87)); }
fn isr88() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (88)); }
fn isr89() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (89)); }
fn isr90() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (90)); }
fn isr91() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (91)); }
fn isr92() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (92)); }
fn isr93() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (93)); }
fn isr94() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (94)); }
fn isr95() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (95)); }
fn isr96() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (96)); }
fn isr97() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (97)); }
fn isr98() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (98)); }
fn isr99() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (99)); }
fn isr100() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (100)); }
fn isr101() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (101)); }
fn isr102() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (102)); }
fn isr103() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (103)); }
fn isr104() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (104)); }
fn isr105() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (105)); }
fn isr106() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (106)); }
fn isr107() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (107)); }
fn isr108() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (108)); }
fn isr109() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (109)); }
fn isr110() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (110)); }
fn isr111() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (111)); }
fn isr112() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (112)); }
fn isr113() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (113)); }
fn isr114() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (114)); }
fn isr115() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (115)); }
fn isr116() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (116)); }
fn isr117() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (117)); }
fn isr118() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (118)); }
fn isr119() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (119)); }
fn isr120() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (120)); }
fn isr121() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (121)); }
fn isr122() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (122)); }
fn isr123() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (123)); }
fn isr124() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (124)); }
fn isr125() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (125)); }
fn isr126() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (126)); }
fn isr127() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (127)); }
fn isr128() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (128)); }
fn isr129() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (129)); }
fn isr130() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (130)); }
fn isr131() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (131)); }
fn isr132() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (132)); }
fn isr133() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (133)); }
fn isr134() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (134)); }
fn isr135() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (135)); }
fn isr136() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (136)); }
fn isr137() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (137)); }
fn isr138() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (138)); }
fn isr139() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (139)); }
fn isr140() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (140)); }
fn isr141() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (141)); }
fn isr142() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (142)); }
fn isr143() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (143)); }
fn isr144() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (144)); }
fn isr145() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (145)); }
fn isr146() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (146)); }
fn isr147() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (147)); }
fn isr148() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (148)); }
fn isr149() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (149)); }
fn isr150() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (150)); }
fn isr151() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (151)); }
fn isr152() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (152)); }
fn isr153() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (153)); }
fn isr154() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (154)); }
fn isr155() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (155)); }
fn isr156() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (156)); }
fn isr157() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (157)); }
fn isr158() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (158)); }
fn isr159() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (159)); }
fn isr160() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (160)); }
fn isr161() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (161)); }
fn isr162() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (162)); }
fn isr163() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (163)); }
fn isr164() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (164)); }
fn isr165() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (165)); }
fn isr166() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (166)); }
fn isr167() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (167)); }
fn isr168() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (168)); }
fn isr169() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (169)); }
fn isr170() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (170)); }
fn isr171() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (171)); }
fn isr172() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (172)); }
fn isr173() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (173)); }
fn isr174() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (174)); }
fn isr175() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (175)); }
fn isr176() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (176)); }
fn isr177() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (177)); }
fn isr178() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (178)); }
fn isr179() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (179)); }
fn isr180() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (180)); }
fn isr181() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (181)); }
fn isr182() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (182)); }
fn isr183() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (183)); }
fn isr184() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (184)); }
fn isr185() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (185)); }
fn isr186() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (186)); }
fn isr187() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (187)); }
fn isr188() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (188)); }
fn isr189() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (189)); }
fn isr190() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (190)); }
fn isr191() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (191)); }
fn isr192() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (192)); }
fn isr193() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (193)); }
fn isr194() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (194)); }
fn isr195() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (195)); }
fn isr196() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (196)); }
fn isr197() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (197)); }
fn isr198() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (198)); }
fn isr199() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (199)); }
fn isr200() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (200)); }
fn isr201() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (201)); }
fn isr202() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (202)); }
fn isr203() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (203)); }
fn isr204() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (204)); }
fn isr205() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (205)); }
fn isr206() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (206)); }
fn isr207() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (207)); }
fn isr208() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (208)); }
fn isr209() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (209)); }
fn isr210() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (210)); }
fn isr211() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (211)); }
fn isr212() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (212)); }
fn isr213() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (213)); }
fn isr214() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (214)); }
fn isr215() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (215)); }
fn isr216() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (216)); }
fn isr217() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (217)); }
fn isr218() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (218)); }
fn isr219() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (219)); }
fn isr220() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (220)); }
fn isr221() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (221)); }
fn isr222() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (222)); }
fn isr223() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (223)); }
fn isr224() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (224)); }
fn isr225() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (225)); }
fn isr226() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (226)); }
fn isr227() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (227)); }
fn isr228() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (228)); }
fn isr229() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (229)); }
fn isr230() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (230)); }
fn isr231() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (231)); }
fn isr232() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (232)); }
fn isr233() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (233)); }
fn isr234() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (234)); }
fn isr235() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (235)); }
fn isr236() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (236)); }
fn isr237() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (237)); }
fn isr238() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (238)); }
fn isr239() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (239)); }
fn isr240() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (240)); }
fn isr241() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (241)); }
fn isr242() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (242)); }
fn isr243() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (243)); }
fn isr244() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (244)); }
fn isr245() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (245)); }
fn isr246() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (246)); }
fn isr247() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (247)); }
fn isr248() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (248)); }
fn isr249() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (249)); }
fn isr250() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (250)); }
fn isr251() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (251)); }
fn isr252() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (252)); }
fn isr253() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (253)); }
fn isr254() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (254)); }
fn isr255() callconv(.Naked) void { asm volatile ("cli; pushq $0; pushq %[vector]; jmp isr_stub_next" : : [vector] "n" (255)); }
