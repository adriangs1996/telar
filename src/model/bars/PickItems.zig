//! The options of one pick list: a label to search and show, the value its
//! `on_select` command receives, and an optional detail shown beside the
//! label. Every string lives in one fixed byte buffer, so a list costs the
//! same whatever its items and never allocates.
const core = @import("telar-core");
const cellgrid = @import("cellgrid");
const std = @import("std");
const PickItem = @import("PickItem.zig");
const bar_text = @import("bar_text.zig");
const bar_values = @import("model.zig");
const PickItems = @This();

pub const max_items = 4096;
/// Room for every label, value and detail of the list together: as much
/// as a list command may print.
pub const max_text_bytes = bar_values.max_pick_output_bytes;
pub const max_label_bytes = 128;
pub const max_value_bytes = 512;
pub const max_detail_bytes = 128;

pub const items_limit = core.Limit.declare("picks.max_items", "options", max_items);
pub const text_limit = core.Limit.declare("picks.max_text_bytes", "option text bytes", max_text_bytes);
pub const label_limit = core.Limit.declare("picks.max_label_bytes", "label bytes", max_label_bytes);
pub const value_limit = core.Limit.declare("picks.max_value_bytes", "value bytes", max_value_bytes);
pub const detail_limit = core.Limit.declare("picks.max_detail_bytes", "detail bytes", max_detail_bytes);
/// How many limits filling one list can pass.
pub const max_reaches = 5;

bytes: [max_text_bytes]u8 = undefined,
used: u32 = 0,
labels: [max_items]Range = undefined,
values: [max_items]Range = undefined,
details: [max_items]Range = undefined,
selected: [max_items]bool = undefined,
swatches: [max_items]?[3]cellgrid.Color = undefined,
count: u16 = 0,
/// What `keep` was offered beyond the limits since the last `clear`.
offered: Offered = .{},

/// The options and bytes `keep` was offered, and the longest label, value
/// and detail that passed their limit (0 when none did).
const Offered = struct {
    items: u32 = 0,
    text: u32 = 0,
    text_full: bool = false,
    label: u32 = 0,
    value: u32 = 0,
    detail: u32 = 0,
};

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
    self.selected[index] = item.selected;
    self.swatches[index] = item.swatch;
    self.count += 1;
}

/// Appends one option and keeps what fits instead of failing: a label or
/// detail past its limit is cut at a character, an option whose value is
/// past its limit is left out (a value is one argv element, never cut),
/// and options past the item or text limits are left out. `reaches` names
/// every limit passed. An invalid option still fails.
///
/// ```zig
/// try items.keep(.{ .label = line });
/// ```
pub fn keep(self: *PickItems, item: PickItem) !void {
    const chosen = item.value orelse item.label;
    self.offered.items +|= 1;
    self.offered.text +|= saturated(item.label.len + item.detail.len + chosen.len);

    var fitted: PickItem = .{
        .label = bar_text.prefix(item.label, max_label_bytes),
        .value = chosen,
        .detail = bar_text.prefix(item.detail, max_detail_bytes),
        .selected = item.selected,
        .swatch = item.swatch,
    };
    if (item.label.len > max_label_bytes) {
        self.offered.label = @max(self.offered.label, saturated(item.label.len));
    }

    if (item.detail.len > max_detail_bytes) {
        self.offered.detail = @max(self.offered.detail, saturated(item.detail.len));
    }

    if (chosen.len > max_value_bytes) {
        self.offered.value = @max(self.offered.value, saturated(chosen.len));
        return;
    }

    if (self.count == max_items or self.offered.text_full) {
        return;
    }

    if (std.mem.eql(u8, fitted.label, chosen)) {
        fitted.value = null;
    }

    self.append(fitted) catch |err| switch (err) {
        error.PickItemsTooLarge => self.offered.text_full = true,
        else => return err,
    };
}

