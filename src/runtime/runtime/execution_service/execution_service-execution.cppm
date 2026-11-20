export module telar.runtime.runtime.execution_service:execution;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.process;
import telar.wire.vocabulary;
import telar.wire.execution;
import telar.base.ds;

// Interface: execution/execution.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class Execution {
    public:
      explicit Execution(Memory& memory, std::uint64_t token, const ExecutionRequest& request, std::uint64_t workspace, std::string_view cwd);

      [[nodiscard]] bool matches(const ExecutionRequest& request) const noexcept;

      static constexpr std::size_t retained_capacity = 1024 * 1024;
      static constexpr std::size_t input_capacity = 64 * 1024;
      std::uint64_t token;
      std::uint64_t id;
      std::uint64_t workspace;
      ds::Option<std::uint64_t> input_owner;
      ds::Option<PipeProcess> process;
      ByteQueue<Memory> input;
      RetainedStream<Memory> output;
      RetainedStream<Memory> error;
      ds::String<Memory> requested_cwd;
      ds::Vec<ds::String<Memory>, Memory> arguments;
      std::uint64_t requested_workspace;
      bool requested_stdin;
      bool eof;
      bool write_interest = false;
      std::uint64_t input_written = 0;
      ExecutionState state = ExecutionState::starting;
      int exit_code = 0;
      std::string_view failure_name;
    };

    extern template class Execution<ConcurrentMemory>;
    extern template class Execution<SystemAllocator>;

  }
}
