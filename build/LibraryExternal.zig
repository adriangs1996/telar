//! A module the libraries import but do not build: an external dependency,
//! or a replacement for a library, bound under the library's name.
const std = @import("std");

name: []const u8,
module: *std.Build.Module,
