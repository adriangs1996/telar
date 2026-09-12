//! Visible structure and interaction state of one telar client.

const SnapshotType = @import("telar-client").AgentSnapshot;
const HistoryPaletteState = @import("telar-client").HistoryPaletteState;
const SuggestionState = @import("telar-client").SuggestionState;
const CenterType = @import("telar-client").Center;
const WorkspaceListSnapshot = @import("telar-client").WorkspaceListSnapshot;
const PlanType = @import("../../presentation/Plan.zig");
const State = @import("telar-client").State;
const PromptType = @import("telar-client").Prompt;
const tab_rename_module = @import("../../widgets/tab_rename.zig");
const ContextType = @import("../../widgets/Context.zig");
const RectType = @import("telar-core").Rect;
const PickerSources = @import("PickerSources.zig");
const GotoPickerOutput = @import("../../widgets/GotoPickerOutput.zig");
const ResultsType = @import("telar-client").Results;
const SourcesType = @import("telar-client").Sources;
const collect_module = @import("telar-client").collect;
const goto_picker_module = @import("../../widgets/goto_picker.zig");
const RowType = @import("../../widgets/Row.zig");
const max_label_bytes_module = @import("telar-client").max_label_bytes;
const describe_module = @import("telar-client").describe;
const max_history_results = @import("telar-core").max_history_results;
const EntryType = @import("../../widgets/Entry.zig");
const history_browser_module = @import("../../widgets/history_browser.zig");
const context_support = @import("../../widgets/context_support.zig");
const std = @import("std");
const RenderStats = @import("RenderStats.zig");
const ScreenType = @import("../../presentation/Screen.zig");
const BufferType = @import("telar-core").Buffer;
const PatchSinkType = @import("../../presentation/PatchSink.zig");
const diff = @import("../../presentation/diff.zig");
const CompositorType = @import("../../workspace/Compositor.zig");
const TestingComposition = @import("TestingComposition.zig");
const LayoutRegions = @import("../../widgets/LayoutRegions.zig");
const default_width = @import("telar-client").default_width;
const StateType = @import("State.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const PointerShape = @import("telar-core").PointerShape;
const TabLocationType = @import("telar-core").TabLocation;
const IntentType = @import("telar-client").Intent;
const PaneIdType = @import("telar-core").PaneId;
const term = @import("../../presentation/screen_support.zig");
const RenderInput = @import("RenderInput.zig");
const AgentInputType = @import("telar-client").AgentInput;
const TargetType = @import("telar-client").AttachmentTarget;
const CaptureType = @import("telar-client").Capture;
const attachment_preview_module = @import("../../widgets/attachment_preview.zig");
const theme_mod = @import("telar-client").theme_support;
const ColorType = @import("telar-core").Color;
const kitty_codec = @import("../../graphics/kitty_codec.zig");
const toast_module = @import("../../widgets/toast.zig");
const transition_duration_ns_module = @import("telar-client").transition_duration_ns;
const TabsModel = @import("telar-client").TabsModel;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const EntryInputType = @import("telar-client").EntryInput;

pub const empty_agent_snapshot: SnapshotType = .{};
pub const empty_history_palette: HistoryPaletteState = .{};
pub const empty_suggestion: SuggestionState = .{};
pub const empty_notifications: CenterType = .{};
pub const empty_workspace_list: WorkspaceListSnapshot = .{};
pub const empty_pane_labels: PlanType = .{};
pub const default_bars_state: State = .{};

pub fn promptKind(prompt: ?*const PromptType) tab_rename_module.Kind {
    const current = prompt orelse return .rename_tab;

    return switch (current.target()) {
        .rename_tab, .goto, .history, .suggest => .rename_tab,
        .create_workspace => .create_workspace,
        .rename_workspace => .rename_workspace,
        .copy_search => |direction| switch (direction) {
            .forward => .copy_search_forward,
            .backward => .copy_search_backward,
        },
    };
}

pub fn pickerPrompt(prompt: ?*PromptType) ?*PromptType {
    const current = prompt orelse return null;
    return switch (current.target()) {
        .goto, .history, .suggest => current,
        else => null,
    };
}

pub fn promptField(prompt: ?*PromptType) ?*tab_rename_module.Field {
    const current = prompt orelse return null;
    return switch (current.target()) {
        .goto, .history, .suggest => null,
        else => &current.field,
    };
}

/// Computes the deterministic result set and renders the visible window with
/// the clamped selection highlighted, scrolled so the selection stays visible.
pub fn renderGotoPicker(context: *ContextType, application: RectType, sources: PickerSources) GotoPickerOutput {
    var results: ResultsType = .{};
    const match_sources: SourcesType = .{
        .agents = sources.agents,
        .workspaces = sources.workspaces,
        .tabs = sources.tabs,
    };
    if (sources.prompt.target() == .suggest) {
        return renderSuggestPalette(context, application, sources);
    }
    if (sources.prompt.target() != .goto) {
        return renderHistoryPalette(context, application, sources);
    }

    collect_module(match_sources, sources.prompt.field.text(), &results);

    const total: u16 = results.len;
    const selected: u16 = if (total == 0) 0 else @min(sources.prompt.selection(), total - 1);
    const window: u16 = @min(@as(u16, goto_picker_module.max_rows), total);
    const start: u16 = if (selected + 1 > window) selected + 1 - window else 0;

    var rows: [goto_picker_module.max_rows]RowType = undefined;
    for (0..window) |offset| {
        const index = start + offset;
        var label: [max_label_bytes_module]u8 = undefined;
        const text = describe_module(match_sources, results.slice()[index].item, &label);
        var row: RowType = .{ .selected = index == selected };
        const len = @min(text.len, goto_picker_module.max_row_bytes);
        @memcpy(row.text[0..len], text[0..len]);
        row.len = @intCast(len);
        rows[offset] = row;
    }

    return goto_picker_module.render(context, application, .{
        .title = "goto",
        .field = &sources.prompt.field,
        .rows = rows[0..window],
        .total = total,
        .graphical_frame = sources.graphical_frame,
    });
}

/// Projects owned history into the specialized compact browser.
fn renderHistoryPalette(context: *ContextType, application: RectType, sources: PickerSources) GotoPickerOutput {
    const entries = sources.history.slice();
    var rows: [max_history_results]EntryType = undefined;
    for (entries, 0..) |*entry, index| {
        rows[index] = .{
            .command = sources.history.commandAt(@intCast(index)) orelse entry.commandSlice(),
            .cwd = entry.cwdSlice(),
            .id = entry.id,
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .exit_code = entry.exit_code,
            .status = entry.status,
            .author = entry.author,
        };
    }

    return history_browser_module.render(context, application, .{
        .field = &sources.prompt.field,
        .entries = rows[0..entries.len],
        .selection = sources.prompt.selection(),
        .scope = @tagName(sources.history.effective_scope),
        .inspecting = sources.prompt.inspecting(),
        .detail_scroll = sources.prompt.detailScroll(),
        .now_ms = sources.history.now_ms,
        .enter_runs = sources.history.enter_runs,
        .match_fuzzy = sources.history.match_fuzzy,
        .loading = sources.history.phase == .loading,
        .page_offset = sources.history.page_offset,
        .has_more = sources.history.has_more,
        .error_text = sources.history.errorSlice(),
        .output = sources.history.outputSlice(),
        .output_hint = sources.history.outputHint(),
        .graphical_frame = sources.graphical_frame,
    });
}

/// Renders the suggestion palette through the same list modal: one row
/// holding the suggested command, the waiting state or the failure, and a
/// footer that says what Enter does next.
fn renderSuggestPalette(context: *ContextType, application: RectType, sources: PickerSources) GotoPickerOutput {
    const state = sources.suggestion;
    const text: []const u8 = switch (state.phase) {
        .idle => "",
        .waiting => "asking the engine...",
        .ready => state.textSlice(),
        .failed => switch (state.status) {
            .ready => "the engine returned no command",
            .unavailable => "no engine configured (runtime.engine)",
            .timeout => "the engine timed out",
            .failed => "the engine could not answer",
        },
    };
    const hint: []const u8 = switch (state.phase) {
        .idle => "enter: ask",
        .waiting => "esc: cancel",
        .ready => "enter: paste",
        .failed => "enter: ask again",
    };

    var rows: [1]RowType = undefined;
    var total: u16 = 0;
    if (text.len != 0) {
        var row: RowType = .{ .selected = state.phase == .ready };
        const len = @min(text.len, goto_picker_module.max_row_bytes);
        @memcpy(row.text[0..len], text[0..len]);
        row.len = @intCast(len);
        rows[0] = row;
        total = 1;
    }

    return goto_picker_module.render(context, application, .{
        .title = "suggest",
        .field = &sources.prompt.field,
        .rows = rows[0..total],
        .total = total,
        .hint = hint,
        .graphical_frame = sources.graphical_frame,
    });
}

pub fn optionalActionEql(a: ?context_support.Action, b: ?context_support.Action) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}

