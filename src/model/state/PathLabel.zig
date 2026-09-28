//! One path picker row as styled runs within a cell budget: the directory
//! muted, the file name plain, matched characters highlighted. A path too
//! wide loses the middle of its directory to `…`; the file name stays.

const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const std = @import("std");
const PathLabelRun = @import("PathLabelRun.zig");
const PathLabel = @This();

pub const Tone = enum {
    directory,
    name,
    match,
    ellipsis,
};

/// Every match splits a run at most twice; the ellipsis and the two parts
/// of the path around it add a few more.
pub const max_runs = 2 * core.max_path_query_bytes + 6;

const ellipsis = "…";

runs: [max_runs]PathLabelRun = undefined,
len: u8 = 0,

/// Lays out `path` in `width` cells.
///
/// ```zig
/// var label: PathLabel = .{};
/// label.layout(state.path(match), match.positions[0..match.position_count], row.w);
/// for (label.slice()) |run| draw(run);
/// ```
pub fn layout(self: *PathLabel, path: []const u8, positions: []const u16, width: u16) void {
    self.len = 0;
    const name_start = nameStart(path);
    if (cellgrid.text.measure(path) <= width) {
        self.emit(.{
            .path = path,
            .positions = positions,
            .start = 0,
            .end = path.len,
            .name_start = name_start,
        });
        return;
    }

    const name_width = cellgrid.text.measure(path[name_start..]);
    const head_end = fitting(path[0..name_start], width -| name_width -| 1);
    self.emit(.{
        .path = path,
        .positions = positions,
        .start = 0,
        .end = head_end,
        .name_start = name_start,
    });
    self.push(.{
        .text = ellipsis,
        .tone = .ellipsis,
    });
    self.emit(.{
        .path = path,
        .positions = positions,
        .start = name_start,
        .end = path.len,
        .name_start = name_start,
    });
}

pub fn slice(self: *const PathLabel) []const PathLabelRun {
    return self.runs[0..self.len];
}

/// Where the last segment starts; a directory's trailing `/` stays in it.
fn nameStart(path: []const u8) usize {
    const trimmed = std.mem.trimEnd(
        u8,
        path,
        "/",
    );
    const split = std.mem.lastIndexOfScalar(
        u8,
        trimmed,
        '/',
    ) orelse return 0;
    return split + 1;
}

/// The longest prefix of `text`, cut on a character, that fits `width` cells.
fn fitting(text: []const u8, width: u16) usize {
    var used: u16 = 0;
    var end: usize = 0;
    while (end < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        const next = @min(end + size, text.len);
        const cells = cellgrid.text.measure(text[end..next]);
        if (used + cells > width) {
            break;
        }

        used += cells;
        end = next;
    }

    return end;
}

const Span = struct {
    path: []const u8,
    positions: []const u16,
    start: usize,
    end: usize,
    name_start: usize,
};

/// Splits `path[start..end]` wherever the tone changes, one character at a
/// time so a run never cuts a multi-byte character.
fn emit(self: *PathLabel, span: Span) void {
    var run_start = span.start;
    var run_tone: ?Tone = null;
    var cursor = span.start;
    while (cursor < span.end) {
        const size = std.unicode.utf8ByteSequenceLength(span.path[cursor]) catch 1;
        const next = @min(cursor + size, span.end);
        const tone = toneAt(
            span,
            cursor,
            next,
        );
        if (run_tone != null and tone != run_tone.?) {
            self.push(.{
                .text = span.path[run_start..cursor],
                .tone = run_tone.?,
            });
            run_start = cursor;
        }

        run_tone = tone;
        cursor = next;
    }

    if (run_tone) |tone| {
        self.push(.{
            .text = span.path[run_start..span.end],
            .tone = tone,
        });
    }
}

fn toneAt(span: Span, start: usize, end: usize) Tone {
    for (span.positions) |position| {
        if (position >= start and position < end) {
            return .match;
        }
    }

    return if (start >= span.name_start) .name else .directory;
}

fn push(self: *PathLabel, run: PathLabelRun) void {
    if (self.len == max_runs) {
        return;
    }

    self.runs[self.len] = run;
    self.len += 1;
}

test "a fitting path splits into directory, name and matched runs" {
    var label: PathLabel = .{};
    label.layout(
        "src/License.ts",
        &.{ 4, 5 },
        40,
    );
    const runs = label.slice();
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try std.testing.expectEqualStrings("src/", runs[0].text);
    try std.testing.expectEqual(Tone.directory, runs[0].tone);
    try std.testing.expectEqualStrings("Li", runs[1].text);
    try std.testing.expectEqual(Tone.match, runs[1].tone);
    try std.testing.expectEqualStrings("cense.ts", runs[2].text);
    try std.testing.expectEqual(Tone.name, runs[2].tone);
}

test "a wide path loses the middle of its directory and keeps the file name" {
    var label: PathLabel = .{};
    label.layout(
        "apps/license-lookup-app/src/types/License.ts",
        &.{},
        24,
    );
    const runs = label.slice();
    var width: u16 = 0;
    for (runs) |run| {
        width += cellgrid.text.measure(run.text);
    }

    try std.testing.expect(width <= 24);
    try std.testing.expectEqual(Tone.ellipsis, runs[1].tone);
    try std.testing.expectEqualStrings("License.ts", runs[runs.len - 1].text);
    try std.testing.expect(std.mem.startsWith(
        u8,
        "apps/license-lookup-app/",
        runs[0].text,
    ));
}

test "a directory keeps its trailing separator in the name" {
    var label: PathLabel = .{};
    label.layout(
        "tests/snapshots/",
        &.{},
        40,
    );
    try std.testing.expectEqualStrings("snapshots/", label.slice()[1].text);
    try std.testing.expectEqual(Tone.name, label.slice()[1].tone);
}
