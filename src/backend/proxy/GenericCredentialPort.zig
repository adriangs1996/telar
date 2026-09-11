const identity = @import("identity.zig");
/// Defines live credential lookup supplied by the proxy credential registry.
///
/// ```zig
/// const port: CredentialPort(Context) = .{ .contains = containsCredential };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        contains: *const fn (*Context, *const identity.Credential) bool,
    };
}
