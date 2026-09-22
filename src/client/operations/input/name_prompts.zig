//! Adapts semantic host input and client request ports to the name-prompt
//! use case.

const name_prompt_opening = @import("../../application/input/name_prompt_opening.zig");
const name_prompt = @import("../../model/name_prompt.zig");
const history_browser = @import("../../application/input/history_browser.zig");
const Client = @import("../../AttachedClient.zig");
const TabIdType = @import("telar-core").TabId;
const InputCopyModeDirection = @import("../../input/copy_mode.zig").Direction;
const ApplicationInputNamePromptOutcome = @import("../../application/input/name_prompt.zig").Outcome;
const ListSnapshot = @import("ListSnapshot.zig");
const ResultsType = @import("../../model/Results.zig");
const collect_module = @import("../../model/goto_picker.zig").collect;
const std = @import("std");
const SourcesType = @import("../../model/Sources.zig");
const ModelGotoPickerItem = @import("../../model/goto_picker.zig").Item;
const tab_selections = @import("../tabs/tab_selections.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const SubmissionType = @import("../../model/Submission.zig");
const workspace_renames = @import("../workspaces/workspace_renames.zig");
const OwnedSearchType = @import("../../connection/OwnedSearch.zig");
const KeyType = @import("../../input/Key.zig");
const ModelNamePromptCommand = @import("../../model/name_prompt.zig").Command;
const NamePromptState = @import("../../model/NamePromptState.zig");
const path_completions = @import("path_completions.zig");
const path_expansion = @import("../../completion/path_expansion.zig");
const command_palette = @import("../../model/command_palette.zig");
const CommandResultsType = @import("../../model/CommandResults.zig");

/// Starts workspace creation only when the current client can plan the
/// request.
///
/// ```zig
/// if (beginWorkspaceCreate(client)) return;
/// ```
pub fn beginWorkspaceCreate(client: *Client) bool {
    if (!open(client, .create_workspace)) {
        return false;
    }

    path_completions.open(client) catch {};
    return true;
}

/// Starts renaming the attached workspace from its canonical name.
///
/// ```zig
/// _ = beginWorkspaceRename(client);
/// ```
pub fn beginWorkspaceRename(client: *Client) bool {
    return open(client, .rename_workspace);
}

/// Starts renaming the active tab when one exists.
///
/// ```zig
/// _ = beginActiveTabRename(client);
/// ```
pub fn beginActiveTabRename(client: *Client) bool {
    return open(client, .rename_active_tab);
}

/// Starts renaming one exact tab from its canonical label.
///
/// ```zig
/// _ = beginTabRename(client, tab_id);
/// ```
pub fn beginTabRename(client: *Client, tab_id: TabIdType) bool {
    return open(client, .{ .rename_tab = tab_id });
}

/// Opens the copy-mode search input. Only valid while copy mode is active.
///
/// ```zig
/// _ = beginCopySearch(client, .forward);
/// ```
pub fn beginCopySearch(client: *Client, direction: InputCopyModeDirection) bool {
    return open(client, .{ .copy_search = direction });
}

/// Opens the fuzzy goto picker over workspaces, tabs and agents.
///
/// ```zig
/// _ = beginGotoPicker(client);
/// ```
pub fn beginGotoPicker(client: *Client) bool {
    return open(client, .goto_picker);
}

/// Opens the history palette prompt; `history_palettes.begin` also clears
/// the result model and sends the first query.
///
/// ```zig
/// _ = beginHistoryPalette(client);
/// ```
pub fn beginHistoryPalette(client: *Client) bool {
    return open(client, .history_palette);
}

/// Opens the command-suggestion palette prompt; `suggestions.begin` also
/// clears the suggestion model.
///
/// ```zig
/// _ = beginSuggestPalette(client);
/// ```
pub fn beginSuggestPalette(client: *Client) bool {
    return open(client, .suggest_palette);
}

/// Opens the command palette with `prefix` already typed. A `?` palette
/// starts with a cleared suggestion, like `suggestions.begin`.
///
/// ```zig
/// _ = beginPalette(client, .goto);
/// ```
pub fn beginPalette(client: *Client, prefix: command_palette.Prefix) bool {
    if (!open(client, .{ .palette = prefix })) {
        return false;
    }

    if (prefix == .suggest) {
        client.model.suggestion.begin();
    }

    return true;
}

/// Chooses one visible list row with the pointer and submits it, exactly as
/// moving the selection there and pressing Enter would.
///
/// ```zig
/// try chooseRow(client, index);
/// ```
pub fn chooseRow(client: *Client, index: u16) !void {
    client.model.name_prompt.select(index);
    clampPickerSelection(client);
    _ = try handleInput(client, .{ .key = .{ .code = .enter } });
}

/// Selects a command from a delivered history page without pasting or running
/// it. Example: `try selectHistoryRow(client, index, page_revision);`.
pub fn selectHistoryRow(client: *Client, index: u16, revision: u64) !void {
    if (!history_browser.select(&client.model, index, revision)) {
        return;
    }

    try client.refreshHistoryInspection();
}

/// Scrolls output by logical lines and reapplies the adapter's exact bound.
/// Example: `try scrollHistoryInspection(client, 1);`.
pub fn scrollHistoryInspection(client: *Client, lines: i16) !void {
    history_browser.scrollInspection(&client.model, lines);
    try client.refreshHistoryInspection();
}

/// Accepts a directory row only while its landed listing is still current.
/// Clicking a folder completes the path without submitting the context form.
/// Example: `try chooseDirectory(client, index, listing_revision);`
pub fn chooseDirectory(client: *Client, index: u16, revision: u64) !void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    const completion = &client.model.path_completion;
    if (prompt.form() == null or completion.version() != revision or completion.pending != .none or index >= completion.entries().len) {
        return;
    }

    _ = try handleInput(client, .{ .command = .{ .focus_field = .directory } });
    client.model.name_prompt.select(index);
    _ = try handleInput(client, .{ .command = .tab });
}

