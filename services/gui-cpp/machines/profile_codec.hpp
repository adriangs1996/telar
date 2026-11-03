#pragma once

#include "core/memory.hpp"
#include "failure.hpp"
#include "identity.hpp"
#include "profile.hpp"
#include "profiles.hpp"
#include "telar_base/text/json.hpp"
#include "telar_base/text/json_fields.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "text/json_unsigned_integer.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <new>
#include <optional>
#include <string_view>

namespace telar::gui {

struct MachineProfileCodec {
  template <Allocator Memory>
  [[nodiscard]] static MachineProfiles parse(Memory &memory, std::string_view source) {
    try {
      validateUtf8(source);
      const runtime::JsonFields fields{memory, runtime::JsonValue::parse(source), file_fields};
      String<Memory> scratch{AllocatorRef<char, Memory>{memory}};
      const auto version = readVersion(memory, fields.required("version"), scratch);
      validateOptionalString(fields.optional("local_label"), scratch);
      std::size_t count = 0;
      fields.required("machines").eachElement([&](const runtime::JsonValue &value) {
        validateProfile(memory, value, scratch);
        ++count;
      });
      if (version < MachineProfiles::plain_format_version || version > MachineProfiles::extended_format_version) {
        throw MachineFailure{MachineError::incompatible_profiles};
      }

      if (count > MachineLimits::profiles) {
        throw MachineFailure{MachineError::too_many};
      }

      MachineProfiles profiles;
      if (const auto &label = fields.optional("local_label"); label && !isNull(*label)) {
        label->string(scratch);
        profiles.relabelLocal(scratch);
      }

      fields.required("machines").eachElement([&](const runtime::JsonValue &value) {
        profiles.add(readProfile(memory, value));
      });

      return profiles;
    } catch (const std::bad_alloc &) {
      throw;
    } catch (const MachineFailure &) {
      throw;
    } catch (const std::exception &) {
      throw MachineFailure{MachineError::invalid_profiles};
    }
  }

  template <Allocator Memory>
  [[nodiscard]] static String<Memory> format(Memory &memory, const MachineProfiles &profiles) {
    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += profiles.version() == MachineProfiles::plain_format_version ? "{\"version\":1" : "{\"version\":2";
    if (const auto label = profiles.localLabel()) {
      output += ",\"local_label\":";
      runtime::appendJsonString(output, *label);
    }

    output += ",\"machines\":[";
    bool first = true;
    for (const auto &profile : profiles.rows()) {
      output += first ? "\n  " : ",\n  ";
      first = false;
      appendProfile(output, profile);
    }

    if (!first) {
      output += '\n';
    }

    output += "]}\n";

    return output;
  }

private:
  static constexpr auto file_fields = std::to_array<std::string_view>({"version", "local_label", "machines"});
  static constexpr auto profile_fields = std::to_array<std::string_view>({"id", "label", "destination", "color", "enabled", "telar_path", "logins"});

  static bool isNull(const runtime::JsonValue &value) noexcept {
    return value.encoded() == "null";
  }

  template <Allocator Memory>
  static std::uint16_t readVersion(Memory &memory, const runtime::JsonValue &value, String<Memory> &scratch) {
    auto text = value.encoded();
    if (text.starts_with('"')) {
      value.string(scratch);
      text = scratch;
    }

    return JsonUnsignedInteger::parse<std::uint16_t>(memory, text);
  }

  template <Allocator Memory>
  static void validateOptionalString(const std::optional<runtime::JsonValue> &value, String<Memory> &scratch) {
    if (value && !isNull(*value)) {
      value->string(scratch);
    }
  }

  template <Allocator Memory>
  static MachineLogin readLogin(const runtime::JsonValue &value, String<Memory> &scratch) {
    auto text = value.encoded();
    if (text.starts_with('"')) {
      value.string(scratch);
      text = scratch;
    }

    auto const *const found = std::ranges::find(machine_login_names, text);
    if (found != machine_login_names.end()) {
      return static_cast<MachineLogin>(found - machine_login_names.begin());
    }

    const auto ordinal = JsonUnsignedInteger::parse<std::uint8_t>(scratch.get_allocator().memory(), text, false);
    if (ordinal >= machine_login_names.size()) {
      throw MachineFailure{MachineError::invalid_profiles};
    }

    return static_cast<MachineLogin>(ordinal);
  }

