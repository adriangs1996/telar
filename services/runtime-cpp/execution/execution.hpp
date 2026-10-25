#pragma once

#include "../memory/byte_queue.hpp"
#include "../memory/retained_stream.hpp"
#include "../platform/command.hpp"
#include "../platform/pipe_process.hpp"

namespace telar::runtime {

template <Allocator Memory>
class Execution {
public:
  explicit Execution(Memory &memory, std::uint64_t token, const ExecutionRequest &request, std::uint64_t workspace, std::string_view cwd)
      : token(token),
        id(request.execution_id),
        workspace(workspace),
        input(memory, input_capacity),
        output(memory, retained_capacity),
        error(memory, retained_capacity),
        requested_cwd(request.cwd, AllocatorRef<char, Memory>{memory}),
        arguments(AllocatorRef<String<Memory>, Memory>{memory}),
        requested_workspace(request.workspace_id),
        requested_stdin(request.stdin_open),
        eof(!request.stdin_open) {
    input.reserve(input_capacity);
    for (const auto argument : request.arguments) {
      arguments.emplace_back(argument, AllocatorRef<char, Memory>{memory});
    }

    try {
      Command command{memory, Launch{.cwd = cwd, .arguments = request.arguments}, CommandPurpose::administration};
      process.emplace(command.specification({}));
      state = ExecutionState::running;
    } catch (const SystemError &failure) {
      state = ExecutionState::failed;
      exit_code = 125;
      failure_name = failure.code() == ENOENT ? "FileNotFound" : failure.code() == EACCES ? "AccessDenied"
                                                                                          : "ExecutionSpawnFailed";
      eof = true;
    }
  }

  bool matches(const ExecutionRequest &request) const noexcept {
    if (requested_workspace != request.workspace_id || requested_cwd != request.cwd || requested_stdin != request.stdin_open || arguments.size() != request.arguments.size()) {
      return false;
    }

    return std::equal(arguments.begin(), arguments.end(), request.arguments.begin(), [](const auto &left, auto right) { return left == right; });
  }

  static constexpr std::size_t retained_capacity = 1024 * 1024;
  static constexpr std::size_t input_capacity = 64 * 1024;
  std::uint64_t token;
  std::uint64_t id;
  std::uint64_t workspace;
  std::optional<std::uint64_t> input_owner;
  std::optional<PipeProcess> process;
  ByteQueue<Memory> input;
  RetainedStream<Memory> output;
  RetainedStream<Memory> error;
  String<Memory> requested_cwd;
  Vector<String<Memory>, Memory> arguments;
  std::uint64_t requested_workspace;
  bool requested_stdin;
  bool eof;
  bool write_interest = false;
  std::uint64_t input_written = 0;
  ExecutionState state = ExecutionState::starting;
  int exit_code = 0;
  std::string_view failure_name;
};

}