/// One semantic host event the prompt can interpret. Pasted text arrives as
/// bounded slices between the paste markers; the adapter decodes bytes.
pub const Input = union(enum) {
    command: ModelNamePromptCommand,
    key: KeyType,
    paste_start,
    paste_end,
    paste_text: []const u8,
};

/// Applies one semantic event as a bounded prompt command. Accepted
/// submissions close the prompt after delivery; blocked or failed
/// effects leave the prompt intact.
///
/// ```zig
/// _ = try handleInput(client, .{ .key = key });
/// ```
pub fn handleInput(client: *Client, input: Input) !ApplicationInputNamePromptOutcome {
    const before = listSnapshot(client);
    const directory_before = directoryVersion(client);
    const outcome = try dispatchInput(client, input);
    try refreshHistoryQuery(client, before);
    try client.navigateHistoryPage();
    if (outcome == .completion_requested) {
        try path_completions.acceptSelected(client);
    } else if (outcome == .cancelled or outcome == .finished) {
        path_completions.close(client);
    } else if (directory_before != null and !std.meta.eql(directory_before, directoryVersion(client))) {
        try path_completions.refresh(client);
    }
    clampPickerSelection(client);
    try client.refreshHistoryInspection();
    discardEditedSuggestion(client, before);
    if (outcome == .finished) {
        var submission = before;
        submission.alternate = client.list_submission_alternate;
        client.list_submission_alternate = false;
        try finishListSubmission(client, submission);
    }
    if (outcome == .removed and before.kind == .history) {
        try client.deleteHistorySelection(before.selection);
    }
    return outcome;
}

/// Length and head of the directory field, enough to notice a text change
/// without copying up to `max_cwd_bytes` per keystroke.
fn directoryVersion(client: *const Client) ?[2]usize {
    const prompt = client.model.name_prompt.currentConst() orelse return null;
    if (prompt.form() == null) {
        return null;
    }

    return .{ prompt.directory.len, std.hash.Crc32.hash(prompt.directory.text()) };
}

