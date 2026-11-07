module;
#include <memory>
#include <type_traits>
#include <cstdio>
#include <string>
#include <variant>
#include <vector>
#include <chrono>
#include <utility>
#include <cstdlib>
#include <mutex>

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <algorithm>
#include <string_view>

#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <span>
#include <optional>

#include <exception>
#include <bit>
#include <limits>
#include <new>

export module telar.gui.machines.profile_store;

export import telar.gui.machines.discovery;


export import telar.base.text;
export import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: machines/field_rules.cppm
export {
namespace telar::gui {

struct MachineFieldRules {
  inline static void label(std::string_view text) {
    if (text.empty() || text.size() > MachineLimits::label_bytes || !alphanumeric(text.front()) || !std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '.' || byte == '_' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_label};
    }
  }

  inline static void destination(std::string_view text) {
    if (text.empty() || text.front() == '-' || std::ranges::any_of(text, [](unsigned char byte) {
          return byte <= ' ' || byte == delete_byte;
        })) {
      throw MachineFailure{MachineError::invalid_destination};
    }
  }

  inline static void profileDestination(std::string_view text) {
    if (text.size() > MachineLimits::destination_bytes || inspectUtf8(text) != Utf8Validation::valid) {
      throw MachineFailure{MachineError::invalid_destination};
    }

    destination(text);
  }

  inline static void color(std::string_view text) {
    if (text.empty() || text.size() > MachineLimits::color_bytes) {
      throw MachineFailure{MachineError::invalid_color};
    }

    if (text.front() == '#') {
      constexpr std::size_t rgb_text_bytes = std::string_view{"#RRGGBB"}.size();
      if (text.size() != rgb_text_bytes || !std::ranges::all_of(text.substr(1), [](char byte) {
            return decimal(byte) || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
          })) {
        throw MachineFailure{MachineError::invalid_color};
      }

      return;
    }

    if (!std::ranges::all_of(text, [](char byte) {
          return (byte >= 'a' && byte <= 'z') || decimal(byte) || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_color};
    }
  }

  inline static void program(std::string_view text) {
    if (text.size() < minimum_program_bytes || text.size() > MachineLimits::program_bytes || text.front() != '/' || text.back() == '/' || text.contains("/../") || text.ends_with("/..")) {
      throw MachineFailure{MachineError::invalid_program};
    }

    if (!std::ranges::all_of(text, [](char byte) {
          return alphanumeric(byte) || byte == '/' || byte == '.' || byte == '_' || byte == '+' || byte == '-';
        })) {
      throw MachineFailure{MachineError::invalid_program};
    }
  }

private:
  static constexpr unsigned char delete_byte = 0x7f;
  static constexpr std::size_t minimum_program_bytes = 2;

  inline static bool decimal(char byte) noexcept {
    return byte >= '0' && byte <= '9';
  }

  inline static bool alphanumeric(char byte) noexcept {
    return decimal(byte) || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }
};

}
}

