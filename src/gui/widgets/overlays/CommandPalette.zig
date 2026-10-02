//! Native palette and pick lists share one pixel-based surface.
const cellgrid = @import("cellgrid");
const TextField = @import("../TextField.zig");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const PaletteHits = @import("PaletteHits.zig");
const PaletteRow = @import("PaletteRow.zig");
const PaletteLayout = @import("PaletteLayout.zig");
const DialogSurface = @import("DialogSurface.zig");
const SuggestionPanel = @import("SuggestionPanel.zig");
const FormButton = @import("../FormButton.zig");
const Label = @import("../Label.zig");
const key_label = @import("key_label.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const CommandPalette = @This();

pub const max_rows = PaletteHits.capacity;
pub const width_px = PaletteLayout.width_px;
pub const top_percent = 11;
pub const radius_px = 12;
projection: *const client.Projection,
hits: *PaletteHits,
modal: *?cellgrid.Rect,
native_modal: *?Rect,
router: ?*const client.key_router.Type,
scale: f32,

const Matches = union(enum) {
    goto: data.Results,
    actions: data.CommandResults,
    machines: client.MachineResults,
    pick: data.PickResults,
    suggest,

    fn count(self: *const Matches) u16 {
        return switch (self.*) {
            .goto => |*rows| rows.len,
            .actions => |*rows| rows.len,
            .machines => |*rows| rows.rows(),
            .pick => |*rows| rows.len,
            .suggest => 0,
        };
    }

    fn group(self: *const Matches, index: u16) []const u8 {
        return switch (self.*) {
            .goto => |*rows| switch (rows.slice()[index].item) {
                .workspace => "Contexts",
                .tab => "Tabs",
                .agent => "Agents",
            },
            .actions => "Actions",
            .machines => "Machines",
            else => "",
        };
    }

    fn tall(self: *const Matches, index: u16) bool {
        return self.* == .goto and self.goto.slice()[index].item == .agent;
    }
};

/// Paints all modes with the same native field, list and action footer.
/// Example: `try palette.draw(canvas);`
pub fn draw(self: CommandPalette, canvas: *Canvas) !void {
    self.hits.* = .{};
    const prompt = self.projection.prompt.?;
    const pick = prompt.target() == .pick;
    const suggest = !pick and prompt.paletteMode() == .suggest;
    const layout = PaletteLayout.measure(canvas, .{ .pick_rows = if (pick) self.projection.model.pick_list.items.count else null, .suggest = suggest });
    self.modal.* = .{ .w = self.projection.host_size.cols, .h = self.projection.host_size.rows };
    self.native_modal.* = layout.bounds;
    try (DialogSurface{ .bounds = layout.bounds, .viewport = layout.viewport }).draw(canvas);
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, layout.bounds);
    try self.heading(canvas, layout.heading);
    try self.search(canvas, layout.search);
    try self.tabs(canvas, layout.tabs);
    if (suggest) {
        try (SuggestionPanel{ .bounds = layout.results, .footer_bounds = layout.footer, .projection = self.projection }).draw(canvas);
        return;
    }

    var matches: Matches = undefined;
    if (pick) {
        matches = .{ .pick = .{} };
        data.pick_list.collect(&self.projection.model.pick_list.items, prompt.field.text(), &matches.pick);
    } else {
        switch (prompt.paletteMode()) {
            .goto => {
                matches = .{ .goto = .{} };
                data.goto_picker.collect(self.sources(), prompt.paletteQuery(), &matches.goto);
            },
            .actions => {
                matches = .{ .actions = .{} };
                data.command_palette.collect(prompt.paletteQuery(), &matches.actions);
            },
            .machines => {
                matches = .{ .machines = .{} };
                if (self.projection.machines) |machines| {
                    client.machine_picker.collect(machines, prompt.paletteQuery(), &matches.machines);
                }
            },
            .suggest => unreachable,
        }
    }
    try self.results(canvas, layout, &matches);
    try self.footer(canvas, layout.footer, matches.count() != 0);
}

