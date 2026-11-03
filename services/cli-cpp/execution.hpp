#pragma once

#include "control_session.hpp"
#include "ensure_runtime.hpp"
#include "execution_options.hpp"
#include <poll.h>

#include <format>

namespace telar::runtime::cli::execution {

inline constexpr int failure_status = 125;
inline constexpr int timeout_status = 124;
inline constexpr std::chrono::milliseconds poll_interval{10};
inline constexpr std::size_t max_chunk = 4096;

inline std::string_view stateName(ExecutionState state) {
  constexpr std::array names{"starting", "running", "exited", "failed"};
  return names.at(static_cast<std::size_t>(state));
}

inline bool finished(const ExecutionReply &reply) {
  return reply.state == ExecutionState::exited || reply.state == ExecutionState::failed;
}

template <Allocator Memory>
ExecutionReply exchange(ControlSession<Memory> &session, ExecutionRequest request) {
  for (;;) {
    try {
      return session.template exchange<ExecutionReply>(request);
    } catch (const ControlFailure &error) {
      if (error.message() != "ExecutionBusy") {
        throw;
      }

      std::this_thread::sleep_for(poll_interval);
    }
  }
}

inline std::string statusJson(const ExecutionReply &reply) {
  return std::format("{{\"execution_id\":{},\"workspace_id\":{},\"state\":{},\"exit_code\":{},\"stdout_offset\":{},\"stderr_offset\":{},\"stdout_bytes\":{},\"stderr_bytes\":{},\"stdin_bytes\":{},\"stdin_open\":{},\"failure\":{}}}\n", reply.execution_id, reply.workspace_id, quoteJson(stateName(reply.state)), finished(reply) ? std::to_string(reply.exit_code) : "null", reply.stdout_offset, reply.stderr_offset, reply.stdout_total, reply.stderr_total, reply.input_offset, jsonBoolean(reply.stdin_open), quoteJson(textBytes(reply.failure)));
}

inline void writeStreams(ExecutionRequest &request, const ExecutionReply &reply) {
  if (request.stdout_offset != reply.stdout_offset || request.stderr_offset != reply.stderr_offset) {
    writeText(std::format("telar exec: retained output lost; resume with --stdout-offset {} --stderr-offset {}\n", reply.stdout_offset, reply.stderr_offset), STDERR_FILENO);
    throw std::runtime_error{"ExecutionOutputLost"};
  }

  writeBytes(STDOUT_FILENO, reply.stdout_bytes);
  writeBytes(STDERR_FILENO, reply.stderr_bytes);
  request.stdout_offset += reply.stdout_bytes.size();
  request.stderr_offset += reply.stderr_bytes.size();
}

template <Allocator Memory>
void list(ControlSession<Memory> &session) {
  ExecutionRequest request{.action = ExecutionAction::list};
  std::string output = "[";
  for (;;) {
    const auto reply = exchange(session, request);
    if (reply.execution_id == 0) {
      break;
    }

    if (request.execution_id != 0) {
      output += ',';
    }

    output += std::format("{{\"execution_id\":{},\"workspace_id\":{},\"state\":{},\"exit_code\":{}}}", reply.execution_id, reply.workspace_id, quoteJson(stateName(reply.state)), finished(reply) ? std::to_string(reply.exit_code) : "null");
    request.execution_id = reply.execution_id;
  }

  output += "]\n";
  writeText(output);
}

template <Allocator Memory>
int observe(ControlSession<Memory> &session, ExecutionRequest request, ExecutionReply reply, const ExecutionOptions &options) {
  const auto started = std::chrono::steady_clock::now();
  bool stdin_open = request.stdin_open;
  const auto stdout_end = reply.stdout_total;
  const auto stderr_end = reply.stderr_total;
  request.action = ExecutionAction::status;
  request.arguments = {};
  request.cwd = {};
  for (;;) {
    writeStreams(request, reply);
    if (options.action == ExecutionOptions::Action::output) {
      if (request.stdout_offset >= stdout_end && request.stderr_offset >= stderr_end) {
        return 0;
      }
    } else {
      if (finished(reply) && request.stdout_offset == reply.stdout_total && request.stderr_offset == reply.stderr_total) {
        if (reply.state == ExecutionState::failed) {
          writeText("telar exec: " + std::string{textBytes(reply.failure)} + "\n", STDERR_FILENO);
        }

        return std::clamp(reply.exit_code, 0, 255);
      }

      if (options.timeout_seconds != 0 && std::chrono::steady_clock::now() - started >= std::chrono::seconds{options.timeout_seconds}) {
        writeText(std::format("telar exec: wait timed out; execution {} continues\n", request.execution_id), STDERR_FILENO);
        return timeout_status;
      }

      if (stdin_open && reply.stdin_open && reply.input_available >= max_chunk) {
        pollfd input{.fd = STDIN_FILENO, .events = POLLIN, .revents = 0};
        if (::poll(&input, 1, 0) > 0) {
          std::array<Byte, max_chunk> bytes;
          const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
          if (count < 0) {
            throw std::runtime_error{"ExecutionStdinFailed"};
          }

          auto chunk = request;
          chunk.action = count == 0 ? ExecutionAction::eof : ExecutionAction::input;
          chunk.bytes = std::span{bytes}.first(static_cast<std::size_t>(count));
          chunk.input_offset = reply.input_offset;
          reply = exchange(session, chunk);
          stdin_open = count != 0;
          continue;
        }
      }

      if (reply.stdout_bytes.empty() && reply.stderr_bytes.empty()) {
        std::this_thread::sleep_for(poll_interval);
      }
    }

    reply = exchange(session, request);
  }
}

template <Allocator Memory>
int start(ControlSession<Memory> &session, const ExecutionOptions &options) {
  if (options.action == ExecutionOptions::Action::list) {
    list(session);
    return 0;
  }

  const auto action = options.action == ExecutionOptions::Action::start ? ExecutionAction::start : options.action == ExecutionOptions::Action::cancel ? ExecutionAction::cancel
                                                                                               : options.action == ExecutionOptions::Action::forget   ? ExecutionAction::forget
                                                                                                                                                      : ExecutionAction::status;
  ExecutionRequest request{
      .action = action,
      .execution_id = options.id == 0 ? randomIdentity() : options.id,
      .workspace_id = options.workspace,
      .stdout_offset = options.stdout_offset,
      .stderr_offset = options.stderr_offset,
      .stdin_open = options.stdin_open && !options.detach,
      .cwd = options.cwd,
      .arguments = std::span{options.arguments}.first(options.argument_count),
  };

  try {
    const auto reply = exchange(session, request);
    if (options.action == ExecutionOptions::Action::status || options.action == ExecutionOptions::Action::cancel || options.action == ExecutionOptions::Action::forget || options.detach) {
      writeText(statusJson(reply));
      return 0;
    }

    return observe(session, request, reply, options);
  } catch (...) {
    if (options.action == ExecutionOptions::Action::start) {
      writeText(std::format("telar exec: query execution {} before retrying an uncertain launch\n", request.execution_id), STDERR_FILENO);
    }

    throw;
  }
}

template <Allocator Memory>
int run(Memory &memory, const ExecutionOptions &options) {
  try {
    ServerOptions server_options{};
    server_options.socket = options.socket;
    const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
    ensureRuntime(memory, paths);
    ControlSession session{memory, paths.socket.c_str()};
    session.receiveTimeout(30);
    return start(session, options);
  } catch (const ControlFailure &error) {
    writeText("telar exec: " + std::string{error.message().empty() ? error.what() : error.message()} + "\n", STDERR_FILENO);
  } catch (const std::exception &error) {
    writeText("telar exec: " + std::string{commandErrorName(error)} + "\n", STDERR_FILENO);
  }

  return failure_status;
}

}
