#pragma once

#include "../platform/process_inspector.hpp"
#include <charconv>

namespace telar::runtime::redirect {

class ProcessToken {
public:
  static constexpr std::size_t maximum_bytes = 64;

  static ProcessIdentity parse(std::string_view value) {
    const auto separator = value.find('@');
    const auto pid = number(value.substr(0, separator));
    if (pid == 0 || pid > INT32_MAX) { throw std::invalid_argument{"Invalid selected process PID"}; }
    ProcessIdentity process{.pid = static_cast<pid_t>(pid)};
    if (separator == std::string_view::npos) { return process; }
    value.remove_prefix(separator + 1);
    const auto dot = value.find('.');
    if (dot == std::string_view::npos) { throw std::invalid_argument{"Process identity requires creation seconds and microseconds"}; }
    process.started_seconds = number(value.substr(0, dot));
    process.started_microseconds = number(value.substr(dot + 1));
    if (process.started_seconds == 0 || process.started_microseconds >= 1000000) { throw std::invalid_argument{"Invalid process creation time"}; }
    return process;
  }

  static FixedText<maximum_bytes> format(const ProcessIdentity &process) {
    if (process.pid <= 0 || process.started_seconds == 0 || process.started_microseconds >= 1000000) { throw std::invalid_argument{"Process identity is not pinned"}; }
    std::array<char, maximum_bytes> text;
    const auto count = std::snprintf(text.data(), text.size(), "%d@%llu.%06llu", process.pid, static_cast<unsigned long long>(process.started_seconds), static_cast<unsigned long long>(process.started_microseconds));
    if (count <= 0 || static_cast<std::size_t>(count) >= text.size()) { throw std::invalid_argument{"Process identity is too long"}; }
    FixedText<maximum_bytes> result;
    result.assign({text.data(), static_cast<std::size_t>(count)});
    return result;
  }

private:
  static std::uint64_t number(std::string_view value) {
    std::uint64_t result;
    const auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
    if (value.empty() || parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size()) { throw std::invalid_argument{"Invalid selected process identity"}; }
    return result;
  }
};

}
