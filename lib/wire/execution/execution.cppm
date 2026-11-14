export module telar.wire.execution;

// Commands the runtime executes for a client, and their output.

import std;
import telar.wire.vocabulary;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
export extern "C++" {
  namespace telar {

    struct ExecutionRequest {
      std::uint64_t request_id{};
      ExecutionAction action{};
      std::uint64_t execution_id{};
      std::uint64_t workspace_id{};
      std::uint64_t stdout_offset{};
      std::uint64_t stderr_offset{};
      std::uint64_t input_offset{};
      bool stdin_open{};
      std::string_view cwd{};
      std::span<const std::string_view> arguments{};
      std::span<const Byte> bytes{};

      void validate() const;
    };

    template <>
    struct MessageSchema<ExecutionRequest>
        : Schema<Direction::client, ClientTag::execution_request, Field<&ExecutionRequest::request_id, NonzeroU64, "request_id">, Field<&ExecutionRequest::action, EnumByte<ExecutionAction, 6>, "action">, Field<&ExecutionRequest::execution_id, u64, "execution_id">, Field<&ExecutionRequest::workspace_id, u64, "workspace_id">, Field<&ExecutionRequest::stdout_offset, u64, "stdout_offset">, Field<&ExecutionRequest::stderr_offset, u64, "stderr_offset">, Field<&ExecutionRequest::input_offset, u64, "input_offset">, Field<&ExecutionRequest::stdin_open, BoolByte, "stdin_open">, Field<&ExecutionRequest::cwd, Text16<4096>, "cwd">, SpanCountField<&ExecutionRequest::arguments, u8, Text16<32768>, 64, "argument_count", 0>, SpanItemsField<&ExecutionRequest::arguments, Text16<32768>, "arguments">, Field<&ExecutionRequest::bytes, SizedBytes<u16, 4096>, "bytes">> {};

    struct ExecutionReply {
      std::uint64_t request_id{};
      std::uint64_t execution_id{};
      std::uint64_t workspace_id{};
      std::uint64_t stdout_offset{};
      std::uint64_t stderr_offset{};
      std::uint64_t stdout_total{};
      std::uint64_t stderr_total{};
      std::uint64_t input_offset{};
      std::uint64_t input_available{};
      ExecutionState state{};
      std::int32_t exit_code{};
      bool stdin_open{};
      std::span<const Byte> failure{};
      std::span<const Byte> stdout_bytes{};
      std::span<const Byte> stderr_bytes{};
    };

    template <>
    struct MessageSchema<ExecutionReply>
        : Schema<Direction::server, ServerTag::execution_reply, Field<&ExecutionReply::request_id, NonzeroU64, "request_id">, Field<&ExecutionReply::execution_id, u64, "execution_id">, Field<&ExecutionReply::workspace_id, u64, "workspace_id">, Field<&ExecutionReply::stdout_offset, u64, "stdout_offset">, Field<&ExecutionReply::stderr_offset, u64, "stderr_offset">, Field<&ExecutionReply::stdout_total, u64, "stdout_total">, Field<&ExecutionReply::stderr_total, u64, "stderr_total">, Field<&ExecutionReply::input_offset, u64, "input_offset">, Field<&ExecutionReply::input_available, u64, "input_available">, Field<&ExecutionReply::state, EnumByte<ExecutionState, 3>, "state">, Field<&ExecutionReply::exit_code, i32, "exit_code">, Field<&ExecutionReply::stdin_open, BoolByte, "stdin_open">, Field<&ExecutionReply::failure, SizedBytes<u16, 128>, "failure">, Field<&ExecutionReply::stdout_bytes, SizedBytes<u16, 4096>, "stdout">, Field<&ExecutionReply::stderr_bytes, SizedBytes<u16, 4096>, "stderr">> {};

  }
}
