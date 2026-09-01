//! Adapts host-terminal input and client request ports to the name-prompt use
//! case.

const std = @import("std");
const core = @import("telar-core");
const presentation = @import("../presentation/root.zig");
const input_application = @import("application/input/root.zig");
const prompt_state = @import("name_prompt.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const tab_renames = @import("tab_renames.zig");
const workspace_creations = @import("workspace_creations.zig");
const workspace_renames = @import("workspace_renames.zig");

const Client = @import("client.zig");
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
pub fn handleInput(client: *Client, bytes: []const u8) !name_prompt.Outcome {
    var use_case = handler(client);

    return dispatchInput(&use_case, bytes);
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
