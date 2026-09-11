const PaneAttachmentConfirmation = @This();
const client_model = @import("../../root.zig").model;
const OpenedPane = @import("OpenedPane.zig");
requested: client_model.PaneAttachment,
opened: OpenedPane,
