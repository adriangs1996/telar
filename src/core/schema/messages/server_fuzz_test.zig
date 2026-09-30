//! Native fuzzing of `decodeServer` and `decodeServerInto`, the dispatch a
//! client runs on every message the runtime sends.
//!
//! This root imports a `telar-core` built for it without C, as
//! `build/fuzz_ipc_server.zig` explains, and runs only through
//! `zig build test-fuzz-ipc-server`. The ordinary suites, and the coverage
//! build that compiles them with `-ffuzz`, never reach its
//! `std.testing.fuzz` call, for the reasons `handshake_fuzz_test.zig` gives.
//!
//! Every payload, fuzzed or seeded, must satisfy these properties:
//!
//! - `decodeServer` and `decodeServerInto` agree: both reject with the same
//!   error, or both accept the same variant with the same semantic fields.
//!   `decodeServerInto` writes over a destination filled with a byte pattern
//!   and over the message it just decoded; a rejected destination is never
//!   read.
//! - An accepted message's views iterate exactly their declared counts,
//!   consume exactly the bytes the decoder delimited and borrow only the
//!   payload. Views the decoder validated in full never fail; history
//!   entries and stats rows may fail validation but never run out of bytes;
//!   cells may fail any way, as `CellReader`'s own rejection.
//! - Every proper prefix of an accepted message fails with `Truncated` and
//!   one byte more fails with `TrailingBytes`, except past the fixed head of
//!   `request_failed`, whose text runs to the end of the payload.
//! - A fully iterable message re-encodes through its tag's encoder to exactly
//!   the payload, except the encoder refusals `encoder_rejections` lists and
//!   pane frames, which this target does not re-encode.

const std = @import("std");
const core = @import("telar-core");

const ServerMessage = core.ServerMessage;
const ServerTag = core.ServerTag;
/// The variant a decoded message holds; one per `ServerTag`.
const MessageTag = std.meta.Tag(ServerMessage);
const DecodeError = @typeInfo(@typeInfo(@TypeOf(core.decodeServer)).@"fn".return_type.?).error_union.error_set;
const Cell = std.meta.Child(@FieldType(core.Span, "cells"));
const HistoryStatsView = @FieldType(ServerMessage, "history_stats_result");

/// Largest payload the fuzzer builds. Seeds up to this size join the corpus;
/// larger directed seeds run through the same properties in a plain test.
const payload_capacity = 2048;

/// Room for the largest directed seed, a snapshot of every agent a tab holds.
const directed_capacity = 16 * 1024;

/// Every seed payload, fuzzed and directed, laid end to end.
const seed_bytes_capacity = 96 * 1024;

const max_seeds = 192;

/// The length prefix `Smith.slice` reads before the bytes it returns.
const smith_length_size = @sizeOf(u32);

/// Filled into the `decodeServerInto` destination before a decode, so a
/// variant that leaves part of itself unwritten differs from `decodeServer`.
const dirty_destination_byte = 0xa5;

/// Tag, request id and failure code: the part of `request_failed` before its
/// raw text.
const request_failed_head_size = 1 + @sizeOf(u64) + @sizeOf(u16);

/// What decoding one payload came to, once every property held.
const Verdict = union(enum) {
    /// Both APIs rejected the payload with this error.
    rejected: DecodeError,
    /// Accepted; its views iterate and it re-encodes to exactly the payload.
    accepted: MessageTag,
    /// Accepted; a view that validates as it is consumed refused an item.
    consumer_rejected: MessageTag,
    /// Accepted and iterable; the tag's encoder refuses the decoded value as
    /// `encoder_rejections` records.
    encoder_rejected: MessageTag,
    /// Accepted and iterable; this target does not re-encode the tag.
    not_reencoded: MessageTag,
};

/// How a view's iterator may refuse items of a message the decoder accepted.
const Lateness = enum {
    /// The decoder validated every item: iteration never fails.
    eager,
    /// The decoder walked item boundaries only: an item may fail validation
    /// but never `Truncated`.
    validates_fields,
    /// The decoder checked sizes only (cells): any error is the consumer's.
    validates_bytes,
};

const Walk = enum { complete, consumer_rejected };

/// A decoded message its tag's encoder refuses. Each one is a decoder that
/// accepts what the encoder never produces, reported in
/// `docs/testing/fuzz-ipc-server.md`.
const EncoderRejection = struct {
    tag: MessageTag,
    err: anyerror,
};

const encoder_rejections = [_]EncoderRejection{
    // `decodeHistoryOutput` checks only the content length; the encoder also
    // refuses a NUL byte.
    .{
        .tag = .history_output,
        .err = error.EmbeddedNul,
    },
    // `decodeHistoryStats` and `HistoryStatsTopIterator` check only the
    // command length; the encoder also refuses a NUL byte.
    .{
        .tag = .history_stats_result,
        .err = error.EmbeddedNul,
    },
};

const Seed = struct {
    name: []const u8,
    payload: []const u8,
    verdict: Verdict,
};

/// Seeds encoded by telar's own encoders, and the mutations built from them.
const SeedCorpus = struct {
    bytes: [seed_bytes_capacity]u8 = undefined,
    used: usize = 0,
    seeds: [max_seeds]Seed = undefined,
    count: usize = 0,

    fn space(self: *SeedCorpus) []u8 {
        return self.bytes[self.used..];
    }

    /// Keeps a payload an encoder wrote into `space()`.
    fn add(self: *SeedCorpus, name: []const u8, payload: []const u8, verdict: Verdict) void {
        std.debug.assert(payload.len == 0 or payload.ptr == self.bytes[self.used..].ptr);
        self.seeds[self.count] = .{
            .name = name,
            .payload = payload,
            .verdict = verdict,
        };
        self.used += payload.len;
        self.count += 1;
    }

    /// Keeps a copy of `source` for a mutation to change.
    fn copy(self: *SeedCorpus, source: []const u8) []u8 {
        const bytes = self.bytes[self.used..][0..source.len];
        @memcpy(bytes, source);
        return bytes;
    }

    fn list(self: *const SeedCorpus) []const Seed {
        return self.seeds[0..self.count];
    }
};

/// Fixed arrays a view is collected into before its encoder can take it.
const OwnedViews = struct {
    panes: [core.max_panes_per_tab]core.PaneDescriptor,
    history_entries: [core.max_history_results]core.HistoryEntry,
    tabs: [core.max_tabs_per_workspace]core.TabDescriptor,
    foregrounds: [core.max_tabs_per_workspace * core.max_panes_per_tab]core.PaneForeground,
    agents: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry,
    workspaces: [core.max_workspace_list_entries]core.WorkspaceListEntry,
    worktrees: [core.max_worktree_entries]core.WorktreeListEntry,
    layout_tabs: [core.max_client_layout_tabs]core.ClientTabLayout,
    layout_nodes: [core.max_client_layout_nodes]core.ClientLayoutNode,
    matches: [core.max_search_matches]core.SearchMatch,
    top: [core.max_history_stats_top]core.HistoryStatsTop,
    paths: [core.max_path_results]core.PathMatch,
    positions: [core.max_path_results * core.max_path_query_bytes]u16,
};

/// Yields path matches with the storage `PathMatchIterator.next` needs.
const PathMatchWalk = struct {
    matches: core.PathMatchIterator,
    storage: [core.max_path_query_bytes]u16 = undefined,

    fn next(self: *PathMatchWalk) !?core.PathMatch {
        return self.matches.next(&self.storage);
    }
};

// Kilobytes each, so they live outside the fuzz loop's stack. The fuzzer
// runs one input at a time and every check fills them before reading.
var destination: ServerMessage = undefined;
var owned: OwnedViews = undefined;
var reencoded: [directed_capacity]u8 = undefined;
var extended: [directed_capacity + 1]u8 = undefined;
var seed_corpus: SeedCorpus = .{};
var corpus_bytes: [seed_bytes_capacity + max_seeds * smith_length_size]u8 = undefined;
var corpus_entries: [max_seeds + replayed_inputs.len][]const u8 = undefined;

/// Inputs the fuzzer saved, kept as regressions. A saved crash is already in
/// `Smith` input form: copy `.zig-cache/f/crash` next to this file and add
/// `@embedFile("<name>")` here; a plain run then replays it, and the fuzzer
/// starts from it.
const replayed_inputs = [_][]const u8{};

const location: core.TabLocation = .{
    .workspace = .{
        .workspace = @enumFromInt(7),
    },
    .tab_id = @enumFromInt(3),
};

const worktree_location: core.TabLocation = .{
    .workspace = .{
        .worktree = @enumFromInt(2),
    },
    .tab_id = @enumFromInt(4),
};

const image_key: core.ImageKey = .{
    .image_id = 7,
    .generation = 2,
};

// -- properties ---------------------------------------------------------------

/// Decodes `payload` with both APIs and checks every property the file
/// comment lists, returning what the decoder and its consumers answered.
fn checkServerPayload(payload: []const u8) !Verdict {
    const decoded = core.decodeServer(payload) catch |err| {
        try expectIntoRejects(payload, err);
        return .{
            .rejected = err,
        };
    };

    @memset(std.mem.asBytes(&destination), dirty_destination_byte);
    core.decodeServerInto(&destination, payload) catch return error.IntoRejectedAcceptedPayload;
    try expectSameValue(
        ServerMessage,
        decoded,
        destination,
    );

    core.decodeServerInto(&destination, payload) catch return error.IntoRejectedAcceptedPayload;
    try expectSameValue(
        ServerMessage,
        decoded,
        destination,
    );

    const tag = std.meta.activeTag(decoded);
    try expectPrefixesTruncated(tag, payload);
    try expectExtensionRejected(tag, payload);

    if (try walkMessage(
        &decoded,
        &destination,
        payload,
    ) == .consumer_rejected) {
        return .{
            .consumer_rejected = tag,
        };
    }

    if (tag == .pane_frame) {
        return .{
            .not_reencoded = tag,
        };
    }

    const bytes = reencode(&decoded, &reencoded) catch |err| {
        if (!isEncoderRejection(tag, err)) {
            return err;
        }

        return .{
            .encoder_rejected = tag,
        };
    };

    if (!std.mem.eql(
        u8,
        payload,
        bytes,
    )) {
        return error.ReencodingDiffers;
    }

    return .{
        .accepted = tag,
    };
}

