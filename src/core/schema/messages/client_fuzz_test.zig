//! Native fuzzing of `decodeClient`, the decoder of every message a client
//! sends the runtime after the handshake.
//!
//! This root imports `telar-core` and runs only through
//! `zig build test-fuzz-ipc-client`. The ordinary suites, and the coverage
//! build that compiles them with `-ffuzz`, never reach its
//! `std.testing.fuzz` call, for the reasons `handshake_fuzz_test.zig` gives.
//!
//! The fuzzer mutates whole payloads. The decoder decides what it accepts;
//! the properties below only check what any answer owes:
//!
//! - an empty payload is rejected as `Truncated`, and a first byte that is no
//!   client tag as `UnknownMessage`;
//! - an accepted payload decodes to the variant its tag names and borrows
//!   only bytes of its body; cut short it is rejected as `Truncated`, and
//!   with one more byte as `TrailingBytes`, except pane input, whose bytes
//!   run to the end of the payload;
//! - every iterator of an accepted view yields exactly its declared count,
//!   borrows only the view's encoded bytes and consumes all of them, within
//!   the schema's budgets; a client layout never fails to iterate, since the
//!   decoder validated every tree before accepting it;
//! - a launch or import iterator rejects an item only with an error that
//!   item's bytes justify, from a closed list per iterator;
//! - an accepted message whose items all pass their iterators is accepted by
//!   its production encoder, decodes back to an equal message, and encodes
//!   again to the same bytes, except for the divergences in
//!   `known_divergences`, each an exact tag, encoder error and condition on
//!   the message, pinned by a regression test. When an item is rejected or a
//!   divergence excused, the round trip is skipped for the whole message.

const std = @import("std");
const bytecodec = @import("bytecodec");
const core = @import("telar-core");

const schema = core.root;
const ClientTag = schema.ClientTag;
const ClientMessage = schema.ClientMessage;
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;

/// The errors `decodeClient` may answer.
const ClientDecodeError = @typeInfo(@typeInfo(@TypeOf(schema.decodeClient)).@"fn".return_type.?).error_union.error_set;

/// Longest payload the fuzzer builds. It holds every seed, a client layout
/// with the most nodes a tab may have and a launch with the most arguments
/// and environment entries; the byte budgets beyond it (argument,
/// environment, input and import command bytes) are checked by the
/// deterministic tests at the end of this file instead of every iteration.
const payload_capacity = 4 * 1024;

/// Room to re-encode an accepted payload. An encoding longer than the
/// payload it came from is reported as a broken property, not a full buffer.
const reencode_capacity = 2 * payload_capacity;

/// Bytes of the little-endian length `std.testing.Smith.slice` reads before
/// the payload, so a seed and a saved crash share one form.
const smith_length_bytes = @sizeOf(u32);

const seed_capacity = 160;

/// Inputs a campaign saved, in the Smith form it saves them, replayed with
/// the seeds by every run. A failure found while fuzzing joins as
/// `@embedFile("client_fuzz_<finding>.bin")` next to this file, so a plain
/// `zig build test-fuzz-ipc-client` reproduces it.
const saved_inputs = [_][]const u8{};
const seed_storage_capacity = 32 * 1024;

/// A payload the fuzzer starts from and what `decodeClient` answers for it;
/// a null outcome is an accepted message.
const ClientSeed = struct {
    name: []const u8,
    payload: []const u8,
    outcome: ?ClientDecodeError,
};

/// Whether the seed corpus reaches a tag with a message the decoder accepts,
/// only with rejected payloads, or not at all.
const SeedCoverage = enum {
    accepted,
    rejected_only,
    none,
};

/// The seed coverage this file claims for `tag`. The switch is exhaustive,
/// so a new client tag fails to compile until it is claimed, and the test
/// "the seed corpus covers the tags it claims" derives the same answer from
/// the corpus, so the claim cannot drift from the seeds.
fn claimedCoverage(tag: ClientTag) SeedCoverage {
    return switch (tag) {
        .execution_request,
        .report_limit,
        .query_limits,
        .query_clients,
        .detach_client,
        .request_client_command,
        .complete_client_command,
        .open_pane,
        .pane_input,
        .pane_resize,
        .frame_ack,
        .request_snapshot,
        .detach_pane,
        .runtime_stop,
        .request_tab_snapshot,
        .create_pane,
        .close_pane,
        .query_history,
        .request_workspace_snapshot,
        .create_tab,
        .rename_tab,
        .close_tab,
        .move_tab,
        .request_graphics_snapshot,
        .graphics_credit,
        .configure_graphics,
        .request_runtime_state,
        .create_workspace,
        .rename_workspace,
        .set_pane_viewport,
        .copy_selection,
        .show_notification,
        .update_client_layout,
        .acknowledge_agent,
        .query_agents,
        .read_pane,
        .send_pane_text,
        .report_agent_session,
        .report_agent,
        .search_pane,
        .import_history,
        .delete_history,
        .prune_history,
        .read_history_output,
        .history_stats,
        .request_pane_focus,
        .complete_pane_focus,
        .suggest_command,
        .report_agent_command,
        .report_agent_title,
        .configure_terminal_colors,
        .configure_frame_interval,
        .open_editor,
        .find_paths,

        .register_worktree,
        .launch_worktree,
        .forget_worktree,
        .interrupt_agent,
        .report_agent_progress,
        .launch_tab,
        .verify_pane_descent,
        => .accepted,
    };
}

/// A message `decodeClient` accepts and its production encoder refuses with
/// `encoder_error`, found by this target and not settled in production yet.
const KnownDivergence = struct {
    name: []const u8,
    tag: ClientTag,
    encoder_error: anyerror,
    /// Whether a decoded message shows exactly this divergence; the same
    /// encoder error for any other reason is not excused.
    holds: *const fn (message: ClientMessage) bool,
    /// The smallest synthetic payload that shows it.
    payload: []const u8,
};

/// The only exceptions to the round-trip property, each an exact tag,
/// encoder error and condition on the decoded message. The test "every known
/// divergence still holds for its payload" fails once an entry stops
/// diverging, so an entry cannot outlive the divergence it records; its
/// payload then belongs in the seed corpus.
const known_divergences = [_]KnownDivergence{
    .{
        .name = "read_history_output of history id 0",
        .tag = .read_history_output,
        .encoder_error = error.InvalidHistoryId,
        .holds = &namesHistoryIdZero,
        .payload = &([_]u8{@intFromEnum(ClientTag.read_history_output)} ++ wireInt(u64, 37) ++ wireInt(u64, 0)),
    },
    .{
        .name = "delete_history of history id 0",
        .tag = .delete_history,
        .encoder_error = error.InvalidHistoryId,
        .holds = &namesHistoryIdZero,
        .payload = &([_]u8{@intFromEnum(ClientTag.delete_history)} ++ wireInt(u64, 35) ++ wireInt(u64, 0)),
    },
    .{
        .name = "import_history of a command holding a NUL",
        .tag = .import_history,
        .encoder_error = error.EmbeddedNul,
        .holds = &importsCommandHoldingNul,
        .payload = &([_]u8{@intFromEnum(ClientTag.import_history)} ++ wireInt(u64, 34) ++ wireSized16("zsh:h") ++
            wireInt(u64, 100) ++ wireInt(u16, 1) ++ wireInt(i64, 1700000002000) ++ wireSized16("a\x00b")),
    },
};

fn wireInt(comptime T: type, comptime value: T) [@sizeOf(T)]u8 {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(
        T,
        &bytes,
        value,
        .little,
    );
    return bytes;
}

fn wireSized16(comptime bytes: []const u8) [@sizeOf(u16) + bytes.len]u8 {
    return wireInt(u16, bytes.len) ++ bytes[0..bytes.len].*;
}

/// A history id of 0 in the two messages whose shared derived decoder
/// accepts it.
fn namesHistoryIdZero(message: ClientMessage) bool {
    return switch (message) {
        .read_history_output => |value| value.id == 0,
        .delete_history => |value| value.id == 0,
        else => false,
    };
}

/// A source the encoder accepts (non-empty, within
/// `max_import_source_bytes`, no NUL) and at least one command holding a
/// NUL, which `ImportEntryIterator` passes and `encodeImportHistory` refuses.
fn importsCommandHoldingNul(message: ClientMessage) bool {
    const view = switch (message) {
        .import_history => |value| value,
        else => return false,
    };
    if (view.source.len == 0 or view.source.len > schema.max_import_source_bytes) {
        return false;
    }

    if (holdsByte(view.source, 0)) {
        return false;
    }

    var entries = view.entries();
    var holds_nul = false;
    while (entries.next() catch return false) |entry| {
        holds_nul = holds_nul or holdsByte(entry.command, 0);
    }

    return holds_nul;
}

fn holdsByte(bytes: []const u8, byte: u8) bool {
    return std.mem.findScalar(u8, bytes, byte) != null;
}

fn isKnownDivergence(tag: ClientTag, message: ClientMessage, err: anyerror) bool {
    for (known_divergences) |divergence| {
        if (divergence.tag == tag and divergence.encoder_error == err and divergence.holds(message)) {
            return true;
        }
    }

    return false;
}

/// Seed payloads kept in Smith form: each entry is a little-endian length
/// followed by its payload, which `seeds` borrows.
const ClientSeeds = struct {
    storage: [seed_storage_capacity]u8 = undefined,
    used: usize = 0,
    seeds: [seed_capacity]ClientSeed = undefined,
    corpus: [seed_capacity][]const u8 = undefined,
    count: usize = 0,

    /// Free storage for the next payload, past room for its length, so an
    /// encoder can write a seed in place.
    fn space(self: *ClientSeeds) []u8 {
        return self.storage[self.used + smith_length_bytes ..];
    }

    fn accept(self: *ClientSeeds, name: []const u8, payload: []const u8) void {
        self.add(
            name,
            payload,
            null,
        );
    }

    fn reject(self: *ClientSeeds, name: []const u8, payload: []const u8, outcome: ClientDecodeError) void {
        self.add(
            name,
            payload,
            outcome,
        );
    }

    /// Commits `payload`, which may already sit at `space()` or anywhere in
    /// committed storage.
    fn add(self: *ClientSeeds, name: []const u8, payload: []const u8, outcome: ?ClientDecodeError) void {
        const entry = self.storage[self.used..][0 .. smith_length_bytes + payload.len];
        @memmove(entry[smith_length_bytes..], payload);
        std.mem.writeInt(
            u32,
            entry[0..smith_length_bytes],
            @intCast(payload.len),
            .little,
        );
        self.seeds[self.count] = .{
            .name = name,
            .payload = entry[smith_length_bytes..],
            .outcome = outcome,
        };
        self.corpus[self.count] = entry;
        self.count += 1;
        self.used += entry.len;
    }

    /// Starts a hand-written payload with its tag at `space()`.
    fn begin(self: *ClientSeeds, tag: ClientTag) Encoder {
        var encoder = Encoder.init(self.space());
        encoder.writeByte(@intFromEnum(tag)) catch unreachable;
        return encoder;
    }

    /// Copies `base` followed by `tail` to `space()`.
    fn extended(self: *ClientSeeds, base: []const u8, tail: []const u8) []const u8 {
        const payload = self.space()[0 .. base.len + tail.len];
        @memcpy(payload[0..base.len], base);
        @memcpy(payload[base.len..], tail);
        return payload;
    }

    fn committed(self: *const ClientSeeds) []const ClientSeed {
        return self.seeds[0..self.count];
    }
};

