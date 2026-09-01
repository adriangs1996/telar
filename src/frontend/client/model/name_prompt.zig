//! Bounded name-prompt state and pure editing transitions.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../input/root.zig");

const edit = input_capability.edit;
const schema = core.schema;

pub const Field = edit.Field(schema.max_tab_label_bytes);

pub const Target = union(enum) {
    rename_tab: schema.TabId,
    create_workspace,
    rename_workspace: schema.WorkspaceLocation,
};

pub const Begin = union(enum) {
    rename_tab: struct {
        tab_id: schema.TabId,
        label: []const u8,
    },
    create_workspace,
    rename_workspace: struct {
        workspace: schema.WorkspaceLocation,
        name: []const u8,
    },
};

pub const Command = union(enum) {
    paste_start,
    paste_end,
    insert: []const u8,
    submit,
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
};

pub const Transition = union(enum) {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    submitted: Submission,
};

pub const Prompt = struct {
    target: Target,
    field: Field,
    pasting: bool = false,
};

pub const State = struct {
    value: ?Prompt = null,
    revision: u64 = 0,

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
            .submit => {
                if (prompt.pasting) {
                    return state.editField(.{ .insert = " " });
                }
                if (prompt.field.text().len == 0) {
                    return .unchanged;
                }

                return .{ .submitted = .{
                    .target = prompt.target,
                    .name = prompt.field.text(),
                } };
            },
            .cancel => {
                state.value = null;
                state.revision +%= 1;
                return .cancelled;
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
            .paste_start, .paste_end, .submit, .cancel => unreachable,
        }
        if (!before.changed(&prompt.field)) {
            return .unchanged;
        }

        state.revision +%= 1;
        return .changed;
    }
};

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