/// A rejected payload is rejected by `decodeServerInto` with the same error.
/// The destination holds no valid message afterwards, so nothing reads it.
fn expectIntoRejects(payload: []const u8, expected: DecodeError) !void {
    @memset(std.mem.asBytes(&destination), dirty_destination_byte);
    core.decodeServerInto(&destination, payload) catch |err| {
        if (err != expected) {
            return error.IntoRejectedDifferently;
        }

        return;
    };

    return error.IntoAcceptedRejectedPayload;
}

/// A decoder reads fields in an order fixed by the bytes already read, so a
/// prefix of an accepted payload stops at its first missing byte.
fn expectPrefixesTruncated(tag: MessageTag, payload: []const u8) !void {
    for (0..payload.len) |length| {
        if (tag == .request_failed and length >= request_failed_head_size) {
            break;
        }

        if (core.decodeServer(payload[0..length])) |_| {
            return error.PrefixAccepted;
        } else |err| {
            if (err != error.Truncated) {
                return error.PrefixRejectedDifferently;
            }
        }
    }
}

/// `decodeServer` checks the end after the message, so a byte more is only
/// ever `TrailingBytes`.
fn expectExtensionRejected(tag: MessageTag, payload: []const u8) !void {
    if (tag == .request_failed) {
        return;
    }

    @memcpy(extended[0..payload.len], payload);
    extended[payload.len] = 0;
    if (core.decodeServer(extended[0 .. payload.len + 1])) |_| {
        return error.ExtensionAccepted;
    } else |err| {
        if (err != error.TrailingBytes) {
            return error.ExtensionRejectedDifferently;
        }
    }
}

fn isEncoderRejection(tag: MessageTag, err: anyerror) bool {
    for (encoder_rejections) |rejection| {
        if (rejection.tag == tag and rejection.err == err) {
            return true;
        }
    }

    return false;
}

/// Compares what two decodes of one payload mean, never their raw bytes:
/// capacity arrays compare only their occupied part, and cells compare as
/// the renderer does.
fn expectSameValue(comptime T: type, expected: T, actual: T) !void {
    if (T == core.ClientList) {
        try expectSameValue(
            core.RequestId,
            expected.request_id,
            actual.request_id,
        );
        try expectSameValue(
            u8,
            expected.count,
            actual.count,
        );
        for (expected.entries[0..expected.count], actual.entries[0..actual.count]) |left, right| {
            try expectSameValue(
                core.ClientDescriptor,
                left,
                right,
            );
        }

        return;
    }

    if (T == core.ClientCommand) {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (comptime !std.mem.eql(
                u8,
                field.name,
                "bytes",
            )) {
                try expectSameValue(
                    field.type,
                    @field(expected, field.name),
                    @field(actual, field.name),
                );
            }
        }

        return expectSameValue(
            []const u8,
            expected.text(),
            actual.text(),
        );
    }

    if (T == core.ChangeReviewSnapshotView) {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (comptime !std.mem.eql(
                u8,
                field.name,
                "comment_storage",
            )) {
                try expectSameValue(
                    field.type,
                    @field(expected, field.name),
                    @field(actual, field.name),
                );
            }
        }

        return expectSameValue(
            []const core.ChangeReviewComment,
            expected.comments(),
            actual.comments(),
        );
    }

    if (T == core.ShmName) {
        return expectSameValue(
            []const u8,
            expected.slice(),
            actual.slice(),
        );
    }

    if (T == Cell) {
        if (!expected.eqlPublic(&actual)) {
            return error.ApiMismatch;
        }

        return;
    }

    switch (@typeInfo(T)) {
        .void => {},
        .bool, .int, .@"enum" => {
            if (expected != actual) {
                return error.ApiMismatch;
            }
        },
        .optional => |optional| {
            if ((expected == null) != (actual == null)) {
                return error.ApiMismatch;
            }

            if (expected) |value| {
                try expectSameValue(
                    optional.child,
                    value,
                    actual.?,
                );
            }
        },
        .array => |array| {
            for (expected, actual) |left, right| {
                try expectSameValue(
                    array.child,
                    left,
                    right,
                );
            }
        },
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("unexpected pointer in a decoded message: " ++ @typeName(T));
            }

            if (expected.len != actual.len) {
                return error.ApiMismatch;
            }

            for (expected, actual) |left, right| {
                try expectSameValue(
                    pointer.child,
                    left,
                    right,
                );
            }
        },
        .@"struct" => |value| {
            inline for (value.fields) |field| {
                try expectSameValue(
                    field.type,
                    @field(expected, field.name),
                    @field(actual, field.name),
                );
            }
        },
        .@"union" => {
            if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) {
                return error.ApiMismatch;
            }

            switch (expected) {
                inline else => |value, variant| {
                    try expectSameValue(
                        @TypeOf(value),
                        value,
                        @field(actual, @tagName(variant)),
                    );
                },
            }
        },
        else => @compileError("unexpected type in a decoded message: " ++ @typeName(T)),
    }
}

/// Every non-empty slice a decoded value holds lies inside `payload`.
/// Values the decoder copies (client lists, command text, shared memory
/// names) and path positions, which land in caller storage, hold none.
fn expectBorrowed(comptime T: type, value: T, payload: []const u8) !void {
    if (T == core.ClientList or T == core.ClientCommand or T == core.ShmName or T == Cell) {
        return;
    }

    if (T == core.ChangeReviewSnapshotView) {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (comptime !std.mem.eql(
                u8,
                field.name,
                "comment_storage",
            )) {
                try expectBorrowed(
                    field.type,
                    @field(value, field.name),
                    payload,
                );
            }
        }

        // The comments live in the message's own storage; their texts
        // borrow the payload.
        for (value.comments()) |comment| {
            try expectBorrowed(
                core.ChangeReviewComment,
                comment,
                payload,
            );
        }

        return;
    }

    if (T == core.PathMatch) {
        return expectBorrowed(
            []const u8,
            value.path,
            payload,
        );
    }

    switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => {},
        .optional => |optional| {
            if (value) |present| {
                try expectBorrowed(
                    optional.child,
                    present,
                    payload,
                );
            }
        },
        .array => |array| {
            for (value) |element| {
                try expectBorrowed(
                    array.child,
                    element,
                    payload,
                );
            }
        },
        .pointer => |pointer| {
            const bytes = std.mem.sliceAsBytes(value);
            const start = @intFromPtr(bytes.ptr);
            if (bytes.len != 0 and (start < @intFromPtr(payload.ptr) or start + bytes.len > @intFromPtr(payload.ptr) + payload.len)) {
                return error.SliceOutsidePayload;
            }

            for (value) |element| {
                try expectBorrowed(
                    pointer.child,
                    element,
                    payload,
                );
            }
        },
        .@"struct" => |layout| {
            inline for (layout.fields) |field| {
                try expectBorrowed(
                    field.type,
                    @field(value, field.name),
                    payload,
                );
            }
        },
        .@"union" => {
            switch (value) {
                inline else => |active| try expectBorrowed(
                    @TypeOf(active),
                    active,
                    payload,
                ),
            }
        },
        else => @compileError("unexpected type in a decoded message: " ++ @typeName(T)),
    }
}

/// Iterates every view of an accepted message from both decodes in
/// lockstep. `actual` holds the same variant as `expected`.
fn walkMessage(expected: *const ServerMessage, actual: *const ServerMessage, payload: []const u8) !Walk {
    try expectBorrowed(
        ServerMessage,
        expected.*,
        payload,
    );

    switch (expected.*) {
        .tab_snapshot => |view| {
            var first = view.panes();
            var second = actual.tab_snapshot.panes();
            return walkItems(
                &first,
                &second,
                payload,
                view.pane_count,
                .eager,
            );
        },
        .history_results => |view| {
            var first = view.entries();
            var second = actual.history_results.entries();
            return walkItems(
                &first,
                &second,
                payload,
                view.entry_count,
                .validates_fields,
            );
        },
        .workspace_snapshot => |view| {
            var first = view.tabs();
            var second = actual.workspace_snapshot.tabs();
            return walkItems(
                &first,
                &second,
                payload,
                view.tab_count,
                .eager,
            );
        },
        .agent_snapshot => |view| {
            var first = view.entries();
            var second = actual.agent_snapshot.entries();
            return walkItems(
                &first,
                &second,
                payload,
                view.entry_count,
                .eager,
            );
        },
        .workspace_list => |view| {
            var first_entries = view.entries();
            var second_entries = actual.workspace_list.entries();
            _ = try walkItems(
                &first_entries,
                &second_entries,
                payload,
                view.entry_count,
                .eager,
            );

            var first_worktrees = view.worktrees();
            var second_worktrees = actual.workspace_list.worktrees();
            return walkItems(
                &first_worktrees,
                &second_worktrees,
                payload,
                view.worktree_count,
                .eager,
            );
        },
        .client_layout_snapshot => |view| {
            var first = view.tabs();
            var second = actual.client_layout_snapshot.tabs();
            return walkItems(
                &first,
                &second,
                payload,
                view.tab_count,
                .eager,
            );
        },
        .pane_matches => |view| {
            var first = view.matches();
            var second = actual.pane_matches.matches();
            return walkItems(
                &first,
                &second,
                payload,
                view.match_count,
                .eager,
            );
        },
        .history_stats_result => |view| {
            var first = view.top();
            var second = actual.history_stats_result.top();
            return walkItems(
                &first,
                &second,
                payload,
                view.top_count,
                .validates_fields,
            );
        },
        .path_results => |view| {
            var first: PathMatchWalk = .{
                .matches = view.matches(),
            };
            var second: PathMatchWalk = .{
                .matches = actual.path_results.matches(),
            };
            return walkItems(
                &first,
                &second,
                payload,
                view.match_count,
                .eager,
            );
        },
        .pane_frame => |view| {
            if (view.text_metadata) |metadata| {
                try walkTextMetadata(metadata, payload);
            }

            var first = view.spans();
            var second = actual.pane_frame.spans();
            return walkItems(
                &first,
                &second,
                payload,
                view.span_count,
                .eager,
            );
        },
        else => return .complete,
    }
}

