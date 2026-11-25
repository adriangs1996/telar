module telar.config.core;

import std;
import telar.tbc;
import telar.sys.posix;
import telar.base.text.utf8;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime::config {

  namespace {

    // A notice's line, cut to its capacity, so that building it never fails.
    class NoticeLine {
    public:
      void text(std::string_view part) noexcept {
        const auto count = std::min(part.size(), capacity - size_);

        std::ranges::copy_n(part.begin(), static_cast<std::ptrdiff_t>(count), bytes_.viewMut().subspan(size_).begin());
        size_ += count;
      }

      void number(std::uint64_t value) noexcept {
        // The digits of the largest std::uint64_t.
        constexpr std::size_t digits_capacity = 20;

        ds::Array<char, digits_capacity> digits{};
        auto view = digits.viewMut();
        const auto written = std::to_chars(std::to_address(view.begin()), std::to_address(view.end()), value);
        const auto length = static_cast<std::size_t>(written.ptr - std::to_address(view.begin()));

        text(std::string_view{digits.data(), length});
      }

      [[nodiscard]] std::span<const char> bytes() const noexcept {
        return bytes_.view().first(size_);
      }

    private:
      static constexpr std::size_t capacity = 512;

      ds::Array<char, capacity> bytes_{};
      std::size_t size_ = 0;
    };

  }

  void LimitNotices::add(tbc::ref_a<LimitReach> reach) noexcept {
    for (auto& entry : entries_.viewMut().first(count_)) {
      if (entry.name == reach.name) {
        if (reach.requested) {
          entry.requested = std::max(entry.requested.valueOr(0), *reach.requested);
        }

        return;
      }
    }

    if (count_ == entries_.size()) {
      return;
    }

    entries_.atMut(count_++) = reach;
  }

  std::span<const LimitReach> LimitNotices::entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

  void LimitNotices::print() const noexcept {
    for (const auto& entry : entries()) {
      const std::string_view separator = entry.noun.empty() ? "" : " ";
      NoticeLine line;

      line.text("telar config: limit reached, the excess was left out: ");
      line.text(entry.name);
      line.text(": ");
      if (entry.requested) {
        line.number(*entry.requested);
        line.text(separator);
        line.text(entry.noun);
        line.text("; limit ");
        line.number(entry.value);
        line.text("\n");
      } else if (entry.value == 0) {
        line.text("limit reached\n");
      } else {
        line.text("limit ");
        line.number(entry.value);
        line.text(separator);
        line.text(entry.noun);
        line.text(" reached\n");
      }

      const auto bytes = line.bytes();

      static_cast<void>(::write(STDERR_FILENO, bytes.data(), bytes.size()));
    }
  }

  void optionalChoice(const lua::Value& value, std::initializer_list<std::string_view> choices) {
    if (!value.present()) {
      return;
    }

    const auto text = value.string();
    if (std::ranges::find(choices, text) == choices.end()) {
      value.fail("is not a supported value");
    }
  }

  void optionalWholeNumber(const lua::Value& value, double minimum, double maximum) {
    const auto number = value.boundedNumber(minimum, {.minimum = minimum, .maximum = maximum});
    if (std::trunc(number) != number) {
      value.fail("must be a whole number");
    }
  }

  void optionalUtf8Text(const lua::Value& value, std::size_t maximum_bytes) {
    if (!value.present()) {
      return;
    }

    const auto text = value.string();

    validateUtf8(text);
    if (text.size() > maximum_bytes || text.contains('\0')) {
      value.fail("exceeds its text bounds or contains NUL");
    }
  }

  ds::Option<std::size_t> optionalChoiceIndex(const lua::Value& value, std::span<const std::string_view> names) {
    if (!value.present()) {
      return ds::none;
    }

    const auto found = std::ranges::find(names, value.string());
    if (found == names.end()) {
      value.fail("is not a supported value");
    }

    return static_cast<std::size_t>(found - names.begin());
  }

  ds::Option<double> optionalNumber(const lua::Value& value, Bounds<double> bounds) {
    return value.present() ? ds::Option{value.boundedNumber(bounds.minimum, bounds)} : ds::none;
  }

  ds::Option<double> optionalWholeValue(const lua::Value& value, Bounds<double> bounds) {
    optionalWholeNumber(value, bounds.minimum, bounds.maximum);
    return value.present() ? ds::Option{value.boundedNumber(bounds.minimum, bounds)} : ds::none;
  }

  ds::Option<bool> optionalBoolean(const lua::Value& value) {
    return value.present() ? ds::Option{value.boolean(false)} : ds::none;
  }

  void printableUiText(const lua::Value& source, std::string_view text, bool allow_tab) {
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_byte = 0x7f;

    validateUtf8(text);
    if (std::ranges::any_of(text, [allow_tab](unsigned char byte) {
          return (byte < first_printable && (!allow_tab || byte != '\t')) || byte == delete_byte;
        })) {
      source.fail("must contain printable text");
    }
  }

  tbc::val_a<std::string_view> fittedUiText(tbc::val_a<std::string_view> text, tbc::val_b<LimitReach> reach, tbc::mut_b<LimitNotices> limits) {
    if (text.size() > reach.value) {
      reach.requested = text.size();
      limits.add(reach);
    }

    return utf8Prefix(text, reach.value);
  }

  bool equalUiName(std::string_view left, std::string_view right) noexcept {
    return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(), [](char byte, char expected) {
      return (byte == '-' ? '_' : asciiLower(byte)) == expected;
    });
  }

  void uiIcon(const lua::Value& value) {
    constexpr ds::Array names{std::string_view{"sidebar_collapse"}, "sidebar_expand", "workspace_menu", "proxy_active", "cpu", "memory", "battery_empty", "battery_quarter", "battery_half", "battery_three_quarters", "battery_full", "provider_unknown", "provider_claude", "provider_codex", "provider_pi", "provider_cursor", "provider_opencode", "provider_antigravity", "app_terminal", "app_editor", "app_git", "agent_unknown", "agent_working_0", "agent_working_1", "agent_working_2", "agent_working_3", "agent_blocked", "agent_ready", "agent_done", "agent_failed", "close", "pane_fullscreen", "telar_mark"};
    const auto text = value.string();
    if (!std::ranges::any_of(names, [text](std::string_view name) {
          return equalUiName(text, name);
        })) {
      value.fail("names an unknown icon");
    }
  }

  void uiMark(const lua::Value& value) {
    static_cast<void>(value.string());
    optionalChoice(value, {"claude", "codex", "pi", "telar"});
  }

  void hexadecimalColor(const lua::Value& value) {
    constexpr std::size_t rgb_text_length = 7;

    const auto text = value.string();
    if (text.size() != rgb_text_length || text.front() != '#' || !std::ranges::all_of(text.substr(1), [](char byte) {
          return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f');
        })) {
      value.fail("must be an RGB hexadecimal color");
    }
  }

}

