export module telar.gui.ui.app.panes:panes_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.design.elements;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.store;
import telar.gui.foundation.model;
import telar.base.ds;
import telar.base.memory.allocators;

export namespace telar::gui::qt {

  // The panes of the active tab, laid out in the workbench, with their headers and what a mod
  // draws in them, and the dividers between them.
  //
  // It reads the active session in the store. Each synchronize() compares what it projected last
  // with the current inputs and rebuilds the records only when one moved. The viewport revision
  // covers the workbench geometry and the rows an attachment shelf reserves under a pane.
  class [[qt::object, qt_qml_named("PanesController"), qt_qml_uncreatable("Use the window's panes")]] PanesController final : public QObject {
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

    PanesController(Store& store, ElementSlots& elements, QObject* parent = nullptr);
    ~PanesController() override = default;
    PanesController(const PanesController&) = delete;
    PanesController& operator=(const PanesController&) = delete;
    PanesController(PanesController&&) = delete;
    PanesController& operator=(PanesController&&) = delete;

    void synchronize();
    // The active session is about to change: nothing projected belongs to the next one.
    void forget();
    // Device pixels per logical pixel of the terminal grid the records are measured in.
    void setScale(double scale) noexcept;
    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] QAbstractItemModel* dividers() noexcept;
    // Drags the divider whose key is `index` to (x, y), in the logical pixels the records are laid
    // out in; `commit` on release keeps the layout.
    [[qt::invokable]] void resizeDivider(int index, qreal x, qreal y, bool commit);
    // How many synchronize() calls rebuilt the records, for tests and probes that check what a
    // change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

    [[qt::signal]] void failed(const QString& message);

  private:
    struct Inputs {
      std::uint64_t machine_view = 0;
      std::uint64_t runtime_generation = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t panes = 0;
      std::uint64_t host = 0;
      std::uint64_t configuration = 0;
      std::uint64_t chrome = 0;
      std::uint64_t agents = 0;
      std::uint64_t graphics = 0;
      std::uint64_t elements = 0;
      std::uint64_t viewport = 0;
      double scale = 1;

      [[tbc::hot_path]] inline bool operator==(const Inputs& other) const {
        return machine_view == other.machine_view && runtime_generation == other.runtime_generation && active_tab == other.active_tab && panes == other.panes && host == other.host && configuration == other.configuration && chrome == other.chrome && agents == other.agents && graphics == other.graphics && elements == other.elements && viewport == other.viewport && std::equal_to<>{}(scale, other.scale);
      }
    };

    [[nodiscard]] Inputs inputs() const;
    [[nodiscard]] QVariantList fullscreenEntries(const Tab<Memory>& tab) const;

    Store& store_;
    ElementSlots& elements_;
    ListModel rows_;
    ListModel dividers_;
    double scale_ = 1;
    ds::Option<Inputs> synchronized_;
    std::uint64_t rebuilds_ = 0;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("rows", &PanesController::rows).constant(),
        telar::qt::property("dividers", &PanesController::dividers).constant()
    );
  };

}
