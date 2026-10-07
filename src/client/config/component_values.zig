//! Parses the components a bar or panel returns from Lua into a bounded list.
//! Every table is checked against the fields its component accepts, and
//! every component against the place it appears in, before anything is kept.
const ComponentSource = @import("ComponentSource.zig");
const core = @import("telar-core");
const data = @import("model");
const lua_api = @import("lua-api");
const lua_value = @import("lua_value.zig");
const bar_values = @import("bar_values.zig");
const Generation = @import("Generation.zig");
const std = @import("std");

/// Where a list of components is shown.
pub const Surface = enum {
    bar,
    panel,
};

const max_list_depth = 4;
const max_glyph_bytes = 16;
const percent_scale: f64 = 100;
const full_scale: f64 = @floatFromInt(data.Node.full_scale);

/// Which components a list accepts.
const Place = enum {
    bar,
    panel,
    group,
    tooltip,
    buttons,

    fn accepts(self: Place, kind: data.NodeKind) bool {
        return switch (self) {
            .bar => kind.isInline(),
            .panel => true,
            .group => kind.isInline() and kind != .group,
            .tooltip => switch (kind) {
                .group, .callout, .actions, .button => false,
                else => true,
            },
            .buttons => kind == .button,
        };
    }
};

const Reader = struct {
    state: *lua_api.c.lua_State,
    diagnostic: *data.Diagnostic,
    generation: *Generation,
    pass: *Pass,
};

/// Ranks a component can take: its priority plus its tone's bonus, at
/// most its container's.
const rank_count = std.math.maxInt(u8) + 1;

/// One walk over a render's result. The first only counts what every
/// component asks, by rank; the second stages the components whose rank
/// reaches `cutoff`, so priority decides what is staged even when the
/// render is larger than the staged list: every rank above the cutoff is
/// staged whole, and the cutoff's own components take the room left, in
/// document order.
const Pass = struct {
    counting: bool = true,
    cutoff: u8 = 0,
    /// What the cutoff's components may take, and what they took.
    room: data.ContentDemand = .{},
    taken: data.ContentDemand = .{},
    /// Everything the render returned, children of any container included.
    demand: data.ContentDemand = .{},
    ranked: [rank_count]data.ContentDemand = @splat(.{}),
    /// Staged containers the render gave children, staged or not, so one
    /// whose children all fell under the cutoff is not kept empty.
    had_children: [data.Node.max_list_nodes]bool = @splat(false),

    /// Picks the lowest rank to stage and the room its components share:
    /// rank 0 and all of `bounds` when the whole render fits.
    fn chooseCutoff(self: *Pass, bounds: data.ContentBounds) void {
        self.counting = false;
        var above: data.ContentDemand = .{};
        var rank: usize = rank_count;
        while (rank > 0) {
            rank -= 1;
            var next = above;
            next.merge(self.ranked[rank]);
            if (!next.fits(bounds)) {
                break;
            }

            above = next;
        } else {
            self.cutoff = 0;
            self.room = data.ContentDemand.of(bounds);
            return;
        }

        self.cutoff = @intCast(rank);
        self.room = data.ContentDemand.of(bounds);
        self.room.remove(above);
    }

    /// Gives back the room `admits` took for a component left out.
    fn release(self: *Pass, input: data.NodeInput) void {
        var one: data.ContentDemand = .{};
        one.add(input);
        self.taken.remove(one);
    }

    /// Whether a component of the cutoff's rank still has room.
    fn admits(self: *Pass, input: data.NodeInput) bool {
        var next = self.taken;
        next.add(input);
        if (!next.within(self.room)) {
            return false;
        }

        self.taken = next;
        return true;
    }
};

/// Where a staged component went: its index, which its children name as
/// their parent, and its rank, which bounds theirs.
const Staged = struct {
    index: u8,
    rank: u8,
};

const Target = struct {
    index: c_int,
    place: Place,
    parent: u8 = data.Node.no_parent,
    priority: u8 = data.Node.default_priority,
    /// The rank of the container, which no child outranks.
    rank: u8 = std.math.maxInt(u8),
    depth: u8 = 0,
};

