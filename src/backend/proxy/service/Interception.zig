const std = @import("std");
const Authority = @import("../Authority.zig");
const Roots = @import("../Roots.zig");
const Trust = @import("Trust.zig");
const Policy = @import("../Policy.zig");
const Paths = @import("Paths.zig");
const Resources = @import("../Resources.zig");
const AuthorityFiles = @import("../AuthorityFiles.zig");
const Counters = @import("../Counters.zig");
const TunnelResources = @import("../tunnel/Resources.zig");
const Interception = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: Authority,
roots: Roots,
trust: Trust,
hosts: Policy,

/// Loads or creates Telar's private authority, writes the combined trust
/// bundle, loads platform roots, and validates the interception policy as
/// one transaction.
///
/// ```zig
/// var interception = try Interception.init(io, gpa, paths);
/// defer interception.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, paths: Paths) !Interception {
    const resources: Resources = .{ .io = io, .allocator = gpa };
    const files: AuthorityFiles = .{ .key = paths.key, .certificate = paths.certificate };
    var authority = if (paths.system_authority)
        try Authority.loadOrCreateSystem(resources, files)
    else
        try Authority.loadOrCreate(resources, files);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&authority));
    try authority.writeBundle(resources, paths.bundle);

    var roots = try Roots.load(io, gpa);
    errdefer roots.deinit(gpa);

    return .{
        .io = io,
        .gpa = gpa,
        .authority = authority,
        .roots = roots,
        .trust = .{
            .certificate_path = paths.certificate,
            .bundle_path = paths.bundle,
        },
        .hosts = try .init(paths.intercept_hosts),
    };
}

/// Releases platform roots and scrubs the authority and policy state.
///
/// ```zig
/// interception.deinit();
/// ```
pub fn deinit(interception: *Interception) void {
    interception.roots.deinit(interception.gpa);
    std.crypto.secureZero(u8, std.mem.asBytes(interception));
}

/// Returns the certificate paths that a registered child must inherit.
///
/// ```zig
/// const trust = interception.clientTrust();
/// ```
pub fn clientTrust(interception: *const Interception) Trust {
    return interception.trust;
}

/// Borrows the exact TLS resources needed by one tunnel. Their lifetime is
/// bounded by the owning service and therefore exceeds every tunnel.
///
/// ```zig
/// const resources = interception.tunnelResources(&telemetry);
/// ```
pub fn tunnelResources(interception: *Interception, telemetry: *Counters) TunnelResources {
    return .{
        .io = interception.io,
        .gpa = interception.gpa,
        .authority = &interception.authority,
        .roots = &interception.roots,
        .intercept_hosts = &interception.hosts,
        .telemetry = telemetry,
    };
}
