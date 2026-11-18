#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "store.hpp"
#include <QMetaObject>
#include <exception>

namespace telar::gui::qt {

  application::machines::Machines& Store::machinesMut() noexcept {
    return machines_;
  }

  const application::machines::Machines& Store::machines() const noexcept {
    return machines_;
  }

  Store::Clients& Store::clientsMut() noexcept {
    return clients_;
  }

  const Store::Clients& Store::clients() const noexcept {
    return clients_;
  }

  MachineClient& Store::client(application::machines::Machines::Slot slot) const noexcept {
    const auto& client = clients_[slot];
    if (!client) {
      std::terminate();
    }

    return **client;
  }

  MachineClient* Store::find(application::machines::MachineClientKey key) const noexcept {
    return findMachineClient(machines_, clients_, key);
  }

  GuiSession& Store::sessionMut() noexcept {
    return client(machines_.active()).session;
  }

  const GuiSession& Store::session() const noexcept {
    return client(machines_.active()).session;
  }

  RuntimeConnection& Store::connectionMut() noexcept {
    return client(machines_.active()).connection;
  }

  const RuntimeConnection& Store::connection() const noexcept {
    return client(machines_.active()).connection;
  }

  application::machines::MachineClientKey Store::admission(application::machines::Machines::Slot slot) noexcept {
    return {.machine = machines_.token(slot), .generation = next_client_generation_++};
  }

  std::uint64_t Store::machineView() const noexcept {
    return machine_view_;
  }

  void Store::advanceMachineView() noexcept {
    ++machine_view_;
  }

  const Store::DialogState& Store::dialog() const noexcept {
    return dialog_;
  }

  void Store::advanceDialog() noexcept {
    ++dialog_.generation;
  }

  void Store::setDialog(Dialog kind, std::uint64_t line_search_pane) noexcept {
    dialog_.kind = kind;
    dialog_.line_search_pane = line_search_pane;
  }

  void Store::touch() {
    if (touched_) {
      return;
    }

    touched_ = true;
    QMetaObject::invokeMethod(this, &Store::flush, Qt::QueuedConnection);
  }

  void Store::flush() {
    if (!touched_) {
      return;
    }

    touched_ = false;
    emit changed();
  }

  void Store::begin() {
    emit interacting();
  }

  void Store::commit() {
    emit interacted();
    // A flush already queued finds nothing left to report.
    touched_ = true;
    flush();
  }

}
