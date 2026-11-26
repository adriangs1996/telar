#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/design/elements/element_slots.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.base.memory.containers;

namespace telar::gui::qt {

  // The sidebar's activity: the agents and worktree commands of every live machine, then the
  // active machine's other processes, with what a mod draws on each card; and the card the
  // pointer is over.
  //
  // It reads the machines and their sessions in the store. Each synchronize() compares the
  // versions it projected last with the current ones and rebuilds the records only when one
  // moved. Selecting or peeking a card acts on a session, so the window does it with what this
  // controller answers.
  class ActivityController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(ActivityController)
    QML_UNCREATABLE("Use the window's activity")
    Q_PROPERTY(QAbstractItemModel* rows READ rows CONSTANT)
    Q_PROPERTY(int agentCount READ agentCount NOTIFY agentCountChanged)
    Q_PROPERTY(QString hovered READ hovered NOTIFY hoveredChanged)

  public:
    ActivityController(Store& store, ElementSlots& elements, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~ActivityController() override = default;
    ActivityController(const ActivityController&) = delete;
    ActivityController& operator=(const ActivityController&) = delete;
    ActivityController(ActivityController&&) = delete;
    ActivityController& operator=(ActivityController&&) = delete;

    void synchronize();
    // The active machine is about to change: its cards go, and the next pass rebuilds them.
    void forget();
    // A mod drew new content: the next pass rebuilds every card.
    void invalidate() noexcept;
    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] const ListModel& records() const noexcept;
    [[nodiscard]] int agentCount() const noexcept;
    // How many synchronize() calls rebuilt the records, for tests and probes that check what a
    // change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

    // What the card with this identity points at, while it is listed.
    [[nodiscard]] const application::machines::MachineActivityTarget* target(const QString& identity) const;
    [[nodiscard]] static QString identity(const application::machines::MachineActivityTarget& target);

    [[nodiscard]] QString hovered() const;
    // The pointer entered a card, or left one when the identity is empty. Hover input that the
    // pointer did not produce, or a card it is not over, is ignored.
    Q_INVOKABLE void hover(const QString& identity, QQuickItem* card = nullptr);
    void clearHover();
    // Marks a card hovered for a peek opened from it, unless the pointer moved since.
    void showHover(const QString& identity, std::uint64_t pointer_revision);
    void observePointer(bool hover_input = true, ds::Option<QPointF> position = {});
    // Counts pointer moves, so a peek opened late knows whether the pointer moved since.
    [[nodiscard]] std::uint64_t pointerRevision() const noexcept;
    void setWindow(QQuickWindow* window) noexcept;

  signals:
    void agentCountChanged();
    void hoveredChanged();

  private:
    struct SourceVersion {
      application::machines::MachineClientKey source;
      std::uint64_t runtime_generation;
      std::uint64_t agents;
      std::uint64_t workspaces;
      std::uint64_t panes;
      // The facts of those panes: their commands, directories and repositories.
      std::uint64_t facts;
      bool connected;
      runtime::FixedText<application::machines::MachineLimits::label_bytes> label;

      bool operator==(const SourceVersion& other) const noexcept {
        return source == other.source && runtime_generation == other.runtime_generation && agents == other.agents && workspaces == other.workspaces && panes == other.panes && facts == other.facts && connected == other.connected && label.view() == other.label.view();
      }
    };

    struct Selection {
      application::machines::Machines::Slot slot;
      std::uint64_t tabs;
      std::uint64_t panes;

      bool operator==(const Selection&) const noexcept = default;
    };

    struct RowTarget {
      QString identity;
      application::machines::MachineActivityTarget target;
    };

    Store& store_;
    ElementSlots& elements_;
    ApplicationAllocator& memory_;
    ListModel rows_;
    ds::Array<ds::Option<SourceVersion>, application::machines::Machines::capacity> versions_;
    ds::Option<Selection> selection_;
    ds::Vec<RowTarget, ApplicationAllocator> targets_;
    int agent_count_ = 0;
    std::uint64_t rebuilds_ = 0;
    QPointer<QQuickWindow> window_;
    QString hovered_;
    QPointer<QQuickItem> hover_card_;
    ds::Option<QPointF> pointer_position_;
    bool hover_pending_ = false;
    bool hover_seen_ = false;
    bool hover_reset_queued_ = false;
    std::uint64_t pointer_revision_ = 0;
  };

}
