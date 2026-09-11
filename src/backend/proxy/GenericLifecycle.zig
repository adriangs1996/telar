const GenericLifecyclePort = @import("GenericLifecyclePort.zig").Type;
/// Creates the owner of one service and its background worker.
///
/// Startup transfers service ownership immediately. If the worker cannot
/// start, the service is destroyed before the error is returned. Shutdown
/// first joins the worker, then closes observations, then destroys the service.
///
/// ```zig
/// const RunningService = Lifecycle(Service, Worker, port);
/// var running = try RunningService.start(service);
/// defer running.deinit();
/// ```
pub fn Type(comptime Service: type, comptime Worker: type, comptime port: GenericLifecyclePort(Service, Worker)) type {
    return struct {
        const Self = @This();

        service: *Service,
        worker: Worker,

        /// Starts the worker and assumes ownership of `service` on every path.
        ///
        /// ```zig
        /// var running = try RunningService.start(service);
        /// ```
        pub fn start(service: *Service) !Self {
            errdefer port.destroy(service);

            return .{
                .service = service,
                .worker = try port.start(service),
            };
        }

        /// Joins the worker and releases every resource owned by this lifecycle.
        ///
        /// ```zig
        /// running.deinit();
        /// ```
        pub fn deinit(lifecycle: *Self) void {
            port.cancel(lifecycle.service, &lifecycle.worker);
            port.close(lifecycle.service);
            port.destroy(lifecycle.service);
        }
    };
}
