//! Proxy command grammar and validated options.

pub const ProxyTrustAction = enum { install, uninstall, status };

pub const LinuxTrustBackend = enum { update_ca_certificates, trust };
