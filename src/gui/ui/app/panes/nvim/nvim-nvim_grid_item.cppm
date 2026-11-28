export module telar.gui.ui.app.panes.nvim:nvim_grid_item;

import std;
import telar.gui.qt;
import :nvim_item;
import telar.gui.ui.kit.cell_scene;
import telar.gui.ui.kit.motion;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  // The cells of one grid of an editor, drawn as a terminal's rows are: QML places one over
  // each grid the editor has, and frames the floats.
  class [[qt::object, qt_qml_named("NvimGrid")]] NvimGridItem : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NvimGridItem(QQuickItem* parent = nullptr);

    [[tbc::hot_path]] [[nodiscard]] inline NvimItem* editor() const noexcept {
      return editor_;
    }

    void setEditor(NvimItem* editor);

    [[tbc::hot_path]] [[nodiscard]] inline int gridId() const noexcept {
      return static_cast<int>(grid_id_);
    }

    void setGridId(int grid_id);

    [[qt::signal]] void editorChanged();
    [[qt::signal]] void gridIdChanged();

  protected:
    void updatePolish() override;
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    [[nodiscard]] const application::nvim::Grid* grid() const noexcept;
    void refresh();
    // A scroll moved the grid's rows `distance` pixels up: they are drawn where they were and
    // slide to their places, the rows that left sliding out ahead of them.
    void slide(double distance, const application::nvim::Grid& current);
    // One display frame of a slide.
    void advance();
    void rest();
    // The rows drawn while a slide lasts: the grid's own and the ones that left it.
    void composeRows();
    [[nodiscard]] ScrollTime now() const;

    QPointer<NvimItem> editor_;
    std::uint32_t grid_id_ = 0;

    // What the item last drew: its screen's revision, how cells are drawn, and whether the
    // cursor was lit and the editor had the keyboard. A frame that changes none of them leaves
    // the item as it is.
    struct Drawn {
      std::uint64_t revision = 0;
      std::uint64_t appearance = 0;
      // The default grid's cells left empty follow the windows and the status line.
      std::uint64_t layout = 0;
      std::int32_t status_row = -1;

      bool operator==(const Drawn&) const = default;
    };

    ds::Option<Drawn> drawn_;
    // How far the rows are from their places, as a position `reach_` pixels above zero: at
    // `reach_` they are in place, past it they still have to come up.
    ScrollMotion motion_;
    double reach_ = 0;
    // The grid's `moved` when the item last looked: its change is a scroll to slide.
    ds::Option<std::int64_t> moved_seen_;
    QMetaObject::Connection frames_;
    // Whether the window's frames are counted for a slide.
    bool counting_ = false;
    QList<TerminalRow> drawn_rows_;
    qreal shift_ = 0;
    // What the default grid's rows are drawn from where cells are covered: copies of the rows
    // covered in part, with the covered cells empty, the one empty row of the ones covered
    // whole, and the flags of the row being covered.
    QList<CellValue> covered_cells_;
    QList<CellValue> blank_row_;
    QList<Byte> covered_;
    // The revision of each row when its fonts were last asked for.
    QList<std::uint64_t> font_row_revisions_;
    std::uint64_t font_appearance_ = 0;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("editor", &NvimGridItem::editor).withWrite(&NvimGridItem::setEditor).withNotify(&NvimGridItem::editorChanged),
        telar::qt::property("gridId", &NvimGridItem::gridId).withWrite(&NvimGridItem::setGridId).withNotify(&NvimGridItem::gridIdChanged)
    );
  };

}