pub fn addStats(a: RenderStats, b: RenderStats) RenderStats {
    return .{ .scanned = a.scanned + b.scanned, .damaged = a.damaged + b.damaged };
}

pub fn syncRegion(screen: *ScreenType, source: *const BufferType, area: RectType) !RenderStats {
    var stats: RenderStats = .{};
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        const row_start = @as(usize, y) * source.w;
        const source_row = source.cells[row_start..][0..source.w];
        var sink: PatchSinkType = .{
            .screen = screen,
            .source_row = source_row,
            .base = row_start,
        };
        stats.damaged += try diff.syncRow(.{
            .source = source_row,
            .reference = screen.back.cells[row_start..][0..source.w],
            .start = area.x,
            .end = area.x + area.w,
        }, &sink);
        stats.scanned += area.w;
    }
    return stats;
}

fn testingCompose(compositor: *CompositorType, composition: TestingComposition) !void {
    const rendered = try compositor.render(.{
        .model = composition.model,
        .screen = composition.screen,
        .input = .{
            .area = composition.area,
            .palette = composition.palette,
            .bottom_reservation = composition.bottom_reservation,
        },
    });
    _ = composition.model.commitPresentation(rendered.commit);
}

test "visible regions reserve top bottom sidebar and workbench" {
    const regions = LayoutRegions.calculate(120, 40, .{ .visible = true, .preferred_width = default_width });
    try std.testing.expectEqual(RectType{ .x = 42, .w = 78, .h = 1 }, regions.top);
    try std.testing.expectEqual(RectType{ .x = 0, .y = 0, .w = 42, .h = 40 }, regions.sidebar);
    try std.testing.expectEqual(RectType{ .x = 42, .y = 1, .w = 78, .h = 38 }, regions.workbench);
    try std.testing.expectEqual(RectType{ .x = 42, .y = 39, .w = 78, .h = 1 }, regions.bottom);
}

test "mouse pointer distinguishes clickable chrome panes and sidebar resizing" {
    var state = try StateType.init(std.testing.allocator, 80, 24);
    defer state.deinit();

    var model = MultiplexerModel.init(std.testing.allocator);
    defer model.deinit();
    const area: RectType = .{ .w = 1, .h = 1 };
    state.pointer_position = .{ .x = 0, .y = 0 };
    state.hits.add(area, .toggle_sidebar);
    try std.testing.expectEqual(PointerShape.pointer, state.mousePointerShape(.{ .model = &model }));
    try std.testing.expectEqual(PointerShape.default, state.mousePointerShape(.{ .model = &model, .copy_mode_active = true }));

    state.hits.clear();
    state.hits.add(area, .{ .focus_pane = @enumFromInt(7) });
    try std.testing.expectEqual(PointerShape.default, state.mousePointerShape(.{ .model = &model }));

    state.hits.clear();
    state.hits.add(area, .resize_sidebar);
    try std.testing.expectEqual(PointerShape.ew_resize, state.mousePointerShape(.{ .model = &model }));

    state.pointer_position = null;
    state.sidebar_resize_active = true;
    try std.testing.expectEqual(PointerShape.ew_resize, state.mousePointerShape(.{ .model = &model }));
}