/// Steps two iterators over the same bytes together. Both yield the same
/// items or fail with the same error; a failure must be one `lateness`
/// allows, and a complete walk yields `count` items and consumes every byte.
fn walkItems(first: anytype, second: anytype, payload: []const u8, count: usize, lateness: Lateness) !Walk {
    var yielded: usize = 0;
    while (true) {
        const expected = first.next() catch |err| {
            if (second.next()) |_| {
                return error.IteratorMismatch;
            } else |repeated| {
                if (repeated != err) {
                    return error.IteratorMismatch;
                }
            }

            try expectLateRejection(err, lateness);
            return .consumer_rejected;
        };

        const actual = second.next() catch return error.IteratorMismatch;
        const item = expected orelse {
            if (actual != null) {
                return error.IteratorMismatch;
            }

            if (yielded != count) {
                return error.IteratorCountDiffers;
            }

            try expectConsumed(first);
            return .complete;
        };

        const other = actual orelse return error.IteratorMismatch;
        yielded += 1;
        if (yielded > count) {
            return error.IteratorCountDiffers;
        }

        try expectSameValue(
            @TypeOf(item),
            item,
            other,
        );
        try expectBorrowed(
            @TypeOf(item),
            item,
            payload,
        );
        if (try walkNested(
            item,
            other,
            payload,
        ) == .consumer_rejected) {
            return .consumer_rejected;
        }
    }
}

/// Walks the views an item holds: a tab's foregrounds, a layout's nodes and
/// a span's cells.
fn walkNested(expected: anytype, actual: @TypeOf(expected), payload: []const u8) !Walk {
    const T = @TypeOf(expected);
    if (comptime @hasDecl(T, "foregrounds")) {
        var first = expected.foregrounds();
        var second = actual.foregrounds();
        return walkItems(
            &first,
            &second,
            payload,
            expected.foreground_count,
            .eager,
        );
    }

    if (comptime @hasDecl(T, "nodes")) {
        var first = expected.nodes();
        var second = actual.nodes();
        return walkItems(
            &first,
            &second,
            payload,
            expected.node_count,
            .eager,
        );
    }

    if (comptime @hasDecl(T, "cells")) {
        var first = expected.cells();
        var second = actual.cells();
        return walkItems(
            &first,
            &second,
            payload,
            expected.cell_count,
            .validates_bytes,
        );
    }

    return .complete;
}

fn expectLateRejection(err: anyerror, lateness: Lateness) !void {
    switch (lateness) {
        .eager => return error.ValidatedViewRejected,
        .validates_fields => {
            if (err == error.Truncated) {
                return error.WalkedViewTruncated;
            }
        },
        .validates_bytes => {},
    }
}

/// A finished iterator has read the whole slice its decoder delimited.
fn expectConsumed(iterator: anytype) !void {
    const decoder = if (@TypeOf(iterator) == *PathMatchWalk) iterator.matches.decoder else iterator.decoder;
    if (decoder.index != decoder.bytes.len) {
        return error.ViewNotConsumed;
    }
}

/// Runs and links of accepted text metadata: every run names a link, every
/// link resolves inside the payload.
fn walkTextMetadata(metadata: core.TextMetadataView, payload: []const u8) !void {
    var runs = metadata.runs();
    var run_count: usize = 0;
    while (runs.next()) |run| {
        run_count += 1;
        if (run_count > metadata.run_count or metadata.link(run.link_index) == null) {
            return error.InvalidMetadataRun;
        }
    }

    if (run_count != metadata.run_count) {
        return error.InvalidMetadataRun;
    }

    for (0..metadata.link_count) |index| {
        const uri = metadata.link(@intCast(index)) orelse return error.InvalidMetadataLink;
        try expectBorrowed(
            []const u8,
            uri,
            payload,
        );
    }
}

// -- re-encoding ----------------------------------------------------------------

/// Encodes a decoded message with its tag's encoder, collecting views into
/// `owned` first. Pane frames have no re-encoding here.
fn reencode(message: *const ServerMessage, buffer: []u8) anyerror![]const u8 {
    return switch (message.*) {
        .client_list => |value| core.encodeClientList(buffer, value),
        .client_command => |value| core.encodeClientCommand(buffer, value),
        .client_command_result => |value| core.encodeClientCommandResult(buffer, value),
        .change_review_changed => |value| core.encodeChangeReviewChanged(buffer, value),
        .change_review_snapshot => |value| core.encodeChangeReviewSnapshot(buffer, value),
        .pane_opened => |value| core.encodePaneOpened(buffer, value),
        .pane_frame => unreachable,
        .pane_exited => |value| core.encodePaneExited(buffer, value),
        .request_failed => |value| core.encodeRequestFailed(buffer, value),
        .runtime_stopping => core.encodeRuntimeStopping(buffer),
        .tab_snapshot => |view| reencodeTabSnapshot(view, buffer),
        .history_results => |view| reencodeHistoryResults(view, buffer),
        .workspace_snapshot => |view| reencodeWorkspaceSnapshot(view, buffer),
        .tab_created => |value| core.encodeTabCreated(buffer, value),
        .tab_renamed => |value| core.encodeTabRenamed(buffer, value),
        .tab_closed => |value| core.encodeTabClosed(buffer, value),
        .tab_moved => |value| core.encodeTabMoved(buffer, value),
        .graphics_snapshot => |value| core.encodeGraphicsSnapshot(buffer, value),
        .graphics_image => |value| core.encodeGraphicsImage(buffer, value),
        .graphics_image_chunk => |value| core.encodeGraphicsImageChunk(buffer, value),
        .graphics_placement => |value| core.encodeGraphicsPlacement(buffer, value),
        .graphics_delete_image => |value| core.encodeGraphicsDeleteImage(buffer, value),
        .graphics_delete_placement => |value| core.encodeGraphicsDeletePlacement(buffer, value),
        .resync_required => |value| core.encodeResyncRequired(buffer, value),
        .graphics_shared_image => |value| core.encodeGraphicsSharedImage(buffer, value),
        .proxy_status => |value| core.encodeProxyStatus(buffer, value),
        .agent_snapshot => |view| reencodeAgentSnapshot(view, buffer),
        .system_metrics => |value| core.encodeSystemMetrics(buffer, value),
        .workspace_list => |view| reencodeWorkspaceList(view, buffer),
        .pane_cwd => |value| core.encodePaneCwd(buffer, value),
        .pane_foreground => |value| core.encodePaneForeground(buffer, value),
        .pane_clipboard => |value| core.encodePaneClipboard(buffer, value),
        .notification => |value| core.encodeNotification(buffer, value),
        .notification_shown => |value| core.encodeNotificationShown(buffer, value),
        .agent_sound => |value| core.encodeAgentSound(buffer, value),
        .client_layout_snapshot => |view| reencodeClientLayoutSnapshot(view, buffer),
        .pane_text => |value| core.encodePaneText(buffer, value),
        .request_completed => |value| core.encodeRequestCompleted(buffer, value),
        .pane_title => |value| core.encodePaneTitle(buffer, value),
        .pane_matches => |view| reencodePaneMatches(view, buffer),
        .history_pruned => |value| core.encodeHistoryPruned(buffer, value),
        .command_suggestion => |value| core.encodeCommandSuggestion(buffer, value),
        .history_output => |value| core.encodeHistoryOutput(buffer, value),
        .history_stats_result => |view| reencodeHistoryStats(view, buffer),
        .pane_focus_command => |value| core.encodePaneFocusCommand(buffer, value),
        .pane_focus_result => |value| core.encodePaneFocusResult(buffer, value),
        .editor_opened => |value| core.encodeEditorOpened(buffer, value),
        .path_results => |view| reencodePathResults(view, buffer),
        .pane_progress => |value| core.encodePaneProgress(buffer, value),
        .worktree_registered => |value| core.encodeWorktreeRegistered(buffer, value),
    };
}

fn collect(comptime T: type, iterator: anytype, storage: []T) ![]const T {
    var count: usize = 0;
    while (try iterator.next()) |item| {
        if (count == storage.len) {
            return error.OwnedViewFull;
        }

        storage[count] = item;
        count += 1;
    }

    return storage[0..count];
}

fn reencodeTabSnapshot(view: core.TabSnapshotView, buffer: []u8) ![]const u8 {
    var panes = view.panes();
    return core.encodeTabSnapshot(buffer, .{
        .request_id = view.request_id,
        .location = view.location,
        .panes = try collect(
            core.PaneDescriptor,
            &panes,
            &owned.panes,
        ),
    });
}

fn reencodeHistoryResults(view: core.HistoryResultsView, buffer: []u8) ![]const u8 {
    var entries = view.entries();
    return core.encodeHistoryResults(buffer, .{
        .request_id = view.request_id,
        .entries = try collect(
            core.HistoryEntry,
            &entries,
            &owned.history_entries,
        ),
        .snapshot_id = view.snapshot_id,
        .has_more = view.has_more,
    });
}

