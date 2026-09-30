//! The options of one pick list: a label to search and show, the value its
//! `on_select` command receives, and an optional detail shown beside the
//! label. Every string lives in one fixed byte buffer, so a list costs the
//! same whatever its items and never allocates.
const std = @import("std");
const PickItem = @import("PickItem.zig");
const bar_text = @import("bar_text.zig");
const PickItems = @This();

pub const max_items = 1024;
/// Room for every label, value and detail of the list together.
pub const max_text_bytes = 128 * 1024;
pub const max_label_bytes = 128;
pub const max_value_bytes = 512;
pub const max_detail_bytes = 128;

bytes: [max_text_bytes]u8 = undefined,
used: u32 = 0,
labels: [max_items]Range = undefined,
values: [max_items]Range = undefined,
details: [max_items]Range = undefined,
count: u16 = 0,

/// A byte range inside `bytes`; its offset reaches past 64 KiB.
const Range = struct {
    offset: u32 = 0,
    len: u16 = 0,
};

/// Appends one validated option. A value equal to its label shares the
/// label's bytes.
///
/// ```zig
/// try items.append(.{ .label = "claude-opus-5-5", .value = "anthropic/claude-opus-5-5", .detail = "anthropic" });
/// ```
pub fn append(self: *PickItems, item: PickItem) !void {
    if (self.count == max_items) {
        return error.TooManyPickItems;
    }

    const chosen = item.value orelse item.label;
    try check(item.label, max_label_bytes);
    try check(item.detail, max_detail_bytes);
    if (item.label.len == 0 or chosen.len == 0 or !bar_text.valid(item.label) or !bar_text.valid(item.detail) or !validValue(chosen)) {
        return error.InvalidPickItem;
    }

    if (chosen.len > max_value_bytes) {
        return error.PickItemTooLong;
    }

    const shared = std.mem.eql(u8, chosen, item.label);
    const needed = item.label.len + item.detail.len + (if (shared) 0 else chosen.len);
    if (self.used + needed > max_text_bytes) {
        return error.PickItemsTooLarge;
    }

    const index = self.count;
    self.labels[index] = self.store(item.label);
    self.values[index] = if (shared) self.labels[index] else self.store(chosen);
    self.details[index] = self.store(item.detail);
    self.count += 1;
}

/// Forgets every option. Example: `items.clear();`
pub fn clear(self: *PickItems) void {
    self.used = 0;
    self.count = 0;
}

/// Example: `const text = items.label(index);`
pub fn label(self: *const PickItems, index: u16) []const u8 {
    return self.text(self.labels[index]);
}

/// Example: `const argument = items.value(index);`
pub fn value(self: *const PickItems, index: u16) []const u8 {
    return self.text(self.values[index]);
}

/// Example: `const secondary = items.detail(index);`
pub fn detail(self: *const PickItems, index: u16) []const u8 {
    return self.text(self.details[index]);
}

fn text(self: *const PickItems, range: Range) []const u8 {
    return self.bytes[range.offset..][0..range.len];
}

fn store(self: *PickItems, source: []const u8) Range {
    const range: Range = .{
        .offset = self.used,
        .len = @intCast(source.len),
    };
    @memcpy(self.bytes[self.used..][0..source.len], source);
    self.used += @intCast(source.len);
    return range;
}

fn check(text_value: []const u8, limit: usize) !void {
    if (text_value.len > limit) {
        return error.PickItemTooLong;
    }
}

// A value becomes one argv element, so a tab from tabulated output may stay;
// any other control byte may not.
fn validValue(text_value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text_value)) {
        return false;
    }

    for (text_value) |byte| {
        if (byte != tab and (byte < printable_start or byte == delete_control)) {
            return false;
        }
    }

    return true;
}

const tab: u8 = '\t';
const printable_start: u8 = 0x20;
const delete_control: u8 = 0x7f;

test "items keep label, value and detail and share a value equal to its label" {
    var items: PickItems = .{};
    try items.append(.{ .label = "medium" });
    try items.append(.{ .label = "claude-opus-5-5", .value = "anthropic/claude-opus-5-5", .detail = "anthropic" });

    try std.testing.expectEqual(@as(u16, 2), items.count);
    try std.testing.expectEqualStrings("medium", items.value(0));
    try std.testing.expectEqualStrings("", items.detail(0));
    try std.testing.expectEqualStrings("anthropic/claude-opus-5-5", items.value(1));
    try std.testing.expectEqualStrings("anthropic", items.detail(1));
    try std.testing.expectEqual(@as(u32, "medium".len + "claude-opus-5-5".len + "anthropic/claude-opus-5-5".len + "anthropic".len), items.used);
}

test "items reject empty, control, oversized and surplus options" {
    var items: PickItems = .{};
    try std.testing.expectError(error.InvalidPickItem, items.append(.{ .label = "" }));
    try std.testing.expectError(error.InvalidPickItem, items.append(.{ .label = "a\nb" }));
    try std.testing.expectError(error.InvalidPickItem, items.append(.{ .label = "a", .value = "x\x00y" }));
    try std.testing.expectError(error.PickItemTooLong, items.append(.{ .label = "a" ** (max_label_bytes + 1) }));
    try std.testing.expectError(error.InvalidPickItem, items.append(.{ .label = "a\tb" }));
    try items.append(.{ .label = "a b", .value = "a\tb" });
    try std.testing.expectEqualStrings("a\tb", items.value(0));
    items.clear();
    try std.testing.expectEqual(@as(u16, 0), items.count);

    for (0..max_items) |_| {
        try items.append(.{ .label = "x" });
    }

    try std.testing.expectError(error.TooManyPickItems, items.append(.{ .label = "x" }));
}
