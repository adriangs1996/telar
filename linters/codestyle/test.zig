const analyzer_support = @import("analysis.zig");
const arguments = @import("arguments.zig");
const fixer_support = @import("fixes.zig");
const paths = @import("paths.zig");
const reporter_support = @import("reporter_tests.zig");
const source_file = @import("source_file.zig");
test {
    _ = analyzer_support;
    _ = arguments;
    _ = fixer_support;
    _ = paths;
    _ = reporter_support;
    _ = source_file;
    _ = @import("layout_tests.zig");
    _ = @import("layout_naming.zig");
}