test "narrow clients hide the sidebar without forgetting user intent" {
    const regions = LayoutRegions.calculate(61, 20, .{ .visible = true, .preferred_width = default_width });
    try std.testing.expect(regions.sidebar.isEmpty());
    try std.testing.expectEqual(@as(u16, 61), regions.workbench.w);
}

test "sidebar toggle changes only the disposable client layout" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 100, 30);
    defer state.deinit();
    try std.testing.expectEqual(@as(u16, default_width), state.regions.sidebar.w);
    try std.testing.expectEqual(RectType{ .x = 42, .w = 58, .h = 1 }, state.regions.top);
    try std.testing.expectEqual(RectType{ .x = 42, .y = 29, .w = 58, .h = 1 }, state.regions.bottom);

    state.toggleSidebar();

    try std.testing.expectEqual(@as(u16, 0), state.regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 100), state.regions.workbench.w);
    try std.testing.expectEqual(RectType{ .w = 100, .h = 1 }, state.regions.top);
    try std.testing.expectEqual(RectType{ .x = 0, .y = 29, .w = 100, .h = 1 }, state.regions.bottom);
}

test "sidebar separator drag reports exact preferred widths" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 120, 30);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 58, .rows = 27 } });
    var screen = try ScreenType.init(gpa, 120, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{ .model = &model, .force = true });

    const pressed = state.handleMouse(.{
        .x = state.regions.sidebar.w - 1,
        .y = 5,
        .kind = .press,
    });
    try std.testing.expect(pressed.consumed);
    try std.testing.expect(pressed.intent == .none);
    try std.testing.expect(state.sidebar_resize_active);

    const dragged = state.handleMouse(.{ .x = 72, .y = 5, .kind = .drag });
    try std.testing.expect(dragged.consumed);
    try std.testing.expectEqualDeep(IntentType{ .resize_sidebar = 73 }, dragged.intent);
    try std.testing.expect(!dragged.layout_changed);
    try std.testing.expect(state.sidebar_resize_active);

    const released = state.handleMouse(.{ .x = 70, .y = 5, .kind = .release });
    try std.testing.expect(released.consumed);
    try std.testing.expectEqualDeep(IntentType{ .resize_sidebar = 71 }, released.intent);
    try std.testing.expect(!released.layout_changed);
    try std.testing.expect(!state.sidebar_resize_active);
}

test "empty production sidebar has no task controls" {
    var state = try StateType.init(std.testing.allocator, 100, 30);
    defer state.deinit();
    var model = MultiplexerModel.init(std.testing.allocator);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 27 } });
    var screen = try ScreenType.init(std.testing.allocator, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{ .model = &model, .force = true });

    try std.testing.expect(state.hits.at(3, 2) == null);
    try std.testing.expect(state.hits.at(state.regions.sidebar.w - 4, 2) == null);
}

test "workbench clicks return focus intent without mutating pane layout" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 80, 24);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    try model.addRoot(.{ .pane_id = first, .location = location, .size = .{ .cols = 50, .rows = 22 } });
    try model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = state.workbench() });
    try std.testing.expect(model.focusPane(first));
    var screen = try ScreenType.init(gpa, 80, 24);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .force = true,
    });
    const second_view = model.layoutSnapshot(state.workbench()).find(second).?;
    const point = term.Event.Mouse{
        .x = second_view.content.x,
        .y = second_view.content.y,
        .kind = .move,
    };
    _ = state.handleMouse(point);
    state.dirty = false;
    const revision = model.layout.currentRevision();
    const interaction_revision = state.interactionVersion();

    var click = point;
    click.kind = .press;
    const interaction = state.handleMouse(click);

    try std.testing.expectEqualDeep(IntentType{ .focus_pane = second }, interaction.intent);
    try std.testing.expect(!interaction.layout_changed);
    try std.testing.expectEqual(first, model.layout.focused().?);
    try std.testing.expectEqual(revision, model.layout.currentRevision());
    try std.testing.expectEqual(interaction_revision, state.interactionVersion());
    try std.testing.expect(!state.dirty);

    model.find(first).?.pointer_shape = .crosshair;
    model.find(second).?.pointer_shape = .text;
    const input: RenderInput = .{ .model = &model, .compositor = &compositor };
    _ = try state.render(&screen, input);
    try std.testing.expectEqual(PointerShape.text, screen.mouse_pointer);
    try std.testing.expectEqual(first, model.layout.focused().?);

    inline for (std.meta.tags(PointerShape)) |shape| {
        model.find(second).?.pointer_shape = shape;
        const stats = try state.render(&screen, input);
        try std.testing.expectEqual(@as(usize, 0), stats.scanned);
        try std.testing.expectEqual(shape, screen.mouse_pointer);
    }

    model.find(second).?.pointer_shape = .text;
    _ = try state.render(&screen, .{ .model = &model, .copy_mode_active = true });
    try std.testing.expectEqual(PointerShape.default, screen.mouse_pointer);
    var prompt: PromptType = .{ .mode = .create_workspace, .field = .{} };
    _ = try state.render(&screen, .{ .model = &model, .prompt = &prompt });
    try std.testing.expectEqual(PointerShape.default, screen.mouse_pointer);
    _ = try state.render(&screen, input);
    try std.testing.expectEqual(PointerShape.text, screen.mouse_pointer);

    const before_border = state.interactionVersion();
    _ = state.handleMouse(.{ .x = second_view.outer.x, .y = point.y, .kind = .move });
    try std.testing.expectEqual(before_border + 1, state.interactionVersion());
    _ = try state.render(&screen, input);
    try std.testing.expectEqual(PointerShape.default, screen.mouse_pointer);
    _ = state.handleMouse(point);
    _ = try state.render(&screen, input);
    try std.testing.expectEqual(PointerShape.text, screen.mouse_pointer);

    const before_move = state.interactionVersion();
    _ = state.handleMouse(.{ .x = point.x + 1, .y = point.y, .kind = .move });
    try std.testing.expectEqual(before_move, state.interactionVersion());
    state.sidebar_resize_active = true;
    _ = try state.render(&screen, input);
    try std.testing.expectEqual(PointerShape.ew_resize, screen.mouse_pointer);
    state.sidebar_resize_active = false;
    model.find(second).?.attached = false;
    _ = try state.render(&screen, input);
    try std.testing.expectEqual(PointerShape.default, screen.mouse_pointer);

    try std.testing.expect(model.removePane(second));
    _ = try state.render(&screen, input);
    try std.testing.expectEqual(PointerShape.default, screen.mouse_pointer);
    _ = try state.render(&screen, .{ .model = &model, .force = true });
    try std.testing.expectEqual(PointerShape.crosshair, screen.mouse_pointer);
}

