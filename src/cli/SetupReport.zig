//! The steps of one `telar machine setup` and how each ended. In text mode
//! each step prints its numbered line as it ends, with its notes under it,
//! and a long step prints what it is doing meanwhile, so the person sees
//! progress; with `--json` nothing prints until `finish` writes one object. Details and notes are bounded copies, so a report
//! never borrows from output that is freed after a step.
const core = @import("telar-core");
const std = @import("std");
const control = @import("control.zig");
const limit_reached = @import("limit_reached.zig");
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
/// The longest progress line, in bytes: room for a login link.
const max_progress_bytes = 2048;
const max_notes = 96;
const notes_limit = core.Limit.declare("cli.setup_report_notes", "notes", max_notes);

const Note = struct {
    step: Step,
    // SAFETY: note formats the text before publishing len and incrementing note_count; printing reads only that prefix.
    bytes: [max_text_bytes]u8 = undefined,
    len: u16 = 0,
};

json: bool,
writer: *std.Io.Writer,
status: [step_count]?Status = @splat(null),
// SAFETY: end formats each detail before setting its length; JSON output reads only the counted prefix.
detail_bytes: [step_count][max_text_bytes]u8 = undefined,
detail_len: [step_count]u16 = @splat(0),
// SAFETY: note initializes the Note and its text before increasing note_count; output visits only that prefix.
notes: [max_notes]Note = undefined,
note_count: u8 = 0,
/// Notes past `max_notes`, counted so `finish` names the limit.
omitted_notes: u32 = 0,

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
    for (self.notes[0..self.note_count]) |*kept| {
        if (kept.step == step) {
            try self.writer.print("      {s}\n", .{kept.bytes[0..kept.len]});
        }
    }

    try self.writer.flush();
}

/// Says what a long step is doing now, in text mode only; nothing is kept.
/// Like a detail it is one line without control bytes, since it may quote
/// what a machine printed, but long enough for a login link.
///
/// ```zig
/// try report.progress("installing {s} there", .{"codex"});
/// ```
pub fn progress(self: *SetupReport, comptime format: []const u8, arguments: anytype) !void {
    if (self.json) {
        return;
    }

    var buffer: [max_progress_bytes]u8 = undefined;
    try self.writer.print("    ... {s}\n", .{bounded(&buffer, format, arguments)});
    try self.writer.flush();
}

/// Adds one line under a step: an agent's result, a file left alone. It
/// prints under the step's line once the step ends, or at once when it
/// already has.
///
/// ```zig
/// try report.note(.agents, "codex: installed at {s}", .{path});
/// ```
pub fn note(self: *SetupReport, step: Step, comptime format: []const u8, arguments: anytype) !void {
    if (self.note_count == max_notes) {
        self.omitted_notes +|= 1;
        return;
    }

    const kept = &self.notes[self.note_count];
    kept.* = .{ .step = step };
    const text = bounded(&kept.bytes, format, arguments);
    kept.len = @intCast(text.len);
    self.note_count += 1;
    if (self.json or self.statusOf(step) == null) {
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

/// Ends a setup that never started: one line, or the JSON object with no
/// steps and `refused` saying why.
///
/// ```zig
/// try report.refuse("box", "dev@box", "--confirm needs a terminal to ask on");
/// ```
pub fn refuse(self: *SetupReport, label: []const u8, destination: []const u8, reason: []const u8) !void {
    if (!self.json) {
        try self.writer.print("telar machine setup {s}: {s}.\n", .{ label, reason });
        try self.writer.flush();
        return;
    }

    try self.writer.writeAll("{\"label\":");
    try control.writeJsonString(self.writer, label);
    try self.writer.writeAll(",\"destination\":");
    try control.writeJsonString(self.writer, destination);
    try self.writer.writeAll(",\"ready\":false,\"pending\":false,\"changed\":false,\"refused\":");
    try control.writeJsonString(self.writer, reason);
    try self.writer.writeAll(",\"steps\":[]}\n");
    try self.writer.flush();
}

/// Whether a step, a login, still waits for the person.
pub fn pending(self: *const SetupReport) bool {
    for (self.status) |status| {
        if (status == .pending) {
            return true;
        }
    }

    return false;
}

/// Ends the report: a closing line, or the whole JSON object. A machine is
/// ready when no step failed and none waits for the person.
///
/// ```zig
/// try report.finish("box", "dev@box");
/// ```
pub fn finish(self: *SetupReport, label: []const u8, destination: []const u8) !void {
    if (self.omitted_notes != 0) {
        limit_reached.report(.{
            .limit = notes_limit,
            .requested = max_notes + @as(u64, self.omitted_notes),
        });
    }

    if (!self.json) {
        const verdict = if (self.failed())
            "is not ready; see the failed steps above"
        else if (self.pending())
            "takes windows, but a login waits for you there; see Logins above and run setup again once it is done"
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
    try self.writer.print(",\"ready\":{},\"pending\":{},\"changed\":{},", .{ !self.failed() and !self.pending(), self.pending(), self.changed() });
    if (self.omitted_notes != 0) {
        try self.writer.print("\"omitted_notes\":{d},", .{self.omitted_notes});
    }

    try self.writer.writeAll("\"steps\":[");
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

// Formats into `buffer`, cutting what does not fit, and turns every control
// byte into a space, so one step stays one line and nothing a machine
// printed can move the cursor or recolor the terminal.
fn bounded(buffer: []u8, comptime format: []const u8, arguments: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print(format, arguments) catch {};
    const text = writer.buffered();
    for (text) |*byte| {
        if ((byte.* < 0x20 and byte.* != '\t') or byte.* == 0x7f) {
            byte.* = ' ';
        }
    }

    return std.mem.trim(u8, text, " ");
}
