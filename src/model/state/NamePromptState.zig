const core = @import("telar-core");
const Prompt = @import("Prompt.zig");
const name_prompt = @import("name_prompt.zig");
const std = @import("std");
const History = @import("History.zig");
const FieldPosition = @import("FieldPosition.zig");
const Submission = @import("Submission.zig");
const State = @This();

value: ?Prompt = null,
revision: u64 = 0,
generation: u64 = 0,

/// Reconciles search scope, selection and scroll after a history transition.
/// Example: `state.updateHistory(.{ .selection = 0, .reset_scroll = true });`.
pub fn updateHistory(self: *State, update: struct { scope: ?name_prompt.HistoryScope = null, author: ?core.HistoryAuthorFilter = null, selection: ?u16 = null, reset_scroll: bool = false, scroll_by: i16 = 0, scroll_limit: ?u32 = null }) void {
    const prompt = self.mutable() orelse return;
    if (prompt.mode != .history) {
        return;
    }

    const history = &prompt.mode.history;
    const before = history.*;
    if (update.scope) |scope| {
        history.scope = scope;
    }

    if (update.author) |author| {
        history.author = author;
    }

    if (update.selection) |selected| {
        history.selection = selected;
    }

    if (update.reset_scroll) {
        history.detail_scroll = 0;
    }

    if (history.inspecting) {
        history.detail_scroll = if (update.scroll_by < 0) history.detail_scroll -| @as(u32, @abs(update.scroll_by)) else history.detail_scroll +| @as(u32, @intCast(update.scroll_by));
    }

    if (update.scroll_limit) |limit| {
        history.detail_scroll = @min(history.detail_scroll, limit);
    }

    if (!std.meta.eql(before, history.*)) {
        self.revision +%= 1;
    }
}

/// Clamps the selected result and commits a revision only when it changes.
/// Example: `state.constrainSelection(result_count);`.
pub fn constrainSelection(self: *State, count: u16) void {
    const prompt = self.mutable() orelse return;
    const selected = @min(prompt.selection(), count -| 1);
    if (selected != prompt.selection()) {
        prompt.setSelection(selected);
        self.revision +%= 1;
    }
}

