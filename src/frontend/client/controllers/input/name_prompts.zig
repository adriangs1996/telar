//! Adapts host-terminal input and client request ports to the name-prompt use
//! case.

const std = @import("std");
const core = @import("telar-core");
const presentation = @import("../../../presentation/root.zig");
const input_application = @import("../../application/input/root.zig");
const prompt_state = @import("../../model/name_prompt.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const connection_outbox = @import("../../connection/outbox.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");
const input_capability = @import("../../../input/root.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const history_palettes = @import("history_palettes.zig");
const goto_picker = @import("../../model/goto_picker.zig");
const tab_renames = @import("../tabs/tab_renames.zig");
const tab_selections = @import("../tabs/tab_selections.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const workspace_creations = @import("../workspaces/workspace_creations.zig");
const workspace_renames = @import("../workspaces/workspace_renames.zig");

const Client = @import("../../client.zig");
const name_prompt = input_application.name_prompt;
const name_prompt_opening = input_application.name_prompt_opening;
const schema = core.schema;
const term = presentation.screen;

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
pub fn beginTabRename(client: *Client, tab_id: schema.TabId) bool {
    var use_case = openingHandler(client);

    return use_case.execute(.{ .rename_tab = tab_id });
}

/// Parses one host-input chunk into bounded prompt commands. Accepted
/// submissions close through the application handler; blocked or failed
/// effects leave the prompt intact.
///
/// ```zig
/// _ = try handleInput(client, bytes);
/// ```
/// Opens the copy-mode search input. Only valid while copy mode is active.
///
/// ```zig
/// _ = beginCopySearch(client, .forward);
/// ```
pub fn beginCopySearch(client: *Client, direction: input_capability.copy_mode.Direction) bool {
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

pub fn handleInput(client: *Client, bytes: []const u8) !name_prompt.Outcome {
    var use_case = handler(client);

    const before = listSnapshot(client);
    const outcome = try dispatchInput(&use_case, bytes);
    clampPickerSelection(client);
    try refreshHistoryQuery(client, before);
    if (outcome == .finished) {
        try finishListSubmission(client, before);
    }
    return outcome;
}

const ListSnapshot = struct {
    kind: enum { none, goto, history } = .none,
    selection: u16 = 0,
    text: [schema.max_tab_label_bytes]u8 = undefined,
    len: u8 = 0,

    fn textSlice(snapshot: *const ListSnapshot) []const u8 {
        return snapshot.text[0..snapshot.len];
    }
};

fn listSnapshot(client: *Client) ListSnapshot {
    const prompt = client.model.name_prompt.currentConst() orelse return .{};
    var snapshot: ListSnapshot = switch (prompt.target) {
        .goto => .{ .kind = .goto },
        .history => .{ .kind = .history },
        else => return .{},
    };

    snapshot.selection = prompt.selection;
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
        .history => try history_palettes.pasteSelection(client, before.selection),
        .goto => {
            var results: goto_picker.Results = .{};
            goto_picker.collect(pickerSources(client), before.textSlice(), &results);
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
    if (prompt.target != .history) {
        return;
    }

    const text = prompt.field.text();
    if (before.kind == .history and std.mem.eql(u8, before.textSlice(), text)) {
        return;
    }

    try history_palettes.sendQuery(client, text);
}

/// Keeps the picker selection inside the deterministic result set the
/// renderer and the submit path both derive from the current query.
fn clampPickerSelection(client: *Client) void {
    const prompt = client.model.name_prompt.current() orelse return;
    if (prompt.selection == 0) {
        return;
    }

    const count: u16 = switch (prompt.target) {
        .goto => blk: {
            var results: goto_picker.Results = .{};
            goto_picker.collect(pickerSources(client), prompt.field.text(), &results);
            break :blk results.len;
        },
        .history => client.model.history_palette.len,
        else => return,
    };
    const limit: u16 = if (count == 0) 0 else count - 1;
    if (prompt.selection > limit) {
        prompt.selection = limit;
    }
}

fn pickerSources(client: *Client) goto_picker.Sources {
    return .{
        .agents = client.model.agentSnapshot(),
        .workspaces = client.model.workspaceListSnapshot(),
        .tabs = &client.model.workspace,
    };
}

fn navigatePickerItem(client: *Client, item: goto_picker.Item) !void {
    switch (item) {
        .workspace => |workspace| _ = try workspace_handoffs.selectWorkspace(client, .{ .workspace = workspace }),
        .tab => |tab_id| {
            var use_case = tab_selections.selectionHandler(client);
            _ = try use_case.execute(.{ .target = .{ .tab_id = tab_id } });
        },
        .agent => |key| _ = try agent_navigation.apply(client, key),
    }
}

fn handler(client: *Client) name_prompt.NamePromptHandler {
    return .{
        .prompt = &client.model.name_prompt,
        .effects = .{
            .context = client,
            .submit = submit,
        },
    };
}

fn openingHandler(client: *Client) name_prompt_opening.OpenNamePromptHandler {
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

fn submit(context: *anyopaque, submission: prompt_state.Submission) !bool {
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
        .goto, .history => true,
        .copy_search => blk: {
            const pane_id = client.model.copyModeTarget() orelse break :blk true;
            const request_id = try request_lifecycle.nextId(client);
            var owned: connection_outbox.OwnedSearch = .{
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

fn dispatchInput(use_case: *name_prompt.NamePromptHandler, bytes: []const u8) !name_prompt.Outcome {
    var outcome: name_prompt.Outcome = .unchanged;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const parsed = term.parse(bytes[offset..]) orelse {
            const prompt = use_case.prompt.currentConst() orelse break;
            if (prompt.pasting) {
                outcome = merge(outcome, try use_case.execute(.{ .insert = bytes[offset..] }));
            }
            break;
        };
        if (parsed.len == 0) {
            break;
        }

        offset += parsed.len;
        const command: ?prompt_state.Command = switch (parsed.event) {
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .key => |key| switch (key.code) {
                .enter => .submit,
                .escape => .cancel,
                .backspace => .backspace,
                .delete => .delete,
                .left => .{ .move_left = key.mods.shift },
                .right => .{ .move_right = key.mods.shift },
                .up => .move_up,
                .down => .move_down,
                .home => .{ .home = key.mods.shift },
                .end => .{ .end = key.mods.shift },
                .char => |char| if (!key.mods.ctrl and !key.mods.alt)
                    .{ .insert = char.slice() }
                else
                    null,
                else => null,
            },
            .mouse, .terminal_response, .incomplete => null,
        };
        const semantic = command orelse continue;
        const next = try use_case.execute(semantic);
        outcome = merge(outcome, next);
        switch (next) {
            .cancelled, .blocked, .finished => return next,
            .unchanged, .routing_changed, .changed => {},
        }
    }

    return outcome;
}

fn merge(current: name_prompt.Outcome, next: name_prompt.Outcome) name_prompt.Outcome {
    if (next == .unchanged) {
        return current;
    }
    if (current == .changed and next == .routing_changed) {
        return current;
    }

    return next;
}

const EffectsCapture = struct {
    accept: bool = true,
    calls: usize = 0,

    fn port(capture: *EffectsCapture) name_prompt.SubmitEffects {
        return .{ .context = capture, .submit = submitPrompt };
    }

    fn submitPrompt(context: *anyopaque, submission: prompt_state.Submission) !bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        _ = submission;
        capture.calls += 1;
        return capture.accept;
    }
};

test "input adapter drops an incomplete zero-length tail without spinning" {
    var prompt: prompt_state.State = .{};
    prompt.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(3), .label = "logs" } });
    var capture: EffectsCapture = .{};
    var use_case: name_prompt.NamePromptHandler = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };

    try std.testing.expect(try dispatchInput(&use_case, "\x1b[123") == .unchanged);
    try std.testing.expectEqualStrings("logs", prompt.currentConst().?.field.text());
    try std.testing.expect(try dispatchInput(&use_case, "!\r") == .finished);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "input adapter preserves pasted newlines as bounded text" {
    var prompt: prompt_state.State = .{};
    prompt.begin(.create_workspace);
    var capture: EffectsCapture = .{};
    var use_case: name_prompt.NamePromptHandler = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };

    try std.testing.expect(try dispatchInput(&use_case, "\x1b[200~one\rtwo\x1b[201~") == .changed);
    try std.testing.expectEqualStrings("one two", prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "blocked submission remains active and escape cancels it" {
    var prompt: prompt_state.State = .{};
    prompt.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(3), .label = "logs" } });
    var capture: EffectsCapture = .{ .accept = false };
    var use_case: name_prompt.NamePromptHandler = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };

    try std.testing.expect(try dispatchInput(&use_case, "!\r") == .blocked);
    try std.testing.expectEqualStrings("logs!", prompt.currentConst().?.field.text());
    try std.testing.expect(try dispatchInput(&use_case, "\x1b") == .cancelled);
    try std.testing.expect(!prompt.active());
}