const kind_names = [_]struct { []const u8, data.NodeKind }{
    .{ "label", .label },
    .{ "icon", .icon },
    .{ "mark", .mark },
    .{ "meter", .meter },
    .{ "sparkline", .sparkline },
    .{ "badge", .badge },
    .{ "clock", .clock },
    .{ "metric", .metric },
    .{ "machines", .machines },
    .{ "group", .group },
    .{ "heading", .heading },
    .{ "text", .text },
    .{ "meter_row", .meter_row },
    .{ "kv", .kv },
    .{ "callout", .callout },
    .{ "actions", .actions },
    .{ "button", .button },
    .{ "divider", .divider },
};

/// Parses `nil`, a string, one component, a legacy segment or a list of any
/// of them into `content`, which is a `data.Content` or `data.PanelContent`.
/// A list larger than `content` keeps its highest-priority components that
/// fit and leaves each bound it passed for the client to report.
///
/// ```zig
/// var content: data.Content = .{};
/// try component_values.parse(generation, &content, .{ .index = -1, .surface = .bar }, diagnostic);
/// ```
pub fn parse(generation: *Generation, content: anytype, request: ComponentSource, diagnostic: *data.Diagnostic) !void {
    var pass: Pass = .{};
    const reader: Reader = .{
        .state = generation.vm.state,
        .diagnostic = diagnostic,
        .generation = generation,
        .pass = &pass,
    };
    const root: Target = .{
        .index = lua_api.c.lua_absindex(reader.state, request.index),
        .place = switch (request.surface) {
            .bar => .bar,
            .panel => .panel,
        },
    };

    const staged = generation.staged_content;
    try readList(reader, staged, root);
    pass.chooseCutoff(data.StagedContent.capacity);
    staged.clear();
    const tabs = &generation.snapshot.command_tabs;
    tabs.beginRender();
    defer tabs.endRender();
    try readList(reader, staged, root);

    content.keepFitting(staged, &pass.had_children);
    reportDemand(generation, pass.demand, switch (request.surface) {
        .bar => data.bar_values.bar_limits,
        .panel => data.bar_values.panel_limits,
    });
}

/// Leaves every bound the render passed for the client to report.
fn reportDemand(generation: *Generation, demand: data.ContentDemand, limits: data.ContentLimits) void {
    const bounds = [_]struct { u32, core.Limit }{
        .{ demand.nodes, limits.nodes },
        .{ demand.text, limits.text },
        .{ demand.actions, limits.actions },
        .{ demand.samples, limits.samples },
    };
    for (bounds) |bound| {
        if (bound[0] > bound[1].value) {
            generation.unreported.add(.{
                .limit = bound[1],
                .requested = bound[0],
            });
        }
    }
}

fn readList(reader: Reader, content: anytype, target: Target) anyerror!void {
    const state = reader.state;
    const index = target.index;
    switch (lua_api.c.lua_type(state, index)) {
        lua_api.c.LUA_TNIL => return,
        lua_api.c.LUA_TSTRING => {
            _ = try append(reader, content, .{
                .kind = .label,
                .parent = target.parent,
                .in_tooltip = target.place == .tooltip,
                .text = lua_value.string(state, index).?,
                .priority = target.priority,
            }, target, null);
            return;
        },
        lua_api.c.LUA_TTABLE => {},
        else => return fail(reader, "components must be text, a telar.ui component or a list of them", .{}),
    }

    if (hasField(state, index, "ui")) {
        return readComponent(reader, content, target);
    }
    if (hasField(state, index, "text") or hasField(state, index, "icon")) {
        return readSegment(reader, content, target);
    }
    if (target.depth == max_list_depth) {
        return fail(reader, "component lists nest at most {d} levels", .{max_list_depth});
    }

    const count = lua_api.c.lua_rawlen(state, index);
    try lua_value.ensureArrayOnly(state, .{ .index = index, .count = count, .path = "component list" }, reader.diagnostic);
    for (0..count) |item| {
        _ = lua_api.c.lua_geti(state, index, @intCast(item + 1));
        defer lua_value.pop(state, 1);
        var nested = target;
        nested.index = lua_api.c.lua_absindex(state, -1);
        nested.depth += 1;
        try readList(reader, content, nested);
    }
}

