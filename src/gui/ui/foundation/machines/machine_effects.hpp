#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/timing/window_frame_pacer.hpp"
#include <array>
#include <optional>

#pragma once

import telar.gui.foundation.system;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  struct MachineClient;

  // The client of each window slot, as the store holds them.
  using MachineClients = ds::Array<ds::Option<ds::Box<MachineClient, ApplicationAllocator>>, application::machines::Machines::capacity>;

  // What one machine's session asks of the desktop. Only a client the window presents, the one it
  // holds for the active machine, reaches it: the others' notifications, sounds and input are dropped.
  // The window tells the effects when that changes, as Rust pushes state into what it owns rather
  // than let it borrow its owner.
  class MachineEffects final : public application::HostEffects {
  public:
    // What the window lends the effects of every client it holds.
    struct Sinks {
      // The desktop's notifications and sounds.
      HostEffects& desktop;
      // The client whose sound plays, which the window tells when the sound ends.
      const ds::Cell<ds::Option<application::machines::MachineClientKey>>& sound_owner;
      // The pacer of the window's frames, while the window has one.
      ds::Option<WindowFramePacer<>>& frame_pacer;
    };

    // Keeps what the sinks refer to, region `a`, not the sinks themselves.
    MachineEffects(tbc::holds<const Sinks&, tbc::lt::a> sinks, application::machines::MachineClientKey source) noexcept
        : sinks_(sinks),
          source_(source) {}

    void setPresented(bool presented) noexcept {
      presented_ = presented;
    }

    bool postNotification(const NotificationPayload& payload) override;
    bool playSound(AgentSound sound) override;
    void notePaneInput(application::window::FramePacer::Pane pane) noexcept override;

  private:
    tbc::view<Sinks, tbc::lt::a> sinks_;
    application::machines::MachineClientKey source_;
    bool presented_ = false;
  };

}
