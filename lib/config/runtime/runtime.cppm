module;
#include "tbc/view.hpp"
#include <cstdint>
#include <ghostty/vt/unicode.h>
#include <lua.h>

#include <limits.h>

#include <arpa/inet.h>

#include "telar_config/terminal/control/policy.hpp"

export module telar.config.runtime;

import std;
export import telar.config.core;
export import telar.plugins;
export import telar.platform.events;
import telar.base.diagnostics;
import telar.wire.vocabulary;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime::control {
  using telar::runtime::control::Access;
  using telar::runtime::control::ColorFormat;
  using telar::runtime::control::Policy;
}

// Interface: telar_config/agents/evidence.cppm
export {
  namespace telar::runtime {

    struct AgentSignal {
      AgentProvider provider = AgentProvider::unknown;
      AgentStatus status = AgentStatus::unknown;
      Byte confidence = 0;
      bool identity_confirmed = false;
      bool ready_confirmed = false;

      bool operator==(const AgentSignal&) const = default;
    };

    struct AgentEvidence {
      AgentProvider provider = AgentProvider::unknown;
      AgentStatus status = AgentStatus::unknown;
      AgentSource source = AgentSource::screen;
      Byte confidence = 0;
      ObservationTime observed;
      std::int64_t expires_at = 0;

      inline bool expired(std::int64_t now) const noexcept {
        return expires_at <= now;
      }

      inline static AgentEvidence process(AgentProvider provider, ObservationTime now) noexcept {
        return {provider, AgentStatus::ready, AgentSource::foreground_process, 100, now, std::numeric_limits<std::int64_t>::max()};
      }

      inline static AgentEvidence screen(AgentProvider provider, AgentSignal signal, ObservationTime now) noexcept {
        return {provider, signal.status, AgentSource::screen, signal.confidence, now, now.milliseconds + (signal.status == AgentStatus::working ? screen_working_expiry : settled_expiry).count()};
      }

      inline static AgentEvidence report(AgentProvider provider, AgentReportState state, ObservationTime now) noexcept {
        const bool working = state == AgentReportState::working || state == AgentReportState::waiting || state == AgentReportState::settling;
        const auto expiry = working ? (state == AgentReportState::settling ? screen_working_expiry : report_working_expiry) : settled_expiry;
        const auto status = working ? AgentStatus::working : state == AgentReportState::blocked ? AgentStatus::blocked
                                                                                                : AgentStatus::ready;

        return {provider, status, AgentSource::lifecycle_report, 100, now, now.milliseconds + expiry.count()};
      }

      static constexpr std::chrono::milliseconds screen_working_expiry{120'000};
      static constexpr std::chrono::milliseconds report_working_expiry{600'000};
      static constexpr std::chrono::milliseconds settled_expiry{1'800'000};
      static constexpr std::chrono::milliseconds renewal_margin{300'000};
    };

    inline bool completionRequiresSignal(AgentProvider provider) noexcept {
      return provider == AgentProvider::codex || provider == AgentProvider::pi || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
    }

  }
}

// Interface: telar_config/agents/manifest.cppm
export {
  namespace telar::runtime {

    inline bool containsInsensitive(std::string_view text, std::string_view phrase) noexcept {
      if (phrase.empty() || phrase.size() > text.size()) {
        return false;
      }

      for (std::size_t offset = 0; offset <= text.size() - phrase.size(); ++offset) {
        if (std::equal(phrase.begin(), phrase.end(), text.begin() + offset, [](char left, char right) {
              return asciiLower(left) == asciiLower(right);
            })) {
          return true;
        }
      }

      return false;
    }

    template <std::size_t Capacity, std::size_t TextCapacity>
    class ManifestTextList {
    public:
      inline void append(std::string_view text) {
        if (text.empty() || text.size() > TextCapacity || count_ == Capacity) {
          throw EncodingError{"Agent manifest list exceeds its bounds"};
        }

        entries_[count_++].assign(text);
      }

      inline bool matches(std::string_view text) const noexcept {
        return std::ranges::any_of(entries(), [&](const auto& phrase) {
          return containsInsensitive(text, phrase.view());
        });
      }

      inline std::span<const FixedText<TextCapacity>> entries() const noexcept {
        return std::span{entries_}.first(count_);
      }

    private:
      std::array<FixedText<TextCapacity>, Capacity> entries_;
      std::size_t count_ = 0;
    };

    enum class AgentInterruptKey {
      none,
      escape,
      escape_twice,
      control_c,
    };

    struct AgentCommandTool {
      FixedText<64> tool;
      FixedText<32> field;
    };

    struct AgentManifest {
      inline void addCommandTool(std::string_view name, std::string_view field) {
        if (name.empty() || name.size() > 64 || field.empty() || field.size() > 32 || tool_count == command_tools.size()) {
          throw EncodingError{"Invalid agent command tool"};
        }

        command_tools[tool_count].tool.assign(name);
        command_tools[tool_count].field.assign(field);
        ++tool_count;
      }

      inline std::string_view commandField(std::string_view tool) const noexcept {
        for (const auto& mapping : std::span{command_tools}.first(tool_count)) {
          if (mapping.tool.view() == tool) {
            return mapping.field.view();
          }
        }

        return {};
      }

      inline std::string_view displayName() const noexcept {
        return display_name.view().empty() ? name.view() : display_name.view();
      }

      // The manifest's own placeholder, or one built in the caller's storage.
      inline tbc::view<std::string_view, tbc::lt::a> placeholderTitle(tbc::view<FixedText<96>&, tbc::lt::a> storage) const {
        if (!placeholder.view().empty()) {
          return placeholder.view();
        }

        std::array<char, 96> bytes{};
        const auto display = displayName();

        std::memcpy(bytes.data(), "New ", 4);
        std::memcpy(bytes.data() + 4, display.data(), display.size());
        std::memcpy(bytes.data() + 4 + display.size(), " session", 8);
        storage.assign({bytes.data(), display.size() + 12});
        return storage.view();
      }

      AgentProvider provider = AgentProvider::unknown;
      tbc::view<FixedText<32>, tbc::lt::a> name;
      tbc::view<FixedText<32>, tbc::lt::a> display_name;
      tbc::view<FixedText<96>, tbc::lt::a> placeholder;
      FixedText<8> icon;
      AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
      AgentInterruptKey interrupt = AgentInterruptKey::none;
      ManifestTextList<8, 128> process_names;
      ManifestTextList<8, 128> process_paths;
      ManifestTextList<16, 64> brand;
      ManifestTextList<16, 64> identity;
      ManifestTextList<16, 64> working;
      ManifestTextList<16, 64> blocked;
      ManifestTextList<16, 64> ready_prompt;
      std::array<AgentCommandTool, 8> command_tools;
      std::size_t tool_count = 0;
    };

    class AgentManifests {
    public:
      inline AgentManifest& add(std::string_view name) {
        auto* manifest = tryAdd(name);
        if (manifest == nullptr) {
          throw EncodingError{"Too many agent manifests"};
        }

        return *manifest;
      }

      inline AgentManifest* tryAdd(std::string_view name) {
        if (name.empty() || name.size() > 32 || !std::ranges::all_of(name, [](char byte) {
              return (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.';
            })) {
          throw EncodingError{"Invalid agent manifest name"};
        }

        const auto builtin = providerNamed(name);

        for (auto& entry : std::span{entries_}.first(count_)) {
          if (entry.name.view() == name) {
            if (builtin == AgentProvider::unknown) {
              throw EncodingError{"Duplicate agent manifest"};
            }

            return &entry;
          }
        }

        if (count_ >= entries_.size() || (builtin == AgentProvider::unknown && custom_count_ >= maximum_custom_agents)) {
          return nullptr;
        }

        auto& entry = entries_[count_++];

        entry.provider = builtin == AgentProvider::unknown ? static_cast<AgentProvider>(first_custom_provider + custom_count_++) : builtin;
        entry.name.assign(name);
        return &entry;
      }

      inline const AgentManifest* find(AgentProvider provider) const noexcept {
        for (const auto& entry : entries()) {
          if (entry.provider == provider) {
            return &entry;
          }
        }

        return nullptr;
      }

      inline AgentProvider named(std::string_view name) const noexcept {
        for (const auto& entry : entries()) {
          if (entry.name.view() == name) {
            return entry.provider;
          }
        }

        return AgentProvider::unknown;
      }

      inline AgentProvider fromExecutable(std::string_view name) const noexcept {
        const auto stem = withoutExecutableSuffix(name);

        for (const auto& entry : entries()) {
          for (const auto& candidate : entry.process_names.entries()) {
            if (asciiEqualIgnoreCase(stem, candidate.view())) {
              return entry.provider;
            }
          }
        }

        return AgentProvider::unknown;
      }

      inline AgentProvider fromPath(std::string_view path) const noexcept {
        for (const auto& entry : entries()) {
          if (entry.process_paths.matches(path)) {
            return entry.provider;
          }
        }

        return AgentProvider::unknown;
      }

      inline std::optional<AgentSignal> detect(std::string_view text) const noexcept {
        for (const auto& entry : entries()) {
          if (entry.blocked.matches(text)) {
            return AgentSignal{inferProvider(text), AgentStatus::blocked, 88};
          }
        }

        for (const auto& entry : entries()) {
          if (entry.working.matches(text)) {
            return AgentSignal{inferProvider(text), AgentStatus::working, 78};
          }
        }

        for (const auto& entry : entries()) {
          if (entry.ready_prompt.matches(text)) {
            return AgentSignal{entry.provider, AgentStatus::ready, 94, true, true};
          }
        }

        for (const auto& entry : entries()) {
          if (entry.identity.matches(text)) {
            return AgentSignal{entry.provider, AgentStatus::ready, 90, true, false};
          }
        }

        return std::nullopt;
      }

      inline std::span<const AgentManifest> entries() const noexcept {
        return std::span{entries_}.first(count_);
      }

    private:
      inline AgentProvider inferProvider(std::string_view text) const noexcept {
        for (const auto& entry : entries()) {
          if (entry.brand.matches(text)) {
            return entry.provider;
          }
        }

        return AgentProvider::unknown;
      }

      static constexpr Byte first_custom_provider = first_custom_agent_provider;
      static constexpr Byte maximum_custom_agents = max_agent_provider_index - first_custom_provider + 1;
      std::array<AgentManifest, 32> entries_;
      std::size_t count_ = 0;
      Byte custom_count_ = 0;
    };

  }
}

// Interface: telar_config/agent_reader.cppm
namespace telar::runtime::config {

  class AgentReader {
  public:
    // Fills the manifests and tells the notices about limits it reaches, region `a`.
    inline explicit AgentReader(tbc::view<AgentManifests&, tbc::lt::a> manifests, tbc::view<LimitNotices&, tbc::lt::a> limits)
        : manifests_(manifests),
          limits_(limits) {}

    inline void read(const lua::Value& agents) {
      if (!agents.present()) {
        return;
      }

      const auto count = agents.arraySize();
      std::size_t dropped = 0;

      for (std::size_t position = 1; position <= count; ++position) {
        const auto entry = agents.element(static_cast<lua_Integer>(position));

        entry.onlyFields({"name", "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt", "display_name", "placeholder", "icon", "attachments", "command_tools"});
        auto* manifest = manifests_.tryAdd(entry.field("name").string());
        if (manifest == nullptr) {
          ++dropped;
          continue;
        }

        paths(entry.field("process_names"), manifest->process_names);
        paths(entry.field("process_paths"), manifest->process_paths);
        phrases(entry.field("brand"), manifest->brand);
        phrases(entry.field("identity"), manifest->identity);
        phrases(entry.field("working"), manifest->working);
        phrases(entry.field("blocked"), manifest->blocked);
        phrases(entry.field("ready_prompt"), manifest->ready_prompt);
        commandTools(entry.field("command_tools"), *manifest);
        presentation(entry, *manifest);
      }

      if (dropped != 0) {
        limits_.add({"agent_manifest.max_custom_agents", "agents", 27, 27 + dropped, {}});
      }
    }

  private:
    inline static tbc::view<std::string_view, tbc::lt::a> printable(const lua::Value& value) {
      const auto text = value.string();

      validateUtf8(text);
      if (text.empty() || std::ranges::any_of(text, [](unsigned char byte) {
            return byte < 0x20 || byte == 0x7f;
          })) {
        value.fail("must be a printable string");
      }

      return text;
    }

    template <std::size_t Capacity, std::size_t TextCapacity>
    inline void list(const lua::Value& value, ManifestTextList<Capacity, TextCapacity>& destination, tbc::view<LimitReach, tbc::lt::a> entries_limit, tbc::view<LimitReach, tbc::lt::a> bytes_limit) {
      if (!value.present()) {
        return;
      }

      const auto count = value.arraySize();

      for (std::size_t position = 1; position <= count; ++position) {
        const auto text = printable(value.element(static_cast<lua_Integer>(position)));
        if (text.size() > TextCapacity) {
          bytes_limit.requested = text.size();
          limits_.add(bytes_limit);
        } else if (destination.entries().size() == Capacity) {
          entries_limit.requested = Capacity + count - position + 1;
          limits_.add(entries_limit);
          return;
        } else {
          destination.append(text);
        }
      }
    }

    inline void paths(const lua::Value& value, ManifestTextList<8, 128>& destination) {
      list(value, destination, {"agent_manifest.max_paths", "entries", 8, {}, {}}, {"agent_manifest.max_path_bytes", "bytes", 128, {}, {}});
    }

    inline void phrases(const lua::Value& value, ManifestTextList<16, 64>& destination) {
      list(value, destination, {"agent_manifest.max_phrases", "phrases", 16, {}, {}}, {"agent_manifest.max_phrase_bytes", "bytes", 64, {}, {}});
    }

    inline void commandTools(const lua::Value& value, AgentManifest& manifest) {
      if (!value.present()) {
        return;
      }

      const auto count = value.arraySize();

      for (std::size_t position = 1; position <= count; ++position) {
        const auto mapping = value.element(static_cast<lua_Integer>(position));

        mapping.onlyFields({"tool", "field"});
        const auto tool = mapping.field("tool").string();
        const auto field = mapping.field("field").string();
        if (tool.empty() || field.empty()) {
          mapping.fail("requires nonempty tool and field strings");
        }

        if (tool.size() > 64 || field.size() > 32) {
          if (tool.size() > 64) {
            limits_.add({"agent_manifest.max_tool_name_bytes", "bytes", 64, tool.size(), {}});
          }

          if (field.size() > 32) {
            limits_.add({"agent_manifest.max_command_field_bytes", "bytes", 32, field.size(), {}});
          }
        } else if (manifest.tool_count == manifest.command_tools.size()) {
          limits_.add({"agent_manifest.max_command_tools", "command tools", 8, 8 + count - position + 1, {}});
          return;
        } else {
          manifest.addCommandTool(tool, field);
        }
      }
    }

    template <std::size_t Capacity>
    inline static void text(const lua::Value& value, FixedText<Capacity>& destination) {
      if (value.present()) {
        destination.assign(printable(value));
      }
    }

    inline static unsigned iconWidth(std::string_view text) noexcept {
      std::array<std::uint32_t, 8> codepoints;
      std::size_t count = 0;

      for (std::size_t offset = 0; offset < text.size();) {
        const auto lead = static_cast<unsigned char>(text[offset++]);
        const unsigned continuation = lead < 0x80 ? 0 : lead < 0xe0 ? 1
                                                    : lead < 0xf0   ? 2
                                                                    : 3;
        std::uint32_t codepoint = continuation == 0 ? lead : lead & (0x7f >> continuation);

        for (unsigned index = 0; index < continuation; ++index) {
          codepoint = (codepoint << 6) | (static_cast<unsigned char>(text[offset++]) & 0x3f);
        }

        codepoints[count++] = codepoint;
      }

      unsigned width = 0;

      for (std::size_t offset = 0; offset < count;) {
        std::uint8_t cluster_width = 0;

        offset += ghostty_unicode_grapheme_width(codepoints.data() + offset, count - offset, &cluster_width);
        width += std::max<unsigned>(1, cluster_width);
      }

      return width;
    }

    inline static void presentation(const lua::Value& entry, AgentManifest& manifest) {
      text(entry.field("display_name"), manifest.display_name);
      text(entry.field("placeholder"), manifest.placeholder);
      const auto icon = entry.field("icon");
      if (icon.present()) {
        const auto value = printable(icon);
        if (value.size() > 8 || iconWidth(value) != 1) {
          icon.fail("must fit in eight bytes and exactly one cell");
        }

        manifest.icon.assign(value);
      }

      const auto attachments = entry.field("attachments");
      if (!attachments.present()) {
        return;
      }

      const auto policy = printable(attachments);

      for (const auto& [name, kind] : std::array<std::pair<std::string_view, AgentAttachmentMarkers>, 4>{{{"none", AgentAttachmentMarkers::none}, {"ordered", AgentAttachmentMarkers::ordered}, {"stable_number", AgentAttachmentMarkers::stable_number}, {"pasted_path", AgentAttachmentMarkers::pasted_path}}}) {
        if (name == policy) {
          manifest.attachments = kind;
          return;
        }
      }

      attachments.fail("must be none, ordered, stable_number or pasted_path");
    }

    tbc::view<AgentManifests&, tbc::lt::a> manifests_;
    tbc::view<LimitNotices&, tbc::lt::a> limits_;
  };

}

// Interface: telar_config/agents/builtin_manifests.cppm
export {
  namespace telar::runtime {

    inline AgentManifests makeBuiltinManifests() {
      AgentManifests table;

      for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
        const auto description = describeProvider(provider);
        auto& manifest = table.add(description.name);

        manifest.display_name.assign(description.display_name);
        manifest.attachments = description.attachments;
        manifest.interrupt = AgentInterruptKey::escape;
        for (const auto process : description.process_names) {
          if (!process.empty()) {
            manifest.process_names.append(process);
          }
        }
      }

      auto& claude = table.add("claude");

      claude.process_paths.append("/@anthropic-ai/claude-code/");
      claude.process_paths.append("\\@anthropic-ai\\claude-code\\");
      claude.brand.append("claude");
      claude.identity.append("claude code");
      claude.addCommandTool("Bash", "command");
      claude.interrupt = AgentInterruptKey::control_c;
      for (const auto phrase : {"press enter to confirm", "enter to submit answer", "enter to select", "allow command?", "[y/n]", "do you want to proceed?", "waiting for permission", "yes, and don't ask again"}) {
        claude.blocked.append(phrase);
      }

      for (const auto phrase : {"esc to interrupt", "working (", "waiting for background agents", "tasks still running", "background shells"}) {
        claude.working.append(phrase);
      }

      auto& codex = table.add("codex");

      codex.process_paths.append("/@openai/codex/");
      codex.process_paths.append("\\@openai\\codex\\");
      codex.brand.append("codex");
      codex.ready_prompt.append("ask codex to do anything");
      codex.addCommandTool("Bash", "command");
      codex.addCommandTool("exec_command", "cmd");
      codex.addCommandTool("shell", "command");

      auto& pi = table.add("pi");

      pi.process_paths.append("/@earendil-works/pi-coding-agent/");
      pi.process_paths.append("\\@earendil-works\\pi-coding-agent\\");
      pi.process_paths.append("/@mariozechner/pi-coding-agent/");
      pi.process_paths.append("\\@mariozechner\\pi-coding-agent\\");
      pi.addCommandTool("bash", "command");

      auto& cursor = table.add("cursor");

      cursor.process_paths.append("/cursor-agent/versions/");
      cursor.addCommandTool("Shell", "command");
      for (const auto phrase : {"not in allowlist:", "skip & tell the agent what to do instead", "yes, build locally", "do you trust the contents of this directory?"}) {
        cursor.blocked.append(phrase);
      }

      auto& opencode = table.add("opencode");

      opencode.interrupt = AgentInterruptKey::escape_twice;
      opencode.addCommandTool("bash", "command");
      return table;
    }

    inline const AgentManifests builtin_manifests = makeBuiltinManifests();

  }
}

// Interface: telar_config/control_reader.cppm
export {
  namespace telar::runtime::config {

    inline void readControlPolicy(const lua::Value& table, control::Policy& policy) {
      if (!table.present()) {
        return;
      }

      table.onlyFields({"clipboard_read", "clipboard_write", "title_report", "checksum_report", "color_format", "answerback"});
      const auto access = [](const lua::Value& value, control::Access fallback) {
        if (!value.present()) {
          return fallback;
        }

        const auto text = value.string();
        if (text == "deny") {
          return control::Access::deny;
        }

        if (text == "ask") {
          return control::Access::ask;
        }

        if (text == "allow") {
          return control::Access::allow;
        }

        value.fail("must be deny, ask or allow");
      };

      policy.clipboard_read = access(table.field("clipboard_read"), policy.clipboard_read);
      policy.clipboard_write = access(table.field("clipboard_write"), policy.clipboard_write);
      policy.title_report = table.field("title_report").boolean(policy.title_report);
      policy.checksum_report = table.field("checksum_report").boolean(policy.checksum_report);

      const auto format = table.field("color_format");
      if (format.present()) {
        const auto text = format.string();
        if (text == "none") {
          policy.color_format = control::ColorFormat::none;
        } else if (text == "8-bit") {
          policy.color_format = control::ColorFormat::eight_bit;
        } else if (text == "16-bit") {
          policy.color_format = control::ColorFormat::sixteen_bit;
        } else {
          format.fail("must be none, 8-bit or 16-bit");
        }
      }

      const auto answerback = table.field("answerback");
      if (answerback.present()) {
        const auto text = answerback.string();
        if (text.size() > policy.answerback.size()) {
          answerback.fail("exceeds 1024 bytes");
        }

        std::copy(text.begin(), text.end(), policy.answerback.begin());
        policy.answerback_length = static_cast<std::uint16_t>(text.size());
      }
    }

  }
}

// Interface: telar_config/history/filters.cppm
export {
  namespace telar::runtime {

    class HistoryPatternList {
    public:
      inline void append(std::string_view pattern) {
        if (pattern.empty() || pattern.find('\0') != std::string_view::npos) {
          throw std::invalid_argument{"History filter patterns must not be empty or contain NUL"};
        }

        if (count_ == patterns_.size()) {
          throw std::length_error{"History filter exceeds 64 patterns"};
        }

        patterns_[count_].assign(pattern);
        ++count_;
      }

      inline bool matches(std::string_view text) const noexcept {
        for (const auto& pattern : std::span{patterns_}.first(count_)) {
          if (text.contains(pattern.view())) {
            return true;
          }
        }

        return false;
      }

    private:
      std::array<FixedText<256>, 64> patterns_;
      std::size_t count_ = 0;
    };

    class HistoryFilters {
    public:
      inline bool allowsPane(std::string_view command, std::string_view directory) const noexcept {
        return !command.empty() && command.front() != ' ' && allowsAgent(command, directory);
      }

      inline bool allowsAgent(std::string_view command, std::string_view directory, bool redact = true) const noexcept {
        return !command.empty() && !(redact && secrets && looksLikeSecret(command)) && !commands.matches(command) && !directories.matches(directory);
      }

      inline static bool looksLikeSecret(std::string_view command) noexcept {
        constexpr std::array tokens{
            TokenRule{"AKIA", 16},
            TokenRule{"ghp_", 20},
            TokenRule{"gho_", 20},
            TokenRule{"github_pat_", 20},
            TokenRule{"npm_", 30},
            TokenRule{"sk_live_", 12},
            TokenRule{"rk_live_", 12},
            TokenRule{"xoxb-", 10},
            TokenRule{"xoxp-", 10},
        };

        for (const auto& rule : tokens) {
          if (matchesToken(command, rule)) {
            return true;
          }
        }

        if (command.contains("hooks.slack.com/services/") || command.contains("-----BEGIN")) {
          return true;
        }

        constexpr std::array<std::string_view, 5> assignments{"password=", "passwd=", "token=", "secret=", "api_key="};

        for (const auto marker : assignments) {
          if (matchesAssignment(command, marker)) {
            return true;
          }
        }

        return false;
      }

      bool secrets = true;
      HistoryPatternList commands;
      HistoryPatternList directories;

    private:
      struct TokenRule {
        std::string_view marker;
        std::size_t minimum_length;
      };

      inline static bool tokenByte(unsigned char byte) noexcept {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
      }

      inline static bool matchesToken(std::string_view command, const TokenRule& rule) noexcept {
        for (std::size_t offset = 0; offset < command.size();) {
          const auto found = command.find(rule.marker, offset);
          if (found == std::string_view::npos) {
            return false;
          }

          const auto suffix = command.substr(found + rule.marker.size());
          std::size_t length = 0;

          while (length < suffix.size() && tokenByte(suffix[length])) {
            ++length;
          }

          if (length >= rule.minimum_length) {
            return true;
          }

          offset = found + 1;
        }

        return false;
      }

      inline static bool matchesAssignment(std::string_view command, std::string_view marker) noexcept {
        for (std::size_t offset = 0; offset + marker.size() < command.size(); ++offset) {
          bool matches = true;

          for (std::size_t index = 0; index < marker.size(); ++index) {
            const unsigned char byte = command[offset + index];
            const auto lower = byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
            if (lower != marker[index]) {
              matches = false;
              break;
            }
          }

          const auto value = command[offset + marker.size()];
          if (matches && value != ' ' && value != '"' && value != '\'') {
            return true;
          }
        }

        return false;
      }
    };

    inline const HistoryFilters default_history_filters{};

  }
}

// Interface: telar_config/proxy/capture_limits.cppm
export {
  namespace telar::runtime {

    struct ProxyCaptureLimits {
      static constexpr std::size_t mebibyte = 1024 * 1024;
      static constexpr std::size_t maximum_exchange_bytes = 64 * mebibyte;
      static constexpr std::size_t maximum_total_bytes = 1024 * mebibyte;
      static constexpr auto maximum_join_timeout = std::chrono::hours{1};

      std::size_t part_bytes = 16 * mebibyte;
      std::size_t exchange_bytes = 32 * mebibyte;
      std::size_t total_bytes = 128 * mebibyte;
      std::chrono::milliseconds join_timeout{std::chrono::minutes{15}};
      bool enabled = false;

      inline bool valid() const noexcept {
        return part_bytes != 0 && exchange_bytes >= 2 && total_bytes != 0 && part_bytes <= exchange_bytes && exchange_bytes <= total_bytes && exchange_bytes <= maximum_exchange_bytes && total_bytes <= maximum_total_bytes && join_timeout.count() > 0 && join_timeout <= maximum_join_timeout;
      }
    };

  }
}

// Interface: telar_config/proxy/host_policy.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class ProxyHostPolicy {
    public:
      static constexpr std::size_t maximum_hosts = 256;
      static constexpr std::size_t maximum_hostname_bytes = ProxyHostname::maximum_bytes;

      inline explicit ProxyHostPolicy(Memory& memory)
          : patterns_(AllocatorRef<String<Memory>, Memory>{memory}) {}

      inline static bool validPattern(std::string_view pattern) noexcept {
        return ProxyHostname::validPattern(pattern);
      }

      inline bool append(std::string_view pattern) {
        if (patterns_.size() == maximum_hosts || !validPattern(pattern)) {
          return false;
        }

        std::array<char, INET6_ADDRSTRLEN> numeric{};

        if (const auto address = ProxyHostname::ipv6(pattern)) {
          ::inet_ntop(AF_INET6, &*address, numeric.data(), numeric.size());
          pattern = numeric.data();
        }

        patterns_.emplace_back(pattern, AllocatorRef<char, Memory>{patterns_.get_allocator().memory()});
        std::ranges::transform(patterns_.back(), patterns_.back().begin(), asciiLower);
        return true;
      }

      inline void finish() {
        std::ranges::sort(patterns_);
        const auto duplicates = std::ranges::unique(patterns_);

        patterns_.erase(duplicates.begin(), duplicates.end());
      }

      inline void clear() noexcept {
        patterns_.clear();
      }

      inline bool contains(std::string_view hostname) const noexcept {
        if (hostname.empty() || patterns_.empty()) {
          return false;
        }

        if (patterns_.front() == "*") {
          return true;
        }

        if (hostname.size() > maximum_hostname_bytes) {
          return false;
        }

        if (const auto address = ProxyHostname::ipv6(hostname)) {
          std::array<char, INET6_ADDRSTRLEN> numeric{};

          ::inet_ntop(AF_INET6, &*address, numeric.data(), numeric.size());
          return find(numeric.data());
        }

        std::array<char, maximum_hostname_bytes + wildcard_prefix.size()> canonical;

        std::ranges::transform(hostname, canonical.begin() + wildcard_prefix.size(), asciiLower);
        const std::string_view exact{canonical.data() + wildcard_prefix.size(), hostname.size()};
        if (find(exact)) {
          return true;
        }

        for (auto dot = hostname.find('.'); dot != std::string_view::npos; dot = hostname.find('.', dot + 1)) {
          const auto start = dot + 1;

          std::ranges::copy(wildcard_prefix, canonical.data() + start);
          if (find({canonical.data() + start, hostname.size() - start + wildcard_prefix.size()})) {
            return true;
          }
        }

        return false;
      }

      inline std::span<const String<Memory>> patterns() const noexcept {
        return patterns_;
      }

    private:
      inline bool find(std::string_view pattern) const noexcept {
        const auto found = std::lower_bound(patterns_.begin(), patterns_.end(), pattern, [](const auto& entry, std::string_view value) {
          return std::string_view{entry} < value;
        });

        return found != patterns_.end() && *found == pattern;
      }

      static constexpr std::string_view wildcard_prefix = "*.";
      Vector<String<Memory>, Memory> patterns_;
    };

  }
}

