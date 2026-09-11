const InstallOptions = @This();
const AuthorityPaths = @import("AuthorityPaths.zig");
const Record = @import("Record.zig");
const source_namespace = @import("proxy.zig");
paths: AuthorityPaths,
previous: ?Record,
backend: source_namespace.TrustBackend,
writer: *source_namespace.Io.Writer,