/// What re-encoding one accepted message needs besides its bytes: the items
/// its views iterate, gathered into the owned values the encoders take.
const Reencoding = struct {
    bytes: [reencode_capacity]u8,
    arguments: [schema.max_argument_count][]const u8,
    environment: [schema.max_environment_count]schema.EnvironmentEntry,
    imports: [schema.max_import_entries]schema.ImportEntry,
    tabs: [schema.max_client_layout_tabs]schema.ClientTabLayout,
    nodes: [schema.max_client_layout_nodes]schema.ClientLayoutNode,
};

/// Scratch memory for one property check, kept out of the stack so a Debug
/// build does not fill it on every fuzz iteration.
const PropertyScratch = struct {
    extended: [payload_capacity + 1]u8,
    first: Reencoding,
    second: Reencoding,
};

var client_seeds: ClientSeeds = .{};
var property_scratch: PropertyScratch = undefined;

const location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(7) },
    .tab_id = @enumFromInt(3),
};

const size: schema.TerminalSize = .{
    .cols = 80,
    .rows = 24,
};

const shell_arguments = [_][]const u8{ "/bin/sh", "-l" };

const fixture_environment = [_]schema.EnvironmentEntry{
    .{
        .name = "TERM",
        .value = "xterm-256color",
    },
    .{
        .name = "EMPTY",
        .value = "",
    },
};

const fixture_launch: schema.Launch = .{
    .cwd = "/work",
    .cwd_source = @enumFromInt(5),
    .arguments = &shell_arguments,
    .environment_mode = .replace,
    .environment = &fixture_environment,
};

const most_arguments = [_][]const u8{"/bin/sh"} ++ [_][]const u8{"x"} ** (schema.max_argument_count - 1);
const too_many_arguments = most_arguments ++ [_][]const u8{"x"};

const most_environment = [_]schema.EnvironmentEntry{.{
    .name = "K",
    .value = "",
}} ** schema.max_environment_count;
const too_much_environment = most_environment ++ [_]schema.EnvironmentEntry{.{
    .name = "K",
    .value = "",
}};

const most_imports = [_]schema.ImportEntry{.{
    .started_at_ms = 1700000002000,
    .command = "ls",
}} ** schema.max_import_entries;
const too_many_imports = most_imports ++ [_]schema.ImportEntry{.{
    .started_at_ms = 1700000002000,
    .command = "ls",
}};

const split_nodes = [_]schema.ClientLayoutNode{
    .{ .split = .{
        .axis = .horizontal,
        .ratio = 6000,
    } },
    .{ .pane = .{ .id = @enumFromInt(5) } },
    .{ .pane = .{ .id = @enumFromInt(6) } },
};

/// Every byte value that names no client tag, in increasing order.
const unassigned_tags = unassigned: {
    @setEvalBranchQuota(std.math.maxInt(u8) * @typeInfo(ClientTag).@"enum".fields.len * 4);
    var bytes: []const u8 = &.{};
    for (0..std.math.maxInt(u8) + 1) |value| {
        if (std.enums.fromInt(ClientTag, value) == null) {
            bytes = bytes ++ [_]u8{value};
        }
    }

    break :unassigned bytes;
};

/// The first byte above the lowest client tag that names none: a gap inside
/// the client range rather than past either end of it.
const tag_range_gap = gap: {
    const lowest = std.mem.min(u8, &tagValues());
    for (unassigned_tags) |value| {
        if (value > lowest) {
            break :gap value;
        }
    }

    unreachable;
};

fn tagValues() [@typeInfo(ClientTag).@"enum".fields.len]u8 {
    var values: [@typeInfo(ClientTag).@"enum".fields.len]u8 = undefined;
    for (@typeInfo(ClientTag).@"enum".fields, &values) |field, *value| {
        value.* = field.value;
    }

    return values;
}

/// The balanced-to-the-right tree with the most nodes a tab may carry:
/// every split's first child is a pane and its second the next split.
fn largestLayoutNodes() [schema.max_client_layout_tab_nodes]schema.ClientLayoutNode {
    var nodes: [schema.max_client_layout_tab_nodes]schema.ClientLayoutNode = undefined;
    const split_count = (schema.max_client_layout_tab_nodes - 1) / 2;
    for (0..split_count) |index| {
        nodes[2 * index] = .{ .split = .{
            .axis = .vertical,
            .ratio = 5000,
        } };
        nodes[2 * index + 1] = .{ .pane = .{ .id = @enumFromInt(index + 1) } };
    }

    nodes[schema.max_client_layout_tab_nodes - 1] = .{ .pane = .{ .id = @enumFromInt(split_count + 1) } };
    return nodes;
}

/// Writes a launch body field by field without the encoder's validation,
/// so a seed can carry counts, bytes and budgets the encoder refuses.
fn writeRawLaunch(encoder: *Encoder, launch: schema.Launch) !void {
    try encoder.writeSized16(launch.cwd);
    try encoder.writeInt(u64, if (launch.cwd_source) |pane_id| @intFromEnum(pane_id) else 0);
    try encoder.writeInt(u16, @intCast(launch.arguments.len));
    for (launch.arguments) |argument| {
        try encoder.writeSized16(argument);
    }

    try encoder.writeByte(@intFromEnum(launch.environment_mode));
    try encoder.writeInt(u16, @intCast(launch.environment.len));
    for (launch.environment) |entry| {
        try encoder.writeSized16(entry.name);
        try encoder.writeSized32(entry.value);
    }
}

/// Writes an `open_pane` for the default target up to its launch body.
fn writeOpenPaneHeader(encoder: *Encoder) !void {
    try encoder.writeInt(u64, 9);
    try encoder.writeByte(0);
    try writeRawSize(encoder, size);
}

fn writeRawSize(encoder: *Encoder, terminal_size: schema.TerminalSize) !void {
    try encoder.writeInt(u16, terminal_size.cols);
    try encoder.writeInt(u16, terminal_size.rows);
    try encoder.writeInt(u16, terminal_size.cell_width_px);
    try encoder.writeInt(u16, terminal_size.cell_height_px);
}

fn writeRawTabLocation(encoder: *Encoder, tab_location: schema.TabLocation) !void {
    switch (tab_location.workspace) {
        .workspace => |workspace_id| {
            try encoder.writeByte(0);
            try encoder.writeInt(u64, @intFromEnum(workspace_id));
        },
        .worktree => |worktree_id| {
            try encoder.writeByte(1);
            try encoder.writeInt(u64, @intFromEnum(worktree_id));
        },
    }

    try encoder.writeInt(u64, @intFromEnum(tab_location.tab_id));
}

/// Writes a layout update body without the encoder's tree validation.
fn writeRawLayout(encoder: *Encoder, update: schema.ClientLayoutUpdate) !void {
    try encoder.writeByte(@intFromBool(update.sidebar_visible));
    try encoder.writeInt(u16, update.sidebar_width);
    try encoder.writeByte(@intFromBool(update.workspace_list_collapsed));
    try writeRawTabLocation(encoder, update.active_tab);
    try encoder.writeInt(u16, @intCast(update.tabs.len));
    for (update.tabs) |tab| {
        try writeRawTabLocation(encoder, tab.location);
        try encoder.writeInt(u64, @intFromEnum(tab.focused_pane));
        try encoder.writeByte(@intFromBool(tab.fullscreen));
        try encoder.writeByte(@intFromBool(tab.workspace_active));
        try encoder.writeInt(u16, @intCast(tab.nodes.len));
        for (tab.nodes) |node| {
            try writeRawLayoutNode(encoder, node);
        }
    }
}

fn writeRawLayoutNode(encoder: *Encoder, node: schema.ClientLayoutNode) !void {
    switch (node) {
        .pane => |pane| {
            try encoder.writeByte(0);
            try encoder.writeInt(u64, @intFromEnum(pane.id));
        },
        .split => |split| {
            try encoder.writeByte(1);
            try encoder.writeByte(@intFromEnum(split.axis));
            try encoder.writeInt(u16, split.ratio);
        },
    }
}

/// A one-tab layout update around `nodes`, focused on `focused_pane`.
fn singleTabLayout(tabs: *[1]schema.ClientTabLayout, nodes: []const schema.ClientLayoutNode, focused_pane: schema.PaneId) schema.ClientLayoutUpdate {
    tabs[0] = .{
        .location = location,
        .focused_pane = focused_pane,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = nodes,
    };
    return .{
        .sidebar_visible = true,
        .sidebar_width = 73,
        .workspace_list_collapsed = false,
        .active_tab = location,
        .tabs = tabs,
    };
}

/// Resets `seeds` and fills it with one accepted payload per client tag,
/// variants of the messages with optional parts, collections and launches,
/// and rejected payloads for every kind of inconsistency the decoder names.
fn addClientSeeds(seeds: *ClientSeeds) !void {
    seeds.* = .{};
    try addPaneSeeds(seeds);
    try addLaunchSeeds(seeds);
    try addTabAndWorkspaceSeeds(seeds);
    try addHistorySeeds(seeds);
    try addLayoutSeeds(seeds);
    try addAgentSeeds(seeds);
    try addClientAndRuntimeSeeds(seeds);
    try addEnvelopeSeeds(seeds);
}

