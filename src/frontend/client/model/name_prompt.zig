//! Bounded name-prompt state and pure editing transitions.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../input/root.zig");

const edit = input_capability.edit;
const copy_mode = input_capability.copy_mode;

pub const Direction = copy_mode.Direction;
const schema = core.schema;

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

pub const Submission = struct {
    target: Target,
    /// Borrowed from the active prompt until the synchronous submit effect
    /// returns.
    name: []const u8,
    /// True for shift+enter, which inverts the configured enter behavior of
    /// list targets.
    alternate: bool = false,
};

pub const Transition = union(enum) {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    /// The history palette asked to delete its selected entry.
    removed: u16,
    submitted: Submission,
};

pub const Prompt = struct {
    target: Target,
    field: Field,
    pasting: bool = false,
    /// Goto-picker list selection; the renderer and the submit path clamp it
    /// against the same deterministic result set.
    selection: u16 = 0,
    /// History-palette search scope, cycled with Tab.
    scope: HistoryScope = .global,
    inspecting: bool = false,
    detail_scroll: u32 = 0,
    page_requested: enum { none, older, newer } = .none,
};

pub const State = struct {
    value: ?Prompt = null,
    revision: u64 = 0,

    /// Reconciles search scope, selection and scroll after a history transition.
    /// Example: `state.updateHistory(.{ .selection = 0, .reset_scroll = true });`.
    pub fn updateHistory(state: *State, update: struct { scope: ?HistoryScope = null, selection: ?u16 = null, reset_scroll: bool = false, scroll_limit: ?u32 = null }) void {
        const prompt = state.current() orelse return;
        if (prompt.target != .history) {
            return;
        }

        if (update.scope) |scope| {
            prompt.scope = scope;
        }

        if (update.selection) |selection| {
            prompt.selection = selection;
        }

        if (update.reset_scroll) {
            prompt.detail_scroll = 0;
        }

        if (update.scroll_limit) |limit| {
            if (prompt.detail_scroll <= limit) {
                return;
            }

            prompt.detail_scroll = limit;
        }

        state.revision +%= 1;
    }

    pub fn takeHistoryPage(state: *State) @FieldType(Prompt, "page_requested") {
        const prompt = state.current() orelse return .none;
        if (prompt.target != .history) {
            return .none;
        }

        const requested = prompt.page_requested;
        prompt.page_requested = .none;
        return requested;
    }

    /// Opens or replaces the prompt and records one visible transition.
    ///
    /// ```zig
    /// prompt.begin(.create_workspace);
    /// ```
    pub fn begin(state: *State, command: Begin) void {
        state.value = switch (command) {
            .rename_tab => |rename| .{
                .target = .{ .rename_tab = rename.tab_id },
                .field = .init(rename.label),
            },
            .create_workspace => .{
                .target = .create_workspace,
                .field = .init(""),
            },
            .rename_workspace => |rename| .{
                .target = .{ .rename_workspace = rename.workspace },
                .field = .init(if (rename.name.len <= schema.max_tab_label_bytes) rename.name else ""),
            },
            .copy_search => |direction| .{
                .target = .{ .copy_search = direction },
                .field = .init(""),
            },
            .goto_picker => .{
                .target = .goto,
                .field = .init(""),
            },
            .history_palette => .{
                .target = .history,
                .field = .init(""),
            },
            .suggest_palette => .{
                .target = .suggest,
                .field = .init(""),
            },
        };
        state.revision +%= 1;
    }

    /// Returns whether input belongs to the prompt.
    ///
    /// ```zig
    /// if (prompt.active()) routeToPrompt();
    /// ```
    pub fn active(state: *const State) bool {
        return state.value != null;
    }

    /// Returns the mutable prompt used by the renderer and input adapter.
    ///
    /// ```zig
    /// const current = prompt.current() orelse return;
    /// ```
    pub fn current(state: *State) ?*Prompt {
        return if (state.value) |*value| value else null;
    }

    /// Returns the current prompt without permitting mutation.
    ///
    /// ```zig
    /// const current = prompt.currentConst() orelse return;
    /// ```
    pub fn currentConst(state: *const State) ?*const Prompt {
        return if (state.value) |*value| value else null;
    }

    /// Returns the revision observed by the client presenter.
    ///
    /// ```zig
    /// const revision = prompt.version();
    /// ```
    pub fn version(state: *const State) u64 {
        return state.revision;
    }

    /// Applies one semantic editor command. Visible changes advance the
    /// revision; paste routing changes do not request a frame.
    ///
    /// ```zig
    /// const transition = prompt.apply(.backspace);
    /// ```
    pub fn apply(state: *State, command: Command) Transition {
        const prompt = state.current() orelse return .unchanged;
        switch (command) {
            .paste_start => {
                if (prompt.pasting) {
                    return .unchanged;
                }

                prompt.pasting = true;
                return .routing_changed;
            },
            .paste_end => {
                if (!prompt.pasting) {
                    return .unchanged;
                }

                prompt.pasting = false;
                return .routing_changed;
            },
            .submit, .submit_alternate => {
                if (prompt.pasting) {
                    return state.editField(.{ .insert = " " });
                }
                if (prompt.field.text().len == 0 and !selects(prompt.target)) {
                    return .unchanged;
                }

                return .{ .submitted = .{
                    .target = prompt.target,
                    .name = prompt.field.text(),
                    .alternate = command == .submit_alternate,
                } };
            },
            .cancel => {
                if (prompt.target == .history and prompt.inspecting) {
                    prompt.inspecting = false;
                    state.revision +%= 1;
                    return .changed;
                }

                state.value = null;
                state.revision +%= 1;
                return .cancelled;
            },
            .move_up => {
                if (prompt.target == .history) {
                    prompt.selection +|= 1;
                    prompt.detail_scroll = 0;
                    state.revision +%= 1;
                    return .changed;
                }

                if (!selects(prompt.target) or prompt.selection == 0) {
                    return .unchanged;
                }

                prompt.selection -= 1;
                state.revision +%= 1;
                return .changed;
            },
            .move_down => {
                if (prompt.target == .history) {
                    if (prompt.selection == 0) {
                        prompt.page_requested = .newer;
                    }

                    prompt.selection -|= 1;
                    prompt.detail_scroll = 0;
                    state.revision +%= 1;
                    return .changed;
                }

                if (!selects(prompt.target)) {
                    return .unchanged;
                }

                prompt.selection +|= 1;
                state.revision +%= 1;
                return .changed;
            },
            .cycle_scope => {
                if (prompt.target != .history) {
                    return .unchanged;
                }

                prompt.scope = prompt.scope.next();
                prompt.selection = 0;
                state.revision +%= 1;
                return .changed;
            },
            .toggle_inspection => {
                if (prompt.target != .history or prompt.pasting) {
                    return .unchanged;
                }

                prompt.inspecting = !prompt.inspecting;
                prompt.detail_scroll = 0;
                state.revision +%= 1;
                return .changed;
            },
            .page_up, .page_down => {
                if (prompt.target != .history) {
                    return .unchanged;
                }

                if (prompt.inspecting) {
                    prompt.detail_scroll = if (command == .page_up) prompt.detail_scroll -| 10 else prompt.detail_scroll +| 10;
                } else {
                    prompt.page_requested = if (command == .page_up) .older else .newer;
                }

                state.revision +%= 1;
                return .changed;
            },
            .remove_entry => {
                if (prompt.target != .history) {
                    return .unchanged;
                }

                state.revision +%= 1;
                return .{ .removed = prompt.selection };
            },
            .insert,
            .backspace,
            .delete,
            .move_left,
            .move_right,
            .home,
            .end,
            => return state.editField(command),
        }
    }

    /// Closes only the prompt that produced an accepted submission.
    ///
    /// ```zig
    /// std.debug.assert(prompt.finish(submission.target));
    /// ```
    pub fn finish(state: *State, target: Target) bool {
        const prompt = state.currentConst() orelse return false;
        if (!std.meta.eql(prompt.target, target)) {
            return false;
        }

        state.value = null;
        state.revision +%= 1;
        return true;
    }

    fn editField(state: *State, command: Command) Transition {
        const prompt = state.current() orelse return .unchanged;
        const before: FieldPosition = .capture(&prompt.field);
        switch (command) {
            .insert => |bytes| prompt.field.insert(bytes),
            .backspace => prompt.field.backspace(),
            .delete => prompt.field.delete(),
            .move_left => |extend| prompt.field.moveLeft(extend),
            .move_right => |extend| prompt.field.moveRight(extend),
            .home => |extend| prompt.field.home(extend),
            .end => |extend| prompt.field.end(extend),
            .paste_start, .paste_end, .submit, .submit_alternate, .cancel, .move_up, .move_down, .cycle_scope, .remove_entry, .toggle_inspection, .page_up, .page_down => unreachable,
        }
        if (!before.changed(&prompt.field)) {
            return .unchanged;
        }

        if (selects(prompt.target) and before.len != prompt.field.len) {
            prompt.selection = 0;
        }
        state.revision +%= 1;
        return .changed;
    }
};

