//! Bounded name-prompt state and pure editing transitions.
const textfield = @import("textfield");

const core = @import("telar-core");
const GenericField = textfield.GenericField;
const NamePromptState = @import("NamePromptState.zig");
const WorkspaceForm = @import("WorkspaceForm.zig");
const command_palette = @import("command_palette.zig");
const std = @import("std");

pub const Field = GenericField(core.max_tab_label_bytes);
/// The working-directory field of the new-context form.
pub const DirectoryField = GenericField(core.max_cwd_bytes);

pub const Target = @import("PromptTarget.zig").PromptTarget;

pub const Begin = @import("PromptBegin.zig").PromptBegin;

pub const HistoryScope = @import("PromptHistoryScope.zig").PromptHistoryScope;

pub const Command = @import("PromptCommand.zig").PromptCommand;

/// Targets whose prompt drives a list selection instead of a plain name.
/// The suggestion palette lists one row, so Enter on an empty field can
/// still paste it.
pub fn selects(target: Target) bool {
    return target == .goto or target == .history or target == .suggest or target == .palette or target == .paths;
}

test "selection clamping and combined history updates publish exactly one revision" {
    var state: NamePromptState = .{};
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
    var state: NamePromptState = .{};
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };

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
    var state: NamePromptState = .{};
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
    var state: NamePromptState = .{};
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
    var state: NamePromptState = .{};
    state.begin(.create_workspace);

    try std.testing.expect(state.apply(.submit) == .unchanged);
    try std.testing.expectEqual(@as(u64, 1), state.version());
    try std.testing.expect(state.apply(.cancel) == .cancelled);
    try std.testing.expect(!state.active());
    try std.testing.expectEqual(@as(u64, 2), state.version());
}

test "goto picker submits empty queries and tracks a resettable selection" {
    var state: NamePromptState = .{};
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
    var state: NamePromptState = .{};
    state.begin(.create_workspace);

    try std.testing.expect(state.apply(.move_down) == .unchanged);
    try std.testing.expect(state.apply(.move_up) == .unchanged);
    try std.testing.expectEqual(@as(u64, 1), state.version());
}

test "the history palette cycles scope with Tab and only there" {
    var state: NamePromptState = .{};
    state.begin(.history_palette);
    try std.testing.expect(state.apply(.move_down) == .changed);

    try std.testing.expect(state.apply(.tab) == .changed);
    const prompt = state.currentConst().?;
    try std.testing.expectEqual(HistoryScope.workspace, prompt.mode.history.scope);
    try std.testing.expectEqual(@as(u16, 0), prompt.selection());

    _ = state.apply(.tab);
    _ = state.apply(.tab);
    try std.testing.expect(state.apply(.tab) == .changed);
    try std.testing.expectEqual(HistoryScope.global, state.currentConst().?.scope());

    const submitted = state.apply(.submit_alternate).submitted;
    try std.testing.expect(submitted.alternate);

    state.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(1), .label = "x" } });
    try std.testing.expect(state.apply(.tab) == .unchanged);
}

test "the command palette opens prefixed, switches mode by its first byte and submits its query" {
    var state: NamePromptState = .{};
    state.begin(.{ .palette = .goto });
    var prompt = state.currentConst().?;
    try std.testing.expectEqual(Target.palette, prompt.target());
    try std.testing.expectEqualStrings("@", prompt.field.text());
    try std.testing.expectEqual(command_palette.Prefix.goto, prompt.paletteMode());
    try std.testing.expectEqualStrings("", prompt.paletteQuery());

    try std.testing.expect(state.apply(.move_down) == .changed);
    try std.testing.expect(state.apply(.{ .insert = "tel" }) == .changed);
    prompt = state.currentConst().?;
    try std.testing.expectEqual(@as(u16, 0), prompt.selection());
    try std.testing.expectEqualStrings("tel", prompt.paletteQuery());

    _ = state.apply(.{ .home = false });
    try std.testing.expect(state.apply(.delete) == .changed);
    try std.testing.expectEqual(command_palette.Prefix.goto, state.currentConst().?.paletteMode());
    try std.testing.expectEqualStrings("tel", state.currentConst().?.paletteQuery());
    try std.testing.expect(state.apply(.{ .insert = ">" }) == .changed);
    try std.testing.expectEqual(command_palette.Prefix.actions, state.currentConst().?.paletteMode());
    try std.testing.expectEqualStrings("tel", state.currentConst().?.paletteQuery());
    try std.testing.expect(state.apply(.tab) == .unchanged);
    try std.testing.expect(state.apply(.remove_entry) == .unchanged);

    state.select(3);
    try std.testing.expectEqual(@as(u16, 3), state.currentConst().?.selection());
    const submitted = state.apply(.submit).submitted;
    try std.testing.expectEqualStrings(">tel", submitted.name);
    try std.testing.expect(state.finish(.palette));
    try std.testing.expect(!state.active());

    state.begin(.{ .palette = .suggest });
    try std.testing.expectEqualStrings("?", state.currentConst().?.field.text());
    try std.testing.expect(state.apply(.submit) == .submitted);
    try std.testing.expect(state.apply(.cancel) == .cancelled);
}

