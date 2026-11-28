export module telar.gui.ui.app.panes.terminal.prompt:prompt_editor_item;

import std;
import telar.gui.qt;
import :prompt_controller;
import telar.gui.ui.design.controls;
import telar.gui.ui.kit.scene;
import telar.gui.application;
import telar.base.ds;
import telar.shell.syntax;
import telar.gui.foundation.core;
import telar.tbc;

export namespace telar::gui::qt {

  // telar's command editor as the prompt line draws it: the command in the terminal's font,
  // coloured by how the shell reads it and wrapped at the line's width, from the layout's indent;
  // the line draws the prompt's mark before it. It holds no state of its own; the session owns the
  // editor, and this item paints it and publishes what QML needs to lay the line out around it.
  class [[qt::object, qt_qml_named("NativePromptEditor")]] PromptEditorItem : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    // emacs, or vim's insert, normal, visual or visual-line.
    // A suggestion from the history shows after the caret, for a key to take it.
    // The command block selected from the editor (its position, from 1, or 0) and how many there
    // are; and copy mode on this pane: "" when off, else "copy", "visual" or "visual-line".
    // Whether the keys that type let the selected block go, as after a click on it.
    // The terminal's cursor is not drawn, standing where no key lands (Session::hidesTerminalCursor).
    // Where the next command runs, for the line to announce when it changes.
    // The running program's progress (OSC 9;4): 0 to 100, -1 without one, -2 when indeterminate.
    // Commands the shell finished and the last one's exit status, for the line's outcome.
    // client.prompt.motion.
    // The completion menu: at most a page of choices around the selected one.
    // A shell `ssh` reached: its host, and how long the last command took to reach it in ms.
    // The key that interrupts the running program, as the terminal's line discipline sets it.
    // The program in the foreground, which a secret is typed for.
    // Where text sweeping in glows, in this item's coordinates, and how strongly: {x, y,
    // width, height, strength}. Empty unless a completion is sweeping in.
    explicit PromptEditorItem(QQuickItem* parent = nullptr);
    ~PromptEditorItem() override;
    PromptEditorItem(const PromptEditorItem&) = delete;
    PromptEditorItem& operator=(const PromptEditorItem&) = delete;
    PromptEditorItem(PromptEditorItem&&) = delete;
    PromptEditorItem& operator=(PromptEditorItem&&) = delete;

    [[nodiscard]] PromptController* controller() const noexcept;
    void setController(PromptController* controller);
    [[nodiscard]] QString paneId() const;
    void setPaneId(const QString& identity);
    [[nodiscard]] QVariantMap grid() const;
    void setGrid(const QVariantMap& grid);
    [[nodiscard]] QVariantMap colors() const;
    void setColors(const QVariantMap& colors);
    [[nodiscard]] int maximumColumns() const noexcept;
    void setMaximumColumns(int columns);
    [[nodiscard]] QString preedit() const;
    void setPreedit(const QString& preedit);

    [[nodiscard]] QString surface() const;
    [[nodiscard]] QString mode() const;
    [[nodiscard]] bool suggesting() const noexcept;
    [[nodiscard]] int block() const noexcept;
    [[nodiscard]] int blocks() const noexcept;
    [[nodiscard]] bool blockTyping() const noexcept;
    [[nodiscard]] QString copying() const;
    [[nodiscard]] bool queued() const noexcept;
    [[nodiscard]] bool answering() const noexcept;
    [[nodiscard]] bool cursorHidden() const noexcept;
    [[nodiscard]] int secretKeys() const noexcept;
    [[nodiscard]] bool failed() const noexcept;
    [[nodiscard]] bool empty() const noexcept;
    [[nodiscard]] QString directory() const;
    [[nodiscard]] QString branch() const;
    [[nodiscard]] int progress() const noexcept;
    [[nodiscard]] int commands() const noexcept;
    [[nodiscard]] int status() const noexcept;
    [[nodiscard]] QString motion() const;
    [[nodiscard]] QVariantList choices() const;
    [[nodiscard]] int choice() const noexcept;
    [[nodiscard]] QString menuLabel() const;
    [[nodiscard]] bool remote() const noexcept;
    [[nodiscard]] QString host() const;
    [[nodiscard]] int link() const noexcept;
    [[nodiscard]] QString interruptKey() const;
    [[nodiscard]] QString program() const;
    [[nodiscard]] int rows() const noexcept;
    [[nodiscard]] int visibleRows() const noexcept;
    [[nodiscard]] int columns() const noexcept;
    [[nodiscard]] QRectF caret() const noexcept;
    [[nodiscard]] QVariantList glows() const;
    [[nodiscard]] qreal cellWidth() const noexcept;
    [[nodiscard]] qreal cellHeight() const noexcept;

