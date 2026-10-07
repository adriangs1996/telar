//! Where each agent records its session, and how far the runtime has read
//! it. Claude Code's `/rename` fires no hook and Codex's has none either: the
//! name only lands in the file the agent's hooks point at. The runtime polls
//! that file on the observation path; this file owns the bounded watch store,
//! never the I/O or the file formats.

const Registration = @import("Registration.zig");
const Watch = @import("Watch.zig");

pub fn fresh(registration: Registration) Watch {
    var watch: Watch = .{ .key = registration.key, .session = registration.session, .kind = registration.kind };
    @memcpy(watch.path[0..registration.path.len], registration.path);
    watch.path_len = @intCast(registration.path.len);
    return watch;
}