fn reencodeWorkspaceSnapshot(view: core.WorkspaceSnapshotView, buffer: []u8) ![]const u8 {
    var tabs = view.tabs();
    var tab_count: usize = 0;
    var foreground_count: usize = 0;
    while (try tabs.next()) |tab| {
        if (tab_count == owned.tabs.len) {
            return error.OwnedViewFull;
        }

        var foregrounds = tab.foregrounds();
        const collected = try collect(
            core.PaneForeground,
            &foregrounds,
            owned.foregrounds[foreground_count..],
        );
        foreground_count += collected.len;
        owned.tabs[tab_count] = .{
            .tab_id = tab.tab_id,
            .position = tab.position,
            .pane_count = tab.pane_count,
            .label = tab.label,
            .foregrounds = collected,
        };
        tab_count += 1;
    }

    return core.encodeWorkspaceSnapshot(buffer, .{
        .request_id = view.request_id,
        .workspace = view.workspace,
        .name = view.name,
        .tabs = owned.tabs[0..tab_count],
    });
}

fn reencodeAgentSnapshot(view: core.AgentSnapshotView, buffer: []u8) ![]const u8 {
    var entries = view.entries();
    return core.encodeAgentSnapshot(buffer, .{
        .revision = view.revision,
        .entries = try collect(
            core.AgentSnapshotEntry,
            &entries,
            &owned.agents,
        ),
    });
}

fn reencodeWorkspaceList(view: core.WorkspaceListView, buffer: []u8) ![]const u8 {
    var entries = view.entries();
    var worktrees = view.worktrees();
    return core.encodeWorkspaceList(buffer, .{
        .revision = view.revision,
        .entries = try collect(
            core.WorkspaceListEntry,
            &entries,
            &owned.workspaces,
        ),
        .worktrees = try collect(
            core.WorktreeListEntry,
            &worktrees,
            &owned.worktrees,
        ),
    });
}

fn reencodeClientLayoutSnapshot(view: core.ClientLayoutSnapshotView, buffer: []u8) ![]const u8 {
    var tabs = view.tabs();
    var tab_count: usize = 0;
    var node_count: usize = 0;
    while (try tabs.next()) |tab| {
        if (tab_count == owned.layout_tabs.len) {
            return error.OwnedViewFull;
        }

        var nodes = tab.nodes();
        const collected = try collect(
            core.ClientLayoutNode,
            &nodes,
            owned.layout_nodes[node_count..],
        );
        node_count += collected.len;
        owned.layout_tabs[tab_count] = .{
            .location = tab.location,
            .focused_pane = tab.focused_pane,
            .fullscreen = tab.fullscreen,
            .workspace_active = tab.workspace_active,
            .nodes = collected,
        };
        tab_count += 1;
    }

    return core.encodeClientLayoutSnapshot(buffer, .{
        .restored = view.restored,
        .sidebar_visible = view.sidebar_visible,
        .sidebar_width = view.sidebar_width,
        .workspace_list_collapsed = view.workspace_list_collapsed,
        .active_tab = view.active_tab,
        .tabs = owned.layout_tabs[0..tab_count],
    });
}

fn reencodePaneMatches(view: core.PaneMatchesView, buffer: []u8) ![]const u8 {
    var matches = view.matches();
    return core.encodePaneMatches(buffer, .{
        .request_id = view.request_id,
        .pane_id = view.pane_id,
        .truncated = view.truncated,
        .matches = try collect(
            core.SearchMatch,
            &matches,
            &owned.matches,
        ),
    });
}

fn reencodeHistoryStats(view: HistoryStatsView, buffer: []u8) ![]const u8 {
    var top = view.top();
    return core.encodeHistoryStats(buffer, .{
        .request_id = view.request_id,
        .total = view.total,
        .unique = view.unique,
        .top = try collect(
            core.HistoryStatsTop,
            &top,
            &owned.top,
        ),
    });
}

fn reencodePathResults(view: core.PathResultsView, buffer: []u8) ![]const u8 {
    var matches: PathMatchWalk = .{
        .matches = view.matches(),
    };
    var match_count: usize = 0;
    var position_count: usize = 0;
    while (try matches.next()) |match| {
        if (match_count == owned.paths.len or position_count + match.positions.len > owned.positions.len) {
            return error.OwnedViewFull;
        }

        const positions = owned.positions[position_count..][0..match.positions.len];
        @memcpy(positions, match.positions);
        position_count += positions.len;
        owned.paths[match_count] = .{
            .path = match.path,
            .kind = match.kind,
            .positions = positions,
        };
        match_count += 1;
    }

    return core.encodePathResults(buffer, .{
        .request_id = view.request_id,
        .root = view.root,
        .scanned = view.scanned,
        .complete = view.complete,
        .truncated = view.truncated,
        .matches = owned.paths[0..match_count],
    });
}

// -- seeds ----------------------------------------------------------------------

fn accepted(tag: MessageTag) Verdict {
    return .{
        .accepted = tag,
    };
}

fn rejected(err: DecodeError) Verdict {
    return .{
        .rejected = err,
    };
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(
        T,
        bytes[offset..][0..@sizeOf(T)],
        value,
        .little,
    );
}

/// One valid payload per server tag, several for tags with variants, then
/// collections at zero and at their protocol bound.
fn addValidSeeds(corpus: *SeedCorpus) !void {
    try addClientSeeds(corpus);
    try addPaneSeeds(corpus);
    try addTabSeeds(corpus);
    try addGraphicsSeeds(corpus);
    try addRuntimeSeeds(corpus);
    try addHistorySeeds(corpus);
    try addWorkspaceSeeds(corpus);
    try addAgentSeeds(corpus);
    try addLayoutSeeds(corpus);
    try addFocusSeeds(corpus);
}

fn addClientSeeds(corpus: *SeedCorpus) !void {
    var list: core.ClientList = .{
        .request_id = @enumFromInt(1),
    };
    corpus.add(
        "client_list_empty",
        try core.encodeClientList(corpus.space(), list),
        accepted(.client_list),
    );

    for (&list.entries, 1..) |*entry, index| {
        entry.* = .{
            .id = index,
            .generation = 1,
            .identity = 2,
            .attachments = 1,
            .last_input_pane = 4,
            .last_input_sequence = 5,
        };
    }

    list.count = 1;
    corpus.add(
        "client_list_one",
        try core.encodeClientList(corpus.space(), list),
        accepted(.client_list),
    );

    list.count = core.ClientList.capacity;
    corpus.add(
        "client_list_full",
        try core.encodeClientList(corpus.space(), list),
        accepted(.client_list),
    );

    var command: core.ClientCommand = .{
        .request_id = @enumFromInt(1),
        .route = .{
            .id = 1,
            .generation = 1,
        },
        .action = .tab_create,
        .target_id = 7,
        .value = -3,
    };
    try command.setText("work");
    corpus.add(
        "client_command",
        try core.encodeClientCommand(corpus.space(), command),
        accepted(.client_command),
    );

    command.status = .applied;
    try command.setText("");
    corpus.add(
        "client_command_result",
        try core.encodeClientCommandResult(corpus.space(), command),
        accepted(.client_command_result),
    );

    const changed: core.ChangeReviewChanged = .{
        .pane_id = @enumFromInt(5),
        .pane_generation = 2,
        .session = "s-1",
        .latest_edition_id = 9,
    };
    corpus.add(
        "change_review_changed",
        try core.encodeChangeReviewChanged(corpus.space(), changed),
        accepted(.change_review_changed),
    );

    var snapshot: core.ChangeReviewSnapshotView = .{
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(5),
        .pane_generation = 2,
    };
    corpus.add(
        "change_review_snapshot_empty",
        try core.encodeChangeReviewSnapshot(corpus.space(), snapshot),
        accepted(.change_review_snapshot),
    );

    snapshot.session = "s-1";
    snapshot.revision = 3;
    snapshot.patch = "--- a\n+++ b\n";
    snapshot.reviewed = true;
    snapshot.delivery = .pending;
    snapshot.status = "ready";
    for (&snapshot.comment_storage, 1..) |*comment, index| {
        comment.* = .{
            .id = index,
            .path = "a.zig",
            .first_line = 1,
            .last_line = 2,
            .body = "fix",
        };
    }

    snapshot.comment_count = 1;
    corpus.add(
        "change_review_snapshot_comment",
        try core.encodeChangeReviewSnapshot(corpus.space(), snapshot),
        accepted(.change_review_snapshot),
    );

    snapshot.comment_count = core.change_review.max_comments;
    corpus.add(
        "change_review_snapshot_full",
        try core.encodeChangeReviewSnapshot(corpus.space(), snapshot),
        accepted(.change_review_snapshot),
    );
}