test "sidebar agent snapshots version changed hover only once" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 100, 30);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 34, .rows = 27 } });
    try model.split(.{ .existing_pane = @enumFromInt(1), .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = state.workbench() });
    try std.testing.expect(model.toggleFullscreen());
    const agent_entries = [_]AgentInputType{.{
        .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 },
        .location = location,
        .pane_index = 1,
        .provider = .codex,
        .status = .blocked,
    }};
    var snapshot: SnapshotType = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var screen = try ScreenType.init(gpa, 100, 30);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
        .force = true,
    });

    const first_row = term.Event.Mouse{ .x = 4, .y = 4, .kind = .move };
    const before_hover = state.interactionVersion();
    _ = state.handleMouse(first_row);
    try std.testing.expectEqual(before_hover + 1, state.interactionVersion());
    _ = state.handleMouse(first_row);
    try std.testing.expectEqual(before_hover + 1, state.interactionVersion());
    const click = term.Event.Mouse{ .x = 4, .y = 4, .kind = .press };
    const interaction = state.handleMouse(click);
    try std.testing.expectEqualDeep(IntentType{ .focus_agent = agent_entries[0].key }, interaction.intent);
    try std.testing.expectEqual(before_hover + 1, state.interactionVersion());
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(2)), model.layout.focused().?);
}

test "focused agent image preview reserves space below its pane and opens a modal layer" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 100, 30);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first_pane: PaneIdType = @enumFromInt(1);
    const target_pane: PaneIdType = @enumFromInt(2);
    try model.addRoot(.{ .pane_id = first_pane, .location = location, .size = .{
        .cols = state.workbench().w,
        .rows = state.workbench().h,
    } });
    try model.split(.{ .existing_pane = first_pane, .new_pane = target_pane, .location = location, .axis = .horizontal, .area = state.workbench() });
    const agent_entries = [_]AgentInputType{.{
        .key = .{ .pane_id = target_pane, .pane_generation = 4 },
        .location = location,
        .pane_index = 2,
        .provider = .codex,
        .status = .ready,
    }};
    var snapshot: SnapshotType = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    const target: TargetType = .{
        .pane_id = agent_entries[0].key.pane_id,
        .pane_generation = agent_entries[0].key.pane_generation,
    };
    try std.testing.expect(!state.syncAttachmentTarget(target));
    const capture = try gpa.create(CaptureType);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1 },
        .png = try gpa.dupe(u8, "png"),
        .width = 1,
        .height = 1,
    };
    try std.testing.expect(try state.adoptAttachment(capture));
    try std.testing.expectEqual(@as(u16, 28), state.workbench().h);

    var screen = try ScreenType.init(gpa, 100, 30);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
        .bottom_reservation = state.attachmentReservation(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
        .force = true,
    });
    const shelf = compositor.bottomReservationArea();
    const projected = compositor.layoutSnapshot();
    const first_view = projected.find(first_pane).?;
    const target_view = projected.find(target_pane).?;
    try std.testing.expectEqual(attachment_preview_module.shelf_height, shelf.h);
    try std.testing.expectEqual(target_view.outer.x, shelf.x);
    try std.testing.expectEqual(target_view.outer.w, shelf.w);
    try std.testing.expectEqual(target_view.outer.y + target_view.outer.h, shelf.y);
    try std.testing.expect(first_view.outer.h > target_view.outer.h);
    try std.testing.expect(shelf.w < state.workbench().w);
    const shelf_move = state.handleMouse(.{
        .x = shelf.x + shelf.w - 1,
        .y = shelf.y,
        .kind = .move,
    });
    try std.testing.expect(shelf_move.consumed);
    const sidebar_before_modal = screen.back.at(20, 4).?.*;

    var open_point: ?struct { x: u16, y: u16 } = null;
    for (state.hits.registered()) |entry| switch (entry.action) {
        .attachment_open => {
            open_point = .{ .x = entry.rect.x + 1, .y = entry.rect.y + 1 };
            break;
        },
        else => {},
    };
    const point = open_point orelse return error.MissingAttachmentHit;
    const opened = state.handleMouse(.{
        .x = point.x,
        .y = point.y,
        .kind = .press,
    });
    try std.testing.expect(opened.consumed);
    try std.testing.expect(state.hasAttachmentModal());

    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
    });
    try std.testing.expectEqual(RectType{ .x = 10, .y = 3, .w = 80, .h = 24 }, state.graphics_plan.modal_area);
    try std.testing.expect(!sidebar_before_modal.eqlPublic(screen.back.at(20, 4).?));

    model.find(first_pane).?.pointer_shape = .crosshair;
    _ = state.handleMouse(.{ .x = first_view.content.x, .y = first_view.content.y, .kind = .move });
    _ = try state.render(&screen, .{ .model = &model, .compositor = &compositor });
    try std.testing.expectEqual(PointerShape.pointer, screen.mouse_pointer);

    const modal_scroll = state.handleMouse(.{
        .x = state.regions.workbench.x,
        .y = state.regions.workbench.y,
        .kind = .scroll_down,
    });
    try std.testing.expect(modal_scroll.consumed);
    try std.testing.expect(state.closeAttachmentModal());

    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .agents = &snapshot,
    });
    try std.testing.expect(sidebar_before_modal.eqlPublic(screen.back.at(20, 4).?));
}

