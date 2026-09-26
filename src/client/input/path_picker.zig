//! Path picker: fuzzy-finds paths under the focused pane's directory and
//! pastes the chosen one at its cursor. The runtime indexes and ranks; the
//! client keeps the root, the page and the selection. See
//! `docs/flows/path-picker.md`.

const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const name_prompt = @import("name_prompt.zig");
const pane_input = @import("../panes/pane_input.zig");
const Client = @import("../execution/Client.zig");

/// Characters a shell reads literally inside a word.
const plain_bytes = "_-./+@%,:";
/// Room for the absolute path of one match, quoted in the worst case.
const max_text_bytes = 4 * (core.max_cwd_bytes + core.max_path_match_bytes);

/// Opens the picker over the focused pane's directory. False when no pane
/// has a known directory or another mode owns input.
///
/// ```zig
/// .path_picker => _ = try path_picker.enter(&client.model),
/// ```
pub fn enter(model: *data.ClientModel) !bool {
    const active = model.tabs.activeSlot() orelse return false;
    const pane = data.tab_layout.focusedPaneConst(model, active) orelse return false;
    const directory = pane.cwdSlice();
    if (directory.len == 0 or directory[0] != '/') {
        return false;
    }

    if (!name_prompt.openNamePrompt(model, .path_picker)) {
        return false;
    }

    model.path_picker.begin(pane.id, directory);
    try request(model, "");
    return true;
}

/// Asks the runtime for the paths under the current root matching `text`.
///
/// ```zig
/// try path_picker.request(model, prompt.field.text());
/// ```
pub fn request(model: *data.ClientModel, text: []const u8) !void {
    const state = &model.path_picker;
    const request_id = try model.request_lifecycle.nextId();
    model.to_runtime.pushFindPaths(.{
        .request_id = request_id,
        .root = state.rootSlice(),
        .query = boundedQuery(text),
        .refresh = state.refresh,
    }) catch |err| switch (err) {
        error.ClientOutboxFull => {
            state.setError("Path request queue is full; retry");
            return;
        },
        else => return err,
    };

    state.expect(core.raw(request_id));
}

/// Lands a page of matches and keeps the selection inside it.
///
/// ```zig
/// .path_results => |results| try path_picker.receive(client, results),
/// ```
pub fn receive(client: *Client, results: core.PathResultsView) !void {
    const model = &client.model;
    if (!try model.path_picker.receive(results)) {
        return;
    }

    const prompt = model.name_prompt.currentConst() orelse return;
    if (prompt.target() == .paths) {
        model.name_prompt.constrainSelection(model.path_picker.len);
    }
}

/// Browses the selected directory. Example: `try path_picker.descend(model, selection);`
pub fn descend(model: *data.ClientModel, selection: u16) !void {
    const state = &model.path_picker;
    const match = selected(state, selection) orelse return;
    if (match.kind != .directory) {
        return;
    }

    var buffer: [core.max_cwd_bytes]u8 = undefined;
    const relative = std.mem.trimEnd(
        u8,
        state.path(match),
        "/",
    );
    const root = join(
        state.rootSlice(),
        relative,
        &buffer,
    ) orelse return;
    try browse(model, root);
}

/// Browses the parent of the current root. Example: `try path_picker.ascend(model);`
pub fn ascend(model: *data.ClientModel) !void {
    const root = model.path_picker.rootSlice();
    if (root.len <= 1) {
        return;
    }

    const split = std.mem.lastIndexOfScalar(
        u8,
        root,
        '/',
    ) orelse return;
    var buffer: [core.max_cwd_bytes]u8 = undefined;
    const parent = if (split == 0) "/" else root[0..split];
    @memcpy(buffer[0..parent.len], parent);
    try browse(model, buffer[0..parent.len]);
}

fn browse(model: *data.ClientModel, root: []const u8) !void {
    model.path_picker.setRoot(root);
    model.name_prompt.clearPathQuery();
    try request(model, "");
}