  template <Allocator Memory>
  static void validateProfile(Memory &memory, const runtime::JsonValue &value, String<Memory> &scratch) {
    const runtime::JsonFields fields{memory, value, profile_fields};
    for (auto const *name : {"id", "label", "destination"}) {
      fields.required(name).string(scratch);
    }

    validateOptionalString(fields.optional("color"), scratch);
    validateOptionalString(fields.optional("telar_path"), scratch);
    if (const auto &enabled = fields.optional("enabled"); enabled && enabled->encoded() != "true" && enabled->encoded() != "false") {
      throw MachineFailure{MachineError::invalid_profiles};
    }

    if (const auto &logins = fields.optional("logins"); logins && !isNull(*logins)) {
      const runtime::JsonFields values{memory, *logins, machine_agent_names};
      for (const auto name : machine_agent_names) {
        if (const auto &login = values.optional(name); login && !isNull(*login)) {
          static_cast<void>(readLogin(*login, scratch));
        }
      }
    }
  }

  template <Allocator Memory>
  static String<Memory> readString(Memory &memory, const runtime::JsonValue &value) {
    String<Memory> text{AllocatorRef<char, Memory>{memory}};
    value.string(text);

    return text;
  }

  template <Allocator Memory>
  static MachineProfile readProfile(Memory &memory, const runtime::JsonValue &value) {
    runtime::JsonFields fields{memory, value, profile_fields};
    const auto identity = MachineId::parse(fields.string("id"));
    const auto label = readString(memory, fields.required("label"));
    const auto destination = readString(memory, fields.required("destination"));
    const auto &color_value = fields.optional("color");
    const auto color = color_value && !isNull(*color_value) ? std::optional{readString(memory, *color_value)} : std::nullopt;
    const auto &program_value = fields.optional("telar_path");
    const auto program = program_value && !isNull(*program_value) ? std::optional{readString(memory, *program_value)} : std::nullopt;
    const auto &enabled = fields.optional("enabled");
    auto profile = MachineProfile::create(identity, {
                                                        .label = label,
                                                        .destination = destination,
                                                        .color = color ? std::optional<std::string_view>{*color} : std::nullopt,
                                                        .enabled = !enabled || enabled->boolean(),
                                                        .program = program ? std::optional<std::string_view>{*program} : std::nullopt,
                                                    });
    if (const auto &logins = fields.optional("logins"); logins && !isNull(*logins)) {
      const runtime::JsonFields values{memory, *logins, machine_agent_names};
      String<Memory> scratch{AllocatorRef<char, Memory>{memory}};
      for (const auto agent : machine_agents) {
        const auto name = machine_agent_names.at(static_cast<std::size_t>(agent));
        if (const auto &login = values.optional(name); login && !isNull(*login)) {
          profile.recordLogin(agent, readLogin(*login, scratch));
        }
      }
    }

    return profile;
  }

  template <Allocator Memory>
  static void appendProfile(String<Memory> &output, const MachineProfile &profile) {
    output += "{\"id\":";
    runtime::appendJsonString(output, profile.identity().format().view());
    output += ",\"label\":";
    runtime::appendJsonString(output, profile.label());
    output += ",\"destination\":";
    runtime::appendJsonString(output, profile.destination());
    if (const auto color = profile.color()) {
      output += ",\"color\":";
      runtime::appendJsonString(output, *color);
    }

    output += profile.enabled() ? ",\"enabled\":true" : ",\"enabled\":false";
    if (const auto program = profile.program()) {
      output += ",\"telar_path\":";
      runtime::appendJsonString(output, *program);
    }

    bool first = true;
    for (const auto agent : machine_agents) {
      const auto login = profile.login(agent);
      if (!login) {
        continue;
      }

      output += first ? ",\"logins\":{" : ",";
      first = false;
      runtime::appendJsonString(output, machine_agent_names.at(static_cast<std::size_t>(agent)));
      output += ':';
      runtime::appendJsonString(output, machine_login_names.at(static_cast<std::size_t>(*login)));
    }

    output += first ? "}" : "}}";
  }
};

}
