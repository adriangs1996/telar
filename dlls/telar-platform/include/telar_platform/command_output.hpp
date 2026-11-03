#pragma once

#include "telar_base/memory/byte_queue.hpp"
#include "telar_base/request_error.hpp"
#include "telar_platform/command.hpp"
#include "telar_platform/pipe_process.hpp"
#include <atomic>
#include <chrono>
#include <poll.h>
#include <sys/wait.h>

namespace telar::runtime {

template <Allocator Memory>
class CommandOutput {
public:
  using Clock = std::chrono::steady_clock;

  explicit CommandOutput(Memory &memory, std::size_t limit, const std::atomic<bool> *cancelled = nullptr)
      : output_(memory, limit),
        limit_(limit),
        cancelled_(cancelled) {}

  int run(Command<Memory> &command, Clock::time_point deadline, bool retain_prefix = false, const std::atomic<bool> *cancelled = nullptr) {
    return execute(command, deadline, ExecutionOptions{.cancelled = cancelled}, [&](std::span<const Byte> bytes) { return append(bytes, retain_prefix); });
  }

  int runWithInput(Command<Memory> &command, Clock::time_point deadline, std::span<const std::string_view> input) {
    return execute(command, deadline, ExecutionOptions{.input = input}, [&](std::span<const Byte> bytes) { return append(bytes, true); });
  }

  template <typename ErrorConsumer>
  int runWithInputDiagnostics(Command<Memory> &command, Clock::time_point deadline, std::span<const std::string_view> input, ErrorConsumer &&error) {
    return execute(command, deadline, ExecutionOptions{.input = input}, [&](std::span<const Byte> bytes) { return append(bytes, true); }, error);
  }

  template <typename Consumer>
  int stream(Command<Memory> &command, Clock::time_point deadline, Consumer &&consume) {
    return execute(command, deadline, ExecutionOptions{}, consume);
  }

  template <typename OutputConsumer, typename ErrorConsumer>
  int streamDiagnostics(Command<Memory> &command, Clock::time_point deadline, OutputConsumer &&output, ErrorConsumer &&error) {
    return execute(command, deadline, ExecutionOptions{}, output, error);
  }

  bool truncated() const noexcept {
    return truncated_;
  }

  std::string_view text() const noexcept {
    const auto bytes = output_.readable();
    return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
  }

private:
  struct ExecutionOptions {
    std::span<const std::string_view> input{};
    const std::atomic<bool> *cancelled = nullptr;
  };

  bool append(std::span<const Byte> bytes, bool retain_prefix) {
    const auto available = limit_ - output_.size();
    if (bytes.size() > available && retain_prefix) {
      output_.append(bytes.first(available));
      truncated_ = true;
      return false;
    }

    output_.append(bytes);
    return true;
  }

  template <typename Consumer, typename ErrorConsumer = std::nullptr_t>
  int execute(Command<Memory> &command, Clock::time_point deadline, ExecutionOptions options, Consumer &&consume, ErrorConsumer &&consume_error = nullptr) {
    checkCancellation(options.cancelled);
    output_.clear();
    truncated_ = false;
    PipeProcess process{command.specification({})};
    auto input = options.input;
    std::size_t input_offset = 0;
    if (input.empty()) {
      process.closeInput();
    }

    std::array<Byte, 16 * 1024> bytes;
    while (process.output() >= 0 || process.error() >= 0 || process.input() >= 0) {
      checkCancellation(options.cancelled);
      if (Clock::now() >= deadline) {
        throw RequestError{FailureCode::resource_limit, "Command deadline exceeded"};
      }
      std::array<pollfd, 3> descriptors{{{process.output(), POLLIN, 0}, {process.error(), POLLIN, 0}, {process.input(), POLLOUT, 0}}};
      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
      const int result = ::poll(descriptors.data(), descriptors.size(), static_cast<int>(std::clamp<std::int64_t>(remaining, 0, 20)));
      if (result < 0 && errno != EINTR) {
        throw SystemError{"Wait for command output"};
      }
      if (descriptors[2].fd >= 0 && descriptors[2].revents != 0) {
        writeInput(process, input, input_offset);
      }

      for (std::size_t index = 0; index < 2; ++index) {
        if (descriptors[index].fd < 0 || descriptors[index].revents == 0) {
          continue;
        }
        const auto count = ::read(descriptors[index].fd, bytes.data(), bytes.size());
        if (count > 0) {
          if (index == 0 && !consume(std::span<const Byte>{bytes}.first(static_cast<std::size_t>(count)))) {
            return 0;
          }
          if constexpr (!std::is_same_v<std::remove_cvref_t<ErrorConsumer>, std::nullptr_t>) {
            if (index == 1) {
              consume_error(std::span<const Byte>{bytes}.first(static_cast<std::size_t>(count)));
            }
          }
        } else if (count == 0) {
          if (index == 0) {
            process.closeOutput();
          } else {
            process.closeError();
          }
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
          throw SystemError{"Read command output"};
        }
      }
    }

    while (Clock::now() < deadline) {
      checkCancellation(options.cancelled);
      if (const auto status = process.reap()) {
        return WIFEXITED(*status) ? WEXITSTATUS(*status) : 128 + WTERMSIG(*status);
      }
      ::poll(nullptr, 0, 1);
    }

    throw RequestError{FailureCode::resource_limit, "Command deadline exceeded"};
  }

  static void writeInput(PipeProcess &process, std::span<const std::string_view> &input, std::size_t &offset) {
    while (!input.empty()) {
      if (offset == input.front().size()) {
        input = input.subspan(1);
        offset = 0;
        continue;
      }

      const auto count = ::write(process.input(), input.front().data() + offset, input.front().size() - offset);
      if (count > 0) {
        offset += static_cast<std::size_t>(count);
      } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        throw SystemError{"Write command input"};
      } else {
        return;
      }
    }

    process.closeInput();
  }

  void checkCancellation(const std::atomic<bool> *request_cancelled) const {
    if ((cancelled_ != nullptr && *cancelled_) || (request_cancelled != nullptr && *request_cancelled)) {
      throw RequestError{FailureCode::invalid_request, "Command cancelled"};
    }
  }

  ByteQueue<Memory> output_;
  std::size_t limit_;
  const std::atomic<bool> *cancelled_;
  bool truncated_ = false;
};

}
