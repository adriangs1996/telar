//! Workspace creation: asks the runtime for a new workspace and adopts the
//! first pane it opens.
const data = @import("model");
const core = @import("telar-core");
const path_queries = @import("../input/path_completions.zig");
const path_expansion = @import("../completion/path_expansion.zig");
const prompt_paths = @import("../completion/prompt_paths.zig");
const name_prompt = @import("../input/name_prompt.zig");
const workspace_handoff = @import("workspace_handoff.zig");
const Client = @import("../execution/Client.zig");

/// Validates a workspace creation and retains its launch parameters until confirmation.
/// Example: `_ = try workspace_creation.requestWorkspaceCreation(app, .{ .name = "agents" });`
pub fn requestWorkspaceCreation(client: *Client, command: data.RequestWorkspaceCreation) !bool {
    if (!client.model.request_lifecycle.tracker.isEmpty()) {
        return false;
    }

    try data.label_validation.validate(command.name, .workspace);
    const cwd_source: ?core.PaneId = if (command.cwd.len == 0)
        client.model.planWorkspaceCreation() orelse return false
    else
        null;
    const request_id = try client.model.request_lifecycle.nextId();
    try sendCreateWorkspaceRequest(
        &client.model,
        .{
            .request_id = request_id,
            .size = data.multiplexer.rectSize(client.geometry().area) orelse return error.TerminalTooSmall,
            .name = command.name,
            .create_cwd = command.create_cwd,
            .launch = .{
                .cwd = if (command.cwd.len != 0) command.cwd else client.options.cwd,
                .cwd_source = cwd_source,
                .arguments = client.options.arguments,
            },
        },
    );

    return true;
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try workspace_creation.sendCreateWorkspaceRequest(client, request);`
fn sendCreateWorkspaceRequest(model: *data.ClientModel, request: core.CreateWorkspace) !void {
    try model.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .create_workspace = request.size,
        },
    );
    errdefer _ = model.request_lifecycle.tracker.take(request.request_id);
    try model.to_runtime.pushCreateWorkspace(request);
}

pub fn arriveOpenedWorkspace(client: *Client, opened: data.OpenedPane) !void {
    const size = data.multiplexer.rectSize(client.geometry().area) orelse return error.TerminalTooSmall;
    const activation = try client.model.arriveWorkspace(workspace_handoff.workspaceArrival(
        &client.model.navigation_history,
        opened,
        size,
    ));
    try workspace_handoff.activateWorkspace(client, activation);
}

pub fn createOpenedWorkspace(client: *Client, confirmation: data.WorkspaceCreation) !void {
    if (!confirmation.opened.created) {
        return error.UnexpectedRequest;
    }

    const replacement = try client.model.replaceWorkspace(workspace_handoff.workspaceArrival(
        &client.model.navigation_history,
        confirmation.opened,
        confirmation.requested_size,
    ));
    workspace_handoff.releaseWorkspace(client, &replacement.departure);
    try workspace_handoff.activateWorkspace(client, replacement.activation);
}

/// Starts workspace creation only when the current client can plan the
/// request.
pub fn beginWorkspacePrompt(client: *Client) bool {
    if (!name_prompt.openNamePrompt(&client.model, .create_workspace)) {
        return false;
    }

    prompt_paths.openPathCompletion(client) catch {};
    return true;
}

/// Expands the typed directory, asks once before creating a missing one and
/// derives the context name from the directory when the name is empty.
pub fn submitWorkspacePrompt(client: *Client, submission: data.Submission) !bool {
    var buffer: [path_queries.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = if (submission.directory.len == 0)
        ""
    else
        prompt_paths.expandPromptDirectory(client, submission.directory, &buffer) catch return false;
    if (cwd.len != 0) {
        switch (prompt_paths.promptDirectoryStatus(client, cwd)) {
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

    return requestWorkspaceCreation(
        client,
        .{
            .name = name,
            .cwd = cwd,
            .create_cwd = submission.create_directory and cwd.len != 0,
        },
    ) catch |err| switch (err) {
        error.InvalidWorkspaceName, error.InvalidUtf8 => false,
        else => err,
    };
}