fn addPaneSeeds(corpus: *SeedCorpus) !void {
    const opened: core.PaneOpened = .{
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(4),
        .location = location,
        .created = true,
        .pane_generation = 3,
    };
    corpus.add(
        "pane_opened",
        try core.encodePaneOpened(corpus.space(), opened),
        accepted(.pane_opened),
    );

    const cells = [_]Cell{.{}};
    const snapshot_spans = [_]core.Span{
        .{
            .start = 0,
            .cells = &cells,
        },
    };
    corpus.add("pane_frame_snapshot", try core.encodePaneFrame(corpus.space(), .{
        .pane_id = @enumFromInt(4),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{
            .total_rows = 1,
            .offset = 0,
        },
        .spans = &snapshot_spans,
    }), .{
        .not_reencoded = .pane_frame,
    });

    const patch_spans = [_]core.Span{
        .{
            .start = 1,
            .cells = &cells,
        },
    };
    corpus.add("pane_frame_patch", try core.encodePaneFrame(corpus.space(), .{
        .pane_id = @enumFromInt(4),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 2,
        .rows = 1,
        .cursor = .{
            .visible = true,
            .x = 1,
        },
        .scroll = .{
            .total_rows = 1,
            .offset = 0,
        },
        .spans = &patch_spans,
    }), .{
        .not_reencoded = .pane_frame,
    });

    const exited: core.PaneExited = .{
        .pane_id = @enumFromInt(4),
        .kind = .signaled,
        .value = 9,
    };
    corpus.add(
        "pane_exited",
        try core.encodePaneExited(corpus.space(), exited),
        accepted(.pane_exited),
    );

    const cwd: core.PaneCwd = .{
        .pane_id = @enumFromInt(4),
        .cwd = "/work",
    };
    corpus.add(
        "pane_cwd",
        try core.encodePaneCwd(corpus.space(), cwd),
        accepted(.pane_cwd),
    );

    const foreground: core.PaneForeground = .{
        .pane_id = @enumFromInt(4),
        .name = "zsh",
    };
    corpus.add(
        "pane_foreground",
        try core.encodePaneForeground(corpus.space(), foreground),
        accepted(.pane_foreground),
    );

    const clipboard: core.PaneClipboard = .{
        .pane_id = @enumFromInt(4),
        .bytes = "copied",
    };
    corpus.add(
        "pane_clipboard",
        try core.encodePaneClipboard(corpus.space(), clipboard),
        accepted(.pane_clipboard),
    );

    var text: core.PaneText = .{
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(4),
        .truncated = true,
        .text = "$ ls\n",
        .exit_code = 1,
    };
    corpus.add(
        "pane_text_exited",
        try core.encodePaneText(corpus.space(), text),
        accepted(.pane_text),
    );

    text.exit_code = null;
    text.truncated = false;
    corpus.add(
        "pane_text_running",
        try core.encodePaneText(corpus.space(), text),
        accepted(.pane_text),
    );

    var title: core.PaneTitle = .{
        .pane_id = @enumFromInt(4),
        .title = "vim",
    };
    corpus.add(
        "pane_title",
        try core.encodePaneTitle(corpus.space(), title),
        accepted(.pane_title),
    );

    title.title = "";
    corpus.add(
        "pane_title_cleared",
        try core.encodePaneTitle(corpus.space(), title),
        accepted(.pane_title),
    );

    var matches: [core.max_search_matches]core.SearchMatch = undefined;
    for (&matches, 0..) |*match, index| {
        match.* = .{
            .x = @intCast(index),
            .y = 3,
            .len = 2,
        };
    }

    const bounds = [_]usize{ 0, 2, core.max_search_matches };
    const names = [_][]const u8{ "pane_matches_empty", "pane_matches_two", "pane_matches_full" };
    for (bounds, names) |count, name| {
        corpus.add(name, try core.encodePaneMatches(corpus.space(), .{
            .request_id = @enumFromInt(1),
            .pane_id = @enumFromInt(4),
            .truncated = count == core.max_search_matches,
            .matches = matches[0..count],
        }), accepted(.pane_matches));
    }

    const progress = [_]core.PaneProgress{
        .{
            .pane_id = @enumFromInt(4),
            .state = .set,
            .percent = 40,
        },
        .{
            .pane_id = @enumFromInt(4),
            .state = .indeterminate,
        },
        .{
            .pane_id = @enumFromInt(4),
            .state = .@"error",
        },
    };
    const progress_names = [_][]const u8{ "pane_progress_set", "pane_progress_indeterminate", "pane_progress_error" };
    for (progress, progress_names) |value, name| {
        corpus.add(
            name,
            try core.encodePaneProgress(corpus.space(), value),
            accepted(.pane_progress),
        );
    }
}

fn addTabSeeds(corpus: *SeedCorpus) !void {
    var panes: [core.max_panes_per_tab]core.PaneDescriptor = undefined;
    for (&panes, 1..) |*pane, index| {
        pane.* = .{
            .pane_id = @enumFromInt(index),
            .lifecycle = if (index % 2 == 0) .exited else .running,
            .pane_generation = index,
        };
    }

    const bounds = [_]usize{ 0, 2, core.max_panes_per_tab };
    const names = [_][]const u8{ "tab_snapshot_empty", "tab_snapshot_two", "tab_snapshot_full" };
    for (bounds, names) |count, name| {
        corpus.add(name, try core.encodeTabSnapshot(corpus.space(), .{
            .request_id = @enumFromInt(1),
            .location = location,
            .panes = panes[0..count],
        }), accepted(.tab_snapshot));
    }

    var created: core.TabCreated = .{
        .request_id = @enumFromInt(1),
        .location = location,
        .position = 2,
        .label = "",
        .root_pane_id = @enumFromInt(4),
        .pane_generation = 1,
    };
    corpus.add(
        "tab_created_automatic",
        try core.encodeTabCreated(corpus.space(), created),
        accepted(.tab_created),
    );

    created.label = "logs";
    created.location = worktree_location;
    corpus.add(
        "tab_created_labelled",
        try core.encodeTabCreated(corpus.space(), created),
        accepted(.tab_created),
    );

    const renamed: core.TabRenamed = .{
        .request_id = @enumFromInt(1),
        .location = location,
        .label = "build",
    };
    corpus.add(
        "tab_renamed",
        try core.encodeTabRenamed(corpus.space(), renamed),
        accepted(.tab_renamed),
    );

    var closed: core.TabClosed = .{
        .request_id = .none,
        .location = location,
        .workspace_closed = false,
    };
    corpus.add(
        "tab_closed",
        try core.encodeTabClosed(corpus.space(), closed),
        accepted(.tab_closed),
    );

    closed.request_id = @enumFromInt(1);
    closed.workspace_closed = true;
    closed.previous_workspace = @enumFromInt(8);
    corpus.add(
        "tab_closed_workspace",
        try core.encodeTabClosed(corpus.space(), closed),
        accepted(.tab_closed),
    );

    const moved: core.TabMoved = .{
        .request_id = @enumFromInt(1),
        .location = location,
        .position = 0,
    };
    corpus.add(
        "tab_moved",
        try core.encodeTabMoved(corpus.space(), moved),
        accepted(.tab_moved),
    );
}

fn addGraphicsSeeds(corpus: *SeedCorpus) !void {
    const snapshot: core.Snapshot = .{
        .pane_id = @enumFromInt(4),
        .revision = 1,
        .phase = .begin,
    };
    corpus.add(
        "graphics_snapshot",
        try core.encodeGraphicsSnapshot(corpus.space(), snapshot),
        accepted(.graphics_snapshot),
    );

    const image: core.Image = .{
        .key = image_key,
        .format = .rgba,
        .width = 2,
        .height = 2,
        .byte_len = 16,
    };
    const graphics_image: core.SchemaImage = .{
        .pane_id = @enumFromInt(4),
        .revision = 1,
        .image = image,
    };
    corpus.add(
        "graphics_image",
        try core.encodeGraphicsImage(corpus.space(), graphics_image),
        accepted(.graphics_image),
    );

    const chunk: core.ImageChunk = .{
        .pane_id = @enumFromInt(4),
        .revision = 1,
        .key = image_key,
        .offset = 8,
        .bytes = "abcd",
    };
    corpus.add(
        "graphics_image_chunk",
        try core.encodeGraphicsImageChunk(corpus.space(), chunk),
        accepted(.graphics_image_chunk),
    );

    const placement: core.SchemaPlacement = .{
        .pane_id = @enumFromInt(4),
        .revision = 1,
        .placement = .{
            .key = image_key,
            .virtual_id = 3,
            .placement_id = 0,
            .x = -1,
            .y = 2,
            .columns = 4,
            .rows = 2,
            .z_index = -5,
        },
    };
    corpus.add(
        "graphics_placement",
        try core.encodeGraphicsPlacement(corpus.space(), placement),
        accepted(.graphics_placement),
    );

    const delete_image: core.DeleteImage = .{
        .pane_id = @enumFromInt(4),
        .revision = 2,
        .key = image_key,
    };
    corpus.add(
        "graphics_delete_image",
        try core.encodeGraphicsDeleteImage(corpus.space(), delete_image),
        accepted(.graphics_delete_image),
    );

    const delete_placement: core.DeletePlacement = .{
        .pane_id = @enumFromInt(4),
        .revision = 2,
        .key = image_key,
        .virtual_id = 3,
        .placement_id = 1,
    };
    corpus.add(
        "graphics_delete_placement",
        try core.encodeGraphicsDeletePlacement(corpus.space(), delete_placement),
        accepted(.graphics_delete_placement),
    );

    const shared: core.SharedImage = .{
        .pane_id = @enumFromInt(4),
        .revision = 1,
        .image = image,
        .name = try core.ShmName.init("/telar-1a2b"),
    };
    corpus.add(
        "graphics_shared_image",
        try core.encodeGraphicsSharedImage(corpus.space(), shared),
        accepted(.graphics_shared_image),
    );
}

