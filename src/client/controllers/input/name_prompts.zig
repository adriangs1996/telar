//! Adapts semantic host input and client request ports to the name-prompt
//! use case.

const Client = @import("../../AttachedClient.zig");
const TabIdType = @import("telar-core").TabId;
const InputCopyModeDirection = @import("../../input/copy_mode.zig").Direction;
const ApplicationInputNamePromptOutcome = @import("../../application/input/name_prompt.zig").Outcome;
const history_palettes = @import("history_palettes.zig");
const ListSnapshot = @import("ListSnapshot.zig");
const suggestions = @import("suggestions.zig");
const ResultsType = @import("../../model/Results.zig");
const collect_module = @import("../../model/goto_picker.zig").collect;
const std = @import("std");
const SourcesType = @import("../../model/Sources.zig");
const ModelGotoPickerItem = @import("../../model/goto_picker.zig").Item;
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const tab_selections = @import("../tabs/tab_selections.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const NamePromptHandlerType = @import("../../application/input/NamePromptHandler.zig");
const OpenNamePromptHandlerType = @import("../../application/input/OpenNamePromptHandler.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const SubmissionType = @import("../../model/Submission.zig");
const workspace_creations = @import("../workspaces/workspace_creations.zig");
const workspace_renames = @import("../workspaces/workspace_renames.zig");
const tab_renames = @import("../tabs/tab_renames.zig");
const OwnedSearchType = @import("../../connection/OwnedSearch.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const KeyType = @import("../../input/Key.zig");
const CharType = @import("../../input/Char.zig");
const ModelNamePromptCommand = @import("../../model/name_prompt.zig").Command;
const NamePromptState = @import("../../model/NamePromptState.zig");
const EffectsCapture = @import("EffectsCapture.zig");

/// Starts workspace creation only when the current client can plan the
/// request.
///
/// ```zig
/// if (beginWorkspaceCreate(client)) return;
/// ```
pub fn beginWorkspaceCreate(client: *Client) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.create_workspace);
}

/// Starts renaming the attached workspace from its canonical name.
///
/// ```zig
/// _ = beginWorkspaceRename(client);
/// ```
pub fn beginWorkspaceRename(client: *Client) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.rename_workspace);
}

/// Starts renaming the active tab when one exists.
///
/// ```zig
/// _ = beginActiveTabRename(client);
/// ```
pub fn beginActiveTabRename(client: *Client) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.rename_active_tab);
}

/// Starts renaming one exact tab from its canonical label.
///
/// ```zig
/// _ = beginTabRename(client, tab_id);
/// ```
pub fn beginTabRename(client: *Client, tab_id: TabIdType) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.{ .rename_tab = tab_id });
}

/// Opens the copy-mode search input. Only valid while copy mode is active.
///
/// ```zig
/// _ = beginCopySearch(client, .forward);
/// ```
pub fn beginCopySearch(client: *Client, direction: InputCopyModeDirection) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.{ .copy_search = direction });
}

/// Opens the fuzzy goto picker over workspaces, tabs and agents.
///
/// ```zig
/// _ = beginGotoPicker(client);
/// ```
pub fn beginGotoPicker(client: *Client) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.goto_picker);
}

/// Opens the history palette prompt; `history_palettes.begin` also clears
/// the result model and sends the first query.
///
/// ```zig
/// _ = beginHistoryPalette(client);
/// ```
pub fn beginHistoryPalette(client: *Client) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.history_palette);
}

/// Opens the command-suggestion palette prompt; `suggestions.begin` also
/// clears the suggestion model.
///
/// ```zig
/// _ = beginSuggestPalette(client);
/// ```
pub fn beginSuggestPalette(client: *Client) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.suggest_palette);
}

/// One semantic host event the prompt can interpret. Pasted text arrives as
/// bounded slices between the paste markers; the adapter decodes bytes.
pub const Input = union(enum) {
    key: KeyType,
    paste_start,
    paste_end,
    paste_text: []const u8,
};

