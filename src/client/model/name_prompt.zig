//! Bounded name-prompt state and pure editing transitions.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");

const edit = input_capability.edit;
pub const copy_mode = input_capability.copy_mode;

pub const Direction = copy_mode.Direction;
pub const schema = core.schema;

pub const Field = edit.Field(schema.max_tab_label_bytes);

pub const Target = union(enum) {
    rename_tab: schema.TabId,
    create_workspace,
    rename_workspace: schema.WorkspaceLocation,
    /// Copy-mode search input; the direction was chosen by `/` or `?`.
    copy_search: copy_mode.Direction,
    /// Fuzzy goto picker over workspaces, tabs and agents.
    goto,
    /// History palette; results live in the history-palette model state.
    history,
    /// Command-suggestion palette; the reply lives in the suggestion model
    /// state and Enter asks or pastes depending on it.
    suggest,
};

pub const Begin = union(enum) {
    copy_search: copy_mode.Direction,
    rename_tab: struct {
        tab_id: schema.TabId,
        label: []const u8,
    },
    create_workspace,
    rename_workspace: struct {
        workspace: schema.WorkspaceLocation,
        name: []const u8,
    },
    goto_picker,
    history_palette,
    suggest_palette,
};

pub const HistoryScope = enum(u8) {
    global = 0,
    workspace = 1,
    cwd = 2,
    pane = 3,

    pub fn next(scope: HistoryScope) HistoryScope {
        return switch (scope) {
            .global => .workspace,
            .workspace => .cwd,
            .cwd => .pane,
            .pane => .global,
        };
    }

    pub fn label(scope: HistoryScope) []const u8 {
        return switch (scope) {
            .global => "global",
            .workspace => "workspace",
            .cwd => "cwd",
            .pane => "pane",
        };
    }
};

pub const Command = union(enum) {
    paste_start,
    paste_end,
    insert: []const u8,
    move_up,
    move_down,
    cycle_scope,
    remove_entry,
    toggle_inspection,
    page_up,
    page_down,
    submit,
    submit_alternate,
    cancel,
    backspace,
    delete,
    move_left: bool,
    move_right: bool,
    home: bool,
    end: bool,
};

pub const Submission = @import("Submission.zig");

pub const Transition = union(enum) {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    /// The history palette asked to delete its selected entry.
    removed: u16,
    submitted: Submission,
};

pub const History = @import("History.zig");

pub const Prompt = @import("Prompt.zig");

pub const State = @import("NamePromptState.zig");

/// Targets whose prompt drives a list selection instead of a plain name.
/// The suggestion palette lists one row, so Enter on an empty field can
/// still paste it.
pub fn selects(target: Target) bool {
    return target == .goto or target == .history or target == .suggest;
}

const FieldPosition = @import("FieldPosition.zig");

test "selection clamping and combined history updates publish exactly one revision" {
    var state: State = .{};
    state.begin(.goto_picker);
    _ = state.apply(.move_down);
    const selected_revision = state.version();
    state.constrainSelection(1);
    try std.testing.expectEqual(@as(u16, 0), state.currentConst().?.selection());
    try std.testing.expectEqual(selected_revision + 1, state.version());
    state.constrainSelection(0);
    try std.testing.expectEqual(selected_revision + 1, state.version());

    state.begin(.history_palette);
    const before = state.version();
    state.updateHistory(.{ .scope = .cwd, .scroll_limit = 0 });
    try std.testing.expectEqual(before + 1, state.version());
    try std.testing.expectEqual(HistoryScope.cwd, state.currentConst().?.scope());
    state.updateHistory(.{ .scope = .cwd, .scroll_limit = 0 });
    try std.testing.expectEqual(before + 1, state.version());
    state.begin(.create_workspace);
    try std.testing.expect(state.currentConst().?.mode == .create_workspace);
    state.updateHistory(.{ .scope = .pane });
    try std.testing.expectEqual(HistoryScope.global, state.currentConst().?.scope());
}

test "prompt opening owns target text and one revision" {
    var state: State = .{};
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };

    state.begin(.{ .rename_workspace = .{
        .workspace = workspace,
        .name = "telar",
    } });

    const prompt = state.currentConst().?;
    try std.testing.expectEqualDeep(Target{ .rename_workspace = workspace }, prompt.target());
    try std.testing.expectEqualStrings("telar", prompt.field.text());
    try std.testing.expectEqual(@as(u64, 1), state.version());
}

test "visible edits advance revision while paste routing does not" {
    var state: State = .{};
    state.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(3), .label = "logs" } });

    try std.testing.expect(state.apply(.paste_start) == .routing_changed);
    try std.testing.expectEqual(@as(u64, 1), state.version());
    try std.testing.expect(state.apply(.submit) == .changed);
    try std.testing.expectEqualStrings("logs ", state.currentConst().?.field.text());
    try std.testing.expectEqual(@as(u64, 2), state.version());
    try std.testing.expect(state.apply(.paste_end) == .routing_changed);
    try std.testing.expectEqual(@as(u64, 2), state.version());

    try std.testing.expect(state.apply(.backspace) == .changed);
    try std.testing.expectEqualStrings("logs", state.currentConst().?.field.text());
    try std.testing.expectEqual(@as(u64, 3), state.version());
}