fn addRuntimeSeeds(corpus: *SeedCorpus) !void {
    var failed: core.RequestFailed = .{
        .request_id = .none,
        .code = .pane_not_found,
        .message = "no pane",
    };
    corpus.add(
        "request_failed",
        try core.encodeRequestFailed(corpus.space(), failed),
        accepted(.request_failed),
    );

    failed.request_id = @enumFromInt(1);
    failed.message = "";
    corpus.add(
        "request_failed_empty",
        try core.encodeRequestFailed(corpus.space(), failed),
        accepted(.request_failed),
    );

    corpus.add(
        "runtime_stopping",
        try core.encodeRuntimeStopping(corpus.space()),
        accepted(.runtime_stopping),
    );

    var proxy: core.ProxyStatus = .{
        .active = true,
        .scope = .wildcard,
        .system_trusted = true,
        .port = 8080,
        .preferred_port = 8081,
    };
    corpus.add(
        "proxy_status_bound",
        try core.encodeProxyStatus(corpus.space(), proxy),
        accepted(.proxy_status),
    );

    proxy = .{
        .active = false,
        .scope = .exact,
        .system_trusted = false,
    };
    corpus.add(
        "proxy_status_disabled",
        try core.encodeProxyStatus(corpus.space(), proxy),
        accepted(.proxy_status),
    );

    const metrics: core.SystemMetrics = .{
        .revision = 1,
        .cpu_percent = 40,
        .memory_used_decigib = 120,
        .has_battery = true,
        .battery_percent = 90,
        .cpu_count = 8,
        .memory_total_decigib = 320,
    };
    corpus.add(
        "system_metrics",
        try core.encodeSystemMetrics(corpus.space(), metrics),
        accepted(.system_metrics),
    );

    const completed: core.RequestCompleted = .{
        .request_id = @enumFromInt(1),
    };
    corpus.add(
        "request_completed",
        try core.encodeRequestCompleted(corpus.space(), completed),
        accepted(.request_completed),
    );

    var notification: core.Notification = .{
        .level = .warning,
        .target = .{
            .pane = @enumFromInt(4),
        },
        .title = "Build",
        .message = "finished",
    };
    corpus.add(
        "notification_pane",
        try core.encodeNotification(corpus.space(), notification),
        accepted(.notification),
    );

    notification.target = .none;
    notification.link = "https://example.com/run";
    corpus.add(
        "notification_link",
        try core.encodeNotification(corpus.space(), notification),
        accepted(.notification),
    );

    const shown: core.NotificationShown = .{
        .request_id = @enumFromInt(1),
        .delivered_clients = 2,
    };
    corpus.add(
        "notification_shown",
        try core.encodeNotificationShown(corpus.space(), shown),
        accepted(.notification_shown),
    );

    var suggestion: core.CommandSuggestion = .{
        .request_id = @enumFromInt(1),
        .status = .ready,
        .text = "ls -la",
    };
    corpus.add(
        "command_suggestion_ready",
        try core.encodeCommandSuggestion(corpus.space(), suggestion),
        accepted(.command_suggestion),
    );

    suggestion.status = .unavailable;
    suggestion.text = "";
    corpus.add(
        "command_suggestion_unavailable",
        try core.encodeCommandSuggestion(corpus.space(), suggestion),
        accepted(.command_suggestion),
    );

    var opened: core.EditorOpened = .{
        .request_id = @enumFromInt(1),
        .outcome = .opened,
        .pane_id = @enumFromInt(4),
        .pane_generation = 1,
    };
    corpus.add(
        "editor_opened",
        try core.encodeEditorOpened(corpus.space(), opened),
        accepted(.editor_opened),
    );

    opened = .{
        .request_id = @enumFromInt(1),
        .outcome = .missing,
    };
    corpus.add(
        "editor_missing",
        try core.encodeEditorOpened(corpus.space(), opened),
        accepted(.editor_opened),
    );

    const registered: core.WorktreeRegistered = .{
        .request_id = @enumFromInt(1),
        .worktree = @enumFromInt(2),
        .created = true,
    };
    corpus.add(
        "worktree_registered",
        try core.encodeWorktreeRegistered(corpus.space(), registered),
        accepted(.worktree_registered),
    );

    var paths: [core.max_path_results]core.PathMatch = undefined;
    for (&paths) |*match| {
        match.* = .{
            .path = "p",
            .kind = .file,
        };
    }

    const positions = [_]u16{ 0, 4 };
    paths[0] = .{
        .path = "src/main.zig",
        .kind = .file,
        .positions = &positions,
    };
    paths[1] = .{
        .path = "src/",
        .kind = .directory,
    };

    const bounds = [_]usize{ 0, 2, core.max_path_results };
    const names = [_][]const u8{ "path_results_empty", "path_results_two", "path_results_full" };
    for (bounds, names) |count, name| {
        corpus.add(name, try core.encodePathResults(corpus.space(), .{
            .request_id = @enumFromInt(1),
            .root = "/work",
            .scanned = 30,
            .complete = count != core.max_path_results,
            .truncated = count == core.max_path_results,
            .matches = paths[0..count],
        }), accepted(.path_results));
    }
}

fn historyEntry(index: usize) core.HistoryEntry {
    return .{
        .id = index + 1,
        .pane_id = @enumFromInt(4),
        .started_at_ms = 1000,
        .duration_ns = 5,
        .exit_code = if (index % 2 == 0) 0 else null,
        .status = .completed,
        .author = .agent,
        .origin = .hook,
        .provider = "claude",
        .command = "zig build",
        .cwd = "/work/telar",
        .workspace_path = "/work/telar",
    };
}

fn addHistorySeeds(corpus: *SeedCorpus) !void {
    var entries: [core.max_history_results]core.HistoryEntry = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = historyEntry(index);
    }

    const bounds = [_]usize{ 0, 1, core.max_history_results };
    const names = [_][]const u8{ "history_results_empty", "history_results_one", "history_results_full" };
    for (bounds, names) |count, name| {
        corpus.add(name, try core.encodeHistoryResults(corpus.space(), .{
            .request_id = @enumFromInt(1),
            .entries = entries[0..count],
            .snapshot_id = 900,
            .has_more = count == 0,
        }), accepted(.history_results));
    }

    const pruned: core.HistoryPruned = .{
        .request_id = @enumFromInt(1),
        .removed = 3,
    };
    corpus.add(
        "history_pruned",
        try core.encodeHistoryPruned(corpus.space(), pruned),
        accepted(.history_pruned),
    );

    const output: core.HistoryOutput = .{
        .request_id = @enumFromInt(1),
        .id = 11,
        .truncated = true,
        .observed_bytes = 90,
        .content = "error: exit 1\n",
    };
    corpus.add(
        "history_output",
        try core.encodeHistoryOutput(corpus.space(), output),
        accepted(.history_output),
    );

    var top: [core.max_history_stats_top]core.HistoryStatsTop = undefined;
    for (&top, 0..) |*row, index| {
        row.* = .{
            .count = 30 - index,
            .command = "git status",
        };
    }

    const top_bounds = [_]usize{ 0, 1, core.max_history_stats_top };
    const top_names = [_][]const u8{ "history_stats_empty", "history_stats_one", "history_stats_full" };
    for (top_bounds, top_names) |count, name| {
        corpus.add(name, try core.encodeHistoryStats(corpus.space(), .{
            .request_id = @enumFromInt(1),
            .total = 120,
            .unique = 40,
            .top = top[0..count],
        }), accepted(.history_stats_result));
    }
}

fn addWorkspaceSeeds(corpus: *SeedCorpus) !void {
    const foregrounds = [_]core.PaneForeground{
        .{
            .pane_id = @enumFromInt(5),
            .name = "zsh",
        },
    };
    var tabs: [core.max_tabs_per_workspace]core.TabDescriptor = undefined;
    for (&tabs, 0..) |*tab, index| {
        tab.* = .{
            .tab_id = @enumFromInt(index + 1),
            .position = @intCast(index),
            .pane_count = 1,
            .label = "",
        };
    }

    tabs[0].label = "logs";
    tabs[0].foregrounds = &foregrounds;
    corpus.add("workspace_snapshot_empty", try core.encodeWorkspaceSnapshot(corpus.space(), .{
        .request_id = @enumFromInt(1),
        .workspace = location.workspace,
        .name = "agents",
        .tabs = &.{},
    }), accepted(.workspace_snapshot));

    corpus.add("workspace_snapshot_worktree", try core.encodeWorkspaceSnapshot(corpus.space(), .{
        .request_id = @enumFromInt(1),
        .workspace = worktree_location.workspace,
        .name = "agents",
        .tabs = tabs[0..1],
    }), accepted(.workspace_snapshot));

    corpus.add("workspace_snapshot_full", try core.encodeWorkspaceSnapshot(corpus.space(), .{
        .request_id = @enumFromInt(1),
        .workspace = location.workspace,
        .name = "agents",
        .tabs = &tabs,
    }), accepted(.workspace_snapshot));

    const resync: core.ResyncRequired = .{
        .workspace = location.workspace,
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(8),
    };
    corpus.add(
        "resync_required",
        try core.encodeResyncRequired(corpus.space(), resync),
        accepted(.resync_required),
    );

    var workspaces: [core.max_workspace_list_entries]core.WorkspaceListEntry = undefined;
    for (&workspaces, 1..) |*entry, index| {
        entry.* = .{
            .workspace = @enumFromInt(index),
            .name = "w",
            .path = "/",
            .tab_count = 1,
        };
    }

    workspaces[0] = .{
        .workspace = @enumFromInt(1),
        .name = "agents",
        .path = "/work",
        .tab_count = 2,
        .branch = "main",
        .dirty = true,
    };

    const worktrees = [_]core.WorktreeListEntry{
        .{
            .worktree = @enumFromInt(2),
            .source = @enumFromInt(1),
            .workspace = @enumFromInt(9),
            .created_by = @enumFromInt(4),
            .path = "/work/fix",
            .branch = "fix",
            .base = "main",
            .title = "Fix",
            .brief = "two\nlines",
            .diff_added = 3,
            .command_label = "test",
            .command_state = .exited,
            .command_exit = 1,
        },
    };
    corpus.add("workspace_list_empty", try core.encodeWorkspaceList(corpus.space(), .{
        .revision = 1,
        .entries = &.{},
    }), accepted(.workspace_list));

    corpus.add("workspace_list_worktree", try core.encodeWorkspaceList(corpus.space(), .{
        .revision = 2,
        .entries = workspaces[0..1],
        .worktrees = &worktrees,
    }), accepted(.workspace_list));

    corpus.add("workspace_list_full", try core.encodeWorkspaceList(corpus.space(), .{
        .revision = 3,
        .entries = &workspaces,
    }), accepted(.workspace_list));
}

fn agentEntry(index: usize) core.AgentSnapshotEntry {
    return .{
        .pane_id = @enumFromInt(index + 1),
        .pane_generation = 1,
        .location = location,
        .pane_index = 1,
        .process_id = 100,
        .session_id = @splat(1),
        .provider = .claude,
        .provider_name = "claude",
        .display_name = "Claude Code",
        .status = .working,
        .source = .lifecycle_report,
        .authority = .active,
        .confidence = 90,
        .sequence = 1,
        .observed_at_ms = 1000,
        .expires_at_ms = 2000,
    };
}

