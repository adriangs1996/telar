#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
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

import telar.gui.components.builtin_content;
import telar.gui.components.configuration;
import telar.gui.foundation.core;

namespace telar::gui::qt {

  class ConfigurationSource;

  // The window's side of the mod slots. A projection pass attaches each slot instance it shows
  // with an item, the JSON a slot function receives; an instance renders on the Lua thread only
  // when its item changed, and its last content stays on screen until the next one arrives.
  class ElementSlots final : public QObject {
    Q_OBJECT

  public:
    using Rendered = RenderedElements<ApplicationAllocator>;
    using Context = std::function<components::Context()>;

    struct Instance {
      components::Slot slot = components::Slot::count;
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
    static constexpr std::array tab_slots{components::Slot::tab, components::Slot::tab_cards, components::Slot::tab_title, components::Slot::tab_path, components::Slot::tab_activity};
    static constexpr std::array pane_slots{components::Slot::pane_header, components::Slot::pane_mark, components::Slot::pane_program, components::Slot::pane_context, components::Slot::pane_status, components::Slot::pane_progress, components::Slot::pane_actions};
    static constexpr std::array agent_slots{components::Slot::agent_card, components::Slot::agent_mark, components::Slot::agent_title, components::Slot::agent_project, components::Slot::agent_status};
    static constexpr std::array bar_slots{components::Slot::top_bar, components::Slot::bottom_bar};

    ElementSlots(ConfigurationSource& source, Context context, QObject* parent = nullptr);
    [[nodiscard]] bool configured(components::Slot slot) const noexcept;
    [[nodiscard]] bool active() const noexcept;
    // Forgets every instance when `generation` is new: it owns new functions.
    void adopt(std::uint64_t generation);
    // A pass over one family: begin() before it attaches, finish() after; finish() drops the
    // family's instances the pass did not attach. Other families keep theirs.
    void begin(std::span<const components::Slot> family);
    // The content a record carries for `slot`; empty while QML should draw the piece.
    [[nodiscard]] QVariantMap attach(components::Slot slot, const QString& key, const QVariantMap& item);
    // The content of every slot in `family` a mod draws for one record, by slot name; empty when
    // no mod draws any.
    [[nodiscard]] QVariantMap elements(std::span<const components::Slot> family, const QString& key, const QVariantMap& item);
    void finish(std::span<const components::Slot> family);
    // Changes whenever what the instances draw may have changed: a render settled, or the
    // instances were forgotten or invalidated. A pass that saw this revision has nothing new.
    [[nodiscard]] std::uint64_t revision() const noexcept;
    [[nodiscard]] const Instance* find(const QString& slot, const QString& key) const;
    // Reruns every instance, after a click function may have changed what the mod draws.
    void invalidate();

    [[nodiscard]] bool owns(const ResolvedActions<ApplicationAllocator>& actions) const noexcept;

    // The item each family of slots receives, built from the record QML already gets.
    [[nodiscard]] static QVariantMap tabItem(const QVariantMap& record, int position);
    [[nodiscard]] static QVariantMap paneItem(const QVariantMap& pane, const QVariantMap& chrome);
    [[nodiscard]] static QVariantMap agentItem(const QVariantMap& record);
    [[nodiscard]] static std::uint64_t identity(components::Slot slot, const QString& key) noexcept;
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
