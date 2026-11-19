#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "ui/foundation/config/configuration_source.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/process/command_process.hpp"
#include "ui/foundation/store/store.hpp"
#include <QByteArray>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::test {
  struct MachineWindow;
  struct MachineProfileWindow;
}

namespace telar::gui::qt {

  class Dialogs;
  class FramePresenter;
  class WindowDisplay;
  class WindowStatus;

  // What the machines need from the window that shows the active one, which only the window
  // can do. The window implements it; none of these calls is on the path of a runtime's payload.
  class MachinesHost {
  public:
    MachinesHost(const MachinesHost&) = delete;
    MachinesHost& operator=(const MachinesHost&) = delete;
    MachinesHost(MachinesHost&&) = delete;
    MachinesHost& operator=(MachinesHost&&) = delete;

    // A client was admitted to a slot: the window listens to what its runtime sends.
    virtual void attend(MachineClient& client) = 0;
    // The client is about to leave its slot: the window stops listening to its runtime.
    virtual void dismiss(MachineClient& client) = 0;
    // The active machine's panes lose the keys and the pointers they hold.
    virtual void releaseInput() = 0;
    // The active machine's view is gone: every projection forgets what it showed.
    virtual void forgetView() = 0;
    // Another machine became the active one: the window shows it.
    virtual void presentMachine() = 0;

  protected:
    MachinesHost() = default;
    ~MachinesHost() = default;
  };

  // The machines of the window: the client admitted to each one, its runtime connection, which
  // of them the window shows and the summary the machine list reads.
  //
  // It owns the clients' lifecycle in the store; the window implements MachinesHost for what a
  // change of the active machine asks of every part of it.
  class MachinesCoordinator final : public QObject {
    friend struct test::MachineWindow;
    friend struct test::MachineProfileWindow;

    Q_OBJECT
    QML_NAMED_ELEMENT(MachinesCoordinator)
    QML_UNCREATABLE("Use the window's machines")
    Q_PROPERTY(QVariantMap context READ context NOTIFY listChanged)

  public:
    MachinesCoordinator(ApplicationAllocator& memory, Store& store, ConfigurationSource& configuration, application::HostEffects& desktop, FramePresenter& frames, WindowDisplay& display, WindowStatus& status, Dialogs& dialogs, MachinesHost& host, QByteArray hostname, QObject* parent = nullptr);
    ~MachinesCoordinator() override = default;
    MachinesCoordinator(const MachinesCoordinator&) = delete;
    MachinesCoordinator& operator=(const MachinesCoordinator&) = delete;
    MachinesCoordinator(MachinesCoordinator&&) = delete;
    MachinesCoordinator& operator=(MachinesCoordinator&&) = delete;

    // Admits the local machine, whose panes start the user's login shell where the window was
    // launched.
    void initialize();
    // Connects the local machine to the runtime listening on the endpoint.
    void open(const QString& endpoint);
    // Closes every client's connection: the window is going away.
    void shutdown();
    // Hands every client the configuration that was loaded.
    void configure();
    void setDisplayRefresh(std::uint16_t fps);

    // Admits a new client to the slot, in place of the one it held.
    [[nodiscard]] MachineClient& createClient(application::machines::Machines::Slot slot);
    [[nodiscard]] const MachineClient& clientAt(application::machines::Machines::Slot slot) const noexcept;
    [[nodiscard]] MachineClient& clientAtMut(application::machines::Machines::Slot slot) noexcept;
    [[nodiscard]] const MachineClient* findClient(application::machines::MachineClientKey key) const noexcept;
    [[nodiscard]] MachineClient* findClientMut(application::machines::MachineClientKey key) noexcept;
    // Shows another machine in the window, if it is live.
    void select(application::machines::MachineToken target);
    // Shows the next live machine in the direction of `delta`.
    void move(int delta);
    // Brings the machine list's row up to date with what the client's session holds.
    void summarize(application::machines::MachineClientKey key);
    // The client's runtime went away: its session and its row say so.
    void markDisconnected(MachineClient& client);
    void publishList();
    // The desktop finished the sound a client's agent asked for.
    void soundFinished(ds::Option<CommandFailure> failure);

    [[nodiscard]] QVariantMap context() const;

  signals:
    // The window is about to show another machine.
    void selecting();
    // The window shows another machine, or another client of the same one.
    void changed();
    // A machine was added, removed, renamed or summarized again.
    void listChanged();
    // The active machine's link to its runtime moved.
    void linkChanged();

  private:
    void connectMachine(application::machines::Machines::Slot slot);
    void release(MachineClient& client);

    ApplicationAllocator& memory_;
    Store& store_;
    ConfigurationSource& configuration_source_;
    application::HostEffects& desktop_;
    FramePresenter& frames_;
    WindowDisplay& display_;
    WindowStatus& status_;
    Dialogs& dialogs_;
    MachinesHost& host_;
    QByteArray hostname_;
    // The client whose agent the desktop's one sound plays for.
    ds::Cell<ds::Option<application::machines::MachineClientKey>> sound_owner_;
  };

}
