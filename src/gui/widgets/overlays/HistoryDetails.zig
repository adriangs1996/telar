//! The inspector's lines: the complete command, its facts and the captured
//! output in one sequence that painting and scroll bounds walk alike. The
//! facts are formatted once on the stack; nothing here allocates.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const labels = @import("history_labels.zig");
const WrappedLines = @import("WrappedLines.zig");
const HistoryLine = @import("HistoryLine.zig");
const HistoryDetails = @This();

const Tone = HistoryLine.Tone;
/// A pane id, its separators and the longest tab label, so the fact always
/// formats.
const pane_fact_bytes = std.fmt.count("{d}  ·  tab ", .{std.math.maxInt(u64)}) + core.max_tab_label_bytes;

history: *const data.HistoryPaletteState,
selection: u16,
command: []const u8,
/// Whether the pane the command ran in is open in this client.
pane_open: bool = false,
when: [96]u8 = undefined,
when_len: usize = 0,
took: [32]u8 = undefined,
took_len: usize = 0,
exit: [32]u8 = undefined,
exit_len: usize = 0,
exit_tone: Tone = .text,
pane: [pane_fact_bytes]u8 = undefined,
pane_len: usize = 0,
by: [128]u8 = undefined,
by_len: usize = 0,
heading: [96]u8 = undefined,
heading_len: usize = 0,

/// Borrows the selected command and formats its facts on the stack.
/// Example: `var details = HistoryDetails.init(&projection, selection);`.
pub fn init(projection: *const client.Projection, selection: u16) HistoryDetails {
    const history = projection.history;
    const entry = &history.slice()[selection];
    var details: HistoryDetails = .{
        .history = history,
        .selection = selection,
        .command = history.commandAt(selection) orelse entry.commandSlice(),
    };

    if (entry.started_at_ms < 0 or entry.started_at_ms > 253402300799999) {
        details.when_len = copy(&details.when, "Timestamp unavailable");
    } else {
        var day_storage: [32]u8 = undefined;
        var clock_storage: [16]u8 = undefined;
        var age_storage: [32]u8 = undefined;
        const day = labels.localDay(entry.started_at_ms, history.utc_offset_min);
        const today = labels.localDay(history.now_ms, history.utc_offset_min);
        details.when_len = (std.fmt.bufPrint(&details.when, "{s} {s}  ·  {s}", .{
            labels.dayLabel(day, today, &day_storage),
            labels.clock(entry.started_at_ms, history.utc_offset_min, &clock_storage),
            labels.age(history.now_ms -| entry.started_at_ms, &age_storage),
        }) catch @as([]u8, details.when[0..0])).len;
    }

    var duration_storage: [32]u8 = undefined;
    details.took_len = copy(&details.took, labels.duration(entry.duration_ns, &duration_storage));
    switch (entry.status) {
        .running => {
            details.exit_len = copy(&details.exit, "running");
            details.exit_tone = .teal;
        },
        .interrupted => {
            details.exit_len = copy(&details.exit, "interrupted");
            details.exit_tone = .yellow;
        },
        .completed => if (entry.exit_code) |code| {
            details.exit_len = (std.fmt.bufPrint(&details.exit, "{d}", .{code}) catch @as([]u8, details.exit[0..0])).len;
            details.exit_tone = if (code == 0) .green else .red;
        } else {
            details.exit_len = copy(&details.exit, "unknown");
            details.exit_tone = .muted;
        },
    }

    const model = projection.model;
    if (model.panes.findConst(entry.pane_id)) |pane| {
        details.pane_open = true;
        const tab_name = if (model.tabs.find(pane.location.tab_id)) |slot| data.tab_label.text(model, slot) else "";
        details.pane_len = (std.fmt.bufPrint(&details.pane, "{d}  ·  tab {s}", .{ core.raw(entry.pane_id), tab_name }) catch @as([]u8, details.pane[0..0])).len;
    } else {
        details.pane_len = (std.fmt.bufPrint(&details.pane, "{d}  ·  closed", .{core.raw(entry.pane_id)}) catch @as([]u8, details.pane[0..0])).len;
    }

    details.by_len = switch (entry.author) {
        .human => (std.fmt.bufPrint(&details.by, "You  ·  #{d}", .{entry.id}) catch @as([]u8, details.by[0..0])).len,
        .agent => (std.fmt.bufPrint(&details.by, "{s}  ·  {s}  ·  #{d}", .{ if (entry.provider_len != 0) entry.providerSlice() else "agent", @tagName(entry.origin), entry.id }) catch @as([]u8, details.by[0..0])).len,
    };

    if (history.output_phase == .ready and history.output_len != 0) {
        var size_storage: [24]u8 = undefined;
        details.heading_len = (std.fmt.bufPrint(&details.heading, "{s}  ·  {s}", .{ history.outputHint(), sizeLabel(history.output_len, &size_storage) }) catch @as([]u8, details.heading[0..0])).len;
    } else {
        details.heading_len = copy(&details.heading, history.outputHint());
    }

    return details;
}

