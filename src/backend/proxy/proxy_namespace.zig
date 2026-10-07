//! Runtime-facing proxy capability.
//!
//! The proxy secret is read, created and compared inside this package. The
//! runtime only asks for a child environment and receives captured halves.

const pty = @import("pty");
const Override = pty.Override;

pub const environment_override_count = 11;

/// Upper bound on identity variables a pane launch may add before the proxy's
/// own overrides.
pub const max_pane_overrides = 6;

pub fn environmentOverrides(proxy_url: []const u8, certificate_path: []const u8, bundle_path: []const u8) [environment_override_count]Override {
    return .{
        .{ .name = "HTTPS_PROXY", .value = proxy_url },
        .{ .name = "https_proxy", .value = proxy_url },
        .{ .name = "NODE_USE_ENV_PROXY", .value = "1" },
        .{ .name = "NODE_EXTRA_CA_CERTS", .value = certificate_path },
        .{ .name = "SSL_CERT_FILE", .value = bundle_path },
        .{ .name = "CURL_CA_BUNDLE", .value = bundle_path },
        .{ .name = "REQUESTS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "AWS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "GIT_SSL_CAINFO", .value = bundle_path },
        .{ .name = "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE", .value = bundle_path },
        .{ .name = "TELAR_PROXY_TLS", .value = "1" },
    };
}
