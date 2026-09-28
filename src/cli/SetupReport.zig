//! The steps of one `telar machine setup` and how each ended. In text mode
//! each step prints its numbered line as it ends, with its notes under it,
//! so the person sees progress; with `--json` nothing prints until `finish`
//! writes one object. Details and notes are bounded copies, so a report
//! never borrows from output that is freed after a step.
const std = @import("std");
const control = @import("control.zig");
const SetupReport = @This();

pub const Step = enum {
    ssh,
    platform,
    telar,
    runtime,
    profile,
    agents,
    integrations,
    configuration,
    logins,
    check,

    pub fn title(self: Step) []const u8 {
        return switch (self) {
            .ssh => "SSH access",
            .platform => "Platform",
            .telar => "telar",
            .runtime => "Runtime",
            .profile => "Profile",
            .agents => "Agents",
            .integrations => "Integrations",
            .configuration => "Configuration",
            .logins => "Logins",
            .check => "Check",
        };
    }
};

/// `ok` means the step found everything as it should be and changed nothing.
pub const Status = enum { ok, changed, skipped, failed, pending };

const step_count = @typeInfo(Step).@"enum".fields.len;
/// The longest detail or note kept, in bytes.
const max_text_bytes = 512;
const max_notes = 96;

const Note = struct {
    step: Step,
    bytes: [max_text_bytes]u8 = undefined,
    len: u16 = 0,
};

json: bool,
writer: *std.Io.Writer,
status: [step_count]?Status = @splat(null),
detail_bytes: [step_count][max_text_bytes]u8 = undefined,
detail_len: [step_count]u16 = @splat(0),
notes: [max_notes]Note = undefined,
note_count: u8 = 0,

/// Records how a step ended and, in text mode, prints its line.
///
/// ```zig
/// try report.end(.telar, .changed, "installed telar {s} at {s}", .{ version, path });
/// ```
pub fn end(self: *SetupReport, step: Step, status: Status, comptime format: []const u8, arguments: anytype) !void {
    const index = @intFromEnum(step);
    self.status[index] = status;
    const text = bounded(&self.detail_bytes[index], format, arguments);
    self.detail_len[index] = @intCast(text.len);
    if (self.json) {
        return;
    }

    try self.writer.print("{d: >2}. {s: <14} {s: <10} {s}\n", .{
        index + 1,
        step.title(),
        @tagName(status),
        text,
    });
    try self.writer.flush();
}

/// Adds one line under a step: an agent's result, a file left alone.
///
/// ```zig
/// try report.note(.agents, "codex: installed at {s}", .{path});
/// ```
pub fn note(self: *SetupReport, step: Step, comptime format: []const u8, arguments: anytype) !void {
    if (self.note_count == max_notes) {
        return;
    }

    const kept = &self.notes[self.note_count];
    kept.* = .{ .step = step };
    const text = bounded(&kept.bytes, format, arguments);
    kept.len = @intCast(text.len);
    self.note_count += 1;
    if (self.json) {
        return;
    }

    try self.writer.print("      {s}\n", .{text});
    try self.writer.flush();
}

pub fn statusOf(self: *const SetupReport, step: Step) ?Status {
    return self.status[@intFromEnum(step)];
}

/// Whether any step failed.
pub fn failed(self: *const SetupReport) bool {
    for (self.status) |status| {
        if (status == .failed) {
            return true;
        }
    }

    return false;
}

/// Whether any step changed the machine or the profile.
pub fn changed(self: *const SetupReport) bool {
    for (self.status) |status| {
        if (status == .changed) {
            return true;
        }
    }

    return false;
}

/// Ends the report: a closing line, or the whole JSON object.
///
/// ```zig
/// try report.finish("box", "dev@box");
/// ```
pub fn finish(self: *SetupReport, label: []const u8, destination: []const u8) !void {
    if (!self.json) {
        const verdict = if (self.failed())
            "is not ready; see the failed steps above"
        else if (self.changed())
            "is ready"
        else
            "was already set up; nothing changed";
        try self.writer.print("{s} {s}.\n", .{ label, verdict });
        try self.writer.flush();
        return;
    }

    try self.writer.writeAll("{\"label\":");
    try control.writeJsonString(self.writer, label);
    try self.writer.writeAll(",\"destination\":");
    try control.writeJsonString(self.writer, destination);
    try self.writer.print(",\"ready\":{},\"changed\":{},\"steps\":[", .{ !self.failed(), self.changed() });
    var first = true;
    for (self.status, 0..) |maybe_status, index| {
        const status = maybe_status orelse continue;
        if (!first) {
            try self.writer.writeByte(',');
        }

        first = false;
        const step: Step = @enumFromInt(index);
        try self.writer.print("{{\"step\":\"{s}\",\"status\":\"{s}\",\"detail\":", .{ @tagName(step), @tagName(status) });
        try control.writeJsonString(self.writer, self.detail_bytes[index][0..self.detail_len[index]]);
        try self.writer.writeAll(",\"notes\":[");
        var first_note = true;
        for (self.notes[0..self.note_count]) |*kept| {
            if (kept.step != step) {
                continue;
            }

            if (!first_note) {
                try self.writer.writeByte(',');
            }

            first_note = false;
            try control.writeJsonString(self.writer, kept.bytes[0..kept.len]);
        }

        try self.writer.writeAll("]}");
    }

    try self.writer.writeAll("]}\n");
    try self.writer.flush();
}

// Formats into `buffer`, cutting what does not fit and anything past the
// first line break, so one step stays one line.
fn bounded(buffer: *[max_text_bytes]u8, comptime format: []const u8, arguments: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print(format, arguments) catch {};
    const text = writer.buffered();
    for (text) |*byte| {
        if (byte.* < 0x20 and byte.* != '\t') {
            byte.* = ' ';
        }
    }

    return std.mem.trim(u8, text, " ");
}

test "text mode prints numbered steps and a verdict" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var report: SetupReport = .{ .json = false, .writer = &writer };
    try report.end(.ssh, .ok, "batch mode works", .{});
    try report.end(.telar, .changed, "installed telar {s}", .{"0.3.0"});
    try report.note(.telar, "linked ~/.local/bin/telar", .{});
    try report.finish("box", "dev@box");

    try std.testing.expectEqualStrings(
        " 1. SSH access     ok         batch mode works\n" ++
            " 3. telar          changed    installed telar 0.3.0\n" ++
            "      linked ~/.local/bin/telar\n" ++
            "box is ready.\n",
        writer.buffered(),
    );
}

test "json mode writes one object with every step and its notes" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var report: SetupReport = .{ .json = true, .writer = &writer };
    try report.end(.ssh, .ok, "batch mode works", .{});
    try report.end(.check, .failed, "schema\n{s}", .{"differs"});
    try report.note(.check, "run \"setup\" again", .{});
    try report.finish("box", "dev@box");

    try std.testing.expectEqualStrings(
        "{\"label\":\"box\",\"destination\":\"dev@box\",\"ready\":false,\"changed\":false,\"steps\":[" ++
            "{\"step\":\"ssh\",\"status\":\"ok\",\"detail\":\"batch mode works\",\"notes\":[]}," ++
            "{\"step\":\"check\",\"status\":\"failed\",\"detail\":\"schema differs\",\"notes\":[\"run \\\"setup\\\" again\"]}]}\n",
        writer.buffered(),
    );
}