fn heading(self: CommandPalette, canvas: *Canvas, bounds: Rect) !void {
    const prompt = self.projection.prompt.?;
    const title = if (prompt.target() == .pick) self.projection.model.pick_list.title() else "Suggest a command";
    var content = PaletteLayout.inset(bounds, canvas.chrome.px(8));
    const model = self.projection.model;
    if (model.palette_parent != null and model.palette_child_generation == prompt.generation) {
        const width = @min(content.width, canvas.chrome.px(26));
        try (FormButton{ .bounds = .{ .x = content.x, .y = bounds.y, .width = width, .height = bounds.height }, .text = "‹", .label = "Back to actions", .action = .{ .prompt = .cancel }, .generation = prompt.generation, .namespace = 3, .quiet = true }).draw(canvas);
        content.x += width;
        content.width -= width;
    }

    _ = try canvas.textAt(content, .{ .text = title, .face = .sans, .size = .small, .color = canvas.theme.palette.text, .alpha = 0.75 });
}

fn search(self: CommandPalette, canvas: *Canvas, bounds: Rect) !void {
    const prompt = self.projection.prompt.?;
    const px = canvas.chrome;
    const inset = @min(px.px(16), bounds.width / 8);
    const icon_width = @min(px.px(18), bounds.width / 8);
    const close_width = @min(px.px(30), bounds.width / 6);
    const close: Rect = .{ .x = bounds.x + bounds.width - inset - close_width, .y = bounds.y, .width = close_width, .height = bounds.height };
    try canvas.iconAt(.{ .x = bounds.x + inset, .y = bounds.y, .width = icon_width, .height = bounds.height }, .{ .text = "\u{f002}", .size = .body, .color = canvas.theme.palette.text, .alpha = 0.65 });
    try (FormButton{ .bounds = close, .text = "", .label = "Close palette", .action = .{ .prompt = .cancel }, .generation = prompt.generation, .namespace = 1, .quiet = true }).draw(canvas);
    try PaletteRow.keycap(canvas, close, "esc");
    const x = bounds.x + inset + icon_width;
    var field = TextField.fromPrompt(&prompt, .{ .x = x, .y = bounds.y, .width = @max(0, close.x - px.px(8) - x), .height = bounds.height }, .name);
    field.form_control = true;
    field.bare = true;
    field.label = "Search palette";
    field.placeholder = if (prompt.target() == .pick) "Search options…" else switch (prompt.paletteMode()) {
        .goto => "Search contexts, tabs and agents…",
        .actions => "Search actions…",
        .machines => "Search machines…",
        .suggest => "What would you like to do?",
    };
    field.placeholder_prefix = if (prompt.target() == .palette and prompt.field.len > 0 and data.CommandPalettePrefix.parse(prompt.field.text()[0]) != null) prompt.field.text()[0] else null;
    try field.draw(canvas);
    try separator(canvas, .{ .x = bounds.x, .y = bounds.y + bounds.height - @min(px.px(1), bounds.height), .width = bounds.width, .height = @min(px.px(1), bounds.height) });
}

fn tabs(self: CommandPalette, canvas: *Canvas, bounds: Rect) !void {
    if (bounds.height <= 0) {
        return;
    }

    const prompt = self.projection.prompt.?;
    const px = canvas.chrome;
    var x = bounds.x + px.px(12);
    for ([_]data.CommandPalettePrefix{ .goto, .actions, .machines }) |mode| {
        const label: Label = .{ .text = switch (mode) {
            .goto => "Navigate  @",
            .actions => "Actions  >",
            .machines => "Machines  :",
            .suggest => unreachable,
        }, .face = .sans, .size = .small, .color = canvas.theme.palette.text };
        const width = @min(try canvas.measure(label) + px.px(20), @max(0, bounds.x + bounds.width - px.px(8) - x));
        const tab: Rect = .{ .x = x, .y = bounds.y + px.px(5), .width = width, .height = @max(0, bounds.height - px.px(10)) };
        if (mode == prompt.paletteMode()) {
            try canvas.fillRoundedAt(tab, .{ .color = canvas.theme.palette.surface0, .radius = px.px(5) });
        }

        try (FormButton{ .bounds = tab, .text = "", .label = label.text, .action = .{ .intent = .{ .palette_mode = mode } }, .generation = prompt.generation, .namespace = mode.byte(), .quiet = true }).draw(canvas);
        _ = try canvas.textAt(PaletteLayout.inset(tab, px.px(4)), label);
        x += width + px.px(4);
    }
}

fn rowHeight(matches: *const Matches, index: u16, layout: PaletteLayout) f32 {
    return if (matches.tall(index)) layout.agent_height else layout.row_height;
}

