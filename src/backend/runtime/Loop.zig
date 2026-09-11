/// Owns the bounded selector and external stop coordination for one runtime.
const Loop = @This();
const stop_signal_module = @import("lifecycle/root.zig").stop_signal;
const source_namespace = @import("event_loop.zig");
stop_signal: stop_signal_module.Coordinator,
storage: [source_namespace.event_capacity]source_namespace.Event,
select: source_namespace.Io.Select(source_namespace.Event),

/// Initializes bounded event storage without starting any actor.
///
/// ```zig
/// var loop: Loop = undefined;
/// loop.init(io, stop_queue);
/// ```
pub fn init(loop: *Loop, io: source_namespace.Io, stop: ?*source_namespace.Io.Queue(u8)) void {
    loop.stop_signal = .init(stop);
    loop.select = source_namespace.Io.Select(source_namespace.Event).init(io, &loop.storage);
}

/// Returns the selector borrowed by runtime event sources and dispatchers.
///
/// ```zig
/// const select = loop.selector();
/// ```
pub fn selector(loop: *Loop) *source_namespace.Io.Select(source_namespace.Event) {
    return &loop.select;
}

/// Returns the coordinator used to arm and complete the stop source.
///
/// ```zig
/// const stop = loop.stopCoordinator();
/// ```
pub fn stopCoordinator(loop: *Loop) *stop_signal_module.Coordinator {
    return &loop.stop_signal;
}

/// Waits until one scheduled actor produces an event.
///
/// ```zig
/// const event = try loop.next();
/// ```
pub fn next(loop: *Loop) !source_namespace.Event {
    return loop.select.await();
}

/// Completes the injected or platform stop source.
///
/// ```zig
/// if (try loop.completeStop(result)) return;
/// ```
pub fn completeStop(loop: *Loop, result: anyerror!void) !bool {
    return switch (try loop.stop_signal.complete(result)) {
        .stop => true,
    };
}

/// Cancels every scheduled actor and discards pending completions.
///
/// ```zig
/// loop.cancel();
/// ```
pub fn cancel(loop: *Loop) void {
    loop.select.cancelDiscard();
}