fn addPaneSeeds(seeds: *ClientSeeds) !void {
    seeds.accept(
        "open_pane attach",
        try schema.encodeOpenPane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(2),
                .target = .{ .pane = @enumFromInt(41) },
                .size = size,
                .launch = null,
            },
        ),
    );
    seeds.accept(
        "open_pane workspace",
        try schema.encodeOpenPane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(3),
                .target = .{ .workspace = @enumFromInt(7) },
                .size = size,
                .launch = null,
            },
        ),
    );
    seeds.accept(
        "pane_input",
        try schema.encodePaneInput(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(3),
                .bytes = "abc",
            },
        ),
    );
    seeds.accept(
        "pane_resize",
        try schema.encodePaneResize(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(3),
                .size = .{
                    .cols = 90,
                    .rows = 30,
                },
            },
        ),
    );
    seeds.accept(
        "frame_ack",
        try schema.encodeFrameAck(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(3),
                .frame_id = 8,
            },
        ),
    );
    seeds.accept(
        "request_snapshot",
        try schema.encodeRequestSnapshot(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(3),
                .known_frame_id = 7,
            },
        ),
    );
    seeds.accept("detach_pane", try schema.encodeDetachPane(seeds.space(), .{ .pane_id = @enumFromInt(3) }));
    seeds.accept(
        "close_pane",
        try schema.encodeClosePane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(22),
                .pane_id = @enumFromInt(8),
            },
        ),
    );
    seeds.accept(
        "set_pane_viewport",
        try schema.encodeSetPaneViewport(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(5),
                .offset = 42,
            },
        ),
    );
    seeds.accept(
        "copy_selection",
        try schema.encodeCopySelection(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(5),
                .start_x = 1,
                .start_y = 2,
                .end_x = 3,
                .end_y = 4,
                .linewise = true,
            },
        ),
    );
    seeds.accept(
        "read_pane",
        try schema.encodeReadPane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .rows = 40,
                .source = .recent,
            },
        ),
    );
    seeds.accept(
        "send_pane_text prompt",
        try schema.encodeSendPaneText(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .mode = .prompt,
                .text = "ls",
            },
        ),
    );
    seeds.accept(
        "send_pane_text raw_enter without text",
        try schema.encodeSendPaneText(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .mode = .raw_enter,
                .text = "",
            },
        ),
    );
    seeds.accept(
        "send_pane_text with sender",
        try schema.encodeSendPaneText(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .mode = .prompt,
                .text = "ls",
                .sender = @enumFromInt(9),
            },
        ),
    );
    seeds.accept(
        "search_pane",
        try schema.encodeSearchPane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .needle = "err",
            },
        ),
    );
    seeds.accept("request_graphics_snapshot", try schema.encodeRequestGraphicsSnapshot(seeds.space(), .{ .pane_id = @enumFromInt(5) }));
    seeds.accept(
        "graphics_credit",
        try schema.encodeGraphicsCredit(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(5),
                .bytes = 4096,
            },
        ),
    );
    seeds.accept("configure_graphics", try schema.encodeConfigureGraphics(seeds.space(), .{ .shared = true }));
    seeds.accept("configure_frame_interval", try schema.encodeConfigureFrameInterval(seeds.space(), .{ .interval_ns = schema.min_frame_interval_ns }));
    seeds.accept(
        "request_pane_focus",
        try schema.encodeRequestPaneFocus(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .direction = .left,
            },
        ),
    );
    seeds.accept(
        "complete_pane_focus",
        try schema.encodeCompletePaneFocus(
            seeds.space(),
            .{
                .requester = .{
                    .id = 9,
                    .generation = 10,
                },
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .outcome = .focused,
                .focused_pane_id = @enumFromInt(6),
            },
        ),
    );
    seeds.accept(
        "open_editor",
        try schema.encodeOpenEditor(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(6),
                .pane_generation = 7,
                .editor = "nvim",
                .path = "/tmp/a",
                .line = 12,
                .column = 3,
            },
        ),
    );
    seeds.accept(
        "find_paths",
        try schema.encodeFindPaths(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .root = "/w",
                .query = "ab",
                .kind = .files,
                .limit = 20,
                .refresh = true,
            },
        ),
    );

    var encoder = seeds.begin(.pane_input);
    try encoder.writeInt(u64, 3);
    seeds.reject(
        "pane_input without bytes",
        encoder.finish(),
        error.InvalidInputLength,
    );

    encoder = seeds.begin(.detach_pane);
    try encoder.writeInt(u64, 0);
    seeds.reject(
        "detach_pane of pane zero",
        encoder.finish(),
        error.InvalidPaneId,
    );

    encoder = seeds.begin(.close_pane);
    try encoder.writeInt(u64, 0);
    try encoder.writeInt(u64, 8);
    seeds.reject(
        "close_pane with request zero",
        encoder.finish(),
        error.InvalidRequestId,
    );

    encoder = seeds.begin(.frame_ack);
    try encoder.writeInt(u64, 3);
    try encoder.writeInt(u64, 0);
    seeds.reject(
        "frame_ack of frame zero",
        encoder.finish(),
        error.InvalidFrameId,
    );

    encoder = seeds.begin(.graphics_credit);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 0);
    seeds.reject(
        "graphics_credit of zero bytes",
        encoder.finish(),
        error.InvalidGraphicsCredit,
    );

    encoder = seeds.begin(.open_pane);
    try encoder.writeInt(u64, 2);
    try encoder.writeByte(3);
    seeds.reject(
        "open_pane with an unknown target",
        encoder.finish(),
        error.InvalidPaneTarget,
    );

    encoder = seeds.begin(.open_pane);
    try encoder.writeInt(u64, 2);
    try encoder.writeByte(1);
    try encoder.writeInt(u64, 41);
    try writeRawSize(
        &encoder,
        .{
            .cols = 0,
            .rows = 24,
        },
    );
    seeds.reject(
        "open_pane with no columns",
        encoder.finish(),
        error.InvalidTerminalSize,
    );

    encoder = seeds.begin(.send_pane_text);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 3);
    try encoder.writeByte(@intFromEnum(schema.PaneTextMode.prompt));
    try encoder.writeSized32("");
    seeds.reject(
        "send_pane_text prompt without text",
        encoder.finish(),
        error.InvalidByteString,
    );

    encoder = seeds.begin(.search_pane);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 5);
    try encoder.writeSized16("\xff");
    seeds.reject(
        "search_pane with an invalid UTF-8 needle",
        encoder.finish(),
        error.InvalidUtf8,
    );

    encoder = seeds.begin(.open_editor);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 6);
    try encoder.writeInt(u64, 7);
    try encoder.writeSized16("nvim");
    try encoder.writeSized16("/tmp/a");
    try encoder.writeInt(u32, 0);
    try encoder.writeInt(u32, 3);
    seeds.reject(
        "open_editor with a column but no line",
        encoder.finish(),
        error.InvalidEditorTarget,
    );

    encoder = seeds.begin(.find_paths);
    try encoder.writeInt(u64, 5);
    try encoder.writeSized16("work");
    try encoder.writeSized16("");
    try encoder.writeByte(@intFromEnum(schema.PathKindFilter.any));
    try encoder.writeInt(u16, 20);
    try encoder.writeByte(0);
    seeds.reject(
        "find_paths under a relative root",
        encoder.finish(),
        error.InvalidPathRoot,
    );
}

fn addLaunchSeeds(seeds: *ClientSeeds) !void {
    seeds.accept(
        "open_pane default",
        try schema.encodeOpenPane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(9),
                .size = size,
                .launch = fixture_launch,
            },
        ),
    );
    seeds.accept(
        "create_pane",
        try schema.encodeCreatePane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(21),
                .location = location,
                .size = size,
                .launch = .{
                    .cwd = "/work",
                    .arguments = &.{"/bin/sh"},
                },
            },
        ),
    );
    seeds.accept(
        "open_pane with the most arguments",
        try schema.encodeOpenPane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(9),
                .size = size,
                .launch = .{
                    .cwd = "/work",
                    .arguments = &most_arguments,
                },
            },
        ),
    );
    seeds.accept(
        "open_pane with the most environment entries",
        try schema.encodeOpenPane(
            seeds.space(),
            .{
                .request_id = @enumFromInt(9),
                .size = size,
                .launch = .{
                    .cwd = "/work",
                    .arguments = &shell_arguments,
                    .environment = &most_environment,
                },
            },
        ),
    );

    var encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    seeds.reject(
        "open_pane default without a launch",
        encoder.finish(),
        error.Truncated,
    );

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &too_many_arguments,
        },
    );
    seeds.reject(
        "open_pane with one argument too many",
        encoder.finish(),
        error.InvalidArgumentCount,
    );

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &.{},
        },
    );
    seeds.reject(
        "open_pane without arguments",
        encoder.finish(),
        error.InvalidArgumentCount,
    );

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &shell_arguments,
            .environment = &too_much_environment,
        },
    );
    seeds.reject(
        "open_pane with one environment entry too many",
        encoder.finish(),
        error.TooManyEnvironmentEntries,
    );

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "",
            .arguments = &shell_arguments,
        },
    );
    seeds.reject(
        "open_pane with an empty cwd",
        encoder.finish(),
        error.InvalidByteString,
    );

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try encoder.writeSized16("/work");
    try encoder.writeInt(u64, 0);
    try encoder.writeInt(u16, 1);
    try encoder.writeSized16("/bin/sh");
    try encoder.writeByte(@intFromEnum(schema.EnvironmentMode.replace) + 1);
    try encoder.writeInt(u16, 0);
    seeds.reject(
        "open_pane with an unknown environment mode",
        encoder.finish(),
        error.InvalidEnvironmentMode,
    );

    // The decoder walks a launch's structure only; the iterators reject the
    // content of each item as the consumer reads it.
    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &.{ "/bin/sh", "a\x00b" },
        },
    );
    seeds.accept("open_pane whose argument holds a NUL", encoder.finish());

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &.{""},
        },
    );
    seeds.accept("open_pane whose program is empty", encoder.finish());

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &shell_arguments,
            .environment = &.{.{
                .name = "A=B",
                .value = "1",
            }},
        },
    );
    seeds.accept("open_pane whose environment name holds '='", encoder.finish());

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &shell_arguments,
            .environment = &.{.{
                .name = "K",
                .value = "a\x00b",
            }},
        },
    );
    seeds.accept("open_pane whose environment value holds a NUL", encoder.finish());

    encoder = seeds.begin(.open_pane);
    try writeOpenPaneHeader(&encoder);
    try writeRawLaunch(
        &encoder,
        .{
            .cwd = "/work",
            .arguments = &shell_arguments,
            .environment = &.{.{
                .name = "",
                .value = "1",
            }},
        },
    );
    seeds.accept("open_pane whose environment name is empty", encoder.finish());
}

