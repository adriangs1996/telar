const PaneKey = @import("../pane/PaneKey.zig");
const SessionTitle = @import("SessionTitle.zig");
const ResumeSession = @import("ResumeSession.zig");
const RestoredAgent = @This();

key: PaneKey,
title: ?SessionTitle = null,
session: ?ResumeSession = null,
