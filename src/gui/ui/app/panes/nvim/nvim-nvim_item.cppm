export module telar.gui.ui.app.panes.nvim:nvim_item;

import std;
import telar.gui.qt;
import :nvim_controller;
import :predictive_echo;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  // One editor pane: a Neovim the runtime runs, drawn natively. It takes the keys, the pointer
  // and the input method for the pane, gives the editor the cells that fit its view, and tells
  // QML where each grid goes and what Neovim's native surfaces show. Each grid is drawn by an
  // NvimGridItem QML places over it.
  class [[qt::object, qt_qml_named("NvimEditor")]] NvimItem : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    // The grids, one record each: where it is drawn, in this item's coordinates, and what it is.
    // Where the cursor's cell is, for what follows it: a trail, the input method.
    // The cursor the pane draws in a layer of its own, over the cells: visible, lit (its blink),
    // shape ("block", "bar" or "underline"), percentage of the cell it covers, the text of its
    // cell and whether that is wide, and its colors.
    // Whether Neovim has drawn its first frame.
    // The surfaces Neovim leaves to its UI, each as QML draws it.
    explicit NvimItem(QQuickItem* parent = nullptr);
    ~NvimItem() override;

    NvimItem(const NvimItem&) = delete;
    NvimItem& operator=(const NvimItem&) = delete;
    NvimItem(NvimItem&&) = delete;
    NvimItem& operator=(NvimItem&&) = delete;

    [[tbc::hot_path]] [[nodiscard]] inline NvimController* controller() const noexcept {
      return controller_;
    }

    void setController(NvimController* controller);

    [[tbc::hot_path]] [[nodiscard]] inline QString paneId() const {
      return QString::number(pane_id_);
    }

    void setPaneId(const QString& pane_id);

    [[tbc::hot_path]] [[nodiscard]] inline QAbstractItemModel* grids() noexcept {
      return &grids_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline qreal cellWidth() const noexcept {
      return font_.cell.width();
    }

    [[tbc::hot_path]] [[nodiscard]] inline qreal cellHeight() const noexcept {
      return font_.cell.height();
    }

    [[tbc::hot_path]] [[nodiscard]] inline QRectF cursorRect() const noexcept {
      return cursor_rect_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QString mode() const {
      return mode_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline bool ready() const noexcept {
      return ready_;
    }

    // Where Neovim fills cells with a separator's character between two windows, in pixels:
    // the window draws a line of its own over each.
    [[tbc::hot_path]] [[nodiscard]] inline QVariantList separators() const {
      return separators_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap cmdline() const {
      return cmdline_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap picker() const {
      return picker_;
    }

    // The letters typed in insert mode that the editor has not shown yet, where the way to it
    // is slow, and the corner of the cell the first goes in.
    [[tbc::hot_path]] [[nodiscard]] inline QString prediction() const {
      return prediction_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QPointF predictionOrigin() const noexcept {
      return prediction_origin_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap popupMenu() const {
      return popup_menu_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap messages() const {
      return messages_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap tabline() const {
      return tabline_;
    }

    // The status line of the whole editor, drawn natively over its row: {visible, row, tokens
    // [{text, color, bold, italic, icon, gap}], left and right [{first, count}]}.
    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap statusLine() const {
      return status_line_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap prompt() const {
      return prompt_;
    }

    // What the person answered to the prompt the editor shows.
    [[qt::invokable]] void answer(bool accepted, int index = 0, const QString& text = {});
    // Keys in Neovim's notation, from a native surface: a tab that was clicked, a menu item.
    [[qt::invokable]] void send(const QString& keys);
    // Takes an item of the completion menu, counted among all it has, as a click on it does.
    [[qt::invokable]] void chooseMenu(int item);
    // The editor's picker. A source is "files", "text" or "buffers"; where an entry opens is
    // "", "split", "vertical" or "tab". The preview's area is in this item's pixels, and an
    // index below zero closes it.
    [[qt::invokable]] void pick(const QString& source);
    [[qt::invokable]] void searchPicker(const QString& query);
    [[qt::invokable]] void acceptPicker(int index, const QString& where = {});
    [[qt::invokable]] void previewPicker(int index, const QRectF& area);
    [[qt::invokable]] void listPicker(const QVariantList& indices);
    [[qt::invokable]] void closePicker();
    // A message, by the key its item carries, went from sight: no view of the pane shows it again.
    [[qt::invokable]] void dismissMessage(const QString& key);

    // What a grid's item reads to draw: the editor as last shown, and how its cells are drawn.
    [[nodiscard]] const application::nvim::Editor* editorState() const noexcept;
    [[nodiscard]] const application::Pane<Memory>* pane() const noexcept;

    [[tbc::hot_path]] [[nodiscard]] inline const TerminalFont& font() const noexcept {
      return font_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline const FontGrid& fontGrid() const noexcept {
      return font_grid_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline const std::shared_ptr<const FontCollection>& fontCollection() const noexcept {
      return font_collection_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline std::uint64_t appearance() const noexcept {
      return appearance_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap caret() const {
      return caret_;
    }

    [[tbc::hot_path]] [[nodiscard]] inline bool cursorOn() const noexcept {
      return cursor_on_;
    }

    // Where the input method draws what it composes: at the cursor.
    [[nodiscard]] QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;

    // Asks the window's fonts for what draws `cells` and the editor's own font lacks.
    void requestFonts(std::span<const CellValue> cells);

    [[qt::signal]] void controllerChanged();
    [[qt::signal]] void paneIdChanged();
    [[qt::signal]] void metricsChanged();
    [[qt::signal]] void cursorChanged();
    [[qt::signal]] void modeChanged();
    [[qt::signal]] void caretChanged();
    [[qt::signal]] void readyChanged();
    [[qt::signal]] void separatorsChanged();
    [[qt::signal]] void pickerChanged();
    [[qt::signal]] void predictionChanged();
    [[qt::signal]] void cmdlineChanged();
    [[qt::signal]] void popupMenuChanged();
    [[qt::signal]] void messagesChanged();
    [[qt::signal]] void tablineChanged();
    [[qt::signal]] void statusLineChanged();
    [[qt::signal]] void promptChanged();
    // A frame was applied, or how cells are drawn changed: each grid's item draws again.
    [[qt::signal]] void frameShown();
    // A button was pressed on the editor: its pane takes the focus.
    [[qt::signal]] void pressed();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void updatePolish() override;
    void keyPressEvent(QKeyEvent* event) override;
    void keyReleaseEvent(QKeyEvent* event) override;
    void inputMethodEvent(QInputMethodEvent* event) override;
    void focusInEvent(QFocusEvent* event) override;
    void focusOutEvent(QFocusEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void wheelEvent(QWheelEvent* event) override;
    void hoverMoveEvent(QHoverEvent* event) override;

  private:
    // A cell of a grid under a point of this item.
    struct Hit {
      std::uint32_t grid = 0;
      std::uint16_t row = 0;
      std::uint16_t column = 0;
    };

    void refresh(qulonglong pane_id);
    void measure();
    void refreshFonts();
    void resizeEditor();
    void synchronizeGrids(const application::nvim::Editor& editor);
    void synchronizeSeparators(const application::nvim::Editor& editor);
    // The pointer a place of the editor shows: text to select, a separator to drag, or neither.
    [[nodiscard]] Qt::CursorShape pointerAt(QPointF position) const;
    void synchronizeCursor(const application::nvim::Editor& editor);
    void synchronizeSurfaces(const application::nvim::Editor& editor);
    void projectCmdline(const application::nvim::Editor& editor);
    void projectMenu(const application::nvim::Editor& editor);
    void projectMessages(const application::nvim::Editor& editor);
    void projectTabs(const application::nvim::Editor& editor);
    void projectStatus(const application::nvim::Editor& editor);
    void projectPrompt(const application::nvim::Editor& editor);
    void projectPicker(const application::nvim::Editor& editor);
    // Takes a key that was sent, and a frame that arrived, to the letters shown ahead.
    void predict(const QKeyEvent& event);
    void confirmPrediction(const application::nvim::Editor& editor);
    void publishPrediction();
    void synchronizeCaret(const application::nvim::Editor& editor);
    void restartBlink(const application::nvim::Editor& editor);
    [[nodiscard]] QRectF gridBounds(const application::nvim::Grid& grid) const noexcept;
    [[nodiscard]] ds::Option<Hit> hit(QPointF position) const;
    void point(const QMouseEvent& event, application::nvim::NvimMouseAction action);

    QPointer<NvimController> controller_;
    std::uint64_t pane_id_ = 0;
    ListModel grids_;
    QVariantList separators_;
    QVariantMap picker_;
    PredictiveEcho echo_;
    QElapsedTimer echo_clock_;
    QString prediction_;
    QPointF prediction_origin_;
    std::uint64_t picker_revision_ = 0;
    // The cells the picker's preview was last asked to cover: the float found there is it.
    application::nvim::PreviewArea preview_area_;
    // What it was asked for, in pixels: a font of another size covers it with other cells.
    int preview_index_ = -1;
    QRectF preview_pixels_;
    TerminalFont font_;
    FontGrid font_grid_;
    std::shared_ptr<const FontCollection> font_collection_;
    std::shared_ptr<ResidentFonts> fonts_;
    QPointer<WindowFontCatalog> font_catalog_;
    QMetaObject::Connection font_catalog_connection_;
    qreal font_scale_ = 1;
    std::uint64_t appearance_ = 1;
    QTimer blink_;
    bool cursor_on_ = true;
    QRectF cursor_rect_;
    QString mode_;
    QVariantMap caret_;
    bool ready_ = false;
    QVariantMap cmdline_;
    QVariantMap popup_menu_;
    QVariantMap messages_;
    QVariantMap tabline_;
    QVariantMap status_line_;
    // The cells of the status line, read again only when Neovim drew its row again.
    ds::Option<application::nvim::StatusLine> status_cells_;
    bool status_shown_ = false;
    std::uint64_t status_layout_ = 0;
    std::uint16_t status_row_ = 0;
    std::uint64_t status_revision_ = 0;
    QVariantMap prompt_;
    // The revisions of the editor each projection was last made at.
    std::uint64_t layout_revision_ = 0;
    std::uint64_t cmdline_revision_ = 0;
    std::uint64_t menu_revision_ = 0;
    std::uint64_t messages_revision_ = 0;
    std::uint64_t tabs_revision_ = 0;
    std::uint64_t prompt_revision_ = 0;
    application::nvim::EditorCursor blink_cursor_;
    // The button a drag holds, and the wheel's travel not yet a whole row.
    ds::Option<application::nvim::NvimMouseButton> held_;
    ds::Option<Hit> held_at_;
    qreal wheel_rows_ = 0;
    qreal wheel_columns_ = 0;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("controller", &NvimItem::controller).withWrite(&NvimItem::setController).withNotify(&NvimItem::controllerChanged),
        telar::qt::property("paneId", &NvimItem::paneId).withWrite(&NvimItem::setPaneId).withNotify(&NvimItem::paneIdChanged),
        telar::qt::property("grids", &NvimItem::grids).constant(),
        telar::qt::property("cellWidth", &NvimItem::cellWidth).withNotify(&NvimItem::metricsChanged),
        telar::qt::property("cellHeight", &NvimItem::cellHeight).withNotify(&NvimItem::metricsChanged),
        telar::qt::property("cursorRect", &NvimItem::cursorRect).withNotify(&NvimItem::cursorChanged),
        telar::qt::property("mode", &NvimItem::mode).withNotify(&NvimItem::modeChanged),
        telar::qt::property("caret", &NvimItem::caret).withNotify(&NvimItem::caretChanged),
        telar::qt::property("ready", &NvimItem::ready).withNotify(&NvimItem::readyChanged),
        telar::qt::property("separators", &NvimItem::separators).withNotify(&NvimItem::separatorsChanged),
        telar::qt::property("cmdline", &NvimItem::cmdline).withNotify(&NvimItem::cmdlineChanged),
        telar::qt::property("popupMenu", &NvimItem::popupMenu).withNotify(&NvimItem::popupMenuChanged),
        telar::qt::property("messages", &NvimItem::messages).withNotify(&NvimItem::messagesChanged),
        telar::qt::property("tabline", &NvimItem::tabline).withNotify(&NvimItem::tablineChanged),
        telar::qt::property("statusLine", &NvimItem::statusLine).withNotify(&NvimItem::statusLineChanged),
        telar::qt::property("prompt", &NvimItem::prompt).withNotify(&NvimItem::promptChanged),
        telar::qt::property("picker", &NvimItem::picker).withNotify(&NvimItem::pickerChanged),
        telar::qt::property("prediction", &NvimItem::prediction).withNotify(&NvimItem::predictionChanged),
        telar::qt::property("predictionOrigin", &NvimItem::predictionOrigin).withNotify(&NvimItem::predictionChanged)
    );
  };

}