fn addTabAndWorkspaceSeeds(seeds: *ClientSeeds) !void {
    seeds.accept(
        "request_tab_snapshot",
        try schema.encodeRequestTabSnapshot(
            seeds.space(),
            .{
                .request_id = @enumFromInt(20),
                .location = location,
            },
        ),
    );
    seeds.accept(
        "request_workspace_snapshot",
        try schema.encodeRequestWorkspaceSnapshot(
            seeds.space(),
            .{
                .request_id = @enumFromInt(40),
                .workspace = .{ .workspace = @enumFromInt(7) },
            },
        ),
    );
    seeds.accept(
        "create_tab",
        try schema.encodeCreateTab(
            seeds.space(),
            .{
                .request_id = @enumFromInt(41),
                .workspace = .{ .worktree = @enumFromInt(4) },
                .label = "logs",
                .size = size,
                .launch = fixture_launch,
            },
        ),
    );
    seeds.accept(
        "launch_tab",
        try schema.encodeLaunchTab(
            seeds.space(),
            .{
                .request_id = @enumFromInt(41),
                .workspace = @enumFromInt(7),
                .label = "logs",
                .size = size,
                .launch = .{
                    .cwd = "/work",
                    .arguments = &.{"/bin/sh"},
                },
            },
        ),
    );
    seeds.accept(
        "rename_tab",
        try schema.encodeRenameTab(
            seeds.space(),
            .{
                .request_id = @enumFromInt(42),
                .location = location,
                .label = "server",
            },
        ),
    );
    seeds.accept(
        "close_tab",
        try schema.encodeCloseTab(
            seeds.space(),
            .{
                .request_id = @enumFromInt(43),
                .location = location,
            },
        ),
    );
    seeds.accept(
        "move_tab",
        try schema.encodeMoveTab(
            seeds.space(),
            .{
                .request_id = @enumFromInt(44),
                .location = location,
                .direction = .previous,
            },
        ),
    );
    seeds.accept(
        "move_tab relative to another tab",
        try schema.encodeMoveTab(
            seeds.space(),
            .{
                .request_id = @enumFromInt(44),
                .location = location,
                .direction = .next,
                .relative_to = @enumFromInt(9),
            },
        ),
    );
    seeds.accept(
        "create_workspace",
        try schema.encodeCreateWorkspace(
            seeds.space(),
            .{
                .request_id = @enumFromInt(4),
                .size = size,
                .name = "agents",
                .create_cwd = true,
                .launch = fixture_launch,
            },
        ),
    );
    seeds.accept(
        "rename_workspace",
        try schema.encodeRenameWorkspace(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .workspace = .{ .workspace = @enumFromInt(7) },
                .name = "agents",
            },
        ),
    );
    seeds.accept(
        "register_worktree",
        try schema.encodeRegisterWorktree(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .source = @enumFromInt(7),
                .created_by = @enumFromInt(5),
                .path = "/work/telar-worktrees/fix",
                .branch = "fix",
                .base = "main",
                .title = "Fix tabs",
                .brief = "Reorder tabs",
                .dispatched_from = "laptop",
            },
        ),
    );
    seeds.accept("report_limit", try schema.encodeReportLimit(seeds.space(), .{
        .reach = .{ .limit = .{ .name = "test.limit", .noun = "items", .value = 4 }, .requested = 5 },
        .hits = 1,
    }));
    seeds.accept("query_limits", try schema.encodeQueryLimits(seeds.space(), .{ .request_id = @enumFromInt(5) }));
    seeds.accept("execution_request", try schema.encodeExecutionRequest(seeds.space(), .{
        .request_id = @enumFromInt(5),
        .action = .status,
        .execution_id = 7,
    }));
    seeds.accept(
        "launch_worktree",
        try schema.encodeLaunchWorktree(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .worktree = @enumFromInt(4),
                .label = "tests",
                .size = size,
                .launch = .{
                    .cwd = "/work/telar-worktrees/fix",
                    .arguments = &shell_arguments,
                },
            },
        ),
    );
    seeds.accept(
        "forget_worktree",
        try schema.encodeForgetWorktree(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .worktree = @enumFromInt(4),
            },
        ),
    );

    var encoder = seeds.begin(.rename_tab);
    try encoder.writeInt(u64, 42);
    try writeRawTabLocation(&encoder, location);
    try encoder.writeSized16("\x1b[2J");
    seeds.reject(
        "rename_tab to a label with a control byte",
        encoder.finish(),
        error.InvalidTabLabel,
    );

    encoder = seeds.begin(.move_tab);
    try encoder.writeInt(u64, 44);
    try writeRawTabLocation(&encoder, location);
    try encoder.writeByte(@intFromEnum(schema.TabMoveDirection.next) + 1);
    seeds.reject(
        "move_tab in an unknown direction",
        encoder.finish(),
        error.InvalidTabMoveDirection,
    );

    encoder = seeds.begin(.create_workspace);
    try encoder.writeInt(u64, 4);
    try writeRawSize(&encoder, size);
    try encoder.writeSized16("agents");
    try encoder.writeByte(2);
    seeds.reject(
        "create_workspace with a create_cwd flag of 2",
        encoder.finish(),
        error.InvalidCreateCwdFlag,
    );
}

fn addHistorySeeds(seeds: *ClientSeeds) !void {
    seeds.accept(
        "query_history global",
        try schema.encodeQueryHistory(seeds.space(), .{ .request_id = @enumFromInt(30) }),
    );
    seeds.accept(
        "query_history cwd",
        try schema.encodeQueryHistory(
            seeds.space(),
            .{
                .request_id = @enumFromInt(31),
                .query = "zig build",
                .scope = .cwd,
                .scope_value = "/work/telar",
                .failed_only = true,
                .match = .fuzzy,
                .distinct = true,
                .limit = 12,
            },
        ),
    );
    seeds.accept(
        "query_history pane",
        try schema.encodeQueryHistory(
            seeds.space(),
            .{
                .request_id = @enumFromInt(32),
                .scope = .pane,
                .pane_id = @enumFromInt(9),
            },
        ),
    );
    seeds.accept(
        "import_history",
        try schema.encodeImportHistory(
            seeds.space(),
            .{
                .request_id = @enumFromInt(34),
                .source = "zsh:/home/u/.zsh_history",
                .base_sequence = 100,
                .entries = &.{
                    .{
                        .started_at_ms = 1700000002000,
                        .command = "git status",
                    },
                    .{
                        .started_at_ms = 1700000003000,
                        .command = "make -j4",
                    },
                },
            },
        ),
    );
    seeds.accept(
        "import_history with the most entries",
        try schema.encodeImportHistory(
            seeds.space(),
            .{
                .request_id = @enumFromInt(34),
                .source = "zsh:/home/u/.zsh_history",
                .base_sequence = 100,
                .entries = &most_imports,
            },
        ),
    );
    seeds.accept(
        "delete_history",
        try schema.encodeDeleteHistory(
            seeds.space(),
            .{
                .request_id = @enumFromInt(35),
                .id = 11,
            },
        ),
    );
    seeds.accept(
        "prune_history",
        try schema.encodePruneHistory(
            seeds.space(),
            .{
                .request_id = @enumFromInt(36),
                .scope = .workspace,
                .scope_value = "/work/telar",
                .before_ms = 1700000000000,
                .failed_only = true,
                .match = "zig",
            },
        ),
    );
    seeds.accept(
        "read_history_output",
        try schema.encodeReadHistoryOutput(
            seeds.space(),
            .{
                .request_id = @enumFromInt(37),
                .id = 11,
            },
        ),
    );
    seeds.accept(
        "history_stats",
        try schema.encodeHistoryStatsQuery(
            seeds.space(),
            .{
                .request_id = @enumFromInt(38),
                .scope = .pane,
                .pane_id = @enumFromInt(9),
                .since_ms = 1700000000000,
            },
        ),
    );
    seeds.accept(
        "suggest_command",
        try schema.encodeSuggestCommand(
            seeds.space(),
            .{
                .request_id = @enumFromInt(41),
                .pane_id = @enumFromInt(9),
                .text = "list files by size",
            },
        ),
    );

    var encoder = seeds.begin(.query_history);
    try encoder.writeInt(u64, 30);
    try encoder.writeSized16("");
    try encoder.writeByte(@intFromEnum(schema.HistoryScope.pane) + 1);
    seeds.reject(
        "query_history in an unknown scope",
        encoder.finish(),
        error.InvalidHistoryScope,
    );

    encoder = seeds.begin(.query_history);
    try encoder.writeInt(u64, 30);
    try encoder.writeSized16("");
    try encoder.writeByte(@intFromEnum(schema.HistoryScope.global));
    try encoder.writeByte(0);
    try encoder.writeByte(@intFromEnum(schema.HistoryAuthorFilter.all));
    try encoder.writeByte(@intFromEnum(schema.HistoryMatch.fts));
    try encoder.writeByte(0);
    try encoder.writeInt(u16, 0);
    seeds.reject(
        "query_history for no results",
        encoder.finish(),
        error.InvalidHistoryLimit,
    );

    encoder = seeds.begin(.import_history);
    try encoder.writeInt(u64, 34);
    try encoder.writeSized16("zsh:/home/u/.zsh_history");
    try encoder.writeInt(u64, 100);
    try encoder.writeInt(u16, 0);
    seeds.reject(
        "import_history without entries",
        encoder.finish(),
        error.InvalidImportBatch,
    );

    encoder = seeds.begin(.import_history);
    try encoder.writeInt(u64, 34);
    try encoder.writeSized16("zsh:/home/u/.zsh_history");
    try encoder.writeInt(u64, 100);
    try encoder.writeInt(u16, too_many_imports.len);
    for (too_many_imports) |entry| {
        try encoder.writeInt(i64, entry.started_at_ms);
        try encoder.writeSized16(entry.command);
    }
    seeds.reject(
        "import_history with one entry too many",
        encoder.finish(),
        error.InvalidImportBatch,
    );

    // The decoder bounds command lengths only; the iterator rejects an
    // empty command as the consumer reads it.
    encoder = seeds.begin(.import_history);
    try encoder.writeInt(u64, 34);
    try encoder.writeSized16("zsh:/home/u/.zsh_history");
    try encoder.writeInt(u64, 100);
    try encoder.writeInt(u16, 1);
    try encoder.writeInt(i64, 1700000002000);
    try encoder.writeSized16("");
    seeds.accept("import_history with an empty command", encoder.finish());

    encoder = seeds.begin(.import_history);
    try encoder.writeInt(u64, 34);
    try encoder.writeSized16("zsh:\x00h");
    try encoder.writeInt(u64, 100);
    try encoder.writeInt(u16, 1);
    try encoder.writeInt(i64, 1700000002000);
    try encoder.writeSized16("ls");
    seeds.reject(
        "import_history with a NUL in source",
        encoder.finish(),
        error.EmbeddedNul,
    );
}