fn addAgentSeeds(corpus: *SeedCorpus) !void {
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = agentEntry(index);
    }

    entries[0].status = .blocked;
    entries[0].blocked_reason = .question;
    entries[0].title_source = .manual;
    entries[0].title_state = .ready;
    entries[0].session_title = "Fix the build";
    entries[0].final_message = "done\nall green";
    entries[0].plan_done = 1;
    entries[0].plan_total = 2;
    entries[0].plan_step = "run tests";

    const bounds = [_]usize{ 0, 1, core.max_agent_snapshot_entries };
    const names = [_][]const u8{ "agent_snapshot_empty", "agent_snapshot_one", "agent_snapshot_full" };
    for (bounds, names) |count, name| {
        corpus.add(name, try core.encodeAgentSnapshot(corpus.space(), .{
            .revision = 1,
            .entries = entries[0..count],
        }), accepted(.agent_snapshot));
    }

    const sound: core.AgentSoundNotification = .{
        .pane_id = @enumFromInt(4),
        .pane_generation = 1,
        .sound = .needs_input,
    };
    corpus.add(
        "agent_sound",
        try core.encodeAgentSound(corpus.space(), sound),
        accepted(.agent_sound),
    );
}

fn addLayoutSeeds(corpus: *SeedCorpus) !void {
    corpus.add("client_layout_snapshot_empty", try core.encodeClientLayoutSnapshot(corpus.space(), .{
        .restored = false,
    }), accepted(.client_layout_snapshot));

    const nodes = [_]core.ClientLayoutNode{
        .{
            .split = .{
                .axis = .vertical,
                .ratio = 6000,
            },
        },
        .{
            .pane = .{
                .id = @enumFromInt(5),
            },
        },
        .{
            .pane = .{
                .id = @enumFromInt(6),
            },
        },
    };
    const single = nodes[1..2];
    var tabs: [core.max_client_layout_tabs]core.ClientTabLayout = undefined;
    for (&tabs, 1..) |*tab, index| {
        tab.* = .{
            .location = .{
                .workspace = location.workspace,
                .tab_id = @enumFromInt(index),
            },
            .focused_pane = @enumFromInt(5),
            .fullscreen = false,
            .nodes = single,
        };
    }

    tabs[0].nodes = &nodes;
    tabs[0].workspace_active = true;
    tabs[0].fullscreen = true;
    const bounds = [_]usize{ 1, core.max_client_layout_tabs };
    const names = [_][]const u8{ "client_layout_snapshot_split", "client_layout_snapshot_full" };
    for (bounds, names) |count, name| {
        corpus.add(name, try core.encodeClientLayoutSnapshot(corpus.space(), .{
            .restored = true,
            .sidebar_width = 30,
            .active_tab = tabs[0].location,
            .tabs = tabs[0..count],
        }), accepted(.client_layout_snapshot));
    }
}

fn addFocusSeeds(corpus: *SeedCorpus) !void {
    const command: core.PaneFocusCommand = .{
        .requester = .{
            .id = 1,
            .generation = 2,
        },
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(4),
        .pane_generation = 1,
        .direction = .down,
    };
    corpus.add(
        "pane_focus_command",
        try core.encodePaneFocusCommand(corpus.space(), command),
        accepted(.pane_focus_command),
    );

    var result: core.PaneFocusResult = .{
        .request_id = @enumFromInt(1),
        .outcome = .focused,
        .focused_pane_id = @enumFromInt(5),
    };
    corpus.add(
        "pane_focus_result",
        try core.encodePaneFocusResult(corpus.space(), result),
        accepted(.pane_focus_result),
    );

    result.outcome = .no_neighbor;
    result.focused_pane_id = @enumFromInt(0);
    corpus.add(
        "pane_focus_result_none",
        try core.encodePaneFocusResult(corpus.space(), result),
        accepted(.pane_focus_result),
    );
}

fn seedNamed(corpus: *const SeedCorpus, name: []const u8) []const u8 {
    for (corpus.list()) |seed| {
        if (std.mem.eql(
            u8,
            seed.name,
            name,
        )) {
            return seed.payload;
        }
    }

    std.debug.panic("no seed named {s}", .{name});
}

/// Changes one byte of a seed copy. Example: `withByte(corpus.copy(seed), 9, 2)`.
fn withByte(bytes: []u8, offset: usize, byte: u8) []u8 {
    bytes[offset] = byte;
    return bytes;
}

/// Mutations of the valid seeds: unknown and wrong-side tags, inconsistent
/// counts, flags and lengths, trailing bytes, and the accepted payloads a
/// late consumer or the encoder refuses. Offsets follow each encoder's field
/// order.
fn addMutatedSeeds(corpus: *SeedCorpus) !void {
    corpus.add(
        "empty",
        corpus.space()[0..0],
        rejected(error.Truncated),
    );

    const unknown_tags = [_]u8{ 0x00, 0x01, 0x42, 0x80, 0xb5, 0xff };
    for (unknown_tags) |tag| {
        const bytes = corpus.space()[0..1];
        bytes[0] = tag;
        corpus.add(
            "unknown_tag",
            bytes,
            rejected(error.UnknownMessage),
        );
    }

    // tab_snapshot: tag, request id, location (kind, workspace, tab), pane
    // count, then 17 bytes per pane: id, lifecycle, generation.
    const tab_snapshot = seedNamed(corpus, "tab_snapshot_two");
    const pane_count_offset = 1 + 8 + 17;
    const first_pane_offset = pane_count_offset + 2;
    const pane_size = 17;
    var bytes = corpus.copy(tab_snapshot);
    writeInt(
        u16,
        bytes,
        pane_count_offset,
        core.max_panes_per_tab + 1,
    );
    corpus.add(
        "tab_snapshot_count_over_bound",
        bytes,
        rejected(error.TooManyPanes),
    );

    bytes = corpus.copy(tab_snapshot);
    writeInt(
        u16,
        bytes,
        pane_count_offset,
        3,
    );
    corpus.add(
        "tab_snapshot_count_past_end",
        bytes,
        rejected(error.Truncated),
    );

    bytes = corpus.copy(tab_snapshot);
    writeInt(
        u16,
        bytes,
        pane_count_offset,
        1,
    );
    corpus.add(
        "tab_snapshot_count_short",
        bytes,
        rejected(error.TrailingBytes),
    );

    corpus.add(
        "tab_snapshot_lifecycle",
        withByte(
            corpus.copy(tab_snapshot),
            first_pane_offset + 8,
            2,
        ),
        rejected(error.InvalidPaneLifecycle),
    );

    bytes = corpus.copy(tab_snapshot);
    @memcpy(bytes[first_pane_offset + pane_size ..][0..8], bytes[first_pane_offset..][0..8]);
    corpus.add(
        "tab_snapshot_duplicate_pane",
        bytes,
        rejected(error.DuplicatePane),
    );

    // pane_opened: the request id follows the tag.
    bytes = corpus.copy(seedNamed(corpus, "pane_opened"));
    writeInt(
        u64,
        bytes,
        1,
        0,
    );
    corpus.add(
        "pane_opened_request_none",
        bytes,
        rejected(error.InvalidRequestId),
    );

    // pane_text: tag, request id, pane id, then the truncated flag.
    corpus.add(
        "pane_text_flag",
        withByte(
            corpus.copy(seedNamed(corpus, "pane_text_exited")),
            1 + 8 + 8,
            2,
        ),
        rejected(error.InvalidBoolean),
    );

    // pane_title: tag, pane id, then the title length.
    bytes = corpus.copy(seedNamed(corpus, "pane_title"));
    writeInt(
        u16,
        bytes,
        1 + 8,
        std.math.maxInt(u16),
    );
    corpus.add(
        "pane_title_length_past_end",
        bytes,
        rejected(error.Truncated),
    );

    // workspace_snapshot: tag, request id, location, name "agents", tab
    // count, then the first tab's id and position.
    const tab_position_offset = 1 + 8 + 9 + 2 + "agents".len + 2 + 8;
    bytes = corpus.copy(seedNamed(corpus, "workspace_snapshot_worktree"));
    writeInt(
        u16,
        bytes,
        tab_position_offset,
        1,
    );
    corpus.add(
        "workspace_snapshot_position",
        bytes,
        rejected(error.InvalidTabPosition),
    );

    // history_results: tag, request id, then the entry count.
    bytes = corpus.copy(seedNamed(corpus, "history_results_one"));
    writeInt(
        u16,
        bytes,
        1 + 8,
        core.max_history_results + 1,
    );
    corpus.add(
        "history_results_count_over_bound",
        bytes,
        rejected(error.TooManyHistoryResults),
    );

    // The first entry starts after the snapshot id and has_more; its status
    // follows id, pane, start, duration and a present exit code. The decoder
    // walks entry boundaries only, so the iterator refuses it.
    const history_status_offset = 1 + 8 + 2 + 8 + 1 + 32 + 1 + 4;
    corpus.add("history_results_status", withByte(
        corpus.copy(seedNamed(corpus, "history_results_one")),
        history_status_offset,
        9,
    ), .{
        .consumer_rejected = .history_results,
    });

    // client_list: tag, request id, then the count.
    corpus.add(
        "client_list_over_capacity",
        withByte(
            corpus.copy(seedNamed(corpus, "client_list_full")),
            1 + 8,
            core.ClientList.capacity + 1,
        ),
        rejected(error.InvalidClientList),
    );

    // change_review_snapshot with empty texts: tag, three ids, empty session,
    // five edition ids, source, empty patch, then the comment count.
    const comment_count_offset = 1 + 24 + 4 + 40 + 1 + 4;
    corpus.add(
        "change_review_comments_over_bound",
        withByte(
            corpus.copy(seedNamed(corpus, "change_review_snapshot_empty")),
            comment_count_offset,
            core.change_review.max_comments + 1,
        ),
        rejected(error.InvalidChangeReview),
    );

    // client_layout_snapshot: tag, restored, sidebar visible, then the width
    // an unrestored layout must leave at zero.
    bytes = corpus.copy(seedNamed(corpus, "client_layout_snapshot_empty"));
    writeInt(
        u16,
        bytes,
        3,
        30,
    );
    corpus.add(
        "client_layout_empty_width",
        bytes,
        rejected(error.InvalidEmptyClientLayout),
    );

    // pane_progress: tag, pane id, state, then 255 for no percent.
    corpus.add(
        "pane_progress_set_without_percent",
        withByte(
            corpus.copy(seedNamed(corpus, "pane_progress_set")),
            1 + 8 + 1,
            255,
        ),
        rejected(error.MissingProgressPercent),
    );

    // graphics_image: tag, pane, revision, key, format, width, height, then
    // the byte length that must equal width * height * 4.
    bytes = corpus.copy(seedNamed(corpus, "graphics_image"));
    writeInt(
        u64,
        bytes,
        1 + 8 + 8 + 12 + 1 + 4 + 4,
        17,
    );
    corpus.add(
        "graphics_image_length",
        bytes,
        rejected(error.InvalidImageLength),
    );

    // pane_frame patch: the body header, no metadata, one span header, then
    // the first cell's header. A cell without a style bit needs a previous
    // style, so the frame is structurally valid and `CellReader` refuses it.
    const first_cell_offset = 1 + 61 + 12;
    corpus.add("pane_frame_cell", withByte(
        corpus.copy(seedNamed(corpus, "pane_frame_patch")),
        first_cell_offset,
        0x01,
    ), .{
        .consumer_rejected = .pane_frame,
    });

    const moved = seedNamed(corpus, "tab_moved");
    bytes = corpus.space()[0 .. moved.len + 1];
    @memcpy(bytes[0..moved.len], moved);
    bytes[moved.len] = 0;
    corpus.add(
        "tab_moved_trailing",
        bytes,
        rejected(error.TrailingBytes),
    );

    // history_stats_result: tag, request id, total, unique, count, then the
    // first row's count and command. An empty command passes the decoder's
    // length walk and fails the iterator.
    const stats = seedNamed(corpus, "history_stats_one");
    const command_length_offset = 1 + 8 + 8 + 8 + 1 + 8;
    bytes = corpus.space()[0 .. command_length_offset + 2];
    @memcpy(bytes[0..command_length_offset], stats[0..command_length_offset]);
    writeInt(
        u16,
        bytes,
        command_length_offset,
        0,
    );
    corpus.add("history_stats_empty_command", bytes, .{
        .consumer_rejected = .history_stats_result,
    });

    // A NUL inside a stats command or history output passes the decoder and
    // the iterator; only the encoder refuses it.
    corpus.add("history_stats_nul_command", withByte(
        corpus.copy(stats),
        command_length_offset + 2,
        0,
    ), .{
        .encoder_rejected = .history_stats_result,
    });

    const output = seedNamed(corpus, "history_output");
    corpus.add("history_output_nul", withByte(
        corpus.copy(output),
        output.len - 1,
        0,
    ), .{
        .encoder_rejected = .history_output,
    });
}

