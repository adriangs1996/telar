const dropqueue = @import("dropqueue");
const owned = @import("owned.zig");
const queue = @import("queue.zig");
const std = @import("std");
const Registry = @import("../Registry.zig");
const CredentialId = @import("../CredentialId.zig");
const Half = owned.Half;
const QueueMetrics = dropqueue.QueueMetrics;
const Envelopes = dropqueue.GenericDropQueue(Envelope, queue.capacity);
const Channel = @This();

envelopes: Envelopes = undefined,
/// Live pane credentials, checked at publication and again at delivery.
/// Envelopes name their credential by identity, so the ring never holds a
/// token.
credentials: *Registry = undefined,

/// Initializes fixed queue storage over the registry whose live
/// credentials admit halves at publication and delivery time.
///
/// ```zig
/// channel.init(&registry);
/// ```
pub fn init(self: *Channel, credentials: *Registry) void {
    self.credentials = credentials;
    self.envelopes.init();
}

/// Attempts a zero-deadline ownership transfer and frees rejected halves.
///
/// ```zig
/// _ = channel.publish(io, .{ .owner = exchange.owner, .half = half });
/// ```
pub fn publish(self: *Channel, io: std.Io, publication: QueuePublication) bool {
    if (!self.credentials.holds(io, publication.owner)) {
        publication.half.deinit();
        return false;
    }

    const envelope: Envelope = .{
        .owner = publication.owner,
        .half = publication.half,
    };

    if (!self.envelopes.publish(io, envelope)) {
        publication.half.deinit();
        return false;
    }

    return true;
}

/// Returns the next half whose credential remains valid at delivery time.
///
/// ```zig
/// const half = try channel.receive(io);
/// ```
pub fn receive(self: *Channel, io: std.Io) anyerror!*Half {
    while (true) {
        const envelope = try self.envelopes.receive(io);

        if (self.credentials.holds(io, envelope.owner)) {
            return envelope.half;
        }

        envelope.half.deinit();
    }
}

/// Closes the channel and frees all buffered half ownership.
///
/// ```zig
/// channel.close(io);
/// ```
pub fn close(self: *Channel, io: std.Io) void {
    self.envelopes.close(io);

    while (self.envelopes.tryReceive(io)) |envelope| {
        envelope.half.deinit();
    }
}

/// Reads queue depth, high-water mark, and capacity drops atomically.
///
/// ```zig
/// const metrics = channel.metrics();
/// ```
pub fn metrics(self: *const Channel) QueueMetrics {
    return self.envelopes.metrics();
}

const QueuePublication = struct {
    owner: CredentialId,
    half: *Half,
};

const Envelope = struct {
    owner: CredentialId,
    half: *Half,
};
