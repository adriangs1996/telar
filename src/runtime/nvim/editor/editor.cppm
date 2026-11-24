export module telar.runtime.nvim.editor;

import std;
import telar.tbc;
import telar.msgpack;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.editor;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.runtime.nvim.rpc;
import telar.runtime.nvim.screen;

// Interface: nvim/editor.cppm
export {
  namespace telar::runtime {

    struct NvimSize {
      static constexpr std::uint16_t default_columns = 80;
      static constexpr std::uint16_t default_rows = 24;

      std::uint16_t columns = default_columns;
      std::uint16_t rows = default_rows;

      constexpr bool operator==(const NvimSize&) const noexcept = default;
    };

    // What the runtime draws itself, each in place of the cells Neovim would draw it with.
    struct NvimSurfaces {
      bool command_line = false;
      bool completion = false;
      bool messages = false;
      bool tabs = false;
    };

    enum class NvimState : std::uint8_t {
      // Asked what Neovim it is; the answer decides whether to attach.
      identifying,
      // Attached as its only UI.
      attached,
      // What it wrote was not the protocol, or passed a limit: it is to be closed.
      failed,
    };

    // What happened since the owner last asked.
    struct NvimPulse {
      // A flush ended: the screen has something new to show.
      bool flushed = false;
      bool bell = false;
      // Something was yanked to a clipboard register: see NvimEditor::clipboard().
      bool copied = false;
      // The buffers asked for arrived: see NvimEditor::buffers().
      bool listed = false;
      // The editor had no window on that side of its current one.
      ds::Option<PaneDirection> navigated;
      // `:Telar` asked for a picker.
      ds::Option<NvimPickSource> pick;
      // Something opened a link: see NvimEditor::link().
      bool opened = false;
      // `:Telar explore` asked for the explorer: see NvimEditor::explored().
      bool explore = false;
    };

    // The names of the editor's listed buffers, most recently used first, as views of `text`,
    // for the request `token` names.
    struct NvimBufferList {
      explicit NvimBufferList(ConcurrentMemory& memory);

      std::uint64_t token = 0;
      ds::Vec<char, ConcurrentMemory> text;
      ds::Vec<NvimSlice, ConcurrentMemory> names;
    };

    // What something in Neovim asks the user through vim.ui.select or vim.ui.input, until it is
    // answered. `id` is zero when nothing is asked.
    struct NvimPromptRequest {
      explicit NvimPromptRequest(ConcurrentMemory& memory);

      std::uint64_t id = 0;
      NvimPromptKind kind = NvimPromptKind::none;
      ds::String<ConcurrentMemory> title;
      ds::String<ConcurrentMemory> initial;
      // Who asks: the language server of a code action, or the caller's kind; empty for none.
      ds::String<ConcurrentMemory> origin;
      // The choices of a selection, in order, as views of `text`.
      ds::Vec<char, ConcurrentMemory> text;
      ds::Vec<NvimSlice, ConcurrentMemory> choices;
    };

    // The user's answer to a prompt: the choice at `index`, counted from zero, or the `text`.
    struct NvimAnswer {
      std::uint64_t id = 0;
      bool accepted = false;
      std::uint32_t index = 0;
      std::string_view text;
    };

    // A place in a file, its line and column counted from one, zero for wherever the cursor is.
    struct NvimPlace {
      std::string_view path;
      std::uint32_t line = 0;
      std::uint32_t column = 0;
      NvimOpenIn in = NvimOpenIn::place;
    };

    // The cells of the editor a float covers, from its top left one.
    struct NvimArea {
      std::uint16_t row = 0;
      std::uint16_t column = 0;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
    };

    // One Neovim started with --embed, as the conversation over its pipes: what to write to its
    // standard input and what its standard output means. It owns no descriptor: its owner reads
    // and writes the pipes, so the same conversation runs against a recording in a test.
    class NvimEditor {
    public:
      // The oldest Neovim whose UI events this reads, as its major version times a thousand plus
      // its minor one: 0.11 added the order floats are composed in.
      static constexpr std::uint64_t minimum_version = 11;
      // The bytes waiting for Neovim to read them, past which input is dropped.
      static constexpr std::size_t output_limit = std::size_t{4} * 1024 * 1024;
      static constexpr std::size_t input_limit = std::size_t{64} * 1024;

      explicit NvimEditor(ConcurrentMemory& memory, NvimSize size, NvimSurfaces surfaces);

      // The bytes Neovim wrote. False once it failed: see state().
      bool receive(std::span<const std::uint8_t> bytes);

      // The bytes to write to Neovim, and how many of them were written.
      [[nodiscard]] std::span<const std::uint8_t> pending() const noexcept;
      void written(std::size_t count) noexcept;

      // Keys in Neovim's notation, as nvim_input() takes them. Neovim takes what its input has
      // room for, and the rest goes again, in order. False when they do not fit.
      bool input(std::string_view keys);
      bool paste(std::string_view text);
      // A mouse event on a cell of a grid, as a client sent it.
      bool mouse(const NvimMouse& event);
      void resize(NvimSize size);
      void focus(bool focused);
      bool command(std::string_view command);
      // Shows a file where `place.in` says.
      bool open(const NvimPlace& place);
      // The window's theme as the colorscheme. False when its colors are not all there.
      bool theme(const TerminalTheme& colors);
      // Moves to the window on a side; `takePulse().navigated` says there was none.
      bool navigate(PaneDirection direction);
      // A file was moved from `from` to `target`: the buffer that shows it, if one does, shows it
      // under its new name, with its changes and its undo. Nothing is written for it.
      bool follow(std::string_view from, std::string_view target);
      // Selects an item of the completion menu, and takes it when `accept`.
      bool selectMenu(std::uint32_t item, bool accept);
      // Asks for the listed buffers, which arrive as `buffers()` with this token. A list asked
      // for before is dropped when it arrives.
      bool listBuffers(std::uint64_t token);
      // Shows a file in a float that takes no focus over `area`; without an area, closes it.
      bool preview(const NvimPlace& place, NvimArea area);
      // Fills the quickfix list with places and opens it.
      bool list(std::span<const TextMatch> places);
      // Hands the user's answer to whatever asked. False for a prompt that is no longer open.
      bool answer(const NvimAnswer& answer);

      [[nodiscard]] NvimState state() const noexcept;
      [[nodiscard]] const NvimScreen& screen() const noexcept;
      [[nodiscard]] NvimSize size() const noexcept;
      // The channel Neovim knows the runtime by; zero until it answered.
      [[nodiscard]] std::uint64_t channel() const noexcept;
      // Why it failed, for the pane's log.
      [[nodiscard]] tbc::val_static<std::string_view> failure() const noexcept;
      [[nodiscard]] NvimPulse takePulse() noexcept;
      // What is asked of the user now, and a count that grows each time that changes.
      [[nodiscard]] const NvimPromptRequest& prompt() const noexcept;
      [[nodiscard]] std::uint64_t promptSerial() const noexcept;
      // The text last yanked to a clipboard register.
      [[nodiscard]] std::string_view clipboard() const noexcept;
      // The link last opened in the editor.
      [[nodiscard]] std::string_view link() const noexcept;
      // The file the explorer was last asked for, or nothing for the editor's directory.
      [[nodiscard]] std::string_view explored() const noexcept;
      [[nodiscard]] const NvimBufferList& buffers() const noexcept;

    private:
      bool handle(std::span<const std::uint8_t> message);
      bool notified(msgpack::Reader& reader, std::span<const std::uint8_t> message);
      bool answered(msgpack::Reader& reader, std::span<const std::uint8_t> message);
      // Sends the typed keys Neovim has not taken.
      bool sendTyped();
      // Neovim's answer to the keys under way: how many of their bytes it took.
      void took(bool refused, msgpack::Reader& reader);
      // A flush ended: what waited for Neovim to read some of its input goes again.
      void drew();
      bool identified(std::span<const std::uint8_t> result);
      bool prompted(std::span<const std::uint8_t> parameters);
      // What telar's own side of the conversation in Neovim says, by the notification's name.
      void told(std::string_view method, std::span<const std::uint8_t> parameters);
      void copied(msgpack::Reader& reader);
      void opened(msgpack::Reader& reader);
      void moved(msgpack::Reader& reader);
      void placedStatus(msgpack::Reader& reader);
      void framed(msgpack::Reader& reader);
      void changed(msgpack::Reader& reader, bool buffers);
      void filed(msgpack::Reader& reader);
      void explore(msgpack::Reader& reader);
      void listed(msgpack::Reader& reader);
      // Publishes a change made outside a redraw, unless a redraw under way will.
      void publish(bool was_settled) noexcept;
      // Asks for the frame of every float placed since it was last asked.
      void frameFloats();
      bool sendTheme();
      void dismissPrompt();
      void attach();
      void refuse(std::uint64_t id);
      bool fail(tbc::val_static<std::string_view> reason) noexcept;

      ConcurrentMemory& memory_;
      NvimInbox inbox_;
      NvimScreen screen_;
      ByteQueue<ConcurrentMemory> output_;
      NvimSize size_;
      NvimSurfaces surfaces_;
      NvimPulse pulse_;
      NvimPromptRequest prompt_;
      std::uint64_t prompt_serial_ = 0;
      // The theme last given, sent again to a Neovim that attaches after it.
      ds::Option<TerminalTheme> theme_;
      ds::String<ConcurrentMemory> clipboard_;
      ds::String<ConcurrentMemory> link_;
      ds::String<ConcurrentMemory> explored_;
      // Whether the person did something that may open a link: one link opens for each thing
      // they do, so nothing in the editor opens links by itself, or many at once. It holds from
      // the keys or the click until the first flush after Neovim took them, which is drawn once
      // it ran what they map to.
      bool asked_ = false;
      // The click under way, until Neovim answered it; zero for none.
      std::uint32_t click_request_ = 0;
      // Keys typed and not yet taken. Neovim's input takes what it has room for, so one call
      // carries them at a time and what it left goes again, ahead of what was typed since.
      ByteQueue<ConcurrentMemory> typed_;
      // The nvim_input under way and how many bytes of `typed_` it carries; zero for none.
      std::uint32_t input_request_ = 0;
      std::size_t input_sent_ = 0;
      // Neovim took none of the last keys: they go again once it drew, having read its input.
      bool input_stalled_ = false;
      NvimBufferList buffers_;
      // The token of the last list asked for.
      std::uint64_t buffers_asked_ = 0;
      std::uint64_t channel_ = 0;
      // The first request asks what Neovim this is.
      std::uint32_t identify_request_ = 1;
      std::uint32_t next_request_ = identify_request_ + 1;
      // The request that teaches Neovim telar's side of the conversation; zero before it is sent.
      std::uint32_t bootstrap_request_ = 0;
      tbc::val_static<std::string_view> failure_;
      NvimState state_ = NvimState::identifying;
      bool focused_ = true;
    };

  }
}