test "the suggestion palette submits empty fields and ignores history-only commands" {
    var state: NamePromptState = .{};
    state.begin(.suggest_palette);
    try std.testing.expectEqual(Target.suggest, state.currentConst().?.target());

    try std.testing.expect(state.apply(.tab) == .unchanged);
    try std.testing.expect(state.apply(.remove_entry) == .unchanged);
    try std.testing.expect(state.apply(.submit) == .submitted);
    try std.testing.expect(state.apply(.{ .insert = "list files" }) == .changed);
    const submitted = state.apply(.submit).submitted;
    try std.testing.expectEqualStrings("list files", submitted.name);
    try std.testing.expect(state.finish(.suggest));
    try std.testing.expect(!state.active());
}

test "history inspection preserves query and selection and escape returns before closing" {
    var state: NamePromptState = .{};
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

test "the new-context form moves focus with tab and edits only the focused field" {
    var state: NamePromptState = .{};
    state.begin(.create_workspace);
    try std.testing.expect(state.apply(.{ .insert = "agents" }) == .changed);
    try std.testing.expectEqual(WorkspaceForm.Focus.name, state.currentConst().?.form().?.focus);

    try std.testing.expect(state.apply(.tab) == .changed);
    try std.testing.expectEqual(WorkspaceForm.Focus.directory, state.currentConst().?.form().?.focus);
    try std.testing.expect(state.apply(.{ .insert = "~/sand" }) == .changed);
    try std.testing.expectEqualStrings("agents", state.currentConst().?.field.text());
    try std.testing.expectEqualStrings("~/sand", state.currentConst().?.directory.text());

    try std.testing.expect(state.apply(.tab) == .completion_requested);
    try std.testing.expect(state.apply(.back_tab) == .changed);
    try std.testing.expectEqual(WorkspaceForm.Focus.name, state.currentConst().?.form().?.focus);
    try std.testing.expect(state.apply(.back_tab) == .changed);
    try std.testing.expectEqual(WorkspaceForm.Focus.directory, state.currentConst().?.form().?.focus);
}

test "the new-context form selects completions in the directory field and resets on edits" {
    var state: NamePromptState = .{};
    state.begin(.create_workspace);
    state.select(3);
    try std.testing.expectEqual(@as(u16, 0), state.currentConst().?.selection());
    try std.testing.expect(state.apply(.move_down) == .unchanged);
    _ = state.apply(.tab);
    try std.testing.expect(state.apply(.move_up) == .unchanged);
    try std.testing.expect(state.apply(.move_down) == .changed);
    try std.testing.expect(state.apply(.move_down) == .changed);
    try std.testing.expectEqual(@as(u16, 2), state.currentConst().?.selection());
    try std.testing.expect(state.apply(.move_up) == .changed);
    try std.testing.expectEqual(@as(u16, 1), state.currentConst().?.selection());
    state.select(4);
    try std.testing.expectEqual(@as(u16, 4), state.currentConst().?.selection());

    try std.testing.expect(state.apply(.{ .insert = "t" }) == .changed);
    try std.testing.expectEqual(@as(u16, 0), state.currentConst().?.selection());
    state.constrainSelection(0);

    state.replaceDirectory("/work/telar/");
    try std.testing.expectEqualStrings("/work/telar/", state.currentConst().?.directory.text());
    try std.testing.expectEqual(WorkspaceForm.Focus.directory, state.currentConst().?.form().?.focus);
}

test "the new-context form submits either field and carries the directory confirmation" {
    var state: NamePromptState = .{};
    state.begin(.create_workspace);
    try std.testing.expect(state.apply(.submit) == .unchanged);
    _ = state.apply(.tab);
    _ = state.apply(.{ .insert = "/tmp/new" });

    const first = state.apply(.submit).submitted;
    try std.testing.expectEqualStrings("", first.name);
    try std.testing.expectEqualStrings("/tmp/new", first.directory);
    try std.testing.expect(!first.create_directory);

    const before = state.version();
    state.requestDirectoryConfirmation();
    try std.testing.expectEqual(before + 1, state.version());
    try std.testing.expect(state.currentConst().?.form().?.confirm_create);
    const second = state.apply(.submit).submitted;
    try std.testing.expect(second.create_directory);

    try std.testing.expect(state.apply(.backspace) == .changed);
    try std.testing.expect(!state.currentConst().?.form().?.confirm_create);
    try std.testing.expect(!state.apply(.submit).submitted.create_directory);
}
