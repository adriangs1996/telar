import std;
import telar.msgpack;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.runtime.nvim.editor;
import telar.wire.editor;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  namespace {

    using namespace telar;
    using namespace telar::runtime;
    using telar::testing::check;

    // One request the editor wrote for Neovim: its method and the bytes of its parameters.
    struct Call {
      std::uint64_t id = 0;
      std::string method;
      std::vector<std::uint8_t> parameters;
    };

    // Takes what the editor queued, as Neovim reading its input would, call by call.
    std::vector<Call> drain(NvimEditor& editor) {
      std::vector<Call> calls;
      auto bytes = editor.pending();
      const auto size = bytes.size();

      while (!bytes.empty()) {
        msgpack::Scanner scanner;
        const auto progress = scanner.feed(bytes);

        check(progress.status == msgpack::Status::ok, "the editor writes whole messages");
        msgpack::Reader reader{bytes.first(progress.consumed)};
        std::uint64_t type = 0;
        Call call;

        check(reader.tuple(4) && reader.unsignedInteger(type) && type == 0 && reader.unsignedInteger(call.id), "each is a request");
        call.method = std::string{reader.string().valueOr("")};
        call.parameters.assign(bytes.begin() + static_cast<std::ptrdiff_t>(reader.offset()), bytes.begin() + static_cast<std::ptrdiff_t>(progress.consumed));
        calls.push_back(std::move(call));
        bytes = bytes.subspan(progress.consumed);
      }

      editor.written(size);
      return calls;
    }

    template <typename Write>
    bool feed(NvimEditor& editor, Write write) {
      std::vector<std::uint8_t> bytes(4096);
      msgpack::Writer writer{bytes};

      write(writer);
      check(!writer.overflowed());
      return editor.receive(writer.written());
    }

    // Neovim's answer to nvim_get_api_info: its channel and its version.
    bool describe(NvimEditor& editor, std::uint64_t request, std::uint64_t minor) {
      return feed(editor, [&](msgpack::Writer& writer) {
        writer.array(4);
        writer.unsignedInteger(1);
        writer.unsignedInteger(request);
        writer.nil();
        writer.array(2);
        writer.unsignedInteger(9);
        writer.map(1);
        writer.string("version");
        writer.map(2);
        writer.string("major");
        writer.unsignedInteger(0);
        writer.string("minor");
        writer.unsignedInteger(minor);
      });
    }

    // An editor attached to a Neovim that described itself, its first requests already read.
    void attach(NvimEditor& editor) {
      const auto asked = drain(editor);

      check(asked.size() == 1 && asked[0].method == "nvim_get_api_info", "the editor first asks what Neovim this is");
      check(describe(editor, asked[0].id, 12) && editor.state() == NvimState::attached && editor.channel() == 9);
    }

    bool prompt(NvimEditor& editor, std::uint64_t id, std::string_view kind, std::initializer_list<std::string_view> choices) {
      return feed(editor, [&](msgpack::Writer& writer) {
        writer.array(3);
        writer.unsignedInteger(2);
        writer.string("telar_prompt");
        writer.array(5);
        writer.unsignedInteger(id);
        writer.string(kind);
        writer.string("Pick one");
        writer.string("first");
        writer.array(static_cast<std::uint32_t>(choices.size()));

        for (const auto choice : choices) {
          writer.string(choice);
        }
      });
    }

    void attachesAfterIdentifying() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 90, .rows = 30}, {}};

      check(editor.state() == NvimState::identifying && editor.input("ia"), "keys typed before Neovim answered are queued for it");
      const auto early = drain(editor);

      check(early.size() == 2 && early[0].method == "nvim_get_api_info" && early[1].method == "nvim_input");
      check(describe(editor, early[0].id, 12) && editor.state() == NvimState::attached);

      const auto calls = drain(editor);
      const auto attached = std::ranges::find(calls, "nvim_ui_attach", &Call::method);

      check(attached != calls.end() && attached == calls.end() - 1, "attaching is the last thing asked, after what must hold before the configuration loads");
      check(std::ranges::find(calls, "nvim_exec_lua", &Call::method) < attached, "vim.ui is taken over before the configuration loads");

      msgpack::Reader reader{attached->parameters};
      std::uint64_t columns = 0;
      std::uint64_t rows = 0;

      check(reader.tuple(3) && reader.unsignedInteger(columns) && reader.unsignedInteger(rows) && columns == 90 && rows == 30, "with the size of its pane");
    }

    void refusesAnOldNeovim() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};
      const auto asked = drain(editor);

      check(!describe(editor, asked[0].id, 9) && editor.state() == NvimState::failed && !editor.failure().empty(), "a Neovim older than the editor reads is refused, with the reason");
      check(!editor.input("x") && drain(editor).empty(), "and is asked nothing more");
    }

    void promptIsAnsweredOnce() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};

      attach(editor);
      drain(editor);
      const auto before = editor.promptSerial();

      check(prompt(editor, 4, "select", {"uno", "dos"}), "a prompt is not a reason to fail");
      const auto& asked = editor.prompt();
      const std::string_view text{asked.text.data(), asked.text.size()};

      check(asked.id == 4 && asked.kind == NvimPromptKind::select && asked.title.view() == "Pick one" && asked.choices.size() == 2 && asked.choices[1].of(text) == "dos", "what was asked, as a client is told it");
      check(editor.promptSerial() > before, "a client learns that it changed");
      check(!editor.answer({.id = 3, .accepted = true}) && drain(editor).empty(), "an answer to another prompt is dropped");
      check(editor.answer({.id = 4, .accepted = true, .index = 1}), "the answer is taken");

      const auto calls = drain(editor);

      check(calls.size() == 1 && calls[0].method == "nvim_exec_lua", "and handed to what asked");
      msgpack::Reader reader{calls[0].parameters};
      std::uint64_t id = 0;
      std::uint64_t index = 0;
      bool accepted = false;

      check(reader.tuple(2) && reader.string().hasValue() && reader.tuple(4) && reader.unsignedInteger(id) && reader.boolean(accepted) && reader.unsignedInteger(index) && id == 4 && accepted && index == 2, "with the choice counted as Lua counts");
      check(editor.prompt().id == 0 && !editor.answer({.id = 4, .accepted = true}), "a prompt is answered once");
    }

    void newerPromptDismissesTheOlder() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};

      attach(editor);
      drain(editor);
      check(prompt(editor, 1, "input", {}) && prompt(editor, 2, "select", {"a"}));

      const auto calls = drain(editor);

      check(editor.prompt().id == 2 && calls.size() == 1 && calls[0].method == "nvim_exec_lua", "whatever asked first is told nothing was chosen");
      check(prompt(editor, 0, "select", {}) && prompt(editor, 5, "other", {}) && editor.prompt().id == 2, "what does not read as a prompt changes nothing");
    }

    void opensAFileWhereAsked() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};

      attach(editor);
      drain(editor);
      check(editor.open({.path = "/tmp/it's a file.txt", .line = 12, .column = 3}) && !editor.open({}), "a place needs a path");

      const auto calls = drain(editor);
      msgpack::Reader reader{calls.at(0).parameters};
      std::uint64_t line = 0;

      // The path travels as an argument, never as part of the script Neovim runs.
      check(calls.size() == 1 && reader.tuple(2) && !reader.string().valueOr("").contains("it's") && reader.tuple(4) && reader.string() == std::string_view{"/tmp/it's a file.txt"} && reader.unsignedInteger(line) && line == 12);

      std::uint64_t column = 0;
      std::uint64_t where = 0;

      check(reader.unsignedInteger(column) && column == 3 && reader.unsignedInteger(where) && where == std::to_underlying(NvimOpenIn::place), "in the window that shows it, unless asked otherwise");
      check(editor.open({.path = "/tmp/b", .in = NvimOpenIn::tab}));
    }

    // A notification from telar's side of the conversation in Neovim: `[2, name, [parameters]]`.
    template <typename Parameters>
    bool tell(NvimEditor& editor, std::string_view name, std::uint32_t count, Parameters parameters) {
      return feed(editor, [&](msgpack::Writer& writer) {
        writer.array(3);
        writer.unsignedInteger(2);
        writer.string(name);
        writer.array(count);
        parameters(writer);
      });
    }

    TerminalTheme sampleTheme() {
      TerminalTheme theme;

      theme.foreground.emplace().fill(Byte{0xd0});
      theme.background.emplace().fill(Byte{0x20});
      theme.palette.emplace().fill(Byte{0x40});
      theme.syntax.emplace().fill(Byte{0x90});
      theme.chrome.emplace().fill(Byte{0x60});
      theme.syntax_bold = 1U << 1U;
      return theme;
    }

    // The window's theme reaches a Neovim that attaches after it was given, before the
    // configuration loads, and one already attached at once.
    void themeIsTheColorscheme() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};
      auto theme = sampleTheme();

      check(!editor.theme(TerminalTheme{}), "a theme without all its colors is not one");
      check(!editor.theme(theme), "before Neovim attached nothing is sent");
      attach(editor);

      const auto calls = drain(editor);
      const auto themed = std::ranges::find_if(calls, [](const Call& call) {
        return call.method == "nvim_exec_lua" && std::string_view{reinterpret_cast<const char*>(call.parameters.data()), call.parameters.size()}.contains("__telar_theme(...)");
      });
      const auto attached = std::ranges::find(calls, "nvim_ui_attach", &Call::method);

      check(themed != calls.end() && attached != calls.end() && themed < attached, "the theme is the colorscheme before the UI attaches and the configuration loads");

      const std::string_view sent{reinterpret_cast<const char*>(themed->parameters.data()), themed->parameters.size()};

      check(sent.contains("#d0d0d0") && sent.contains("#202020") && sent.contains("#404040") && sent.contains("#909090") && sent.contains("#606060"), "with every color it has");
      check(sent.contains("keyword") && sent.contains("panel_bg") && !sent.contains("cursor"), "each under its name, and none it lacks");
      check(!editor.theme(theme) && drain(editor).empty(), "the same theme again sends nothing");
      theme.cursor.emplace().fill(Byte{0xff});
      check(editor.theme(theme) && drain(editor).size() == 1, "another one is sent at once");
    }

    // What runs in Neovim tells the runtime of the clipboard, the directory, the way out of the
    // last window, the picker and the buffers. Anything can send these: what is not what it
    // names is passed over.
    void neovimTellsTheRuntime() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};

      attach(editor);
      drain(editor);
      static_cast<void>(editor.takePulse());
      check(tell(editor, "telar_clipboard", 1, [](msgpack::Writer& writer) {
        writer.string("two\nlines");
      }));
      check(tell(editor, "telar_navigate", 1, [](msgpack::Writer& writer) {
        writer.string("left");
      }));
      check(tell(editor, "telar_pick", 1, [](msgpack::Writer& writer) {
        writer.string("grep");
      }));
      check(tell(editor, "telar_buffers", 2, [](msgpack::Writer& writer) {
        writer.unsignedInteger(7);
        writer.array(3);
        writer.string("src/main.cpp");
        writer.string("bad\x01name");
        writer.string("README.md");
      }));
      check(tell(editor, "telar_directory", 1, [](msgpack::Writer& writer) {
        writer.string("/srv/project");
      }));

      const auto pulse = editor.takePulse();

      check(pulse.copied && editor.clipboard() == "two\nlines", "what was yanked is kept for the clipboard");
      check(pulse.navigated && *pulse.navigated == PaneDirection::left && pulse.pick && *pulse.pick == NvimPickSource::text);
      check(pulse.listed && editor.buffers().token == 7 && editor.buffers().names.size() == 2, "a name a client could not list is left out");
      check(editor.screen().directory() == "/srv/project" && pulse.flushed, "the directory is published at once when no redraw is under way");
      check(tell(editor, "telar_directory", 1, [](msgpack::Writer& writer) {
        writer.string("relative/place");
      }));
      check(editor.screen().directory() == "/srv/project", "a directory not named from the root says nothing of where the editor works");

      check(tell(editor, "telar_navigate", 1, [](msgpack::Writer& writer) {
        writer.string("sideways");
      }));
      check(tell(editor, "telar_clipboard", 1, [](msgpack::Writer& writer) {
        writer.unsignedInteger(3);
      }));
      check(tell(editor, "telar_unknown", 0, [](msgpack::Writer&) {}));

      const auto after = editor.takePulse();

      check(!after.navigated && !after.copied && editor.state() == NvimState::attached, "what is not what it names changes nothing");

      // A link opens for something the person did, once, and only one of the web or of mail.
      const auto open = [&](std::string_view uri) {
        check(tell(editor, "telar_open", 1, [&](msgpack::Writer& writer) {
          writer.string(uri);
        }));
        return editor.takePulse().opened;
      };

      check(!open("https://example.com/unasked"), "nothing in the editor opens a link by itself");
      check(editor.input("gx") && !open("file:///etc/passwd") && editor.link().empty(), "a file of the host is not a link for the person's machine");
      check(editor.input("gx") && open("https://example.com/docs") && editor.link() == "https://example.com/docs");
      check(!open("https://example.com/again"), "one link for each thing the person does");
    }

    // What the runtime asks of Neovim for a client: a side to move to, an item of the menu,
    // the buffers, a preview and a list of places.
    void clientsAskThroughTheRuntime() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};
      const ds::Array<TextMatch, 1> places{TextMatch{.path = "a.cpp", .line = 4, .column = 2, .text = "int a;"}};

      check(!editor.navigate(PaneDirection::up) && !editor.selectMenu(0, true), "nothing is asked before Neovim attached");
      attach(editor);
      drain(editor);
      check(editor.navigate(PaneDirection::up) && editor.selectMenu(3, true) && editor.listBuffers(9) && editor.preview({.path = "/tmp/a", .line = 2}, {.row = 1, .column = 2, .columns = 30, .rows = 8}) && editor.list(places.view()));
      check(!editor.list({}), "an empty list is not one");

      const auto calls = drain(editor);

      check(calls.size() == 5 && calls[1].method == "nvim_select_popupmenu_item");

      msgpack::Reader menu{calls[1].parameters};
      std::uint64_t item = 0;
      bool insert = false;
      bool finish = false;

      check(menu.tuple(4) && menu.unsignedInteger(item) && item == 3 && menu.boolean(insert) && insert && menu.boolean(finish) && finish, "the item is taken as a key that accepts it would");
    }

    // Without what the runtime teaches it, Neovim would attach half taught: the editor fails.
    void refusedBootstrapFailsTheEditor() {
      testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      NvimEditor editor{memory, {.columns = 80, .rows = 24}, {}};

      attach(editor);

      const auto calls = drain(editor);
      const auto taught = std::ranges::find(calls, "nvim_exec_lua", &Call::method);

      check(taught != calls.end());
      check(!feed(editor, [&](msgpack::Writer& writer) {
        writer.array(4);
        writer.unsignedInteger(1);
        writer.unsignedInteger(taught->id);
        writer.string("E5108: Lua error");
        writer.nil();
      }) && editor.state() == NvimState::failed);
    }

  }

  const telar::testing::Case case_attach{"nvim_editor.attaches_after_identifying", attachesAfterIdentifying};
  const telar::testing::Case case_old{"nvim_editor.refuses_an_old_neovim", refusesAnOldNeovim};
  const telar::testing::Case case_prompt{"nvim_editor.prompt_is_answered_once", promptIsAnsweredOnce};
  const telar::testing::Case case_newer{"nvim_editor.newer_prompt_dismisses_the_older", newerPromptDismissesTheOlder};
  const telar::testing::Case case_open{"nvim_editor.opens_a_file_where_asked", opensAFileWhereAsked};
  const telar::testing::Case case_theme{"nvim_editor.theme_is_the_colorscheme", themeIsTheColorscheme};
  const telar::testing::Case case_told{"nvim_editor.neovim_tells_the_runtime", neovimTellsTheRuntime};
  const telar::testing::Case case_asks{"nvim_editor.clients_ask_through_the_runtime", clientsAskThroughTheRuntime};
  const telar::testing::Case case_bootstrap{"nvim_editor.refused_bootstrap_fails_the_editor", refusedBootstrapFailsTheEditor};

}