fn addLayoutSeeds(seeds: *ClientSeeds) !void {
    var tabs: [1]schema.ClientTabLayout = undefined;
    seeds.accept(
        "update_client_layout",
        try schema.encodeClientLayoutUpdate(
            seeds.space(),
            singleTabLayout(
                &tabs,
                &split_nodes,
                @enumFromInt(5),
            ),
        ),
    );

    const largest_nodes = comptime largestLayoutNodes();
    seeds.accept(
        "update_client_layout with the most nodes",
        try schema.encodeClientLayoutUpdate(
            seeds.space(),
            singleTabLayout(
                &tabs,
                &largest_nodes,
                @enumFromInt(1),
            ),
        ),
    );

    const two_tabs = [_]schema.ClientTabLayout{
        .{
            .location = location,
            .focused_pane = @enumFromInt(5),
            .fullscreen = true,
            .workspace_active = true,
            .nodes = &split_nodes,
        },
        .{
            .location = .{
                .workspace = .{ .worktree = @enumFromInt(4) },
                .tab_id = @enumFromInt(8),
            },
            .focused_pane = @enumFromInt(9),
            .fullscreen = false,
            .workspace_active = true,
            .nodes = &.{.{ .pane = .{ .id = @enumFromInt(9) } }},
        },
    };
    seeds.accept(
        "update_client_layout with two tabs",
        try schema.encodeClientLayoutUpdate(
            seeds.space(),
            .{
                .sidebar_visible = false,
                .sidebar_width = 40,
                .workspace_list_collapsed = true,
                .active_tab = location,
                .tabs = &two_tabs,
            },
        ),
    );

    var update = singleTabLayout(
        &tabs,
        &split_nodes,
        @enumFromInt(5),
    );
    update.sidebar_width = 0;
    var encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(&encoder, update);
    seeds.reject(
        "update_client_layout without sidebar width",
        encoder.finish(),
        error.InvalidClientLayoutWidth,
    );

    update = singleTabLayout(
        &tabs,
        &split_nodes,
        @enumFromInt(5),
    );
    update.tabs = &.{};
    encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(&encoder, update);
    seeds.reject(
        "update_client_layout without tabs",
        encoder.finish(),
        error.InvalidClientLayoutSnapshot,
    );

    const one_node_too_many = largest_nodes ++ [_]schema.ClientLayoutNode{.{ .pane = .{ .id = @enumFromInt(99) } }};
    encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(
        &encoder,
        singleTabLayout(
            &tabs,
            &one_node_too_many,
            @enumFromInt(1),
        ),
    );
    seeds.reject(
        "update_client_layout with one node too many",
        encoder.finish(),
        error.InvalidClientLayoutNodeCount,
    );

    encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(
        &encoder,
        singleTabLayout(
            &tabs,
            split_nodes[0..2],
            @enumFromInt(5),
        ),
    );
    seeds.reject(
        "update_client_layout with a split missing a child",
        encoder.finish(),
        error.InvalidClientLayoutTree,
    );

    encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(
        &encoder,
        singleTabLayout(
            &tabs,
            &split_nodes,
            @enumFromInt(7),
        ),
    );
    seeds.reject(
        "update_client_layout focused outside its tree",
        encoder.finish(),
        error.InvalidClientLayoutFocus,
    );

    const duplicate_pane_nodes = [_]schema.ClientLayoutNode{
        split_nodes[0],
        split_nodes[1],
        split_nodes[1],
    };
    encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(
        &encoder,
        singleTabLayout(
            &tabs,
            &duplicate_pane_nodes,
            @enumFromInt(5),
        ),
    );
    seeds.reject(
        "update_client_layout showing one pane twice",
        encoder.finish(),
        error.DuplicatePane,
    );

    const narrow_split_nodes = [_]schema.ClientLayoutNode{
        .{ .split = .{
            .axis = .horizontal,
            .ratio = schema.min_client_layout_ratio - 1,
        } },
        split_nodes[1],
        split_nodes[2],
    };
    encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(
        &encoder,
        singleTabLayout(
            &tabs,
            &narrow_split_nodes,
            @enumFromInt(5),
        ),
    );
    seeds.reject(
        "update_client_layout with a split below the ratio bound",
        encoder.finish(),
        error.InvalidClientLayoutRatio,
    );

    update = singleTabLayout(
        &tabs,
        &split_nodes,
        @enumFromInt(5),
    );
    update.active_tab = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(4),
    };
    encoder = seeds.begin(.update_client_layout);
    try writeRawLayout(&encoder, update);
    seeds.reject(
        "update_client_layout whose active tab is not among its tabs",
        encoder.finish(),
        error.InvalidClientLayoutActiveTab,
    );
}

fn addAgentSeeds(seeds: *ClientSeeds) !void {
    seeds.accept(
        "acknowledge_agent",
        try schema.encodeAcknowledgeAgent(
            seeds.space(),
            .{
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
            },
        ),
    );
    seeds.accept("query_agents", try schema.encodeQueryAgents(seeds.space(), .{ .request_id = @enumFromInt(5) }));
    seeds.accept(
        "report_agent_session",
        try schema.encodeReportAgentSession(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .session = "abc",
            },
        ),
    );
    seeds.accept(
        "report_agent blocked",
        try schema.encodeReportAgent(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .provider = .codex,
                .state = .blocked,
                .session = "abc",
                .blocked_reason = .permission,
                .event = "Run zig build test?",
            },
        ),
    );
    seeds.accept(
        "report_agent idle",
        try schema.encodeReportAgent(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .state = .idle,
            },
        ),
    );
    seeds.accept(
        "report_agent_command",
        try schema.encodeReportAgentCommand(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .phase = .finished,
                .provider = "codex",
                .tool_call_id = "call-7",
                .command = "zig build test",
                .cwd = "/work",
                .session = "abc",
                .exit_code = 7,
            },
        ),
    );
    seeds.accept(
        "report_agent_title",
        try schema.encodeReportAgentTitle(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .provider = .claude,
                .title = "Fix proxy",
            },
        ),
    );
    seeds.accept(
        "report_agent_progress",
        try schema.encodeReportAgentProgress(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
                .provider = .claude,
                .cwd = "/work/telar-worktrees/fix/src",
                .work_tree_path = "/work/telar-worktrees/fix",
                .work_tree_branch = "fix",
                .final_message = "Done.\n\tAll green.",
                .plan_op = .add,
                .plan_done = 1,
                .plan_total = 2,
                .plan_text = "Add the reorder test",
            },
        ),
    );
    seeds.accept(
        "interrupt_agent",
        try schema.encodeInterruptAgent(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
            },
        ),
    );
    seeds.accept(
        "verify_pane_descent",
        try schema.encodeVerifyPaneDescent(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(5),
                .pane_generation = 3,
            },
        ),
    );
    var encoder = seeds.begin(.report_agent);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 3);
    try encoder.writeByte(schema.max_agent_provider_index + 1);
    seeds.reject(
        "report_agent from a provider past the manifest range",
        encoder.finish(),
        error.InvalidAgentProvider,
    );

    encoder = seeds.begin(.report_agent_command);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 3);
    try encoder.writeByte(@intFromEnum(schema.AgentCommandPhase.started));
    try encoder.writeSized16("codex");
    try encoder.writeSized16("");
    try encoder.writeSized32("ls");
    try encoder.writeSized16("");
    try encoder.writeSized16("");
    try encoder.writeByte(1);
    try encoder.writeInt(i32, 0);
    seeds.reject(
        "report_agent_command started with an exit code",
        encoder.finish(),
        error.InvalidAgentCommandExitCode,
    );
}

fn addClientAndRuntimeSeeds(seeds: *ClientSeeds) !void {
    seeds.accept("runtime_stop", try schema.encodeRuntimeStop(seeds.space()));
    seeds.accept("query_clients", try schema.encodeQueryClients(seeds.space(), .{ .request_id = @enumFromInt(5) }));
    seeds.accept(
        "detach_client",
        try schema.encodeDetachClient(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .client_id = 7,
                .client_generation = 9,
            },
        ),
    );
    seeds.accept(
        "request_client_command",
        try schema.encodeRequestClientCommand(
            seeds.space(),
            .{
                .request_id = @enumFromInt(5),
                .route = .{
                    .id = 7,
                    .generation = 9,
                },
                .action = .workspace_select,
                .status = .request,
                .target_id = 42,
            },
        ),
    );

    var command: schema.ClientCommand = .{
        .request_id = @enumFromInt(5),
        .route = .{
            .id = 7,
            .generation = 9,
        },
        .action = .layout_apply,
        .status = .admitted,
        .value = -3,
    };
    try command.setText("{\"tabs\":[]}");
    seeds.accept("complete_client_command with text", try schema.encodeCompleteClientCommand(seeds.space(), command));
    seeds.accept(
        "configure_terminal_colors",
        try schema.encodeConfigureTerminalColors(
            seeds.space(),
            .{
                .foreground = .{ 255, 255, 255 },
                .background = .{ 16, 16, 16 },
                .palette = .{.{ 1, 2, 3 }} ** 16,
            },
        ),
    );
    seeds.accept("configure_terminal_colors without colors", try schema.encodeConfigureTerminalColors(seeds.space(), .{}));
    seeds.accept("request_runtime_state", try schema.encodeRequestRuntimeState(seeds.space(), .{ .client_identity = @enumFromInt(9) }));
    seeds.accept(
        "show_notification",
        try schema.encodeShowNotification(
            seeds.space(),
            .{
                .request_id = @enumFromInt(45),
                .notification = .{
                    .level = .success,
                    .duration_ms = 2500,
                    .target = .{ .pane = @enumFromInt(5) },
                    .title = "Build complete",
                    .message = "Open the pane",
                },
            },
        ),
    );

    var encoder = seeds.begin(.detach_client);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 7);
    try encoder.writeInt(u64, 0);
    seeds.reject(
        "detach_client of generation zero",
        encoder.finish(),
        error.InvalidClientRoute,
    );

    encoder = seeds.begin(.request_client_command);
    try encoder.writeInt(u64, 5);
    try encoder.writeInt(u64, 7);
    try encoder.writeInt(u64, 9);
    try encoder.writeByte(@intFromEnum(schema.ClientAction.workspace_select));
    try encoder.writeByte(0);
    try encoder.writeInt(u64, 42);
    try encoder.writeInt(i64, 0);
    try encoder.writeSized16("\xff");
    seeds.reject(
        "request_client_command with invalid UTF-8 text",
        encoder.finish(),
        error.InvalidClientCommandText,
    );

    encoder = seeds.begin(.configure_terminal_colors);
    try encoder.writeByte(2);
    seeds.reject(
        "configure_terminal_colors with a presence flag of 2",
        encoder.finish(),
        error.InvalidBoolean,
    );

    encoder = seeds.begin(.request_runtime_state);
    try encoder.writeInt(u64, 0);
    try encoder.writeByte(1);
    seeds.reject(
        "request_runtime_state without identity",
        encoder.finish(),
        error.InvalidClientIdentity,
    );
}

