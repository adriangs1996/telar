const ReturnGraphicsCreditHandler = @This();
const source_namespace = @import("graphics_credit.zig");
const ReturnGraphicsCredit = @import("ReturnGraphicsCredit.zig");
attachments: *source_namespace.AttachmentStore,

/// Returns only bytes previously consumed by one attachment. The aggregate
/// rejects over-returned or unrepresentable amounts without changing credit.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id, .bytes = 4096 });
/// ```
pub fn execute(handler: *ReturnGraphicsCreditHandler, command: ReturnGraphicsCredit) !source_namespace.ReturnGraphicsCreditResult {
    return switch (handler.attachments.returnGraphicsCredit(.{
        .pane_id = command.pane_id,
        .bytes = command.bytes,
    })) {
        .returned => .returned,
        .pane_not_attached => .pane_not_attached,
        .invalid_amount => .invalid_amount,
    };
}
