const std = @import("std");

/// Adds the macOS SDK's frameworks and libraries to `module`'s search paths.
/// Zig finds the SDK by itself only for the native target; a release pins
/// the deployment target (`-Dtarget=aarch64-macos.26.0`), which Zig then
/// treats as foreign. Such a build also needs `--libc` naming the SDK's
/// headers, or Zig mixes its own Darwin headers with the SDK's frameworks;
/// `packaging/macos/sdk-libc.sh` writes that file.
///
/// ```zig
/// macos_sdk.addPaths(b, frontend);
/// ```
pub fn addPaths(b: *std.Build, module: *std.Build.Module) void {
    const target = module.resolved_target.?;
    if (target.result.os.tag != .macos or b.graph.host.result.os.tag != .macos or target.query.isNativeOs()) {
        return;
    }

    if (b.libc_file == null) {
        std.debug.panic("-Dtarget={s} needs --libc naming the SDK headers; see packaging/macos/sdk-libc.sh", .{target.query.zigTriple(b.allocator) catch "macos"});
    }

    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse @panic("No macOS SDK found; install Xcode or the Command Line Tools");
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}
