//! Bounded configuration and presentation state for client-owned bars.

const std = @import("std");
const core = @import("telar-core");
const ui_icons = @import("../layout/root.zig").icons;

pub const ui = core.ui;

pub const max_segments = 16;
pub const max_text_bytes = 512;
pub const max_command_args = 32;
pub const max_command_bytes = 4096;
pub const min_interval_ms: u32 = 100;
pub const max_interval_ms: u32 = 60 * 60 * 1000;
pub const min_command_timeout_ms: u32 = 100;
pub const max_command_timeout_ms: u32 = 10_000;

pub const Position = enum(u3) {
    bottom_left,
    bottom_center,
    bottom_right,
    top_right,

    pub fn bit(position: Position) u8 {
        return @as(u8, 1) << @intFromEnum(position);
    }
};

pub const Alignment = enum {
    left,
    center,
    right,
};

pub const PaletteColor = enum {
    accent,
    panel_bg,
    surface0,
    surface1,
    surface_dim,
    overlay0,
    overlay1,
    text,
    subtext0,
    mauve,
    green,
    yellow,
    red,
    blue,
    teal,
    peach,
};

pub const Color = union(enum) {
    palette: PaletteColor,
    value: ui.Color,
};

pub const Style = @import("Style.zig");

pub const Segment = @import("Segment.zig");

pub const SegmentInput = @import("SegmentInput.zig");

pub const Content = @import("Content.zig");

pub const CallbackRef = @import("CallbackRef.zig");

pub const Dynamic = @import("Dynamic.zig");

pub const Command = @import("Command.zig");

pub const Source = union(enum) {
    empty,
    tabs,
    metrics,
    static: Content,
    dynamic: Dynamic,
    command: Command,

    pub fn interval(source: *const Source) ?u64 {
        return switch (source.*) {
            .dynamic => |value| value.interval_ns,
            .command => |value| value.interval_ns,
            else => null,
        };
    }
};

pub const Configuration = @import("Configuration.zig");

pub const Slot = union(enum) {
    empty,
    tabs,
    metrics,
    content: Content,
};

pub const Layout = @import("Layout.zig");

pub const Change = enum {
    unchanged,
    changed,
};

pub const Update = @import("Update.zig");

pub const State = @import("State.zig");

pub fn presentationSlot(source: *const Source) Slot {
    return switch (source.*) {
        .empty => .empty,
        .tabs => .tabs,
        .metrics => .metrics,
        .static => |content| .{ .content = content },
        .dynamic, .command => .{ .content = .{} },
    };
}

pub fn slotEql(left: *const Slot, right: *const Slot) bool {
    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) {
        return false;
    }

    return switch (left.*) {
        .content => |*content| content.eql(&right.content),
        else => true,
    };
}

pub fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) {
        return false;
    }

    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return false;
        }
    }

    return true;
}

test "bar content keeps bounded segment text and exact style" {
    var content: Content = .{};
    try content.append(.{
        .text = " CPU 20%",
        .icon = .cpu,
        .style = .{ .foreground = .{ .palette = .teal }, .bold = true },
    });

    try std.testing.expectEqual(@as(u8, 1), content.segment_count);
    try std.testing.expectEqualStrings(" CPU 20%", content.text(content.slice()[0]));
    try std.testing.expectEqual(@as(u16, 9), content.width());
    try std.testing.expect(content.slice()[0].style.bold);
}

test "bar content reserves the rendered width of wide Unicode icons" {
    var content: Content = .{};
    try content.append(.{ .text = "", .icon = .battery_full });

    try std.testing.expectEqual(
        @max(@as(u16, 1), ui.measure(ui_icons.Icon.battery_full.unicodeGlyph())),
        content.width(),
    );
}

test "bar state rejects stale dynamic updates and folds equal content" {
    const configuration: Configuration = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 7, .id = 1 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var state = State.init(configuration.presentation());
    var content: Content = .{};
    try content.append(.{ .text = "ready" });

    try std.testing.expectError(error.StaleBarUpdate, state.update(.{ .generation = 6, .position = .bottom_left, .content = content }));
    try std.testing.expectEqual(Change.changed, try state.update(.{ .generation = 7, .position = .bottom_left, .content = content }));
    try std.testing.expectEqual(Change.unchanged, try state.update(.{ .generation = 7, .position = .bottom_left, .content = content }));
}

test "bar text rejects terminal controls before it reaches the renderer" {
    var content: Content = .{};

    try std.testing.expectError(error.InvalidBarText, content.append(.{ .text = "line\n" }));
    try std.testing.expectError(error.InvalidBarText, content.append(.{ .text = "\x1b[31m" }));
}
