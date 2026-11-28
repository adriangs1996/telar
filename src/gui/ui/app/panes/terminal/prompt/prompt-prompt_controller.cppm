export module telar.gui.ui.app.panes.terminal.prompt:prompt_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.base.ds;
import telar.base.memory.allocators;

export namespace telar::gui::qt {

  class PromptEditorItem;

  // telar's command editor in each pane: who has the pane's keyboard, the line the editor holds
  // and what it suggests, the keys and text it takes, and the command block selected from it.
  //
  // It reads the store. The editors that draw a line attach to it, and the window tells it when a
  // pane's screen moved, or the configuration changed: it refreshes the editors of that pane
  // directly, since a pane's output reaches here as often as it paints. What a key asks of the
  // window (the history search, the scrollback search, the status) goes up as a signal.
  class [[qt::object, qt_qml_named("PromptController"), qt_qml_uncreatable("Use the window's prompt")]] PromptController final : public QObject {
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

    // The editors it serves are listed in `memory`.
    PromptController(Store& store, Memory& memory, QObject* parent = nullptr);
    ~PromptController() override = default;
    PromptController(const PromptController&) = delete;
    PromptController& operator=(const PromptController&) = delete;
    PromptController(PromptController&&) = delete;
    PromptController& operator=(PromptController&&) = delete;

    [[nodiscard]] application::prompt::Surface surface(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] bool edits(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] bool hidesTerminalCursor(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] ds::Option<application::prompt::LineView> line(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] std::string_view suggestion(std::uint64_t pane_id) const noexcept;
    // The bytes of the first option the line's command does not accept; none to mark.
    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> rejectedOption(std::uint64_t pane_id);
    // Whether the pane's shell runs `word`; asks the runtime once and answers pending until then.
    [[nodiscard]] application::prompt::CommandPresence commandPresence(std::uint64_t pane_id, std::string_view word);
    // The command block selected in the pane, by index among its blocks.
    [[nodiscard]] ds::Option<std::size_t> selectedBlock(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] bool typingLeavesBlock(std::uint64_t pane_id) const noexcept;
    // macOS's Command keys for the editor's text: select all, redo, and copy or cut the selection
    // to the clipboard; false for a copy or cut with nothing selected.
    void textCommand(std::uint64_t pane_id, application::prompt::TextCommand command);
    bool copyText(std::uint64_t pane_id, bool cut);
    void placeCursor(std::uint64_t pane_id, std::size_t offset);

    // What an editor shows around the line: its pane, the configuration and copy mode.
    [[nodiscard]] const application::Pane<Memory>* pane(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] const Configuration& configuration() const noexcept;
    [[nodiscard]] const ds::Option<application::terminal::copy_mode::CopyState>& copy() const noexcept;

    // The keys and text telar's command editor takes. False hands the key or the text back to the
    // terminal.
    bool key(std::uint64_t pane_id, const application::prompt::KeyPress& key);
    bool text(std::uint64_t pane_id, const QString& text);
    // An input method reconverted bytes [begin, end) of the line into `text`.
    void reconvert(std::uint64_t pane_id, application::prompt::Surrounding replaced, const QString& text);
    // The pane's line moved: its editors refresh, then lineChanged tells the terminal.
    void publish(qulonglong pane_id);
    // Text the line's editor took from outside the keyboard reaches its view.
    void publishWrite();

    void attach(PromptEditorItem& editor);
    void detach(PromptEditorItem& editor);
    // The pane's line or screen moved: its editors refresh, keeping their layout if nothing they
    // draw changed.
    void refresh(qulonglong pane_id);
    // The configuration changed: every editor lays its line out again.
    void configure();

    [[qt::signal]] void lineChanged(qulonglong pane_id);
    // A key at the prompt asked for the history search.
    [[qt::signal]] void historyRequested();
    // A key selected a command block or left it: the pane scrolls, and copy mode may begin on it.
    [[qt::signal]] void blockChanged(qulonglong pane_id);
    // A key asked to search a command's output.
    [[qt::signal]] void searchRequested();
    [[qt::signal]] void failed(const QString& message);

  private:
    Store& store_;
    // An editor that detaches leaves its slot empty, so one that attaches or detaches while the
    // others refresh neither moves nor skips them.
    ds::Vec<PromptEditorItem*, Memory> editors_;
  };

}