    // A click at `point`, in this item's coordinates: the cursor goes to the character there, or
    // to the end of the row past its last.
    [[qt::invokable]] void placeCaret(QPointF point);

    // Rebuilds the layout from the session's editor.
    void refresh();
    // The pane's line or screen moved: refreshes when this editor shows that pane, keeping the
    // layout if nothing it draws changed.
    void refreshPane(std::uint64_t pane_id);

    [[qt::signal]] void controllerChanged();
    [[qt::signal]] void paneIdChanged();
    [[qt::signal]] void gridChanged();
    [[qt::signal]] void colorsChanged();
    [[qt::signal]] void maximumColumnsChanged();
    [[qt::signal]] void preeditChanged();
    [[qt::signal]] void stateChanged();
    [[qt::signal]] void layoutChanged();
    [[qt::signal]] void metricsChanged();
    [[qt::signal]] void glowsChanged();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;

  private:
    // Text a completion or a suggestion taken just wrote: it sweeps in from the accent colour,
    // one character after another.
    struct Fresh {
      std::size_t start = 0;
      std::size_t end = 0;
      qint64 started_ms = 0;
    };

    // How a run shows: its colour and how opaque it is.
    struct RunLook {
      QColor color;
      qreal opacity = 1;
    };

    // Where display_'s parts fall: the composition, this many bytes at the cursor, is part of
    // what was typed, and the suggestion follows it.
    struct Composed {
      std::size_t cursor = 0;
      std::size_t composing = 0;
      std::size_t typed = 0;
    };

    static constexpr int default_maximum_columns = 80;
    static constexpr int default_maximum_rows = 12;

    [[nodiscard]] bool resolveGrid();
    [[nodiscard]] Composed compose(std::string_view text, std::size_t cursor, std::string_view composing);
    void styleDisplay(const Composed& composed, const application::Pane<Memory>* pane);
    void markCommands(std::size_t typed);
    void groupFresh(const Composed& composed);
    void lay(std::size_t caret, std::size_t mark, ds::Option<std::pair<std::size_t, std::size_t>> range);
    void placeRuns();
    void placeRun(std::size_t index, const application::prompt::Run& run, const RunLook& look, QSizeF cell);
    [[nodiscard]] RunLook look(const application::prompt::Run& run, QSizeF cell, qint64 now, QVariantList& glows) const;
    [[nodiscard]] bool rowVisible(std::uint32_t row) const noexcept;
    void paintSelection(QSGNode& group) const;
    void paintUnderlines(QSGNode& group) const;
    void track(std::string_view text, bool animate);
    void animateInsertion(std::size_t prefix, std::string_view added, qint64 now);
    void tick();
    [[nodiscard]] bool animating(qint64 now) const noexcept;
    [[nodiscard]] QColor styleColor(application::prompt::Style style) const;
    [[nodiscard]] QColor roleColor(application::prompt::Style style) const;
    void cacheColors();

    // QML makes the item, so it owns the memory its buffers live in.
    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> adapter_{memory_};
    // Glyphs snap to the scene's pixels, so moving any ancestor repaints them.
    tbc::val_self<AncestorGeometry> ancestors_;
    QPointer<PromptController> controller_;
    CellTextGrid resolved_;
    ds::Vec<NativeCellText*, Memory> runs_{adapter_};
    QVariantMap grid_;
    QVariantMap colors_;
    // What colors_ gives each style, the accent and the path underline, read once per change of
    // colors_ instead of once per run and frame.
    ds::Array<QColor, static_cast<std::size_t>(application::prompt::Style::missing) + 1> style_colors_;
    QColor accent_;
    QColor underline_;
    QString preedit_;
    ds::String<Memory> display_{adapter_};
    ds::String<Memory> typed_{adapter_};
    ds::String<Memory> ghost_{adapter_};
    ds::Vec<application::prompt::Style, Memory> styles_{adapter_};
    ds::Vec<std::uint8_t, Memory> groups_{adapter_};
    ds::Vec<Fresh, Memory> fresh_{adapter_};
    // The lexer's scratch for classify, kept across refreshes.
    ds::Vec<shell::Token, Memory> tokens_{adapter_};
    QVariantList glows_;
    qint64 ghost_started_ms_ = -1;
    QElapsedTimer clock_;
    // Drives frames while text animates, in step with the window's animations.
    QVariantAnimation ticker_;
    application::prompt::Layout layout_{adapter_};
    std::uint64_t pane_id_ = 0;
    std::uint64_t revision_ = 0;
    qreal scale_ = 1;
    int maximum_columns_ = default_maximum_columns;
    int maximum_rows_ = default_maximum_rows;
    int first_row_ = 0;
    std::uint8_t surface_ = 0;
    bool cursor_hidden_ = false;
    bool failed_ = false;
    // Set by a pane's own signals: refresh keeps the layout when nothing it draws changed.
    bool reuse_layout_ = false;

