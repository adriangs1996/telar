export module telar.gui.ui.app.chrome.tabs:tab_strip_layout;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] TabStripLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit TabStripLayout(QQuickItem* parent = nullptr);
    ~TabStripLayout() override;
    TabStripLayout(const TabStripLayout&) = delete;
    TabStripLayout& operator=(const TabStripLayout&) = delete;
    TabStripLayout(TabStripLayout&&) = delete;
    TabStripLayout& operator=(TabStripLayout&&) = delete;
    void setContext(std::uint64_t machine_view, ds::Option<WorkspaceLocation> workspace);
    [[nodiscard]] QAbstractItemModel* model() const noexcept;
    void setModel(QAbstractItemModel* model);
    [[nodiscard]] QAbstractItemModel* items() noexcept;
    [[nodiscard]] QFont font() const;
    void setFont(const QFont& font);
    [[nodiscard]] qreal pixelSize() const noexcept;
    void setPixelSize(qreal size);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    [[nodiscard]] bool hovered() const noexcept;
    void setHovered(bool hovered);

    [[tbc::hot_path, nodiscard]] inline QRectF stripBounds() const noexcept {
      return strip_bounds_;
    }

    [[tbc::hot_path, nodiscard]] inline QRectF selectionBounds() const noexcept {
      return selection_bounds_;
    }

    [[nodiscard]] QRectF dropMarker() const noexcept;
    [[nodiscard]] QRectF draggedBounds() const noexcept;
    [[nodiscard]] QString hoveredTab() const;
    void setPointerHover(ds::Option<std::uint64_t> tab);

    [[tbc::hot_path, nodiscard]] inline bool transitioning() const noexcept {
      return next_sample_ns_.hasValue();
    }

    [[nodiscard]] std::size_t dropSlots(std::span<application::workbench::TabDropSlot> output) const;
    void setDrag(ds::Option<application::workbench::TabDragMove> preview, ds::Option<std::uint64_t> dragged, QPointF pointer, qreal grab_offset);
    [[nodiscard]] QVariantMap counter() const;
    [[nodiscard]] QRectF plus() const noexcept;
    void setPlus(const QRectF& plus);
    [[nodiscard]] QVariantMap style() const;

    [[qt::signal]] void plusChanged();
    [[qt::signal]] void modelChanged();
    [[qt::signal]] void fontChanged();
    [[qt::signal]] void ratioChanged();
    [[qt::signal]] void hoveredChanged();
    [[qt::signal]] void layoutChanged();
    [[qt::signal]] void pointerHoverChanged();

  protected:
    void updatePolish() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    friend class WindowAnimationItems<TabStripLayout>;
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
    void sample(std::uint64_t now_ns);
    void bindClock();
    static constexpr std::size_t model_connection_count = 6;
    [[nodiscard]] float captionAdvance(const QString& label);

    // The row the tabs are laid out in: where it starts, how tall it is and how wide it may grow.
    struct StripRow {
      float top = 0;
      float height = 0;
      float available = 0;
    };

    void rebuild();
    // Forgets the layout: the strip has no room to lay tabs out in.
    void clearLayout();
    // Places the counter of the hidden tabs after `left`, if any are; returns where the strip ends.
    [[nodiscard]] float placeCounter(const QList<QVariantMap>& records, const application::workbench::TabStripGeometry::Plan& plan, const application::workbench::TabStripGeometry::Metrics& metrics, StripRow row, float left);
    // Moves the selection's highlight toward the selected tab, in device pixels at `density`.
    void placeSelection(ds::Option<Rect> selection, bool dragging, application::workbench::TabMotionFrame& frame, qreal density);
    void finishMotions(const application::workbench::TabMotionFrame& frame);
    void raiseDraggedSlot();
    [[nodiscard]] QRectF placeTab(std::uint64_t id, QRectF bounds, application::workbench::TabMotionFrame& frame);
    [[nodiscard]] QVariantList placeCards(const QVariantMap& tab, application::workbench::TabMotionFrame& frame);
    [[nodiscard]] application::workbench::TabStripGeometry::Plan measureTabs(QList<QVariantMap>& records, std::span<application::workbench::TabStripGeometry::Measure> sizes, const application::workbench::TabStripGeometry::Room& room);

    QPointer<WindowAnimationClock> clock_;
    QMetaObject::Connection frame_connection_;
    application::workbench::TabMotions motions_;
    application::workbench::TabCardMotions card_motions_;
    QRectF plus_;
    ds::Option<application::workbench::TabMotion> selection_motion_;
    ds::Option<WorkspaceLocation> workspace_;
    std::uint64_t machine_view_ = 0;
    ds::Option<std::uint64_t> next_sample_ns_;
    bool frame_requested_ = false;
    QPointer<QAbstractItemModel> model_;
    ds::Array<QMetaObject::Connection, model_connection_count> connections_;
    ListModel items_{this};
    QFont font_;
    std::shared_ptr<ChromeFonts> fonts_;
    qreal pixel_size_ = 0;
    qreal ratio_ = 1;
    bool hovered_ = false;
    QString anchor_;
    QRectF strip_bounds_;
    QRectF selection_bounds_;
    QRectF drop_marker_;
    QRectF dragged_bounds_;
    ds::Array<application::workbench::TabDropSlot, application::workbench::TabDropSlots::capacity> drop_slots_{};
    std::size_t drop_slot_count_ = 0;
    ds::Option<application::workbench::TabDragMove> drag_preview_;
    ds::Option<std::uint64_t> dragged_;
    QPointF drag_pointer_;
    qreal drag_grab_offset_ = 0;
    QVariantMap counter_;
    ds::Option<std::uint64_t> hovered_tab_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("model", &TabStripLayout::model).withWrite(&TabStripLayout::setModel).withNotify(&TabStripLayout::modelChanged),
        telar::qt::property("items", &TabStripLayout::items).constant(),
        telar::qt::property("font", &TabStripLayout::font).withWrite(&TabStripLayout::setFont).withNotify(&TabStripLayout::fontChanged),
        telar::qt::property("pixelSize", &TabStripLayout::pixelSize).withWrite(&TabStripLayout::setPixelSize).withNotify(&TabStripLayout::fontChanged),
        telar::qt::property("ratio", &TabStripLayout::ratio).withWrite(&TabStripLayout::setRatio).withNotify(&TabStripLayout::ratioChanged),
        telar::qt::property("hovered", &TabStripLayout::hovered).withWrite(&TabStripLayout::setHovered).withNotify(&TabStripLayout::hoveredChanged),
        telar::qt::property("stripBounds", &TabStripLayout::stripBounds).withNotify(&TabStripLayout::layoutChanged),
        telar::qt::property("selectionBounds", &TabStripLayout::selectionBounds).withNotify(&TabStripLayout::layoutChanged),
        telar::qt::property("dropMarker", &TabStripLayout::dropMarker).withNotify(&TabStripLayout::layoutChanged),
        telar::qt::property("draggedBounds", &TabStripLayout::draggedBounds).withNotify(&TabStripLayout::layoutChanged),
        telar::qt::property("hoveredTab", &TabStripLayout::hoveredTab).withNotify(&TabStripLayout::pointerHoverChanged),
        telar::qt::property("transitioning", &TabStripLayout::transitioning).withNotify(&TabStripLayout::layoutChanged),
        telar::qt::property("counter", &TabStripLayout::counter).withNotify(&TabStripLayout::layoutChanged),
        telar::qt::property("plus", &TabStripLayout::plus).withWrite(&TabStripLayout::setPlus).withNotify(&TabStripLayout::plusChanged),
        telar::qt::property("style", &TabStripLayout::style).withNotify(&TabStripLayout::ratioChanged)
    );
  };

}