namespace telar::runtime {

  ProviderDescription describeProvider(AgentProvider provider) noexcept {
    switch (provider) {
    case AgentProvider::claude:
      return {.name = "claude", .display_name = "Claude Code", .placeholder = "New Claude Code session", .attachments = AgentAttachmentMarkers::stable_number, .process_names = {"claude", "claude-code"}};
    case AgentProvider::codex:
      return {.name = "codex", .display_name = "Codex", .placeholder = "New Codex session", .attachments = AgentAttachmentMarkers::ordered, .process_names = {"codex", {}}};
    case AgentProvider::pi:
      return {.name = "pi", .display_name = "Pi", .placeholder = "New Pi session", .attachments = AgentAttachmentMarkers::pasted_path, .process_names = {"pi", {}}};
    case AgentProvider::cursor:
      return {.name = "cursor", .display_name = "Cursor Agent", .placeholder = "New Cursor Agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {"cursor-agent", {}}};
    case AgentProvider::opencode:
      return {.name = "opencode", .display_name = "OpenCode", .placeholder = "New OpenCode session", .attachments = AgentAttachmentMarkers::none, .process_names = {"opencode", {}}};
    case AgentProvider::antigravity:
      return {.name = "antigravity", .display_name = "Antigravity", .placeholder = "New Antigravity session", .attachments = AgentAttachmentMarkers::none, .process_names = {"agy", {}}};
    case AgentProvider::unknown:
    case AgentProvider::last_custom:
      break;
    }

    // Unknown and custom providers, whose values fall between the named ones.
    return {.name = "", .display_name = "", .placeholder = "New agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {}};
  }

  AgentProvider builtinProviderFromExecutable(std::string_view name) noexcept {
    const auto stem = withoutExecutableSuffix(name);

    for (const auto provider : built_in_agent_providers) {
      for (const auto process : describeProvider(provider).process_names) {
        if (!process.empty() && asciiEqualIgnoreCase(stem, process)) {
          return provider;
        }
      }
    }

    return AgentProvider::unknown;
  }

  AgentProvider providerNamed(std::string_view name) noexcept {
    for (const auto provider : built_in_agent_providers) {
      if (describeProvider(provider).name == name) {
        return provider;
      }
    }

    return AgentProvider::unknown;
  }

}

namespace telar::runtime::config {

  IntegrationProvider IntegrationProvider::describe(AgentProvider provider) {
    switch (provider) {
    case AgentProvider::claude:
      return {.name = "claude", .environment = "CLAUDE_CONFIG_DIR", .home_directory = ".claude", .file = "settings.json", .events = claude_events, .worktree_events = claude_worktree_events, .timeout = "5"};
    case AgentProvider::codex:
      return {.name = "codex", .environment = "CODEX_HOME", .home_directory = ".codex", .file = "hooks.json", .events = codex_events, .timeout = "3", .launch_note = "Codex runs its hooks in its shared daemon, outside any pane, unless it starts with --no-daemon; launch it that way, for instance with `alias codex='codex --no-daemon'`"};
    case AgentProvider::cursor:
      return {.name = "cursor", .home_directory = ".cursor", .file = "hooks.json", .events = cursor_events, .timeout = "5", .flat_hooks = true};
    case AgentProvider::pi:
      return {.name = "pi", .environment = "PI_CODING_AGENT_DIR", .home_directory = ".pi/agent", .file = "extensions/telar.ts"};
    case AgentProvider::opencode:
      return {.name = "opencode", .environment = "XDG_CONFIG_HOME", .home_directory = ".config/opencode", .environment_suffix = "/opencode", .file = "plugins/telar.ts"};
    case AgentProvider::antigravity:
      return {.name = "antigravity", .home_directory = ".gemini/config", .file = "hooks.json", .events = antigravity_events, .flat_events = antigravity_flat_events, .timeout = "30", .hooks_key = "telar", .matcher = "*", .fail_open = true};
    case AgentProvider::unknown:
    case AgentProvider::last_custom:
      break;
    }

    throw std::invalid_argument{"Unknown integration provider"};
  }

  tbc::val_a<ds::String<Memory>> IntegrationProvider::root(tbc::mut_a<Memory> memory, const EnvironmentSource& source, bool legacy) const {
    ds::String<Memory> result{memory};

    if (environment != nullptr && !legacy) {
      result.assign(source.lookup(environment));
      if (!result.empty()) {
        result.append(environment_suffix);
        return result;
      }
    }

    result.assign(source.lookup("HOME"));
    if (result.empty()) {
      throw std::invalid_argument{"Home directory unavailable for integration"};
    }

    result.push('/');
    result.append(home_directory);
    return result;
  }

}
