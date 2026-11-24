// The explorer as ui drives it over the sessions of a window: each of its windows reads the files
// of one machine, as the runtime of that session answers; the keys and the pointer of the person
// go to the window they act on, and what they hand over to the panes of the tab that shows.
export module telar.gui.application:explorer;

import std;

import :session;
import telar.tbc;
import telar.gui.features.explorer;
import telar.config.client;
import telar.wire.files;

export namespace telar::gui::application::explorer {

  using features::explorer::ActorLook;
  using features::explorer::ActorTone;
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
  using features::explorer::TransferKind;
  using features::explorer::TransferLooks;
  using features::explorer::TransferPhase;
  using features::explorer::View;
  using features::explorer::Window;
  using features::explorer::WindowRows;

  using features::explorer::baseOf;
  using features::explorer::chosen;
  using features::explorer::fetch;
  using features::explorer::Fetched;
  using features::explorer::Fetching;
  using features::explorer::fetching;
  using features::explorer::idle_message;
  using features::explorer::Leaves;
  using features::explorer::leaves;
  using features::explorer::lens_count;
  using features::explorer::modeText;
  using features::explorer::Outside;
  using features::explorer::placedOf;
  using features::explorer::saidOf;
  using features::explorer::stopTransfer;
  using features::explorer::strand;
  using features::explorer::takeOut;
  using features::explorer::toneOf;
  using features::explorer::touchedSince;
  using features::explorer::transferring;
  using features::explorer::transfers;
  using features::explorer::verbText;

  using runtime::config::KeyChord;
  using telar::FileState;

  using features::explorer::Action;
  using features::explorer::ActionKind;
  using features::explorer::Context;
  using features::explorer::MachineFact;
  using features::explorer::PaneFact;
  using features::explorer::Reach;
  using features::explorer::Revealed;
  using features::explorer::Side;

  // The use cases, which ui runs with the cache of the machine of the window they act on: the
  // session of that machine holds it, and ui keeps one of its own for a machine that is away.
  using features::explorer::absorb;
  using features::explorer::activate;
  using features::explorer::aim;
  using features::explorer::bringIn;
  using features::explorer::cancel;
  using features::explorer::chooseMenu;
  using features::explorer::click;
  using features::explorer::climb;
  using features::explorer::close;
  using features::explorer::complete;
  using features::explorer::configure;
  using features::explorer::docked;
  using features::explorer::drop;
  using features::explorer::focus;
  using features::explorer::grab;
  using features::explorer::hand;
  using features::explorer::header;
  using features::explorer::Help;
  using features::explorer::help;
  using features::explorer::hints;
  using features::explorer::lenses;
  using features::explorer::look;
  using features::explorer::menu;
  using features::explorer::open;
  using features::explorer::openMenu;
  using features::explorer::pin;
  using features::explorer::planNote;
  using features::explorer::press;
  using features::explorer::preview;
  using features::explorer::previewText;
  using features::explorer::release;
  using features::explorer::resize;
  using features::explorer::reveal;
  using features::explorer::say;
  using features::explorer::scroll;
  using features::explorer::select;
  using features::explorer::status;
  using features::explorer::step;
  using features::explorer::submit;
  using features::explorer::toggle;
  using features::explorer::toward;
  using features::explorer::typed;

  // A machine the window keeps, as only ui knows it: the number the explorer's windows on it
  // carry, its label, the home of its account where ui knows it, and whether the window runs
  // on it.
  struct Host {
    std::uint64_t machine = 0;
    std::string_view name;
    std::string_view home;
    bool local = true;
  };

  // The panes a tab holds at most, and the machines a window keeps.
  inline constexpr std::size_t scene_panes = 64;
  inline constexpr std::size_t scene_machines = 16;

  // What the explorer reads around the files: the panes of the tab that shows, and every machine
  // the window keeps. It owns what it holds, copied out of the sessions, so a use case changes
  // a session's cache while it reads this. ui keeps one and observes again when a session
  // changed.
  struct Scene {
    explicit Scene(Memory& made_in);

    struct Pane {
      explicit Pane(Memory& made_in);

      std::uint64_t id = 0;
      std::uint16_t number = 0;
      features::explorer::PaneKind kind = features::explorer::PaneKind::shell;
      ds::String<Memory> title;
      ds::String<Memory> cwd;
    };

    struct Machine {
      explicit Machine(Memory& made_in);

      std::uint64_t id = 0;
      ds::String<Memory> label;
      ds::String<Memory> home;
      bool local = false;
      Reach reach = Reach::away;
    };