/// Admits a submission only when the selected path fits one paste; the
/// prompt stays open otherwise. Example: `if (!path_picker.canInsert(model, selection)) return false;`
pub fn canInsert(model: *data.ClientModel, selection: u16) bool {
    const state = &model.path_picker;
    if (selected(state, selection) == null) {
        state.setError(if (state.phase == .loading) "Searching..." else "No path to insert");
        return false;
    }

    if (model.to_runtime.availableCapacity() < 2) {
        state.setError("Input is busy; retry");
        return false;
    }

    return true;
}

/// Makes Up and Down follow the screen. A picker opened above the cursor
/// lists its best match at the bottom, next to the field, so there the
/// selection moves to worse matches going up.
///
/// ```zig
/// const command = path_picker.orient(&client.model, name_prompts.commandFor(&input));
/// ```
pub fn orient(model: *const data.ClientModel, command: ?data.PromptCommand) ?data.PromptCommand {
    const value = command orelse return null;
    const prompt = model.name_prompt.currentConst() orelse return value;
    if (prompt.target() != .paths) {
        return value;
    }

    const placement = data.path_picker_placement.current(model) orelse return value;
    return onScreen(value, placement.flipped);
}

fn onScreen(command: data.PromptCommand, flipped: bool) data.PromptCommand {
    if (!flipped) {
        return command;
    }

    return switch (command) {
        .move_up => .move_down,
        .move_down => .move_up,
        else => command,
    };
}

/// Pastes the selected path after the prompt closed: relative to the
/// pane's directory when it lies inside it, absolute otherwise or when
/// `absolute` asks for it.
///
/// ```zig
/// try path_picker.insert(client, before.selection, before.alternate);
/// ```
pub fn insert(client: *Client, selection: u16, absolute: bool) !void {
    defer close(&client.model);

    var buffer: [max_text_bytes]u8 = undefined;
    const text = insertion(
        &client.model.path_picker,
        .{
            .selection = selection,
            .absolute = absolute,
        },
        &buffer,
    ) orelse return;
    _ = try pane_input.pasteText(
        client,
        text,
        false,
    );
}

/// Forgets the page when the prompt closes. Example: `path_picker.close(model);`
pub fn close(model: *data.ClientModel) void {
    model.path_picker.close();
}

const Choice = struct {
    selection: u16,
    absolute: bool,
};

/// The shell word for one match, written into `buffer`.
fn insertion(state: *const data.PathPickerState, choice: Choice, buffer: *[max_text_bytes]u8) ?[]const u8 {
    const match = selected(state, choice.selection) orelse return null;
    var joined: [core.max_cwd_bytes + core.max_path_match_bytes + 1]u8 = undefined;
    const full = join(
        state.rootSlice(),
        state.path(match),
        &joined,
    ) orelse return null;
    const anchor = state.anchorSlice();
    var word = full;
    if (!choice.absolute) {
        if (relativeTo(anchor, full)) |relative| {
            word = relative;
        }
    }

    return quote(word, buffer);
}

fn selected(state: *const data.PathPickerState, selection: u16) ?*const data.PathPickerMatch {
    if (state.len == 0) {
        return null;
    }

    return &state.slice()[@min(selection, state.len - 1)];
}

/// `root/relative`, or null when it does not fit `buffer`.
fn join(root: []const u8, relative: []const u8, buffer: []u8) ?[]const u8 {
    const separator: []const u8 = if (root.len == 1) "" else "/";
    return std.fmt.bufPrint(
        buffer,
        "{s}{s}{s}",
        .{ root, separator, relative },
    ) catch null;
}

/// The part of `path` below `anchor`, or null when it lies elsewhere.
fn relativeTo(anchor: []const u8, path: []const u8) ?[]const u8 {
    if (anchor.len == 1) {
        return if (path.len > 1) path[1..] else null;
    }

    if (path.len <= anchor.len + 1 or !std.mem.startsWith(
        u8,
        path,
        anchor,
    ) or path[anchor.len] != '/') {
        return null;
    }

    return path[anchor.len + 1 ..];
}

