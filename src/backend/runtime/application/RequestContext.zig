const RuntimeModel = @import("../RuntimeModel.zig");
const Session = @import("../client/Session.zig");
const Repository = @import("../../workspace/Repository.zig");

model: *RuntimeModel,
session: *Session,
workspaces: Repository,
