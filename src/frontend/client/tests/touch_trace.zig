//! Client requests for the touchrange Valgrind tool
//! (docs/performance/client-model-cache/touchrange). Natively the request
//! sequence is a no-op that returns the default, so nothing is printed.
const builtin = @import("builtin");
const std = @import("std");

pub const Range = enum(usize) {
    client = 0,
    adapter = 1,
    pane = 2,
};

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
const layout_depth = 3;

/// Registers the bytes of `value` as one traced range.
/// Example: `touch_trace.register(.client, client);`
pub fn register(range: Range, value: anytype) void {
    const Pointee = @typeInfo(@TypeOf(value)).pointer.child;
    const arguments: Arguments = .{
        .first = @intFromEnum(range),
        .second = @intFromPtr(value),
        .third = @sizeOf(Pointee),
    };

    if (running()) {
        std.debug.print(
            "TRB {d} {d} {d}\n",
            .{ arguments.first, arguments.second, arguments.third },
        );
    }

    _ = request(.range, arguments);
}

/// Starts recording when `traced` is set.
/// Example: `touch_trace.start(iteration == last);`
pub fn start(traced: bool) void {
    if (traced) {
        _ = request(.start, .{});
    }
}

/// Stops recording and prints the touched runs under `label`.
/// Example: `touch_trace.stop(traced, "frame/server");`
pub fn stop(traced: bool, label: [:0]const u8) void {
    if (traced) {
        _ = request(.stop, .{
            .first = @intFromPtr(label.ptr),
        });
    }
}

/// Prints the digest of what the traced session sent, so two builds can be
/// compared byte for byte.
/// Example: `touch_trace.reportOutput(&digest, messages, terminal_bytes);`
pub fn reportOutput(digest: []const u8, messages: u64, terminal_bytes: u64) void {
    if (!running()) {
        return;
    }

    std.debug.print(
        "TRD {x} {d} {d}\n",
        .{ digest, messages, terminal_bytes },
    );
}

/// Prints every field's offset and size down to `layout_depth` levels, so
/// the analysis can name the field behind each touched byte.
/// Example: `touch_trace.dumpLayout(Client, "Client");`
pub fn dumpLayout(comptime T: type, comptime name: []const u8) void {
    if (!running()) {
        return;
    }

    std.debug.print("TRL {s} 0 {d}\n", .{ name, @sizeOf(T) });
    dumpFields(
        T,
        name,
        0,
        layout_depth,
    );
}

fn dumpFields(comptime T: type, comptime prefix: []const u8, base: usize, comptime depth: usize) void {
    inline for (std.meta.fields(T)) |field| {
        const offset = base + @offsetOf(T, field.name);
        std.debug.print(
            "TRL {s}.{s} {d} {d}\n",
            .{ prefix, field.name, offset, @sizeOf(field.type) },
        );

        if (depth > 1 and comptime nested(field.type)) {
            dumpFields(
                field.type,
                prefix ++ "." ++ field.name,
                offset,
                depth - 1,
            );
        }
    }
}

fn nested(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.layout != .@"packed" and info.fields.len > 0,
        else => false,
    };
}

fn running() bool {
    return request(.running_on_valgrind, .{}) != 0;
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
