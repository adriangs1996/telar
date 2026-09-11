const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const selection = @import("../../attachment/selection.zig");
const CopySelectionType = @import("telar-core").CopySelection;
const std = @import("std");

/// Builds a statically dispatched selection controller. `Clipboard` owns only
/// confirmed output; extraction uses request-scoped scratch storage.
///
/// ```zig
/// const SelectionController = Controller(*copy_selection_commands.CopySelectionHandler, *Delivery);
/// var controller = SelectionController.init(&metrics, &handler, &delivery);
/// ```
pub fn Type(comptime Executor: type, comptime Clipboard: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetricsType,
        executor: Executor,
        clipboard: Clipboard,
        scratch: [selection.scratch_bytes]u8 = undefined,

        /// Creates one request-scoped controller without modifying pending
        /// clipboard delivery.
        ///
        /// ```zig
        /// var controller = SelectionController.init(&metrics, &handler, &delivery);
        /// ```
        pub fn init(metrics: *RuntimeMetricsType, executor: Executor, clipboard: Clipboard) Self {
            return .{
                .metrics = metrics,
                .executor = executor,
                .clipboard = clipboard,
            };
        }

        /// Maps absolute scrollback coordinates, extracts bounded text, and
        /// replaces pending clipboard output only after successful extraction.
        /// A request for a pane outside this client's attachments is stale;
        /// unavailable and oversized selections are ignored.
        ///
        /// ```zig
        /// controller.copySelection(request);
        /// ```
        pub fn copySelection(controller: *Self, request: CopySelectionType) void {
            const result = controller.executor.execute(.{
                .pane_id = request.pane_id,
                .start_x = request.start_x,
                .start_y = request.start_y,
                .end_x = request.end_x,
                .end_y = request.end_y,
                .linewise = request.linewise,
            }, &controller.scratch);

            switch (result) {
                .copied => |bytes| {
                    const accepted = controller.clipboard.setClipboard(request.pane_id, bytes);
                    std.debug.assert(accepted);
                },
                .pane_not_attached => controller.metrics.stale_client_messages += 1,
                .unavailable, .too_large => {},
            }
        }
    };
}
