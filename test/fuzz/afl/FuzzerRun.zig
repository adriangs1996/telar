/// Inputs `afl-fuzz` needs: the instrumented executable, the seed corpus it
/// reads and the directory where it stores findings.
const FuzzerRun = @This();
const std = @import("std");
exe: std.Build.LazyPath,
corpus_dir: std.Build.LazyPath,
output_dir: std.Build.LazyPath,