fn readSegment(reader: Reader, content: anytype, target: Target) !void {
    const segment = try bar_values.parseBarSegment(reader.state, target.index, reader.diagnostic);
    _ = try append(reader, content, .{
        .kind = if (segment.text.len == 0) .icon else .label,
        .parent = target.parent,
        .in_tooltip = target.place == .tooltip,
        .text = segment.text,
        .icon = segment.icon,
        .style = segment.style,
        .priority = target.priority,
    }, target, null);
}

fn readComponent(reader: Reader, content: anytype, target: Target) !void {
    const state = reader.state;
    const index = target.index;
    const name = try stringField(reader, index, "ui") orelse "";
    const kind = kindNamed(name) orelse return fail(reader, "unknown component telar.ui.{s}", .{name});
    if (!target.place.accepts(kind)) {
        return fail(reader, "telar.ui.{s} is not allowed in a {s}", .{ name, @tagName(target.place) });
    }

    try lua_value.ensureOnlyFields(state, .{
        .index = index,
        .allowed = fieldsOf(kind),
        .path = name,
        .children = kind == .group or kind == .actions,
    }, reader.diagnostic);

    var input: data.NodeInput = .{
        .kind = kind,
        .parent = target.parent,
        .in_tooltip = target.place == .tooltip,
        .priority = try priorityField(reader, index, target.priority),
        .tone = try toneField(reader, index),
    };
    var samples: [data.Node.max_samples]u8 = undefined;
    // The action is parsed only once the component is staged, so a
    // component left out never keeps a command tab.
    var action_field: ?[*:0]const u8 = null;
    switch (kind) {
        .label => {
            input.text = try stringField(reader, index, "text") orelse "";
            input.style = try bar_values.parseStyle(state, index, reader.diagnostic);
        },
        .icon => {
            input.icon = try iconField(reader, index, "name");
            input.text = try stringField(reader, index, "glyph") orelse "";
            if (input.text.len > max_glyph_bytes) {
                return fail(reader, "telar.ui.icon glyph must be at most {d} bytes", .{max_glyph_bytes});
            }
            if (input.icon == null and input.text.len == 0) {
                return fail(reader, "telar.ui.icon needs a name or a glyph", .{});
            }
        },
        .mark => {
            input.mark = try markField(reader, index) orelse return fail(reader, "telar.ui.mark needs a name", .{});
        },
        .meter, .meter_row => {
            input.value = try fractionField(reader, index, "value") orelse 0;
            input.marker = try fractionField(reader, index, "marker");
            input.text = try stringField(reader, index, "label") orelse "";
            input.detail = try stringField(reader, index, if (kind == .meter) "text" else "detail") orelse "";
        },
        .sparkline => {
            input.samples = try samplesField(reader, index, &samples);
        },
        .badge, .heading, .text => {
            input.text = try stringField(reader, index, "text") orelse "";
        },
        .clock => {
            input.text = try stringField(reader, index, "format") orelse "%H:%M";
            if (input.text.len > data.bar_clock.max_format_bytes) {
                return fail(reader, "telar.ui.clock format must be at most {d} bytes", .{data.bar_clock.max_format_bytes});
            }
        },
        .metric => {
            input.metric = try metricField(reader, index);
        },
        .machines => {},
        .group => {
            input.mark = try markField(reader, index);
            input.icon = try iconField(reader, index, "icon");
            action_field = if (hasField(state, index, "on_click")) "on_click" else null;
            input.url = try stringField(reader, index, "url") orelse "";
        },
        .kv => {
            input.text = try stringField(reader, index, "key") orelse "";
            input.detail = try stringField(reader, index, "value") orelse "";
        },
        .callout => {
            input.icon = try iconField(reader, index, "icon");
            input.text = try stringField(reader, index, "text") orelse "";
            input.detail = try stringField(reader, index, "detail") orelse "";
        },
        .button => {
            input.text = try stringField(reader, index, "text") orelse "";
            action_field = if (hasField(state, index, "action")) "action" else null;
            input.url = try stringField(reader, index, "url") orelse "";
            input.primary = try boolField(reader, index, "primary");
            if (action_field == null and input.url.len == 0) {
                return fail(reader, "telar.ui.button needs an action or a url", .{});
            }
        },
        .actions, .divider => {},
    }

    const node = try append(reader, content, input, target, action_field) orelse return;
    switch (kind) {
        .group => {
            try readChildren(reader, content, .{
                .index = index,
                .place = .group,
                .parent = node.index,
                .priority = input.priority,
                .rank = node.rank,
            });
            try readTooltip(reader, content, .{
                .index = index,
                .place = .tooltip,
                .parent = node.index,
                .rank = node.rank,
            });
        },
        .actions => try readChildren(reader, content, .{
            .index = index,
            .place = .buttons,
            .parent = node.index,
            .rank = node.rank,
        }),
        .callout => {
            _ = lua_api.c.lua_getfield(state, index, "button");
            defer lua_value.pop(state, 1);
            try readList(reader, content, .{
                .index = lua_api.c.lua_absindex(state, -1),
                .place = .buttons,
                .parent = node.index,
                .rank = node.rank,
            });
        },
        else => {},
    }
}

