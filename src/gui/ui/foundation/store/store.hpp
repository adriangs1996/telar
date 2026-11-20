#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/machines/machine_client.hpp"
#include <QObject>
#include <QtQml/qqmlregistration.h>
#include <concepts>
#include <cstdint>
#include <exception>
#include <utility>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  // The state the window shows, below every controller: the machines, the client connected to
  // each one, which of them is active, and the dialog open over the workbench. Controllers read
  // it; only the composition root that owns it decides when a client is admitted, replaced or
  // released.
  //
  // It is reactive by versions: whoever mutates the state touches the store, and once per turn of
  // the event loop the store emits changed(). Each subscriber compares the versions it read last
  // time with the current ones and recomputes only when something it uses moved.
  class Store final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(Store)
    QML_UNCREATABLE("The window owns its store")
    // QML names every enum value with its enum: Store.Dialog.palette, not Store.palette.
    Q_CLASSINFO("RegisterEnumClassesUnscoped", "false")

  public:
    // The dialog or line search open over the workbench, if any.
    enum class Dialog : quint8 {
      none,
      palette,
      paths,
      history,
      peek,
      machine,
      copy_search,
      new_workspace,
      rename_tab,
      rename_workspace,
      monitor,
    };
    Q_ENUM(Dialog)

    struct DialogState {
      Dialog kind = Dialog::none;
      // Changes with every dialog shown, and with each step of a multi-step prompt.
      std::uint64_t generation = 0;
      // The pane whose prompt line hosts the open history or path search, or 0 for the dialog.
      std::uint64_t line_search_pane = 0;
    };

    using Clients = MachineClients;

    Store() = default;
    ~Store() override = default;
    Store(const Store&) = delete;
    Store& operator=(const Store&) = delete;
    Store(Store&&) = delete;
    Store& operator=(Store&&) = delete;

    [[nodiscard]] application::machines::Machines& machinesMut() noexcept;
    [[nodiscard]] const application::machines::Machines& machines() const noexcept;
    [[nodiscard]] Clients& clientsMut() noexcept;
    [[nodiscard]] const Clients& clients() const noexcept;
    // The client of an occupied slot; an empty slot is a broken invariant and terminates.
    [[nodiscard]] const MachineClient& client(application::machines::Machines::Slot slot) const noexcept;
    [[nodiscard]] MachineClient& clientMut(application::machines::Machines::Slot slot) noexcept;
    // The client the key names, or null once its slot holds another client or none.
    [[nodiscard]] const MachineClient* find(application::machines::MachineClientKey key) const noexcept;
    [[nodiscard]] MachineClient* findMut(application::machines::MachineClientKey key) noexcept;
    [[nodiscard]] GuiSession& sessionMut() noexcept;
    [[nodiscard]] const GuiSession& session() const noexcept;
    [[nodiscard]] RuntimeConnection& connectionMut() noexcept;
    [[nodiscard]] const RuntimeConnection& connection() const noexcept;
    // The key for the next client admitted to the slot; each one gets a new generation.
    [[nodiscard]] application::machines::MachineClientKey admission(application::machines::Machines::Slot slot) noexcept;
    // Changes whenever the active session stops being the one the window showed.
    [[nodiscard]] std::uint64_t machineView() const noexcept;
    void advanceMachineView() noexcept;
    [[nodiscard]] const DialogState& dialog() const noexcept;
    // A new generation for the dialog about to show; what is presented for the previous one
    // stops matching.
    void advanceDialog() noexcept;
    void setDialog(Dialog kind, std::uint64_t line_search_pane) noexcept;
    // Marks the state as changed; the store emits changed() once, on the next turn of the event
    // loop, however many mutations touched it before.
    void touch();
    // Emits changed() now if the state was touched since the last time.
    void flush();
    // Starts a user interaction: interacting() lets the window cancel what the interaction
    // supersedes, before the mutation runs.
    void begin();
    // Ends a user interaction: interacted() runs its effects, and changed() follows at once, so
    // what the user did shows in the same turn. Runtime messages keep waiting for touch()'s flush.
    void commit();

    // Runs a user's mutation of the state as one interaction. A mutation that throws is not
    // committed: `failed` reports its error instead.
    template <std::invocable Mutation, std::invocable<const std::exception&> Failure>
    void interact(Mutation&& mutate, Failure&& failed) {
      begin();
      try {
        std::forward<Mutation>(mutate)();
      } catch (const std::exception& error) {
        std::forward<Failure>(failed)(error);

        return;
      }

      commit();
    }

  signals:
    void changed();
    void interacting();
    void interacted();

  private:
    application::machines::Machines machines_;
    // Each client reports back to the application that owns this store.
    tbc::val_self<Clients> clients_;
    std::uint64_t next_client_generation_ = 1;
    std::uint64_t machine_view_ = 0;
    DialogState dialog_;
    bool touched_ = false;
  };

}
