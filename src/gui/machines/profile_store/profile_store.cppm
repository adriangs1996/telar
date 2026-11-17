module;
#include "tbc/annotations.hpp"

export module telar.gui.machines.profile_store;

import std;

import telar.gui.machines.discovery;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.machines;

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
      TBC_GENERIC static void apply(MachineProfiles& profiles, const MachineEdit& edit, Random& random, std::string_view local_fallback) {
        if (edit.kind != MachineEditKind::add) {
          change(profiles, edit, local_fallback);
          return;
        }

        requireRemoteLabel(profiles, edit.label, local_fallback);
        add(profiles, edit, MachineId::generate(random));
      }

    private:
      static void add(MachineProfiles& profiles, const MachineEdit& edit, MachineId id);

      // Every edit but add, which alone draws an identity.
      static void change(MachineProfiles& profiles, const MachineEdit& edit, std::string_view local_fallback);

      static void requireRemoteLabel(const MachineProfiles& profiles, std::string_view label, std::string_view fallback);
    };

  }
}

// Interface: machines/owned_edit.cppm
export {
  namespace telar::gui {

    class OwnedMachineEdit {
    public:
      [[nodiscard]] static OwnedMachineEdit copy(const MachineEdit& edit);

      [[nodiscard]] MachineEdit view() const noexcept;

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

    // Generic over the caller's storage, a file in production and fakes in tests.
    template <Allocator Memory, MachineProfileStorage<Memory> Storage>
    class TBC_GENERIC MachineProfileStore {
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
