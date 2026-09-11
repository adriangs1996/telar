/// Defines how a service worker starts and how all of its resources stop.
/// `cancel` must join the worker before `destroy` releases the service.
///
/// ```zig
/// const port: Port(Service, Worker) = .{
///     .start = startWorker,
///     .cancel = cancelWorker,
///     .close = closeObservations,
///     .destroy = destroyService,
/// };
/// ```
pub fn Type(comptime Service: type, comptime Worker: type) type {
    return struct {
        start: *const fn (*Service) anyerror!Worker,
        cancel: *const fn (*Service, *Worker) void,
        close: *const fn (*Service) void,
        destroy: *const fn (*Service) void,
    };
}
