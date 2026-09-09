//! Owned Git observation requests and bounded aggregate transitions.

const core = @import("telar-core");
const schema = core.schema;

pub const Probe = struct {
    workspace: schema.WorkspaceId,
    path: [schema.max_cwd_bytes]u8 = undefined,
    path_len: u16,

    /// Borrows the path owned by this asynchronous request.
    /// Example: `const path = probe.pathSlice();`.
    pub fn pathSlice(probe: *const Probe) []const u8 {
        return probe.path[0..probe.path_len];
    }
};

pub const Observation = struct {
    workspace: schema.WorkspaceId,
    branch: []const u8,
    /// Null when the probe could not decide, such as a timed-out `git
    /// status`; the previous cleanliness is then retained rather than
    /// reported clean.
    dirty: ?bool,
    checked_at_ms: i64,
};
