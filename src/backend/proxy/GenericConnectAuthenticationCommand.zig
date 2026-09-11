const GenericCredentialPort = @import("GenericCredentialPort.zig").Type;
const connect_authentication = @import("connect_authentication.zig");
const identity = @import("identity.zig");
const std = @import("std");

/// Creates the CONNECT authentication command for one credential store.
///
/// ```zig
/// const Authenticate = Command(Context, credential_port);
/// const decision = Authenticate.execute(&context, request_head);
/// ```
pub fn Type(comptime Context: type, comptime credentials: GenericCredentialPort(Context)) type {
    return struct {
        /// Authenticates before revealing target validity. Only an exact
        /// `CONNECT authority HTTP/1.1` line with a bounded hostname and a
        /// nonzero decimal port is accepted. A successful value owns a
        /// credential copy whose token the caller must securely erase; its
        /// validated hostname borrows from `head`.
        ///
        /// ```zig
        /// const decision = Authenticate.execute(&context, request_head);
        /// ```
        pub fn execute(context: *Context, head: []const u8) connect_authentication.Decision {
            var credential = identity.parseProxyAuthorization(head) orelse return connect_authentication.rejectInvalidAuthorization();
            defer std.crypto.secureZero(u8, &credential.token);

            if (!credentials.contains(context, &credential)) {
                return connect_authentication.rejectUnknownCredential();
            }

            const target = connect_authentication.parseTarget(head) orelse return connect_authentication.rejectInvalidTarget();
            return .{ .authenticated = .{
                .credential = credential,
                .target = target,
            } };
        }
    };
}