// Interface: machines/profile.cppm
export {
namespace telar::gui {

enum class MachineLogin : std::uint8_t {
  pending,
  done,
  failed,
};
enum class MachineAgent : std::uint8_t {
  claude,
  codex,
  pi,
  cursor,
  opencode,
};

inline constexpr std::array machine_agents{MachineAgent::claude, MachineAgent::codex, MachineAgent::pi, MachineAgent::cursor, MachineAgent::opencode};
inline constexpr std::array<std::string_view, machine_agents.size()> machine_agent_names{"claude", "codex", "pi", "cursor", "opencode"};
inline constexpr auto machine_login_names = std::to_array<std::string_view>({"pending", "done", "failed"});

struct MachineProfileFields {
  std::string_view label;
  std::string_view destination;
  std::optional<std::string_view> color = std::nullopt;
  bool enabled = true;
  std::optional<std::string_view> program = std::nullopt;
};

class MachineProfile {
public:
  [[nodiscard]] inline static MachineProfile create(MachineId identity, MachineProfileFields fields) {
    if (identity.value() == 0) {
      throw MachineFailure{MachineError::invalid_id};
    }

    MachineFieldRules::label(fields.label);
    MachineFieldRules::profileDestination(fields.destination);
    MachineProfile profile;
    profile.identity_ = identity;
    profile.label_.assign(fields.label);
    profile.destination_.assign(fields.destination);
    profile.enabled_ = fields.enabled;
    if (fields.color) {
      MachineFieldRules::color(*fields.color);
      profile.color_.assign(*fields.color);
    }

    if (fields.program) {
      profile.placeProgram(*fields.program);
    }

    return profile;
  }

  [[nodiscard]] inline MachineId identity() const noexcept {
    return identity_;
  }

  [[nodiscard]] inline std::string_view label() const noexcept {
    return label_.view();
  }

  [[nodiscard]] inline std::string_view destination() const noexcept {
    return destination_.view();
  }

  [[nodiscard]] inline std::optional<std::string_view> color() const noexcept {
    return optional(color_.view());
  }

  [[nodiscard]] inline std::optional<std::string_view> program() const noexcept {
    return optional(program_.view());
  }

  [[nodiscard]] inline bool enabled() const noexcept {
    return enabled_;
  }

  inline void enable(bool enabled) noexcept {
    enabled_ = enabled;
  }

  inline void relabel(std::string_view label) {
    MachineFieldRules::label(label);
    label_.assign(label);
  }

  inline void placeProgram(std::string_view path) {
    MachineFieldRules::program(path);
    program_.assign(path);
  }

  inline void recordLogin(MachineAgent agent, std::optional<MachineLogin> login) {
    logins_.at(static_cast<std::size_t>(agent)) = login;
  }

  [[nodiscard]] inline std::optional<MachineLogin> login(MachineAgent agent) const {
    return logins_.at(static_cast<std::size_t>(agent));
  }

private:
  inline static std::optional<std::string_view> optional(std::string_view value) noexcept {
    return value.empty() ? std::nullopt : std::optional{value};
  }

  MachineId identity_;
  runtime::FixedText<MachineLimits::label_bytes> label_;
  runtime::FixedText<MachineLimits::destination_bytes> destination_;
  runtime::FixedText<MachineLimits::color_bytes> color_;
  runtime::FixedText<MachineLimits::program_bytes> program_;
  std::array<std::optional<MachineLogin>, machine_agents.size()> logins_{};
  bool enabled_ = true;
};

}
}

// Interface: machines/profiles.cppm
export {
namespace telar::gui {

class MachineProfiles {
public:
  static constexpr std::uint16_t plain_format_version = 1;
  static constexpr std::uint16_t extended_format_version = 2;

  [[nodiscard]] inline std::span<const MachineProfile> rows() const noexcept {
    return std::span{rows_}.first(length_);
  }

  [[nodiscard]] inline std::optional<std::string_view> localLabel() const noexcept {
    return local_label_.view().empty() ? std::nullopt : std::optional{local_label_.view()};
  }

  inline void relabelLocal(std::string_view label) {
    MachineFieldRules::label(label);
    local_label_.assign(label);
  }

  [[nodiscard]] inline std::optional<std::size_t> find(std::string_view label) const noexcept {
    const auto found = std::ranges::find(rows(), label, &MachineProfile::label);

    return found == rows().end() ? std::nullopt : std::optional{static_cast<std::size_t>(found - rows().begin())};
  }

  [[nodiscard]] inline std::optional<std::size_t> findDestination(std::string_view destination) const noexcept {
    const auto found = std::ranges::find(rows(), destination, &MachineProfile::destination);

    return found == rows().end() ? std::nullopt : std::optional{static_cast<std::size_t>(found - rows().begin())};
  }

  inline void add(const MachineProfile &profile) {
    if (length_ == rows_.size()) {
      throw MachineFailure{MachineError::too_many};
    }

    requireFreeLabel(profile.label());
    for (const auto &existing : rows()) {
      if (existing.identity() == profile.identity()) {
        throw MachineFailure{MachineError::duplicate_id};
      }

      if (existing.destination() == profile.destination()) {
        throw MachineFailure{MachineError::duplicate_destination};
      }
    }

    rows_[length_] = profile;
    ++length_;
  }

  inline void remove(std::string_view label) {
    const auto position = require(label);
    for (auto index = position; index + 1 < length_; ++index) {
      rows_[index] = rows_[index + 1];
    }

    --length_;
  }

  inline void rename(std::string_view label, std::string_view replacement) {
    const auto position = require(label);
    if (label == replacement) {
      return;
    }

    requireFreeLabel(replacement);
    rows_[position].relabel(replacement);
  }

  inline void enable(std::string_view label, bool enabled) {
    rows_[require(label)].enable(enabled);
  }

  inline void recordLogin(std::string_view label, MachineAgent agent, MachineLogin login) {
    rows_[require(label)].recordLogin(agent, login);
  }

  inline void placeProgram(std::string_view label, std::string_view path) {
    rows_[require(label)].placeProgram(path);
  }

  [[nodiscard]] inline std::uint16_t version() const {
    for (const auto &profile : rows()) {
      if (profile.program() || std::ranges::any_of(machine_agents, [&](MachineAgent agent) {
            return profile.login(agent).has_value();
          })) {
        return extended_format_version;
      }
    }

    return plain_format_version;
  }

private:
  [[nodiscard]] inline std::size_t require(std::string_view label) const {
    const auto found = find(label);
    if (!found) {
      throw MachineFailure{MachineError::unknown_machine};
    }

    return *found;
  }

  inline void requireFreeLabel(std::string_view label) const {
    MachineFieldRules::label(label);
    if (find(label) || localLabel() == label) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }

  std::array<MachineProfile, MachineLimits::profiles> rows_;
  runtime::FixedText<MachineLimits::label_bytes> local_label_;
  std::size_t length_ = 0;
};

}
}

