//! What `src/main.zig` reads from `build_options`: the build-time switches
//! of one telar executable. The shipped build takes them from `-D` options;
//! the cross check builds with the defaults.
const BinaryFlags = @This();

native_client: bool,
diagnostics: bool = false,
echo_trace: bool = false,
echo_trace_cpu: bool = false,
profile_counts: bool = false,
profile_timing: bool = false,
