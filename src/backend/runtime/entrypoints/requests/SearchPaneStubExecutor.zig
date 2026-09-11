const StubExecutor = @This();
const search_commands = @import("../../application/commands/search_pane.zig");
result: search_commands.SearchPaneResult = .pane_not_attached,

fn execute(stub: *StubExecutor, _: search_commands.SearchPane) search_commands.SearchPaneResult {
    return stub.result;
}
