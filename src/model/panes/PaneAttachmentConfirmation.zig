const PaneAttachment = @import("../state/PaneAttachment.zig");
const OpenedPane = @import("OpenedPane.zig");
const PaneAttachmentConfirmation = @This();

requested: PaneAttachment,
opened: OpenedPane,
