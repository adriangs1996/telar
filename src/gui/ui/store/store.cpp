#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "store.hpp"
#include <exception>

namespace telar::gui::qt {

  Machines& Store::machines() noexcept {
    return machines_;
  }

  const Machines& Store::machines() const noexcept {
    return machines_;
  }

  Store::Clients& Store::clients() noexcept {
    return clients_;
  }

  const Store::Clients& Store::clients() const noexcept {
    return clients_;
  }

  MachineClient& Store::client(Machines::Slot slot) const noexcept {
    const auto& client = clients_[slot];
    if (!client) {
      std::terminate();
    }

    return **client;
  }

  MachineClient* Store::find(MachineClientKey key) const noexcept {
    if (!machines_.contains(key.machine)) {
      return nullptr;
    }

    const auto& client = clients_[key.machine.slot];

    return client && (*client)->key == key ? client->get() : nullptr;
  }

  GuiSession& Store::session() noexcept {
    return client(machines_.active()).session;
  }

  const GuiSession& Store::session() const noexcept {
    return client(machines_.active()).session;
  }

  RuntimeConnection& Store::connection() noexcept {
    return client(machines_.active()).connection;
  }

  const RuntimeConnection& Store::connection() const noexcept {
    return client(machines_.active()).connection;
  }

  MachineClientKey Store::admission(Machines::Slot slot) noexcept {
    return {.machine = machines_.token(slot), .generation = next_client_generation_++};
  }

  std::uint64_t Store::machineView() const noexcept {
    return machine_view_;
  }

  void Store::advanceMachineView() noexcept {
    ++machine_view_;
  }

}
