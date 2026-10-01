//! The open pick list's disposable state: which configured pick it shows,
//! its options once they arrive, why they could not, and the commands in
//! flight. A command's completion names its execution; one that no longer
//! matches finds nothing here and is dropped.
const std = @import("std");
const PickItems = @import("../bars/PickItems.zig");
const PanelHeading = @import("../bars/PanelHeading.zig");
const bar_text = @import("../bars/bar_text.zig");
const command_execution = @import("../bars/command_execution.zig");
const PickOpening = @import("PickOpening.zig");
const Prompt = @import("Prompt.zig");
const PickListState = @This();

/// Room for why a list command failed, its own words included.
pub const max_error_bytes = 512;

pub const Phase = enum {
    closed,
    loading,
    ready,
    failed,
};

revision: u64 = 0,
phase: Phase = .closed,
/// The configured pick, valid for `generation` only.
index: u8 = 0,
generation: u64 = 0,
/// The palette opening that shows this list; another prompt replacing it
/// closes the list.
prompt_generation: u64 = 0,
/// The pick's title, which the palette shows above its keys.
title_bytes: [PanelHeading.max_title_bytes]u8 = undefined,
title_len: u8 = 0,
items: PickItems = .{},
error_text: [max_error_bytes]u8 = undefined,
error_len: u16 = 0,
/// The list command whose options this list waits for.
listing: command_execution.Id = .none,
/// The `on_select` command running after a choice; it outlives the list,
/// so it keeps its own pick and generation.
selecting: command_execution.Id = .none,
selecting_index: u8 = 0,
selecting_generation: u64 = 0,
next_execution_id: u64 = 1,

/// Starts a list for one configured pick with no options yet.
///
/// ```zig
/// model.pick_list.begin(.{ .index = index, .generation = generation, .prompt_generation = prompt.generation, .title = title });
/// ```
pub fn begin(self: *PickListState, opening: PickOpening) void {
    std.debug.assert(opening.title.len <= self.title_bytes.len);
    self.phase = .loading;
    self.index = opening.index;
    self.generation = opening.generation;
    self.prompt_generation = opening.prompt_generation;
    @memcpy(self.title_bytes[0..opening.title.len], opening.title);
    self.title_len = @intCast(opening.title.len);
    self.items.clear();
    self.error_len = 0;
    self.listing = .none;
    self.revision +%= 1;
}

/// Closes the list; its list command lands into nothing, a running
/// `on_select` still reports. Example: `model.pick_list.close();`
pub fn close(self: *PickListState) void {
    if (self.phase == .closed) {
        return;
    }

    self.phase = .closed;
    self.listing = .none;
    self.items.clear();
    self.revision +%= 1;
}

/// Reserves the identity of the next command this list starts.
/// Example: `model.pick_list.listing = model.pick_list.reserve();`
pub fn reserve(self: *PickListState) command_execution.Id {
    const id: command_execution.Id = @enumFromInt(self.next_execution_id);
    self.next_execution_id +%= 1;

    if (self.next_execution_id == 0) {
        self.next_execution_id = 1;
    }

    return id;
}

/// Shows the options that arrived. Example: `model.pick_list.show();`
pub fn show(self: *PickListState) void {
    self.phase = .ready;
    self.listing = .none;
    self.revision +%= 1;
}

/// Shows why the options could not be listed, cut at a character to the
/// bytes it keeps. Example: `model.pick_list.fail("the list command timed out");`
pub fn fail(self: *PickListState, reason: []const u8) void {
    const kept = bar_text.prefix(reason, max_error_bytes);
    @memcpy(self.error_text[0..kept.len], kept);
    self.error_len = @intCast(kept.len);
    self.phase = .failed;
    self.listing = .none;
    self.items.clear();
    self.revision +%= 1;
}

pub fn title(self: *const PickListState) []const u8 {
    return self.title_bytes[0..self.title_len];
}

pub fn errorSlice(self: *const PickListState) []const u8 {
    return self.error_text[0..self.error_len];
}

/// Whether a list is open for the configured pick `index` of `generation`.
/// Example: `if (!model.pick_list.shows(index, generation)) return;`
pub fn shows(self: *const PickListState, index: u8, generation: u64) bool {
    return self.phase != .closed and self.index == index and self.generation == generation;
}

/// Whether the prompt on screen is the palette opening this list; any
/// other prompt, or none, means the list was replaced.
/// Example: `if (!model.pick_list.shownBy(model.name_prompt.currentConst())) model.pick_list.close();`
pub fn shownBy(self: *const PickListState, prompt: ?*const Prompt) bool {
    const current = prompt orelse return false;
    return self.phase != .closed and current.target() == .pick and current.generation == self.prompt_generation;
}

pub fn version(self: *const PickListState) u64 {
    return self.revision;
}

test "a list closes once, keeps the running selection and fails with a bounded reason" {
    var state: PickListState = .{};
    state.begin(.{
        .index = 2,
        .generation = 7,
        .prompt_generation = 1,
        .title = "Pi model",
    });
    try std.testing.expectEqualStrings("Pi model", state.title());
    state.listing = state.reserve();
    state.selecting = state.reserve();
    try std.testing.expect(state.shows(2, 7));
    try std.testing.expect(!state.shows(2, 8));

    state.fail("x" ** (max_error_bytes + 10));
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expectEqual(@as(usize, max_error_bytes), state.errorSlice().len);
    state.fail("x" ++ "é" ** max_error_bytes);
    try std.testing.expectEqual(@as(usize, max_error_bytes - 1), state.errorSlice().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.errorSlice()));
    try std.testing.expectEqual(command_execution.Id.none, state.listing);

    const before = state.version();
    state.close();
    state.close();
    try std.testing.expectEqual(before + 1, state.version());
    try std.testing.expect(state.selecting != .none);
    try std.testing.expect(!state.shows(2, 7));
}
