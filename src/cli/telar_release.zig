//! This build's release, as `telar machine setup` names it to a machine:
//! where it is published, and the SHA-256 its `SHA256SUMS` gives an asset.
//! The machine downloads the archive itself; the hash it must match comes
//! from here, so a machine never installs an archive this client did not
//! name.
const std = @import("std");

/// Where releases are published unless `TELAR_RELEASES_URL` says otherwise;
/// `install.sh` reads the same variable.
pub const default_releases_url = "https://github.com/adriangs1996/telar/releases";
/// The version a development build reports; it has no release.
pub const development_version = "0.0.0";

/// Hex digits of a SHA-256.
pub const digest_hex_bytes = 64;
/// The largest `SHA256SUMS` read, in bytes.
const max_sums_bytes = 64 * 1024;
const fetch_timeout_s = 60;

/// Whether this build has a release to download.
pub fn released(version: []const u8) bool {
    return !std.mem.eql(u8, version, development_version);
}

/// The release base URL: `TELAR_RELEASES_URL` or GitHub's.
///
/// ```zig
/// const base = telar_release.releasesUrl(process_init.minimal.environ);
/// ```
pub fn releasesUrl(environ: std.process.Environ) []const u8 {
    const configured = std.process.Environ.getPosix(environ, "TELAR_RELEASES_URL") orelse return default_releases_url;
    if (configured.len == 0) {
        return default_releases_url;
    }

    return configured;
}

/// Downloads `SHA256SUMS` of `version` with curl, as `install.sh` does:
/// https or a local `file://` mirror only, redirects included, and returns
/// the hash it lists for `asset`.
///
/// ```zig
/// const digest = try telar_release.fetchDigest(process_init, "0.3.0", "telar-linux-aarch64-headless.tar.gz");
/// ```
pub fn fetchDigest(init: std.process.Init, version: []const u8, asset: []const u8) ![digest_hex_bytes]u8 {
    var url_buffer: [2048]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/download/v{s}/SHA256SUMS", .{ releasesUrl(init.minimal.environ), version }) catch return error.ReleaseUrlTooLong;
    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "curl", "--proto", "=https,file", "--tlsv1.2", "-fsSL", "--", url },
        .stdout_limit = .limited(max_sums_bytes),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(fetch_timeout_s) } },
    }) catch return error.ReleaseUnavailable;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.ReleaseUnavailable;
    }

    return digestFor(result.stdout, asset);
}

/// The hash `SHA256SUMS` lists for `asset`, in either of the forms
/// `sha256sum` writes (`HASH  NAME` or `HASH *NAME`).
///
/// ```zig
/// const digest = try telar_release.digestFor(sums, "telar-macos-aarch64.tar.gz");
/// ```
pub fn digestFor(sums: []const u8, asset: []const u8) ![digest_hex_bytes]u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        const digest = words.next() orelse continue;
        const name_word = words.next() orelse continue;
        const name = if (name_word[0] == '*') name_word[1..] else name_word;
        if (!std.mem.eql(u8, name, asset)) {
            continue;
        }

        if (digest.len != digest_hex_bytes) {
            return error.ReleaseDigestUnreadable;
        }

        var result: [digest_hex_bytes]u8 = undefined;
        for (digest, 0..) |byte, index| {
            if (!std.ascii.isHex(byte)) {
                return error.ReleaseDigestUnreadable;
            }

            result[index] = std.ascii.toLower(byte);
        }

        return result;
    }

    return error.ReleaseAssetMissing;
}

/// The SHA-256 of a local file as lowercase hex, read in blocks.
///
/// ```zig
/// const digest = try telar_release.fileDigest(io, "/tmp/telar");
/// ```
pub fn fileDigest(io: std.Io, path: []const u8) ![digest_hex_bytes]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &.{});
    while (true) {
        const read = reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (read == 0) {
            break;
        }

        hasher.update(buffer[0..read]);
    }

    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

test "the digest of an asset comes from its own line" {
    const a = "a" ** digest_hex_bytes;
    const b = "B" ** digest_hex_bytes;
    const sums = a ++ "  telar-linux-aarch64.tar.gz\n" ++ b ++ " *telar-linux-aarch64-headless.tar.gz\n";

    try std.testing.expectEqualStrings("b" ** digest_hex_bytes, &try digestFor(sums, "telar-linux-aarch64-headless.tar.gz"));
    try std.testing.expectEqualStrings(a, &try digestFor(sums, "telar-linux-aarch64.tar.gz"));
    try std.testing.expectError(error.ReleaseAssetMissing, digestFor(sums, "telar-macos-aarch64.tar.gz"));
    try std.testing.expectError(error.ReleaseDigestUnreadable, digestFor("xyz  telar-macos-aarch64.tar.gz\n", "telar-macos-aarch64.tar.gz"));
}

test "a development build has no release" {
    try std.testing.expect(!released("0.0.0"));
    try std.testing.expect(released("0.3.0"));
}