test "sidebar highlight follows pane focus and the rendered workspace" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 100, 30);
    defer state.deinit();
    const first_location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const second_location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(1),
    };
    const first_pane: PaneIdType = @enumFromInt(1);
    const second_pane: PaneIdType = @enumFromInt(2);
    const shell_pane: PaneIdType = @enumFromInt(3);
    const workspace_pane: PaneIdType = @enumFromInt(4);

    var first_model = MultiplexerModel.init(gpa);
    defer first_model.deinit();
    try first_model.addRoot(.{ .pane_id = first_pane, .location = first_location, .size = .{ .cols = 34, .rows = 27 } });
    try first_model.split(.{ .existing_pane = first_pane, .new_pane = second_pane, .location = first_location, .axis = .horizontal, .area = state.workbench() });
    try first_model.split(.{ .existing_pane = second_pane, .new_pane = shell_pane, .location = first_location, .axis = .vertical, .area = state.workbench() });
    try std.testing.expect(first_model.focusPane(first_pane));

    var second_model = MultiplexerModel.init(gpa);
    defer second_model.deinit();
    try second_model.addRoot(.{ .pane_id = workspace_pane, .location = second_location, .size = .{ .cols = 38, .rows = 27 } });

    const agent_entries = [_]AgentInputType{
        .{
            .key = .{ .pane_id = first_pane, .pane_generation = 1 },
            .location = first_location,
            .pane_index = 1,
            .provider = .codex,
            .status = .ready,
        },
        .{
            .key = .{ .pane_id = second_pane, .pane_generation = 1 },
            .location = first_location,
            .pane_index = 2,
            .provider = .claude,
            .status = .ready,
        },
        .{
            .key = .{ .pane_id = workspace_pane, .pane_generation = 1 },
            .location = second_location,
            .pane_index = 1,
            .provider = .codex,
            .status = .ready,
        },
    };
    var snapshot: SnapshotType = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var screen = try ScreenType.init(gpa, 100, 30);
    defer screen.deinit();
    const palette = state.palette();

    _ = try state.render(&screen, .{ .model = &first_model, .agents = &snapshot, .force = true });
    try std.testing.expectEqualDeep(palette.surface0, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 7).?.style.bg);

    try std.testing.expect(first_model.focusPane(second_pane));
    state.invalidate();
    _ = try state.render(&screen, .{ .model = &first_model, .agents = &snapshot });
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface0, screen.back.at(10, 7).?.style.bg);

    try std.testing.expect(first_model.focusPane(shell_pane));
    state.invalidate();
    _ = try state.render(&screen, .{ .model = &first_model, .agents = &snapshot });
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 7).?.style.bg);

    state.invalidate();
    _ = try state.render(&screen, .{ .model = &second_model, .agents = &snapshot });
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 4).?.style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.at(10, 7).?.style.bg);
    try std.testing.expectEqualDeep(palette.surface0, screen.back.at(10, 10).?.style.bg);
}

test "hybrid sidebar preserves agent hit testing and cell fallback navigation" {
    var state = try StateType.init(std.testing.allocator, 100, 30);
    defer state.deinit();
    try state.configureSidebar(.kitty_hybrid, .{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var model = MultiplexerModel.init(std.testing.allocator);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 30, .rows = 20 } });
    const agent_entries = [_]AgentInputType{.{
        .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 4 },
        .location = location,
        .pane_index = 1,
        .provider = .claude,
        .status = .ready,
    }};
    var snapshot: SnapshotType = .{};
    _ = try snapshot.replace(.{ .revision = 1, .agents = &agent_entries });
    var screen = try ScreenType.init(std.testing.allocator, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{ .model = &model, .agents = &snapshot, .force = true });
    _ = try state.prepareGraphics(&empty_notifications, true);
    try std.testing.expect(state.kittySidebar().focused_card != null);
    try std.testing.expectEqualDeep(
        context_support.Action{ .sidebar_focus_agent = agent_entries[0].key },
        state.hits.at(4, 4).?,
    );
    const interaction_revision = state.interactionVersion();
    const interaction = state.handleMouse(.{ .x = 4, .y = 4, .kind = .press });
    try std.testing.expectEqual(interaction_revision + 1, state.interactionVersion());
    try std.testing.expectEqualDeep(IntentType{ .focus_agent = agent_entries[0].key }, interaction.intent);
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(1)), model.layout.focused().?);
    try std.testing.expect(state.kittySidebar().damaged());
}

test "Nerd Font theme publishes embedded icon marks over cell fallbacks" {
    var state = try StateType.initWithAppearance(
        std.testing.allocator,
        .{ .width = 100, .height = 30 },
        .{ .theme = theme_mod.default_theme, .icons = .nerd_font },
    );
    defer state.deinit();
    try state.configureSidebar(.automatic, .{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var model = MultiplexerModel.init(std.testing.allocator);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 28 } });
    var screen = try ScreenType.init(std.testing.allocator, 100, 30);
    defer screen.deinit();

    _ = try state.render(&screen, .{ .model = &model, .force = true });
    const logo_mark = for (state.graphics_plan.icons.slice()) |mark| {
        if (mark.icon == .telar_mark) {
            break mark;
        }
    } else null;
    try std.testing.expect(logo_mark != null);
    try std.testing.expectEqualStrings(
        " ",
        screen.back.at(logo_mark.?.area.x, logo_mark.?.area.y).?.text(),
    );
    try std.testing.expect(state.graphics_plan.icons.len != 0);
    _ = try state.prepareGraphics(&empty_notifications, true);
    try std.testing.expect(state.kittyIcons().retainedBytes() != 0);
    try std.testing.expect(state.kittyIcons().damaged());
}

