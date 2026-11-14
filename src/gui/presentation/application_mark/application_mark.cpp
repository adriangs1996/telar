module telar.gui.presentation.application_mark;

import std;
import telar.tbc;

import telar.config.core;
import telar.gui.core.unicode_scalar;
import telar.wire.vocabulary;

namespace telar::gui {

  bool ApplicationMark::followsTheme() const noexcept {
    return provider == AgentProvider::codex || provider == AgentProvider::pi || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
  }

  ApplicationMark ApplicationMark::forApplication(std::string_view name) noexcept {
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
      return {.provider = provider, .glyph = "", .tile = "#d97757", .ink = "#1a1627"};
    case AgentProvider::codex:
      return {.provider = provider, .glyph = "", .tile = "#f2f1f5", .ink = "#1a1627"};
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
        Known{"nvim", "", "#5fb095", "#0f1a16"},
        Known{"vim", "", "#5fb095", "#0f1a16"},
        Known{"vi", "", "#5fb095", "#0f1a16"},
        Known{"git", "", "#f37986", "#1a1627"},
        Known{"lazygit", "", "#f37986", "#1a1627"},
        Known{"node", "", "#83cd29", "#10210a"},
        Known{"npm", "", "#83cd29", "#10210a"},
        Known{"python", "", "#ffd43b", "#1f2d3d"},
        Known{"python3", "", "#ffd43b", "#1f2d3d"},
        Known{"ruby", "", "#cc342d", "#ffffff"},
        Known{"irb", "", "#cc342d", "#ffffff"},
        Known{"bundle", "", "#cc342d", "#ffffff"},
        Known{"docker", "", "#2496ed", "#ffffff"},
        Known{"cargo", "", "#dea584", "#1a1627"},
        Known{"go", "", "#00add8", "#08252b"},
        Known{"bun", "B", "#fbf0df", "#1a1627"},
    };

    for (const auto& entry : known) {
      if (entry.name == name) {
        return {.provider = AgentProvider::unknown, .glyph = entry.glyph, .tile = entry.tile, .ink = entry.ink};
      }
    }

    return {};
  }

  bool LoadingCue::sample(bool waiting, std::optional<std::uint64_t> now_ns) noexcept {
    if (!waiting || !now_ns) {
      since_ns_.reset();

      return waiting;
    }

    const auto since = since_ns_.value_or(*now_ns);

    since_ns_ = since;

    return *now_ns >= visibleAt(since);
  }

  std::optional<std::uint64_t> LoadingCue::deadline() const noexcept {
    return since_ns_ ? std::optional{visibleAt(*since_ns_)} : std::nullopt;
  }

  std::uint64_t LoadingCue::visibleAt(std::uint64_t since_ns) noexcept {
    return since_ns + std::min(delay_ns, std::numeric_limits<std::uint64_t>::max() - since_ns);
  }

  WindowTitle WindowTitle::render(std::string_view pattern, Tokens tokens) {
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

  void WindowTitle::appendSuffix(std::string_view suffix) noexcept {
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

  std::string_view WindowTitle::view() const noexcept {
    return {bytes_.data(), length_};
  }

  std::size_t WindowTitle::expand(std::string_view pattern, Tokens values) {
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

  tbc::view<std::optional<std::string_view>, tbc::lt::a> WindowTitle::token(std::string_view name, tbc::view<Tokens, tbc::lt::a> values) noexcept {
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

  void WindowTitle::append(std::string_view value) noexcept {
    const auto count = std::min(capacity - length_, value.size());
    if (count != 0) {
      std::memcpy(bytes_.data() + length_, value.data(), count);
      length_ += count;
    }
  }

  void WindowTitle::filter() {
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
      } catch (const std::invalid_argument&) {
        break;
      }

      position += size;
    }

    length_ = written;
  }

}
