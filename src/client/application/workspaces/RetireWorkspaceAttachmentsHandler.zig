const ModelType = @import("../../model/Model.zig");
const PanePasteEffects = @import("../input/PanePasteEffects.zig");
const PaneFocusReportingEffects = @import("../panes/PaneFocusReportingEffects.zig");
const TabAttachmentRetirementEffects = @import("../tabs/TabAttachmentRetirementEffects.zig");
const RetireTabAttachmentsHandlerType = @import("../tabs/RetireTabAttachmentsHandler.zig");
const RetireWorkspaceAttachmentsHandler = @This();

model: *ModelType,
paste_effects: PanePasteEffects,
focus_effects: PaneFocusReportingEffects,
attachment_effects: TabAttachmentRetirementEffects,

/// Retires each tab's client-owned authorities and attachments in stable
/// workspace order without changing semantic presentation state.
///
/// ```zig
/// try handler.execute();
/// ```
pub fn execute(handler: *RetireWorkspaceAttachmentsHandler) !void {
    var tabs = handler.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var retire: RetireTabAttachmentsHandlerType = .{
            .model = handler.model,
            .paste_effects = handler.paste_effects,
            .focus_effects = handler.focus_effects,
            .effects = handler.attachment_effects,
        };

        try retire.execute(tab.location);
    }
}
