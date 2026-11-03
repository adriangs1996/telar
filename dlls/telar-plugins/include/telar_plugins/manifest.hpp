#pragma once

#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/json_fields.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_plugins/capabilities.hpp"
#include "telar_plugins/identity.hpp"
#include "telar_plugins/package_limits.hpp"
#include "telar_plugins/schema_version.hpp"
#include <charconv>
#include <optional>

namespace telar::runtime::plugins {

struct Manifest {
  FixedText<PackageLimits::id_bytes> id;
  FixedText<PackageLimits::version_bytes> version;
  FixedText<PackageLimits::entry_bytes> entry;
  FixedText<PackageLimits::source_bytes> source;
  FixedText<PackageLimits::revision_bytes> revision;
  std::array<FixedText<PackageLimits::action_bytes>, PackageLimits::actions> actions;
  std::size_t action_count = 0;
  Capabilities capabilities;

  // Zig's `parseManifest`: the typed JSON read first, then each field's
  // check in Zig's order, failing with Zig's error names.
  template <Allocator Memory>
  static Manifest parse(Memory &memory, std::string_view bytes) {
    if (bytes.size() > PackageLimits::manifest_bytes) {
      throw std::invalid_argument{"ManifestTooLarge"};
    }

    std::optional<JsonValue> root;
    try {
      validateUtf8(bytes);
      root = JsonValue::parse(bytes);
    } catch (const std::exception &) {
      throw std::invalid_argument{syntaxFailure(bytes)};
    }

    Wire<Memory> wire{memory};
    try {
      wire.read(memory, *root);
    } catch (const RequestError &) {
      throw std::invalid_argument{"UnexpectedToken"};
    } catch (const std::invalid_argument &error) {
      throw std::invalid_argument{fieldFailure(error.what())};
    }

    return wire.validate();
  }

private:
  template <Allocator Memory>
  struct Wire {
    explicit Wire(Memory &memory)
        : id(AllocatorRef<char, Memory>{memory}),
          version(AllocatorRef<char, Memory>{memory}),
          entry(AllocatorRef<char, Memory>{memory}),
          url(AllocatorRef<char, Memory>{memory}),
          revision(AllocatorRef<char, Memory>{memory}),
          actions(AllocatorRef<String<Memory>, Memory>{memory}),
          capabilities(AllocatorRef<String<Memory>, Memory>{memory}) {}

    void read(Memory &memory, const JsonValue &root) {
      JsonFields fields{memory, root, field_names};
      api_version = number(fields.required("api_version"));
      fields.required("id").string(id);
      fields.required("version").string(version);
      fields.required("entry").string(entry);
      JsonFields origin{memory, fields.required("source"), source_names};
      origin.required("url").string(url);
      origin.required("revision").string(revision);
      for (auto [name, list] : {std::pair{"actions", &actions}, std::pair{"capabilities", &capabilities}}) {
        if (const auto &value = fields.optional(name)) {
          value->eachElement([&](const JsonValue &element) {
            element.string(list->emplace_back(AllocatorRef<char, Memory>{memory}));
          });
        }
      }
    }

    Manifest validate() const {
      constexpr std::uint64_t manifest_api = 1;
      if (api_version != manifest_api) {
        throw std::invalid_argument{"IncompatibleManifestApi"};
      }

      if (!validIdentifier(id) || id.size() > PackageLimits::id_bytes) {
        throw std::invalid_argument{"InvalidPluginId"};
      }

      if (version.empty() || version.size() > PackageLimits::version_bytes) {
        throw std::invalid_argument{"InvalidVersion"};
      }

      if (!validEntrypoint(entry) || entry.size() > PackageLimits::entry_bytes) {
        throw std::invalid_argument{"InvalidEntrypoint"};
      }

      if (url.empty() || url.size() > PackageLimits::source_bytes) {
        throw std::invalid_argument{"InvalidSource"};
      }

      if (revision.empty() || revision.size() > PackageLimits::revision_bytes) {
        throw std::invalid_argument{"InvalidRevision"};
      }

      if (actions.size() > PackageLimits::actions) {
        throw std::invalid_argument{"TooManyActions"};
      }

      Manifest manifest;
      manifest.id.assign(id);
      manifest.version.assign(version);
      manifest.entry.assign(entry);
      manifest.source.assign(url);
      manifest.revision.assign(revision);
      for (const auto &name : actions) {
        if (!validIdentifier(name) || name.size() > PackageLimits::action_bytes) {
          throw std::invalid_argument{"InvalidActionName"};
        }

        for (const auto &previous : std::span{manifest.actions}.first(manifest.action_count)) {
          if (previous.view() == name) {
            throw std::invalid_argument{"DuplicateAction"};
          }
        }

        manifest.actions[manifest.action_count++].assign(name);
      }

      for (const auto &name : capabilities) {
        manifest.capabilities.insert(Capabilities::parseName(name));
      }

      return manifest;
    }

    // A JSON number as Zig's typed read of a u16 takes it.
    static std::uint64_t number(const JsonValue &value) {
      const auto text = value.encoded();
      if (text.empty() || (text.front() != '-' && (text.front() < '0' || text.front() > '9'))) {
        throw std::invalid_argument{"UnexpectedToken"};
      }

      std::uint16_t result = 0;
      const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
      if (parsed.ec == std::errc::result_out_of_range) {
        throw std::invalid_argument{"Overflow"};
      }

      if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
        throw std::invalid_argument{"InvalidNumber"};
      }

      return result;
    }

    std::uint64_t api_version = 0;
    String<Memory> id;
    String<Memory> version;
    String<Memory> entry;
    String<Memory> url;
    String<Memory> revision;
    Vector<String<Memory>, Memory> actions;
    Vector<String<Memory>, Memory> capabilities;
  };

  // std.json's scanner: input that stops inside a string or an open object or
  // array ran out; anything else malformed is a syntax error.
  static const char *syntaxFailure(std::string_view text) noexcept {
    std::size_t depth = 0;
    bool in_string = false;
    bool escaped = false;
    for (const char byte : text) {
      if (in_string) {
        escaped = !escaped && byte == '\\';
        in_string = escaped || byte != '"';
      } else if (byte == '"') {
        in_string = true;
      } else if (byte == '{' || byte == '[') {
        ++depth;
      } else if ((byte == '}' || byte == ']') && depth != 0) {
        --depth;
      }
    }

    return in_string || depth != 0 || text.find_first_not_of(" \t\r\n") == std::string_view::npos ? "UnexpectedEndOfInput" : "SyntaxError";
  }

  // std.json's typed-read errors for JsonFields' refusals.
  static const char *fieldFailure(std::string_view message) noexcept {
    if (message == "Missing JSON field") {
      return "MissingField";
    }

    if (message == "Unknown JSON field") {
      return "UnknownField";
    }

    if (message == "Duplicate JSON field") {
      return "DuplicateField";
    }

    return message.data();
  }

  static constexpr auto field_names = std::to_array<std::string_view>({"api_version", "id", "version", "entry", "source", "actions", "capabilities"});
  static constexpr auto source_names = std::to_array<std::string_view>({"url", "revision"});
};

}
