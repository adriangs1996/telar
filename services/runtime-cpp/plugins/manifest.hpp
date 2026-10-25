#pragma once

#include "../memory/fixed_text.hpp"
#include "../text/json_fields.hpp"
#include "capabilities.hpp"
#include "identity.hpp"
#include "package_limits.hpp"
#include "schema_version.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"

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

  template <Allocator Memory>
  static Manifest parse(Memory &memory, std::string_view bytes) {
    if (bytes.size() > PackageLimits::manifest_bytes) {
      throw std::invalid_argument{"Plugin manifest exceeds its limit"};
    }
    validateUtf8(bytes);
    JsonFields fields{memory, JsonValue::parse(bytes), field_names};
    if (!SchemaVersion<Memory>::isOne(memory, fields.required("api_version"))) {
      throw std::invalid_argument{"Incompatible plugin manifest API"};
    }

    Manifest manifest;
    manifest.id.assign(fields.string("id"));
    manifest.version.assign(fields.string("version"));
    manifest.entry.assign(fields.string("entry"));
    JsonFields origin{memory, fields.required("source"), source_names};
    manifest.source.assign(origin.string("url"));
    manifest.revision.assign(origin.string("revision"));
    if (!validIdentifier(manifest.id.view()) || !validEntrypoint(manifest.entry.view()) || manifest.version.view().empty() || manifest.source.view().empty() || manifest.revision.view().empty()) {
      throw std::invalid_argument{"Invalid plugin manifest"};
    }

    if (const auto &actions = fields.optional("actions")) {
      String<Memory> name{AllocatorRef<char, Memory>{memory}};
      actions->eachElement([&](const JsonValue &value) {
        value.string(name);
        if (manifest.action_count == PackageLimits::actions || !validIdentifier(name)) {
          throw std::invalid_argument{"Invalid plugin actions"};
        }
        for (const auto &previous : std::span{manifest.actions}.first(manifest.action_count)) {
          if (previous.view() == name) {
            throw std::invalid_argument{"Duplicate plugin action"};
          }
        }
        manifest.actions[manifest.action_count++].assign(name);
      });
    }
    if (const auto &capabilities = fields.optional("capabilities")) {
      manifest.capabilities = Capabilities::parse(memory, *capabilities);
    }
    return manifest;
  }

private:
  static constexpr auto field_names = std::to_array<std::string_view>({"api_version", "id", "version", "entry", "source", "actions", "capabilities"});
  static constexpr auto source_names = std::to_array<std::string_view>({"url", "revision"});
};

}
