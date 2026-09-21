//! One bounded observation worker; only owned identities cross the runtime loop.
const std = @import("std");
const core = @import("telar-core");
const Candidate = @import("Candidate.zig");
const ClientKey = @import("../history/ClientKey.zig");
const remote = @import("remote.zig");
const Job = @This();

pub const max_entries = 128;
pub const max_endpoints = 32;
pub const output_limit = 16 * 1024;

client: ClientKey,
request: core.OwnedEditorOpen,
candidates: [core.max_panes_per_tab]Candidate = undefined,
candidate_count: usize = 0,
environment: std.process.Environ,
result: core.EditorOpened,
io: std.Io = undefined,
deadline: std.Io.Timeout = .none,
entries_left: usize = max_entries,
endpoints_left: usize = max_endpoints,
commands_left: usize = max_entries,

/// Executes discovery and remote opening under one deadline. Example: `const completed = Job.run(job, io);`
pub fn run(self: *Job, io: std.Io) *Job {
    self.io = io;
    self.deadline = (std.Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } }).toDeadline(io);
    remote.open(self) catch {
        // Once a remote operation may have been submitted, failure must never
        // trigger a second editor. A timeout cannot prove the open did not run.
        self.result.outcome = .failed;
    };
    return self;
}

/// Runs a fixed argv, never a shell, sharing the job's absolute deadline. Example: `const output = try job.command(&.{"vim", "--serverlist"});`
pub fn command(self: *Job, argv: []const []const u8) !std.process.RunResult {
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

/// Releases output owned by a completed helper. Example: `defer Job.release(output);`
pub fn release(output: std.process.RunResult) void {
    std.heap.page_allocator.free(output.stdout);
    std.heap.page_allocator.free(output.stderr);
}

/// Looks up only a foreground process captured from this tab. Example: `const candidate = job.find(pid) orelse return;`
pub fn find(self: *const Job, pid: u32) ?Candidate {
    for (self.candidates[0..self.candidate_count]) |candidate| {
        if (candidate.process_group == pid) {
            return candidate;
        }
    }

    return null;
}

/// Records the exact pane that accepted the file. Example: `job.opened(candidate);`
pub fn opened(self: *Job, candidate: Candidate) void {
    self.result = .{
        .request_id = self.request.request_id,
        .outcome = .opened,
        .pane_id = candidate.pane.id,
        .pane_generation = candidate.pane.generation,
    };
}
