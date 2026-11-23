// The explorer as ui drives it: the files of a session's machine as its runtime answers, the keys
// and the pointer of the person, and what they hand to the panes of the tab.
export module telar.gui.application:explorer;

import std;

import :session;
import telar.tbc;
import telar.gui.features.explorer;
import telar.config.client;
import telar.wire.files;

export namespace telar::gui::application::explorer {

  using features::explorer::Aim;
  using features::explorer::DiffTone;
  using features::explorer::Drop;
  using features::explorer::Fact;
  using features::explorer::HeaderLook;
  using features::explorer::Hint;
  using features::explorer::Hints;
  using features::explorer::Lens;
  using features::explorer::LensLook;
  using features::explorer::MenuLine;
  using features::explorer::MenuLook;
  using features::explorer::Mode;
  using features::explorer::Pick;
  using features::explorer::PlanStep;
  using features::explorer::PlanVerb;
  using features::explorer::PreviewLook;
  using features::explorer::RowKind;
  using features::explorer::RowLook;
  using features::explorer::State;
  using features::explorer::StatusLook;
  using features::explorer::Tone;
  using features::explorer::View;
  using features::explorer::Window;
  using features::explorer::WindowRows;

  using features::explorer::chosen;
  using features::explorer::idle_message;
  using features::explorer::lens_count;
  using features::explorer::modeText;
  using features::explorer::toneOf;
  using features::explorer::verbText;

  using runtime::config::KeyChord;
  using telar::FileState;

  // The machine a session is of, as the window names it, which only ui knows: its label, the
  // home of its account, whether it is the one the window runs on, and the number the explorer's
  // windows on it carry.
  struct Host {
    std::uint64_t machine = 0;
    std::string_view name;
    std::string_view home;
    bool local = true;
  };

  // What ui does once a use case returns.
  enum class Effect : std::uint8_t {
    none,
    // The explorer closed: the panes take the keys again.
    closed,
    // `view.text` goes on the clipboard.
    copy,
  };

  // Whether the runtime of this session answers the explorer.
  [[nodiscard]] bool available(const Session& session) noexcept;

  // Opens the explorer at the focused pane of the session; false when its runtime does not
  // answer for files.
  bool open(Session& session, View& view, const Host& host);

  void close(View& view) noexcept;

  // A key of normal or visual mode, or over the plan.
  Effect press(Session& session, View& view, const Host& host, KeyChord chord);

  // What was typed in the field of the mode, as it changes and when Enter ends it; and Escape.
  void typed(Session& session, View& view, const Host& host, std::string_view text);
  Effect submit(Session& session, View& view, const Host& host, std::string_view text);
  void cancel(Session& session, View& view, const Host& host);

  // The pointer chose, asked for or unfolded a row of a window.
  void select(Session& session, View& view, const Host& host, const Pick& pick);
  Effect activate(Session& session, View& view, const Host& host, const Pick& pick);
  void toggle(Session& session, View& view, const Host& host, const Pick& pick);

  // The pointer asked for the menu of a row of a window, or of the window with a row past its
  // last; and chose a line of it.
  void openMenu(Session& session, View& view, const Host& host, const Pick& pick);
  Effect chooseMenu(Session& session, View& view, const Host& host, std::size_t line);

  // The pointer took hold of a row to drag it, which says how many rows go with it; where it
  // is now would take them or not; and it let them go there, or where nothing takes them.
  std::size_t grab(Session& session, View& view, const Host& host, const Pick& pick);
  [[nodiscard]] Aim aim(const Session& session, const View& view, const Host& host, const Drop& drop);
  void drop(Session& session, View& view, const Host& host, const Drop& drop);
  void release(View& view) noexcept;

  // A window shows `rows` rows; and the wheel moves what it shows by `rows` rows.
  void resize(View& view, const WindowRows& shown) noexcept;
  void scroll(View& view, const WindowRows& moved) noexcept;

  // Brings the windows of the session's machine up to date with what its runtime answered and
  // with the focused pane, and asks the runtime for what they still lack. True when what the
  // explorer shows changed.
  bool refresh(Session& session, View& view, const Host& host);

  // What ui reads to draw a window, a row, the hints and the preview.
  [[nodiscard]] RowLook look(const Session& session, const View& view, const Host& host, const Pick& pick);
  [[nodiscard]] HeaderLook header(const Session& session, const View& view, const Host& host, std::size_t window);
  [[nodiscard]] StatusLook status(const Session& session, const View& view, const Host& host, std::size_t window);
  [[nodiscard]] Hints hints(const Session& session, const View& view, const Host& host);
  [[nodiscard]] ds::Array<LensLook, lens_count> lenses(const Session& session, const View& view, const Host& host);
  [[nodiscard]] PreviewLook preview(const Session& session, const View& view, const Host& host, std::uint64_t now_seconds);
  [[nodiscard]] MenuLook menu(const Session& session, const View& view, const Host& host);

  // The text the preview shows, which is the session's own.
  [[nodiscard]] tbc::val_a<std::string_view> previewText(tbc::ref_a<Session> session, const View& view) noexcept;

}
