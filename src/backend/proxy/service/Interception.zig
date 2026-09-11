const std = @import("std");
const AuthorityType = @import("../Authority.zig");
const RootsType = @import("../Roots.zig");
const Trust = @import("Trust.zig");
const PolicyType = @import("../Policy.zig");
const Paths = @import("Paths.zig");
const ResourcesType = @import("../Resources.zig");
const AuthorityFilesType = @import("../AuthorityFiles.zig");
const CountersType = @import("../Counters.zig");
const TunnelResources = @import("../tunnel/Resources.zig");
const Interception = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: AuthorityType,
roots: RootsType,
trust: Trust,
hosts: PolicyType,

/// Loads or creates Telar's private authority, writes the combined trust
/// bundle, loads platform roots, and validates the interception policy as
/// one transaction.
///
/// ```zig
/// var interception = try Interception.init(io, gpa, paths);
/// defer interception.deinit();
/// ```
pub fn init(io: std.Io, gpa: std.mem.Allocator, paths: Paths) !Interception {
    const resources: ResourcesType = .{ .io = io, .allocator = gpa };
    const files: AuthorityFilesType = .{ .key = paths.key, .certificate = paths.certificate };
    var authority = if (paths.system_authority)
        try AuthorityType.loadOrCreateSystem(resources, files)
    else
        try AuthorityType.loadOrCreate(resources, files);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&authority));
    try authority.writeBundle(resources, paths.bundle);

    var roots = try RootsType.load(io, gpa);
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
pub fn tunnelResources(interception: *Interception, telemetry: *CountersType) TunnelResources {
    return .{
        .io = interception.io,
        .gpa = interception.gpa,
        .authority = &interception.authority,
        .roots = &interception.roots,
        .intercept_hosts = &interception.hosts,
        .telemetry = telemetry,
    };
}
