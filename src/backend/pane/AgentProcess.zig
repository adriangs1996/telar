const std = @import("std");
const Session = @import("../agent_panes/Session.zig");
io: std.Io,
session: *Session,
metadata_revision: u64 = 0,
review_latest_edition_id: u64 = 0,