pub fn takeHistoryPage(self: *State) @FieldType(History, "page_requested") {
    const prompt = self.mutable() orelse return .none;
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
pub fn begin(self: *State, command: name_prompt.Begin) void {
    self.generation += 1;
    self.value = switch (command) {
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
            .field = .init(if (rename.name.len <= core.max_tab_label_bytes) rename.name else ""),
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
        .path_picker => .{
            .mode = .{ .paths = .{} },
            .field = .init(""),
        },
        .palette => |prefix| .{
            .mode = .{ .palette = .{} },
            .field = .init(&[_]u8{prefix.byte()}),
        },
        .rename_machine => |rename| .{
            .mode = .{ .machine = .{ .rename = rename.slot } },
            .field = .init(rename.label),
        },
        .add_machine => .{
            .mode = .{ .machine = .add_label },
            .field = .init(""),
        },
    };
    self.value.?.generation = self.generation;
    self.revision +%= 1;
}

/// Moves a list selection to one exact row, as a pointer press does; the
/// controller clamps it against the current result set afterwards.
///
/// ```zig
/// state.select(row);
/// ```
pub fn select(self: *State, index: u16) void {
    const prompt = self.mutable() orelse return;
    if (!(name_prompt.selects(prompt.target()) or directoryFocused(prompt)) or prompt.selection() == index) {
        return;
    }

    prompt.setSelection(index);
    self.revision +%= 1;
}

/// Returns whether input belongs to the prompt.
///
/// ```zig
/// if (prompt.active()) routeToPrompt();
/// ```
pub fn active(self: *const State) bool {
    return self.value != null;
}

fn mutable(self: *State) ?*Prompt {
    return if (self.value) |*value| value else null;
}

/// Returns the current prompt without permitting mutation.
///
/// ```zig
/// const current = prompt.currentConst() orelse return;
/// ```
pub fn currentConst(self: *const State) ?*const Prompt {
    return if (self.value) |*value| value else null;
}

/// Returns the revision observed by the client presenter.
///
/// ```zig
/// const revision = prompt.version();
/// ```
pub fn version(self: *const State) u64 {
    return self.revision;
}

/// Applies one semantic editor command. Visible changes advance the
/// revision; paste routing changes do not request a frame.
///
/// ```zig
/// const transition = prompt.apply(.backspace);
/// ```
pub fn apply(self: *State, command: name_prompt.Command) PromptTransition {
    const prompt = self.mutable() orelse return .unchanged;
    switch (command) {
        .focus_field => |focus| {
            if (prompt.mode != .create_workspace or prompt.mode.create_workspace.focus == focus) {
                return .unchanged;
            }

            prompt.mode.create_workspace.focus = focus;
            self.revision +%= 1;
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

            self.revision +%= 1;
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
                return self.editField(.{ .insert = " " });
            }
            if (prompt.mode == .machine and prompt.mode.machine == .add_label) {
                return self.askDestination(prompt);
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
                self.revision +%= 1;
                return .changed;
            }

            self.value = null;
            self.revision +%= 1;
            return .cancelled;
        },
        .move_up => {
            if (prompt.target() == .history) {
                prompt.setSelection(prompt.selection() +| 1);
                prompt.mode.history.detail_scroll = 0;
                self.revision +%= 1;
                return .changed;
            }

            if (!(name_prompt.selects(prompt.target()) or directoryFocused(prompt)) or prompt.selection() == 0) {
                return .unchanged;
            }

            prompt.setSelection(prompt.selection() - 1);
            self.revision +%= 1;
            return .changed;
        },
        .move_down => {
            if (prompt.target() == .history) {
                if (prompt.selection() == 0) {
                    prompt.mode.history.page_requested = .newer;
                }

                prompt.setSelection(prompt.selection() -| 1);
                prompt.mode.history.detail_scroll = 0;
                self.revision +%= 1;
                return .changed;
            }

            if (!(name_prompt.selects(prompt.target()) or directoryFocused(prompt))) {
                return .unchanged;
            }

            prompt.setSelection(prompt.selection() +| 1);
            self.revision +%= 1;
            return .changed;
        },
        .tab => {
            if (prompt.mode == .create_workspace) {
                const form_state = &prompt.mode.create_workspace;
                if (form_state.focus == .directory) {
                    return .completion_requested;
                }

                form_state.focus = .directory;
                self.revision +%= 1;
                return .changed;
            }
            if (prompt.target() == .paths) {
                return if (prompt.pasting) .unchanged else .{ .descend_requested = prompt.selection() };
            }

            if (prompt.target() != .history) {
                return .unchanged;
            }

            prompt.mode.history.scope = prompt.mode.history.scope.next();
            prompt.setSelection(0);
            self.revision +%= 1;
            return .changed;
        },
        .back_tab => {
            if (prompt.target() == .paths) {
                return if (prompt.pasting) .unchanged else .ascend_requested;
            }

            if (prompt.target() == .history) {
                prompt.mode.history.author = nextAuthor(prompt.mode.history.author);
                prompt.setSelection(0);
                self.revision +%= 1;
                return .changed;
            }
            if (prompt.mode != .create_workspace) {
                return .unchanged;
            }

            const form_state = &prompt.mode.create_workspace;
            form_state.focus = if (form_state.focus == .name) .directory else .name;
            self.revision +%= 1;
            return .changed;
        },
        .select_scope => |scope| {
            if (prompt.target() != .history or prompt.mode.history.scope == scope) {
                return .unchanged;
            }

            prompt.mode.history.scope = scope;
            prompt.setSelection(0);
            self.revision +%= 1;
            return .changed;
        },
        .select_author => |author| {
            if (prompt.target() != .history or prompt.mode.history.author == author) {
                return .unchanged;
            }

            prompt.mode.history.author = author;
            prompt.setSelection(0);
            self.revision +%= 1;
            return .changed;
        },
        .toggle_failed => {
            if (prompt.target() != .history) {
                return .unchanged;
            }

            prompt.mode.history.failed_only = !prompt.mode.history.failed_only;
            prompt.setSelection(0);
            self.revision +%= 1;
            return .changed;
        },
        .copy_entry => {
            if (prompt.target() != .history) {
                return .unchanged;
            }

            return .{ .copied = prompt.selection() };
        },
        .visit_pane => {
            // Alt+Enter inserts the selected path absolute.
            if (prompt.target() == .paths) {
                return self.apply(.submit_alternate);
            }

            if (prompt.target() != .history or prompt.pasting) {
                return .unchanged;
            }

            return .{ .pane_requested = prompt.selection() };
        },
        .toggle_inspection => {
            if (prompt.target() != .history or prompt.pasting) {
                return .unchanged;
            }

            prompt.mode.history.inspecting = !prompt.mode.history.inspecting;
            prompt.mode.history.detail_scroll = 0;
            self.revision +%= 1;
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

            self.revision +%= 1;
            return .changed;
        },
        .remove_entry => {
            if (prompt.target() != .history and prompt.paletteMode() != .machines) {
                return .unchanged;
            }

            self.revision +%= 1;
            return .{ .removed = prompt.selection() };
        },
        .rename_entry => {
            if (prompt.paletteMode() != .machines or prompt.pasting) {
                return .unchanged;
            }

            return .{ .rename_requested = prompt.selection() };
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
        => return self.editField(command),
    }
}

/// Closes only the prompt that produced an accepted submission.
///
/// ```zig
/// std.debug.assert(prompt.finish(submission.target));
/// ```
pub fn finish(self: *State, target: name_prompt.Target) bool {
    const prompt = self.currentConst() orelse return false;
    if (!std.meta.eql(prompt.target(), target)) {
        return false;
    }

    self.value = null;
    self.revision +%= 1;
    return true;
}

/// Marks the typed directory as missing so the next submit creates it.
///
/// ```zig
/// state.requestDirectoryConfirmation();
/// ```
pub fn requestDirectoryConfirmation(self: *State) void {
    const prompt = self.mutable() orelse return;
    if (prompt.mode != .create_workspace or prompt.mode.create_workspace.confirm_create) {
        return;
    }

    prompt.mode.create_workspace.confirm_create = true;
    self.revision +%= 1;
}

/// Replaces the directory text with an accepted completion and keeps the
/// directory field focused with a fresh selection.
///
/// ```zig
/// state.replaceDirectory("/work/telar/");
/// ```
pub fn replaceDirectory(self: *State, text: []const u8) void {
    const prompt = self.mutable() orelse return;
    if (prompt.mode != .create_workspace) {
        return;
    }

    prompt.directory.setText(text);
    prompt.mode.create_workspace = .{ .focus = .directory };
    self.revision +%= 1;
}

/// Empties the path picker's query and selection after its root moved, so
/// the new directory lists from its first entry.
///
/// ```zig
/// state.clearPathQuery();
/// ```
pub fn clearPathQuery(self: *State) void {
    const prompt = self.mutable() orelse return;
    if (prompt.mode != .paths) {
        return;
    }

    prompt.field.setText("");
    prompt.setSelection(0);
    self.revision +%= 1;
}

// The first step of adding a machine keeps the label and asks for the
// destination in the same prompt.
fn askDestination(self: *State, prompt: *Prompt) PromptTransition {
    const text = prompt.field.text();
    if (text.len == 0) {
        return .unchanged;
    }

    prompt.mode = .{ .machine = .{ .add_destination = .init(text) } };
    prompt.field = .init("");
    self.revision +%= 1;
    return .changed;
}

fn directoryFocused(prompt: *const Prompt) bool {
    return prompt.mode == .create_workspace and prompt.mode.create_workspace.focus == .directory;
}

// Shift+Tab walks the author chips left to right: you, agents, both.
fn nextAuthor(author: core.HistoryAuthorFilter) core.HistoryAuthorFilter {
    return switch (author) {
        .human => .agent,
        .agent => .all,
        .all => .human,
    };
}

fn editField(self: *State, command: name_prompt.Command) PromptTransition {
    const prompt = self.mutable() orelse return .unchanged;
    if (directoryFocused(prompt)) {
        return self.editDirectory(command);
    }

    const before: FieldPosition = .capture(&prompt.field);
    applyEdit(&prompt.field, prompt.pasting, command);
    if (!before.changed(&prompt.field)) {
        return .unchanged;
    }

    if (name_prompt.selects(prompt.target()) and before.len != prompt.field.len) {
        prompt.setSelection(0);
    }
    self.revision +%= 1;
    return .changed;
}

fn editDirectory(self: *State, command: name_prompt.Command) PromptTransition {
    const prompt = self.mutable() orelse return .unchanged;
    const before: FieldPosition = .capture(&prompt.directory);
    applyEdit(&prompt.directory, prompt.pasting, command);
    if (!before.changed(&prompt.directory)) {
        return .unchanged;
    }

    if (before.len != prompt.directory.len) {
        prompt.mode.create_workspace = .{ .focus = .directory };
    }
    self.revision +%= 1;
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
        .focus_field, .replace_range, .paste_start, .paste_end, .submit, .submit_alternate, .cancel, .move_up, .move_down, .tab, .back_tab, .select_scope, .select_author, .toggle_failed, .remove_entry, .rename_entry, .copy_entry, .visit_pane, .toggle_inspection, .page_up, .page_down => unreachable,
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

    try std.testing.expectEqual(PromptTransition.routing_changed, state.apply(.paste_start));
    try std.testing.expectEqual(PromptTransition.changed, state.apply(.{ .insert = "one\r\ntwo\nthree\r" }));
    try std.testing.expectEqual(PromptTransition.routing_changed, state.apply(.paste_end));
    try std.testing.expectEqualStrings("one two three ", state.currentConst().?.field.text());
}

const PromptTransition = union(enum) {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    /// The history palette or the machine list asked to delete its
    /// selected entry.
    removed: u16,
    /// The machine list asked to rename its selected machine.
    rename_requested: u16,
    /// The history palette asked to copy its selected command.
    copied: u16,
    /// The history palette asked to leave for the pane its selected
    /// command ran in.
    pane_requested: u16,
    /// The directory field asked for its selected completion; the
    /// controller owns the list and answers with `replaceDirectory`.
    completion_requested,
    /// The path picker asked to browse the selected directory.
    descend_requested: u16,
    /// The path picker asked to browse the parent of its root.
    ascend_requested,
    submitted: Submission,
};
