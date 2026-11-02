#pragma once

#include "../memory/fixed_text.hpp"
#include "../text/ascii.hpp"
#include "../text/executable_name.hpp"
#include "evidence.hpp"
#include "provider.hpp"
#include <cstring>

namespace telar::runtime {

inline bool containsInsensitive(std::string_view text, std::string_view phrase) noexcept {
  if (phrase.empty() || phrase.size() > text.size()) {
    return false;
  }

  for (std::size_t offset = 0; offset <= text.size() - phrase.size(); ++offset) {
    if (std::equal(phrase.begin(), phrase.end(), text.begin() + offset, [](char left, char right) { return asciiLower(left) == asciiLower(right); })) {
      return true;
    }
  }

  return false;
}

template <std::size_t Capacity, std::size_t TextCapacity>
class ManifestTextList {
public:
  void append(std::string_view text) {
    if (text.empty() || text.size() > TextCapacity || count_ == Capacity) {
      throw EncodingError{"Agent manifest list exceeds its bounds"};
    }

    entries_[count_++].assign(text);
  }

  bool matches(std::string_view text) const noexcept {
    return std::ranges::any_of(entries(), [&](const auto &phrase) { return containsInsensitive(text, phrase.view()); });
  }

  std::span<const FixedText<TextCapacity>> entries() const noexcept {
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
  control_c
};

struct AgentCommandTool {
  FixedText<64> tool;
  FixedText<32> field;
};

struct AgentManifest {
  void addCommandTool(std::string_view name, std::string_view field) {
    if (name.empty() || name.size() > 64 || field.empty() || field.size() > 32 || tool_count == command_tools.size()) {
      throw EncodingError{"Invalid agent command tool"};
    }

    command_tools[tool_count].tool.assign(name);
    command_tools[tool_count].field.assign(field);
    ++tool_count;
  }

  std::string_view commandField(std::string_view tool) const noexcept {
    for (const auto &mapping : std::span{command_tools}.first(tool_count)) {
      if (mapping.tool.view() == tool) {
        return mapping.field.view();
      }
    }

    return {};
  }

  std::string_view displayName() const noexcept {
    return display_name.view().empty() ? name.view() : display_name.view();
  }

  std::string_view placeholderTitle(FixedText<96> &storage) const {
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
  FixedText<32> name;
  FixedText<32> display_name;
  FixedText<96> placeholder;
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
  AgentManifest &add(std::string_view name) {
    auto *manifest = tryAdd(name);
    if (manifest == nullptr) {
      throw EncodingError{"Too many agent manifests"};
    }

    return *manifest;
  }

  AgentManifest *tryAdd(std::string_view name) {
    if (name.empty() || name.size() > 32 || !std::ranges::all_of(name, [](char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.'; })) {
      throw EncodingError{"Invalid agent manifest name"};
    }

    const auto builtin = providerNamed(name);
    for (auto &entry : std::span{entries_}.first(count_)) {
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

    auto &entry = entries_[count_++];
    entry.provider = builtin == AgentProvider::unknown ? static_cast<AgentProvider>(first_custom_provider + custom_count_++) : builtin;
    entry.name.assign(name);
    return &entry;
  }

  const AgentManifest *find(AgentProvider provider) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.provider == provider) {
        return &entry;
      }
    }

    return nullptr;
  }

  AgentProvider named(std::string_view name) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.name.view() == name) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  AgentProvider fromExecutable(std::string_view name) const noexcept {
    const auto stem = withoutExecutableSuffix(name);
    for (const auto &entry : entries()) {
      for (const auto &candidate : entry.process_names.entries()) {
        if (asciiEqualIgnoreCase(stem, candidate.view())) {
          return entry.provider;
        }
      }
    }

    return AgentProvider::unknown;
  }

  AgentProvider fromPath(std::string_view path) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.process_paths.matches(path)) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  std::optional<AgentSignal> detect(std::string_view text) const noexcept {
    for (const auto &entry : entries()) {
      if (entry.blocked.matches(text)) {
        return AgentSignal{inferProvider(text), AgentStatus::blocked, 88};
      }
    }

    for (const auto &entry : entries()) {
      if (entry.working.matches(text)) {
        return AgentSignal{inferProvider(text), AgentStatus::working, 78};
      }
    }

    for (const auto &entry : entries()) {
      if (entry.ready_prompt.matches(text)) {
        return AgentSignal{entry.provider, AgentStatus::ready, 94, true, true};
      }
    }

    for (const auto &entry : entries()) {
      if (entry.identity.matches(text)) {
        return AgentSignal{entry.provider, AgentStatus::ready, 90, true, false};
      }
    }

    return std::nullopt;
  }

  std::span<const AgentManifest> entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

private:
  AgentProvider inferProvider(std::string_view text) const noexcept {
    for (const auto &entry : entries()) {
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
