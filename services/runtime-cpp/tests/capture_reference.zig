const std = @import("std");
const capture_library = @import("capture");
const Half = capture_library.GenericHalf(void);

const Operation = extern struct {
    bytes: [*]const u8,
    length: usize,
    kind: u32,
    slot: u32,
};

const Input = extern struct {
    operations: [*]const Operation,
    count: usize,
    part_limit: usize,
    exchange_limit: usize,
    total_limit: usize,
    fail_allocation: usize,
    output: [*]u8,
    output_capacity: usize,
    enabled: u8,
};

const Result = extern struct {
    length: usize,
    allocation_calls: usize,
    retained_allocations: usize,
    retained_quota: usize,
    overflow: u8,
};

const Memory = struct {
    fail: usize,
    calls: usize = 0,
    live: usize = 0,

    fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(context));
        const call = self.calls;
        self.calls += 1;
        if (call == self.fail) {
            return null;
        }
        const pointer = std.heap.c_allocator.rawAlloc(length, alignment, address) orelse return null;
        self.live += 1;
        return pointer;
    }

    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.live -= 1;
        std.heap.c_allocator.rawFree(bytes, alignment, address);
    }
};

const Output = struct {
    input: *const Input,
    result: *Result,

    fn integer(self: *Output, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.append(&bytes);
    }

    fn text(self: *Output, bytes: []const u8) void {
        self.integer(bytes.len);
        self.append(bytes);
    }

    fn append(self: *Output, bytes: []const u8) void {
        if (bytes.len > self.input.output_capacity - self.result.length) {
            self.result.overflow = 1;
            return;
        }
        @memcpy(self.input.output[self.result.length..][0..bytes.len], bytes);
        self.result.length += bytes.len;
    }

    fn record(self: *Output, slot: ?*Half) void {
        self.integer(@intFromBool(slot != null));
        const half = slot orelse return;
        self.integer(half.head.len);
        self.integer(half.body.len);
        self.integer(half.head.storage.len);
        self.integer(half.body.storage.len);
        self.integer(half.captured_bytes);
        self.integer(@intFromBool(half.head.truncated));
        self.integer(@intFromBool(half.body.truncated));
        self.integer(@intFromBool(half.truncation.part));
        self.integer(@intFromBool(half.truncation.exchange));
        self.integer(@intFromBool(half.truncation.total));
        self.integer(@intFromEnum(half.outcome));
        self.integer(@intCast(half.finished_at_ms));
    }
};

fn apply(half: *Half, operation: Operation) bool {
    const bytes = operation.bytes[0..operation.length];
    if (operation.kind >= 2 and operation.kind <= 5) {
        return half.append(@enumFromInt(operation.kind - 2), bytes);
    }
    switch (operation.kind) {
        6 => half.appendHead(bytes),
        7 => {
            half.captured_bytes -= half.head.len;
            half.head.reset();
        },
        8 => {
            half.captured_bytes -= half.body.len;
            half.body.reset();
        },
        9 => half.setMethod(bytes),
        10 => half.setTarget(bytes),
        11 => half.setEncoding(bytes),
        12 => half.finish(@enumFromInt(operation.length % 3), @intCast(operation.length)),
        else => {},
    }
    return false;
}

export fn capture(input: *const Input, result: *Result) void {
    result.* = std.mem.zeroes(Result);
    var memory = Memory{ .fail = input.fail_allocation };
    var quota = capture_library.Quota.init(input.total_limit);
    const config: capture_library.Config = .{ .enabled = input.enabled != 0, .max_part_bytes = input.part_limit, .max_exchange_bytes = input.exchange_limit, .max_total_bytes = input.total_limit };
    var halves: [4]?*Half = .{null} ** 4;
    var output = Output{ .input = input, .result = result };
    for (input.operations[0..input.count]) |operation| {
        const slot = &halves[operation.slot % halves.len];
        var accepted = false;
        if (operation.kind <= 1) {
            if (slot.*) |half| half.deinit();
            slot.* = Half.create(.{
                .gpa = memory.allocator(),
                .quota = &quota,
                .config = config,
                .meta = {},
                .key = .{ .connection_id = 0, .stream_id = 0 },
                .side = @enumFromInt(operation.kind),
                .host = operation.bytes[0..operation.length],
                .started_at_ms = 0,
            });
        } else if (operation.kind == 13) {
            if (slot.*) |half| half.deinit();
            slot.* = null;
        } else if (slot.*) |half| {
            accepted = apply(half, operation);
        }
        output.integer(@intFromBool(accepted));
        output.integer(quota.used());
        output.record(slot.*);
    }
    for (&halves) |*slot| {
        if (slot.*) |half| {
            output.text(half.host());
            output.text(half.method());
            output.text(half.target());
            output.text(half.encoding());
            output.text(half.head.bytes());
            output.text(half.body.bytes());
            half.deinit();
            slot.* = null;
        }
    }
    result.allocation_calls = memory.calls;
    result.retained_allocations = memory.live;
    result.retained_quota = quota.used();
}

export fn batch(input: *const Input, iterations: usize) u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        var result: Result = undefined;
        capture(input, &result);
        checksum += result.length + result.allocation_calls;
    }
    return checksum;
}
