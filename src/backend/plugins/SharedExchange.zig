//! One captured exchange every tap worker reads, shared instead of copied
//! per worker. Each worker encodes its own frame from it on its own thread
//! and releases it; the last release frees the exchange and returns its
//! bytes to the queued-bytes budget. The runtime's event loop only moves
//! pointers.
const owned = @import("../proxy/capture/owned.zig");
const std = @import("std");
const Exchange = owned.Exchange;
const TapBudget = @import("TapBudget.zig");
const SharedExchange = @This();

gpa: std.mem.Allocator,
exchange: Exchange,
event_id: u64,
/// Bytes charged to `budget` for this exchange.
charged: usize,
budget: *TapBudget,
/// Workers that still hold the exchange.
holders: std.atomic.Value(u32),

/// Takes ownership of `exchange` for `holders` workers; `exchange` is left
/// empty.
///
/// ```zig
/// const shared = try SharedExchange.create(gpa, &exchange, .{
///     .event_id = id,
///     .charged = size,
///     .budget = &service.budget,
///     .holders = 2,
/// });
/// ```
pub fn create(gpa: std.mem.Allocator, exchange: *Exchange, options: Options) !*SharedExchange {
    const shared = try gpa.create(SharedExchange);
    shared.* = .{
        .gpa = gpa,
        .exchange = exchange.*,
        .event_id = options.event_id,
        .charged = options.charged,
        .budget = options.budget,
        .holders = .init(options.holders),
    };
    exchange.* = .{};
    return shared;
}

/// Drops one worker's hold; the last one frees the exchange and returns its
/// charge.
///
/// ```zig
/// shared.release();
/// ```
pub fn release(self: *SharedExchange) void {
    if (self.holders.fetchSub(1, .acq_rel) != 1) {
        return;
    }

    const gpa = self.gpa;
    self.exchange.deinit();
    self.budget.release(self.charged);
    gpa.destroy(self);
}

/// What sharing one exchange needs.
const Options = struct {
    event_id: u64,
    charged: usize,
    budget: *TapBudget,
    holders: u32,
};
