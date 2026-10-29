#pragma once

#include "core/memory.hpp"
#include "edit.hpp"
#include "identity.hpp"
#include "limits.hpp"
#include "profile_codec.hpp"
#include "profiles.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <concepts>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

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
  MachineProfileStore(Memory &memory, Storage &storage) noexcept
      : memory_(memory),
        storage_(storage) {}

  [[nodiscard]] MachineProfiles load() {
    return read(storage_);
  }

  template <MachineIdentityRandom Random>
  [[nodiscard]] MachineProfiles change(std::span<const MachineEdit> edits, Random &random, std::string_view local_fallback) {
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
  MachineProfiles read(Source &storage) {
    const auto source = storage.read(memory_);

    return source ? MachineProfileCodec::parse(memory_, textView(*source)) : MachineProfiles{};
  }

  Memory &memory_;
  Storage &storage_;
};

}