/// Payloads that break the envelope rather than a body: no tag, bytes that
/// name no client tag, and bytes after or missing from a whole message.
fn addEnvelopeSeeds(seeds: *ClientSeeds) !void {
    seeds.reject(
        "empty payload",
        "",
        error.Truncated,
    );
    seeds.reject(
        "lowest unassigned tag",
        &.{unassigned_tags[0]},
        error.UnknownMessage,
    );
    seeds.reject(
        "unassigned tag inside the client range",
        &.{tag_range_gap},
        error.UnknownMessage,
    );
    seeds.reject(
        "server tag",
        &.{@intFromEnum(schema.ServerTag.pane_opened)},
        error.UnknownMessage,
    );
    seeds.reject(
        "highest byte",
        &.{std.math.maxInt(u8)},
        error.UnknownMessage,
    );

    const runtime_stop = &[_]u8{@intFromEnum(ClientTag.runtime_stop)};
    seeds.reject(
        "runtime_stop followed by a byte",
        seeds.extended(runtime_stop, &.{0}),
        error.TrailingBytes,
    );

    const attach = try schema.encodeOpenPane(
        seeds.space(),
        .{
            .request_id = @enumFromInt(2),
            .target = .{ .pane = @enumFromInt(41) },
            .size = size,
            .launch = null,
        },
    );
    var launch_encoder = Encoder.init(seeds.space()[attach.len..]);
    try writeRawLaunch(&launch_encoder, fixture_launch);
    seeds.reject(
        "open_pane attach followed by a launch",
        seeds.space()[0 .. attach.len + launch_encoder.index],
        error.TrailingBytes,
    );

    const resize = try schema.encodePaneResize(
        seeds.space(),
        .{
            .pane_id = @enumFromInt(3),
            .size = size,
        },
    );
    seeds.reject(
        "pane_resize missing its last byte",
        resize[0 .. resize.len - 1],
        error.Truncated,
    );
}

/// Checks every property of the file header against one payload.
fn expectClientPayload(payload: []const u8) !void {
    const message = schema.decodeClient(payload) catch |err| {
        return expectRejection(payload, err);
    };

    try expectAccepted(payload, message);
}

/// A rejection is the decoder's to choose, apart from the two answers the
/// envelope alone decides.
fn expectRejection(payload: []const u8, err: ClientDecodeError) !void {
    if (payload.len == 0 and err != error.Truncated) {
        return error.EmptyPayloadNotTruncated;
    }

    if (payload.len != 0 and std.enums.fromInt(ClientTag, payload[0]) == null and err != error.UnknownMessage) {
        return error.UnknownTagNotRejected;
    }
}

fn expectAccepted(payload: []const u8, message: ClientMessage) !void {
    const tag = std.enums.fromInt(ClientTag, payload[0]) orelse return error.AcceptedUnknownTag;
    const variant = @tagName(std.meta.activeTag(message));
    if (!std.mem.eql(u8, @tagName(tag), variant)) {
        return error.VariantDiffersFromTag;
    }

    try expectBorrowedWithin(payload[1..], message);
    try expectFraming(payload, tag);

    const reencoded = (encodeAccepted(message, &property_scratch.first) catch |err| {
        if (isKnownDivergence(
            tag,
            message,
            err,
        )) {
            return;
        }

        return err;
    }) orelse return;
    const redecoded = try schema.decodeClient(reencoded);
    try std.testing.expectEqualDeep(message, redecoded);
    try expectBorrowedWithin(reencoded[1..], redecoded);

    const stable = (try encodeAccepted(redecoded, &property_scratch.second)) orelse return error.ReencodedItemsRejected;
    try std.testing.expectEqualSlices(
        u8,
        reencoded,
        stable,
    );
}

/// Every message reads a fixed or length-prefixed shape, so a cut payload
/// runs out of bytes before any check that the whole one passed, and an
/// extended one has bytes after its end. Pane input is the one message
/// whose bytes run to the end of the payload.
fn expectFraming(payload: []const u8, tag: ClientTag) !void {
    if (tag == .pane_input) {
        return;
    }

    for ([_]usize{ 0, payload.len / 2, payload.len - 1 }) |length| {
        if (schema.decodeClient(payload[0..length])) |_| {
            return error.PrefixAccepted;
        } else |err| {
            if (err != error.Truncated) {
                return error.PrefixNotTruncated;
            }
        }
    }

    const extended = property_scratch.extended[0 .. payload.len + 1];
    @memcpy(extended[0..payload.len], payload);
    extended[payload.len] = 0;
    if (schema.decodeClient(extended)) |_| {
        return error.TrailingByteAccepted;
    } else |err| {
        if (err != error.TrailingBytes) {
            return error.TrailingByteNotRejected;
        }
    }
}

/// Fails when a slice anywhere in `value` points outside `body`. Owned
/// arrays are the value's own bytes; empty slices borrow nothing.
fn expectBorrowedWithin(body: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum", .array => {},
        .optional => {
            if (value) |present| {
                try expectBorrowedWithin(body, present);
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                try expectBorrowedWithin(body, @field(value, field.name));
            }
        },
        .@"union" => {
            switch (value) {
                inline else => |payload| try expectBorrowedWithin(body, payload),
            }
        },
        .pointer => |info| {
            if (info.size != .slice or info.child != u8) {
                @compileError("decoded messages borrow only byte slices, not " ++ @typeName(T));
            }

            try expectBorrowedSlice(body, value);
        },
        else => @compileError("unexpected decoded field type " ++ @typeName(T)),
    }
}

fn expectBorrowedSlice(bytes: []const u8, slice: []const u8) !void {
    if (slice.len == 0) {
        return;
    }

    const start = @intFromPtr(slice.ptr);
    if (start < @intFromPtr(bytes.ptr) or start + slice.len > @intFromPtr(bytes.ptr) + bytes.len) {
        return error.SliceOutsidePayload;
    }
}

/// The decoder checks a launch's and an import batch's structure and leaves
/// the content of each item to the iterators. An iterator may reject an
/// item only with an error that item's own bytes justify, read again from
/// where the iterator started it; running out of bytes the decoder walked,
/// or any other error, fails.
fn expectArgumentRejection(err: anyerror, item_bytes: []const u8, index: usize) !void {
    var item = Decoder.init(item_bytes);
    const argument = item.readSized16() catch return error.IteratorDisagreesWithDecoder;
    const justified = switch (err) {
        error.InvalidByteString => argument.len == 0 and index == 0,
        error.EmbeddedNul => holdsByte(argument, 0),
        else => false,
    };
    if (!justified) {
        return error.UnjustifiedItemRejection;
    }
}

fn expectEnvironmentRejection(err: anyerror, item_bytes: []const u8) !void {
    var item = Decoder.init(item_bytes);
    const name = item.readSized16() catch return error.IteratorDisagreesWithDecoder;
    const value = item.readSized32() catch return error.IteratorDisagreesWithDecoder;
    const justified = switch (err) {
        error.InvalidByteString => name.len == 0,
        error.EmbeddedNul => holdsByte(name, 0) or holdsByte(value, 0),
        error.InvalidEnvironmentName => holdsByte(name, '='),
        else => false,
    };
    if (!justified) {
        return error.UnjustifiedItemRejection;
    }
}

/// The decoder already bounds a command's length, so the only rejection
/// left to the iterator is an empty command.
fn expectImportRejection(err: anyerror, item_bytes: []const u8) !void {
    var item = Decoder.init(item_bytes);
    _ = item.readInt(i64) catch return error.IteratorDisagreesWithDecoder;
    const command = item.readSized16() catch return error.IteratorDisagreesWithDecoder;
    if (err != error.InvalidByteString or command.len != 0) {
        return error.UnjustifiedItemRejection;
    }
}

/// Walks a launch's iterators and gathers them into the launch its encoder
/// takes; null when an iterator rejects an item's content.
fn gatherLaunch(launch: schema.LaunchView, reencoding: *Reencoding) !?schema.Launch {
    if (launch.cwd.len == 0 or launch.cwd.len > schema.max_cwd_bytes) {
        return error.LaunchOutsideBudget;
    }

    if (launch.argument_count == 0 or launch.argument_count > schema.max_argument_count) {
        return error.LaunchOutsideBudget;
    }

    if (launch.environment_count > schema.max_environment_count) {
        return error.LaunchOutsideBudget;
    }

    var arguments = launch.arguments();
    var argument_bytes: usize = 0;
    for (reencoding.arguments[0..launch.argument_count], 0..) |*argument, index| {
        const item_start = arguments.decoder.index;
        const next = arguments.next() catch |err| {
            try expectArgumentRejection(
                err,
                launch.encoded_arguments[item_start..],
                index,
            );
            return null;
        };

        argument.* = next orelse return error.IteratorEndedEarly;
        try expectBorrowedSlice(launch.encoded_arguments, argument.*);
        argument_bytes += argument.len;
    }

    if (try arguments.next() != null) {
        return error.IteratorOutlivedCount;
    }

    if (arguments.decoder.index != launch.encoded_arguments.len or argument_bytes > schema.max_argument_bytes) {
        return error.IteratorDisagreesWithDecoder;
    }

    var environment = launch.environment();
    var environment_bytes: usize = 0;
    for (reencoding.environment[0..launch.environment_count]) |*entry| {
        const item_start = environment.decoder.index;
        const next = environment.next() catch |err| {
            try expectEnvironmentRejection(err, launch.encoded_environment[item_start..]);
            return null;
        };

        entry.* = next orelse return error.IteratorEndedEarly;
        try expectBorrowedSlice(launch.encoded_environment, entry.name);
        try expectBorrowedSlice(launch.encoded_environment, entry.value);
        environment_bytes += entry.name.len + entry.value.len;
    }

    if (try environment.next() != null) {
        return error.IteratorOutlivedCount;
    }

    if (environment.decoder.index != launch.encoded_environment.len or environment_bytes > schema.max_environment_bytes) {
        return error.IteratorDisagreesWithDecoder;
    }

    return .{
        .cwd = launch.cwd,
        .cwd_source = launch.cwd_source,
        .arguments = reencoding.arguments[0..launch.argument_count],
        .environment_mode = launch.environment_mode,
        .environment = reencoding.environment[0..launch.environment_count],
    };
}

/// Walks an import batch's entries into the batch its encoder takes; null
/// when the iterator rejects an entry's content.
fn gatherImports(view: schema.ImportHistoryView, reencoding: *Reencoding) !?schema.ImportHistory {
    if (view.entry_count == 0 or view.entry_count > schema.max_import_entries) {
        return error.ImportOutsideBudget;
    }

    var entries = view.entries();
    for (reencoding.imports[0..view.entry_count]) |*entry| {
        const item_start = entries.decoder.index;
        const next = entries.next() catch |err| {
            try expectImportRejection(err, view.encoded_entries[item_start..]);
            return null;
        };

        entry.* = next orelse return error.IteratorEndedEarly;
        try expectBorrowedSlice(view.encoded_entries, entry.command);
        if (entry.command.len > schema.max_import_command_bytes) {
            return error.ImportOutsideBudget;
        }
    }

    if (try entries.next() != null) {
        return error.IteratorOutlivedCount;
    }

    if (entries.decoder.index != view.encoded_entries.len) {
        return error.IteratorDisagreesWithDecoder;
    }

    return .{
        .request_id = view.request_id,
        .source = view.source,
        .base_sequence = view.base_sequence,
        .entries = reencoding.imports[0..view.entry_count],
    };
}

