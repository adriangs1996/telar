const PanelDefinition = @import("PanelDefinition.zig");
const PickDefinition = @import("PickDefinition.zig");
const model = @import("model.zig");
const Layout = @import("BarLayout.zig");
const std = @import("std");
const Configuration = @This();

/// The panel or pick index of an action that names an entry left out at
/// its limit; no entry has it, so the action does nothing.
pub const dropped_index: u8 = std.math.maxInt(u8);

bottom: [3]model.Source = .{ .metrics, .empty, .tabs },
top_right: model.Source = .empty,
/// Left-to-right slots of the sidebar footer row; tabs are never accepted here.
sidebar_footer: [3]model.Source = .{ .metrics, .empty, .empty },
/// `client.panels`, in the order their names were sorted while loading.
panels: [model.max_panels]PanelDefinition = @splat(.{}),
panel_count: u8 = 0,
/// `client.picks`, in the order their names were sorted while loading.
picks: [model.max_picks]PickDefinition = @splat(.{}),
pick_count: u8 = 0,

pub fn source(self: *const Configuration, position: model.Position) *const model.Source {
    return switch (position) {
        .bottom_left => &self.bottom[0],
        .bottom_center => &self.bottom[1],
        .bottom_right => &self.bottom[2],
        .top_right => &self.top_right,
        .sidebar_footer_left => &self.sidebar_footer[0],
        .sidebar_footer_center => &self.sidebar_footer[1],
        .sidebar_footer_right => &self.sidebar_footer[2],
    };
}

pub fn panel(self: *const Configuration, index: u8) ?*const PanelDefinition {
    if (index >= self.panel_count) {
        return null;
    }

    return &self.panels[index];
}

/// Resolves a panel name while configuration and callback results are parsed.
/// Example: `const index = configuration.panelIndex("claude") orelse return error.UnknownPanel;`
pub fn panelIndex(self: *const Configuration, name: []const u8) ?u8 {
    for (self.panels[0..self.panel_count], 0..) |*definition, index| {
        if (std.mem.eql(u8, definition.heading.name(), name)) {
            return @intCast(index);
        }
    }

    return null;
}

pub fn pick(self: *const Configuration, index: u8) ?*const PickDefinition {
    if (index >= self.pick_count) {
        return null;
    }

    return &self.picks[index];
}

/// Resolves a pick name while configuration and callback results are parsed.
/// Example: `const index = configuration.pickIndex("pi_model") orelse return error.UnknownPick;`
pub fn pickIndex(self: *const Configuration, name: []const u8) ?u8 {
    for (self.picks[0..self.pick_count], 0..) |*definition, index| {
        if (std.mem.eql(u8, definition.heading.name(), name)) {
            return @intCast(index);
        }
    }

    return null;
}

pub fn presentation(self: *const Configuration) Layout {
    var result: Layout = .{};
    inline for (std.meta.fields(model.Position)) |field| {
        const position: model.Position = @enumFromInt(field.value);
        result.set(position, model.presentationSlot(self.source(position)));
        if (sourceGeneration(self.source(position))) |generation| {
            result.generation = generation;
            result.live_mask |= position.bit();
        }
    }

    for (self.panels[0..self.panel_count], 0..) |*definition, index| {
        result.panels[index] = definition.heading;
        if (sourceGeneration(&definition.source)) |generation| {
            result.generation = generation;
        }
    }
    result.panel_count = self.panel_count;

    return result;
}

fn sourceGeneration(value: *const model.Source) ?u64 {
    return switch (value.*) {
        .dynamic => |dynamic| dynamic.callback.generation,
        .command => |command| command.generation,
        else => null,
    };
}
