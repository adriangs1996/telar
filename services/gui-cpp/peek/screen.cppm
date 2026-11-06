module;

#include <cstdint>
#include <string_view>


#include <cstddef>


#include "telar_client/serializers/telar_messages.hpp"
#include <variant>


#include "../core/memory.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <optional>
#include <stdexcept>

export module telar.gui.peek.screen;

export import telar.gui.suggestions.state;


export import telar.gui.palette.navigation_label;

// Interface: peek/command.cppm
export {
namespace telar::gui {

enum class PeekCommand : std::uint8_t {
  open,
  stop,
  diff,
  message,
};

struct PeekInput {
  [[nodiscard]] inline static std::string_view trim(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(" \t");
    if (first == std::string_view::npos) {
      return {};
    }

    text.remove_suffix(text.size() - text.find_last_not_of(" \t") - 1);
    text.remove_prefix(first);

    return text;
  }

  [[nodiscard]] inline static PeekCommand command(std::string_view text) noexcept {
    text = trim(text);
    if (text.empty() || text == "/open") {
      return PeekCommand::open;
    }

    if (text == "/stop") {
      return PeekCommand::stop;
    }

    return text == "/diff" ? PeekCommand::diff : PeekCommand::message;
  }
};

}
}

// Interface: peek/limits.cppm
export {
namespace telar::gui {

struct PeekLimits {
  static constexpr std::uint16_t rows = 16;
  static constexpr std::size_t row_cells = 256;
  static constexpr std::size_t cell_bytes = 4;
  static constexpr std::size_t text_bytes = rows * row_cells * cell_bytes;
  static constexpr std::size_t message_bytes = SuggestionLimits::request_bytes;
};

}
}

// Interface: peek/target.cppm
export {
namespace telar::gui {

struct PeekTarget {
  AgentNavigationTarget agent;
  decltype(AgentSnapshotEntry::session_id) session{};

  bool operator==(const PeekTarget &) const noexcept = default;
};

}
}

// Interface: peek/screen.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class PeekScreen {
public:
  inline explicit PeekScreen(Memory &memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  inline void show(PeekTarget target) noexcept {
    target_ = target;
    text_.clear();
    request_id_ = 0;
    ++revision_;
  }

  inline void close() noexcept {
    target_.reset();
    text_.clear();
    request_id_ = 0;
    ++revision_;
  }

  [[nodiscard]] inline const auto &target() const noexcept {
    return target_;
  }

  [[nodiscard]] inline std::string_view text() const noexcept {
    return text_;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline bool reading() const noexcept {
    return request_id_ != 0;
  }

  [[nodiscard]] inline bool owns(std::uint64_t request) const noexcept {
    return request != 0 && request_id_ == request;
  }

  [[nodiscard]] inline std::optional<ReadPane> request(std::uint64_t identity) {
    if (!target_ || reading()) {
      return std::nullopt;
    }

    if (identity == 0) {
      throw std::invalid_argument{"InvalidPeekRequest"};
    }

    request_id_ = identity;

    return ReadPane{.request_id = identity, .pane_id = target_->agent.pane_id, .pane_generation = target_->agent.pane_generation, .rows = PeekLimits::rows, .source = PaneTextSource::recent};
  }

  inline bool fail(std::uint64_t identity) noexcept {
    if (!owns(identity)) {
      return false;
    }

    request_id_ = 0;

    return true;
  }

  [[nodiscard]] inline std::optional<std::size_t> store(const PaneText &reply) {
    if (!owns(reply.request_id)) {
      return std::nullopt;
    }

    request_id_ = 0;
    if (!target_ || target_->agent.pane_id != reply.pane_id) {
      return std::nullopt;
    }

    auto start = reply.text.size() - std::min(reply.text.size(), PeekLimits::text_bytes);
    constexpr unsigned char continuation_mask = 0xc0;
    constexpr unsigned char continuation_bits = 0x80;
    while (start > 0 && start < reply.text.size() && (static_cast<unsigned char>(reply.text[start]) & continuation_mask) == continuation_bits) {
      ++start;
    }

    text_ = reply.text.substr(start);
    ++revision_;

    return start;
  }

  [[nodiscard]] inline static std::string_view lastLines(std::string_view text, std::uint16_t count) noexcept {
    const auto last = text.find_last_not_of(" \n\r\t");
    if (last == std::string_view::npos) {
      return {};
    }

    text.remove_suffix(text.size() - last - 1);
    auto start = text.size();
    std::uint16_t seen = 0;
    while (start > 0 && seen < count) {
      --start;
      if (text[start] == '\n') {
        ++seen;
        if (seen == count) {
          ++start;
          break;
        }
      }
    }

    text.remove_prefix(start);

    return text;
  }

private:
  String<Memory> text_;
  std::optional<PeekTarget> target_;
  std::uint64_t request_id_ = 0;
  std::uint64_t revision_ = 0;
};

}
}
