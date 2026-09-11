const search_commands = @import("../../application/commands/search_pane.zig");
const SearchPaneType = @import("../../application/commands/SearchPane.zig");
const StubExecutor = @This();

result: search_commands.SearchPaneResult = .pane_not_attached,

pub fn execute(stub: *StubExecutor, _: SearchPaneType) search_commands.SearchPaneResult {
    return stub.result;
}
