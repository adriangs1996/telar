const CombinedGraphicsWriter = @This();
const source_namespace = @import("Presenter.zig");
const attachments_module = @import("../../attachments/root.zig");
panes: source_namespace.kitty.KittyGraphicsWriter,
sidebar: *source_namespace.kitty.KittySidebarRenderer,
icons: *source_namespace.icon_graphics.Renderer,
toasts: *source_namespace.toast_graphics.Renderer,
modal: *source_namespace.modal_graphics.Renderer,
pill: *source_namespace.pill_graphics.Renderer,
attachments: *attachments_module.Store,
allow_toast_transmission: bool,
metrics: *source_namespace.ClientMetrics,

pub fn writeOpaque(context: *anyopaque, writer: *source_namespace.Io.Writer) source_namespace.Io.Writer.Error!usize {
    const self: *CombinedGraphicsWriter = @ptrCast(@alignCast(context));
    var pane_bytes: usize = 0;
    var toast_bytes: usize = 0;
    var sidebar_bytes: usize = 0;
    var icon_bytes: usize = 0;
    var modal_bytes: usize = 0;
    var pill_bytes: usize = 0;
    var attachment_bytes: usize = 0;

    // KGP continuation chunks do not identify their image. Whichever
    // renderer opened a transfer owns the graphics stream until it closes;
    // a pane, toast, or icon atlas can never interleave another transfer.
    if (@import("../../attachments/root.zig").delivery.transferInProgress(self.attachments)) {
        attachment_bytes = try @import("../../attachments/root.zig").delivery.write(self.attachments, writer);
    } else if (self.pill.transferInProgress()) {
        pill_bytes = try self.pill.write(writer);
    } else if (self.modal.transferInProgress()) {
        modal_bytes = try self.modal.write(writer);
    } else if (self.toasts.transferInProgress()) {
        toast_bytes = try self.toasts.write(
            writer,
            true,
        );
    } else if (self.icons.transferInProgress()) {
        icon_bytes = try self.icons.write(writer);
    } else {
        pane_bytes = try self.panes.write(writer);
        if (pane_bytes == 0 and self.panes.store.delivery.partial == null) {
            modal_bytes = try self.modal.write(writer);
            if (modal_bytes == 0) {
                attachment_bytes = try @import("../../attachments/root.zig").delivery.write(self.attachments, writer);
                if (attachment_bytes == 0) {
                    toast_bytes = try self.toasts.write(writer, self.allow_toast_transmission);
                    if (toast_bytes == 0) {
                        sidebar_bytes = try self.sidebar.write(writer);
                        if (sidebar_bytes == 0) {
                            pill_bytes = try self.pill.write(writer);
                            if (pill_bytes == 0) {
                                icon_bytes = try self.icons.write(writer);
                            }
                        }
                    }
                }
            }
        }
    }
    if (comptime source_namespace.diagnostics.enabled) {
        self.metrics.pane_graphics_flushed_bytes += pane_bytes;
        self.metrics.toast_graphics_flushed_bytes += toast_bytes;
        self.metrics.sidebar_graphics_flushed_bytes += sidebar_bytes;
        self.metrics.icon_graphics_flushed_bytes += icon_bytes;
        self.metrics.modal_graphics_flushed_bytes += modal_bytes;
        self.metrics.pill_graphics_flushed_bytes += pill_bytes;
        self.metrics.attachment_graphics_flushed_bytes += attachment_bytes;
    }
    return pane_bytes + toast_bytes + sidebar_bytes + icon_bytes + modal_bytes + pill_bytes + attachment_bytes;
}