fn results(self: CommandPalette, canvas: *Canvas, layout: PaletteLayout, matches: *const Matches) !void {
    const bounds = PaletteLayout.inset(layout.results, canvas.chrome.px(8));
    const total = matches.count();
    const prompt = self.projection.prompt.?;
    const first_quad = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first_quad, bounds);
    if (total == 0) {
        const picks = &self.projection.model.pick_list;
        const text = if (matches.* != .pick) "No results. Try another search." else switch (picks.phase) {
            .loading => "Loading options…",
            .failed => picks.errorSlice(),
            .ready, .closed => "No results. Try another search.",
        };
        _ = try canvas.textAt(PaletteLayout.inset(bounds, canvas.chrome.px(12)), .{ .text = text, .face = .sans, .size = .body, .color = if (matches.* == .pick and picks.phase == .failed) canvas.theme.palette.red else canvas.theme.palette.text, .alpha = 0.75 });
        return;
    }

    const grouped = prompt.paletteQuery().len == 0 and matches.* != .pick;
    const selected = @min(prompt.selection(), total - 1);
    var start = selected;
    var used = rowHeight(matches, selected, layout) + if (grouped) layout.group_height else @as(f32, 0);
    while (start > 0 and selected - start + 1 < max_rows) {
        const preceding = start - 1;
        const extra = rowHeight(matches, preceding, layout) + if (grouped and !std.mem.eql(u8, matches.group(preceding), matches.group(start))) layout.group_height else @as(f32, 0);
        if (used + extra > bounds.height) {
            break;
        }

        start = preceding;
        used += extra;
    }

    self.hits.first = start;
    var y = bounds.y;
    var last_group: []const u8 = "";
    var index = start;
    while (index < total and self.hits.count < max_rows) : (index += 1) {
        const group = matches.group(index);
        if (grouped and !std.mem.eql(u8, group, last_group)) {
            if (y + layout.group_height + rowHeight(matches, index, layout) > bounds.y + bounds.height) {
                break;
            }

            _ = try canvas.textAt(.{ .x = bounds.x + canvas.chrome.px(10), .y = y, .width = @max(0, bounds.width - canvas.chrome.px(20)), .height = layout.group_height }, .{ .text = group, .face = .sans, .size = .small, .bold = true, .color = canvas.theme.palette.text, .alpha = 0.65 });
            y += layout.group_height;
            last_group = group;
        }

        const height = rowHeight(matches, index, layout);
        if (y + height > bounds.y + bounds.height) {
            break;
        }

        const row_bounds: Rect = .{ .x = bounds.x, .y = y, .width = bounds.width, .height = height };
        var label_storage: [data.goto_picker.max_label_bytes]u8 = undefined;
        var key_storage: [key_label.max_bytes]u8 = undefined;
        var row = switch (matches.*) {
            .goto => |*rows| self.pickerRow(rows.slice()[index].item, &label_storage),
            .actions => |*rows| self.actionRow(rows.slice()[index].index, &key_storage),
            .machines => |*rows| if (rows.slotAt(index)) |slot| self.machineRow(slot, &label_storage) else addMachineRow(),
            .pick => |*rows| pickRow(&self.projection.model.pick_list.items, rows.slice()[index].index),
            .suggest => unreachable,
        };
        row.selected = index == selected;
        try row.drawAt(canvas, row_bounds);
        self.hits.addAt(row_bounds);
        y += height;
    }
}

fn footer(self: CommandPalette, canvas: *Canvas, bounds: Rect, enabled: bool) !void {
    const px = canvas.chrome;
    const prompt = self.projection.prompt.?;
    try separator(canvas, .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = @min(bounds.height, px.px(1)) });
    const inset = @min(px.px(14), bounds.width / 8);
    const key_width = @min(px.px(22), bounds.width / 10);
    try PaletteRow.keycap(canvas, .{ .x = bounds.x + inset, .y = bounds.y, .width = key_width, .height = bounds.height }, "↑");
    try PaletteRow.keycap(canvas, .{ .x = bounds.x + inset + key_width + px.px(4), .y = bounds.y, .width = key_width, .height = bounds.height }, "↓");
    const action = if (prompt.target() == .pick) "Choose  ↵" else switch (prompt.paletteMode()) {
        .goto => "Open  ↵",
        .actions => "Run  ↵",
        .machines => "Show  ↵",
        .suggest => unreachable,
    };
    const action_width = @min(px.px(112), bounds.width / 2);
    if (bounds.width > px.px(320)) {
        const x = bounds.x + inset + key_width * 2 + px.px(14);
        _ = try canvas.textAt(.{ .x = x, .y = bounds.y, .width = @max(0, bounds.width - (x - bounds.x) - action_width - inset), .height = bounds.height }, .{ .text = if (prompt.paletteMode() == .machines) "⇧↵ enable/disable · ^R rename · ^D remove" else "Navigate", .face = .sans, .size = .small, .color = canvas.theme.palette.text, .alpha = 0.65 });
    }

    try (FormButton{ .bounds = .{ .x = bounds.x + bounds.width - action_width - inset, .y = bounds.y + px.px(4), .width = action_width, .height = @max(0, bounds.height - px.px(8)) }, .text = action, .action = .{ .prompt = .submit }, .generation = prompt.generation, .namespace = 2, .quiet = true, .enabled = enabled }).draw(canvas);
}

