const PaneAttachmentType = @import("../../state/PaneAttachment.zig");
const OpenedPane = @import("OpenedPane.zig");
const PaneAttachmentConfirmation = @This();

requested: PaneAttachmentType,
opened: OpenedPane,