/// Builds every seed into `seed_corpus` and the fuzz corpus from those that
/// fit `payload_capacity`, in `std.testing.Smith` input form: one `slice`
/// call reads a little-endian u32 length and then that many bytes. A crash
/// the fuzzer saves has the same form.
fn buildCorpus() ![]const []const u8 {
    seed_corpus = .{};
    try addValidSeeds(&seed_corpus);
    try addMutatedSeeds(&seed_corpus);

    var used: usize = 0;
    var count: usize = 0;
    for (seed_corpus.list()) |seed| {
        if (seed.payload.len > payload_capacity) {
            continue;
        }

        const entry = corpus_bytes[used..][0 .. smith_length_size + seed.payload.len];
        std.mem.writeInt(
            u32,
            entry[0..smith_length_size],
            @intCast(seed.payload.len),
            .little,
        );
        @memcpy(entry[smith_length_size..], seed.payload);
        corpus_entries[count] = entry;
        used += entry.len;
        count += 1;
    }

    for (replayed_inputs) |input| {
        corpus_entries[count] = input;
        count += 1;
    }

    return corpus_entries[0..count];
}

// -- tests ----------------------------------------------------------------------

/// One edit the fuzzer may apply to the payload it read.
const PatchKind = enum(u8) { byte, int16, int32, truncate, insert };

/// Edits read after the payload. Zig 0.16.0's fuzzer mutates a slice as a
/// stream from its first byte, so a change deep inside a seed, such as one
/// byte of a length or a flag, is rare; each patch's kind, offset and value
/// are integers the fuzzer mutates on their own, and reach any offset.
const max_patches = 4;

/// Patch values: small numbers and boundaries as often as all the others,
/// because counts, lengths, flags and tags live there.
const patch_value_weights = [_]std.testing.Smith.Weight{
    .rangeAtMost(
        u32,
        0,
        0x101,
        1 << 24,
    ),
    .value(
        u32,
        std.math.maxInt(u16),
        1 << 30,
    ),
    .value(
        u32,
        std.math.maxInt(u32),
        1 << 30,
    ),
    .rangeAtMost(
        u32,
        0,
        std.math.maxInt(u32),
        1,
    ),
};

/// Reads a payload, then up to `max_patches` edits while the input goes on.
/// A seed holds only the payload, so it replays unchanged: past the end of
/// the input, `eos` is true.
fn readPayload(smith: *std.testing.Smith, buffer: *[payload_capacity]u8) []u8 {
    var length: usize = smith.slice(buffer);
    var patches: usize = 0;
    while (patches < max_patches and !smith.eosWeightedSimple(1, 1)) : (patches += 1) {
        const kind = smith.value(PatchKind);
        const offset = smith.valueRangeLessThan(
            u16,
            0,
            payload_capacity,
        );
        const value = smith.valueWeighted(u32, &patch_value_weights);
        length = patch(
            buffer,
            length,
            kind,
            offset,
            value,
        );
    }

    return buffer[0..length];
}

/// Applies one edit at `offset` wrapped into the payload and returns the new
/// length. Integers are written little-endian, as the wire writes them.
fn patch(buffer: *[payload_capacity]u8, length: usize, kind: PatchKind, offset: u16, value: u32) usize {
    switch (kind) {
        .truncate => return offset % (length + 1),
        .insert => {
            if (length == buffer.len) {
                return length;
            }

            const at = offset % (length + 1);
            std.mem.copyBackwards(
                u8,
                buffer[at + 1 .. length + 1],
                buffer[at..length],
            );
            buffer[at] = @truncate(value);
            return length + 1;
        },
        .byte => {
            if (length != 0) {
                buffer[offset % length] = @truncate(value);
            }

            return length;
        },
        .int16 => return patchInt(
            u16,
            buffer[0..length],
            offset,
            @truncate(value),
        ),
        .int32 => return patchInt(
            u32,
            buffer[0..length],
            offset,
            value,
        ),
    }
}

fn patchInt(comptime T: type, payload: []u8, offset: u16, value: T) usize {
    if (payload.len >= @sizeOf(T)) {
        writeInt(
            T,
            payload,
            offset % (payload.len - @sizeOf(T) + 1),
            value,
        );
    }

    return payload.len;
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn decodeFuzzedServerMessage(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [payload_capacity]u8 = undefined;
    const payload = readPayload(smith, &buffer);
    _ = checkServerPayload(payload) catch |err| {
        std.debug.panic("server message property failed: {t} for payload {x}", .{ err, payload });
    };
}

test "every server fuzz seed reaches its verdict" {
    _ = try buildCorpus();
    for (seed_corpus.list()) |seed| {
        const verdict = checkServerPayload(seed.payload) catch |err| {
            std.debug.print("seed {s} broke a property: {t}\n", .{ seed.name, err });
            return err;
        };

        std.testing.expectEqualDeep(seed.verdict, verdict) catch |err| {
            std.debug.print("seed {s} reached {any}\n", .{ seed.name, verdict });
            return err;
        };
    }
}

test "every server tag has an accepted seed" {
    _ = try buildCorpus();
    var reached: [@typeInfo(MessageTag).@"enum".fields.len]bool = @splat(false);
    for (seed_corpus.list()) |seed| {
        switch (seed.verdict) {
            .accepted, .not_reencoded => |tag| reached[@intFromEnum(tag)] = true,
            .rejected, .consumer_rejected, .encoder_rejected => {},
        }
    }

    try std.testing.expectEqual(@typeInfo(ServerTag).@"enum".fields.len, reached.len);
    for (reached, 0..) |seen, index| {
        if (!seen) {
            std.debug.print("no accepted seed for {t}\n", .{@as(MessageTag, @enumFromInt(index))});
            return error.TagWithoutSeed;
        }
    }
}

test "the fuzz corpus replays every seed that fits the fuzzed payload" {
    const corpus = try buildCorpus();
    var index: usize = 0;
    for (seed_corpus.list()) |seed| {
        if (seed.payload.len > payload_capacity) {
            continue;
        }

        var smith: std.testing.Smith = .{
            .in = corpus[index],
        };
        var buffer: [payload_capacity]u8 = undefined;
        try std.testing.expectEqualSlices(
            u8,
            seed.payload,
            buffer[0..smith.slice(&buffer)],
        );
        index += 1;
    }

    try std.testing.expectEqual(corpus.len, index + replayed_inputs.len);
}

test "every saved fuzz input keeps the properties" {
    for (replayed_inputs) |input| {
        var smith: std.testing.Smith = .{
            .in = input,
        };
        try decodeFuzzedServerMessage({}, &smith);
    }
}

test "fuzz server message decoding" {
    try std.testing.fuzz({}, decodeFuzzedServerMessage, .{
        .corpus = try buildCorpus(),
    });
}
