const std = @import("std");
const escape = @import("telar-history-escape");

const probe =
    "\x1b]133;A\x07" ++
    "\x1b_Gm=0;AAAA\x1b\\" ++
    "\x1b[200~x\n\x1b[201~\r";

pub export fn zig_fuzz_init() callconv(.c) void {}

pub export fn zig_fuzz_test(buf: [*]const u8, len: usize) callconv(.c) void {
    if (len == 0) {
        return;
    }

    const input = buf[1..len];
    const chunk_size = @as(usize, buf[0] % 32) + 1;

    driveOsc(input);
    expectEqual(
        observeKittyWhole(input),
        observeKittyChunked(input, chunk_size),
        "kitty framing split mismatch",
    );
    expectEqual(
        observeInputWhole(input),
        observeInputChunked(input, chunk_size),
        "input scanner split mismatch",
    );
}

fn driveOsc(input: []const u8) void {
    var scanner: escape.OscScanner = .{};
    var digest: u64 = 0xcbf29ce484222325;
    for (input) |byte| {
        digest = updateOscDigest(digest, scanner.next(byte));
    }
    for (probe) |byte| {
        digest = updateOscDigest(digest, scanner.next(byte));
    }
    std.mem.doNotOptimizeAway(digest);
}

fn updateOscDigest(digest: u64, event: escape.OscScanner.Event) u64 {
    const value: u8 = switch (event) {
        .none => 0,
        .start => 1,
        .byte => |byte| byte,
        .end => 2,
    };
    return (digest ^ value) *% 0x100000001b3;
}

fn observeKittyWhole(input: []const u8) usize {
    var counter: escape.KittyFramingCounter = .{};
    var complete = counter.observe(input);
    complete += counter.observe(probe);
    return complete;
}

fn observeKittyChunked(input: []const u8, chunk_size: usize) usize {
    var counter: escape.KittyFramingCounter = .{};
    var complete: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        const end = @min(input.len, index + chunk_size);
        complete += counter.observe(input[index..end]);
        index = end;
    }
    complete += counter.observe(probe);
    return complete;
}

fn observeInputWhole(input: []const u8) escape.InputScanner.Event {
    var scanner: escape.InputScanner = .{};
    return mergeInput(scanner.feed(input), scanner.feed(probe));
}

fn observeInputChunked(input: []const u8, chunk_size: usize) escape.InputScanner.Event {
    var scanner: escape.InputScanner = .{};
    var event: escape.InputScanner.Event = .{};
    var index: usize = 0;
    while (index < input.len) {
        const end = @min(input.len, index + chunk_size);
        event = mergeInput(event, scanner.feed(input[index..end]));
        index = end;
    }
    return mergeInput(event, scanner.feed(probe));
}

fn mergeInput(a: escape.InputScanner.Event, b: escape.InputScanner.Event) escape.InputScanner.Event {
    return .{
        .submitted = a.submitted or b.submitted,
        .cancelled = a.cancelled or b.cancelled,
    };
}

fn expectEqual(actual: anytype, expected: @TypeOf(actual), message: []const u8) void {
    if (!std.meta.eql(actual, expected)) {
        std.debug.panic("{s}", .{message});
    }
}
