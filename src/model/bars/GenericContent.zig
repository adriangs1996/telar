//! A bounded, flat list of components with the text, samples and actions they
//! own. Bar slots and panels use the same shape with different bounds, so one
//! parser and one painter serve both.
const Action = @import("../input/action.zig").Action;
const ContentRange = @import("ContentRange.zig");
const Node = @import("Node.zig");
const NodeInput = @import("NodeInput.zig");
const SegmentInput = @import("SegmentInput.zig");
const bar_text = @import("bar_text.zig");
const ContentBounds = @import("ContentBounds.zig");
const ContentDemand = @import("ContentDemand.zig");
const NodeKind = @import("NodeKind.zig").NodeKind;
const std = @import("std");

const max_url_bytes = 1024;
const max_node_capacity = Node.max_list_nodes;

/// Example: `const Content = GenericContent.Type(.{ .nodes = 64, .text = 4096, .actions = 32, .samples = 256 });`
pub fn Type(comptime bounds: ContentBounds) type {
    comptime {
        std.debug.assert(bounds.nodes <= max_node_capacity and bounds.actions <= max_node_capacity);
    }

    return struct {
        const Self = @This();

        pub const capacity = bounds;

        text_bytes: [bounds.text]u8 = @splat(0),
        text_len: u16 = 0,
        nodes: [bounds.nodes]Node = @splat(.{}),
        node_count: u8 = 0,
        sample_bytes: [bounds.samples]u8 = @splat(0),
        sample_len: u16 = 0,
        actions: [bounds.actions]Action = @splat(.close_panel),
        action_count: u8 = 0,

        /// Copies one validated component and returns its index, which
        /// later components use as their `parent`.
        ///
        /// ```zig
        /// const group = try content.append(.{ .kind = .group, .mark = .claude });
        /// _ = try content.append(.{ .kind = .meter, .parent = group, .text = "5h", .value = 220 });
        /// ```
        pub fn append(self: *Self, input: NodeInput) !u8 {
            if (self.node_count == bounds.nodes) {
                return error.TooManyBarComponents;
            }

            try validateParent(self, input);
            if (input.value > Node.full_scale or (input.marker orelse 0) > Node.full_scale) {
                return error.InvalidBarValue;
            }
            if (input.samples.len > Node.max_samples) {
                return error.TooManyBarSamples;
            }
            if (input.url.len != 0 and !validUrl(input.url)) {
                return error.InvalidBarUrl;
            }

            // Reserve every range before copying, so a rejected component
            // leaves the list exactly as it was.
            const text_needed = input.text.len + input.detail.len + input.url.len;
            if (@as(usize, self.text_len) + text_needed > bounds.text) {
                return error.BarTextTooLong;
            }
            if (@as(usize, self.sample_len) + input.samples.len > bounds.samples) {
                return error.TooManyBarSamples;
            }
            if (input.action != null and self.action_count == bounds.actions) {
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

        /// Empties the list without touching its storage, so a large list
        /// is reused without rewriting every byte.
        /// Example: `staged.clear();`
        pub fn clear(self: *Self) void {
            self.text_len = 0;
            self.node_count = 0;
            self.sample_len = 0;
            self.action_count = 0;
        }

        /// The borrowed values of one stored component, as `append` takes
        /// them; `parent` still names this list's index.
        /// Example: `_ = try other.append(content.inputAt(index));`
        pub fn inputAt(self: *const Self, index: u8) NodeInput {
            const node = self.nodes[index];
            return .{
                .kind = node.kind,
                .parent = node.parent,
                .in_tooltip = node.in_tooltip,
                .text = self.text(node.text),
                .detail = self.text(node.detail),
                .url = self.text(node.url),
                .samples = self.samples(node),
                .icon = node.icon,
                .mark = node.mark,
                .metric = node.metric,
                .tone = node.tone,
                .style = node.style,
                .value = node.value,
                .marker = node.marker,
                .priority = node.priority,
                .primary = node.primary,
                .action = self.action(node),
            };
        }

        /// Replaces this list with the components of `source`, a list of
        /// any bounds, that fit this one. Components are chosen by
        /// priority, highest first; a component never outranks its
        /// container and is kept only with it; equal ranks keep document
        /// order. The kept components stay in their document order, so a
        /// source that fits is copied whole.
        ///
        /// ```zig
        /// content.keepFitting(generation.staged_content);
        /// ```
        pub fn keepFitting(self: *Self, source: anytype) void {
            self.clear();
            const count = source.node_count;
            var rank: [max_node_capacity]u8 = undefined;
            var order: [max_node_capacity]u8 = undefined;
            for (source.slice(), 0..) |node, index| {
                rank[index] = node.effectivePriority();
                if (!node.isRoot()) {
                    rank[index] = @min(rank[index], rank[node.parent]);
                }

                order[index] = @intCast(index);
            }

            std.sort.pdq(u8, order[0..count], &rank, outranks);
            var kept: [max_node_capacity]bool = @splat(false);
            var budget: ContentDemand = .{};
            for (order[0..count]) |index| {
                const node = source.nodes[index];
                if (!node.isRoot() and !kept[node.parent]) {
                    continue;
                }

                var next = budget;
                next.add(source.inputAt(index));
                if (!next.fits(bounds)) {
                    continue;
                }

                kept[index] = true;
                budget = next;
            }

            var copied: [max_node_capacity]u8 = undefined;
            for (0..count) |index| {
                if (!kept[index]) {
                    continue;
                }

                var value = source.inputAt(@intCast(index));
                if (value.parent != Node.no_parent) {
                    if (!kept[value.parent]) {
                        kept[index] = false;
                        continue;
                    }

                    value.parent = copied[value.parent];
                }

                copied[index] = self.append(value) catch {
                    kept[index] = false;
                    continue;
                };
            }
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

/// A higher rank first; equal ranks in document order.
fn outranks(rank: *const [max_node_capacity]u8, left: u8, right: u8) bool {
    if (rank[left] != rank[right]) {
        return rank[left] > rank[right];
    }

    return left < right;
}

const TestContent = Type(.{
    .nodes = 4,
    .text = 64,
    .actions = 1,
    .samples = 64,
});

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

test "a larger list keeps its highest-priority components with their containers, in document order" {
    var source: Type(.{
        .nodes = 16,
        .text = 256,
        .actions = 4,
        .samples = 64,
    }) = .{};
    _ = try source.append(.{
        .kind = .label,
        .text = "low",
        .priority = 10,
    });
    const group = try source.append(.{
        .kind = .group,
        .priority = 90,
        .action = .toggle_sidebar,
    });
    _ = try source.append(.{
        .kind = .label,
        .parent = group,
        .text = "child",
        // A child never outranks its group, so it is ranked 90, not 100.
        .priority = 100,
    });
    _ = try source.append(.{
        .kind = .label,
        .text = "middle",
        .priority = 50,
    });
    _ = try source.append(.{
        .kind = .button,
        .text = "go",
        .action = .detach,
        .priority = 85,
    });

    var content: TestContent = .{};
    content.keepFitting(&source);

    // The button needs a second action this list has no room for, so the
    // next component that fits takes its place.
    const nodes = content.slice();
    try std.testing.expectEqual(@as(u8, 4), content.node_count);
    try std.testing.expectEqualStrings("low", content.text(nodes[0].text));
    try std.testing.expectEqual(NodeKind.group, nodes[1].kind);
    try std.testing.expect(content.action(nodes[1]).? == .toggle_sidebar);
    try std.testing.expectEqualStrings("child", content.text(nodes[2].text));
    try std.testing.expectEqual(@as(u8, 1), nodes[2].parent);
    try std.testing.expectEqualStrings("middle", content.text(nodes[3].text));
}

test "a list that fits is copied whole and a dropped container drops its children" {
    var source: Type(.{
        .nodes = 8,
        .text = 256,
        .actions = 2,
        .samples = 64,
    }) = .{};
    const group = try source.append(.{
        .kind = .group,
        .priority = 5,
    });
    _ = try source.append(.{
        .kind = .label,
        .parent = group,
        .text = "inside",
        .priority = 99,
    });
    for (0..4) |_| {
        _ = try source.append(.{
            .kind = .label,
            .text = "top",
            .priority = 60,
        });
    }

    var wide: Type(.{
        .nodes = 8,
        .text = 256,
        .actions = 2,
        .samples = 64,
    }) = .{};
    wide.keepFitting(&source);
    try std.testing.expect(wide.eql(&source));

    var content: TestContent = .{};
    content.keepFitting(&source);
    try std.testing.expectEqual(@as(u8, 4), content.node_count);
    for (content.slice()) |node| {
        try std.testing.expect(node.isRoot());
        try std.testing.expectEqualStrings("top", content.text(node.text));
    }
}
