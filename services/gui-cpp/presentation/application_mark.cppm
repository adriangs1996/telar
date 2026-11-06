module;

#include <cstdint>


#include "telar_client/serializers/telar_messages.hpp"
#include <string_view>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>


#include <algorithm>
#include <limits>
#include <optional>


#include <bit>
#include <cstddef>
#include <stdexcept>
#include <cstring>

export module telar.gui.presentation.application_mark;

export import telar.config;


export import telar.gui.core.unicode_scalar;

// Interface: presentation/activity_card.cppm
export {
namespace telar::gui {

enum class ActivityCard : std::uint8_t {
  agent,
  task_full,
  task_compact,
};

}
}

// Interface: presentation/application_mark.cppm
export {
namespace telar::gui {

struct ApplicationMark {
  static constexpr float dimmed_alpha = 0.6F;
  static constexpr float atlas_cell_side = 20;
  static constexpr int minimum_cell = 8;
  static constexpr int maximum_cell = 96;

  AgentProvider provider = AgentProvider::unknown;
  std::string_view glyph = "\uea85";
  std::string_view tile = "#2b2a3a";
  std::string_view ink = "#5fb095";

  [[nodiscard]] inline bool followsTheme() const noexcept {
    return provider == AgentProvider::codex || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
  }

  [[nodiscard]] inline static ApplicationMark forApplication(std::string_view name) noexcept {
    auto provider = runtime::builtinProviderFromExecutable(name);
    if (provider == AgentProvider::unknown) {
      for (const auto candidate : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
        if (name == runtime::describeProvider(candidate).display_name) {
          provider = candidate;
          break;
        }
      }
    }

    switch (provider) {
    case AgentProvider::claude:
      return {.provider = provider, .glyph = "\uec20", .tile = "#d97757", .ink = "#1a1627"};
    case AgentProvider::codex:
      return {.provider = provider, .glyph = "\uea85", .tile = "#f2f1f5", .ink = "#1a1627"};
    case AgentProvider::pi:
      return {.provider = provider, .glyph = "\U000f03ff", .tile = "#e5ca93", .ink = "#1a1627"};
    case AgentProvider::cursor:
      return {.provider = provider, .glyph = "\U000f02d8", .tile = "#e5e3ee", .ink = "#1a1627"};
    case AgentProvider::opencode:
      return {.provider = provider, .glyph = "\U000f0763", .tile = "#99baf8", .ink = "#1a1627"};
    default:
      break;
    }

    struct Known {
      std::string_view name;
      std::string_view glyph;
      std::string_view tile;
      std::string_view ink;
    };
    // Terminal programs have no operating system icon of their own.
    static constexpr std::array known{
        Known{"nvim", "\ue62b", "#5fb095", "#0f1a16"}, Known{"vim", "\ue62b", "#5fb095", "#0f1a16"}, Known{"vi", "\ue62b", "#5fb095", "#0f1a16"},
        Known{"git", "\ue702", "#f37986", "#1a1627"}, Known{"lazygit", "\ue702", "#f37986", "#1a1627"},
        Known{"node", "\ue718", "#83cd29", "#10210a"}, Known{"npm", "\ue718", "#83cd29", "#10210a"},
        Known{"python", "\ue73c", "#ffd43b", "#1f2d3d"}, Known{"python3", "\ue73c", "#ffd43b", "#1f2d3d"},
        Known{"ruby", "\ue739", "#cc342d", "#ffffff"}, Known{"irb", "\ue739", "#cc342d", "#ffffff"}, Known{"bundle", "\ue739", "#cc342d", "#ffffff"},
        Known{"docker", "\uf308", "#2496ed", "#ffffff"},
        Known{"cargo", "\ue7a8", "#dea584", "#1a1627"},
        Known{"go", "\ue626", "#00add8", "#08252b"},
        Known{"bun", "B", "#fbf0df", "#1a1627"},
    };
    for (const auto &entry : known) {
      if (entry.name == name) {
        return {.provider = AgentProvider::unknown, .glyph = entry.glyph, .tile = entry.tile, .ink = entry.ink};
      }
    }

    return {};
  }
};

}
}

// Interface: presentation/loading_cue.cppm
export {
namespace telar::gui {

class LoadingCue {
public:
  static constexpr std::uint64_t delay_ns = 150'000'000;

  [[nodiscard]] inline bool sample(bool waiting, std::optional<std::uint64_t> now_ns) noexcept {
    if (!waiting || !now_ns) {
      since_ns_.reset();

      return waiting;
    }

    const auto since = since_ns_.value_or(*now_ns);
    since_ns_ = since;

    return *now_ns >= visibleAt(since);
  }

  [[nodiscard]] inline std::optional<std::uint64_t> deadline() const noexcept {
    return since_ns_ ? std::optional{visibleAt(*since_ns_)} : std::nullopt;
  }

private:
  [[nodiscard]] inline static std::uint64_t visibleAt(std::uint64_t since_ns) noexcept {
    return since_ns + std::min(delay_ns, std::numeric_limits<std::uint64_t>::max() - since_ns);
  }

  std::optional<std::uint64_t> since_ns_;
};

}
}

