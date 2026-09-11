/// One bounded batch of foreign shell history. `source` is the stable
/// identity of the imported file (e.g. `zsh:/home/u/.zsh_history`); the
/// runtime derives one deterministic session from it so re-imports are
/// idempotent, and `base_sequence` orders batches within that session.
const ImportHistory = @This();
const source_namespace = @import("history.zig");
const ImportEntry = @import("ImportEntry.zig");
request_id: source_namespace.RequestId,
source: []const u8,
base_sequence: u64,
entries: []const ImportEntry,
