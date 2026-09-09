//! Bounded incremental reads of Claude session transcripts.

const std = @import("std");
const core = @import("telar-core");
const types = @import("types.zig");
const Job = types.Job;
const Completion = types.Completion;
const Io = std.Io;
const schema = core.schema;
const transcript = @import("../transcript.zig");

var scan_window: [transcript.max_scan_bytes]u8 = undefined;

/// Example: `probe(job, &completion);`.
/// The first probe of a watch only records where the file ends; later
/// probes read at most `max_scan_bytes` past the last offset and leave the
/// rest for the next one. Claude Code creates the transcript lazily, so a
/// file that does not exist yet is seeded at zero and read whole once it
/// appears. A file shorter than the offset was rewritten and is read again.
pub fn probe(job: Job, completion: *Completion) void {
    const file = Io.Dir.cwd().openFile(job.io, job.watch.pathSlice(), .{}) catch {
        if (job.watch.offset == null) {
            completion.offset = 0;
        }

        return;
    };
    defer file.close(job.io);
    const length = file.length(job.io) catch return;
    const start = job.watch.offset orelse {
        completion.offset = length;
        return;
    };
    const offset = if (length < start) 0 else start;
    if (length == offset) {
        completion.offset = offset;
        return;
    }

    // Probes are single-flight, so one static window serves them all
    // instead of a page mapping per probe.
    const buffer = &scan_window;
    var reader = file.reader(job.io, &.{});
    reader.seekTo(offset) catch return;
    const len = reader.interface.readSliceShort(buffer) catch return;

    var title_buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
    const result = transcript.scan(buffer[0..len], job.watch.session.slice(), &title_buffer);
    // A line longer than the whole window can never complete: skip it.
    const consumed = if (result.consumed == 0 and len == buffer.len) len else result.consumed;
    completion.offset = offset + consumed;
    if (result.title) |title| {
        completion.setTitle(title);
    }
}