/// Walks a layout update's tabs and their nodes into the update its encoder
/// takes. The decoder validated every tree, so any iterator error fails.
fn gatherLayout(view: schema.ClientLayoutUpdateView, reencoding: *Reencoding) !schema.ClientLayoutUpdate {
    if (view.tab_count == 0 or view.tab_count > schema.max_client_layout_tabs) {
        return error.LayoutOutsideBudget;
    }

    var tabs = view.tabs();
    var node_total: usize = 0;
    for (reencoding.tabs[0..view.tab_count]) |*tab| {
        const tab_view = (try tabs.next()) orelse return error.IteratorEndedEarly;
        try expectBorrowedSlice(view.encoded_tabs, tab_view.encoded_nodes);
        if (tab_view.node_count > schema.max_client_layout_nodes - node_total) {
            return error.LayoutOutsideBudget;
        }

        const nodes = reencoding.nodes[node_total..][0..tab_view.node_count];
        var node_iterator = tab_view.nodes();
        for (nodes) |*node| {
            node.* = (try node_iterator.next()) orelse return error.IteratorEndedEarly;
        }

        if (try node_iterator.next() != null) {
            return error.IteratorOutlivedCount;
        }

        if (node_iterator.decoder.index != tab_view.encoded_nodes.len) {
            return error.IteratorDisagreesWithDecoder;
        }

        node_total += nodes.len;
        tab.* = .{
            .location = tab_view.location,
            .focused_pane = tab_view.focused_pane,
            .fullscreen = tab_view.fullscreen,
            .workspace_active = tab_view.workspace_active,
            .nodes = nodes,
        };
    }

    if (try tabs.next() != null) {
        return error.IteratorOutlivedCount;
    }

    if (tabs.decoder.index != view.encoded_tabs.len) {
        return error.IteratorDisagreesWithDecoder;
    }

    return .{
        .sidebar_visible = view.sidebar_visible,
        .sidebar_width = view.sidebar_width,
        .workspace_list_collapsed = view.workspace_list_collapsed,
        .active_tab = view.active_tab,
        .tabs = reencoding.tabs[0..view.tab_count],
    };
}

/// The owned message a view of type `@TypeOf(view)` stands for, with its
/// gathered launch in place of the view's.
fn launchMessage(comptime Owned: type, view: anytype, launch: schema.Launch) Owned {
    var owned: Owned = undefined;
    inline for (@typeInfo(Owned).@"struct".fields) |field| {
        const is_launch = comptime std.mem.eql(u8, field.name, "launch");
        if (is_launch) {
            owned.launch = launch;
        } else {
            @field(owned, field.name) = @field(view, field.name);
        }
    }

    return owned;
}

