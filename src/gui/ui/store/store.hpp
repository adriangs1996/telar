#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "telar_base/memory/allocator.hpp"
#include "ui/machines/machine_client.hpp"
#include "ui/machines/machine_client_key.hpp"
#include <QObject>
#include <array>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.machines.picker;

namespace telar::gui::qt {

  // The state the window shows, below every controller: the machines, the client connected to
  // each one, and which of them is active. Controllers read it; only the composition root that
  // owns it decides when a client is admitted, replaced or released.
  class Store final : public QObject {
    Q_OBJECT

  public:
    using Clients = std::array<std::optional<Owned<MachineClient, ApplicationAllocator>>, Machines::capacity>;

    Store() = default;
    ~Store() override = default;
    Store(const Store&) = delete;
    Store& operator=(const Store&) = delete;
    Store(Store&&) = delete;
    Store& operator=(Store&&) = delete;

    [[nodiscard]] Machines& machines() noexcept;
    [[nodiscard]] const Machines& machines() const noexcept;
    [[nodiscard]] Clients& clients() noexcept;
    [[nodiscard]] const Clients& clients() const noexcept;
    // The client of an occupied slot; an empty slot is a broken invariant and terminates.
    [[nodiscard]] MachineClient& client(Machines::Slot slot) const noexcept;
    // The client the key names, or null once its slot holds another client or none.
    [[nodiscard]] MachineClient* find(MachineClientKey key) const noexcept;
    [[nodiscard]] GuiSession& session() noexcept;
    [[nodiscard]] const GuiSession& session() const noexcept;
    [[nodiscard]] RuntimeConnection& connection() noexcept;
    [[nodiscard]] const RuntimeConnection& connection() const noexcept;
    // The key for the next client admitted to the slot; each one gets a new generation.
    [[nodiscard]] MachineClientKey admission(Machines::Slot slot) noexcept;
    // Changes whenever the active session stops being the one the window showed.
    [[nodiscard]] std::uint64_t machineView() const noexcept;
    void advanceMachineView() noexcept;

  private:
    Machines machines_;
    // Each client reports back to the application that owns this store.
    tbc::view<Clients, tbc::lt::self> clients_;
    std::uint64_t next_client_generation_ = 1;
    std::uint64_t machine_view_ = 0;
  };

}
