#pragma once

#include "../memory/fixed_text.hpp"
#include "../platform/git_files.hpp"
#include "../platform/git_repository.hpp"

namespace telar::runtime {

inline constexpr auto git_distance_timeout = std::chrono::seconds{10};

struct GitDistance {
  std::uint32_t added = 0;
  std::uint32_t removed = 0;
  std::uint32_t files = 0;
  std::uint32_t ahead = 0;
};

template <Allocator Memory>
class GitBaseDistance {
public:
  using Clock = std::chrono::steady_clock;

  explicit GitBaseDistance(Memory &memory, const std::atomic<bool> &cancelled) noexcept
      : memory_(memory),
        cancelled_(cancelled) {}

  GitDistance read(std::string_view root, std::string_view base, Clock::time_point deadline) {
    if (base.empty() || base.starts_with('-')) {
      reject();
    }

    const auto ancestor = line<64>(root, deadline, {"merge-base", base, "HEAD"});
    const auto difference = line<4096>(root, deadline, {"diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--shortstat", ancestor.view(), "--"});
    GitDistance result;
    parseDiff(difference.view(), result);
    String<Memory> range{ancestor.view(), AllocatorRef<char, Memory>{memory_}};
    range += "..HEAD";
    const auto count = line<32>(root, deadline, {"rev-list", "--count", range, "--"});
    const auto text = count.view();
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result.ahead);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
      reject();
    }

    return result;
  }

private:
  template <std::size_t Capacity>
  FixedText<Capacity> line(std::string_view root, Clock::time_point deadline, std::initializer_list<std::string_view> arguments) {
    GitRepository git{memory_, root, deadline, cancelled_};
    constexpr std::size_t maximum_output = 4096;
    const auto output = git.run(arguments, false, maximum_output);
    const auto trimmed = GitFiles::trim(output, " \r\n");
    if (trimmed.size() > Capacity) {
      reject();
    }

    FixedText<Capacity> result;
    result.assign(trimmed);
    return result;
  }

  static void parseDiff(std::string_view output, GitDistance &result) noexcept {
    while (!output.empty()) {
      const auto delimiter = output.find(',');
      const auto part = GitFiles::trim(output.substr(0, delimiter), " \n");
      output = delimiter == std::string_view::npos ? std::string_view{} : output.substr(delimiter + 1);
      const auto separator = part.find(' ');
      if (separator == std::string_view::npos) {
        continue;
      }

      std::uint32_t value = 0;
      const auto parsed = std::from_chars(part.data(), part.data() + separator, value);
      if (parsed.ec != std::errc{} || parsed.ptr != part.data() + separator) {
        continue;
      }
      const auto label = part.substr(separator + 1);
      if (label.starts_with("file")) {
        result.files = value;
      } else if (label.starts_with("insertion")) {
        result.added = value;
      } else if (label.starts_with("deletion")) {
        result.removed = value;
      }
    }
  }

  [[noreturn]] static void reject() {
    throw RequestError{FailureCode::invalid_request, "Git distance unavailable"};
  }

  Memory &memory_;
  const std::atomic<bool> &cancelled_;
};

}
