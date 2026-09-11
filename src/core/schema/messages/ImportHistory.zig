const id = @import("../id.zig");
const ImportEntry = @import("ImportEntry.zig");
/// One bounded batch of foreign shell history. `source` is the stable
/// identity of the imported file (e.g. `zsh:/home/u/.zsh_history`); the
/// runtime derives one deterministic session from it so re-imports are
/// idempotent, and `base_sequence` orders batches within that session.
const ImportHistory = @This();

request_id: id.RequestId,
source: []const u8,
base_sequence: u64,
entries: []const ImportEntry,
