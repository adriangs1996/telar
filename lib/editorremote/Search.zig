//! One bounded discovery-and-open: every helper runs a fixed argv, never a
//! shell, under one absolute deadline and fixed budgets of directory
//! entries, endpoints and commands.
const std = @import("std");
const Candidate = @import("Candidate.zig");
const remote = @import("remote.zig");
const Search = @This();

pub const max_entries = 128;
pub const max_endpoints = 32;
pub const output_limit = 16 * 1024;

const timeout_seconds = 3;

editor: []const u8,
path: []const u8,
/// The line to show once the file opens; zero leaves the editor's choice.
line: u32 = 0,
/// The column on `line`; zero means its start.
column: u32 = 0,
candidates: []Candidate,
environment: std.process.Environ,
io: std.Io = undefined,
deadline: std.Io.Timeout = .none,
entries_left: usize = max_entries,
endpoints_left: usize = max_endpoints,
commands_left: usize = max_entries,
/// The candidate whose editor accepted the file.
opened: ?usize = null,

/// Discovers the editor behind one of `candidates` and asks it to open the
/// file. Returns the candidate that accepted it, or null when none matched.
/// An error means an open may have been submitted: never start a second
/// editor after one.
///
/// ```zig
/// var search: Search = .{ .editor = "nvim", .path = path, .candidates = candidates, .environment = environ };
/// const index = try search.run(io);
/// ```
pub fn run(self: *Search, io: std.Io) !?usize {
    self.io = io;
    self.deadline = (std.Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_seconds) } }).toDeadline(io);
    try remote.open(self);
    return self.opened;
}

/// Runs a fixed argv, never a shell, sharing the search's absolute deadline.
///
/// ```zig
/// const output = try search.command(&.{ "vim", "--serverlist" });
/// defer Search.release(output);
/// ```
pub fn command(self: *Search, argv: []const []const u8) !std.process.RunResult {
    if (self.commands_left == 0) {
        return error.EditorCommandLimit;
    }

    if (self.deadline.toDurationFromNow(self.io)) |remaining| {
        if (remaining.raw.toNanoseconds() <= 0) {
            return error.Timeout;
        }
    }

    self.commands_left -= 1;
    return std.process.run(std.heap.page_allocator, self.io, .{
        .argv = argv,
        .stdout_limit = .limited(output_limit),
        .stderr_limit = .limited(output_limit),
        .timeout = self.deadline,
    });
}

/// Releases output owned by a completed helper.
///
/// ```zig
/// defer Search.release(output);
/// ```
pub fn release(output: std.process.RunResult) void {
    std.heap.page_allocator.free(output.stdout);
    std.heap.page_allocator.free(output.stderr);
}

/// The candidate whose foreground process is `pid`.
///
/// ```zig
/// const index = search.find(pid) orelse return;
/// ```
pub fn find(self: *const Search, pid: u32) ?usize {
    for (self.candidates, 0..) |candidate, index| {
        if (candidate.process_group == pid) {
            return index;
        }
    }

    return null;
}