fn separator(canvas: *Canvas, bounds: Rect) !void {
    try canvas.fillAt(bounds, canvas.theme.palette.surface1);
}

fn sources(self: CommandPalette) data.Sources {
    return .{ .agents = self.projection.agents, .workspaces = self.projection.workspaces, .model = self.projection.model };
}

fn pickerRow(self: CommandPalette, item: data.goto_picker.Item, storage: *[data.goto_picker.max_label_bytes]u8) PaletteRow {
    const label = data.goto_picker.describe(self.sources(), item, storage);
    const split = std.mem.indexOf(u8, label, "  ") orelse label.len;
    const icon: []const u8 = switch (item) {
        .workspace => "\u{f07b}",
        .tab => "\u{f2d0}",
        .agent => "\u{f121}",
    };
    const kind: []const u8 = switch (item) {
        .workspace => "context",
        .tab => "tab",
        .agent => "agent",
    };
    if (item == .agent) {
        const agent = self.projection.agents.find(item.agent) orelse return .{ .icon = icon, .primary = label };
        const detail = std.fmt.bufPrint(storage, "{s} · {s}", .{ agent.providerName(), agent.workspaceLabel() }) catch agent.providerName();
        return .{ .icon = icon, .primary = if (agent.sessionTitle().len != 0) agent.sessionTitle() else agent.providerName(), .secondary = detail, .detail_below = true };
    }

    const primary = if (item == .tab and std.mem.startsWith(u8, label, "tab ")) label[4..split] else label[0..split];
    return .{ .icon = icon, .primary = primary, .secondary = std.mem.trimStart(u8, label[split..], " "), .hint = if (self.projection.prompt.?.paletteQuery().len > 0) kind else "" };
}

fn actionRow(self: CommandPalette, index: u8, storage: *[key_label.max_bytes]u8) PaletteRow {
    const entry = data.command_palette.entries[index];
    const hint: []const u8 = if (self.router) |router| blk: {
        const key = router.prefixedKeyForAction(entry.action) orelse break :blk "";
        break :blk key_label.chord(storage, router.prefix, key, key_label.host_style);
    } else "";
    return .{ .icon = "\u{f105}", .primary = entry.label, .hint = hint, .shortcut = hint.len != 0 };
}

fn pickRow(items: *const data.PickItems, index: u16) PaletteRow {
    return .{
        .icon = "",
        .primary = items.label(index),
        .secondary = items.detail(index),
        .checked = items.selected[index],
        .swatch = items.swatches[index],
    };
}

fn addMachineRow() PaletteRow {
    return .{ .icon = "+", .primary = "Add machine…", .secondary = "a label and its SSH destination" };
}

// Label, then destination and state; the one on screen says so, and one
// that asks for the person carries a dot.
fn machineRow(self: CommandPalette, slot: u8, storage: *[data.goto_picker.max_label_bytes]u8) PaletteRow {
    const machines = self.projection.machines.?;
    const state: []const u8 = if (!machines.enabled[slot])
        "disabled · enter enables"
    else if (slot == machines.active)
        "shown"
    else switch (machines.phase[slot]) {
        .connected => if (machines.cpu_percent[slot]) |cpu| std.fmt.bufPrint(storage, "{d}% cpu", .{cpu}) catch "connected" else "connected",
        .connecting => "connecting",
        .lost => "unreachable · enter retries",
        .failed => if (machines.needs_setup[slot]) "no telar for this build · enter sets it up" else "failed · enter retries",
        .stopped => "disabled",
    };
    const destination = machines.destination(slot);
    return .{
        .icon = if (machines.attention[slot]) "●" else "○",
        .primary = machines.label(slot),
        .secondary = if (destination.len == 0) "this machine" else destination,
        .hint = state,
    };
}
