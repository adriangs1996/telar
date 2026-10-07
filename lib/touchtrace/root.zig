//! Client requests for the touchrange Valgrind tool: register byte ranges,
//! then record which of their bytes a window of code reads or writes.
//! Natively the request sequence is a no-op that returns the default, so
//! nothing is recorded or printed.
const builtin = @import("builtin");

const Request = enum(usize) {
    running_on_valgrind = 0x1001,
    range = tool_base,
    start = tool_base + 1,
    stop = tool_base + 2,
};

const Arguments = struct {
    first: usize = 0,
    second: usize = 0,
    third: usize = 0,
};

const tool_base = (@as(usize, 'T') << 24) | (@as(usize, 'R') << 16);

/// Starts recording when `traced` is set.
/// Example: `touchtrace.start(iteration == last);`
pub fn start(traced: bool) void {
    if (traced) {
        _ = request(.start, .{});
    }
}

/// Stops recording and prints the touched runs under `label`.
/// Example: `touchtrace.stop(traced, "frame/server");`
pub fn stop(traced: bool, label: [:0]const u8) void {
    if (traced) {
        _ = request(.stop, .{
            .first = @intFromPtr(label.ptr),
        });
    }
}

fn request(code: Request, arguments: Arguments) usize {
    const words = [_]usize{ @intFromEnum(code), arguments.first, arguments.second, arguments.third, 0, 0 };
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ror x12, x12, #3  ; ror x12, x12, #13
            \\ ror x12, x12, #51 ; ror x12, x12, #61
            \\ orr x10, x10, x10
            : [_] "={x3}" (-> usize),
            : [_] "{x4}" (&words),
              [_] "{x3}" (@as(usize, 0)),
            : .{ .memory = true }),
        .x86_64 => asm volatile (
            \\ rolq $3,  %%rdi ; rolq $13, %%rdi
            \\ rolq $61, %%rdi ; rolq $51, %%rdi
            \\ xchgq %%rbx,%%rbx
            : [_] "={rdx}" (-> usize),
            : [_] "{rax}" (&words),
              [_] "{rdx}" (@as(usize, 0)),
            : .{ .cc = true, .memory = true }),
        else => 0,
    };
}
