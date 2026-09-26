//! A bounded, flat list of components with the text, samples and actions they
//! own. Bar slots and panels use the same shape with different bounds, so one
//! parser and one painter serve both.
const Action = @import("../input/action.zig").Action;
const ContentRange = @import("ContentRange.zig");
const Node = @import("Node.zig");
const NodeInput = @import("NodeInput.zig");
const SegmentInput = @import("SegmentInput.zig");
const bar_text = @import("bar_text.zig");
const std = @import("std");

const max_samples = 64;
const max_url_bytes = 1024;
const max_node_samples = 32;

/// Example: `const Content = GenericContent.Type(32, 1024, 4);`
pub fn Type(comptime max_nodes: u8, comptime max_text: u16, comptime max_actions: u8) type {
    return struct {
        const Self = @This();

        pub const node_capacity = max_nodes;
        pub const text_capacity = max_text;
        pub const action_capacity = max_actions;

        text_bytes: [max_text]u8 = @splat(0),
        text_len: u16 = 0,
        nodes: [max_nodes]Node = @splat(.{}),
        node_count: u8 = 0,
        sample_bytes: [max_samples]u8 = @splat(0),
        sample_len: u16 = 0,
        actions: [max_actions]Action = @splat(.close_panel),
        action_count: u8 = 0,

        /// Copies one validated component and returns its index, which
        /// later components use as their `parent`.
        ///
        /// ```zig
        /// const group = try content.append(.{ .kind = .group, .mark = .claude });
        /// _ = try content.append(.{ .kind = .meter, .parent = group, .text = "5h", .value = 220 });
        /// ```
        pub fn append(self: *Self, input: NodeInput) !u8 {
            if (self.node_count == max_nodes) {
                return error.TooManyBarComponents;
            }

            try validateParent(self, input);
            if (input.value > Node.full_scale or (input.marker orelse 0) > Node.full_scale) {
                return error.InvalidBarValue;
            }
            if (input.samples.len > max_node_samples) {
                return error.TooManyBarSamples;
            }
            if (input.url.len != 0 and !validUrl(input.url)) {
                return error.InvalidBarUrl;
            }

            // Reserve every range before copying, so a rejected component
            // leaves the list exactly as it was.
            const text_needed = input.text.len + input.detail.len + input.url.len;
            if (@as(usize, self.text_len) + text_needed > max_text) {
                return error.BarTextTooLong;
            }
            if (@as(usize, self.sample_len) + input.samples.len > max_samples) {
                return error.TooManyBarSamples;
            }
            if (input.action != null and self.action_count == max_actions) {
                return error.TooManyBarActions;
            }
            for ([_][]const u8{ input.text, input.detail }) |value| {
                if (!bar_text.valid(value)) {
                    return error.InvalidBarText;
                }
            }

            var node: Node = .{
                .kind = input.kind,
                .parent = input.parent,
                .in_tooltip = input.in_tooltip,
                .icon = input.icon,
                .mark = input.mark,
                .metric = input.metric,
                .tone = input.tone,
                .style = input.style,
                .value = input.value,
                .marker = input.marker,
                .priority = @min(input.priority, Node.max_priority),
                .primary = input.primary,
            };
            node.text = self.copyText(input.text);
            node.detail = self.copyText(input.detail);
            node.url = self.copyText(input.url);
            node.samples = self.copySamples(input.samples);
            if (input.action) |value| {
                self.actions[self.action_count] = value;
                node.action = self.action_count;
                self.action_count += 1;
            }

            self.nodes[self.node_count] = node;
            self.node_count += 1;
            return self.node_count - 1;
        }

        /// Appends a legacy text segment as a label, or as an icon when it
        /// has no text.
        ///
        /// ```zig
        /// try content.appendSegment(.{ .text = " CPU", .icon = .cpu });
        /// ```
        pub fn appendSegment(self: *Self, input: SegmentInput) !void {
            if (input.text.len == 0 and input.icon == null) {
                return error.EmptyBarSegment;
            }

            _ = try self.append(.{
                .kind = if (input.text.len == 0) .icon else .label,
                .text = input.text,
                .icon = input.icon,
                .style = input.style,
            });
        }

        pub fn text(self: *const Self, range: ContentRange) []const u8 {
            return self.text_bytes[range.offset..][0..range.len];
        }

        pub fn samples(self: *const Self, node: Node) []const u8 {
            return self.sample_bytes[node.samples.offset..][0..node.samples.len];
        }

        pub fn action(self: *const Self, node: Node) ?Action {
            if (node.action == Node.no_action) {
                return null;
            }

            return self.actions[node.action];
        }

        pub fn slice(self: *const Self) []const Node {
            return self.nodes[0..self.node_count];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.node_count == 0;
        }

        /// Whether a group shows a tooltip made of its own components.
        /// Example: `if (content.hasTooltip(index)) try tooltips.show(index);`
        pub fn hasTooltip(self: *const Self, parent: u8) bool {
            for (self.slice()) |node| {
                if (node.parent == parent and node.in_tooltip) {
                    return true;
                }
            }

            return false;
        }

        pub fn eql(self: *const Self, right: *const Self) bool {
            if (self.text_len != right.text_len or self.node_count != right.node_count) {
                return false;
            }
            if (self.sample_len != right.sample_len or self.action_count != right.action_count) {
                return false;
            }
            if (!std.mem.eql(u8, self.text_bytes[0..self.text_len], right.text_bytes[0..right.text_len])) {
                return false;
            }
            if (!std.mem.eql(u8, self.sample_bytes[0..self.sample_len], right.sample_bytes[0..right.sample_len])) {
                return false;
            }

            for (self.slice(), right.slice()) |left_node, right_node| {
                if (!std.meta.eql(left_node, right_node)) {
                    return false;
                }
            }

            for (self.actions[0..self.action_count], right.actions[0..right.action_count]) |left_action, right_action| {
                if (!std.meta.eql(left_action, right_action)) {
                    return false;
                }
            }

            return true;
        }

        fn copyText(self: *Self, value: []const u8) ContentRange {
            const offset = self.text_len;
            @memcpy(self.text_bytes[offset..][0..value.len], value);
            self.text_len += @intCast(value.len);

            return .{
                .offset = offset,
                .len = @intCast(value.len),
            };
        }

        fn copySamples(self: *Self, values: []const u8) ContentRange {
            const offset = self.sample_len;
            @memcpy(self.sample_bytes[offset..][0..values.len], values);
            self.sample_len += @intCast(values.len);

            return .{
                .offset = offset,
                .len = @intCast(values.len),
            };
        }

        fn validateParent(self: *const Self, input: NodeInput) !void {
            if (input.parent == Node.no_parent) {
                if (input.in_tooltip) {
                    return error.InvalidBarParent;
                }

                return;
            }
            if (input.parent >= self.node_count) {
                return error.InvalidBarParent;
            }

            const parent = self.nodes[input.parent];
            if (!parent.kind.isContainer()) {
                return error.InvalidBarParent;
            }
            if (input.in_tooltip and parent.kind != .group) {
                return error.InvalidBarParent;
            }
        }
    };
}

