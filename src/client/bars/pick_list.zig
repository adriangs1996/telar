//! Pick lists (docs/flows/pick-list.md): a configured pick opens the palette
//! on its options, written in the configuration or printed by a command that
//! runs off the event loop, and the chosen value runs the pick's `on_select`
//! as an argv without a shell. After a successful choice the bar sources and
//! the open panel run again, so they show what the command changed.
const data = @import("model");
const std = @import("std");
const Client = @import("../execution/Client.zig");
const bar_updates = @import("../config/bar_updates.zig");
const client_diagnostic = @import("../config/client_diagnostic.zig");
const name_prompt = @import("../input/name_prompt.zig");
const PickCommandCompletion = @import("PickCommandCompletion.zig");
const PickCommandJob = @import("PickCommandJob.zig");
const Output = @import("Output.zig");

/// Opens the palette on the pick `index` of the active configuration. A
/// list command starts now and its options arrive with its completion;
/// written options show at once.
///
/// ```zig
/// try pick_list.open(client, index);
/// ```
pub fn open(client: *Client, index: u8) !void {
    const definition = current(client, index) orelse return;
    if (!name_prompt.openNamePrompt(&client.model, .pick)) {
        return;
    }

    const state = &client.model.pick_list;
    state.begin(.{
        .index = index,
        .generation = client.model.configuration_generation,
        .prompt_generation = client.model.name_prompt.currentConst().?.generation,
        .title = definition.heading.title(),
    });
    if (definition.list) |list| {
        return start(client, .{
            .purpose = .list,
            .command = list,
        });
    }

    fill(client, definition, null);
}

/// Runs the `on_select` of the open list with the option the palette's
/// query and selection name, then closes the list. Nothing runs while the
/// options are not there or nothing matches.
///
/// ```zig
/// try pick_list.choose(client, snapshot.textSlice(), snapshot.selection);
/// ```
pub fn choose(client: *Client, query: []const u8, selection: u16) !void {
    const state = &client.model.pick_list;
    defer state.close();

    if (state.phase != .ready) {
        return;
    }

    const definition = current(client, state.index) orelse return;

    if (state.generation != client.model.configuration_generation) {
        return;
    }

    const option = data.pick_list.chosen(&state.items, query, selection) orelse return;

    if (state.selecting != .none) {
        return report(client, client_diagnostic.formatted("pick '{s}' is still running its last choice", .{definition.heading.name()}));
    }

    const command = definition.selection(state.items.value(option)) catch |err| {
        return report(client, client_diagnostic.formatted("pick '{s}': the choice does not fit on_select: {s}", .{ definition.heading.name(), @errorName(err) }));
    };

    state.selecting_index = state.index;
    state.selecting_generation = state.generation;

    try start(client, .{
        .purpose = .select,
        .command = command,
    });
}

/// Closes the list when its palette closes or another prompt replaces it.
/// Example: `pick_list.close(&client.model);`
pub fn close(model: *data.ClientModel) void {
    model.pick_list.close();
}

/// Takes a finished list or `on_select` command. A completion the list no
/// longer waits for is released and dropped.
///
/// ```zig
/// try pick_list.finish(client, completion);
/// ```
pub fn finish(client: *Client, completion: PickCommandCompletion) !void {
    var result = completion.result;
    defer if (result) |*output| output.deinit() else |_| {};

    switch (completion.purpose) {
        .list => finishList(client, completion.execution_id, &result),
        .select => try finishSelection(client, completion.execution_id, &result),
    }
}

fn finishList(client: *Client, execution_id: data.command_execution.Id, result: *const anyerror!Output) void {
    const state = &client.model.pick_list;
    if (state.listing == .none or state.listing != execution_id) {
        return;
    }

    // A palette replaced while the command ran shows nothing to fill.
    if (!state.shownBy(client.model.name_prompt.currentConst())) {
        return state.close();
    }

    const definition = current(client, state.index) orelse return state.fail("the configuration changed; open the list again");
    if (state.generation != client.model.configuration_generation) {
        return state.fail("the configuration changed; open the list again");
    }

    const output = result.* catch |err| return failList(state, err);
    fill(client, definition, output.slice());
}

