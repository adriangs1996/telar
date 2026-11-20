module telar.config.core;

import std;
import telar.tbc;
import telar.sys.posix;
import telar.base.text.utf8;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime::config {

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
      std::fprintf(stderr, "telar config: limit reached, the excess was left out: %.*s: ", static_cast<int>(entry.name.size()), entry.name.data());
      const auto* separator = entry.noun.empty() ? "" : " ";

      if (entry.requested) {
        std::fprintf(stderr, "%llu%s%.*s; limit %llu\n", static_cast<unsigned long long>(*entry.requested), separator, static_cast<int>(entry.noun.size()), entry.noun.data(), static_cast<unsigned long long>(entry.value));
      } else if (entry.value == 0) {
        std::fputs("limit reached\n", stderr);
      } else {
        std::fprintf(stderr, "limit %llu%s%.*s reached\n", static_cast<unsigned long long>(entry.value), separator, static_cast<int>(entry.noun.size()), entry.noun.data());
      }
    }
  }

  void optionalChoice(const lua::Value& value, std::initializer_list<std::string_view> choices) {
    if (!value.present()) {
      return;
    }

    const auto text = value.string();
    if (std::find(choices.begin(), choices.end(), text) == choices.end()) {
      value.fail("is not a supported value");
    }
  }

  void optionalWholeNumber(const lua::Value& value, double minimum, double maximum) {
    const auto number = value.boundedNumber(minimum, minimum, maximum);
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
    return value.present() ? ds::Option{value.boundedNumber(bounds.minimum, bounds.minimum, bounds.maximum)} : ds::none;
  }

  ds::Option<double> optionalWholeValue(const lua::Value& value, Bounds<double> bounds) {
    optionalWholeNumber(value, bounds.minimum, bounds.maximum);
    return value.present() ? ds::Option{value.boundedNumber(bounds.minimum, bounds.minimum, bounds.maximum)} : ds::none;
  }

  ds::Option<bool> optionalBoolean(const lua::Value& value) {
    return value.present() ? ds::Option{value.boolean(false)} : ds::none;
  }

  void printableUiText(const lua::Value& source, std::string_view text, bool allow_tab) {
    validateUtf8(text);
    if (std::ranges::any_of(text, [allow_tab](unsigned char byte) {
          return (byte < 0x20 && !(allow_tab && byte == '\t')) || byte == 0x7f;
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
    constexpr std::string_view names[]{"sidebar_collapse", "sidebar_expand", "workspace_menu", "proxy_active", "cpu", "memory", "battery_empty", "battery_quarter", "battery_half", "battery_three_quarters", "battery_full", "provider_unknown", "provider_claude", "provider_codex", "provider_pi", "provider_cursor", "provider_opencode", "app_terminal", "app_editor", "app_git", "agent_unknown", "agent_working_0", "agent_working_1", "agent_working_2", "agent_working_3", "agent_blocked", "agent_ready", "agent_done", "agent_failed", "close", "pane_fullscreen", "telar_mark"};
    const auto text = value.string();
    if (!std::ranges::any_of(names, [text](std::string_view name) {
          return equalUiName(text, name);
        })) {
      value.fail("names an unknown icon");
    }
  }

  void uiMark(const lua::Value& value) {
    value.string();
    optionalChoice(value, {"claude", "codex", "pi", "telar"});
  }

  void hexadecimalColor(const lua::Value& value) {
    const auto text = value.string();
    if (text.size() != 7 || text.front() != '#' || !std::ranges::all_of(text.substr(1), [](char byte) {
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
    default:
      return {.name = "", .display_name = "", .placeholder = "New agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {}};
    }
  }

  AgentProvider builtinProviderFromExecutable(std::string_view name) noexcept {
    const auto stem = withoutExecutableSuffix(name);

    for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
      for (const auto process : describeProvider(provider).process_names) {
        if (!process.empty() && asciiEqualIgnoreCase(stem, process)) {
          return provider;
        }
      }
    }

    return AgentProvider::unknown;
  }

  AgentProvider providerNamed(std::string_view name) noexcept {
    for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
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
    default:
      throw std::invalid_argument{"Unknown integration provider"};
    }
  }

  tbc::val_a<ds::String<Memory>> IntegrationProvider::root(tbc::mut_a<Memory> memory, const EnvironmentSource& environment, bool legacy) const {
    ds::String<Memory> result{memory};

    if (this->environment != nullptr && !legacy) {
      result.assign(environment.lookup(this->environment));
      if (!result.empty()) {
        result.append(environment_suffix);
        return result;
      }
    }

    result.assign(environment.lookup("HOME"));
    if (result.empty()) {
      throw std::invalid_argument{"Home directory unavailable for integration"};
    }

    result.push('/');
    result.append(home_directory);
    return result;
  }

}