/// The six facts under the command, in reading order.
/// Example: `for (details.facts()) |fact| paint(fact);`.
pub fn facts(self: *const HistoryDetails) [6]HistoryLine {
    const entry = &self.history.slice()[self.selection];
    return .{
        .{ .kind = .fact, .label = "When", .text = self.when[0..self.when_len] },
        .{ .kind = .fact, .label = "Took", .text = self.took[0..self.took_len] },
        .{ .kind = .fact, .label = "Exit", .text = self.exit[0..self.exit_len], .tone = self.exit_tone },
        .{ .kind = .fact, .label = "Where", .text = entry.cwdSlice(), .mono = true },
        .{ .kind = .fact, .label = "Pane", .text = self.pane[0..self.pane_len] },
        .{ .kind = .fact, .label = "By", .text = self.by[0..self.by_len] },
    };
}

/// Walks every line the inspector paints at `columns` cells, in order.
/// Example: `var lines = details.lines(columns); while (lines.next()) |line| ...`.
pub fn lines(self: *const HistoryDetails, columns: u16) LineIterator {
    return .{
        .details = self,
        .columns = columns,
        .wrapped = .{ .text = self.command, .width = columns },
    };
}

const LineIterator = struct {
    details: *const HistoryDetails,
    columns: u16,
    phase: enum { command, after_command, facts, after_facts, heading, output, done } = .command,
    fact: usize = 0,
    wrapped: WrappedLines,

    /// Example: `while (lines.next()) |line| paint(line);`.
    pub fn next(self: *LineIterator) ?HistoryLine {
        while (true) {
            switch (self.phase) {
                .command => {
                    if (self.wrapped.next()) |text| {
                        return .{ .kind = .command, .text = text, .mono = true };
                    }

                    self.phase = .after_command;
                },
                .after_command => {
                    self.phase = .facts;
                    return .{ .kind = .blank, .text = "" };
                },
                .facts => {
                    const all = self.details.facts();
                    if (self.fact < all.len) {
                        const line = all[self.fact];
                        self.fact += 1;
                        return line;
                    }

                    self.phase = .after_facts;
                },
                .after_facts => {
                    self.phase = .heading;
                    return .{ .kind = .blank, .text = "" };
                },
                .heading => {
                    self.phase = .output;
                    self.wrapped = .{ .text = self.details.history.outputSlice(), .width = self.columns };
                    return .{ .kind = .heading, .text = self.details.heading[0..self.details.heading_len], .tone = .muted };
                },
                .output => {
                    if (self.wrapped.next()) |text| {
                        return .{ .kind = .output, .text = text, .mono = true, .tone = .muted };
                    }

                    self.phase = .done;
                },
                .done => return null,
            }
        }
    }

    /// Counts with the exact iteration used for painting.
    /// Example: `const limit = lines.count() -| visible_rows;`.
    pub fn count(self: LineIterator) u32 {
        var copy_of = self;
        var total: u32 = 0;
        while (copy_of.next() != null) {
            total += 1;
        }

        return total;
    }
};

fn copy(storage: []u8, text: []const u8) usize {
    const len = @min(storage.len, text.len);
    @memcpy(storage[0..len], text[0..len]);
    return len;
}

fn sizeLabel(bytes: u32, storage: []u8) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(storage, "{d} B", .{bytes}) catch "?";
    }

    return std.fmt.bufPrint(storage, "{d}.{d} KiB", .{ bytes / 1024, (bytes % 1024) * 10 / 1024 }) catch "?";
}

test "byte sizes print in bytes or tenths of KiB" {
    var storage: [24]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", sizeLabel(512, &storage));
    try std.testing.expectEqualStrings("2.1 KiB", sizeLabel(2200, &storage));
    try std.testing.expectEqualStrings("64.0 KiB", sizeLabel(64 * 1024, &storage));
}
