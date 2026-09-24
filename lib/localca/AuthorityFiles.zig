const AuthorityFiles = @This();

key: []const u8,
certificate: []const u8,
/// Subject of the authority's certificate and issuer of every leaf it mints.
common_name: []const u8,