test "Nerd Font theme falls back to Unicode without Kitty Graphics" {
    var state = try StateType.initWithAppearance(
        std.testing.allocator,
        .{ .width = 100, .height = 30 },
        .{ .theme = theme_mod.default_theme, .icons = .nerd_font },
    );
    defer state.deinit();
    try state.configureSidebar(.automatic, .{ .support = .unsupported, .cell_width = 10, .cell_height = 20 });
    var model = MultiplexerModel.init(std.testing.allocator);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 28 } });
    var screen = try ScreenType.init(std.testing.allocator, 100, 30);
    defer screen.deinit();

    _ = try state.render(&screen, .{ .model = &model, .force = true });
    const logo = for (state.hits.registered()) |entry| {
        if (std.meta.activeTag(entry.action) == .toggle_sidebar) {
            break entry.rect;
        }
    } else null;
    try std.testing.expect(logo != null);
    try std.testing.expectEqualStrings(
        "\u{25a3}",
        screen.back.at(logo.?.x + 1, logo.?.y).?.text(),
    );
    try std.testing.expectEqual(@as(u8, 0), state.graphics_plan.icons.len);
}

test "fullscreen labels keep small-font text across focus changes and fall back on geometry changes" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 100, 24);
    defer state.deinit();
    try state.configureSidebar(.cells, .{ .support = .supported, .cell_width = 22, .cell_height = 58 });
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    const area = state.workbench();
    try model.addRoot(.{ .pane_id = first, .location = location, .size = .{ .cols = 20, .rows = 6 } });
    try model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .vertical, .area = area });
    try std.testing.expect(model.toggleFullscreen());
    var screen = try ScreenType.init(gpa, 100, 24);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    _ = try state.render(&screen, .{ .model = &model, .compositor = &compositor, .force = true });
    const original = compositor.fullscreenLabels().*;
    try std.testing.expectEqual(@as(u8, 2), original.len);
    try std.testing.expectEqual(@as(usize, 0), state.kittyPill().retainedBytes());
    const selected_x = original.area.x + original.labels[1].offset + 1;
    try std.testing.expectEqualStrings("2", screen.back.at(selected_x, original.area.y).?.text());
    try std.testing.expect(!screen.back.at(selected_x, original.area.y).?.style.flags.bold);

    _ = try state.prepareGraphics(&empty_notifications, true);
    try std.testing.expect(!state.graphicalPillCoversPlan());
    var storage: [128 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    _ = try state.kittyPill().write(&writer);
    try std.testing.expect(state.graphicalPillCoversPlan());
    state.invalidate();
    _ = try state.render(&screen, .{ .model = &model, .compositor = &compositor });
    for (original.slice()) |label| {
        for (0..label.width) |offset| {
            const cell = screen.back.at(original.area.x + label.offset + @as(u16, @intCast(offset)), original.area.y).?;
            try std.testing.expectEqualStrings(" ", cell.text());
            try std.testing.expectEqual(ColorType.default, cell.style.bg);
        }
    }

    // Gaps still show the pane border; only label rectangles are replaced.
    try std.testing.expectEqualStrings("─", screen.back.at(original.area.x + original.labels[0].width, original.area.y).?.text());
    const idle = try state.render(&screen, .{ .model = &model, .compositor = &compositor });
    try std.testing.expectEqual(@as(usize, 0), idle.scanned);
    try std.testing.expectEqual(first, model.focusDirection(.left, area).?);
    try testingCompose(&compositor, .{ .model = &model, .screen = &screen, .area = area });
    _ = try state.render(&screen, .{ .model = &model, .compositor = &compositor, .force = true });
    try std.testing.expect(!original.sameContent(compositor.fullscreenLabels()));
    try std.testing.expect(state.graphicalPillCoversPlan());
    try std.testing.expect(!state.kittyPill().retirementPending());
    try std.testing.expectEqualStrings(" ", screen.back.at(selected_x, original.area.y).?.text());
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try state.kittyPill().writeRetirements(&writer));
    _ = try state.prepareGraphics(&empty_notifications, true);
    try std.testing.expect(state.graphicalPillCoversPlan());
    writer = std.Io.Writer.fixed(&storage);
    _ = try state.kittyPill().write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=t") != null);

    // The old label row lies beyond the resized screen's right edge.
    try state.resize(40, 8);
    try screen.resize(40, 8);
    const resized_area = state.workbench();
    try testingCompose(&compositor, .{ .model = &model, .screen = &screen, .area = resized_area });
    _ = try state.render(&screen, .{ .model = &model, .compositor = &compositor, .force = true });
    const resized_labels = compositor.fullscreenLabels().area;
    try std.testing.expectEqual(resized_labels, resized_labels.intersect(screen.back.area()));
    try std.testing.expect(!state.graphicalPillCoversPlan());
    try std.testing.expect(model.toggleFullscreen());
    try testingCompose(&compositor, .{ .model = &model, .screen = &screen, .area = resized_area });
    _ = try state.render(&screen, .{ .model = &model, .compositor = &compositor, .force = true });
    try std.testing.expectEqual(@as(u8, 0), state.graphics_plan.pill_labels.len);
    writer = std.Io.Writer.fixed(&storage);
    _ = try state.kittyPill().writeRetirements(&writer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "a=d"));
    try std.testing.expect(!state.kittyPill().damaged());
}

