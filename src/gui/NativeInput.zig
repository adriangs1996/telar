const std = @import("std");
const client = @import("telar-client");
const Event = @import("native/native.zig").InputEvent;
const Item = @import("input_item.zig").Item;
const Input = @This();

pub const max_paste_bytes = 64 * 1024;
const capacity = 1024;
items: [capacity]Item = undefined,
head: usize = 0,
len: usize = 0,

/// Copies borrowed native input before returning to the platform callback.
/// A whole paste is admitted or rejected. Example: `try input.accept(event);`
pub fn accept(input: *Input, event: Event) !void {
    if (event.len > max_paste_bytes) {
        return error.InputTooLarge;
    }

    if ((event.len != 0 and event.text == null) or event.mods > 7 or event.phase < 1 or event.phase > 3) {
        return error.InvalidNativeInput;
    }

    const text = if (event.text) |ptr| ptr[0..event.len] else "";
    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    switch (event.kind) {
        1 => {
            const view = try std.unicode.Utf8View.init(text);
            var iterator = view.iterator();
            var count: usize = 0;
            while (iterator.nextCodepoint() != null) {
                count += 1;
            }

            try input.reserve(count);
            iterator = view.iterator();
            while (iterator.nextCodepointSlice()) |bytes| {
                var key: client.Key = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(bytes.len) } }, .phase = @enumFromInt(event.phase) };
                @memcpy(key.code.char.bytes[0..bytes.len], bytes);
                input.push(.{ .key = key });
            }
        },
        2 => {
            if (text.len == 0) {
                return;
            }

            try input.reserve((text.len + 255) / 256 + 2);
            input.push(.paste_start);
            var offset: usize = 0;
            while (offset < text.len) {
                const count = @min(256, text.len - offset);
                var chunk: @import("PasteChunk.zig") = .{ .len = @intCast(count) };
                @memcpy(chunk.bytes[0..count], text[offset..][0..count]);
                input.push(.{ .paste_text = chunk });
                offset += count;
            }

            input.push(.paste_finish);
        },
        3 => {
            try input.reserve(1);
            const codes = [_]client.Key.Code{ .enter, .tab, .backspace, .escape, .up, .down, .left, .right, .home, .end, .delete, .page_up, .page_down };
            const key: client.Key = .{
                .code = if (event.code >= 1 and event.code <= codes.len) codes[event.code - 1] else return error.InvalidNativeKey,
                .mods = @bitCast(@as(u3, @truncate(event.mods))),
                .phase = if (event.phase >= 1 and event.phase <= 3) @enumFromInt(event.phase) else return error.InvalidNativeKey,
            };
            input.push(.{ .key = key });
        },
        4 => {
            try input.reserve(1);
            var key: client.Key = .{
                .code = .{ .char = .{ .bytes = @splat(0), .len = 0 } },
                .mods = @bitCast(@as(u3, @truncate(event.mods))),
                .phase = if (event.phase >= 1 and event.phase <= 3) @enumFromInt(event.phase) else return error.InvalidNativeKey,
            };
            key.code.char.len = try std.unicode.utf8Encode(std.math.cast(u21, event.code) orelse return error.InvalidNativeKey, &key.code.char.bytes);
            input.push(.{ .key = key });
        },
        else => return error.InvalidNativeInput,
    }
}

/// Stops before the shared outbox fills, resuming on transport completion.
/// Example: `try input.drain(&gui.app);`
pub fn drain(input: *Input, app: *client.AttachedClient) !void {
    if (app.startup.holdsInput()) {
        return;
    }

    while (input.len != 0 and client.runtime_io.availableCapacity(app) >= 4) {
        switch (input.items[input.head]) {
            .key => |key| _ = try client.controllers.pane_inputs.send(app, .{ .target = .focused, .source = .host, .payload = .{ .key = key } }),
            .paste_start => _ = try client.controllers.pane_pastes.start(app),
            .paste_text => |*chunk| _ = try client.controllers.pane_pastes.content(app, chunk.bytes[0..chunk.len]),
            .paste_finish => _ = try client.controllers.pane_pastes.finish(app),
        }

        input.head = (input.head + 1) % capacity;
        input.len -= 1;
    }
}

fn reserve(input: *const Input, count: usize) !void {
    if (count > capacity - input.len) {
        return error.NativeInputFull;
    }
}

fn push(input: *Input, item: Item) void {
    input.items[(input.head + input.len) % capacity] = item;
    input.len += 1;
}

test "native paste admission is atomic and owns the borrowed bytes" {
    var input: Input = .{};
    var bytes = [_]u8{'x'} ** 257;
    try input.accept(.{ .kind = 2, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'y');
    try std.testing.expectEqual(@as(usize, 4), input.len);
    try std.testing.expectEqual(@as(u8, 'x'), input.items[1].paste_text.bytes[0]);
    input.len = capacity - 1;
    try std.testing.expectError(error.NativeInputFull, input.accept(.{ .kind = 2, .text = &bytes, .len = bytes.len }));
    try std.testing.expectEqual(capacity - 1, input.len);
}
