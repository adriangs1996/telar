//! TLS interception resources owned for the lifetime of one proxy service.

const std = @import("std");
const ca = @import("../ca.zig");
const metrics = @import("../metrics.zig");
const passthrough_policy = @import("../passthrough_policy.zig");
const tls = @import("../tls.zig");
const tunnel_tls = @import("../tunnel/tls.zig");

const Io = std.Io;

pub const Paths = struct {
    key: []const u8,
    certificate: []const u8,
    bundle: []const u8,
    passthrough_hosts: []const []const u8 = &.{},
};

pub const Trust = struct {
    certificate_path: []const u8,
    bundle_path: []const u8,
};

pub const Interception = struct {
    io: Io,
    gpa: std.mem.Allocator,
    authority: ca.Authority,
    roots: tls.Roots,
    trust: Trust,
    passthrough: passthrough_policy.Policy,

    /// Loads or creates Telar's private authority, writes the combined trust
    /// bundle, loads platform roots, and validates the passthrough policy as
    /// one transaction.
    ///
    /// ```zig
    /// var interception = try Interception.init(io, gpa, paths);
    /// defer interception.deinit();
    /// ```
    pub fn init(io: Io, gpa: std.mem.Allocator, paths: Paths) !Interception {
        const resources: ca.Resources = .{ .io = io, .allocator = gpa };
        var authority = try ca.Authority.loadOrCreate(resources, .{
            .key = paths.key,
            .certificate = paths.certificate,
        });
        defer std.crypto.secureZero(u8, std.mem.asBytes(&authority));
        try authority.writeBundle(resources, paths.bundle);

        var roots = try tls.Roots.load(io, gpa);
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
            .passthrough = try .init(paths.passthrough_hosts),
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
    pub fn tunnelResources(interception: *Interception, telemetry: *metrics.Counters) tunnel_tls.Resources {
        return .{
            .io = interception.io,
            .gpa = interception.gpa,
            .authority = &interception.authority,
            .roots = &interception.roots,
            .passthrough = &interception.passthrough,
            .telemetry = telemetry,
        };
    }
};

test "interception owns trust paths and exposes bounded tunnel resources" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var certificate_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory});
    const certificate_path = try std.fmt.bufPrint(&certificate_buffer, "{s}/ca-cert.pem", .{directory});
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory});

    var interception = try Interception.init(io, gpa, .{
        .key = key_path,
        .certificate = certificate_path,
        .bundle = bundle_path,
        .passthrough_hosts = &.{"localhost"},
    });
    defer interception.deinit();
    const trust = interception.clientTrust();
    var telemetry: metrics.Counters = .{};
    const resources = interception.tunnelResources(&telemetry);

    try std.testing.expectEqualStrings(certificate_path, trust.certificate_path);
    try std.testing.expectEqualStrings(bundle_path, trust.bundle_path);
    try std.testing.expect(resources.authority == &interception.authority);
    try std.testing.expect(resources.roots == &interception.roots);
    try std.testing.expect(resources.telemetry == &telemetry);
    try std.testing.expect(resources.passthrough.contains("localhost"));
    try std.testing.expect(!resources.passthrough.contains("api.openai.com"));
}
