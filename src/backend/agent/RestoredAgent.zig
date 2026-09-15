const PaneKeyType = @import("../pane/PaneKey.zig");
const SessionTitleType = @import("SessionTitle.zig");
const ResumeSession = @import("ResumeSession.zig");
const RestoredAgent = @This();

key: PaneKeyType,
title: ?SessionTitleType = null,
session: ?ResumeSession = null,