/// Applies one semantic event as a bounded prompt command. Accepted
/// submissions close through the application handler; blocked or failed
/// effects leave the prompt intact.
///
/// ```zig
/// _ = try handleInput(client, .{ .key = key });
/// ```
pub fn handleInput(client: *Client, input: Input) !ApplicationInputNamePromptOutcome {
    var use_case = handler(client);

    const before = listSnapshot(client);
    const outcome = try dispatchInput(&use_case, input);
    try refreshHistoryQuery(client, before);
    try history_palettes.navigatePage(client);
    clampPickerSelection(client);
    try history_palettes.refreshInspection(client);
    discardEditedSuggestion(client, before);
    if (outcome == .finished) {
        var submission = before;
        submission.alternate = client.list_submission_alternate;
        client.list_submission_alternate = false;
        try finishListSubmission(client, submission);
    }
    if (outcome == .removed and before.kind == .history) {
        try history_palettes.deleteSelected(client, before.selection);
    }
    return outcome;
}

fn listSnapshot(client: *Client) ListSnapshot {
    const prompt = client.model.name_prompt.currentConst() orelse return .{};
    var snapshot: ListSnapshot = switch (prompt.target()) {
        .goto => .{ .kind = .goto },
        .history => .{ .kind = .history },
        .suggest => .{ .kind = .suggest },
        else => return .{},
    };

    snapshot.selection = prompt.selection();
    snapshot.scope = prompt.scope();
    const text = prompt.field.text();
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
        .history => try history_palettes.pasteSelection(client, .{
            .selection = before.selection,
            .run = client.history_enter_runs != before.alternate,
        }),
        .suggest => try suggestions.pasteSuggestion(client),
        .goto => {
            var results: ResultsType = .{};
            collect_module(pickerSources(client), before.textSlice(), &results);
            if (results.len == 0) {
                return;
            }

            const index = @min(before.selection, @as(u16, results.len) - 1);
            try navigatePickerItem(client, results.slice()[index].item);
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

    try history_palettes.sendQuery(client, text);
}

/// Drops a landed or pending suggestion once its request text changed, so
/// the next Enter asks again instead of pasting a stale answer.
fn discardEditedSuggestion(client: *Client, before: ListSnapshot) void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    if (prompt.target() != .suggest or before.kind != .suggest) {
        return;
    }

    if (std.mem.eql(u8, before.textSlice(), prompt.field.text())) {
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
        .goto => blk: {
            var results: ResultsType = .{};
            collect_module(pickerSources(client), prompt.field.text(), &results);
            break :blk results.len;
        },
        .history => client.model.history_palette.len,
        .suggest => 1,
        else => return,
    };
    client.model.name_prompt.constrainSelection(count);
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
        .workspace => |workspace| _ = try workspace_handoffs.selectWorkspace(client, .{ .workspace = workspace }),
        .tab => |tab_id| {
            var use_case = tab_selections.selectionHandler(client);
            _ = try use_case.execute(.{ .target = .{ .tab_id = tab_id } });
        },
        .agent => |key| _ = try agent_navigation.apply(client, key),
    }
}

fn handler(client: *Client) NamePromptHandlerType {
    return .{
        .prompt = &client.model.name_prompt,
        .effects = .{
            .context = client,
            .submit = submit,
        },
    };
}

fn openingHandler(client: *Client) OpenNamePromptHandlerType {
    return .{
        .model = &client.model,
        .workspace_creation = .{
            .context = client,
            .pending = workspaceCreationPending,
        },
    };
}

fn workspaceCreationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.busy(client);
}

