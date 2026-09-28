//! Parses the components a bar or panel returns from Lua into a bounded list.
//! Every table is checked against the fields its component accepts, and
//! every component against the place it appears in, before anything is kept.
const ComponentSource = @import("ComponentSource.zig");
const data = @import("model");
const lua_api = @import("lua-api");
const lua_value = @import("lua_value.zig");
const bar_values = @import("bar_values.zig");
const Generation = @import("Generation.zig");
const BarCallbackContext = @import("BarCallbackContext.zig");
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
};

const Target = struct {
    index: c_int,
    place: Place,
    parent: u8 = data.Node.no_parent,
    priority: u8 = data.Node.default_priority,
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
///
/// ```zig
/// var content: data.Content = .{};
/// try component_values.parse(generation, &content, .{ .index = -1, .surface = .bar }, diagnostic);
/// ```
pub fn parse(generation: *Generation, content: anytype, request: ComponentSource, diagnostic: *data.Diagnostic) !void {
    const reader: Reader = .{
        .state = generation.vm.state,
        .diagnostic = diagnostic,
        .generation = generation,
    };

    try readList(reader, content, .{
        .index = lua_api.c.lua_absindex(reader.state, request.index),
        .place = switch (request.surface) {
            .bar => .bar,
            .panel => .panel,
        },
    });
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
            }, target.place);
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
    }, target.place);
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
    var samples: [data.CpuHistory.capacity]u8 = undefined;
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
        .group => {
            input.mark = try markField(reader, index);
            input.icon = try iconField(reader, index, "icon");
            input.action = try actionField(reader, index, "on_click");
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
            input.action = try actionField(reader, index, "action");
            input.url = try stringField(reader, index, "url") orelse "";
            input.primary = try boolField(reader, index, "primary");
            if (input.action == null and input.url.len == 0) {
                return fail(reader, "telar.ui.button needs an action or a url", .{});
            }
        },
        .actions, .divider => {},
    }

    const node = try append(reader, content, input, target.place);
    switch (kind) {
        .group => {
            try readChildren(reader, content, .{
                .index = index,
                .place = .group,
                .parent = node,
                .priority = input.priority,
            });
            try readTooltip(reader, content, .{
                .index = index,
                .place = .tooltip,
                .parent = node,
            });
        },
        .actions => try readChildren(reader, content, .{
            .index = index,
            .place = .buttons,
            .parent = node,
        }),
        .callout => {
            _ = lua_api.c.lua_getfield(state, index, "button");
            defer lua_value.pop(state, 1);
            try readList(reader, content, .{
                .index = lua_api.c.lua_absindex(state, -1),
                .place = .buttons,
                .parent = node,
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

fn append(reader: Reader, content: anytype, input: data.NodeInput, place: Place) !u8 {
    if (!place.accepts(input.kind)) {
        return fail(reader, "telar.ui.{s} is not allowed in a {s}", .{ @tagName(input.kind), @tagName(place) });
    }

    return content.append(input) catch |err| {
        reader.diagnostic.set("invalid telar.ui.{s}: {s}", .{ @tagName(input.kind), @errorName(err) });
        return error.InvalidBarContent;
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

    return reader.generation.parseComponentAction(-1, reader.diagnostic) catch
        return fail(reader, "component field '{s}' must be a telar.action value", .{name});
}

/// Scales `values` to percentages of `max`, or of their largest value.
fn samplesField(reader: Reader, index: c_int, buffer: *[data.CpuHistory.capacity]u8) ![]const u8 {
    const state = reader.state;
    const maximum = try numberField(reader, index, "max");
    _ = lua_api.c.lua_getfield(state, index, "values");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        return fail(reader, "telar.ui.sparkline needs a values list", .{});
    }

    const table = lua_api.c.lua_absindex(state, -1);
    const count = lua_api.c.lua_rawlen(state, table);
    if (count > buffer.len) {
        return fail(reader, "telar.ui.sparkline accepts at most {d} values", .{buffer.len});
    }

    var values: [data.CpuHistory.capacity]f64 = undefined;
    var largest: f64 = 0;
    for (0..count) |item| {
        _ = lua_api.c.lua_geti(state, table, @intCast(item + 1));
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

fn fail(reader: Reader, comptime message: []const u8, arguments: anytype) error{InvalidBarContent} {
    reader.diagnostic.set(message, arguments);
    return error.InvalidBarContent;
}

fn testContext(output: ?[]const u8) BarCallbackContext {
    return .{
        .client = .{
            .sidebar_visible = true,
            .tab_count = 1,
            .active_tab_index = 0,
            .pane_count = 1,
            .focused_pane_id = 1,
        },
        .time = .{
            .unix_seconds = 1,
            .year = 2026,
            .month = 9,
            .day = 26,
            .hour = 11,
            .minute = 52,
            .second = 0,
            .weekday = 6,
        },
        .metrics = null,
        .command_output = output,
    };
}

fn testLoad(source: []const u8, diagnostic: *data.Diagnostic) !*Generation {
    return Generation.loadSource(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .diagnostic = diagnostic,
    }, .{
        .source = source,
        .source_name = "@config.lua",
        .number = 4,
    });
}

test "bar components compile into a flat list with groups, tooltips and panel actions" {
    const source =
        \\local telar = require("telar")
        \\local ui = telar.ui
        \\return { api_version = 2, client = {
        \\  panels = {
        \\    usage = telar.panel({ title = "Usage", mark = "claude", render = function() return {} end }),
        \\  },
        \\  keybindings = { telar.bind({ "u" }, telar.action.open_panel("usage")) },
        \\  bars = { bottom = {
        \\    left = telar.bar.static({
        \\      ui.clock("%H:%M"),
        \\      ui.metrics({ "cpu" }),
        \\      ui.group({
        \\        mark = "claude",
        \\        priority = 90,
        \\        on_click = telar.action.open_panel({ panel = "usage" }),
        \\        tooltip = { ui.meter_row({ label = "Session", value = 0.22, marker = 0.71 }) },
        \\        ui.label({ text = "Claude", priority = 10 }),
        \\        ui.meter({ label = "5h", value = 0.22, tone = "warning" }),
        \\      }),
        \\    }),
        \\    right = telar.bar.tabs(),
        \\  } },
        \\} }
    ;
    var diagnostic: data.Diagnostic = .{};
    const generation = testLoad(source, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer generation.deinit();

    try std.testing.expectEqual(@as(u8, 1), generation.snapshot.bars.panel_count);
    try std.testing.expectEqualStrings("Usage", generation.snapshot.bars.panels[0].heading.title());
    const content = &generation.snapshot.bars.bottom[0].static;
    const nodes = content.slice();
    try std.testing.expectEqual(@as(u8, 7), content.node_count);
    try std.testing.expectEqual(data.NodeKind.clock, nodes[0].kind);
    try std.testing.expectEqualStrings("%H:%M", content.text(nodes[0].text));
    try std.testing.expectEqual(data.NodeKind.group, nodes[1].kind);
    try std.testing.expectEqual(data.MetricName.cpu, nodes[2].metric);
    try std.testing.expectEqual(@as(u8, 1), nodes[2].parent);
    try std.testing.expectEqual(data.NodeKind.group, nodes[3].kind);
    try std.testing.expect(content.action(nodes[3]).?.open_panel == 0);
    try std.testing.expect(nodes[6].in_tooltip and nodes[6].parent == 3);
    try std.testing.expectEqual(@as(u16, 710), nodes[6].marker.?);
    try std.testing.expectEqual(@as(u8, 10), nodes[4].priority);
    try std.testing.expectEqual(@as(u8, 90), nodes[5].priority);
    try std.testing.expectEqual(data.Tone.warning, nodes[5].tone);
    try std.testing.expectEqual(@as(u16, 220), nodes[5].value);
}

test "a panel renders blocks from decoded command output" {
    const source =
        \\local telar = require("telar")
        \\local ui = telar.ui
        \\return { api_version = 2, client = { panels = {
        \\  usage = telar.panel({
        \\    command = { "cat", "usage.json" },
        \\    every_ms = 30000,
        \\    render = function(ctx)
        \\      local usage = telar.json.decode(ctx.output)
        \\      return {
        \\        ui.heading("On track"),
        \\        ui.meter_row({ label = "Session", detail = "Resets 13:20", value = usage.five_hour / 100 }),
        \\        ui.callout({ text = "1 free reset", button = ui.button({ text = "Use", url = "https://example.com/reset" }) }),
        \\        ui.actions({ ui.button({ text = "Refresh", action = telar.action.refresh_panel() }) }),
        \\      }
        \\    end,
        \\  }),
        \\} } }
    ;
    var diagnostic: data.Diagnostic = .{};
    const generation = testLoad(source, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer generation.deinit();

    const definition = generation.snapshot.bars.panels[0];
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), definition.source.command.interval_ns);
    var content: data.PanelContent = .{};
    generation.invokeBar(.{
        .reference = definition.source.command.render.?,
        .context = testContext("{\n  \"five_hour\": 22\n}"),
        .surface = .panel,
    }, &content, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };

    const nodes = content.slice();
    try std.testing.expectEqual(@as(u8, 6), content.node_count);
    try std.testing.expectEqual(data.NodeKind.heading, nodes[0].kind);
    try std.testing.expectEqual(@as(u16, 220), nodes[1].value);
    try std.testing.expectEqualStrings("Resets 13:20", content.text(nodes[1].detail));
    try std.testing.expectEqual(data.NodeKind.button, nodes[3].kind);
    try std.testing.expectEqual(@as(u8, 2), nodes[3].parent);
    try std.testing.expectEqualStrings("https://example.com/reset", content.text(nodes[3].url));
    try std.testing.expect(content.action(nodes[5]).? == .refresh_panel);
}

test "components are rejected outside the places that accept them" {
    const source =
        \\local telar = require("telar")
        \\local ui = telar.ui
        \\return { api_version = 2, client = { bars = { bottom = {
        \\  left = telar.bar.dynamic({ render = function(ctx)
        \\    if ctx.pane_title == "block" then return ui.heading("x") end
        \\    return ui.meter({ value = 1, colour = "red" })
        \\  end }),
        \\  right = telar.bar.tabs(),
        \\} } } }
    ;
    var diagnostic: data.Diagnostic = .{};
    const generation = try testLoad(source, &diagnostic);
    defer generation.deinit();

    var content: data.Content = .{};
    var context = testContext(null);
    context.pane_title = "block";
    try std.testing.expectError(error.InvalidBarContent, generation.invokeBar(.{
        .reference = generation.snapshot.bars.bottom[0].dynamic.callback,
        .context = context,
    }, &content, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "not allowed in a bar") != null);

    try std.testing.expectError(error.InvalidConfig, generation.invokeBar(.{
        .reference = generation.snapshot.bars.bottom[0].dynamic.callback,
        .context = testContext(null),
    }, &content, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "colour") != null);
}

test "an action names only a configured panel" {
    var diagnostic: data.Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, testLoad(
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = { telar.bind({ "u" }, telar.action.open_panel("missing")) } } }
    , &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "missing") != null);
}