    // The texts are kept from one observation to the next, and `pane_count` and `machine_count`
    // say how many of each stand now.
    ds::Vec<Pane, Memory> panes;
    std::size_t pane_count = 0;
    ds::Vec<Machine, Memory> machines;
    std::size_t machine_count = 0;
    std::uint64_t focused = 0;
    // The pane that had the focus before the explorer's own took it: what the explorer hands a
    // file to, and follows, while it stands as a pane and has the keys.
    std::uint64_t companion = 0;
    std::uint64_t shown = 0;
    ds::String<Memory> workspace;
    // The time of the observation, in seconds: what a row says how long ago against.
    std::uint64_t now = 0;
    // The files the editors of the machines observed hold, each path a piece of `edited_text`.
    ds::Vec<char, Memory> edited_text;
    ds::Vec<features::explorer::EditedFile, Memory> edited;
    // The sum of what the sessions observed count of the changes of those files: another
    // number when they are other files.
    std::uint64_t edited_revision = 0;
  };

  // Forgets the machines, before each is observed again.
  void clear(Scene& scene) noexcept;

  // Reads into `scene` the panes of the tab `session` shows, which is the session of `machine`.
  // The pane the explorer stands as is none of them: with the focus in it, the focused pane is
  // the one that had it before.
  void observe(Scene& scene, const Session& session, std::uint64_t machine);

  // Adds a machine to `scene`: one whose session the window holds, with the home its runtime
  // said; or one that is away.
  void observe(Scene& scene, const Host& host, const Session& session);
  void observe(Scene& scene, const Host& host);

  // The scene as the use cases read it: views of what it holds, for as long as it is not
  // observed again.
  struct Around {
    ds::Array<PaneFact, scene_panes> panes{};
    std::size_t pane_count = 0;
    ds::Array<MachineFact, scene_machines> machines{};
    ds::Array<std::string_view, scene_machines> homes{};
    std::size_t machine_count = 0;
    std::uint64_t focused = 0;
    std::uint64_t shown = 0;
    std::string_view workspace;
    std::uint64_t now = 0;
    features::explorer::Edited edited;
  };

  [[nodiscard]] tbc::val_a<Around> around(tbc::ref_a<Scene> scene) noexcept;

  // The context of a use case on a window of `machine`.
  [[nodiscard]] tbc::val_a<Context> contextOf(tbc::ref_a<Around> around, std::uint64_t machine) noexcept;

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

  // The pane of the tab `session` shows that is the explorer; 0 when the tab has none, or the
  // one it has is being closed.
  [[nodiscard]] std::uint64_t standing(const Session& session) noexcept;

  // What became of the explorer when it was brought to where the tab that shows has it.
  enum class Stood : std::uint8_t {
    same,
    // It stands as a pane of the tab that shows now, and was closed or over the panes before.
    taken,
    // The pane it stood as is gone, or is of a tab that no longer shows: it closed.
    left,
  };

  // Brings the explorer to where the tab `session` shows has it. With a pane that is the
  // explorer, it stands as that pane, with the windows the runtime keeps of it, and has the keys
  // while the pane has the focus. With none, an explorer that stood as a pane closes. The
  // runtime is given its windows when they changed, and when it leaves them. `context` is the
  // one of the session's machine.
  Stood host(Session& session, View& view, const Context& context);

  // Brings the windows on the session's machine up to date with what its runtime answered, and
  // with the focused pane when the session is the one that shows; then asks for what they still
  // lack. True when what the explorer shows changed.
  bool refresh(Session& session, View& view, const Context& context);

  // Carries the files on their way to or from the session's machine: takes what its runtime
  // answered them, and asks it for what each wants next of it, one request for each. A file
  // brought for a pane of this session is typed there once it is whole. It goes on while the
  // explorer is closed. True when what the explorer shows of them changed.
  bool carry(Session& session, View& view, const Context& context, std::uint64_t now_ms);

  // What an action hands to the panes, which are of `session`, the one that shows: a path
  // typed, a mention, a shell's directory, a split, the focus.
  Effect deliver(Session& session, View& view, const Context& context, const Action& action);

  // What an action asks of the runtime of the session's machine: its part of the plan, the
  // plan taken back, a commit, or the files to open in an editor there. False when it was to
  // open them and no editor did: the view says so, and the action is not delivered.
  bool send(Session& session, View& view, const Context& context, const Action& action);

}