// Interface: machines/edit.cppm
export {
namespace telar::gui {

enum class MachineEditKind : std::uint8_t {
  add,
  remove,
  rename,
  enable,
  disable,
  place_program,
  record_login,
};

struct MachineEdit {
  MachineEditKind kind;
  std::string_view label;
  std::string_view value;
  std::optional<std::string_view> color = std::nullopt;
  bool enabled = true;
  MachineAgent login_agent = MachineAgent::claude;
  MachineLogin login = MachineLogin::pending;
};

struct MachineProfileEdits {
  template <MachineIdentityRandom Random>
  inline static void apply(MachineProfiles &profiles, const MachineEdit &edit, Random &random, std::string_view local_fallback) {
    switch (edit.kind) {
    case MachineEditKind::add:
      requireRemoteLabel(profiles, edit.label, local_fallback);
      profiles.add(MachineProfile::create(MachineId::generate(random), {
                                                                           .label = edit.label,
                                                                           .destination = edit.value,
                                                                           .color = edit.color,
                                                                           .enabled = edit.enabled,
                                                                       }));
      break;
    case MachineEditKind::remove:
      profiles.remove(edit.label);
      break;
    case MachineEditKind::rename:
      requireRemoteLabel(profiles, edit.value, local_fallback);
      profiles.rename(edit.label, edit.value);
      break;
    case MachineEditKind::enable:
      profiles.enable(edit.label, true);
      break;
    case MachineEditKind::disable:
      profiles.enable(edit.label, false);
      break;
    case MachineEditKind::place_program:
      profiles.placeProgram(edit.label, edit.value);
      break;
    case MachineEditKind::record_login:
      profiles.recordLogin(edit.label, edit.login_agent, edit.login);
      break;
    }
  }

private:
  inline static void requireRemoteLabel(const MachineProfiles &profiles, std::string_view label, std::string_view fallback) {
    if (label == profiles.localLabel().value_or(fallback)) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }
};

}
}

// Interface: machines/owned_edit.cppm
export {
namespace telar::gui {

class OwnedMachineEdit {
public:
  [[nodiscard]] inline static OwnedMachineEdit copy(const MachineEdit &edit) {
    if (edit.label.size() > MachineLimits::label_bytes || edit.value.size() > MachineLimits::destination_bytes) {
      throw MachineFailure{MachineError::invalid_label};
    }

    if (edit.color && edit.color->size() > MachineLimits::color_bytes) {
      throw MachineFailure{MachineError::invalid_color};
    }

    OwnedMachineEdit result;
    result.kind_ = edit.kind;
    result.enabled_ = edit.enabled;
    result.login_agent_ = edit.login_agent;
    result.login_ = edit.login;
    result.has_color_ = edit.color.has_value();
    result.label_.assign(edit.label);
    result.value_.assign(edit.value);
    if (edit.color) {
      result.color_.assign(*edit.color);
    }

    return result;
  }

  [[nodiscard]] inline MachineEdit view() const noexcept {
    return {
        .kind = kind_,
        .label = label_.view(),
        .value = value_.view(),
        .color = has_color_ ? std::optional{color_.view()} : std::nullopt,
        .enabled = enabled_,
        .login_agent = login_agent_,
        .login = login_,
    };
  }

private:
  OwnedMachineEdit() = default;

  MachineEditKind kind_ = MachineEditKind::add;
  MachineAgent login_agent_ = MachineAgent::claude;
  MachineLogin login_ = MachineLogin::pending;
  bool enabled_ = true;
  bool has_color_ = false;
  runtime::FixedText<MachineLimits::label_bytes> label_;
  runtime::FixedText<MachineLimits::destination_bytes> value_;
  runtime::FixedText<MachineLimits::color_bytes> color_;
};

}
}

