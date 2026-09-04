//! Bounded configuration and presentation state for client-owned bars.

const std = @import("std");
const core = @import("telar-core");
const ui_icons = @import("../ui/root.zig").icons;

const ui = core.ui;

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

pub const Style = struct {
    foreground: ?Color = null,
    background: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
};

pub const Segment = struct {
    text_offset: u16 = 0,
    text_len: u16 = 0,
    icon: ?ui_icons.Icon = null,
    style: Style = .{},
};

pub const SegmentInput = struct {
    text: []const u8,
    icon: ?ui_icons.Icon = null,
    style: Style = .{},
};

pub const Content = struct {
    text_bytes: [max_text_bytes]u8 = @splat(0),
    text_len: u16 = 0,
    segments: [max_segments]Segment = @splat(.{}),
    segment_count: u8 = 0,

    /// Appends one logical segment after validating and compacting its text.
    ///
    /// ```zig
    /// try content.append(.{ .text = " CPU", .icon = .cpu });
    /// ```
    pub fn append(content: *Content, input: SegmentInput) !void {
        if (content.segment_count == max_segments) {
            return error.TooManyBarSegments;
        }
        if (input.text.len == 0 and input.icon == null) {
            return error.EmptyBarSegment;
        }
        if (!validText(input.text)) {
            return error.InvalidBarText;
        }

        const end = @as(usize, content.text_len) + input.text.len;
        if (end > content.text_bytes.len) {
            return error.BarTextTooLong;
        }

        const offset = content.text_len;
        @memcpy(content.text_bytes[offset..end], input.text);
        content.segments[content.segment_count] = .{
            .text_offset = offset,
            .text_len = @intCast(input.text.len),
            .icon = input.icon,
            .style = input.style,
        };
        content.text_len = @intCast(end);
        content.segment_count += 1;
    }

    pub fn text(content: *const Content, segment: Segment) []const u8 {
        return content.text_bytes[segment.text_offset..][0..segment.text_len];
    }

    pub fn slice(content: *const Content) []const Segment {
        return content.segments[0..content.segment_count];
    }

    pub fn width(content: *const Content) u16 {
        var result: u16 = 0;
        for (content.slice()) |segment| {
            if (segment.icon) |icon| {
                result +|= @max(@as(u16, 1), ui.measure(icon.unicodeGlyph()));
            }
            result +|= ui.measure(content.text(segment));
        }

        return result;
    }

    pub fn eql(left: *const Content, right: *const Content) bool {
        if (left.text_len != right.text_len or left.segment_count != right.segment_count) {
            return false;
        }
        if (!std.mem.eql(u8, left.text_bytes[0..left.text_len], right.text_bytes[0..right.text_len])) {
            return false;
        }

        for (left.segments[0..left.segment_count], right.segments[0..right.segment_count]) |left_segment, right_segment| {
            if (!std.meta.eql(left_segment, right_segment)) {
                return false;
            }
        }

        return true;
    }
};

pub const CallbackRef = struct {
    generation: u64,
    id: u8,
};

pub const Dynamic = struct {
    callback: CallbackRef,
    interval_ns: u64,
};

pub const Command = struct {
    const Argument = struct {
        offset: u16 = 0,
        len: u16 = 0,
    };

    generation: u64,
    bytes: [max_command_bytes]u8 = @splat(0),
    byte_len: u16 = 0,
    arguments: [max_command_args]Argument = @splat(.{}),
    argument_count: u8 = 0,
    interval_ns: u64,
    timeout_ms: u32,
    render: ?CallbackRef = null,

    pub fn appendArgument(command: *Command, argument_value: []const u8) !void {
        if (command.argument_count == max_command_args) {
            return error.TooManyBarCommandArguments;
        }
        if ((command.argument_count == 0 and argument_value.len == 0) or std.mem.indexOfScalar(u8, argument_value, 0) != null) {
            return error.InvalidBarCommandArgument;
        }

        const end = @as(usize, command.byte_len) + argument_value.len;
        if (argument_value.len > std.math.maxInt(u16) or end > command.bytes.len) {
            return error.BarCommandTooLong;
        }

        command.arguments[command.argument_count] = .{
            .offset = command.byte_len,
            .len = @intCast(argument_value.len),
        };
        @memcpy(command.bytes[command.byte_len..end], argument_value);
        command.byte_len = @intCast(end);
        command.argument_count += 1;
    }

    pub fn argument(command: *const Command, index: usize) ?[]const u8 {
        if (index >= command.argument_count) {
            return null;
        }

        const reference = command.arguments[index];
        return command.bytes[reference.offset..][0..reference.len];
    }

    pub fn argumentSlice(command: *const Command, storage: *[max_command_args][]const u8) []const []const u8 {
        for (0..command.argument_count) |index| {
            storage[index] = command.argument(index).?;
        }

        return storage[0..command.argument_count];
    }
};

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

