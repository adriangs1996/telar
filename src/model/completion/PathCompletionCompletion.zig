const PathCompletionState = @import("../state/PathCompletionState.zig");
const ResultType = @import("../state/PathCompletionResult.zig");
/// The result the adapter delivers for one directory listing. A successful
/// result is heap-owned by the worker's allocation and released by the
/// controller that consumes it, so the inbox message stays small.
const Completion = @This();

execution_id: PathCompletionState.ExecutionId,
result: anyerror!*ResultType,
