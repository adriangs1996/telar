//! Name prompt: the prompt that names tabs and workspaces, picks directories
//! and runs palette commands.
const data = @import("model");
const std = @import("std");
const name_prompts = @import("name_prompts.zig");
const name_prompt_opening = @import("name_prompt_opening.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const prompt_paths = @import("../completion/prompt_paths.zig");
const actions = @import("actions.zig");
const history_palette = @import("history_palette.zig");
const machine_picker = @import("../machines/machine_picker.zig");
const machine_profiles = @import("../machines/machine_profiles.zig");
const MachineResults = @import("../machines/MachineResults.zig");
const Machines = @import("../machines/Machines.zig");
const path_picker = @import("path_picker.zig");
const pick_list = @import("../bars/pick_list.zig");
const suggest_command = @import("suggest_command.zig");
const tab_rename = @import("../workspace/tab_rename.zig");
const tab_selection = @import("../workspace/tab_selection.zig");
const workspace_creation = @import("../workspace/workspace_creation.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const workspace_rename = @import("../workspace/workspace_rename.zig");
const agent_peek = @import("../agents/agent_peek.zig");
const Client = @import("../execution/Client.zig");

/// Opens the command palette with `prefix` already typed. A `?` palette
/// starts with a cleared suggestion, like `suggestions.begin`.
/// Example: `_ = name_prompt.beginCommandPalette(app, prefix);`
pub fn beginCommandPalette(model: *data.ClientModel, prefix: data.CommandPalettePrefix) bool {
    if (!openNamePrompt(
        model,
        .{
            .palette = prefix,
        },
    )) {
        return false;
    }

    if (prefix == .suggest) {
        model.suggestion.begin();
    }

    return true;
}

/// Chooses one visible list row with the pointer and submits it, exactly as
/// moving the selection there and pressing Enter would.
/// Example: `try name_prompt.choosePromptRow(app, index);`
pub fn choosePromptRow(client: *Client, index: u16) !void {
    client.model.name_prompt.select(index);
    constrainPickerSelection(&client.model, client.machines);
    _ = try inputPrompt(
        client,
        .{
            .key = .{
                .code = .enter,
            },
        },
    );
}

/// Accepts a directory row only while its landed listing is still current.
/// Clicking a folder completes the path without submitting the context form.
/// Example: `try chooseDirectory(client, index, listing_revision);`
/// Example: `try name_prompt.chooseDirectory(app, index, revision);`
pub fn chooseDirectory(client: *Client, index: u16, revision: u64) !void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    const completion = &client.model.path_completion;
    if (prompt.form() == null or completion.version() != revision or completion.pending != .none or index >= completion.entries().len) {
        return;
    }

    _ = try inputPrompt(
        client,
        .{
            .command = .{
                .focus_field = .directory,
            },
        },
    );
    client.model.name_prompt.select(index);
    _ = try inputPrompt(
        client,
        .{
            .command = .tab,
        },
    );
}

/// Applies one semantic event as a bounded prompt command. Accepted
/// submissions close the prompt after delivery; blocked or failed
/// effects leave the prompt intact.
/// Example: `_ = try name_prompt.inputPrompt(app, input);`
pub fn inputPrompt(client: *Client, input: name_prompts.Input) !PromptOutcome {
    const before = promptListSnapshot(&client.model.name_prompt);
    const directory_before = promptDirectoryVersion(&client.model.name_prompt);
    const paths_request = client.model.path_picker.pending_request;
    const command = path_picker.orient(&client.model, name_prompts.commandFor(&input));
    const outcome = if (command) |value| try applyPromptCommand(client, value) else .unchanged;
    try refreshPromptHistory(&client.model, before);
    try refreshPromptPaths(
        &client.model,
        before,
        paths_request,
    );
    if (outcome == .cancelled and before.kind == .paths) {
        path_picker.close(&client.model);
    }

    if (outcome == .cancelled and before.kind == .pick) {
        pick_list.close(&client.model);
    }

    try history_palette.navigateHistoryPage(&client.model);
    if (outcome == .completion_requested) {
        try prompt_paths.acceptPathCompletion(client);
    } else if (outcome == .cancelled or outcome == .finished) {
        prompt_paths.closePathCompletion(&client.model);
        agent_peek.settle(&client.model);
    } else if (directory_before != null and !std.meta.eql(directory_before, promptDirectoryVersion(&client.model.name_prompt))) {
        try prompt_paths.refreshPathCompletion(client);
    }
    constrainPickerSelection(&client.model, client.machines);
    try history_palette.refreshHistoryInspection(client);
    suggest_command.discardEditedSuggestion(&client.model, before);
    if (outcome == .finished) {
        var submission = before;
        submission.alternate = client.list_submission_alternate;
        client.list_submission_alternate = false;
        try finishPromptList(client, submission);
    }
    if (outcome == .removed and before.kind == .history) {
        try history_palette.deleteHistorySelection(&client.model, before.selection);
    }
    if (outcome == .removed and before.kind == .machines) {
        try machine_picker.remove(client, machineRow(client, before));
    }
    if (outcome == .rename_requested and before.kind == .machines) {
        machine_picker.rename(client, machineRow(client, before));
    }
    if (outcome == .copied and before.kind == .history) {
        try history_palette.copyHistorySelection(client, before.selection);
    }
    if (outcome == .pane_requested and before.kind == .history) {
        try history_palette.visitHistoryPane(client, before.selection);
    }
    return outcome;
}

/// Checks current input authority and initializes the prompt from canonical model state.
/// Example: `const opened = name_prompt.openNamePrompt(app, .rename_active_tab);`
pub fn openNamePrompt(model: *data.ClientModel, intent: name_prompt_opening.Intent) bool {
    if (data.pane_input.pasteActive(model)) {
        return false;
    }
    if (intent == .copy_search) {
        if (!data.copy_mode.isActive(model)) {
            return false;
        }

        model.name_prompt.begin(
            .{
                .copy_search = intent.copy_search,
            },
        );
        return true;
    }
    if (data.copy_mode.isActive(model)) {
        return false;
    }

    const command: data.PromptBegin = switch (intent) {
        .create_workspace => create: {
            if (!model.request_lifecycle.tracker.isEmpty()) {
                return false;
            }
            if (data.workspace_creation.plan(model) == null) {
                return false;
            }

            break :create .create_workspace;
        },
        .rename_workspace => rename: {
            const workspace = model.workspace orelse return false;
            break :rename .{
                .rename_workspace = .{
                    .workspace = workspace,
                    .name = model.workspaceName(),
                },
            };
        },
        .rename_active_tab => rename: {
            const active = model.tabs.activeSlot() orelse return false;
            break :rename name_prompt_opening.renameTab(model.tabs.location[active].tab_id, data.tab_label.text(model, active));
        },
        .rename_tab => |tab_id| rename: {
            const tab = model.tabs.find(tab_id) orelse return false;
            break :rename name_prompt_opening.renameTab(tab_id, data.tab_label.text(model, tab));
        },
        .goto_picker => .goto_picker,
        .history_palette => .history_palette,
        .suggest_palette => .suggest_palette,
        .path_picker => .path_picker,
        .palette => |prefix| .{
            .palette = prefix,
        },
        .rename_machine => |rename| .{
            .rename_machine = .{
                .slot = rename.slot,
                .label = rename.label,
            },
        },
        .add_machine => .add_machine,
        .peek => |key| peek: {
            if (model.agent_snapshot.find(key) == null) {
                return false;
            }

            break :peek .{ .peek = key };
        },
        .pick => .pick,
        .copy_search => unreachable,
    };

    model.name_prompt.begin(command);
    return true;
}

/// Length and head of the directory field, enough to notice a text change
/// without copying up to `max_cwd_bytes` per keystroke.
fn promptDirectoryVersion(prompt_state: *const data.NamePromptState) ?[2]usize {
    const prompt = prompt_state.currentConst() orelse return null;
    if (prompt.form() == null) {
        return null;
    }

    return .{
        prompt.directory.len,
        std.hash.Crc32.hash(prompt.directory.text()),
    };
}

pub fn promptListSnapshot(prompt_state: *const data.NamePromptState) data.PromptListSnapshot {
    const prompt = prompt_state.currentConst() orelse return .{};
    var snapshot: data.PromptListSnapshot = switch (prompt.target()) {
        .goto => .{
            .kind = .goto,
        },
        .history => .{
            .kind = .history,
        },
        .paths => .{
            .kind = .paths,
        },
        .suggest => .{
            .kind = .suggest,
        },
        .pick => .{
            .kind = .pick,
        },
        .palette => switch (prompt.paletteMode()) {
            .goto => .{
                .kind = .goto,
            },
            .suggest => .{
                .kind = .suggest,
            },
            .actions => .{
                .kind = .actions,
            },
            .machines => .{
                .kind = .machines,
            },
        },
        else => return .{},
    };

    snapshot.selection = prompt.selection();
    snapshot.scope = prompt.scope();
    if (prompt.mode == .history) {
        snapshot.author = prompt.mode.history.author;
        snapshot.failed_only = prompt.mode.history.failed_only;
    }
    const text = prompt.paletteQuery();
    snapshot.len = @intCast(text.len);
    @memcpy(snapshot.text[0..text.len], text);
    return snapshot;
}

/// Applies the accepted list submission after the prompt closed. Pastes and
/// navigation are gated on prompt authority (`planPaneInput`, handoffs), so
/// they must not run inside the submit effect while the prompt is active.
fn finishPromptList(client: *Client, before: data.PromptListSnapshot) !void {
    switch (before.kind) {
        .none => {},
        .history => try history_palette.pasteHistorySelection(
            client,
            .{
                .selection = before.selection,
                .run = client.model.config.history_enter_runs != before.alternate,
            },
        ),
        .suggest => try suggest_command.pasteSuggestion(client),
        .paths => try path_picker.insert(
            client,
            before.selection,
            before.alternate,
        ),
        .goto => {
            var results: data.Results = .{};
            data.goto_picker.collect(
                pickerSources(&client.model),
                before.textSlice(),
                &results,
            );
            if (results.len == 0) {
                return;
            }

            const index = @min(before.selection, @as(u16, results.len) - 1);
            try navigatePickerItem(client, results.slice()[index].item);
        },
        .actions => {
            var results: data.CommandResults = .{};
            data.command_palette.collect(before.textSlice(), &results);
            if (results.len == 0) {
                return;
            }

            const index = @min(before.selection, @as(u16, results.len) - 1);
            _ = try actions.executeAction(client, data.command_palette.entries[results.slice()[index].index].action, .effect);
        },
        .machines => {
            if (client.machines == null) {
                return;
            }

            try machine_picker.choose(client, machineRow(client, before), before.alternate);
        },
        .pick => try pick_list.choose(client, before.textSlice(), before.selection),
    }
}

/// Requeries the runtime only when the palette's query text actually
/// changed, so selection moves and pastes stay local.
fn refreshPromptHistory(model: *data.ClientModel, before: data.PromptListSnapshot) !void {
    const prompt = model.name_prompt.currentConst() orelse return;
    if (prompt.target() != .history) {
        return;
    }

    const text = prompt.field.text();
    const history = prompt.mode.history;
    if (before.kind == .history and before.scope == history.scope and before.author == history.author and before.failed_only == history.failed_only and
        std.mem.eql(
            u8,
            before.textSlice(),
            text,
        ))
    {
        return;
    }

    try history_palette.queryHistory(model, text);
}

/// Asks for new matches only when the path query text changed; moving the
/// root clears the field and requests on its own.
fn refreshPromptPaths(model: *data.ClientModel, before: data.PromptListSnapshot, request_before: u64) !void {
    const prompt = model.name_prompt.currentConst() orelse return;
    if (prompt.target() != .paths or before.kind != .paths or model.path_picker.pending_request != request_before) {
        return;
    }

    const text = prompt.field.text();
    if (std.mem.eql(
        u8,
        before.textSlice(),
        text,
    )) {
        return;
    }

    try path_picker.request(model, text);
}

/// Keeps the picker selection inside the deterministic result set the
/// renderer and the submit path both derive from the current query.
fn constrainPickerSelection(model: *data.ClientModel, machines_for_selection: ?*const Machines) void {
    const prompt = model.name_prompt.currentConst() orelse return;
    if (prompt.selection() == 0) {
        return;
    }

    const count: u16 = switch (prompt.target()) {
        .goto => pickerCount(model, prompt.field.text()),
        .history => model.history_palette.len,
        .paths => model.path_picker.len,
        .suggest => 1,
        .create_workspace => @intCast(model.path_completion.entries().len),
        .pick => blk: {
            var results: data.PickResults = .{};
            data.pick_list.collect(&model.pick_list.items, prompt.field.text(), &results);
            break :blk results.len;
        },
        .palette => switch (prompt.paletteMode()) {
            .goto => pickerCount(model, prompt.paletteQuery()),
            .suggest => 1,
            .actions => blk: {
                var results: data.CommandResults = .{};
                data.command_palette.collect(prompt.paletteQuery(), &results);
                break :blk results.len;
            },
            .machines => blk: {
                const machines = machines_for_selection orelse break :blk 0;
                var results: MachineResults = .{};
                machine_picker.collect(machines, prompt.paletteQuery(), &results);
                break :blk results.rows();
            },
        },
        else => return,
    };
    model.name_prompt.constrainSelection(count);
}

// The row of the machine list the snapshot's selection names, as the
// palette drew it.
fn machineRow(client: *Client, before: data.PromptListSnapshot) ?u8 {
    const machines = client.machines orelse return null;
    var results: MachineResults = .{};
    machine_picker.collect(machines, before.textSlice(), &results);
    return results.slotAt(@min(before.selection, results.rows() - 1));
}

fn pickerCount(model: *data.ClientModel, query: []const u8) u16 {
    var results: data.Results = .{};
    data.goto_picker.collect(
        pickerSources(model),
        query,
        &results,
    );
    return results.len;
}

fn pickerSources(model: *const data.ClientModel) data.Sources {
    return .{
        .agents = &model.agent_snapshot,
        .workspaces = &model.workspace_list_snapshot,
        .model = model,
    };
}

fn navigatePickerItem(client: *Client, item: data.goto_picker.Item) !void {
    switch (item) {
        .workspace => |workspace| _ = try workspace_handoff.selectWorkspace(
            client,
            .{
                .workspace = workspace,
            },
        ),
        .tab => |tab_id| {
            _ = try tab_selection.selectTab(
                client,
                .{
                    .target = .{
                        .tab_id = tab_id,
                    },
                },
            );
        },
        .agent => |key| _ = try agent_navigation.navigateAgent(client, key),
    }
}

fn submitPrompt(client: *Client, submission: data.Submission) !bool {
    return switch (submission.target) {
        .create_workspace => workspace_creation.submitWorkspacePrompt(client, submission),
        .rename_workspace => |workspace| blk: {
            break :blk try workspace_rename.requestWorkspaceRename(
                &client.model,
                .{
                    .workspace = workspace,
                    .name = submission.name,
                },
            );
        },
        .rename_tab => |tab_id| blk: {
            break :blk try tab_rename.requestTabRename(
                &client.model,
                .{
                    .tab_id = tab_id,
                    .label = submission.name,
                },
            );
        },
        // List targets only close here; the picked entry is applied by
        // `finishListSubmission` once the prompt no longer owns input.
        .history => blk: {
            const prompt = client.model.name_prompt.currentConst() orelse break :blk false;
            if (!history_palette.canSubmitHistory(&client.model, prompt.selection())) {
                break :blk false;
            }

            client.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .goto => blk: {
            client.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .paths => blk: {
            const prompt = client.model.name_prompt.currentConst() orelse break :blk false;
            if (!path_picker.canInsert(&client.model, prompt.selection())) {
                break :blk false;
            }

            client.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .suggest => suggest_command.submitSuggestion(&client.model, submission.name),
        // Enter is inert until the options arrive and while none matches.
        .pick => data.pick_list.chosen(&client.model.pick_list.items, submission.name, client.model.name_prompt.currentConst().?.selection()) != null and
            client.model.pick_list.phase == .ready,
        .peek => |key| try agent_peek.submit(client, key, submission.name),
        // The palette closes like the list its prefix selects; `>` closes
        // only when a catalogue entry matches, so Enter on no match is inert.
        .palette => blk: {
            const prompt = client.model.name_prompt.currentConst() orelse break :blk false;
            switch (prompt.paletteMode()) {
                .goto => {
                    client.list_submission_alternate = submission.alternate;
                    break :blk true;
                },
                .suggest => break :blk try suggest_command.submitSuggestion(&client.model, prompt.paletteQuery()),
                .actions => {
                    var results: data.CommandResults = .{};
                    data.command_palette.collect(prompt.paletteQuery(), &results);
                    break :blk results.len != 0;
                },
                .machines => {
                    client.list_submission_alternate = submission.alternate;
                    break :blk client.machines != null;
                },
            }
        },
        .machine => |machine| blk: {
            const machines = client.machines orelse break :blk true;
            switch (machine) {
                .rename => |slot| try machine_profiles.start(client, .{
                    .kind = .rename,
                    .label = machines.label(slot),
                    .value = submission.name,
                }),
                .add_label => {},
                .add_destination => |label| try machine_profiles.start(client, .{
                    .kind = .add,
                    .label = label.text(),
                    .value = submission.name,
                }),
            }

            break :blk true;
        },
        .copy_search => blk: {
            const pane_id = data.copy_mode.targetPane(&client.model) orelse break :blk true;
            const request_id = try client.model.request_lifecycle.nextId();
            var owned: data.OwnedSearch = .{
                .request_id = request_id,
                .pane_id = pane_id,
                .needle_len = @intCast(submission.name.len),
            };
            @memcpy(owned.needle[0..submission.name.len], submission.name);
            try client.model.to_runtime.push(
                .{
                    .search_pane = owned,
                },
            );
            break :blk true;
        },
    };
}

fn applyPromptCommand(client: *Client, command: data.PromptCommand) !PromptOutcome {
    return switch (client.model.name_prompt.apply(command)) {
        .unchanged => .unchanged,
        .routing_changed => .routing_changed,
        .changed => .changed,
        .cancelled => .cancelled,
        .removed => .removed,
        .rename_requested => .rename_requested,
        .copied => .copied,
        .pane_requested => .pane_requested,
        .completion_requested => .completion_requested,
        .descend_requested => |selection| blk: {
            try path_picker.descend(&client.model, selection);
            break :blk .changed;
        },
        .ascend_requested => blk: {
            try path_picker.ascend(&client.model);
            break :blk .changed;
        },
        .submitted => |submission| if (!try submitPrompt(client, submission))
            .blocked
        else blk: {
            std.debug.assert(client.model.name_prompt.finish(submission.target));
            break :blk .finished;
        },
    };
}

const PromptOutcome = enum {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    /// The palette asked to delete its selected entry; the controller owns
    /// the wire effect.
    removed,
    /// The machine list asked to rename its selected machine.
    rename_requested,
    /// The palette asked to copy its selected command to the clipboard.
    copied,
    /// The palette asked to leave for the pane its selected command ran in.
    pane_requested,
    /// The directory field asked for its selected completion; the
    /// controller owns the completion list.
    completion_requested,
    blocked,
    finished,
};