pub const Configuration = struct {
    bottom: [3]Source = .{ .metrics, .empty, .tabs },
    top_right: Source = .empty,

    pub fn source(configuration: *const Configuration, position: Position) *const Source {
        return switch (position) {
            .bottom_left => &configuration.bottom[0],
            .bottom_center => &configuration.bottom[1],
            .bottom_right => &configuration.bottom[2],
            .top_right => &configuration.top_right,
        };
    }

    pub fn presentation(configuration: *const Configuration) Layout {
        var result: Layout = .{};
        inline for (std.meta.fields(Position)) |field| {
            const position: Position = @enumFromInt(field.value);
            result.set(position, presentationSlot(configuration.source(position)));
            switch (configuration.source(position).*) {
                .dynamic => |value| {
                    result.generation = value.callback.generation;
                    result.live_mask |= position.bit();
                },
                .command => |value| {
                    result.generation = value.generation;
                    result.live_mask |= position.bit();
                },
                else => {},
            }
        }

        return result;
    }
};

pub const Slot = union(enum) {
    empty,
    tabs,
    metrics,
    content: Content,
};

pub const Layout = struct {
    generation: u64 = 0,
    live_mask: u8 = 0,
    bottom: [3]Slot = .{ .metrics, .empty, .tabs },
    top_right: Slot = .empty,

    pub fn slot(layout: *const Layout, position: Position) *const Slot {
        return switch (position) {
            .bottom_left => &layout.bottom[0],
            .bottom_center => &layout.bottom[1],
            .bottom_right => &layout.bottom[2],
            .top_right => &layout.top_right,
        };
    }

    pub fn isLive(layout: *const Layout, position: Position) bool {
        return layout.live_mask & position.bit() != 0;
    }

    fn set(layout: *Layout, position: Position, slot_value: Slot) void {
        switch (position) {
            .bottom_left => layout.bottom[0] = slot_value,
            .bottom_center => layout.bottom[1] = slot_value,
            .bottom_right => layout.bottom[2] = slot_value,
            .top_right => layout.top_right = slot_value,
        }
    }

    fn eql(left: *const Layout, right: *const Layout) bool {
        if (left.generation != right.generation or left.live_mask != right.live_mask) {
            return false;
        }
        inline for (std.meta.fields(Position)) |field| {
            const position: Position = @enumFromInt(field.value);
            if (!slotEql(left.slot(position), right.slot(position))) {
                return false;
            }
        }

        return true;
    }
};

pub const Change = enum {
    unchanged,
    changed,
};

pub const Update = struct {
    generation: u64,
    position: Position,
    content: Content,
};

pub const State = struct {
    layout: Layout = .{},

    pub fn init(layout: Layout) State {
        return .{ .layout = layout };
    }

    pub fn replace(state: *State, layout: Layout) Change {
        if (state.layout.eql(&layout)) {
            return .unchanged;
        }

        state.layout = layout;
        return .changed;
    }

    pub fn update(state: *State, update_value: Update) !Change {
        if (state.layout.generation != update_value.generation or !state.layout.isLive(update_value.position)) {
            return error.StaleBarUpdate;
        }

        const current = state.layout.slot(update_value.position);
        if (current.* != .content) {
            return error.InvalidBarUpdateTarget;
        }
        if (current.content.eql(&update_value.content)) {
            return .unchanged;
        }

        state.layout.set(update_value.position, .{ .content = update_value.content });
        return .changed;
    }
};

fn presentationSlot(source: *const Source) Slot {
    return switch (source.*) {
        .empty => .empty,
        .tabs => .tabs,
        .metrics => .metrics,
        .static => |content| .{ .content = content },
        .dynamic, .command => .{ .content = .{} },
    };
}

fn slotEql(left: *const Slot, right: *const Slot) bool {
    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) {
        return false;
    }

    return switch (left.*) {
        .content => |*content| content.eql(&right.content),
        else => true,
    };
}

fn validText(text: []const u8) bool {
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
