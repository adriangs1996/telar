//! One bounded observation worker; only owned identities cross the runtime loop.
const std = @import("std");
const core = @import("telar-core");
const editorremote = @import("editorremote");
const ClientKey = @import("../history/ClientKey.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Job = @This();

comptime {
    std.debug.assert(core.OpenEditor.max_bytes <= editorremote.expressions.max_path_bytes);
}

client: ClientKey,
request: core.OwnedEditorOpen,
/// The pane each candidate belongs to, by index.
panes: [core.max_panes_per_tab]PaneKey = undefined,
candidates: [core.max_panes_per_tab]editorremote.Candidate = undefined,
candidate_count: usize = 0,
environment: std.process.Environ,
result: core.EditorOpened,

/// Adds a foreground process from the requesting tab.
/// Example: `job.addCandidate(pane.key(), pid);`
pub fn addCandidate(self: *Job, pane: PaneKey, process_group: u32) void {
    self.panes[self.candidate_count] = pane;
    self.candidates[self.candidate_count] = .{ .process_group = process_group };
    self.candidate_count += 1;
}

/// Checks that the path names a regular file, then runs discovery and remote
/// opening under one deadline. A missing file asks no editor to create it.
/// Example: `const completed = Job.run(job, io);`
pub fn run(self: *Job, io: std.Io) *Job {
    const stat = std.Io.Dir.cwd().statFile(io, self.request.path(), .{}) catch {
        self.result.outcome = .missing;
        return self;
    };

    if (stat.kind != .file) {
        self.result.outcome = .missing;
        return self;
    }

    var search: editorremote.Search = .{
        .editor = self.request.editor(),
        .path = self.request.path(),
        .line = self.request.line,
        .column = self.request.column,
        .candidates = self.candidates[0..self.candidate_count],
        .environment = self.environment,
    };
    const opened = search.run(io) catch {
        // Once a remote operation may have been submitted, failure must never
        // trigger a second editor. A timeout cannot prove the open did not run.
        self.result.outcome = .failed;
        return self;
    };

    if (opened) |index| {
        self.result = .{
            .request_id = self.request.request_id,
            .outcome = .opened,
            .pane_id = self.panes[index].id,
            .pane_generation = self.panes[index].generation,
        };
    }

    return self;
}

test "editor opens ask no editor for a path that is not a regular file" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(
        io,
        .{
            .sub_path = "present.zig",
            .data = "one\n",
        },
    );
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cases = [_]struct { name: []const u8, outcome: core.EditorOpened.Outcome }{
        .{ .name = "absent.zig", .outcome = .missing },
        .{ .name = "", .outcome = .missing },
        .{ .name = "present.zig", .outcome = .unavailable },
    };

    for (cases) |case| {
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, case.name });
        var job: Job = .{
            .client = .{
                .id = 1,
                .generation = 1,
            },
            .request = .{
                .request_id = @enumFromInt(5),
                .pane_id = @enumFromInt(6),
                .pane_generation = 7,
                .line = 3,
            },
            .environment = std.testing.environ,
            .result = .{
                .request_id = @enumFromInt(5),
                .outcome = .unavailable,
            },
        };
        try job.request.setTarget("nvim", path);
        try std.testing.expectEqual(case.outcome, job.run(io).result.outcome);
    }
}
