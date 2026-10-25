#pragma once

#include "../agents/manifest.hpp"
#include "../lua/value.hpp"
#include "limit_notices.hpp"
#include <ghostty/vt/unicode.h>

namespace telar::runtime::config {

class AgentReader {
public:
  explicit AgentReader(AgentManifests &manifests, LimitNotices &limits)
      : manifests_(manifests),
        limits_(limits) {}

  void read(const lua::Value &agents) {
    if (!agents.present()) {
      return;
    }

    const auto count = agents.arraySize();
    std::size_t dropped = 0;
    for (std::size_t position = 1; position <= count; ++position) {
      const auto entry = agents.element(static_cast<lua_Integer>(position));
      entry.onlyFields({"name", "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt", "display_name", "placeholder", "icon", "attachments", "command_tools"});
      auto *manifest = manifests_.tryAdd(entry.field("name").string());
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
  static std::string_view printable(const lua::Value &value) {
    const auto text = value.string();
    validateUtf8(text);
    if (text.empty() || std::ranges::any_of(text, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
      value.fail("must be a printable string");
    }

    return text;
  }

  template <std::size_t Capacity, std::size_t TextCapacity>
  void list(const lua::Value &value, ManifestTextList<Capacity, TextCapacity> &destination, LimitReach entries_limit, LimitReach bytes_limit) {
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

  void paths(const lua::Value &value, ManifestTextList<8, 128> &destination) {
    list(value, destination, {"agent_manifest.max_paths", "entries", 8, {}, {}}, {"agent_manifest.max_path_bytes", "bytes", 128, {}, {}});
  }

  void phrases(const lua::Value &value, ManifestTextList<16, 64> &destination) {
    list(value, destination, {"agent_manifest.max_phrases", "phrases", 16, {}, {}}, {"agent_manifest.max_phrase_bytes", "bytes", 64, {}, {}});
  }

  void commandTools(const lua::Value &value, AgentManifest &manifest) {
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
  static void text(const lua::Value &value, FixedText<Capacity> &destination) {
    if (value.present()) {
      destination.assign(printable(value));
    }
  }

  static unsigned iconWidth(std::string_view text) noexcept {
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

  static void presentation(const lua::Value &entry, AgentManifest &manifest) {
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
    for (const auto &[name, kind] : std::array<std::pair<std::string_view, AgentAttachmentMarkers>, 4>{{{"none", AgentAttachmentMarkers::none}, {"ordered", AgentAttachmentMarkers::ordered}, {"stable_number", AgentAttachmentMarkers::stable_number}, {"pasted_path", AgentAttachmentMarkers::pasted_path}}}) {
      if (name == policy) {
        manifest.attachments = kind;
        return;
      }
    }

    attachments.fail("must be none, ordered, stable_number or pasted_path");
  }

  AgentManifests &manifests_;
  LimitNotices &limits_;
};

}
