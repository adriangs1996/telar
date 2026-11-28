export module telar.gui.ui.app.chrome.activity:activity_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.design.elements;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.base.memory.containers;

export namespace telar::gui::qt {

  // The sidebar's activity: the agents and worktree commands of every live machine, then the
  // active machine's other processes, with what a mod draws on each card; and the card the
  // pointer is over.
  //
  // It reads the machines and their sessions in the store. Each synchronize() compares the
  // versions it projected last with the current ones and rebuilds the records only when one
  // moved. Selecting or peeking a card acts on a session, so the window does it with what this
  // controller answers.
  class [[qt::object, qt_qml_named("ActivityController"), qt_qml_uncreatable("Use the window's activity")]] ActivityController final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);
    enum class QmlIsUncreatable : quint8 {
      yes = 1,
    };
    void qt_qmlMarker_uncreatable();

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
    [[qt::invokable]] void hover(const QString& identity, QQuickItem* card = nullptr);
    void clearHover();
    // Marks a card hovered for a peek opened from it, unless the pointer moved since.
    void showHover(const QString& identity, std::uint64_t pointer_revision);
    void observePointer(bool hover_input = true, ds::Option<QPointF> position = {});
    // Counts pointer moves, so a peek opened late knows whether the pointer moved since.
    [[nodiscard]] std::uint64_t pointerRevision() const noexcept;
    void setWindow(QQuickWindow* window) noexcept;

    [[qt::signal]] void agentCountChanged();
    [[qt::signal]] void hoveredChanged();

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

      [[tbc::hot_path]] inline bool operator==(const SourceVersion& other) const noexcept {
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

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("rows", &ActivityController::rows).constant(),
        telar::qt::property("agentCount", &ActivityController::agentCount).withNotify(&ActivityController::agentCountChanged),
        telar::qt::property("hovered", &ActivityController::hovered).withNotify(&ActivityController::hoveredChanged)
    );
  };

}