/// Reads the array part of a container as its children.
fn readChildren(reader: Reader, content: anytype, target: Target) !void {
    const state = reader.state;
    const count = lua_api.c.lua_rawlen(state, target.index);
    for (0..count) |item| {
        _ = lua_api.c.lua_geti(state, target.index, @intCast(item + 1));
        defer lua_value.pop(state, 1);
        var child = target;
        child.index = lua_api.c.lua_absindex(state, -1);
        try readList(reader, content, child);
    }
}

/// Reads a group's `tooltip`, a string or a list of components.
fn readTooltip(reader: Reader, content: anytype, target: Target) !void {
    const state = reader.state;
    _ = lua_api.c.lua_getfield(state, target.index, "tooltip");
    defer lua_value.pop(state, 1);
    var tooltip = target;
    tooltip.index = lua_api.c.lua_absindex(state, -1);
    try readList(reader, content, tooltip);
}

/// Counts one component on the first pass; stages it on the second when
/// its rank reaches the cutoff and the staged list has room, parsing its
/// `action_field` of the component table only then. Null leaves it out,
/// and a container left out takes its children with it.
fn append(reader: Reader, content: anytype, input: data.NodeInput, target: Target, action_field: ?[*:0]const u8) !?Staged {
    if (!target.place.accepts(input.kind)) {
        return fail(reader, "telar.ui.{s} is not allowed in a {s}", .{ @tagName(input.kind), @tagName(target.place) });
    }

    const ranked: data.Node = .{
        .priority = @min(input.priority, data.Node.max_priority),
        .tone = input.tone,
    };
    const rank = @min(ranked.effectivePriority(), target.rank);
    // Counts as the component will: the placeholder stands for its action,
    // which is not parsed yet.
    var counted = input;
    if (action_field != null) {
        counted.action = .close_panel;
    }

    const pass = reader.pass;
    if (pass.counting) {
        pass.demand.add(counted);
        pass.ranked[rank].add(counted);
        return .{
            .index = 0,
            .rank = rank,
        };
    }

    if (target.parent != data.Node.no_parent) {
        pass.had_children[target.parent] = true;
    }

    if (rank < pass.cutoff) {
        return null;
    }

    const admitted = rank == pass.cutoff;
    if (admitted and !pass.admits(counted)) {
        return null;
    }

    var staged = input;
    if (action_field) |name| {
        staged.action = actionField(reader, target.index, name) catch |err| {
            try leaveOut(err);
            // A component left out gives back the room it was admitted to,
            // for the other components of the cutoff's rank.
            if (admitted) {
                pass.release(counted);
            }

            return null;
        };
    }

    const index = content.append(staged) catch |err| switch (err) {
        error.TooManyBarComponents, error.BarTextTooLong, error.TooManyBarActions, error.TooManyBarSamples => return null,
        else => {
            reader.diagnostic.set("invalid telar.ui.{s}: {s}", .{ @tagName(input.kind), @errorName(err) });
            return error.InvalidBarContent;
        },
    };
    return .{
        .index = index,
        .rank = rank,
    };
}