fn finishSelection(client: *Client, execution_id: data.command_execution.Id, result: *const anyerror!Output) !void {
    const state = &client.model.pick_list;
    if (state.selecting == .none or state.selecting != execution_id) {
        return;
    }

    state.selecting = .none;
    const definition = if (state.selecting_generation == client.model.configuration_generation) current(client, state.selecting_index) else null;
    const name = if (definition) |value| value.heading.name() else "";
    _ = result.* catch |err| {
        return report(client, client_diagnostic.formatted("pick '{s}' on_select {s}", .{ name, reason(err) }));
    };

    if (definition != null and definition.?.refresh) {
        try bar_updates.refreshSources(client);
    }
}

// Lists the options: the written table, or the `items` function over the
// command's output, or one option per line of that output.
fn fill(client: *Client, definition: *const data.PickDefinition, output: ?[]const u8) void {
    const state = &client.model.pick_list;
    const reference = definition.items orelse {
        data.pick_list.readLines(&state.items, output orelse "") catch |err| return failList(state, err);
        return state.show();
    };

    const generation = client.lua_generation orelse return state.fail("the configuration is not loaded");
    var diagnostic: data.Diagnostic = .{};
    generation.invokePick(.{
        .reference = reference,
        .context = bar_updates.callbackContext(client, output),
    }, &state.items, &diagnostic) catch |err| {
        return state.fail(if (diagnostic.len != 0) diagnostic.message() else @errorName(err));
    };
    state.show();
}

fn start(client: *Client, run: Run) !void {
    const state = &client.model.pick_list;
    const execution_id = state.reserve();
    client.to_background.push(.{ .pick_command = .{
        .execution_id = execution_id,
        .purpose = run.purpose,
        .command = run.command,
    } }) catch |err| switch (run.purpose) {
        .list => return failList(state, err),
        .select => return report(client, client_diagnostic.formatted("pick on_select could not start: {s}", .{@errorName(err)})),
    };

    switch (run.purpose) {
        .list => state.listing = execution_id,
        .select => state.selecting = execution_id,
    }
}

fn failList(state: *data.PickListState, err: anyerror) void {
    var text: [data.PickListState.max_error_bytes]u8 = undefined;
    state.fail(std.fmt.bufPrint(&text, "the list command {s}", .{reason(err)}) catch "the list command failed");
}

fn report(client: *Client, diagnostic: data.Diagnostic) !void {
    _ = try client_diagnostic.replace(&client.model, .{
        .diagnostic = diagnostic,
        .invalid_fallback = client_diagnostic.formatted("pick command failed", .{}),
    });
}

/// What went wrong, worded to follow "the command".
fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.BarCommandFailed => "exited with an error",
        error.Timeout => "timed out",
        error.StreamTooLong => "printed more than it may",
        error.FileNotFound => "was not found",
        error.InvalidBarCommandOutput => "printed control characters or invalid UTF-8",
        error.TooManyPickItems => "printed more than 1024 options",
        error.PickItemsTooLarge => "printed more option text than a list holds",
        error.PickItemTooLong => "printed a line longer than 512 bytes",
        error.InvalidPickItem => "printed control characters or invalid UTF-8",
        else => @errorName(err),
    };
}

// The active configuration's pick `index`, while Lua and the model agree
// on the generation.
fn current(client: *const Client, index: u8) ?*const data.PickDefinition {
    const configuration = bar_updates.barConfiguration(client) orelse return null;
    return configuration.pick(index);
}

const Run = struct {
    purpose: PickCommandJob.Purpose,
    command: data.BarCommand,
};

test "failure reasons read after the command" {
    try std.testing.expectEqualStrings("timed out", reason(error.Timeout));
    try std.testing.expectEqualStrings("Unexpected", reason(error.Unexpected));
}
