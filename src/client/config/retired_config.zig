//! Retired configuration keys (docs/configuration.md#retired-keys): a file
//! that still sets one loads without it, and the person is told which keys
//! were ignored, in the window and by `telar config check`.
const std = @import("std");
const data = @import("model");
const RetiredConfigKey = @import("RetiredConfigKey.zig").RetiredConfigKey;
const Client = @import("../execution/Client.zig");
const notifications = @import("../notifications/notifications.zig");

pub const Set = std.EnumSet(RetiredConfigKey);

const lead = "Ignored ";
const separator = ", ";
const tail = ": only the retired terminal client used them; remove them";

/// Room for every retired key and the sentence around them, counted from
/// the keys, so a new key never outgrows it.
pub const max_description_bytes = describedBytes();

/// One sentence naming the ignored keys, or an empty slice when none is set.
/// Example: `const text = retired_config.describe(snapshot.retired, &buffer);`
pub fn describe(retired: Set, buffer: *[max_description_bytes]u8) []const u8 {
    if (retired.count() == 0) {
        return "";
    }

    // The buffer holds every key (`describedBytes`), so no write fails.
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll(lead) catch unreachable;
    var keys = retired.iterator();
    var first = true;
    while (keys.next()) |key| {
        if (!first) {
            writer.writeAll(separator) catch unreachable;
        }

        writer.writeAll(key.path()) catch unreachable;
        first = false;
    }

    writer.writeAll(tail) catch unreachable;
    return writer.buffered();
}

fn describedBytes() usize {
    var bytes: usize = lead.len + tail.len;
    for (std.enums.values(RetiredConfigKey)) |key| {
        bytes += key.path().len + separator.len;
    }

    return bytes;
}

/// Tells the person which keys the active configuration ignored.
/// Example: `try retired_config.announce(client, generation.snapshot.retired);`
pub fn announce(client: *Client, retired: Set) !void {
    var buffer: [max_description_bytes]u8 = undefined;
    const message = describe(retired, &buffer);
    if (message.len == 0) {
        return;
    }

    try notifications.publishNotificationNow(
        client,
        .{
            .level = .warning,
            .title = "Configuration keys ignored",
            .message = message,
        },
    );
}

test "every retired key fits the description" {
    var buffer: [max_description_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("", describe(.initEmpty(), &buffer));

    const all = describe(.initFull(), &buffer);
    try std.testing.expect(std.mem.startsWith(u8, all, "Ignored client.sidebar.renderer, "));
    try std.testing.expect(std.mem.endsWith(u8, all, "client.icons: only the retired terminal client used them; remove them"));
}
