const PaneAttachmentType = @import("../../model/PaneAttachment.zig");
const ConfirmPaneAttachment = @This();

requested: PaneAttachmentType,
confirmed: PaneAttachmentType,
created: bool,