fn validUrl(value: []const u8) bool {
    if (value.len > max_url_bytes or !bar_text.valid(value)) {
        return false;
    }
    if (std.mem.indexOfScalar(u8, value, ' ') != null) {
        return false;
    }

    return std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://");
}

const TestContent = Type(4, 64, 1);

test "component lists copy text and reject a component without changing" {
    var content: TestContent = .{};
    const group = try content.append(.{
        .kind = .group,
        .mark = .claude,
        .action = .toggle_sidebar,
    });
    _ = try content.append(.{
        .kind = .meter,
        .parent = group,
        .text = "5h",
        .value = 220,
    });

    try std.testing.expectError(error.InvalidBarValue, content.append(.{
        .kind = .meter,
        .parent = group,
        .value = 1001,
    }));
    try std.testing.expectError(error.InvalidBarText, content.append(.{
        .kind = .label,
        .text = "\x1b[31m",
    }));
    try std.testing.expectError(error.TooManyBarActions, content.append(.{
        .kind = .button,
        .action = .detach,
    }));

    try std.testing.expectEqual(@as(u8, 2), content.node_count);
    try std.testing.expectEqualStrings("5h", content.text(content.slice()[1].text));
    try std.testing.expectEqual(@as(u8, 22), content.slice()[1].percent());
    try std.testing.expect(content.action(content.slice()[0]).? == .toggle_sidebar);
}

test "components name only earlier containers as parents" {
    var content: TestContent = .{};
    const label = try content.append(.{
        .kind = .label,
        .text = "cpu",
    });

    try std.testing.expectError(error.InvalidBarParent, content.append(.{
        .kind = .label,
        .parent = label,
    }));
    try std.testing.expectError(error.InvalidBarParent, content.append(.{
        .kind = .label,
        .parent = 3,
    }));
    try std.testing.expectError(error.InvalidBarParent, content.append(.{
        .kind = .label,
        .in_tooltip = true,
    }));
}

test "component urls accept only http destinations" {
    var content: TestContent = .{};

    try std.testing.expectError(error.InvalidBarUrl, content.append(.{
        .kind = .button,
        .url = "file:///etc/passwd",
    }));
    try std.testing.expectError(error.InvalidBarUrl, content.append(.{
        .kind = .button,
        .url = "https://a b",
    }));
    _ = try content.append(.{
        .kind = .button,
        .url = "https://claude.ai/settings/usage",
    });

    try std.testing.expect(content.slice()[0].isActionable());
}
