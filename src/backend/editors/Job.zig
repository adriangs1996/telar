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

/// Executes discovery and remote opening under one deadline. Example: `const completed = Job.run(job, io);`
pub fn run(self: *Job, io: std.Io) *Job {
    var search: editorremote.Search = .{
        .editor = self.request.editor(),
        .path = self.request.path(),
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
