module;
#include <cstdio>
#include <cstdlib>

#include <cstddef>
#include <cstdint>

#include <cstring>

#include <new>

export module telar.gui.machines.profile_store;

import std;

export import telar.gui.machines.discovery;

export import telar.base.text;
export import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.gui.core.primitives;
import telar.wire.vocabulary;

// Interface: machines/field_rules.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
  using telar::runtime::machines::MachineFieldRules;
}

// Interface: machines/profile.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
  using telar::runtime::machines::machine_agent_names;
  using telar::runtime::machines::machine_agents;
  using telar::runtime::machines::machine_login_names;
  using telar::runtime::machines::MachineAgent;
  using telar::runtime::machines::MachineLogin;
  using telar::runtime::machines::MachineProfile;
  using telar::runtime::machines::MachineProfileFields;
}

// Interface: machines/profiles.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
  using telar::runtime::machines::MachineProfiles;
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
      inline static void apply(MachineProfiles& profiles, const MachineEdit& edit, Random& random, std::string_view local_fallback) {
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
      inline static void requireRemoteLabel(const MachineProfiles& profiles, std::string_view label, std::string_view fallback) {
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
      [[nodiscard]] inline static OwnedMachineEdit copy(const MachineEdit& edit) {
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
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
  using telar::runtime::machines::MachineProfileCodec;
}

// Interface: machines/profile_store.cppm
export {
  namespace telar::gui {

    template <typename Source, typename Memory>
    concept MachineProfileSource = Allocator<Memory> && requires(Source& source, Memory& memory) {
      { source.read(memory) } -> std::same_as<std::optional<Vector<Byte, Memory>>>;
    };

    template <typename Storage, typename Memory>
    concept MachineProfileStorage = MachineProfileSource<Storage, Memory> && requires(Storage& storage) {
      storage.lock();
      requires MachineProfileSource<decltype(storage.lock()), Memory>;
      { storage.lock().replace(std::string_view{}) } -> std::same_as<void>;
    };

    template <Allocator Memory, MachineProfileStorage<Memory> Storage>
    class MachineProfileStore {
    public:
      inline MachineProfileStore(Memory& memory, Storage& storage) noexcept
          : memory_(memory),
            storage_(storage) {}

      [[nodiscard]] inline MachineProfiles load() {
        return read(storage_);
      }

      template <MachineIdentityRandom Random>
      [[nodiscard]] inline MachineProfiles change(std::span<const MachineEdit> edits, Random& random, std::string_view local_fallback) {
        auto transaction = storage_.lock();
        auto profiles = read(transaction);

        for (const auto& edit : edits) {
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
      inline MachineProfiles read(Source& storage) {
        const auto source = storage.read(memory_);

        return source ? MachineProfileCodec::parse(memory_, textView(*source)) : MachineProfiles{};
      }

      Memory& memory_;
      Storage& storage_;
    };

  }
}

// Interface: machines/remote_command.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
  using telar::runtime::machines::MachineRemoteCommand;
}
