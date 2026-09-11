const GenericConnectionAdmissionPort = @import("GenericConnectionAdmissionPort.zig").Type;
const std = @import("std");

/// Creates the accept-loop policy for one proxy service.
///
/// ```zig
/// const Admission = Runner(Context, Stream, port);
/// try Admission.run(&context);
/// ```
pub fn Type(comptime Context: type, comptime Stream: type, comptime port: GenericConnectionAdmissionPort(Context, Stream)) type {
    return struct {
        /// Accepts until cancellation or listener closure while preserving
        /// exact stream and slot ownership on capacity and scheduling failures.
        /// Transient accept failures are retried.
        ///
        /// ```zig
        /// try Admission.run(&context);
        /// ```
        pub fn run(context: *Context) anyerror!void {
            var workers: std.Io.Group = .init;
            defer port.cancel(context, &workers);

            while (true) {
                const stream = port.accept(context) catch |err| switch (err) {
                    error.Canceled => |canceled| return canceled,
                    error.SocketNotListening => return,
                    else => continue,
                };

                if (!port.acquire(context)) {
                    port.close(context, stream);
                    continue;
                }

                port.start(context, &workers, stream) catch {
                    port.release(context);
                    port.close(context, stream);
                };
            }
        }
    };
}