/// Targets whose prompt drives a list selection instead of a plain name.
/// The suggestion palette lists one row, so Enter on an empty field can
/// still paste it.
fn selects(target: Target) bool {
    return target == .goto or target == .history or target == .suggest;
}

const FieldPosition = struct {
    len: usize,
    head: usize,
    anchor: usize,

    fn capture(field: *const Field) FieldPosition {
        return .{
            .len = field.len,
            .head = field.head,
            .anchor = field.anchor,
        };
    }

    fn changed(before: FieldPosition, field: *const Field) bool {
        return before.len != field.len or before.head != field.head or before.anchor != field.anchor;
    }
};

test "prompt opening owns target text and one revision" {
    var state: State = .{};
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };

    state.begin(.{ .rename_workspace = .{
        .workspace = workspace,
        .name = "telar",
    } });

    const prompt = state.currentConst().?;
    try std.testing.expectEqualDeep(Target{ .rename_workspace = workspace }, prompt.target);
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
    try std.testing.expectEqual(@as(u16, 2), state.currentConst().?.selection);

    try std.testing.expect(state.apply(.{ .insert = "a" }) == .changed);
    try std.testing.expectEqual(@as(u16, 0), state.currentConst().?.selection);

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
    try std.testing.expectEqual(HistoryScope.workspace, prompt.scope);
    try std.testing.expectEqual(@as(u16, 0), prompt.selection);

    _ = state.apply(.cycle_scope);
    _ = state.apply(.cycle_scope);
    try std.testing.expect(state.apply(.cycle_scope) == .changed);
    try std.testing.expectEqual(HistoryScope.global, state.currentConst().?.scope);

    const submitted = state.apply(.submit_alternate).submitted;
    try std.testing.expect(submitted.alternate);

    state.begin(.create_workspace);
    try std.testing.expect(state.apply(.cycle_scope) == .unchanged);
}

test "the suggestion palette submits empty fields and ignores history-only commands" {
    var state: State = .{};
    state.begin(.suggest_palette);
    try std.testing.expectEqual(Target.suggest, state.currentConst().?.target);

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
    try std.testing.expectEqual(@as(u16, 10), state.currentConst().?.detail_scroll);
    try std.testing.expectEqual(@as(u16, 1), state.currentConst().?.selection);
    try std.testing.expectEqualStrings("zig", state.currentConst().?.field.text());
    try std.testing.expect(state.apply(.cancel) == .changed);
    try std.testing.expect(!state.currentConst().?.inspecting);
    try std.testing.expect(state.apply(.cancel) == .cancelled);
}