test "submission borrows state until matching completion" {
    var state: State = .{};
    state.begin(.create_workspace);
    try std.testing.expect(state.apply(.{ .insert = "agents" }) == .changed);

    const submitted = state.apply(.submit).submitted;

    try std.testing.expectEqualDeep(Target.create_workspace, submitted.target);
    try std.testing.expectEqualStrings("agents", submitted.name);
    try std.testing.expect(state.active());
    try std.testing.expect(!state.finish(.{ .rename_tab = @enumFromInt(9) }));
    try std.testing.expect(state.finish(submitted.target));
    try std.testing.expect(!state.active());
    try std.testing.expectEqual(@as(u64, 3), state.version());
}

test "cancel closes the prompt and empty submit is inert" {
    var state: State = .{};
    state.begin(.create_workspace);

    try std.testing.expect(state.apply(.submit) == .unchanged);
    try std.testing.expectEqual(@as(u64, 1), state.version());
    try std.testing.expect(state.apply(.cancel) == .cancelled);
    try std.testing.expect(!state.active());
    try std.testing.expectEqual(@as(u64, 2), state.version());
}

test "goto picker submits empty queries and tracks a resettable selection" {
    var state: State = .{};
    state.begin(.goto_picker);

    try std.testing.expect(state.apply(.move_up) == .unchanged);
    try std.testing.expect(state.apply(.move_down) == .changed);
    try std.testing.expect(state.apply(.move_down) == .changed);
    try std.testing.expectEqual(@as(u16, 2), state.currentConst().?.selection());

    try std.testing.expect(state.apply(.{ .insert = "a" }) == .changed);
    try std.testing.expectEqual(@as(u16, 0), state.currentConst().?.selection());

    const submitted = state.apply(.submit).submitted;
    try std.testing.expectEqualStrings("a", submitted.name);
    try std.testing.expect(state.finish(.goto));

    state.begin(.goto_picker);
    try std.testing.expect(state.apply(.submit) == .submitted);
}

test "rename prompts ignore picker selection commands" {
    var state: State = .{};
    state.begin(.create_workspace);

    try std.testing.expect(state.apply(.move_down) == .unchanged);
    try std.testing.expect(state.apply(.move_up) == .unchanged);
    try std.testing.expectEqual(@as(u64, 1), state.version());
}

test "the history palette cycles scope with Tab and only there" {
    var state: State = .{};
    state.begin(.history_palette);
    try std.testing.expect(state.apply(.move_down) == .changed);

    try std.testing.expect(state.apply(.cycle_scope) == .changed);
    const prompt = state.currentConst().?;
    try std.testing.expectEqual(HistoryScope.workspace, prompt.mode.history.scope);
    try std.testing.expectEqual(@as(u16, 0), prompt.selection());

    _ = state.apply(.cycle_scope);
    _ = state.apply(.cycle_scope);
    try std.testing.expect(state.apply(.cycle_scope) == .changed);
    try std.testing.expectEqual(HistoryScope.global, state.currentConst().?.scope());

    const submitted = state.apply(.submit_alternate).submitted;
    try std.testing.expect(submitted.alternate);

    state.begin(.create_workspace);
    try std.testing.expect(state.apply(.cycle_scope) == .unchanged);
}

test "the suggestion palette submits empty fields and ignores history-only commands" {
    var state: State = .{};
    state.begin(.suggest_palette);
    try std.testing.expectEqual(Target.suggest, state.currentConst().?.target());

    try std.testing.expect(state.apply(.cycle_scope) == .unchanged);
    try std.testing.expect(state.apply(.remove_entry) == .unchanged);
    try std.testing.expect(state.apply(.submit) == .submitted);
    try std.testing.expect(state.apply(.{ .insert = "list files" }) == .changed);
    const submitted = state.apply(.submit).submitted;
    try std.testing.expectEqualStrings("list files", submitted.name);
    try std.testing.expect(state.finish(.suggest));
    try std.testing.expect(!state.active());
}

test "history inspection preserves query and selection and escape returns before closing" {
    var state: State = .{};
    state.begin(.history_palette);
    _ = state.apply(.{ .insert = "zig" });
    _ = state.apply(.move_up);
    _ = state.apply(.toggle_inspection);
    _ = state.apply(.page_down);
    try std.testing.expectEqual(@as(u16, 10), state.currentConst().?.detailScroll());
    try std.testing.expectEqual(@as(u16, 1), state.currentConst().?.selection());
    try std.testing.expectEqualStrings("zig", state.currentConst().?.field.text());
    try std.testing.expect(state.apply(.cancel) == .changed);
    try std.testing.expect(!state.currentConst().?.inspecting());
    try std.testing.expect(state.apply(.cancel) == .cancelled);
}