fn listSnapshot(client: *Client) ListSnapshot {
    const prompt = client.model.name_prompt.currentConst() orelse return .{};
    var snapshot: ListSnapshot = switch (prompt.target()) {
        .goto => .{ .kind = .goto },
        .history => .{ .kind = .history },
        .suggest => .{ .kind = .suggest },
        .palette => switch (prompt.paletteMode()) {
            .goto => .{ .kind = .goto },
            .suggest => .{ .kind = .suggest },
            .actions => .{ .kind = .actions },
        },
        else => return .{},
    };

    snapshot.selection = prompt.selection();
    snapshot.scope = prompt.scope();
    const text = prompt.paletteQuery();
    snapshot.len = @intCast(text.len);
    @memcpy(snapshot.text[0..text.len], text);
    return snapshot;
}

/// Applies the accepted list submission after the prompt closed. Pastes and
/// navigation are gated on prompt authority (`planPaneInput`, handoffs), so
/// they must not run inside the submit effect while the prompt is active.
fn finishListSubmission(client: *Client, before: ListSnapshot) !void {
    switch (before.kind) {
        .none => {},
        .history => try client.pasteHistorySelection(.{
            .selection = before.selection,
            .run = client.history_enter_runs != before.alternate,
        }),
        .suggest => try client.pasteSuggestion(),
        .goto => {
            var results: ResultsType = .{};
            collect_module(pickerSources(client), before.textSlice(), &results);
            if (results.len == 0) {
                return;
            }

            const index = @min(before.selection, @as(u16, results.len) - 1);
            try navigatePickerItem(client, results.slice()[index].item);
        },
        .actions => {
            var results: CommandResultsType = .{};
            command_palette.collect(before.textSlice(), &results);
            if (results.len == 0) {
                return;
            }

            const index = @min(before.selection, @as(u16, results.len) - 1);
            _ = try client.executeAction(command_palette.entries[results.slice()[index].index].action, .effect);
        },
    }
}

/// Requeries the runtime only when the palette's query text actually
/// changed, so selection moves and pastes stay local.
fn refreshHistoryQuery(client: *Client, before: ListSnapshot) !void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    if (prompt.target() != .history) {
        return;
    }

    const text = prompt.field.text();
    if (before.kind == .history and before.scope == prompt.scope() and
        std.mem.eql(u8, before.textSlice(), text))
    {
        return;
    }

    try client.queryHistory(text);
}

/// Drops a landed or pending suggestion once its request text changed, so
/// the next Enter asks again instead of pasting a stale answer. Entering
/// the palette's `?` mode from another mode counts as a change.
fn discardEditedSuggestion(client: *Client, before: ListSnapshot) void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    if (listSnapshot(client).kind != .suggest) {
        return;
    }

    if (before.kind == .suggest and std.mem.eql(u8, before.textSlice(), prompt.paletteQuery())) {
        return;
    }

    client.model.suggestion.invalidate();
}

/// Keeps the picker selection inside the deterministic result set the
/// renderer and the submit path both derive from the current query.
fn clampPickerSelection(client: *Client) void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    if (prompt.selection() == 0) {
        return;
    }

    const count: u16 = switch (prompt.target()) {
        .goto => pickerCount(client, prompt.field.text()),
        .history => client.model.history_palette.len,
        .suggest => 1,
        .create_workspace => @intCast(client.model.path_completion.entries().len),
        .palette => switch (prompt.paletteMode()) {
            .goto => pickerCount(client, prompt.paletteQuery()),
            .suggest => 1,
            .actions => blk: {
                var results: CommandResultsType = .{};
                command_palette.collect(prompt.paletteQuery(), &results);
                break :blk results.len;
            },
        },
        else => return,
    };
    client.model.name_prompt.constrainSelection(count);
}