    // What the current layout was built from.
    struct Laid {
      [[tbc::hot_path]] inline explicit Laid(Memory& memory)
          : display(memory),
            styles(memory),
            groups(memory) {}

      ds::String<Memory> display;
      ds::Vec<application::prompt::Style, Memory> styles;
      ds::Vec<std::uint8_t, Memory> groups;
      std::size_t caret = 0;
      std::size_t anchor = 0;
      ds::Option<std::pair<std::size_t, std::size_t>> range;
      int columns = 0;
      int rows = 0;
    };

    Laid laid_{adapter_};

    // The menu's choices as QML last read them, for the line and revision they came from.
    struct [[tbc::shared]] ChoicesCache {
      QVariantList choices;
      const void* line = nullptr;
      std::uint64_t revision = 0;
    };

    mutable ChoicesCache choices_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("controller", &PromptEditorItem::controller).withWrite(&PromptEditorItem::setController).withNotify(&PromptEditorItem::controllerChanged),
        telar::qt::property("paneId", &PromptEditorItem::paneId).withWrite(&PromptEditorItem::setPaneId).withNotify(&PromptEditorItem::paneIdChanged),
        telar::qt::property("grid", &PromptEditorItem::grid).withWrite(&PromptEditorItem::setGrid).withNotify(&PromptEditorItem::gridChanged),
        telar::qt::property("colors", &PromptEditorItem::colors).withWrite(&PromptEditorItem::setColors).withNotify(&PromptEditorItem::colorsChanged),
        telar::qt::property("maximumColumns", &PromptEditorItem::maximumColumns).withWrite(&PromptEditorItem::setMaximumColumns).withNotify(&PromptEditorItem::maximumColumnsChanged),
        telar::qt::property("preedit", &PromptEditorItem::preedit).withWrite(&PromptEditorItem::setPreedit).withNotify(&PromptEditorItem::preeditChanged),
        telar::qt::property("surface", &PromptEditorItem::surface).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("mode", &PromptEditorItem::mode).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("suggesting", &PromptEditorItem::suggesting).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("block", &PromptEditorItem::block).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("blocks", &PromptEditorItem::blocks).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("blockTyping", &PromptEditorItem::blockTyping).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("copying", &PromptEditorItem::copying).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("queued", &PromptEditorItem::queued).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("answering", &PromptEditorItem::answering).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("cursorHidden", &PromptEditorItem::cursorHidden).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("secretKeys", &PromptEditorItem::secretKeys).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("failed", &PromptEditorItem::failed).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("empty", &PromptEditorItem::empty).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("directory", &PromptEditorItem::directory).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("branch", &PromptEditorItem::branch).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("progress", &PromptEditorItem::progress).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("commands", &PromptEditorItem::commands).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("status", &PromptEditorItem::status).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("motion", &PromptEditorItem::motion).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("choices", &PromptEditorItem::choices).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("choice", &PromptEditorItem::choice).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("menuLabel", &PromptEditorItem::menuLabel).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("remote", &PromptEditorItem::remote).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("host", &PromptEditorItem::host).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("link", &PromptEditorItem::link).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("interruptKey", &PromptEditorItem::interruptKey).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("program", &PromptEditorItem::program).withNotify(&PromptEditorItem::stateChanged),
        telar::qt::property("rows", &PromptEditorItem::rows).withNotify(&PromptEditorItem::layoutChanged),
        telar::qt::property("visibleRows", &PromptEditorItem::visibleRows).withNotify(&PromptEditorItem::layoutChanged),
        telar::qt::property("columns", &PromptEditorItem::columns).withNotify(&PromptEditorItem::layoutChanged),
        telar::qt::property("caret", &PromptEditorItem::caret).withNotify(&PromptEditorItem::layoutChanged),
        telar::qt::property("glows", &PromptEditorItem::glows).withNotify(&PromptEditorItem::glowsChanged),
        telar::qt::property("cellWidth", &PromptEditorItem::cellWidth).withNotify(&PromptEditorItem::metricsChanged),
        telar::qt::property("cellHeight", &PromptEditorItem::cellHeight).withNotify(&PromptEditorItem::metricsChanged)
    );
  };

}
