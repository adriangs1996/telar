const RetireWorkspaceAttachmentsHandler = @This();
const client_model = @import("../../root.zig").model;
const pane_paste = @import("../input/root.zig").pane_paste;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const tab_attachment_retirement = @import("../tabs/root.zig").tab_attachment_retirement;
model: *client_model.Model,
paste_effects: pane_paste.Effects,
focus_effects: pane_focus_reporting.Effects,
attachment_effects: tab_attachment_retirement.Effects,

/// Retires each tab's client-owned authorities and attachments in stable
/// workspace order without changing semantic presentation state.
///
/// ```zig
/// try handler.execute();
/// ```
pub fn execute(handler: *RetireWorkspaceAttachmentsHandler) !void {
    var tabs = handler.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var retire: tab_attachment_retirement.RetireTabAttachmentsHandler = .{
            .model = handler.model,
            .paste_effects = handler.paste_effects,
            .focus_effects = handler.focus_effects,
            .effects = handler.attachment_effects,
        };

        try retire.execute(tab.location);
    }
}
