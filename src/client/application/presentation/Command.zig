const PresentationCommitType = @import("../../panes/PresentationCommit.zig");
const Command = @This();

commit: PresentationCommitType,
media_pending: bool,
