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
// SAFETY: addCandidate assigns the pane key before increasing candidate_count; result lookup uses the matching candidate index.
panes: [core.max_panes_per_tab]PaneKey = undefined,
// SAFETY: addCandidate assigns the candidate before increasing candidate_count; discovery receives only that prefix.
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
