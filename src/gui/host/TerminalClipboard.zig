//! A pending system paste records the terminal attachment before asynchronous
//! clipboard I/O. A replaced or unfocused target cannot receive its response.
const GuiClient = @import("../GuiClient.zig");
const Result = @import("../input/ClipboardResult.zig");
const Clipboard = @This();

request_id: u64 = 0,
pane_id: ?@import("telar-core").PaneId = null,
generation: u64 = 0,

/// Repeated requests share one outstanding transfer. Example: `try clipboard.read(gui);`
pub fn read(clipboard: *Clipboard, gui: *GuiClient) !void {
    if (clipboard.request_id != 0 or gui.app.model.name_prompt.active() or gui.app.model.copyModeActive()) {
        return;
    }

    const model = gui.app.model.activeTabModelConst() orelse return;
    const pane = model.focusedPaneConst() orelse return;
    clipboard.request_id = try gui.host.read(.{ .generation = pane.attachment_generation });
    clipboard.pane_id = pane.id;
    clipboard.generation = pane.attachment_generation;
    @import("../native/native.zig").telar_gui_wake(gui.driver.fds[1]);
}

/// Completes once, discarding a response whose original attachment is no
/// longer the focused terminal. Example: `if (clipboard.take(gui, result)) startPaste();`
pub fn take(clipboard: *Clipboard, gui: *const GuiClient, result: Result) bool {
    if (result.request_id != clipboard.request_id) {
        return false;
    }

    defer clipboard.request_id = 0;
    if (result.status != .success or result.target_id != 0 or result.generation != clipboard.generation or gui.app.model.name_prompt.active() or gui.app.model.copyModeActive() or !gui.focused) {
        return false;
    }

    const model = gui.app.model.activeTabModelConst() orelse return false;
    const pane = model.focusedPaneConst() orelse return false;
    return pane.id == clipboard.pane_id and pane.attachment_generation == clipboard.generation;
}
