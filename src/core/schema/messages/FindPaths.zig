const std = @import("std");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
/// Asks the runtime for the paths under `root` that best match `query`.
/// `refresh` rebuilds the root's index; later keystrokes reuse it.
const FindPaths = @This();

request_id: id.RequestId,
root: []const u8,
query: []const u8 = "",
kind: types.PathKindFilter = .any,
limit: u16 = types.max_path_results,
refresh: bool = false,

/// Validates borrowed wire data before dispatch. Example: `try request.validateWire();`
pub fn validateWire(self: FindPaths) !void {
    try codec.validateRequestId(self.request_id);
    try codec.validateBytes(
        self.root,
        types.max_cwd_bytes,
        false,
    );
    if (self.root[0] != '/' or std.mem.indexOfScalar(
        u8,
        self.root,
        0,
    ) != null) {
        return error.InvalidPathRoot;
    }

    try codec.validateBytes(
        self.query,
        types.max_path_query_bytes,
        true,
    );
    if (!std.unicode.utf8ValidateSlice(self.query)) {
        return error.InvalidUtf8;
    }

    if (self.limit == 0 or self.limit > types.max_path_results) {
        return error.InvalidPathLimit;
    }
}