fn fieldsOf(kind: data.NodeKind) []const []const u8 {
    return switch (kind) {
        .label => &.{ "ui", "text", "tone", "priority", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough" },
        .icon => &.{ "ui", "name", "glyph", "tone", "priority" },
        .mark => &.{ "ui", "name", "priority" },
        .meter => &.{ "ui", "value", "label", "text", "marker", "tone", "priority" },
        .meter_row => &.{ "ui", "value", "label", "detail", "marker", "tone", "priority" },
        .sparkline => &.{ "ui", "values", "max", "tone", "priority" },
        .badge, .heading, .text => &.{ "ui", "text", "tone", "priority" },
        .clock => &.{ "ui", "format", "tone", "priority" },
        .metric => &.{ "ui", "name", "priority" },
        .machines => &.{ "ui", "priority" },
        .group => &.{ "ui", "mark", "icon", "tooltip", "on_click", "url", "priority", "tone" },
        .kv => &.{ "ui", "key", "value", "tone", "priority" },
        .callout => &.{ "ui", "icon", "text", "detail", "button", "tone", "priority" },
        .button => &.{ "ui", "text", "action", "url", "primary", "tone", "priority" },
        .actions, .divider => &.{ "ui", "priority" },
    };
}

fn kindNamed(name: []const u8) ?data.NodeKind {
    for (kind_names) |entry| {
        if (std.mem.eql(u8, entry[0], name)) {
            return entry[1];
        }
    }

    return null;
}

fn hasField(state: *lua_api.c.lua_State, index: c_int, name: [*:0]const u8) bool {
    _ = lua_api.c.lua_getfield(state, index, name);
    defer lua_value.pop(state, 1);
    return lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL;
}

fn stringField(reader: Reader, index: c_int, name: [*:0]const u8) !?[]const u8 {
    const state = reader.state;
    _ = lua_api.c.lua_getfield(state, index, name);
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return null;
    }

    return lua_value.string(state, -1) orelse return fail(reader, "component field '{s}' must be a string", .{name});
}

fn boolField(reader: Reader, index: c_int, name: [*:0]const u8) !bool {
    const state = reader.state;
    _ = lua_api.c.lua_getfield(state, index, name);
    defer lua_value.pop(state, 1);
    return switch (lua_api.c.lua_type(state, -1)) {
        lua_api.c.LUA_TNIL => false,
        lua_api.c.LUA_TBOOLEAN => lua_api.c.lua_toboolean(state, -1) != 0,
        else => return fail(reader, "component field '{s}' must be a boolean", .{name}),
    };
}

fn numberField(reader: Reader, index: c_int, name: [*:0]const u8) !?f64 {
    const state = reader.state;
    _ = lua_api.c.lua_getfield(state, index, name);
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return null;
    }
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNUMBER) {
        return fail(reader, "component field '{s}' must be a number", .{name});
    }

    const value = lua_api.c.lua_tonumberx(state, -1, null);
    if (!std.math.isFinite(value)) {
        return fail(reader, "component field '{s}' must be finite", .{name});
    }

    return value;
}

/// A value in 0..1, clamped, stored in thousandths.
fn fractionField(reader: Reader, index: c_int, name: [*:0]const u8) !?u16 {
    const value = try numberField(reader, index, name) orelse return null;
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * full_scale));
}

fn priorityField(reader: Reader, index: c_int, inherited: u8) !u8 {
    const value = try numberField(reader, index, "priority") orelse return inherited;
    if (value < 0 or value > @as(f64, @floatFromInt(data.Node.max_priority))) {
        return fail(reader, "component priority must be in 0..{d}", .{data.Node.max_priority});
    }

    return @intFromFloat(@round(value));
}

