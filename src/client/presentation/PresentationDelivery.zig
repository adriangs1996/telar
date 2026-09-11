const PresentationCommitType = @import("../panes/PresentationCommit.zig");
const Delivery = @This();

commit: PresentationCommitType,
media_pending: bool,
