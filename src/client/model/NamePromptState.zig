const Prompt = @import("Prompt.zig");
const name_prompt = @import("name_prompt.zig");
const std = @import("std");
const History = @import("History.zig");
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const FieldPosition = @import("FieldPosition.zig");
const State = @This();

value: ?Prompt = null,
revision: u64 = 0,
generation: u64 = 0,

/// Reconciles search scope, selection and scroll after a history transition.
/// Example: `state.updateHistory(.{ .selection = 0, .reset_scroll = true });`.
pub fn updateHistory(state: *State, update: struct { scope: ?name_prompt.HistoryScope = null, selection: ?u16 = null, reset_scroll: bool = false, scroll_limit: ?u32 = null }) void {
    const prompt = state.mutable() orelse return;
    if (prompt.mode != .history) {
        return;
    }

    const history = &prompt.mode.history;
    const before = history.*;
    if (update.scope) |scope| {
        history.scope = scope;
    }

    if (update.selection) |selected| {
        history.selection = selected;
    }

    if (update.reset_scroll) {
        history.detail_scroll = 0;
    }

    if (update.scroll_limit) |limit| {
        history.detail_scroll = @min(history.detail_scroll, limit);
    }

    if (!std.meta.eql(before, history.*)) {
        state.revision +%= 1;
    }
}

/// Clamps the selected result and commits a revision only when it changes.
/// Example: `state.constrainSelection(result_count);`.
pub fn constrainSelection(state: *State, count: u16) void {
    const prompt = state.mutable() orelse return;
    const selected = @min(prompt.selection(), count -| 1);
    if (selected != prompt.selection()) {
        prompt.setSelection(selected);
        state.revision +%= 1;
    }
}

pub fn takeHistoryPage(state: *State) @FieldType(History, "page_requested") {
    const prompt = state.mutable() orelse return .none;
    if (prompt.target() != .history) {
        return .none;
    }

    const requested = prompt.mode.history.page_requested;
    prompt.mode.history.page_requested = .none;
    return requested;
}

/// Opens or replaces the prompt and records one visible transition.
///
/// ```zig
/// prompt.begin(.create_workspace);
/// ```
pub fn begin(state: *State, command: name_prompt.Begin) void {
    state.generation += 1;
    state.value = switch (command) {
        .rename_tab => |rename| .{
            .mode = .{ .rename_tab = rename.tab_id },
            .field = .init(rename.label),
        },
        .create_workspace => .{
            .mode = .{ .create_workspace = .{} },
            .field = .init(""),
        },
        .rename_workspace => |rename| .{
            .mode = .{ .rename_workspace = rename.workspace },
            .field = .init(if (rename.name.len <= max_tab_label_bytes_module) rename.name else ""),
        },
        .copy_search => |direction| .{
            .mode = .{ .copy_search = direction },
            .field = .init(""),
        },
        .goto_picker => .{
            .mode = .{ .goto = .{} },
            .field = .init(""),
        },
        .history_palette => .{
            .mode = .{ .history = .{} },
            .field = .init(""),
        },
        .suggest_palette => .{
            .mode = .suggest,
            .field = .init(""),
        },
        .palette => |prefix| .{
            .mode = .{ .palette = .{} },
            .field = .init(&[_]u8{prefix.byte()}),
        },
    };
    state.value.?.generation = state.generation;
    state.revision +%= 1;
}