fn pickerCount(client: *Client, query: []const u8) u16 {
    var results: ResultsType = .{};
    collect_module(pickerSources(client), query, &results);
    return results.len;
}

fn pickerSources(client: *Client) SourcesType {
    return .{
        .agents = client.model.agentSnapshot(),
        .workspaces = client.model.workspaceListSnapshot(),
        .tabs = &client.model.workspace,
    };
}

fn navigatePickerItem(client: *Client, item: ModelGotoPickerItem) !void {
    switch (item) {
        .workspace => |workspace| _ = try client.selectWorkspace(
            .{
                .workspace = workspace,
            },
        ),
        .tab => |tab_id| {
            _ = try tab_selections.select(client, .{ .target = .{ .tab_id = tab_id } });
        },
        .agent => |key| _ = try agent_navigation.apply(client, key),
    }
}

fn submit(client: *Client, submission: SubmissionType) !bool {
    return switch (submission.target) {
        .create_workspace => submitWorkspaceCreation(client, submission),
        .rename_workspace => |workspace| blk: {
            break :blk try workspace_renames.request(client, .{
                .workspace = workspace,
                .name = submission.name,
            });
        },
        .rename_tab => |tab_id| blk: {
            break :blk try client.requestTabRename(.{
                .tab_id = tab_id,
                .label = submission.name,
            });
        },
        // List targets only close here; the picked entry is applied by
        // `finishListSubmission` once the prompt no longer owns input.
        .history => blk: {
            const prompt = client.model.name_prompt.currentConst() orelse break :blk false;
            if (!client.canSubmitHistory(prompt.selection())) {
                break :blk false;
            }

            client.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .goto => blk: {
            client.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .suggest => submitSuggestion(client, submission.name),
        // The palette closes like the list its prefix selects; `>` closes
        // only when a catalogue entry matches, so Enter on no match is inert.
        .palette => blk: {
            const prompt = client.model.name_prompt.currentConst() orelse break :blk false;
            switch (prompt.paletteMode()) {
                .goto => {
                    client.list_submission_alternate = submission.alternate;
                    break :blk true;
                },
                .suggest => break :blk try submitSuggestion(client, prompt.paletteQuery()),
                .actions => {
                    var results: CommandResultsType = .{};
                    command_palette.collect(prompt.paletteQuery(), &results);
                    break :blk results.len != 0;
                },
            }
        },
        .copy_search => blk: {
            const pane_id = client.model.copyModeTarget() orelse break :blk true;
            const request_id = try client.request_lifecycle.nextId();
            var owned: OwnedSearchType = .{
                .request_id = request_id,
                .pane_id = pane_id,
                .needle_len = @intCast(submission.name.len),
            };
            @memcpy(owned.needle[0..submission.name.len], submission.name);
            try client.sendRuntime(
                .{
                    .search_pane = owned,
                },
            );
            break :blk true;
        },
    };
}

/// Enter asks while no suggestion is ready and the prompt stays open; once
/// a suggestion landed, Enter closes and pastes it.
fn submitSuggestion(client: *Client, text: []const u8) !bool {
    if (client.model.suggestion.phase == .ready) {
        return true;
    }

    if (text.len == 0 or client.model.suggestion.phase == .waiting) {
        return false;
    }

    try client.requestSuggestion(text);
    return false;
}

/// Expands the typed directory, asks once before creating a missing one and
/// derives the context name from the directory when the name is empty.
fn submitWorkspaceCreation(client: *Client, submission: SubmissionType) !bool {
    var buffer: [path_completions.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = if (submission.directory.len == 0)
        ""
    else
        path_completions.expandDirectory(client, submission.directory, &buffer) catch return false;
    if (cwd.len != 0) {
        switch (path_completions.directoryStatus(client, cwd)) {
            .directory => {},
            .other => return false,
            .missing => if (!submission.create_directory) {
                client.model.name_prompt.requestDirectoryConfirmation();
                return false;
            },
        }
    }

    const name = if (submission.name.len != 0) submission.name else path_expansion.basename(cwd);
    if (name.len == 0) {
        return false;
    }

    return client.requestWorkspaceCreation(.{
        .name = name,
        .cwd = cwd,
        .create_cwd = submission.create_directory and cwd.len != 0,
    }) catch |err| switch (err) {
        error.InvalidWorkspaceName, error.InvalidUtf8 => false,
        else => err,
    };
}

fn dispatchInput(client: *Client, input: Input) !ApplicationInputNamePromptOutcome {
    const command = commandFor(input) orelse return .unchanged;
    return applyCommand(client, command);
}

/// Maps one semantic host event to a prompt command; events the prompt does
/// not interpret produce no command.
fn commandFor(input: Input) ?ModelNamePromptCommand {
    return switch (input) {
        .command => |command| command,
        .paste_start => .paste_start,
        .paste_end => .paste_end,
        .paste_text => |text| .{ .insert = text },
        .key => |key| switch (key.code) {
            .enter => if (key.mods.shift) .submit_alternate else .submit,
            .escape => .cancel,
            .backspace => .backspace,
            .delete => .delete,
            .left => .{ .move_left = key.mods.shift },
            .right => .{ .move_right = key.mods.shift },
            .up => .move_up,
            .down => .move_down,
            .page_up => .page_up,
            .page_down => .page_down,
            .tab => .tab,
            .back_tab => .back_tab,
            .home => .{ .home = key.mods.shift },
            .end => .{ .end = key.mods.shift },
            .char => |char| if (!key.mods.ctrl and !key.mods.alt)
                .{ .insert = char.slice() }
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'd')
                .remove_entry
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'o')
                .toggle_inspection
            else
                null,
        },
    };
}

fn open(client: *Client, intent: name_prompt_opening.Intent) bool {
    if (client.model.panePasteActive()) {
        return false;
    }
    if (intent == .copy_search) {
        if (!client.model.copyModeActive()) {
            return false;
        }

        client.model.name_prompt.begin(.{ .copy_search = intent.copy_search });
        return true;
    }
    if (client.model.copyModeActive()) {
        return false;
    }

    const command: name_prompt.Begin = switch (intent) {
        .create_workspace => create: {
            if (!client.request_lifecycle.tracker.isEmpty()) {
                return false;
            }
            if (client.model.planWorkspaceCreation() == null) {
                return false;
            }

            break :create .create_workspace;
        },
        .rename_workspace => rename: {
            const workspace = client.model.workspaceLocation() orelse return false;
            break :rename .{ .rename_workspace = .{
                .workspace = workspace,
                .name = client.model.workspace.workspaceName(),
            } };
        },
        .rename_active_tab => rename: {
            const active = client.model.workspace.activeConst() orelse return false;
            break :rename name_prompt_opening.renameTab(active.location.tab_id, active.labelSlice());
        },
        .rename_tab => |tab_id| rename: {
            const tab = client.model.workspace.find(tab_id) orelse return false;
            break :rename name_prompt_opening.renameTab(tab_id, tab.labelSlice());
        },
        .goto_picker => .goto_picker,
        .history_palette => .history_palette,
        .suggest_palette => .suggest_palette,
        .palette => |prefix| .{ .palette = prefix },
        .copy_search => unreachable,
    };

    client.model.name_prompt.begin(command);
    return true;
}

fn applyCommand(client: *Client, command: ModelNamePromptCommand) !ApplicationInputNamePromptOutcome {
    return switch (client.model.name_prompt.apply(command)) {
        .unchanged => .unchanged,
        .routing_changed => .routing_changed,
        .changed => .changed,
        .cancelled => .cancelled,
        .removed => .removed,
        .completion_requested => .completion_requested,
        .submitted => |submission| if (!try submit(
            client,
            submission,
        ))
            .blocked
        else blk: {
            std.debug.assert(client.model.name_prompt.finish(submission.target));
            break :blk .finished;
        },
    };
}