// Interface: machines/profile_codec.cppm
export {
namespace telar::gui {

struct MachineProfileCodec {
  template <Allocator Memory>
  [[nodiscard]] inline static MachineProfiles parse(Memory &memory, std::string_view source) {
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
  [[nodiscard]] inline static String<Memory> format(Memory &memory, const MachineProfiles &profiles) {
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

  inline static bool isNull(const runtime::JsonValue &value) noexcept {
    return value.encoded() == "null";
  }

  template <Allocator Memory>
  inline static std::uint16_t readVersion(Memory &memory, const runtime::JsonValue &value, String<Memory> &scratch) {
    auto text = value.encoded();
    if (text.starts_with('"')) {
      value.string(scratch);
      text = scratch;
    }

    return JsonUnsignedInteger::parse<std::uint16_t>(memory, text);
  }

  template <Allocator Memory>
  inline static void validateOptionalString(const std::optional<runtime::JsonValue> &value, String<Memory> &scratch) {
    if (value && !isNull(*value)) {
      value->string(scratch);
    }
  }

  template <Allocator Memory>
  inline static MachineLogin readLogin(const runtime::JsonValue &value, String<Memory> &scratch) {
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
  inline static void validateProfile(Memory &memory, const runtime::JsonValue &value, String<Memory> &scratch) {
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
  inline static String<Memory> readString(Memory &memory, const runtime::JsonValue &value) {
    String<Memory> text{AllocatorRef<char, Memory>{memory}};
    value.string(text);

    return text;
  }

  template <Allocator Memory>
  inline static MachineProfile readProfile(Memory &memory, const runtime::JsonValue &value) {
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
  inline static void appendProfile(String<Memory> &output, const MachineProfile &profile) {
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
}

// Interface: machines/profile_store.cppm
export {
namespace telar::gui {

template <typename Source, typename Memory>
concept MachineProfileSource = Allocator<Memory> && requires(Source &source, Memory &memory) {
  { source.read(memory) } -> std::same_as<std::optional<Vector<Byte, Memory>>>;
};

template <typename Storage, typename Memory>
concept MachineProfileStorage = MachineProfileSource<Storage, Memory> && requires(Storage &storage) {
  storage.lock();
  requires MachineProfileSource<decltype(storage.lock()), Memory>;
  { storage.lock().replace(std::string_view{}) } -> std::same_as<void>;
};

template <Allocator Memory, MachineProfileStorage<Memory> Storage>
class MachineProfileStore {
public:
  inline MachineProfileStore(Memory &memory, Storage &storage) noexcept
      : memory_(memory),
        storage_(storage) {}

  [[nodiscard]] inline MachineProfiles load() {
    return read(storage_);
  }

  template <MachineIdentityRandom Random>
  [[nodiscard]] inline MachineProfiles change(std::span<const MachineEdit> edits, Random &random, std::string_view local_fallback) {
    auto transaction = storage_.lock();
    auto profiles = read(transaction);
    for (const auto &edit : edits) {
      MachineProfileEdits::apply(profiles, edit, random, local_fallback);
    }

    const auto source = MachineProfileCodec::format(memory_, profiles);
    if (source.size() > MachineLimits::file_bytes) {
      throw std::length_error{"Machine profiles exceed the file byte limit"};
    }

    transaction.replace(source);

    return profiles;
  }

private:
  template <MachineProfileSource<Memory> Source>
  inline MachineProfiles read(Source &storage) {
    const auto source = storage.read(memory_);

    return source ? MachineProfileCodec::parse(memory_, textView(*source)) : MachineProfiles{};
  }

  Memory &memory_;
  Storage &storage_;
};

}
}

// Interface: machines/remote_command.cppm
export {
namespace telar::gui {

class MachineRemoteCommand {
  static constexpr std::string_view discovery_prefix = R"(/bin/sh -c 'printf "%s\n" "$HOME" "${SHELL:-/bin/sh}"; exec )";
  static constexpr std::string_view discovery_suffix = " server endpoint'";
  static constexpr std::string_view bridge_prefix = "exec ";
  static constexpr std::string_view bridge_suffix = " server bridge";

public:
  static constexpr std::size_t max_bytes = discovery_prefix.size() + MachineLimits::program_bytes + discovery_suffix.size();
  using Text = BoundedText<max_bytes>;

  [[nodiscard]] inline static Text discovery(std::optional<std::string_view> program = std::nullopt) {
    return format(discovery_prefix, program, discovery_suffix);
  }

  [[nodiscard]] inline static Text bridge(std::optional<std::string_view> program = std::nullopt) {
    return format(bridge_prefix, program, bridge_suffix);
  }

private:
  inline static Text format(std::string_view prefix, std::optional<std::string_view> program, std::string_view suffix) {
    if (program) {
      MachineFieldRules::program(*program);
    }

    Text command;
    command.append(prefix);
    command.append(program.value_or("telar"));
    command.append(suffix);

    return command;
  }
};

}
}
