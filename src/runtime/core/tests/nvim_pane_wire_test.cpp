#include <stdlib.h>
#include <unistd.h>

import std;
import telar.msgpack;
import telar.platform.fs;
import telar.platform.process;
import telar.testing;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.files;
import telar.wire.layout;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr ds::Array<std::string_view, 1> cat{"/bin/cat"};

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  // A stand-in for `nvim --embed`: it speaks Neovim's RPC on its pipes, far enough for a runtime
  // to attach, type, paste and resize, and draws what it was asked on its one grid. Row 0 says
  // what it last did, row 1 holds what was typed.
  class FakeNvim {
  public:
    int run() {
      std::vector<std::uint8_t> pending;
      ds::Array<std::uint8_t, 4096> piece{};

      for (;;) {
        const auto count = ::read(STDIN_FILENO, piece.dataMut(), piece.size());
        if (count <= 0) {
          return 0;
        }

        pending.insert(pending.end(), piece.data(), piece.data() + count);
        for (;;) {
          msgpack::Scanner scanner;
          const auto progress = scanner.feed(pending);
          if (progress.status != msgpack::Status::ok) {
            break;
          }

          request(std::span{pending}.first(progress.consumed));
          pending.erase(pending.begin(), pending.begin() + static_cast<std::ptrdiff_t>(progress.consumed));
        }
      }
    }

    std::string configuration;

  private:
    void request(std::span<const std::uint8_t> message) {
      msgpack::Reader reader{message};
      std::uint64_t type = 0;
      std::uint64_t id = 0;

      if (!reader.tuple(4) || !reader.unsignedInteger(type) || type != 0 || !reader.unsignedInteger(id)) {
        return;
      }

      const auto method = std::string{reader.string().valueOr("")};
      std::uint32_t parameters = 0;

      static_cast<void>(reader.array(parameters));
      if (method == "nvim_get_api_info") {
        respond(id, [](msgpack::Writer& writer) {
          writer.array(2);
          writer.unsignedInteger(7);
          writer.map(1);
          writer.string("version");
          writer.map(2);
          writer.string("major");
          writer.unsignedInteger(0);
          writer.string("minor");
          writer.unsignedInteger(12);
        });
        return;
      }

      respond(id, [](msgpack::Writer& writer) {
        writer.nil();
      });

      if (method == "nvim_ui_attach" || method == "nvim_ui_try_resize") {
        static_cast<void>(reader.unsignedInteger(columns_));
        static_cast<void>(reader.unsignedInteger(rows_));
        draw(method == "nvim_ui_attach" ? "ready" : "resized", true);
      } else if (method == "nvim_input") {
        const auto keys = std::string{reader.string().valueOr("")};
        if (keys == "<F5>") {
          ask();
          return;
        }

        // What telar's side of the conversation in Neovim would say.
        if (keys == "<F6>") {
          tell("telar_clipboard", 1, [](msgpack::Writer& writer) {
            writer.string("yanked");
          });
          return;
        }

        if (keys == "<F4>") {
          tell("telar_open", 1, [](msgpack::Writer& writer) {
            writer.string("https://example.com/docs");
          });
          return;
        }

        if (keys == "<F7>") {
          tell("telar_pick", 1, [](msgpack::Writer& writer) {
            writer.string("files");
          });
          return;
        }

        if (keys == "<F8>") {
          draw("themes " + std::to_string(themes_), false);
          return;
        }

        // What it was started with: its configuration, and the name it keeps its files under.
        if (keys == "<F9>") {
          const char* name = std::getenv("NVIM_APPNAME");
          std::ifstream file{configuration};
          const std::string text{std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};

          draw(std::string{text.contains("telar's own Neovim configuration") ? "telar's" : "own"} + " as " + (name == nullptr ? "nvim" : name), false);
          return;
        }

        // The files its buffers show, and `:Telar explore` on one of them.
        if (keys == "<F10>") {
          tell("telar_files", 1, [](msgpack::Writer& writer) {
            writer.array(2);
            writer.array(3);
            writer.string("/work/main.cpp");
            writer.boolean(true);
            writer.boolean(true);
            writer.array(3);
            writer.string("/work/README.md");
            writer.boolean(false);
            writer.boolean(false);
          });
          return;
        }

        if (keys == "<F11>") {
          tell("telar_explore", 1, [](msgpack::Writer& writer) {
            writer.string("/work/main.cpp");
          });
          return;
        }

        typed_ += keys;
        draw("typed", false);
      } else if (method == "nvim_exec_lua") {
        script(reader);
      } else if (method == "nvim_paste") {
        typed_ += std::string{reader.string().valueOr("")};
        draw("pasted", false);
      } else if (method == "nvim_input_mouse") {
        draw("clicked", false);
      } else if (method == "nvim_select_popupmenu_item") {
        std::uint64_t item = 0;

        static_cast<void>(reader.unsignedInteger(item));
        draw("picked " + std::to_string(item), false);
      }
    }

    // A notification, as what runs in Neovim sends the runtime.
    template <typename Parameters>
    static void tell(std::string_view name, std::uint32_t count, Parameters parameters) {
      ds::Array<std::uint8_t, 256> bytes{};
      msgpack::Writer writer{bytes.viewMut()};

      writer.array(3);
      writer.unsignedInteger(2);
      writer.string(name);
      writer.array(count);
      parameters(writer);
      write(writer.written());
    }

    // Asks the user to choose, as vim.ui.select does once the runtime took it over.
    static void ask() {
      ds::Array<std::uint8_t, 256> bytes{};
      msgpack::Writer writer{bytes.viewMut()};

      writer.array(3);
      writer.unsignedInteger(2);
      writer.string("telar_prompt");
      writer.array(5);
      writer.unsignedInteger(1);
      writer.string("select");
      writer.string("Pick");
      writer.string("");
      writer.array(2);
      writer.string("uno");
      writer.string("dos");
      write(writer.written());
    }

    // The scripts the runtime runs: an answer to a prompt, or a file to show.
    void script(msgpack::Reader& reader) {
      const auto source = std::string{reader.string().valueOr("")};
      std::uint32_t arguments = 0;

      static_cast<void>(reader.array(arguments));
      if (source.starts_with("__telar_prompt_answer")) {
        std::uint64_t id = 0;
        std::uint64_t index = 0;
        bool accepted = false;

        static_cast<void>(reader.unsignedInteger(id) && reader.boolean(accepted) && reader.unsignedInteger(index));
        draw(accepted ? "chose " + std::to_string(index) : std::string{"dismissed"}, false);
      } else if (source.starts_with("__telar_moved")) {
        // The buffer of a file that moved is given its new name: the stand-in says which.
        const std::filesystem::path from{reader.string().valueOr("")};
        const std::filesystem::path target{reader.string().valueOr("")};

        draw("moved " + from.filename().string() + ">" + target.filename().string() + (std::filesystem::weakly_canonical(from.parent_path()) == std::filesystem::weakly_canonical(target.parent_path()) ? "" : " elsewhere"), false);
      } else if (source.starts_with("__telar_theme")) {
        ++themes_;
      } else if (source.starts_with("__telar_navigate")) {
        // The stand-in has one window: there is none on any side.
        const auto side = std::string{reader.string().valueOr("")};

        tell("telar_navigate", 1, [&](msgpack::Writer& writer) {
          writer.string(side);
        });
      } else if (source.starts_with("__telar_buffers")) {
        std::uint64_t token = 0;

        static_cast<void>(reader.unsignedInteger(token));
        // The list asked as token 30 is answered late, after the next one is asked, as a
        // Neovim busy when it was asked would.
        if (token == late_buffers) {
          held_ = token;
          return;
        }

        listBuffers(token);
        if (held_ != 0) {
          listBuffers(std::exchange(held_, 0));
        }
      } else if (source.contains("vim.cmd.tabedit")) {
        std::uint64_t line = 0;
        const auto path = std::string{reader.string().valueOr("")};

        static_cast<void>(reader.unsignedInteger(line));
        draw("opened " + path + ":" + std::to_string(line), false);
      }
    }

    static void listBuffers(std::uint64_t token) {
      tell("telar_buffers", 2, [&](msgpack::Writer& writer) {
        writer.unsignedInteger(token);
        writer.array(3);
        writer.string("docs/editor.md");
        writer.string("src/main.cpp");
        writer.string("README.md");
      });
    }

    template <typename Result>
    void respond(std::uint64_t id, Result result) {
      ds::Array<std::uint8_t, 256> bytes{};
      msgpack::Writer writer{bytes.viewMut()};

      writer.array(4);
      writer.unsignedInteger(1);
      writer.unsignedInteger(id);
      writer.nil();
      result(writer);
      write(writer.written());
    }

    static void line(msgpack::Writer& writer, std::uint32_t row, std::string_view text) {
      writer.array(2);
      writer.string("grid_line");
      writer.array(5);
      writer.unsignedInteger(1);
      writer.unsignedInteger(row);
      writer.unsignedInteger(0);
      writer.array(static_cast<std::uint32_t>(text.size() + 1));

      for (std::size_t index = 0; index < text.size(); ++index) {
        writer.array(index == 0 ? 2 : 1);
        writer.string(text.substr(index, 1));
        if (index == 0) {
          writer.unsignedInteger(0);
        }
      }

      // The rest of the row is cleared, so a shorter text leaves nothing of a longer one.
      writer.array(3);
      writer.string(" ");
      writer.unsignedInteger(0);
      writer.unsignedInteger(32);
      writer.boolean(false);
    }

    void draw(std::string_view status, bool resized) {
      // Nothing is drawn for a UI that has not attached: what was typed waits for it.
      if (columns_ == 0) {
        return;
      }

      std::vector<std::uint8_t> bytes(64 * 1024);
      msgpack::Writer writer{bytes};

      writer.array(3);
      writer.unsignedInteger(2);
      writer.string("redraw");
      writer.array(resized ? 6 : 5);
      // Neovim titles itself after the file its focused window shows.
      writer.array(2);
      writer.string("set_title");
      writer.array(1);
      writer.string("notes.md");
      if (resized) {
        writer.array(2);
        writer.string("grid_resize");
        writer.array(3);
        writer.unsignedInteger(1);
        writer.unsignedInteger(columns_);
        writer.unsignedInteger(rows_);
      }

      line(writer, 0, status);
      line(writer, 1, typed_.empty() ? " " : typed_);
      writer.array(2);
      writer.string("grid_cursor_goto");
      writer.array(3);
      writer.unsignedInteger(1);
      writer.unsignedInteger(1);
      writer.unsignedInteger(typed_.size());
      writer.array(2);
      writer.string("flush");
      writer.array(0);
      write(writer.written());
    }

    static void write(std::span<const std::uint8_t> bytes) {
      while (!bytes.empty()) {
        const auto count = ::write(STDOUT_FILENO, bytes.data(), bytes.size());
        if (count <= 0) {
          std::_Exit(1);
        }

        bytes = bytes.subspan(static_cast<std::size_t>(count));
      }
    }

    std::uint64_t columns_ = 0;
    std::uint64_t rows_ = 0;
    static constexpr std::uint64_t late_buffers = 30;
    std::uint64_t themes_ = 0;
    std::uint64_t held_ = 0;
    std::string typed_;
  };

  int fakeNvim(int argc, char** argv) {
    FakeNvim neovim;

    // The configuration it was started on, as `-u FILE` names it.
    for (int index = 1; index + 1 < argc; ++index) {
      if (std::string_view{argv[index]} == "-u") {
        neovim.configuration = argv[index + 1];
      }
    }

    return neovim.run();
  }

  const telar::testing::Mode embed_mode{"--embed", fakeNvim};

  // A runtime whose PATH finds the stand-in as `nvim`, or finds no nvim at all.
  struct EditorHost {
    explicit EditorHost(bool installed = true, RuntimeHostOptions options = {})
        : programs(makeDirectory()) {
      if (installed) {
        const runtime::ExecutablePath self;

        std::filesystem::create_symlink(self.view(), programs + "/nvim");
      }

      // The runtime starts as a child of this process and looks nvim up along its PATH.
      ::setenv("PATH", programs.c_str(), 1);
      host.emplace(options);
    }

    ~EditorHost() {
      host.reset();
      std::error_code ignored;

      std::filesystem::remove_all(programs, ignored);
    }

    EditorHost(const EditorHost&) = delete;
    EditorHost& operator=(const EditorHost&) = delete;

    static std::string makeDirectory() {
      ds::Array<char, 32> directory{};

      std::strcpy(directory.dataMut(), "/tmp/telar-nvim-XXXXXX");
      check(::mkdtemp(directory.dataMut()) != nullptr);
      return directory.data();
    }

    std::string programs;
    std::optional<RuntimeHost> host;
  };

  // What a client keeps of an editor pane's one grid, as the frames it applied left it.
  struct Editor {
    std::uint64_t pane = 0;
    std::uint64_t frame = 0;
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
    std::vector<std::string> cells;
    std::uint16_t cursor_row = 0;
    std::uint16_t cursor_column = 0;
    std::size_t frames = 0;
    // The files its buffers show, as the frames said them: each path, with `+` after one whose
    // buffer has changes not written.
    std::string files;

    std::string row(std::size_t index) const {
      std::string text;

      for (std::size_t column = 0; column < columns; ++column) {
        text += cells[(index * columns) + column];
      }

      text.erase(text.find_last_not_of(' ') + 1);
      return text;
    }

    void apply(const NvimGrid& grid) {
      check(grid.pane_id == pane && grid.grid == 1, "the stand-in draws one grid");
      if (grid.full) {
        columns = grid.columns;
        rows = grid.rows;
        cells.assign(std::size_t{columns} * rows, " ");
      }

      check(grid.columns == columns && grid.rows == rows, "a grid that changed size is sent whole");
      for (const auto& span : grid.spans) {
        auto reader = span.reader();
        std::size_t index = span.start;

        while (const auto cell = reader.next()) {
          cells[index++] = std::string{textView(cell->text)};
        }
      }
    }

    // Receives the pane's next frame, applies it and says so, as a window does once it drew.
    void next(ProtocolPeer& peer) {
      peer.deadline(std::chrono::seconds{10});
      for (;;) {
        const auto message = peer.receiveAny<NvimGrid, NvimOpenFiles, NvimFrame>();
        if (const auto* grid = std::get_if<NvimGrid>(&message)) {
          if (grid->pane_id == pane) {
            apply(*grid);
          }

          continue;
        }

        if (const auto* shown = std::get_if<NvimOpenFiles>(&message)) {
          files.clear();
          for (const auto& file : shown->files) {
            files += std::string{file.path} + (file.modified ? "+ " : " ");
          }

          continue;
        }

        const auto& ended = std::get<NvimFrame>(message);
        if (ended.pane_id != pane) {
          continue;
        }

        check(ended.base_frame_id == 0 || ended.base_frame_id == frame, "a frame changes the one the client applied");
        frame = ended.frame_id;
        cursor_row = ended.cursor_row;
        cursor_column = ended.cursor_column;
        ++frames;
        peer.send(FrameAck{pane, frame});
        return;
      }
    }

    // Applies frames until row 0 says `status`.
    void until(ProtocolPeer& peer, std::string_view status) {
      while (cells.empty() || row(0) != status) {
        next(peer);
      }
    }
  };

  // A terminal pane to open the editor beside, and the client attached to it.
  PaneOpened openTerminal(ProtocolPeer& peer) {
    return peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
  }

  // Opens an editor pane beside `beside`, checking the client is told its kind before its id.
  Editor openEditor(ProtocolPeer& peer, const PaneOpened& beside, std::uint64_t request = 2) {
    peer.send(CreateNvimPane{.request_id = request, .location = beside.location, .size = size, .cwd = "/tmp"});
    peer.deadline(std::chrono::seconds{10});
    const auto notice = peer.receive<PaneKindNotice>();
    const auto opened = peer.receive<PaneOpened>();

    check(notice.kind == PaneKind::nvim && notice.pane_id == opened.pane_id && opened.created && opened.request_id == request, "the client is told the pane is an editor before the reply names it");
    return {.pane = opened.pane_id};
  }

  ds::Option<FailureCode> refused(ProtocolPeer& peer, auto&& send) {
    try {
      send();
    } catch (const ProtocolFailure& failure) {
      return failure.code;
    }

    return ds::none;
  }

  void testEditorPaneDrawsAndTakesInput() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    check(editor.columns == size.cols && editor.rows == size.rows, "the editor is as large as the pane");

    const auto first = editor.frame;

    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("hola")});
    editor.until(peer, "typed");
    check(editor.row(1) == "hola" && editor.frame > first, "what was typed is drawn in a later frame");
    check(editor.cursor_row == 1 && editor.cursor_column == 4, "the cursor is where Neovim put it");

    peer.send(NvimPaste{.pane_id = editor.pane, .text = bytes(" mundo")});
    editor.until(peer, "pasted");
    check(editor.row(1) == "hola mundo", "what was pasted is drawn");

    peer.send(NvimMouse{.pane_id = editor.pane, .grid = 1, .row = 0, .column = 0, .button = NvimMouseButton::left, .action = NvimMouseAction::press});
    editor.until(peer, "clicked");
  }

  void testEditorPaneFollowsItsSize() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.send(PaneResize{.pane_id = editor.pane, .size = {100, 30, 8, 16}});
    editor.until(peer, "resized");
    check(editor.columns == 100 && editor.rows == 30, "the grid has the size the client asked for");
  }

  void testEditorTabIsAnnounced() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);

    peer.send(CreateNvimPane{.request_id = 2, .location = terminal.location, .new_tab = true, .size = size, .cwd = "/tmp"});
    peer.deadline(std::chrono::seconds{10});
    const auto notice = peer.receive<PaneKindNotice>();
    const auto created = peer.receive<TabCreated>();

    check(notice.kind == PaneKind::nvim && notice.pane_id == created.root_pane_id && created.location.tab_id != terminal.location.tab_id, "a tab of its own, whose pane is announced as an editor");

    Editor editor{.pane = created.root_pane_id};

    editor.until(peer, "ready");
  }

  void testEditorPaneNamesItsDocument() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    // A client that lists the panes hears, with each pane's facts, the file the editor shows.
    ProtocolPeer listener{editor_host.host->socket()};
    bool named = false;

    listener.send(RequestRuntimeState{.client_identity = 71});
    listener.deadline(std::chrono::seconds{10});
    while (!named) {
      const auto facts = listener.receive<PaneFacts>();
      if (facts.pane_id != editor.pane) {
        check(facts.document.empty(), "a terminal names no document");
        continue;
      }

      check(facts.document == "notes.md" && facts.command_state == PaneCommandState::none && facts.command.empty(), "an editor's facts name the file it shows, and no command");
      named = true;
    }
  }

  void testSecondClientIsSentTheScreenWhole() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    // Typed before Neovim attached: the keys wait in its input, and none is lost.
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("visto")});
    editor.until(peer, "ready");
    check(editor.row(1) == "visto", "keys typed while the editor starts are kept");

    ProtocolPeer late{editor_host.host->socket()};

    late.send(OpenPane{.request_id = 7, .target = {.kind = PaneTarget::Kind::pane, .id = editor.pane}, .size = size});
    late.deadline(std::chrono::seconds{10});
    const auto notice = late.receive<PaneKindNotice>();
    const auto opened = late.receive<PaneOpened>();

    check(notice.pane_id == editor.pane && notice.kind == PaneKind::nvim && opened.pane_id == editor.pane && !opened.created, "a client that attaches later learns the pane's kind too");

    Editor mirror{.pane = editor.pane};

    mirror.next(late);
    check(mirror.frames == 1 && mirror.row(0) == "ready" && mirror.row(1) == "visto", "and is sent what the editor shows in one frame");

    // A client that lost its screen asks for it again.
    late.send(RequestSnapshot{.pane_id = editor.pane});
    Editor again{.pane = editor.pane};

    again.next(late);
    check(again.row(1) == "visto", "a snapshot sends the screen whole again");
  }

  void testRequestsOfAnotherKindAreRefused() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.deadline(std::chrono::seconds{10});
    check(refused(peer, [&] {
      peer.exchange<PaneMatches>(SearchPane{.request_id = 10, .pane_id = editor.pane, .needle = "x"});
    }) == FailureCode::unsupported_pane_kind,
        "a terminal's request of an editor says the pane is of another kind");

    peer.send(NvimInput{.pane_id = terminal.pane_id, .keys = bytes("x")});
    check(refused(peer, [&] {
      peer.exchange<PaneText>(ReadPane{.request_id = 11, .pane_id = terminal.pane_id, .rows = 10});
    }) == FailureCode::unsupported_pane_kind,
        "an editor's request of a terminal is refused the same way");

    // The editor still answers after both refusals.
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("ok")});
    editor.until(peer, "typed");
  }

  // A client that asks what a tab holds was told nothing of its panes: the editor is announced
  // before the snapshot that names it.
  void testTabSnapshotAnnouncesTheEditor() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");

    ProtocolPeer late{editor_host.host->socket()};

    late.send(RequestTabSnapshot{.request_id = 7, .location = terminal.location});
    late.deadline(std::chrono::seconds{10});
    const auto first = late.receiveAny<PaneKindNotice, TabSnapshot>();
    const auto snapshot = late.receive<TabSnapshot>();
    const auto* notice = std::get_if<PaneKindNotice>(&first);

    check(notice != nullptr && notice->pane_id == editor.pane && notice->kind == PaneKind::nvim, "the editor's kind comes before the snapshot");
    check(snapshot.request_id == 7 && snapshot.panes.size() == 2, "and the snapshot names the terminal and the editor");
    check(late.exchange<TabSnapshot>(RequestTabSnapshot{.request_id = 8, .location = terminal.location}).panes.size() == 2, "on a connection that stays open");
  }

  // What an agent reads of an editor pane is what its screen shows.
  void testEditorTextIsRead() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("hola")});
    editor.until(peer, "typed");

    const auto text = peer.exchange<PaneText>(ReadPane{.request_id = 10, .pane_id = editor.pane, .rows = 2});

    check(text.pane_id == editor.pane && !text.truncated && text.text == "typed\nhola\n", "the rows asked for, as the screen shows them");
  }

  // What runs in Neovim tells the client that drives the editor: a yank is its clipboard, the
  // way out of the last window is its focus to move, and `:Telar` asks for its picker.
  void testEditorTellsItsClient() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.deadline(std::chrono::seconds{10});
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F6>")});

    const auto copied = peer.receive<PaneClipboard>();

    check(copied.pane_id == editor.pane && textView(copied.bytes) == "yanked", "what was yanked reaches the client's clipboard");
    peer.send(NvimNavigate{.pane_id = editor.pane, .direction = PaneDirection::left});

    const auto left = peer.receive<NvimNavigated>();

    check(left.pane_id == editor.pane && left.direction == PaneDirection::left, "an editor without a window on that side says so");
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F7>")});

    const auto pick = peer.receive<NvimPick>();

    check(pick.pane_id == editor.pane && pick.source == NvimPickSource::files);
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F4>")});

    const auto link = peer.receive<NvimLink>();

    check(link.pane_id == editor.pane && link.uri == "https://example.com/docs", "a link opened in the editor reaches who is typing in it");

    const auto buffers = peer.exchange<PathResults>(NvimBuffers{.request_id = 20, .pane_id = editor.pane, .query = "main", .limit = 10});

    check(buffers.request_id == 20 && buffers.complete && buffers.matches.size() == 1 && buffers.matches[0].path == "src/main.cpp" && !buffers.matches[0].positions.empty(), "the buffers its query matches, with where");

    const auto all = peer.exchange<PathResults>(NvimBuffers{.request_id = 21, .pane_id = editor.pane, .query = "", .limit = 2});

    check(all.matches.size() == 2 && all.truncated && all.matches[0].path == "docs/editor.md", "without a query, the most recently used first, up to the limit");
    peer.send(NvimMenuSelect{.pane_id = editor.pane, .item = 2, .accept = true});
    editor.until(peer, "picked 2");
  }

  // The editor says which files its buffers show and asks for the explorer on one; and a file
  // an explorer moves is followed by the editor that may show it, back too when the move is
  // undone.
  void testEditorAndExplorerKnowOfEachOther() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);
    const runtime::TemporaryDirectory directory{"/tmp/telar-moved-XXXXXX"};
    const std::string from = std::string{directory.path()} + "/draft.md";
    const std::string target = std::string{directory.path()} + "/final.md";

    std::ofstream{from} << "text";
    editor.until(peer, "ready");
    peer.deadline(std::chrono::seconds{10});
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F10>")});

    // They reach the client with a frame, which it applies as any other.
    while (editor.files.empty()) {
      editor.next(peer);
    }

    check(editor.files == "/work/main.cpp+ /work/README.md ", "the files of its buffers, and which has changes not written");
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F11>")});

    const auto explore = peer.receive<NvimExplore>();

    check(explore.pane_id == editor.pane && explore.path == "/work/main.cpp", "`:Telar explore` reaches who is typing in the editor");

    const ds::Array<FileOperation, 1> operations{FileOperation{.kind = FileOperationKind::move, .source = from, .target = target}};
    const auto changed = peer.exchange<FilesChanged>(ChangeFiles{.request_id = 40, .operations = operations.view()});

    check(changed.results.size() == 1 && changed.results[0].outcome == FileOutcome::done && std::filesystem::exists(target));
    editor.until(peer, "moved draft.md>final.md");

    const auto undone = peer.exchange<FilesChanged>(UndoFileChanges{.request_id = 41});

    check(undone.results.size() == 1 && undone.results[0].outcome == FileOutcome::done && std::filesystem::exists(from));
    editor.until(peer, "moved final.md>draft.md");
  }

  // A query asked while an older one waits for Neovim's answer is answered, whatever order the
  // answers come in.
  void testNewestBuffersQueryIsAnswered() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.deadline(std::chrono::seconds{10});
    peer.send(NvimBuffers{.request_id = 30, .pane_id = editor.pane, .query = "read", .limit = 10});
    peer.send(NvimBuffers{.request_id = 31, .pane_id = editor.pane, .query = "main", .limit = 10});

    // The stand-in answers the first after the second was asked.
    const auto found = peer.receive<PathResults>();

    check(found.request_id == 31 && found.matches.size() == 1 && found.matches[0].path == "src/main.cpp", "the newest query gets its answer, and the older one none");
  }

  // A yank reaches the clipboard where the user types only when programs may write it: `ask`
  // keeps it from there, as a terminal's program is kept while no client can ask.
  void testYankFollowsTheClipboardPolicy() {
    for (const std::string_view policy : {"ask", "deny"}) {
      EditorHost editor_host{true, {.clipboard_write = std::string{policy}}};
      ProtocolPeer peer{editor_host.host->socket()};
      const auto terminal = openTerminal(peer);
      auto editor = openEditor(peer, terminal);

      editor.until(peer, "ready");
      peer.deadline(std::chrono::seconds{10});
      peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F6>")});
      peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F7>")});

      const auto first = peer.receiveAny<PaneClipboard, NvimPick>();

      check(std::holds_alternative<NvimPick>(first), "what was yanked stays off the client's clipboard");
    }
  }

  // The editor's colorscheme is the theme of the client that owns its workspace, when it
  // attaches and whenever that client changes it.
  void testEditorTakesTheWindowsTheme() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    ConfigureTerminalColors colors;

    colors.foreground.emplace().fill(Byte{0xd0});
    colors.background.emplace().fill(Byte{0x20});
    colors.palette.emplace().fill(Byte{0x40});
    colors.syntax.emplace().fill(Byte{0x90});
    colors.chrome.emplace().fill(Byte{0x60});
    peer.send(colors);

    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F8>")});
    editor.until(peer, "themes 1");
    // The syntax colors alone change nothing a terminal shows, and are an editor's all the same.
    colors.syntax.emplace().fill(Byte{0x99});
    peer.send(colors);
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F8>")});
    editor.until(peer, "themes 2");
  }

  // An editor starts on telar's own configuration, kept under a name of its own, whether the
  // host has a configuration of Neovim or not, and whatever NVIM_APPNAME the runtime has.
  void testEditorStartsOnTelarsConfiguration() {
    runtime::TemporaryDirectory home{"/tmp/telar-nvim-home-XXXXXX"};
    const std::string root{home.path()};

    ::setenv("HOME", root.c_str(), 1);
    ::unsetenv("XDG_CONFIG_HOME");
    ::unsetenv("NVIM_APPNAME");
    ::unsetenv("TELAR_NVIM");
    {
      EditorHost editor_host{true, {.data_home = true}};
      ProtocolPeer peer{editor_host.host->socket()};
      const auto terminal = openTerminal(peer);
      auto editor = openEditor(peer, terminal);

      editor.until(peer, "ready");
      peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F9>")});
      editor.until(peer, "telar's as telar/editor");
    }

    std::filesystem::create_directories(root + "/.config/nvim");
    ::setenv("NVIM_APPNAME", "mine", 1);

    EditorHost editor_host{true, {.data_home = true}};
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F9>")});
    editor.until(peer, "telar's as telar/editor");
    ::unsetenv("NVIM_APPNAME");
  }

  void testPromptIsShownAndAnswered() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F5>")});
    peer.deadline(std::chrono::seconds{10});
    const auto asked = peer.receive<NvimPrompt>();

    check(asked.pane_id == editor.pane && asked.kind == NvimPromptKind::select && asked.title == "Pick" && asked.choices.size() == 2 && asked.choices[1] == "dos", "what Neovim asks reaches the client as a prompt");

    const auto prompt = asked.prompt_id;
    const auto serial = asked.serial;

    peer.send(NvimPromptReply{.pane_id = editor.pane, .prompt_id = prompt, .accepted = true, .index = 1});
    const auto closed = peer.receive<NvimPrompt>();

    check(closed.kind == NvimPromptKind::none && closed.prompt_id == 0 && closed.serial > serial, "once answered, the client is told nothing is asked");
    editor.until(peer, "chose 2");

    peer.send(NvimOpen{.pane_id = editor.pane, .path = "/tmp/notes.md", .line = 7});
    editor.until(peer, "opened /tmp/notes.md:7");
  }

  // A runtime that keeps its session starts the editor again when it restarts, as the pane it
  // was, and a client that attaches is sent its screen.
  // On telar's own configuration it comes back keeping its files under the same name.
  void testEditorReturnsWithTheSession() {
    runtime::TemporaryDirectory home{"/tmp/telar-nvim-home-XXXXXX"};
    const std::string root{home.path()};

    ::setenv("HOME", root.c_str(), 1);
    ::unsetenv("XDG_CONFIG_HOME");
    ::unsetenv("NVIM_APPNAME");
    ::unsetenv("TELAR_NVIM");
    EditorHost editor_host{true, {.session = true, .data_home = true}};
    std::uint64_t pane = 0;

    {
      ProtocolPeer peer{editor_host.host->socket()};
      const auto terminal = openTerminal(peer);
      auto editor = openEditor(peer, terminal);

      editor.until(peer, "ready");
      peer.send(NvimInput{.pane_id = editor.pane, .keys = bytes("<F9>")});
      editor.until(peer, "telar's as telar/editor");
      pane = editor.pane;
    }

    editor_host.host->stop();
    editor_host.host->start();

    ProtocolPeer peer{editor_host.host->socket()};

    peer.send(OpenPane{.request_id = 5, .target = {.kind = PaneTarget::Kind::pane, .id = pane}, .size = size});
    peer.deadline(std::chrono::seconds{10});
    const auto notice = peer.receive<PaneKindNotice>();
    const auto opened = peer.receive<PaneOpened>();

    check(notice.pane_id == pane && notice.kind == PaneKind::nvim && opened.pane_id == pane && !opened.created, "the pane is back, and is an editor");

    Editor restored{.pane = pane};

    restored.until(peer, "ready");
    peer.send(NvimInput{.pane_id = pane, .keys = bytes("<F9>")});
    restored.until(peer, "telar's as telar/editor");
  }

  // A client's editor configuration takes the place of the runtime's machine's, where its Neovim
  // reads it; one that names a path outside it is refused whole.
  void testConfigurationReplacesTheMachines() {
    RuntimeHost host;
    ProtocolPeer peer{host.socket()};
    const std::filesystem::path editor = host.directory() + "/config/telar/editor";
    const ds::Array files{
        NvimConfigurationFile{.path = "init.lua", .content = bytes("require('plugins')\n")},
        NvimConfigurationFile{.path = "lua/plugins/init.lua", .content = bytes("return {}\n")},
    };

    std::filesystem::create_directories(editor);
    std::ofstream{editor / "old.lua"} << "-- the machine's\n";
    peer.send(NvimConfiguration{.request_id = 7, .files = files});
    peer.deadline(std::chrono::seconds{10});
    check(peer.receive<RequestCompleted>().request_id == 7, "the configuration is taken");

    std::ifstream written{editor / "lua/plugins/init.lua"};
    const std::string text{std::istreambuf_iterator<char>{written}, std::istreambuf_iterator<char>{}};

    check(text == "return {}\n" && !std::filesystem::exists(editor / "old.lua"), "the machine holds the client's files and no others");

    const ds::Array escaping{NvimConfigurationFile{.path = "../config.lua", .content = bytes("os.exit()\n")}};

    peer.send(NvimConfiguration{.request_id = 8, .files = escaping});
    const auto refused = peer.receive<RequestFailed>();

    check(refused.request_id == 8 && refused.code == FailureCode::invalid_request, "a path outside the directory is refused");
    check(!std::filesystem::exists(editor.parent_path() / "config.lua") && std::filesystem::exists(editor / "init.lua"), "and nothing is touched");
  }

  void testClosingEndsTheEditor() {
    EditorHost editor_host;
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);
    auto editor = openEditor(peer, terminal);

    editor.until(peer, "ready");
    peer.send(ClosePane{.request_id = 20, .pane_id = editor.pane});
    peer.deadline(std::chrono::seconds{10});

    for (;;) {
      const auto message = peer.receiveAny<PaneExited, NvimFrame>();
      if (const auto* exited = std::get_if<PaneExited>(&message)) {
        check(exited->pane_id == editor.pane && exited->kind == ExitKind::signaled, "the pane ends when its Neovim does");
        break;
      }

      peer.send(FrameAck{editor.pane, std::get<NvimFrame>(message).frame_id});
    }
  }

  void testMissingNeovimFailsTheRequest() {
    EditorHost editor_host{false};
    ProtocolPeer peer{editor_host.host->socket()};
    const auto terminal = openTerminal(peer);

    peer.deadline(std::chrono::seconds{10});
    check(refused(peer, [&] {
      peer.exchange<PaneOpened>(CreateNvimPane{.request_id = 2, .location = terminal.location, .size = size, .cwd = "/tmp"});
    }) == FailureCode::spawn_failed,
        "a host without Neovim says the editor could not start");

    // The tab is as it was: the terminal still opens panes beside it.
    check(peer.exchange<PaneOpened>(CreatePane{.request_id = 3, .location = terminal.location, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}}).created);
  }

  const telar::testing::Case case_draws{"nvim_pane_wire.editor_pane_draws_and_takes_input", testEditorPaneDrawsAndTakesInput};
  const telar::testing::Case case_size{"nvim_pane_wire.editor_pane_follows_its_size", testEditorPaneFollowsItsSize};
  const telar::testing::Case case_tab{"nvim_pane_wire.editor_tab_is_announced", testEditorTabIsAnnounced};
  const telar::testing::Case case_document{"nvim_pane_wire.editor_pane_names_its_document", testEditorPaneNamesItsDocument};
  const telar::testing::Case case_second{"nvim_pane_wire.second_client_is_sent_the_screen_whole", testSecondClientIsSentTheScreenWhole};
  const telar::testing::Case case_refused{"nvim_pane_wire.requests_of_another_kind_are_refused", testRequestsOfAnotherKindAreRefused};
  const telar::testing::Case case_prompt{"nvim_pane_wire.prompt_is_shown_and_answered", testPromptIsShownAndAnswered};
  const telar::testing::Case case_snapshot{"nvim_pane_wire.tab_snapshot_announces_the_editor", testTabSnapshotAnnouncesTheEditor};
  const telar::testing::Case case_text{"nvim_pane_wire.editor_text_is_read", testEditorTextIsRead};
  const telar::testing::Case case_configuration{"nvim_pane_wire.editor_starts_on_telars_configuration", testEditorStartsOnTelarsConfiguration};
  const telar::testing::Case case_tells{"nvim_pane_wire.editor_tells_its_client", testEditorTellsItsClient};
  const telar::testing::Case case_explorer{"nvim_pane_wire.editor_and_explorer_know_of_each_other", testEditorAndExplorerKnowOfEachOther};
  const telar::testing::Case case_newest{"nvim_pane_wire.newest_buffers_query_is_answered", testNewestBuffersQueryIsAnswered};
  const telar::testing::Case case_policy{"nvim_pane_wire.yank_follows_the_clipboard_policy", testYankFollowsTheClipboardPolicy};
  const telar::testing::Case case_theme{"nvim_pane_wire.editor_takes_the_windows_theme", testEditorTakesTheWindowsTheme};
  const telar::testing::Case case_session{"nvim_pane_wire.editor_returns_with_the_session", testEditorReturnsWithTheSession};
  const telar::testing::Case case_configuration_replaces{"nvim_pane_wire.configuration_replaces_the_machines", testConfigurationReplacesTheMachines};
  const telar::testing::Case case_close{"nvim_pane_wire.closing_ends_the_editor", testClosingEndsTheEditor};
  const telar::testing::Case case_missing{"nvim_pane_wire.missing_neovim_fails_the_request", testMissingNeovimFailsTheRequest};

}
