//! Vertical and application tests for client graphics transport policy.

const GenericGraphicsConfigurationController = @import("../entrypoints/requests/GenericGraphicsConfigurationController.zig").Type;
const ConfigureGraphicsHandlerType = @import("../application/commands/ConfigureGraphicsHandler.zig");
const PaneFixture = @import("PaneFixture.zig");
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const std = @import("std");
const graphics_configuration_commands = @import("../application/commands/graphics_configuration.zig");

const GraphicsConfigurationController = GenericGraphicsConfigurationController(*ConfigureGraphicsHandlerType);

test "ConfigureGraphicsHandler updates existing attachments only for its client" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var other_client: AttachmentStore = .{};
    defer other_client.deinit();
    const other_attachment = try other_client.attach(std.testing.allocator, fixture.pane);
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var handler: ConfigureGraphicsHandlerType = .{
        .attachments = &fixture.attachments,
    };

    try std.testing.expectEqual(
        graphics_configuration_commands.ConfigureGraphicsResult.changed,
        try handler.execute(.{ .shared = true }),
    );
    try std.testing.expect(attachment.graphics.shared_transport);
    try std.testing.expect(!other_attachment.graphics.shared_transport);

    try std.testing.expectEqual(
        graphics_configuration_commands.ConfigureGraphicsResult.unchanged,
        try handler.execute(.{ .shared = true }),
    );
    try std.testing.expect(attachment.graphics.shared_transport);
    try std.testing.expect(!other_attachment.graphics.shared_transport);
}

test "graphics policy survives workspace clearing and resets at aggregate deinit" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    fixture.attachments.deinit();
    var handler: ConfigureGraphicsHandlerType = .{
        .attachments = &fixture.attachments,
    };
    try std.testing.expectEqual(
        graphics_configuration_commands.ConfigureGraphicsResult.changed,
        try handler.execute(.{ .shared = true }),
    );

    const first = try fixture.attachments.attach(std.testing.allocator, fixture.pane);
    try std.testing.expect(first.graphics.shared_transport);

    fixture.attachments.clearAttachments();
    const replacement = try fixture.attachments.attach(std.testing.allocator, fixture.pane);
    try std.testing.expect(replacement.graphics.shared_transport);

    fixture.attachments.deinit();
    const after_deinit = try fixture.attachments.attach(std.testing.allocator, fixture.pane);
    try std.testing.expect(!after_deinit.graphics.shared_transport);
}

test "graphics configuration crosses controller and handler in both directions" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var handler: ConfigureGraphicsHandlerType = .{
        .attachments = &fixture.attachments,
    };
    var controller = GraphicsConfigurationController.init(&handler);

    try controller.configureGraphics(.{ .shared = true });
    try std.testing.expect(attachment.graphics.shared_transport);

    try controller.configureGraphics(.{ .shared = false });
    try std.testing.expect(!attachment.graphics.shared_transport);
}
