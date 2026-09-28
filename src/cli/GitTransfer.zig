const std = @import("std");
/// What `push` and `fetch` move between this clone and another machine's.
const GitTransfer = @This();

/// The local clone.
root: []const u8,
/// `ssh://DESTINATION/PATH` of the other machine's clone.
url: []const u8,
/// One refspec; `push` never forces, `fetch` may update a remote-tracking ref.
refspec: []const u8,
/// The environment Git runs with: this process's, plus `GIT_SSH_COMMAND`
/// naming telar's managed SSH options.
environ_map: *const std.process.Environ.Map,
