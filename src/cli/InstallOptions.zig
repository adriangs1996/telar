const AuthorityPaths = @import("AuthorityPaths.zig");
const Record = @import("Record.zig");
const proxy = @import("proxy.zig");
const std = @import("std");

paths: AuthorityPaths,
previous: ?Record,
backend: proxy.TrustBackend,
writer: *std.Io.Writer,
