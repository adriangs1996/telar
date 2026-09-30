/// The process an identified agent runs as: its process group and, when the
/// probe found which member it is, its own process.
const AgentProcess = @This();

group: u32,
pid: u32,
