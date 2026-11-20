module telar.runtime.runtime.execution_service;

import telar.platform.error;

namespace telar::runtime {

  template <Allocator Memory>
  Execution<Memory>::Execution(Memory& memory, std::uint64_t execution_token, const ExecutionRequest& request, std::uint64_t workspace_id, std::string_view cwd)
      : token(execution_token),
        id(request.execution_id),
        workspace(workspace_id),
        input(memory, input_capacity),
        output(memory, retained_capacity),
        error(memory, retained_capacity),
        requested_cwd(memory, request.cwd),
        arguments(memory),
        requested_workspace(request.workspace_id),
        requested_stdin(request.stdin_open),
        eof(!request.stdin_open) {
    input.reserve(input_capacity);
    for (const auto argument : request.arguments) {
      arguments.emplace(memory, argument);
    }

    try {
      Command command{memory, Launch{.cwd = cwd, .arguments = request.arguments}, CommandPurpose::administration};

      process.emplace(command.specification({}));
      state = ExecutionState::running;
    } catch (const SystemError& failure) {
      // The shells' code for a command that could not be run.
      constexpr int spawn_failure_exit_code = 125;

      state = ExecutionState::failed;
      exit_code = spawn_failure_exit_code;
      failure_name = sys::errorName(failure.code(), "ExecutionSpawnFailed");
      eof = true;
    }
  }

  template <Allocator Memory>
  bool Execution<Memory>::matches(const ExecutionRequest& request) const noexcept {
    if (requested_workspace != request.workspace_id || requested_cwd != request.cwd || requested_stdin != request.stdin_open || arguments.size() != request.arguments.size()) {
      return false;
    }

    return std::equal(arguments.begin(), arguments.end(), request.arguments.begin(), [](const auto& left, auto right) {
      return left == right;
    });
  }

  template class Execution<ConcurrentMemory>;
  template class Execution<SystemAllocator>;

}