// Interface: telar_config/proxy/options.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    struct ProxyOptions {
      inline explicit ProxyOptions(Memory& memory)
          : authority_directory(AllocatorRef<char, Memory>{memory}),
            intercept_hosts(memory) {}

      String<Memory> authority_directory;
      ProxyHostPolicy<Memory> intercept_hosts;
      ProxyCaptureLimits capture;
      bool enabled = false;
      bool anonymous_tunnels = false;
      bool pane_https_proxy = true;
      bool network_capture = false;
      bool network_control = false;
      bool transparent_redirect = false;
      bool transparent_tls = false;
      bool stream_interception = false;
    };

  }
}

// Interface: telar_config/proxy_reader.cppm
export {
  namespace telar::runtime::config {

    template <Allocator Memory>
    class ProxyReader {
    public:
      inline static void read(const lua::Value& table, ProxyOptions<Memory>& values) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"enabled", "anonymous_tunnels", "pane_https_proxy", "ca_dir", "intercept_hosts", "capture", "network_capture", "network_control", "transparent_redirect", "transparent_tls", "stream_interception"});
        values.enabled = table.field("enabled").boolean(values.enabled);
        values.anonymous_tunnels = table.field("anonymous_tunnels").boolean(values.anonymous_tunnels);
        values.pane_https_proxy = table.field("pane_https_proxy").boolean(values.pane_https_proxy);
        values.network_capture = table.field("network_capture").boolean(values.network_capture);
        values.network_control = table.field("network_control").boolean(values.network_control);
        if (values.network_control && !values.network_capture) {
          table.fail("network_control requires network_capture");
        }

        values.transparent_redirect = table.field("transparent_redirect").boolean(values.transparent_redirect);
        values.transparent_tls = table.field("transparent_tls").boolean(values.transparent_tls);
        values.stream_interception = table.field("stream_interception").boolean(values.stream_interception);
        if (values.transparent_tls && !values.transparent_redirect) {
          table.fail("transparent_tls requires transparent_redirect");
        }

        if (values.stream_interception && (!values.enabled || !values.network_capture)) {
          table.fail("stream_interception requires enabled and network_capture");
        }

        if (values.transparent_redirect && !values.enabled) {
          table.fail("transparent_redirect requires the proxy to be enabled");
        }

        capture(table.field("capture"), values.capture);
        const auto directory = table.field("ca_dir");
        if (directory.present()) {
          const auto text = directory.string();
          if (text.empty() || text.size() > maximum_path_bytes || text.contains('\0')) {
            directory.fail("is invalid");
          }

          values.authority_directory = text;
        }

        const auto hosts = table.field("intercept_hosts");
        if (!hosts.present()) {
          return;
        }

        const auto count = hosts.arraySize();
        if (count > ProxyHostPolicy<Memory>::maximum_hosts) {
          hosts.fail("exceeds 256 entries");
        }

        values.intercept_hosts.clear();
        for (std::size_t index = 1; index <= count; ++index) {
          const auto host = hosts.element(static_cast<lua_Integer>(index));
          if (!values.intercept_hosts.append(host.string())) {
            host.fail("is not a valid hostname");
          }
        }

        values.intercept_hosts.finish();
      }

    private:
      inline static std::size_t positive(const lua::Value& field, std::size_t fallback) {
        return field.boundedInteger(fallback, 1, SIZE_MAX);
      }

      inline static void capture(const lua::Value& table, ProxyCaptureLimits& limits) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"enabled", "max_part_bytes", "max_exchange_bytes", "max_total_bytes", "join_timeout_ms"});
        limits.enabled = table.field("enabled").boolean(limits.enabled);
        limits.part_bytes = positive(table.field("max_part_bytes"), limits.part_bytes);
        limits.exchange_bytes = positive(table.field("max_exchange_bytes"), limits.exchange_bytes);
        limits.total_bytes = positive(table.field("max_total_bytes"), limits.total_bytes);
        const auto timeout = positive(table.field("join_timeout_ms"), static_cast<std::size_t>(limits.join_timeout.count()));
        if (timeout > static_cast<std::size_t>(std::chrono::duration_cast<std::chrono::milliseconds>(ProxyCaptureLimits::maximum_join_timeout).count())) {
          table.field("join_timeout_ms").fail("exceeds its 3600000 ms ceiling");
        }

        limits.join_timeout = std::chrono::milliseconds{timeout};

        if (limits.exchange_bytes < 2 || limits.part_bytes > limits.exchange_bytes || limits.exchange_bytes > limits.total_bytes) {
          table.fail("byte limits must satisfy part <= exchange <= total");
        }

        if (limits.exchange_bytes > ProxyCaptureLimits::maximum_exchange_bytes) {
          table.field("max_exchange_bytes").fail("exceeds its 67108864-byte ceiling");
        }

        if (limits.total_bytes > ProxyCaptureLimits::maximum_total_bytes) {
          table.field("max_total_bytes").fail("exceeds its 1073741824-byte ceiling");
        }
      }

      static constexpr std::size_t maximum_path_bytes = 1024;
    };

  }
}

