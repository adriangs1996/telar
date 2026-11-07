module;
#include "telar_platform/trace_macro.hpp"
#include <utility>
#include <concepts>
#include <memory>
#include <type_traits>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>
#include <bit>
#include <chrono>
#include <cstdlib>
#include <mutex>
#include <new>

#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

#include <array>
#include <cstring>
#include <optional>
#include <span>
#include <string_view>
#include <unistd.h>

#include <cstddef>
#include <cstdint>
#include <exception>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <variant>
#include <stdexcept>

export module telar.cli.hooks.session;

export import telar.platform;


export import telar.cli.runtime_observer;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: hooks/codex_subagents.cppm
export {
namespace telar::runtime::cli::hooks {

class CodexSubagents {
public:
  inline void read(std::string_view path) noexcept {
    count_ = 0;
    if (!path.starts_with('/') || !path.ends_with(".jsonl") || path.size() >= PATH_MAX || path.contains('\0')) {
      return;
    }

    std::array<char, PATH_MAX> terminated;
    std::memcpy(terminated.data(), path.data(), path.size());
    terminated[path.size()] = '\0';
    FileDescriptor file{::open(terminated.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
    struct stat status;
    if (!file || ::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != ::getuid()) {
      return;
    }

    std::array<char, 64 * 1024> window;
    std::size_t held = 0;
    for (;;) {
      const auto received = ::read(file.get(), window.data() + held, window.size() - held);
      if (received < 0 && errno == EINTR) {
        continue;
      }
      if (received < 0) {
        count_ = 0;
        return;
      }

      const auto filled = held + static_cast<std::size_t>(received);
      const auto consumed = scan({window.data(), filled}, received == 0);
      if (received == 0) {
        return;
      }

      held = filled - consumed;
      std::memmove(window.data(), window.data() + consumed, held);
    }
  }

  inline std::size_t countExcept(std::string_view finished) const noexcept {
    return count_ - (find(finished) != count_);
  }

private:
  inline static std::string_view value(std::string_view item, std::string_view key) noexcept {
    const auto offset = item.find(key);
    if (offset == std::string_view::npos) {
      return {};
    }

    item.remove_prefix(offset + key.size());
    const auto end = item.find('"');
    return end == std::string_view::npos ? std::string_view{} : item.substr(0, end);
  }

  inline std::size_t find(std::string_view identifier) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      if (identifiers_[index].view() == identifier) {
        return index;
      }
    }

    return count_;
  }

  inline void apply(std::string_view item) noexcept {
    const auto kind = value(item, "\"kind\":\"");
    const auto identifier = value(item, "\"agent_thread_id\":\"");
    if (identifier.empty() || identifier.size() > 64) {
      return;
    }

    const auto index = find(identifier);
    if (kind == "started" && index == count_ && count_ != identifiers_.size()) {
      identifiers_[count_++].assign(identifier);
    } else if (kind == "completed" && index != count_) {
      identifiers_[index] = identifiers_[--count_];
    }
  }

  inline std::size_t scan(std::string_view bytes, bool at_end) noexcept {
    constexpr std::string_view marker = "\"item\":{\"type\":\"SubAgentActivity\"";
    constexpr std::size_t maximum_item_bytes = 1024;
    std::size_t cursor = 0;
    for (;;) {
      const auto start = bytes.find(marker, cursor);
      if (start == std::string_view::npos) {
        break;
      }

      const auto limit = std::min(bytes.size(), start + maximum_item_bytes);
      const auto close = bytes.substr(0, limit).find('}', start + marker.size());
      if (close == std::string_view::npos) {
        if (limit == bytes.size() && !at_end) {
          return start;
        }

        cursor = start + marker.size();
        continue;
      }

      apply(bytes.substr(start, close - start));
      cursor = close + 1;
    }

    const auto tail = std::min(bytes.size(), marker.size() - 1);
    return at_end ? bytes.size() : std::max(cursor, bytes.size() - tail);
  }

  std::array<FixedText<64>, 32> identifiers_;
  std::size_t count_ = 0;
};

}
}

// Interface: hooks/reports.cppm
export {
namespace telar::runtime::cli::hooks {

struct Reports {
  std::optional<ReportAgent> lifecycle;
  std::optional<ReportAgentCommand> command;
  std::optional<ReportAgentTitle> title;
  std::optional<ReportAgentProgress> progress;
  FixedText<96> event;
  FixedText<96> step;
  FixedText<2048> message;
  LinkedWorktree worktree;

  inline bool empty() const noexcept {
    return !lifecycle && !command && !title && !progress;
  }
};

}
}

// Interface: hooks/session.cppm
export {
namespace telar::runtime::cli::hooks {

struct PaneTarget {
  std::uint64_t pane_id;
  std::uint64_t generation;
  AgentProvider provider;
};

// The hook's conversation with the runtime: every report carries the pane and
// provider the hook runs for, and the runtime first verifies the reporter's ancestry.
template <Allocator Memory>
class Session {
public:
  inline Session(Memory &memory, const char *socket, PaneTarget target)
      : control_(memory, socket, reply_bytes),
        target_(target) {
    control_.receiveTimeout(30);
    exchange(VerifyPaneDescent{});
  }

  template <typename Report>
  inline void report(Report value) noexcept {
    try {
      TELAR_TRACE("hooks.sendReport");
      exchange(value);
    } catch (const std::exception &) {
    }
  }

  inline void reportLimit(std::uint64_t received, std::size_t capacity) noexcept {
    try {
      control_.send(ReportLimit{.reach = {.name = "hooks.max_input_bytes", .noun = "bytes", .value = capacity, .requested = received}, .hits = 1});
    } catch (const std::exception &) {
    }
  }

  template <typename Reply = RequestCompleted, typename Report>
  inline Reply exchange(Report value) {
    if constexpr (requires { value.pane_id; value.pane_generation; }) {
      value.pane_id = target_.pane_id;
      value.pane_generation = target_.generation;
    }
    if constexpr (requires { value.provider = AgentProvider{}; }) {
      value.provider = target_.provider;
    }

    return control_.template exchange<Reply>(value);
  }

private:
  static constexpr std::size_t reply_bytes = 2048;

  ControlSession<Memory> control_;
  PaneTarget target_;
};
}
}