test "cell rendering leaves toast rasterization to the media pass" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 120, 30);
    defer state.deinit();
    try state.configureSidebar(.cells, .{ .support = .supported, .cell_width = 22, .cell_height = 58 });
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{
        .cols = state.workbench().w,
        .rows = state.workbench().h,
    } });
    var center: CenterType = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    var screen = try ScreenType.init(gpa, 120, 30);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .notifications = &center,
        .force = true,
    });

    try std.testing.expectEqual(@as(usize, 0), state.kittyToasts().retainedBytes());
    _ = try state.prepareGraphics(&center, false);
    try std.testing.expectEqual(@as(usize, 0), state.kittyToasts().retainedBytes());
    try std.testing.expect(state.kittyToasts().preparationDeferred());

    // The same fixed plan is retried after the idle boundary; it does not need
    // another cell composition to make progress.
    _ = try state.prepareGraphics(&center, true);
    try std.testing.expect(
        state.kittyToasts().retainedBytes() > kitty_codec.transmission_budget_per_frame,
    );
    try std.testing.expect(state.kittyToasts().transmissionPending());
}

test "client chrome uses Vesper by default" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 80, 24);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 50, .rows = 22 } });
    var screen = try ScreenType.init(gpa, 80, 24);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .force = true,
    });

    const top_start = state.regions.top.x;
    try std.testing.expectEqualDeep(state.palette().panel_bg, screen.back.cells[top_start].style.bg);
    try std.testing.expectEqualDeep(state.palette().accent, screen.back.cells[top_start].style.fg);
    try std.testing.expect(!screen.back.cells[top_start].style.flags.inverse);
    try std.testing.expectEqual(theme_mod.Builtin.vesper, state.theme.base);
}

test "configuration diagnostics stay inside the bottom bar" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 80, 24);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    var screen = try ScreenType.init(gpa, 80, 24);
    defer screen.deinit();

    _ = try state.render(&screen, .{
        .model = &model,
        .force = true,
        .diagnostic = "invalid config",
    });

    const contracted = state.regions.bottom;
    try std.testing.expect(contracted.x > 0);
    try std.testing.expectEqualDeep(state.palette().panel_bg, screen.back.at(0, contracted.y).?.style.bg);
    try std.testing.expectEqualDeep(state.palette().red, screen.back.at(contracted.x, contracted.y).?.style.bg);
    try std.testing.expectEqualStrings("T", screen.back.at(contracted.x, contracted.y).?.text());

    state.toggleSidebar();
    _ = try state.render(&screen, .{
        .model = &model,
        .diagnostic = "invalid config",
    });

    const expanded = state.regions.bottom;
    try std.testing.expectEqual(@as(u16, 0), expanded.x);
    try std.testing.expectEqualDeep(state.palette().red, screen.back.at(0, expanded.y).?.style.bg);
    try std.testing.expectEqualStrings("T", screen.back.at(0, expanded.y).?.text());
}

test "terminal theme leaves client chrome backgrounds to the host terminal" {
    const gpa = std.testing.allocator;
    var state = try StateType.initWithTheme(gpa, .{ .width = 80, .height = 24 }, theme_mod.builtin(.terminal));
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 50, .rows = 22 } });
    var screen = try ScreenType.init(gpa, 80, 24);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
        .palette = state.palette(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .force = true,
    });

    try std.testing.expectEqualDeep(ColorType.default, screen.back.cells[0].style.bg);
    // The sidebar column stays on the host terminal's background.
    try std.testing.expectEqualDeep(
        ColorType.default,
        screen.back.cells[@as(usize, 23) * 80].style.bg,
    );
}

test "clickable toast restores pane cells after its exit animation" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 120, 30);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(7),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{
        .cols = state.workbench().w,
        .rows = state.workbench().h,
    } });
    const overlay = toast_module.overlayArea(state.workbench());
    var center: CenterType = .{};
    const notification_id = center.push(100, .{
        .level = .success,
        .title = "Ready",
        .message = "Open tab",
        .target = .{ .select_tab = location.tab_id },
    });
    const first_frame_ns = std.time.ns_per_s / 60;
    _ = center.advance(100 + first_frame_ns);
    const visible_width = center.itemAt(0).?.animatedWidth(overlay.w);
    const click_x = overlay.x + overlay.w - visible_width;
    const click_y = overlay.y;
    model.find(@enumFromInt(1)).?.buffer.setCell(
        .{ .x = click_x - state.workbench().x, .y = click_y - state.workbench().y },
        .{ .text = "u" },
    );
    var screen = try ScreenType.init(gpa, 120, 30);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = &model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .notifications = &center,
    });

    const interaction = state.handleMouse(.{
        .x = click_x,
        .y = click_y,
        .kind = .press,
    });
    try std.testing.expectEqualDeep(
        IntentType{ .notification_activate = notification_id },
        interaction.intent,
    );
    const target = center.activate(notification_id, 200).?;
    try std.testing.expectEqual(location.tab_id, target.select_tab);
    try std.testing.expect(center.advance(200 + transition_duration_ns_module));
    try std.testing.expect(!center.hasItems());
    _ = try state.render(&screen, .{
        .model = &model,
        .compositor = &compositor,
        .notifications = &center,
    });

    const restored = screen.back.cells[@as(usize, click_y) * screen.back.w + click_x];
    try std.testing.expectEqualStrings("u", restored.text());
}

test "changing themes invalidates client chrome" {
    var state = try StateType.init(std.testing.allocator, 80, 24);
    defer state.deinit();
    state.dirty = false;
    state.hovered = .active_workspace;

    state.setTheme(theme_mod.builtin(.catppuccin));

    try std.testing.expect(state.dirty);
    try std.testing.expect(state.hovered == null);
    try std.testing.expectEqual(theme_mod.Builtin.catppuccin, state.theme.base);
}

