#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "machine_client_key.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/timing/window_frame_pacer.hpp"
#include <array>
#include <optional>

#pragma once

import telar.gui.text.notification_payload;
import telar.gui.application.host_effects;
import telar.gui.machines.picker;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

  struct MachineClient;

  // The client of each window slot, as the store holds them.
  using MachineClients = std::array<std::optional<Owned<MachineClient, ApplicationAllocator>>, Machines::capacity>;

  // What one machine's session asks of the desktop. Only the client the window holds for the
  // active machine reaches it: the others' notifications, sounds and input are dropped.
  class MachineEffects final : public HostEffects {
  public:
    // What the window lends the effects of every client it holds.
    struct Sinks {
      const Machines& machines;
      const MachineClients& clients;
      // The desktop's notifications and sounds.
      HostEffects& desktop;
      // The client whose sound plays, which the window tells when the sound ends.
      std::optional<MachineClientKey>& sound_owner;
      // The pacer of the window's frames, while the window has one.
      std::optional<WindowFramePacer<>>& frame_pacer;
    };

    MachineEffects(const Sinks& sinks, MachineClientKey source) noexcept
        : sinks_(sinks),
          source_(source) {}

    bool postNotification(const NotificationPayload& payload) override;
    bool playSound(AgentSound sound) override;
    void notePaneInput(FramePacer::Pane pane) noexcept override;

  private:
    // Whether the window still holds this client and shows its machine.
    [[nodiscard]] bool presented() const noexcept;

    Sinks sinks_;
    MachineClientKey source_;
  };

}