/// Writes `word` so a POSIX shell reads it back unchanged: plain words go
/// as they are, others in single quotes, and a leading `-` becomes `./-`
/// so no command reads the path as an option.
fn quote(word: []const u8, buffer: *[max_text_bytes]u8) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (word[0] == '-') {
        writer.writeAll("./") catch return null;
    }

    if (isPlain(word)) {
        writer.writeAll(word) catch return null;
        return writer.buffered();
    }

    writer.writeByte('\'') catch return null;
    for (word) |byte| {
        if (byte == '\'') {
            writer.writeAll("'\\''") catch return null;
        } else {
            writer.writeByte(byte) catch return null;
        }
    }

    writer.writeByte('\'') catch return null;
    return writer.buffered();
}

fn isPlain(word: []const u8) bool {
    for (word) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(
            u8,
            plain_bytes,
            byte,
        ) == null) {
            return false;
        }
    }

    return true;
}

/// The query the wire accepts: at most `max_path_query_bytes`, cut on a
/// UTF-8 boundary.
fn boundedQuery(text: []const u8) []const u8 {
    if (text.len <= core.max_path_query_bytes) {
        return text;
    }

    var len: usize = core.max_path_query_bytes;
    while (len > 0 and (text[len] & 0xc0) == 0x80) {
        len -= 1;
    }

    return text[0..len];
}

fn stateWith(paths: []const []const u8) !data.PathPickerState {
    var state: data.PathPickerState = .{};
    state.begin(@enumFromInt(3), "/work/app");
    state.expect(9);

    var matches: [4]core.PathMatch = undefined;
    for (paths, 0..) |relative, index| {
        matches[index] = .{
            .path = relative,
            .kind = if (relative[relative.len - 1] == '/') .directory else .file,
        };
    }

    var buffer: [1024]u8 = undefined;
    const encoded = try core.encodePathResults(&buffer, .{
        .request_id = @enumFromInt(9),
        .root = "/work/app",
        .matches = matches[0..paths.len],
    });
    _ = try state.receive((try core.decodeServer(encoded)).path_results);
    return state;
}

test "inserted paths are relative to the pane's directory and quoted for the shell" {
    var state = try stateWith(&.{ "src/main.zig", "my docs/", "-rf", "it's.txt" });
    var buffer: [max_text_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("src/main.zig", insertion(
        &state,
        .{
            .selection = 0,
            .absolute = false,
        },
        &buffer,
    ).?);
    try std.testing.expectEqualStrings("/work/app/src/main.zig", insertion(
        &state,
        .{
            .selection = 0,
            .absolute = true,
        },
        &buffer,
    ).?);
    try std.testing.expectEqualStrings("'my docs/'", insertion(
        &state,
        .{
            .selection = 1,
            .absolute = false,
        },
        &buffer,
    ).?);
    try std.testing.expectEqualStrings("./-rf", insertion(
        &state,
        .{
            .selection = 2,
            .absolute = false,
        },
        &buffer,
    ).?);
    try std.testing.expectEqualStrings("'it'\\''s.txt'", insertion(
        &state,
        .{
            .selection = 3,
            .absolute = false,
        },
        &buffer,
    ).?);
}

test "a root above the pane's directory inserts absolute paths" {
    var state = try stateWith(&.{"notes.md"});
    state.anchor_len = 0;
    @memcpy(state.anchor[0.."/work/app/src".len], "/work/app/src");
    state.anchor_len = "/work/app/src".len;

    var buffer: [max_text_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/work/app/notes.md", insertion(
        &state,
        .{
            .selection = 0,
            .absolute = false,
        },
        &buffer,
    ).?);
}

test "a picker opened above the cursor moves the selection the way its rows run" {
    try std.testing.expectEqual(data.PromptCommand.move_down, onScreen(.move_down, false));
    try std.testing.expectEqual(data.PromptCommand.move_up, onScreen(.move_down, true));
    try std.testing.expectEqual(data.PromptCommand.move_down, onScreen(.move_up, true));
    try std.testing.expectEqual(data.PromptCommand.tab, onScreen(.tab, true));
}

test "long queries are cut on a character boundary" {
    const text = "a" ** (core.max_path_query_bytes - 1) ++ "é";
    try std.testing.expectEqual(@as(usize, core.max_path_query_bytes - 1), boundedQuery(text).len);
    try std.testing.expectEqualStrings("abc", boundedQuery("abc"));
}