/// Encodes an accepted message with its production encoder; null when one
/// of its views holds an item its iterator rejects. The switch is
/// exhaustive, so a new client message fails to compile here until it has
/// an encoder to round-trip through.
fn encodeAccepted(message: ClientMessage, reencoding: *Reencoding) !?[]const u8 {
    const buffer = &reencoding.bytes;
    return switch (message) {
        .open_pane => |view| {
            var launch: ?schema.Launch = null;
            if (view.launch) |launch_view| {
                launch = (try gatherLaunch(launch_view, reencoding)) orelse return null;
            }

            return try schema.encodeOpenPane(
                buffer,
                .{
                    .request_id = view.request_id,
                    .target = view.target,
                    .size = view.size,
                    .launch = launch,
                },
            );
        },
        .create_pane => |view| {
            const launch = (try gatherLaunch(view.launch, reencoding)) orelse return null;
            const owned = launchMessage(
                schema.CreatePane,
                view,
                launch,
            );
            return try schema.encodeCreatePane(buffer, owned);
        },
        .create_tab => |view| {
            const launch = (try gatherLaunch(view.launch, reencoding)) orelse return null;
            const owned = launchMessage(
                schema.CreateTab,
                view,
                launch,
            );
            return try schema.encodeCreateTab(buffer, owned);
        },
        .launch_tab => |view| {
            const launch = (try gatherLaunch(view.launch, reencoding)) orelse return null;
            const owned = launchMessage(
                schema.LaunchTab,
                view,
                launch,
            );
            return try schema.encodeLaunchTab(buffer, owned);
        },
        .create_workspace => |view| {
            const launch = (try gatherLaunch(view.launch, reencoding)) orelse return null;
            const owned = launchMessage(
                schema.CreateWorkspace,
                view,
                launch,
            );
            return try schema.encodeCreateWorkspace(buffer, owned);
        },
        .report_limit => |value| try schema.encodeReportLimit(buffer, value),
        .query_limits => |value| try schema.encodeQueryLimits(buffer, value),
        .execution_request => |value| try schema.encodeExecutionRequest(buffer, value),
        .launch_worktree => |view| {
            const launch = (try gatherLaunch(view.launch, reencoding)) orelse return null;
            const owned = launchMessage(
                schema.LaunchWorktree,
                view,
                launch,
            );
            return try schema.encodeLaunchWorktree(buffer, owned);
        },
        .import_history => |view| {
            const batch = (try gatherImports(view, reencoding)) orelse return null;
            return try schema.encodeImportHistory(buffer, batch);
        },
        .update_client_layout => |view| try schema.encodeClientLayoutUpdate(buffer, try gatherLayout(view, reencoding)),
        .runtime_stop => try schema.encodeRuntimeStop(buffer),
        .query_clients => |value| try schema.encodeQueryClients(buffer, value),
        .detach_client => |value| try schema.encodeDetachClient(buffer, value),
        .request_client_command => |value| try schema.encodeRequestClientCommand(buffer, value),
        .complete_client_command => |value| try schema.encodeCompleteClientCommand(buffer, value),

        .pane_input => |value| try schema.encodePaneInput(buffer, value),
        .pane_resize => |value| try schema.encodePaneResize(buffer, value),
        .frame_ack => |value| try schema.encodeFrameAck(buffer, value),
        .request_snapshot => |value| try schema.encodeRequestSnapshot(buffer, value),
        .detach_pane => |value| try schema.encodeDetachPane(buffer, value),
        .request_tab_snapshot => |value| try schema.encodeRequestTabSnapshot(buffer, value),
        .close_pane => |value| try schema.encodeClosePane(buffer, value),
        .query_history => |value| try schema.encodeQueryHistory(buffer, value),
        .request_workspace_snapshot => |value| try schema.encodeRequestWorkspaceSnapshot(buffer, value),
        .rename_tab => |value| try schema.encodeRenameTab(buffer, value),
        .close_tab => |value| try schema.encodeCloseTab(buffer, value),
        .move_tab => |value| try schema.encodeMoveTab(buffer, value),
        .request_graphics_snapshot => |value| try schema.encodeRequestGraphicsSnapshot(buffer, value),
        .graphics_credit => |value| try schema.encodeGraphicsCredit(buffer, value),
        .configure_graphics => |value| try schema.encodeConfigureGraphics(buffer, value),
        .configure_terminal_colors => |value| try schema.encodeConfigureTerminalColors(buffer, value),
        .configure_frame_interval => |value| try schema.encodeConfigureFrameInterval(buffer, value),
        .request_runtime_state => |value| try schema.encodeRequestRuntimeState(buffer, value),
        .rename_workspace => |value| try schema.encodeRenameWorkspace(buffer, value),
        .set_pane_viewport => |value| try schema.encodeSetPaneViewport(buffer, value),
        .copy_selection => |value| try schema.encodeCopySelection(buffer, value),
        .show_notification => |value| try schema.encodeShowNotification(buffer, value),
        .acknowledge_agent => |value| try schema.encodeAcknowledgeAgent(buffer, value),
        .query_agents => |value| try schema.encodeQueryAgents(buffer, value),
        .read_pane => |value| try schema.encodeReadPane(buffer, value),
        .send_pane_text => |value| try schema.encodeSendPaneText(buffer, value),
        .report_agent_session => |value| try schema.encodeReportAgentSession(buffer, value),
        .report_agent => |value| try schema.encodeReportAgent(buffer, value),
        .report_agent_command => |value| try schema.encodeReportAgentCommand(buffer, value),
        .report_agent_title => |value| try schema.encodeReportAgentTitle(buffer, value),
        .search_pane => |value| try schema.encodeSearchPane(buffer, value),
        .delete_history => |value| try schema.encodeDeleteHistory(buffer, value),
        .suggest_command => |value| try schema.encodeSuggestCommand(buffer, value),
        .prune_history => |value| try schema.encodePruneHistory(buffer, value),
        .read_history_output => |value| try schema.encodeReadHistoryOutput(buffer, value),
        .history_stats => |value| try schema.encodeHistoryStatsQuery(buffer, value),
        .request_pane_focus => |value| try schema.encodeRequestPaneFocus(buffer, value),
        .open_editor => |value| try schema.encodeOpenEditor(buffer, value),
        .find_paths => |value| try schema.encodeFindPaths(buffer, value),
        .complete_pane_focus => |value| try schema.encodeCompletePaneFocus(buffer, value),
        .register_worktree => |value| try schema.encodeRegisterWorktree(buffer, value),
        .forget_worktree => |value| try schema.encodeForgetWorktree(buffer, value),
        .interrupt_agent => |value| try schema.encodeInterruptAgent(buffer, value),
        .report_agent_progress => |value| try schema.encodeReportAgentProgress(buffer, value),
        .verify_pane_descent => |value| try schema.encodeVerifyPaneDescent(buffer, value),
    };
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn decodeFuzzedClientMessage(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [payload_capacity]u8 = undefined;
    const payload = buffer[0..smith.slice(&buffer)];
    expectClientPayload(payload) catch |err| {
        std.debug.panic(
            "decodeClient property failed: {t} for payload {x}",
            .{
                err,
                payload,
            },
        );
    };
}

/// Decodes a payload larger than `payload_capacity` and returns its
/// outcome, null when accepted.
fn decodeOutcome(payload: []const u8) ?ClientDecodeError {
    _ = schema.decodeClient(payload) catch |err| return err;
    return null;
}

test "every client tag names one client message variant" {
    const tags = @typeInfo(ClientTag).@"enum".fields;
    try std.testing.expectEqual(tags.len, @typeInfo(ClientMessage).@"union".fields.len);
    inline for (tags) |field| {
        try std.testing.expect(@hasField(ClientMessage, field.name));
    }
}

test "every first byte that names no client tag is an unknown message" {
    for (0..std.math.maxInt(u8) + 1) |value| {
        const byte: u8 = @intCast(value);
        const outcome = decodeOutcome(&.{byte});
        const unassigned = std.mem.findScalar(u8, unassigned_tags, byte) != null;
        if (unassigned) {
            try std.testing.expectEqual(@as(?ClientDecodeError, error.UnknownMessage), outcome);
        } else if (outcome) |err| {
            try std.testing.expect(err != error.UnknownMessage);
        }
    }
}

test "every client fuzz seed reaches its decoder outcome and holds every property" {
    try addClientSeeds(&client_seeds);
    for (client_seeds.committed(), client_seeds.corpus[0..client_seeds.count]) |seed, entry| {
        errdefer std.debug.print("seed \"{s}\"\n", .{seed.name});
        try std.testing.expectEqual(seed.outcome, decodeOutcome(seed.payload));
        try expectClientPayload(seed.payload);

        var smith: std.testing.Smith = .{ .in = entry };
        var buffer: [payload_capacity]u8 = undefined;
        const replayed = buffer[0..smith.slice(&buffer)];
        try std.testing.expectEqualSlices(
            u8,
            seed.payload,
            replayed,
        );
    }
}

test "the seed corpus covers the tags it claims" {
    try addClientSeeds(&client_seeds);
    var covered: [std.math.maxInt(u8) + 1]SeedCoverage = @splat(.none);
    for (client_seeds.committed()) |seed| {
        if (seed.payload.len == 0) {
            continue;
        }

        const coverage = &covered[seed.payload[0]];
        if (seed.outcome == null) {
            coverage.* = .accepted;
        } else if (coverage.* == .none) {
            coverage.* = .rejected_only;
        }
    }

    for (std.enums.values(ClientTag)) |tag| {
        errdefer std.debug.print("tag {t}\n", .{tag});
        try std.testing.expectEqual(claimedCoverage(tag), covered[@intFromEnum(tag)]);
    }
}

test "every known divergence still holds for its payload" {
    for (known_divergences) |divergence| {
        errdefer std.debug.print("known divergence \"{s}\"\n", .{divergence.name});
        const message = try schema.decodeClient(divergence.payload);
        try std.testing.expectEqual(divergence.tag, std.enums.fromInt(ClientTag, divergence.payload[0]).?);
        try expectBorrowedWithin(divergence.payload[1..], message);
        try expectFraming(divergence.payload, divergence.tag);
        try std.testing.expect(divergence.holds(message));
        try std.testing.expectError(divergence.encoder_error, encodeAccepted(message, &property_scratch.first));
        try std.testing.expect(isKnownDivergence(
            divergence.tag,
            message,
            divergence.encoder_error,
        ));
    }
}

test "an import whose source holds a NUL never counts as the known divergence" {
    const message = try schema.decodeClient(known_divergences[2].payload);
    try std.testing.expect(isKnownDivergence(
        .import_history,
        message,
        error.EmbeddedNul,
    ));

    // The decoder refuses a NUL in a source (the seed "import_history with a
    // NUL in source"); a decoder that stopped would hand the encoder this
    // message, whose EmbeddedNul the old tag and error pair excused.
    var nul_source = message;
    nul_source.import_history.source = "zsh\x00h";
    try std.testing.expectError(error.EmbeddedNul, encodeAccepted(nul_source, &property_scratch.first));
    try std.testing.expect(!isKnownDivergence(
        .import_history,
        nul_source,
        error.EmbeddedNul,
    ));

    const clean = try schema.decodeClient(&([_]u8{@intFromEnum(ClientTag.import_history)} ++ wireInt(u64, 34) ++
        wireSized16("zsh:h") ++ wireInt(u64, 100) ++ wireInt(u16, 1) ++ wireInt(i64, 1700000002000) ++ wireSized16("ab")));
    try std.testing.expect(!isKnownDivergence(
        .import_history,
        clean,
        error.EmbeddedNul,
    ));
    try std.testing.expect(!isKnownDivergence(
        .import_history,
        message,
        error.InvalidByteString,
    ));
}

test "an iterator rejection must be justified by the item it rejects" {
    try expectArgumentRejection(
        error.EmbeddedNul,
        &wireSized16("a\x00b"),
        1,
    );
    try expectArgumentRejection(
        error.InvalidByteString,
        &wireSized16(""),
        0,
    );
    try std.testing.expectError(error.UnjustifiedItemRejection, expectArgumentRejection(
        error.InvalidByteString,
        &wireSized16(""),
        1,
    ));
    try std.testing.expectError(error.UnjustifiedItemRejection, expectArgumentRejection(
        error.EmbeddedNul,
        &wireSized16("ab"),
        1,
    ));
    try std.testing.expectError(error.UnjustifiedItemRejection, expectArgumentRejection(
        error.OutOfMemory,
        &wireSized16("ab"),
        1,
    ));
    try std.testing.expectError(error.IteratorDisagreesWithDecoder, expectArgumentRejection(
        error.Truncated,
        wireSized16("ab")[0..3],
        1,
    ));

    try expectEnvironmentRejection(error.InvalidEnvironmentName, &(wireSized16("A=B") ++ wireInt(u32, 0)));
    try expectEnvironmentRejection(error.EmbeddedNul, &(wireSized16("A") ++ wireInt(u32, 1) ++ [_]u8{0}));
    try expectEnvironmentRejection(error.InvalidByteString, &(wireSized16("") ++ wireInt(u32, 0)));
    try std.testing.expectError(
        error.UnjustifiedItemRejection,
        expectEnvironmentRejection(error.InvalidEnvironmentName, &(wireSized16("AB") ++ wireInt(u32, 0))),
    );

    try expectImportRejection(error.InvalidByteString, &(wireInt(i64, 1) ++ wireSized16("")));
    try std.testing.expectError(
        error.UnjustifiedItemRejection,
        expectImportRejection(error.InvalidByteString, &(wireInt(i64, 1) ++ wireSized16("ls"))),
    );
}

test "launch argument bytes stop at their budget" {
    const buffer = try std.testing.allocator.alloc(u8, schema.max_argument_bytes + payload_capacity);
    defer std.testing.allocator.free(buffer);

    const text = try std.testing.allocator.alloc(u8, schema.max_argument_bytes + 1);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');

    for ([_]usize{ 0, 1 }) |excess| {
        var arguments: [schema.max_argument_count][]const u8 = undefined;
        var count: usize = 0;
        var remaining = schema.max_argument_bytes + excess;
        var offset: usize = 0;
        while (remaining > 0) : (count += 1) {
            const length = @min(remaining, std.math.maxInt(u16));
            arguments[count] = text[offset..][0..length];
            offset += length;
            remaining -= length;
        }

        var encoder = Encoder.init(buffer);
        try encoder.writeByte(@intFromEnum(ClientTag.open_pane));
        try writeOpenPaneHeader(&encoder);
        try writeRawLaunch(
            &encoder,
            .{
                .cwd = "/work",
                .arguments = arguments[0..count],
            },
        );

        const expected: ?ClientDecodeError = if (excess == 0) null else error.ArgumentsTooLarge;
        try std.testing.expectEqual(expected, decodeOutcome(encoder.finish()));
    }
}

test "launch environment bytes stop at their budget" {
    const buffer = try std.testing.allocator.alloc(u8, schema.max_environment_bytes + payload_capacity);
    defer std.testing.allocator.free(buffer);

    const value = try std.testing.allocator.alloc(u8, schema.max_environment_bytes);
    defer std.testing.allocator.free(value);
    @memset(value, 'v');

    const name = "K";
    for ([_]usize{ 0, 1 }) |excess| {
        var encoder = Encoder.init(buffer);
        try encoder.writeByte(@intFromEnum(ClientTag.open_pane));
        try writeOpenPaneHeader(&encoder);
        try writeRawLaunch(
            &encoder,
            .{
                .cwd = "/work",
                .arguments = &shell_arguments,
                .environment = &.{.{
                    .name = name,
                    .value = value[0 .. schema.max_environment_bytes - name.len + excess],
                }},
            },
        );

        const expected: ?ClientDecodeError = if (excess == 0) null else error.EnvironmentTooLarge;
        try std.testing.expectEqual(expected, decodeOutcome(encoder.finish()));
    }
}

test "pane input stops at its budget" {
    const buffer = try std.testing.allocator.alloc(u8, schema.max_input_bytes + payload_capacity);
    defer std.testing.allocator.free(buffer);

    for ([_]usize{ 0, 1 }) |excess| {
        var encoder = Encoder.init(buffer);
        try encoder.writeByte(@intFromEnum(ClientTag.pane_input));
        try encoder.writeInt(u64, 3);
        const input = buffer[encoder.index..][0 .. schema.max_input_bytes + excess];
        @memset(input, 'i');
        encoder.index += input.len;

        const expected: ?ClientDecodeError = if (excess == 0) null else error.InvalidInputLength;
        try std.testing.expectEqual(expected, decodeOutcome(encoder.finish()));
    }
}

test "imported commands stop at their budget" {
    const buffer = try std.testing.allocator.alloc(u8, schema.max_import_command_bytes + payload_capacity);
    defer std.testing.allocator.free(buffer);

    const command = try std.testing.allocator.alloc(u8, schema.max_import_command_bytes + 1);
    defer std.testing.allocator.free(command);
    @memset(command, 'c');

    for ([_]usize{ 0, 1 }) |excess| {
        var encoder = Encoder.init(buffer);
        try encoder.writeByte(@intFromEnum(ClientTag.import_history));
        try encoder.writeInt(u64, 34);
        try encoder.writeSized16("zsh:/home/u/.zsh_history");
        try encoder.writeInt(u64, 100);
        try encoder.writeInt(u16, 1);
        try encoder.writeInt(i64, 1700000002000);
        if (schema.max_import_command_bytes + excess > std.math.maxInt(u16)) {
            try std.testing.expectError(error.LengthOverflow, encoder.writeSized16(command[0 .. schema.max_import_command_bytes + excess]));
            continue;
        }

        try encoder.writeSized16(command[0 .. schema.max_import_command_bytes + excess]);

        const expected: ?ClientDecodeError = if (excess == 0) null else error.InvalidByteString;
        try std.testing.expectEqual(expected, decodeOutcome(encoder.finish()));
    }
}

test "every saved input holds every property" {
    for (saved_inputs) |entry| {
        var smith: std.testing.Smith = .{ .in = entry };
        var buffer: [payload_capacity]u8 = undefined;
        try expectClientPayload(buffer[0..smith.slice(&buffer)]);
    }
}

test "fuzz client message decoding" {
    try addClientSeeds(&client_seeds);
    var corpus: [seed_capacity + saved_inputs.len][]const u8 = undefined;
    const seeds = client_seeds.corpus[0..client_seeds.count];
    @memcpy(corpus[0..seeds.len], seeds);
    @memcpy(corpus[seeds.len..][0..saved_inputs.len], &saved_inputs);
    try std.testing.fuzz({}, decodeFuzzedClientMessage, .{
        .corpus = corpus[0 .. seeds.len + saved_inputs.len],
    });
}
