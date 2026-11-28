export module telar.gui.ui.app.chrome.components:component_surface_state;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  struct ComponentSlotState {
    using Clock = std::chrono::steady_clock;
    using Bar = application::components::RenderedContent<application::components::BarContent::capacity, ApplicationAllocator>;
    using Panel = application::components::RenderedContent<application::components::PanelContent::capacity, ApplicationAllocator>;
    // The last content the Lua thread rendered; the window reads only this copy.
    std::shared_ptr<const Bar> bar;
    std::shared_ptr<const Panel> panel;
    QVariantList nodes;
    QString error;
    Clock::time_point next;
    Clock::time_point clock_next = Clock::time_point::max();
    std::uint64_t revision = 0;
    std::uint64_t identity = 0;
    bool rendering = false;
  };

  struct ComponentSurfaceState {
    static constexpr std::size_t bar_slots = application::components::Definitions::positions;
    ds::Array<ComponentSlotState, bar_slots> bars;
    ComponentSlotState panel;
    ds::Option<std::size_t> open_panel = ds::none;
    // When the open panel last rendered, in milliseconds since the epoch; 0 before its first render.
    qint64 last_render_ms = 0;
    std::uint64_t generation = 0;
    // Changes on every reset, so a render started before it is dropped.
    std::uint64_t epoch = 0;
    std::uint64_t panel_identity = 0;
    QPointF panel_anchor{-1, -1};
  };

  struct ComponentCommandOwner {
    std::size_t index = 0;
    bool panel = false;
    std::uint64_t generation = 0;
    // Changes on every reset, so a render started before it is dropped.
    std::uint64_t epoch = 0;
    std::uint64_t panel_identity = 0;
    application::machines::MachineClientKey source;
    std::uint64_t runtime = 0;
  };

}