test "tab bar renders ordered labels and clicks carry runtime ids" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 80, 24);
    defer state.deinit();
    var tabs = TabsModel.init(gpa);
    defer tabs.deinit();
    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(4),
    }, .size = .{ .cols = 50, .rows = 22 } });
    _ = try tabs.addCreated(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(9) },
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 50, .rows = 22 });
    var screen = try ScreenType.init(gpa, 80, 24);
    defer screen.deinit();
    const model = &tabs.active().?.model;
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .tabs = &tabs,
        .model = model,
        .compositor = &compositor,
        .force = true,
    });

    // Tabs anchor to the right edge: " 1:main ", one empty cell and
    // " 2:logs " occupy the last seventeen columns of the bottom row.
    const click = term.Event.Mouse{ .x = 65, .y = 23, .kind = .press };
    const interaction = state.handleMouse(click);
    try std.testing.expectEqualDeep(
        IntentType{ .select_tab = @enumFromInt(4) },
        interaction.intent,
    );
    try std.testing.expect(state.hits.at(71, 23) == null);
    try std.testing.expectEqualDeep(
        IntentType{ .select_tab = @enumFromInt(9) },
        state.handleMouse(.{ .x = 72, .y = 23, .kind = .press }).intent,
    );

    // A right click only reports the intent: entering the rename prompt is
    // a mode change the client owns.
    const rename = state.handleMouse(.{
        .x = 65,
        .y = 23,
        .kind = .press,
        .button = 2,
    });
    try std.testing.expectEqualDeep(
        IntentType{ .rename_tab = @enumFromInt(4) },
        rename.intent,
    );
}

test "tab bar marks the tab whose pane is fullscreen" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 100, 30);
    defer state.deinit();
    var tabs = TabsModel.init(gpa);
    defer tabs.deinit();
    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const logs: TabLocationType = .{ .workspace = workspace, .tab_id = @enumFromInt(9) };
    try tabs.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(4),
    }, .size = .{ .cols = 50, .rows = 22 } });
    _ = try tabs.addCreated(.{
        .location = logs,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 50, .rows = 22 });
    // Creating "logs" made it the active tab; its root pane is pane 2.
    const model = &tabs.active().?.model;
    try model.split(.{ .existing_pane = @enumFromInt(2), .new_pane = @enumFromInt(3), .location = logs, .axis = .horizontal, .area = state.workbench() });
    try std.testing.expect(model.toggleFullscreen());
    var screen = try ScreenType.init(gpa, 100, 30);
    defer screen.deinit();
    var compositor = CompositorType.init(gpa);
    defer compositor.deinit();
    try testingCompose(&compositor, .{
        .model = model,
        .screen = &screen,
        .area = state.workbench(),
    });
    _ = try state.render(&screen, .{
        .tabs = &tabs,
        .model = model,
        .compositor = &compositor,
        .force = true,
    });

    // " 1:main ", one empty cell and " 2:logs ⛶ " fill the last nineteen
    // columns; the marker sits inside the second tab's click target.
    const bottom_row: usize = 29 * 100;
    try std.testing.expectEqualStrings(" ", screen.back.cells[bottom_row + 89].text());
    try std.testing.expectEqualStrings("\u{26f6}", screen.back.cells[bottom_row + 98].text());
    try std.testing.expect(state.hits.at(89, 29) == null);
    try std.testing.expectEqualDeep(
        IntentType{ .select_tab = @enumFromInt(9) },
        state.handleMouse(.{ .x = 98, .y = 29, .kind = .press }).intent,
    );

    // The inactive tab sits one surface above the bar; the gap keeps the bar.
    const palette = &state.theme.palette;
    try std.testing.expectEqualDeep(palette.surface0, screen.back.cells[bottom_row + 81].style.bg);
    try std.testing.expectEqualDeep(palette.panel_bg, screen.back.cells[bottom_row + 89].style.bg);
    try std.testing.expectEqualDeep(palette.accent, screen.back.cells[bottom_row + 98].style.bg);
}

test "the top bar lists open workspaces and clicking one requests a switch" {
    const gpa = std.testing.allocator;
    var state = try StateType.init(gpa, 100, 30);
    defer state.deinit();
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = 38, .rows = 27 } });
    var workspaces: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInputType{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
    };
    try std.testing.expect(try workspaces.replace(.{
        .revision = 1,
        .entries = &entries,
    }));
    var screen = try ScreenType.init(gpa, 100, 30);
    defer screen.deinit();
    _ = try state.render(&screen, .{
        .model = &model,
        .workspaces = &workspaces,
        .force = true,
    });

    const sidebar_requested = state.sidebar_requested;
    const sidebar_toggle = state.handleMouse(.{
        .x = state.regions.top.x,
        .y = 0,
        .kind = .press,
    });
    try std.testing.expect(sidebar_toggle.intent == .toggle_sidebar);
    try std.testing.expectEqual(sidebar_requested, state.sidebar_requested);

    // Locate hits on the top row instead of pinning glyph widths. While the
    // list fits, nothing on the row collapses it.
    var workspace_x: ?u16 = null;
    var x: u16 = 0;
    while (x < 100) : (x += 1) {
        const action = state.hits.at(x, 0) orelse continue;
        switch (std.meta.activeTag(action)) {
            .select_workspace => workspace_x = workspace_x orelse x,
            .toggle_workspace_list => return error.TestUnexpectedResult,
            else => {},
        }
    }

    const interaction = state.handleMouse(.{
        .x = workspace_x.?,
        .y = 0,
        .kind = .press,
    });
    try std.testing.expectEqualDeep(
        IntentType{ .select_workspace = @enumFromInt(2) },
        interaction.intent,
    );

    // Once collapsed, the counter is the one mouse target that expands it.
    state.workspace_list_collapsed = true;
    _ = try state.render(&screen, .{
        .model = &model,
        .workspaces = &workspaces,
        .force = true,
    });
    var counter_x: ?u16 = null;
    x = 0;
    while (x < 100) : (x += 1) {
        const action = state.hits.at(x, 0) orelse continue;
        if (std.meta.activeTag(action) == .toggle_workspace_list) {
            counter_x = x;
            break;
        }
    }

    const workspace_list_toggle = state.handleMouse(.{
        .x = counter_x.?,
        .y = 0,
        .kind = .press,
    });
    try std.testing.expect(workspace_list_toggle.intent == .toggle_workspace_list);
    try std.testing.expect(state.workspace_list_collapsed);
}
