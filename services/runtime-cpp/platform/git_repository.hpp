#pragma once

#include "command_output.hpp"
#include "git_observation_policy.hpp"
#include <charconv>

namespace telar::runtime {

template <Allocator Memory>
class GitRepository {
public:
  using Clock = std::chrono::steady_clock;

  explicit GitRepository(Memory &memory, std::string_view root, Clock::time_point deadline, const std::atomic<bool> &cancelled)
      : memory_(memory),
        root_(root),
        deadline_(deadline),
        output_(memory, maximum_output, &cancelled),
        overrides_(AllocatorRef<String<Memory>, Memory>{memory}) {
    if (execute({"config", "--show-scope", "-z", "--get-regexp", "^(filter\\.|extensions\\.partialclone$|remote\\..*\\.(promisor|partialclonefilter|uploadpack)$)"}) > 1) {
      reject();
    }
    const auto facts = GitRepositoryFacts::parse(output_.text());
    if (!facts) {
      reject();
    }

    for (std::size_t index = 0; index < facts->driver_count; ++index) {
      for (const auto suffix : {".clean=", ".smudge=", ".process="}) {
        overrides_.emplace_back("filter.", AllocatorRef<char, Memory>{memory});
        overrides_.back() += facts->drivers[index];
        overrides_.back() += suffix;
      }
    }
    if (facts->may_fetch) {
      verifyLazyFetchControl();
    }
  }

  std::string_view run(std::initializer_list<std::string_view> arguments, bool retain_prefix = false, std::size_t maximum_bytes = maximum_output) {
    if (execute(arguments, retain_prefix) != 0) {
      reject();
    }
    auto text = output_.text();
    if (text.size() > maximum_bytes) {
      reject();
    }
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
      text.remove_suffix(1);
    }
    return text;
  }

  int execute(std::initializer_list<std::string_view> arguments, bool retain_prefix = false) {
    return withCommand(arguments, [&](auto &command) { return output_.run(command, deadline_, retain_prefix); });
  }

  template <typename Consumer>
  int stream(std::initializer_list<std::string_view> arguments, Consumer &&consume, Clock::time_point deadline = Clock::time_point::max()) {
    return withCommand(arguments, [&](auto &command) { return output_.stream(command, deadline, consume); });
  }

private:
  void verifyLazyFetchControl() {
    const auto version = run({"version"});
    constexpr std::string_view prefix = "git version ";
    if (!version.starts_with(prefix)) {
      reject();
    }

    const auto number = version.substr(prefix.size());
    unsigned major = 0;
    const auto parsed = std::from_chars(number.data(), number.data() + number.size(), major);
    if (parsed.ec != std::errc{} || parsed.ptr == number.data() + number.size() || *parsed.ptr != '.') {
      reject();
    }

    unsigned minor = 0;
    const auto subversion = std::from_chars(parsed.ptr + 1, number.data() + number.size(), minor);
    constexpr unsigned lazy_fetch_major = 2;
    constexpr unsigned lazy_fetch_minor = 45;
    if (subversion.ec != std::errc{} || major < lazy_fetch_major || (major == lazy_fetch_major && minor < lazy_fetch_minor)) {
      reject();
    }
  }

  template <typename Operation>
  int withCommand(std::initializer_list<std::string_view> arguments, Operation &&operation) {
    std::array<std::string_view, 128> complete;
    std::size_t count = 0;
    for (const auto argument : git_observation_options) {
      complete[count++] = argument;
    }
    for (const auto &override : overrides_) {
      complete[count++] = "-c";
      complete[count++] = override;
    }
    if (arguments.size() > complete.size() - count) {
      reject();
    }
    for (const auto argument : arguments) {
      complete[count++] = argument;
    }
    Command command{memory_, Launch{.cwd = root_, .arguments = std::span{complete}.first(count)}, CommandPurpose::administration};
    command.removeEnvironmentPrefix("GIT_");
    command.setEnvironment("GIT_OPTIONAL_LOCKS", "0");
    command.setEnvironment("GIT_NO_LAZY_FETCH", "1");
    command.setEnvironment("GIT_TERMINAL_PROMPT", "0");
    command.setEnvironment("LC_ALL", "C");
    return operation(command);
  }

  [[noreturn]] static void reject() {
    throw RequestError{FailureCode::invalid_request, "Git observation unavailable"};
  }

  static constexpr std::size_t maximum_output = 64 * 1024;
  Memory &memory_;
  std::string_view root_;
  Clock::time_point deadline_;
  CommandOutput<Memory> output_;
  Vector<String<Memory>, Memory> overrides_;
};

}