// Interface: presentation/status_age.cppm
export {
namespace telar::gui {

struct StatusAgeInterval {
  static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
  std::uint64_t age_ns = 0;
  std::uint64_t sampled_ns = 0;

  [[nodiscard]] inline std::uint64_t elapsed(std::uint64_t now_ns) const noexcept {
    const auto delta = now_ns > sampled_ns ? now_ns - sampled_ns : 0;

    return age_ns + std::min(std::numeric_limits<std::uint64_t>::max() - age_ns, delta);
  }

  [[nodiscard]] inline std::uint32_t seconds(std::uint64_t now_ns) const noexcept {
    return static_cast<std::uint32_t>(std::min<std::uint64_t>(std::numeric_limits<std::uint32_t>::max(), elapsed(now_ns) / nanoseconds_per_second));
  }

  bool operator==(const StatusAgeInterval &) const = default;
};

struct StatusAgeSample {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;
  AgentStatus status = AgentStatus::unknown;
  AgentProvider provider = AgentProvider::unknown;
  std::uint32_t reported_seconds = 0;

  [[nodiscard]] inline bool continues(const StatusAgeSample &previous) const noexcept {
    return pane_id == previous.pane_id && pane_generation == previous.pane_generation && status == previous.status && provider == previous.provider && reported_seconds >= previous.reported_seconds;
  }
};

class StatusAge {
public:
  inline void observe(StatusAgeSample sample, std::uint64_t now_ns) noexcept {
    auto age_ns = static_cast<std::uint64_t>(sample.reported_seconds) * StatusAgeInterval::nanoseconds_per_second;
    if (sample.continues(sample_)) {
      age_ns = std::max(age_ns, interval_.elapsed(now_ns));
    }

    sample_ = sample;
    interval_ = {.age_ns = age_ns, .sampled_ns = now_ns};
  }

  [[nodiscard]] inline bool observed() const noexcept {
    return sample_.pane_id != 0;
  }

  [[nodiscard]] inline StatusAgeInterval interval() const noexcept {
    return interval_;
  }

private:
  StatusAgeSample sample_;
  StatusAgeInterval interval_;
};

}
}

// Interface: presentation/window_title.cppm
export {
namespace telar::gui {

class WindowTitle {
public:
  static constexpr std::size_t capacity = 256;
  static constexpr std::string_view default_title = "Telar";

  struct Tokens {
    std::string_view workspace;
    std::string_view tab;
    std::string_view pane_title;
    std::string_view hostname;
  };

  [[nodiscard]] inline static WindowTitle render(std::string_view pattern, Tokens tokens) {
    WindowTitle result;
    while (!pattern.empty()) {
      const auto consumed = result.expand(pattern, tokens);
      if (consumed != 0) {
        pattern.remove_prefix(consumed);
      } else {
        result.append(pattern.substr(0, 1));
        pattern.remove_prefix(1);
      }
    }

    result.filter();

    return result;
  }

  inline void appendSuffix(std::string_view suffix) noexcept {
    constexpr unsigned continuation_mask = 0xc0;
    const auto suffix_length = std::min(suffix.size(), capacity);
    auto kept = std::min(length_, capacity - suffix_length);
    while (kept > 0 && kept < length_ && (static_cast<unsigned char>(bytes_[kept]) & continuation_mask) == Utf8Scalar::continuation_prefix) {
      --kept;
    }

    if (suffix_length != 0) {
      std::memmove(bytes_.data() + kept, suffix.data(), suffix_length);
    }

    length_ = kept + suffix_length;
  }

  [[nodiscard]] inline std::string_view view() const noexcept {
    return {bytes_.data(), length_};
  }

private:
  inline std::size_t expand(std::string_view pattern, Tokens values) {
    if (!pattern.starts_with('{')) {
      return 0;
    }

    const auto close = pattern.find('}');
    if (close == std::string_view::npos) {
      return 0;
    }

    const auto value = token(pattern.substr(1, close - 1), values);
    if (!value) {
      return 0;
    }

    append(*value);

    return close + 1;
  }

  inline static std::optional<std::string_view> token(std::string_view name, Tokens values) noexcept {
    if (name == "workspace") {
      return values.workspace;
    }

    if (name == "tab") {
      return values.tab;
    }

    if (name == "pane_title") {
      return values.pane_title;
    }

    if (name == "hostname") {
      return values.hostname;
    }

    return std::nullopt;
  }

  inline void append(std::string_view value) noexcept {
    const auto count = std::min(capacity - length_, value.size());
    if (count != 0) {
      std::memcpy(bytes_.data() + length_, value.data(), count);
      length_ += count;
    }
  }

  inline void filter() {
    constexpr unsigned printable_start = 0x20;
    constexpr unsigned control_start = 0x7f;
    constexpr unsigned control_end = 0x9f;
    std::size_t position = 0;
    std::size_t written = 0;
    while (position < length_) {
      const auto first = static_cast<unsigned char>(bytes_[position]);
      const auto size = first <= Utf8Scalar::maximum_codepoints.front() ? std::size_t{1} : static_cast<std::size_t>(std::countl_one(first));
      if (size > Utf8Scalar::leading_masks.size() || size > length_ - position) {
        break;
      }

      try {
        const auto codepoint = Utf8Scalar::decode({bytes_.data() + position, size});
        if (codepoint >= printable_start && (codepoint < control_start || codepoint > control_end)) {
          std::memmove(bytes_.data() + written, bytes_.data() + position, size);
          written += size;
        }
      } catch (const std::invalid_argument &) {
        break;
      }

      position += size;
    }

    length_ = written;
  }

  std::array<char, capacity> bytes_{};
  std::size_t length_ = 0;
};

}
}
