export module telar.gui.ui.app.panes:pane_motion_layout;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.application;
import telar.base.ds;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] PaneMotionLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit PaneMotionLayout(QQuickItem* parent = nullptr);
    ~PaneMotionLayout() override;
    PaneMotionLayout(const PaneMotionLayout&) = delete;
    PaneMotionLayout& operator=(const PaneMotionLayout&) = delete;
    PaneMotionLayout(PaneMotionLayout&&) = delete;
    PaneMotionLayout& operator=(PaneMotionLayout&&) = delete;

    [[tbc::hot_path, nodiscard]] inline QAbstractItemModel* model() const noexcept {
      return model_;
    }

    void setModel(QAbstractItemModel* model);

    [[tbc::hot_path, nodiscard]] inline QAbstractItemModel* items() noexcept {
      return &items_;
    }

    [[tbc::hot_path, nodiscard]] inline bool motionEnabled() const noexcept {
      return enabled_;
    }

    void setMotionEnabled(bool enabled);

    [[qt::signal]] void modelChanged();
    [[qt::signal]] void motionEnabledChanged();

  protected:
    void updatePolish() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    friend class WindowAnimationItems<PaneMotionLayout>;
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
    void sample(std::uint64_t now_ns);
    void bindClock();

    // One per model signal that moves the panes: data, insert, remove, move, reset and destruction.
    static constexpr std::size_t model_connection_count = 6;

    QPointer<QAbstractItemModel> model_;
    ds::Array<QMetaObject::Connection, model_connection_count> connections_;
    ListModel items_{this};
    application::workbench::PaneMotions motions_;
    QString context_;
    QPointer<WindowAnimationClock> clock_;
    QMetaObject::Connection frame_connection_;
    ds::Option<std::uint64_t> next_sample_ns_;
    bool frame_requested_ = false;
    bool immediate_ = true;
    bool enabled_ = true;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("model", &PaneMotionLayout::model).withWrite(&PaneMotionLayout::setModel).withNotify(&PaneMotionLayout::modelChanged),
        telar::qt::property("items", &PaneMotionLayout::items).constant(),
        telar::qt::property("animationsEnabled", &PaneMotionLayout::motionEnabled).withWrite(&PaneMotionLayout::setMotionEnabled).withNotify(&PaneMotionLayout::motionEnabledChanged)
    );
  };

}