/// Moves a list selection to one exact row, as a pointer press does; the
/// controller clamps it against the current result set afterwards.
///
/// ```zig
/// state.select(row);
/// ```
pub fn select(state: *State, index: u16) void {
    const prompt = state.mutable() orelse return;
    if (!name_prompt.selects(prompt.target()) or prompt.selection() == index) {
        return;
    }

    prompt.setSelection(index);
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

fn mutable(state: *State) ?*Prompt {
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
pub fn apply(state: *State, command: name_prompt.Command) name_prompt.Transition {
    const prompt = state.mutable() orelse return .unchanged;
    switch (command) {
        .focus_field => |focus| {
            if (prompt.mode != .create_workspace or prompt.mode.create_workspace.focus == focus) {
                return .unchanged;
            }

            prompt.mode.create_workspace.focus = focus;
            state.revision +%= 1;
            return .changed;
        },
        .replace_range => |replacement| {
            const changed = if (directoryFocused(prompt)) prompt.directory.replace(replacement.range, replacement.text) else prompt.field.replace(replacement.range, replacement.text);
            if (!changed) {
                return .unchanged;
            }

            if (directoryFocused(prompt)) {
                prompt.mode.create_workspace = .{ .focus = .directory };
            } else if (name_prompt.selects(prompt.target())) {
                prompt.setSelection(0);
            }

            state.revision +%= 1;
            return .changed;
        },
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
            if (prompt.form()) |form_state| {
                if (prompt.field.text().len == 0 and prompt.directory.text().len == 0) {
                    return .unchanged;
                }

                return .{ .submitted = .{
                    .target = prompt.target(),
                    .name = prompt.field.text(),
                    .directory = prompt.directory.text(),
                    .create_directory = form_state.confirm_create,
                } };
            }
            if (prompt.field.text().len == 0 and !name_prompt.selects(prompt.target())) {
                return .unchanged;
            }

            return .{ .submitted = .{
                .target = prompt.target(),
                .name = prompt.field.text(),
                .alternate = command == .submit_alternate,
            } };
        },
        .cancel => {
            if (prompt.target() == .history and prompt.mode.history.inspecting) {
                prompt.mode.history.inspecting = false;
                state.revision +%= 1;
                return .changed;
            }

            state.value = null;
            state.revision +%= 1;
            return .cancelled;
        },
        .move_up => {
            if (prompt.target() == .history) {
                prompt.setSelection(prompt.selection() +| 1);
                prompt.mode.history.detail_scroll = 0;
                state.revision +%= 1;
                return .changed;
            }

            if (!(name_prompt.selects(prompt.target()) or directoryFocused(prompt)) or prompt.selection() == 0) {
                return .unchanged;
            }

            prompt.setSelection(prompt.selection() - 1);
            state.revision +%= 1;
            return .changed;
        },
        .move_down => {
            if (prompt.target() == .history) {
                if (prompt.selection() == 0) {
                    prompt.mode.history.page_requested = .newer;
                }

                prompt.setSelection(prompt.selection() -| 1);
                prompt.mode.history.detail_scroll = 0;
                state.revision +%= 1;
                return .changed;
            }

            if (!(name_prompt.selects(prompt.target()) or directoryFocused(prompt))) {
                return .unchanged;
            }

            prompt.setSelection(prompt.selection() +| 1);
            state.revision +%= 1;
            return .changed;
        },
        .tab => {
            if (prompt.mode == .create_workspace) {
                const form_state = &prompt.mode.create_workspace;
                if (form_state.focus == .directory) {
                    return .completion_requested;
                }

                form_state.focus = .directory;
                state.revision +%= 1;
                return .changed;
            }
            if (prompt.target() != .history) {
                return .unchanged;
            }

            prompt.mode.history.scope = prompt.mode.history.scope.next();
            prompt.setSelection(0);
            state.revision +%= 1;
            return .changed;
        },
        .back_tab => {
            if (prompt.mode != .create_workspace) {
                return .unchanged;
            }

            const form_state = &prompt.mode.create_workspace;
            form_state.focus = if (form_state.focus == .name) .directory else .name;
            state.revision +%= 1;
            return .changed;
        },
        .toggle_inspection => {
            if (prompt.target() != .history or prompt.pasting) {
                return .unchanged;
            }

            prompt.mode.history.inspecting = !prompt.mode.history.inspecting;
            prompt.mode.history.detail_scroll = 0;
            state.revision +%= 1;
            return .changed;
        },
        .page_up, .page_down => {
            if (prompt.target() != .history) {
                return .unchanged;
            }

            if (prompt.mode.history.inspecting) {
                prompt.mode.history.detail_scroll = if (command == .page_up) prompt.mode.history.detail_scroll -| 10 else prompt.mode.history.detail_scroll +| 10;
            } else {
                prompt.mode.history.page_requested = if (command == .page_up) .older else .newer;
            }

            state.revision +%= 1;
            return .changed;
        },
        .remove_entry => {
            if (prompt.target() != .history) {
                return .unchanged;
            }

            state.revision +%= 1;
            return .{ .removed = prompt.selection() };
        },
        .insert,
        .backspace,
        .delete,
        .move_left,
        .move_right,
        .home,
        .end,
        .select_range,
        .select_all,
        => return state.editField(command),
    }
}

/// Closes only the prompt that produced an accepted submission.
///
/// ```zig
/// std.debug.assert(prompt.finish(submission.target));
/// ```
pub fn finish(state: *State, target: name_prompt.Target) bool {
    const prompt = state.currentConst() orelse return false;
    if (!std.meta.eql(prompt.target(), target)) {
        return false;
    }

    state.value = null;
    state.revision +%= 1;
    return true;
}

/// Marks the typed directory as missing so the next submit creates it.
///
/// ```zig
/// state.requestDirectoryConfirmation();
/// ```
pub fn requestDirectoryConfirmation(state: *State) void {
    const prompt = state.mutable() orelse return;
    if (prompt.mode != .create_workspace or prompt.mode.create_workspace.confirm_create) {
        return;
    }

    prompt.mode.create_workspace.confirm_create = true;
    state.revision +%= 1;
}

/// Replaces the directory text with an accepted completion and keeps the
/// directory field focused with a fresh selection.
///
/// ```zig
/// state.replaceDirectory("/work/telar/");
/// ```
pub fn replaceDirectory(state: *State, text: []const u8) void {
    const prompt = state.mutable() orelse return;
    if (prompt.mode != .create_workspace) {
        return;
    }

    prompt.directory.setText(text);
    prompt.mode.create_workspace = .{ .focus = .directory };
    state.revision +%= 1;
}

fn directoryFocused(prompt: *const Prompt) bool {
    return prompt.mode == .create_workspace and prompt.mode.create_workspace.focus == .directory;
}

fn editField(state: *State, command: name_prompt.Command) name_prompt.Transition {
    const prompt = state.mutable() orelse return .unchanged;
    if (directoryFocused(prompt)) {
        return state.editDirectory(command);
    }

    const before: FieldPosition = .capture(&prompt.field);
    applyEdit(&prompt.field, prompt.pasting, command);
    if (!before.changed(&prompt.field)) {
        return .unchanged;
    }

    if (name_prompt.selects(prompt.target()) and before.len != prompt.field.len) {
        prompt.setSelection(0);
    }
    state.revision +%= 1;
    return .changed;
}

fn editDirectory(state: *State, command: name_prompt.Command) name_prompt.Transition {
    const prompt = state.mutable() orelse return .unchanged;
    const before: FieldPosition = .capture(&prompt.directory);
    applyEdit(&prompt.directory, prompt.pasting, command);
    if (!before.changed(&prompt.directory)) {
        return .unchanged;
    }

    if (before.len != prompt.directory.len) {
        prompt.mode.create_workspace = .{ .focus = .directory };
    }
    state.revision +%= 1;
    return .changed;
}

fn applyEdit(field: anytype, pasting: bool, command: name_prompt.Command) void {
    switch (command) {
        .insert => |bytes| if (pasting) insertPasted(field, bytes) else field.insert(bytes),
        .backspace => field.backspace(),
        .delete => field.delete(),
        .move_left => |extend| field.moveLeft(extend),
        .move_right => |extend| field.moveRight(extend),
        .home => |extend| field.home(extend),
        .end => |extend| field.end(extend),
        .select_range => |range| _ = field.selectRange(range),
        .select_all => field.selectAll(),
        .focus_field, .replace_range, .paste_start, .paste_end, .submit, .submit_alternate, .cancel, .move_up, .move_down, .tab, .back_tab, .remove_entry, .toggle_inspection, .page_up, .page_down => unreachable,
    }
}

/// Pasted line breaks are text, not submissions: each CR, LF or CRLF becomes
/// one space. Typed input never reaches this path.
fn insertPasted(field: anytype, bytes: []const u8) void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte != '\r' and byte != '\n') {
            continue;
        }

        field.insert(bytes[start..index]);
        field.insert(" ");
        if (byte == '\r' and index + 1 < bytes.len and bytes[index + 1] == '\n') {
            index += 1;
        }

        start = index + 1;
    }

    field.insert(bytes[start..]);
}

test "pasted line breaks become spaces while typed text is inserted verbatim" {
    var state: State = .{};
    state.begin(.create_workspace);

    try std.testing.expectEqual(name_prompt.Transition.routing_changed, state.apply(.paste_start));
    try std.testing.expectEqual(name_prompt.Transition.changed, state.apply(.{ .insert = "one\r\ntwo\nthree\r" }));
    try std.testing.expectEqual(name_prompt.Transition.routing_changed, state.apply(.paste_end));
    try std.testing.expectEqualStrings("one two three ", state.currentConst().?.field.text());
}