fn submit(context: *anyopaque, submission: SubmissionType) !bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return switch (submission.target) {
        .create_workspace => blk: {
            var use_case = workspace_creations.requestHandler(client);
            break :blk try use_case.execute(.{ .name = submission.name });
        },
        .rename_workspace => |workspace| blk: {
            var use_case = workspace_renames.requestHandler(client);
            break :blk try use_case.execute(.{
                .workspace = workspace,
                .name = submission.name,
            });
        },
        .rename_tab => |tab_id| blk: {
            var use_case = tab_renames.requestHandler(client);
            break :blk try use_case.execute(.{
                .tab_id = tab_id,
                .label = submission.name,
            });
        },
        // List targets only close here; the picked entry is applied by
        // `finishListSubmission` once the prompt no longer owns input.
        .history => blk: {
            const prompt = client.model.name_prompt.currentConst() orelse break :blk false;
            if (!history_palettes.canSubmit(client, prompt.selection())) {
                break :blk false;
            }

            client.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .goto => blk: {
            client.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        // Enter asks while no suggestion is ready and the prompt stays
        // open; once a suggestion landed, Enter closes and pastes it.
        .suggest => blk: {
            if (client.model.suggestion.phase == .ready) {
                break :blk true;
            }

            if (submission.name.len == 0 or client.model.suggestion.phase == .waiting) {
                break :blk false;
            }

            try suggestions.request(client, submission.name);
            break :blk false;
        },
        .copy_search => blk: {
            const pane_id = client.model.copyModeTarget() orelse break :blk true;
            const request_id = try request_lifecycle.nextId(client);
            var owned: OwnedSearchType = .{
                .request_id = request_id,
                .pane_id = pane_id,
                .needle_len = @intCast(submission.name.len),
            };
            @memcpy(owned.needle[0..submission.name.len], submission.name);
            try runtime_transport.enqueue(client, .{ .search_pane = owned });
            break :blk true;
        },
    };
}

fn dispatchInput(use_case: *NamePromptHandlerType, input: Input) !ApplicationInputNamePromptOutcome {
    const command = commandFor(input) orelse return .unchanged;

    return use_case.execute(command);
}

/// Maps one semantic host event to a prompt command; events the prompt does
/// not interpret produce no command.
fn commandFor(input: Input) ?ModelNamePromptCommand {
    return switch (input) {
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
            .tab => .cycle_scope,
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
            else => null,
        },
    };
}

test "input adapter ignores keys the prompt does not interpret" {
    var prompt: NamePromptState = .{};
    prompt.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(3), .label = "logs" } });
    var capture: EffectsCapture = .{};
    var use_case: NamePromptHandlerType = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };

    try std.testing.expect(try dispatchInput(&use_case, .{ .key = .{ .code = .back_tab } }) == .unchanged);
    try std.testing.expectEqualStrings("logs", prompt.currentConst().?.field.text());
    try std.testing.expect(try dispatchInput(&use_case, .{ .key = .{ .code = .{ .char = CharType.init("!") } } }) == .changed);
    try std.testing.expect(try dispatchInput(&use_case, .{ .key = .{ .code = .enter } }) == .finished);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "input adapter preserves pasted newlines as bounded text" {
    var prompt: NamePromptState = .{};
    prompt.begin(.create_workspace);
    var capture: EffectsCapture = .{};
    var use_case: NamePromptHandlerType = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };

    try std.testing.expect(try dispatchInput(&use_case, .paste_start) == .routing_changed);
    try std.testing.expect(try dispatchInput(&use_case, .{ .paste_text = "one\rtwo" }) == .changed);
    try std.testing.expect(try dispatchInput(&use_case, .paste_end) == .routing_changed);
    try std.testing.expectEqualStrings("one two", prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "blocked submission remains active and escape cancels it" {
    var prompt: NamePromptState = .{};
    prompt.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(3), .label = "logs" } });
    var capture: EffectsCapture = .{ .accept = false };
    var use_case: NamePromptHandlerType = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };

    try std.testing.expect(try dispatchInput(&use_case, .{ .key = .{ .code = .{ .char = CharType.init("!") } } }) == .changed);
    try std.testing.expect(try dispatchInput(&use_case, .{ .key = .{ .code = .enter } }) == .blocked);
    try std.testing.expectEqualStrings("logs!", prompt.currentConst().?.field.text());
    try std.testing.expect(try dispatchInput(&use_case, .{ .key = .{ .code = .escape } }) == .cancelled);
    try std.testing.expect(!prompt.active());
}
