const InitialOpenType = @import("../../connection/InitialOpen.zig");
const FailureCodeType = @import("telar-core").FailureCode;
const InitialOpenFailure = @This();

open: InitialOpenType,
code: FailureCodeType,
