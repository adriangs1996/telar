const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const prompt_scan = @import("src/backend/history/prompt_scan.zig");
const codex_screen = @import("src/backend/history/codex_screen.zig");
const cursor_screen = @import("src/backend/history/cursor_screen.zig");

const Input = extern struct {
    bytes: [*]const u8,
    length: usize,
    columns: u16,
    rows: u16,
    chunk: u16,
    provider: u8,
    manifests: u8,
};

export fn scan_screen(input: *const Input) u32 {
    return scan(input) catch 0x80000000;
}

fn scan(input: *const Input) !u32 {
    const allocator = std.heap.c_allocator;
    var terminal = try vt.Terminal.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{ .cols = input.columns, .rows = input.rows });
    defer terminal.deinit(allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    var remaining = input.bytes[0..input.length];
    while (remaining.len != 0) {
        const count = if (input.chunk == 0) remaining.len else @min(input.chunk, remaining.len);
        stream.nextSlice(remaining[0..count]);
        remaining = remaining[count..];
    }

    var manifests: core.Table = .{};
    if (input.manifests != 0) {
        const codex = try manifests.add("codex");
        try codex.ready_prompt.append("ask codex to do anything");
    }

    const provider: core.AgentProvider = @enumFromInt(input.provider);
    const signal = switch (provider) {
        .claude => prompt_scan.scanReadyPrompt(&terminal),
        .codex => codex_screen.scan(&terminal, &manifests),
        .cursor => cursor_screen.scan(&terminal),
        else => null,
    };
    var result: u32 = @as(u32, @intFromBool(prompt_scan.showsRestoredDraft(&terminal, provider))) << 6;
    if (signal) |observed| {
        result |= switch (observed.status) {
            .working => @as(u32, 1),
            .blocked => @as(u32, 2),
            .ready => @as(u32, 3),
        };
        result |= @as(u32, @intFromBool(observed.identity_confirmed)) << 4;
        result |= @as(u32, @intFromBool(observed.ready_confirmed)) << 5;
        result |= @as(u32, observed.confidence) << 8;
    }

    return result;
}
