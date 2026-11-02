#pragma once

#include "../platform/command.hpp"
#include "../platform/pipe_process.hpp"
#include "../proxy/socket.hpp"
#include <chrono>
#include <poll.h>

namespace telar::runtime::redirect {

template <Allocator Memory>
class PfCommand {
public:
  explicit PfCommand(Memory &memory) noexcept : memory_(memory) {}

  String<Memory> run(std::span<const std::string_view> arguments, std::string_view input = {}) {
    constexpr std::size_t maximum_arguments = 12;
    if (arguments.size() >= maximum_arguments) {
      throw std::invalid_argument{"Too many PF command arguments"};
    }
    std::array<std::string_view, maximum_arguments> argv{};
    argv[0] = "/sbin/pfctl";
    std::ranges::copy(arguments, argv.begin() + 1);
    const std::array<EnvironmentEntry, 2> environment{{{"LC_ALL", "C"}, {"PATH", "/usr/bin:/bin:/usr/sbin:/sbin"}}};
    Command command{memory_, Launch{.cwd = "/", .arguments = std::span{argv}.first(arguments.size() + 1), .environment_mode = EnvironmentMode::replace, .environment = environment}, CommandPurpose::administration};
    PipeProcess process{command.specification({})};
    String<Memory> output{AllocatorRef<char, Memory>{memory_}};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    bool out_open = true;
    bool err_open = true;
    while (out_open || err_open || !process.reap()) {
      if (input.empty()) {
        process.closeInput();
      }
      std::array<pollfd, 3> descriptors{{{process.input(), POLLOUT, 0}, {out_open ? process.output() : -1, POLLIN, 0}, {err_open ? process.error() : -1, POLLIN, 0}}};
      constexpr int poll_ms = 20;
      if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && errno != EINTR) {
        throw SystemError{"Poll PF administration command"};
      }
      if (!input.empty() && (descriptors[0].revents & POLLOUT)) {
        const auto written = ::write(process.input(), input.data(), input.size());
        if (written > 0) {
          input.remove_prefix(static_cast<std::size_t>(written));
        } else if (written == 0 || !socketWouldBlock(errno)) {
          throw SystemError{"Write PF rules"};
        }
      }
      drain(process.output(), out_open, output);
      drain(process.error(), err_open, output);
      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"PF administration command timed out", ETIMEDOUT};
      }
    }
    const auto status = *process.reap();
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      throw std::runtime_error{std::string{output.data(), output.size()}};
    }
    return output;
  }

private:
  static void drain(int descriptor, bool &open, String<Memory> &output) {
    if (!open) {
      return;
    }
    std::array<char, 4096> bytes{};
    const auto count = ::read(descriptor, bytes.data(), bytes.size());
    if (count == 0) {
      open = false;
    } else if (count > 0) {
      constexpr std::size_t output_limit = 256 * 1024;
      if (output.size() + static_cast<std::size_t>(count) > output_limit) {
        throw std::runtime_error{"PF command output exceeds its limit"};
      }
      output.append(bytes.data(), static_cast<std::size_t>(count));
    } else if (!socketWouldBlock(errno)) {
      throw SystemError{"Read PF command output"};
    }
  }

  Memory &memory_;
};

}