// Interface: telar_config/runtime_values.cppm
export {
  namespace telar::runtime::config {

    template <Allocator Memory>
    struct CommandValues {
      static constexpr std::size_t maximum_arguments = 32;

      // The arguments as views into this value.
      struct Views {
        std::array<std::string_view, maximum_arguments> words{};
        std::size_t count = 0;

        [[nodiscard]] inline std::span<const std::string_view> span() const noexcept {
          return std::span{words}.first(count);
        }
      };

      inline explicit CommandValues(Memory& memory)
          : arguments(AllocatorRef<String<Memory>, Memory>{memory}) {}

      [[nodiscard]] inline Views views() const noexcept {
        Views views;

        for (const auto& argument : arguments) {
          views.words[views.count++] = argument;
        }

        return views;
      }

      Vector<String<Memory>, Memory> arguments;
      std::chrono::milliseconds timeout{15'000};
      std::chrono::milliseconds idle_timeout{300'000};
    };

    template <Allocator Memory>
    struct RuntimeValues {
      inline explicit RuntimeValues(Memory& memory)
          : history_path(AllocatorRef<char, Memory>{memory}),
            session_path(AllocatorRef<char, Memory>{memory}),
            engine(memory),
            descriptions(memory),
            proxy(memory) {}

      String<Memory> history_path;
      String<Memory> session_path;
      HistoryFilters history_filters;
      CommandValues<Memory> engine;
      CommandValues<Memory> descriptions;
      ProxyOptions<Memory> proxy;
      plugins::Specifications plugins;
      FixedText<PATH_MAX> configuration_directory;
      AgentManifests manifests = builtin_manifests;
      LimitNotices limits;
      GraphicsLimits graphics;
      control::Policy control_policy{};
      bool capture_output = false;
      bool persist_session = true;
      bool resume_agents = true;
      bool shell_integration = true;
      bool ssh_integration = true;
    };

    template <Allocator Memory>
    RuntimeValues(Memory& memory) -> RuntimeValues<Memory>;

  }
}

// Interface: telar_config/runtime_reader.cppm
export {
  namespace telar::runtime::config {

    template <Allocator Memory>
    class RuntimeReader {
    public:
      inline explicit RuntimeReader(RuntimeValues<Memory>& values)
          : values_(values) {}

      inline void read(const lua::Value& runtime) {
        if (!runtime.present()) {
          return;
        }

        runtime.onlyFields({"history", "session", "engine", "agent_descriptions", "graphics", "proxy", "agents", "control_queries", "shell_integration", "ssh_integration"});
        values_.shell_integration = runtime.field("shell_integration").boolean(values_.shell_integration);
        values_.ssh_integration = runtime.field("ssh_integration").boolean(values_.ssh_integration);
        history(runtime.field("history"));
        session(runtime.field("session"));
        helper(runtime.field("engine"), values_.engine, true);
        helper(runtime.field("agent_descriptions"), values_.descriptions, false);
        AgentReader{values_.manifests, values_.limits}.read(runtime.field("agents"));
        graphics(runtime.field("graphics"));
        readControlPolicy(runtime.field("control_queries"), values_.control_policy);
        ProxyReader<Memory>::read(runtime.field("proxy"), values_.proxy);
      }

    private:
      inline void graphics(const lua::Value& table) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"pane_mib", "global_mib"});
        values_.graphics.pane_bytes = table.field("pane_mib").boundedInteger(values_.graphics.pane_bytes / GraphicsLimits::mebibyte, 2, 256) * GraphicsLimits::mebibyte;
        values_.graphics.global_bytes = table.field("global_mib").boundedInteger(values_.graphics.global_bytes / GraphicsLimits::mebibyte, 2, 512) * GraphicsLimits::mebibyte;
        if (values_.graphics.global_bytes < values_.graphics.pane_bytes) {
          table.fail("global memory must cover the pane memory limit");
        }
      }

      inline static void path(const lua::Value& field, String<Memory>& destination) {
        if (!field.present()) {
          return;
        }

        const auto text = field.string();
        if (text.empty() || text.size() > 1024 || text.contains('\0')) {
          field.fail("is not a valid path");
        }

        destination = text;
      }

      inline static void patterns(const lua::Value& field, HistoryPatternList& destination) {
        if (!field.present()) {
          return;
        }

        const auto count = field.arraySize();

        for (std::size_t index = 1; index <= count; ++index) {
          destination.append(field.element(static_cast<lua_Integer>(index)).string());
        }
      }

      inline void history(const lua::Value& table) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"path", "secrets_filter", "command_filters", "cwd_filters", "output"});
        path(table.field("path"), values_.history_path);
        values_.history_filters.secrets = table.field("secrets_filter").boolean(values_.history_filters.secrets);
        patterns(table.field("command_filters"), values_.history_filters.commands);
        patterns(table.field("cwd_filters"), values_.history_filters.directories);
        const auto output = table.field("output");
        if (output.present()) {
          const auto mode = output.string();
          if (mode != "off" && mode != "bounded") {
            output.fail("must be off or bounded");
          }

          values_.capture_output = mode == "bounded";
        }
      }

      inline void session(const lua::Value& table) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"path", "persist", "resume_agents"});
        path(table.field("path"), values_.session_path);
        values_.persist_session = table.field("persist").boolean(values_.persist_session);
        values_.resume_agents = table.field("resume_agents").boolean(values_.resume_agents);
      }

      inline static void helper(const lua::Value& table, CommandValues<Memory>& destination, bool engine) {
        if (!table.present()) {
          return;
        }

        if (engine) {
          table.onlyFields({"command", "timeout_ms", "idle_timeout_ms"});
        } else {
          table.onlyFields({"command", "timeout_ms"});
        }

        const auto command = table.field("command");
        const auto count = command.arraySize();
        static_assert(CommandValues<Memory>::maximum_arguments == 32, "the message names the limit");

        if (count == 0 || count > CommandValues<Memory>::maximum_arguments) {
          command.fail("must contain 1..32 arguments");
        }

        destination.arguments.clear();
        auto& memory = destination.arguments.get_allocator().memory();
        std::size_t bytes = 0;

        for (std::size_t index = 1; index <= count; ++index) {
          const auto argument = command.element(static_cast<lua_Integer>(index));
          const auto text = argument.string();
          if ((index == 1 && text.empty()) || text.size() > 4096 - bytes || text.contains('\0')) {
            argument.fail("exceeds the helper command bounds");
          }

          bytes += text.size();
          destination.arguments.emplace_back(text, AllocatorRef<char, Memory>{memory});
        }

        destination.timeout = std::chrono::milliseconds{table.field("timeout_ms").boundedInteger(15'000, 1000, 60'000)};
        if (engine) {
          destination.idle_timeout = std::chrono::milliseconds{table.field("idle_timeout_ms").boundedInteger(300'000, 10'000, 3'600'000)};
        }
      }

      RuntimeValues<Memory>& values_;
    };

    template <Allocator Memory>
    RuntimeReader(RuntimeValues<Memory>& values) -> RuntimeReader<Memory>;

  }
}