fn toneField(reader: Reader, index: c_int) !data.Tone {
    const name = try stringField(reader, index, "tone") orelse return .neutral;
    inline for (std.meta.fields(data.Tone)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return fail(reader, "unknown tone '{s}'", .{name});
}

fn iconField(reader: Reader, index: c_int, name: [*:0]const u8) !?data.icons.Icon {
    const value = try stringField(reader, index, name) orelse return null;
    return bar_values.parseBarIcon(value) orelse return fail(reader, "unknown icon '{s}'", .{value});
}

fn markField(reader: Reader, index: c_int) !?data.Mark {
    const field: [*:0]const u8 = if (hasField(reader.state, index, "name")) "name" else "mark";
    const value = try stringField(reader, index, field) orelse return null;
    inline for (std.meta.fields(data.Mark)) |mark| {
        if (std.mem.eql(u8, value, mark.name)) {
            return @enumFromInt(mark.value);
        }
    }

    return fail(reader, "unknown mark '{s}'", .{value});
}

fn metricField(reader: Reader, index: c_int) !data.MetricName {
    const value = try stringField(reader, index, "name") orelse return fail(reader, "telar.ui.metric needs a name", .{});
    inline for (std.meta.fields(data.MetricName)) |metric| {
        if (std.mem.eql(u8, value, metric.name)) {
            return @enumFromInt(metric.value);
        }
    }

    return fail(reader, "unknown metric '{s}'", .{value});
}

fn actionField(reader: Reader, index: c_int, name: [*:0]const u8) !?data.Action {
    const state = reader.state;
    _ = lua_api.c.lua_getfield(state, index, name);
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return null;
    }

    return reader.generation.parseComponentAction(-1, reader.diagnostic) catch |err| switch (err) {
        error.TooManyArguments, error.ArgumentsTooLarge, error.TooManyCommandTabs => return err,
        else => return fail(reader, "component field '{s}' must be a telar.action value", .{name}),
    };
}

/// Scales `values` to percentages of `max`, or of their largest value. A
/// longer list keeps its last `data.Node.max_samples` values, the most
/// recent in a history.
fn samplesField(reader: Reader, index: c_int, buffer: *[data.Node.max_samples]u8) ![]const u8 {
    const state = reader.state;
    const maximum = try numberField(reader, index, "max");
    _ = lua_api.c.lua_getfield(state, index, "values");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        return fail(reader, "telar.ui.sparkline needs a values list", .{});
    }

    const table = lua_api.c.lua_absindex(state, -1);
    const length = lua_api.c.lua_rawlen(state, table);
    const count = @min(length, buffer.len);
    const first = length - count;
    if (length > buffer.len) {
        reader.generation.unreported.add(.{
            .limit = data.bar_values.node_samples_limit,
            .requested = length,
        });
    }

    var values: [data.Node.max_samples]f64 = undefined;
    var largest: f64 = 0;
    for (0..count) |item| {
        _ = lua_api.c.lua_geti(state, table, @intCast(first + item + 1));
        defer lua_value.pop(state, 1);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNUMBER) {
            return fail(reader, "telar.ui.sparkline values must be numbers", .{});
        }

        const value = lua_api.c.lua_tonumberx(state, -1, null);
        if (!std.math.isFinite(value) or value < 0) {
            return fail(reader, "telar.ui.sparkline values must be finite and not negative", .{});
        }

        values[item] = value;
        largest = @max(largest, value);
    }

    const scale = maximum orelse largest;
    for (values[0..count], 0..) |value, item| {
        const fraction = if (scale > 0) std.math.clamp(value / scale, 0, 1) else 0;
        buffer[item] = @intFromFloat(@round(fraction * percent_scale));
    }

    return buffer[0..count];
}

/// A component whose action stopped at a limit is left out with its
/// children and the rest of the list stays; the limit is already kept for
/// the client to report. Any other error fails the render.
fn leaveOut(err: anyerror) anyerror!void {
    return switch (err) {
        error.TooManyArguments, error.ArgumentsTooLarge, error.TooManyCommandTabs => {},
        else => err,
    };
}

fn fail(reader: Reader, comptime message: []const u8, arguments: anytype) error{InvalidBarContent} {
    reader.diagnostic.set(message, arguments);
    return error.InvalidBarContent;
}
