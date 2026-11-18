#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "ui/foundation/config/lua_host.hpp"
#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <array>
#include <cstdint>
#include <functional>
#include <initializer_list>
#include <memory>
#include <optional>
#include <span>

#pragma once

import telar.gui.application;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::qt {

  class ConfigurationSource;

  // The window's side of the mod slots. A projection pass attaches each slot instance it shows
  // with an item, the JSON a slot function receives; an instance renders on the Lua thread only
  // when its item changed, and its last content stays on screen until the next one arrives.
  class ElementSlots final : public QObject {
    Q_OBJECT

  public:
    using Rendered = application::components::RenderedElements<ApplicationAllocator>;
    using Context = std::function<application::components::Context()>;

    struct Instance {
      application::components::Slot slot = application::components::Slot::count;
      QString key;
      std::uint64_t id = 0;
      QByteArray item;
      std::shared_ptr<const Rendered> rendered;
      QVariantList nodes;
      QString error;
      std::uint64_t revision = 0;
      unsigned failures = 0;
      bool rendering = false;
      bool dirty = false;
      bool seen = false;
    };

    static constexpr unsigned failure_limit = 3;
    // The slot families, each projected by its own pass.
    static constexpr ds::Array tab_slots{application::components::Slot::tab, application::components::Slot::tab_cards, application::components::Slot::tab_title, application::components::Slot::tab_path, application::components::Slot::tab_activity};
    static constexpr ds::Array pane_slots{application::components::Slot::pane_header, application::components::Slot::pane_mark, application::components::Slot::pane_program, application::components::Slot::pane_context, application::components::Slot::pane_status, application::components::Slot::pane_progress, application::components::Slot::pane_actions};
    static constexpr ds::Array agent_slots{application::components::Slot::agent_card, application::components::Slot::agent_mark, application::components::Slot::agent_title, application::components::Slot::agent_project, application::components::Slot::agent_status};
    static constexpr ds::Array bar_slots{application::components::Slot::top_bar, application::components::Slot::bottom_bar};

    ElementSlots(ConfigurationSource& source, Context context, QObject* parent = nullptr);
    [[nodiscard]] bool configured(application::components::Slot slot) const noexcept;
    [[nodiscard]] bool active() const noexcept;
    // Forgets every instance when `generation` is new: it owns new functions.
    void adopt(std::uint64_t generation);
    // A pass over one family: begin() before it attaches, finish() after; finish() drops the
    // family's instances the pass did not attach. Other families keep theirs.
    void begin(std::span<const application::components::Slot> family);
    // The content a record carries for `slot`; empty while QML should draw the piece.
    [[nodiscard]] QVariantMap attach(application::components::Slot slot, const QString& key, const QVariantMap& item);
    // The content of every slot in `family` a mod draws for one record, by slot name; empty when
    // no mod draws any.
    [[nodiscard]] QVariantMap elements(std::span<const application::components::Slot> family, const QString& key, const QVariantMap& item);
    void finish(std::span<const application::components::Slot> family);
    // Changes whenever what the instances draw may have changed: a render settled, or the
    // instances were forgotten or invalidated. A pass that saw this revision has nothing new.
    [[nodiscard]] std::uint64_t revision() const noexcept;
    [[nodiscard]] const Instance* find(const QString& slot, const QString& key) const;
    // Reruns every instance, after a click function may have changed what the mod draws.
    void invalidate();

    [[nodiscard]] bool owns(const application::components::ResolvedActions<ApplicationAllocator>& actions) const noexcept;

    // The item each family of slots receives, built from the record QML already gets.
    [[nodiscard]] static QVariantMap tabItem(const QVariantMap& record, int position);
    [[nodiscard]] static QVariantMap paneItem(const QVariantMap& pane, const QVariantMap& chrome);
    [[nodiscard]] static QVariantMap agentItem(const QVariantMap& record);
    [[nodiscard]] static std::uint64_t identity(application::components::Slot slot, const QString& key) noexcept;
    [[nodiscard]] static QVariantList project(const Rendered& rendered, const Theme& theme);

  signals:
    // Rendered content changed; the next projection pass carries it.
    void contentChanged();
    // An instance failed `failure_limit` times in a row and fell back to the QML piece.
    void failed(const QString& message);

  private:
    void render(std::uint64_t id);

    ConfigurationSource& source_;
    Context context_;
    QHash<std::uint64_t, Instance> instances_;
    QTimer settle_;
    std::uint64_t next_revision_ = 0;
    std::uint64_t epoch_ = 0;
    std::uint64_t generation_ = 0;
    std::uint64_t revision_ = 0;
  };

}