/// The limits `keep` passed since the last `clear`, for the client to
/// report.
///
/// ```zig
/// var buffer: [PickItems.max_reaches]core.LimitReach = undefined;
/// for (items.reaches(&buffer)) |reach| limit_reached.report(client, reach);
/// ```
pub fn reaches(self: *const PickItems, buffer: *[max_reaches]core.LimitReach) []const core.LimitReach {
    var count: usize = 0;
    const passed = [max_reaches]struct { bool, core.Limit, u32 }{
        .{ self.offered.items > max_items, items_limit, self.offered.items },
        .{ self.offered.text_full, text_limit, self.offered.text },
        .{ self.offered.label != 0, label_limit, self.offered.label },
        .{ self.offered.value != 0, value_limit, self.offered.value },
        .{ self.offered.detail != 0, detail_limit, self.offered.detail },
    };
    for (passed) |entry| {
        if (!entry[0]) {
            continue;
        }

        buffer[count] = .{
            .limit = entry[1],
            .requested = entry[2],
        };
        count += 1;
    }

    return buffer[0..count];
}

/// Forgets every option. Example: `items.clear();`
pub fn clear(self: *PickItems) void {
    self.used = 0;
    self.count = 0;
    self.offered = .{};
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

fn saturated(amount: usize) u32 {
    return std.math.cast(u32, amount) orelse std.math.maxInt(u32);
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

test "keeping options cuts long labels and details, leaves out long values and surplus, and names each limit" {
    var items: PickItems = .{};
    try items.keep(.{
        .label = "l" ** (max_label_bytes + 3),
        .detail = "d" ** (max_detail_bytes + 1),
    });
    try items.keep(.{
        .label = "long value",
        .value = "v" ** (max_value_bytes + 1),
    });
    try items.keep(.{ .label = "fits" });

    try std.testing.expectEqual(@as(u16, 2), items.count);
    try std.testing.expectEqual(@as(usize, max_label_bytes), items.label(0).len);
    try std.testing.expectEqual(@as(usize, max_label_bytes + 3), items.value(0).len);
    try std.testing.expectEqual(@as(usize, max_detail_bytes), items.detail(0).len);
    try std.testing.expectEqualStrings("fits", items.value(1));

    var buffer: [max_reaches]core.LimitReach = undefined;
    const passed = items.reaches(&buffer);
    try std.testing.expectEqual(@as(usize, 3), passed.len);
    try std.testing.expectEqualStrings("picks.max_label_bytes", passed[0].limit.name);
    try std.testing.expectEqual(@as(?u64, max_label_bytes + 3), passed[0].requested);
    try std.testing.expectEqualStrings("picks.max_value_bytes", passed[1].limit.name);
    try std.testing.expectEqualStrings("picks.max_detail_bytes", passed[2].limit.name);

    items.clear();
    for (0..max_items + 2) |_| {
        try items.keep(.{ .label = "x" });
    }

    try std.testing.expectEqual(@as(u16, max_items), items.count);
    const surplus = items.reaches(&buffer);
    try std.testing.expectEqual(@as(usize, 1), surplus.len);
    try std.testing.expectEqual(@as(?u64, max_items + 2), surplus[0].requested);

    items.clear();
    try std.testing.expectError(error.InvalidPickItem, items.keep(.{ .label = "a\nb" }));
}

test "a list past its text keeps the options before the one that did not fit" {
    var items: PickItems = .{};
    const long_value = "v" ** max_value_bytes;
    const fitting = max_text_bytes / (1 + long_value.len);
    for (0..fitting + 3) |_| {
        try items.keep(.{
            .label = "x",
            .value = long_value,
        });
    }

    try std.testing.expectEqual(@as(u16, @intCast(fitting)), items.count);
    var buffer: [max_reaches]core.LimitReach = undefined;
    const passed = items.reaches(&buffer);
    try std.testing.expectEqual(@as(usize, 1), passed.len);
    try std.testing.expectEqualStrings("picks.max_text_bytes", passed[0].limit.name);
}
