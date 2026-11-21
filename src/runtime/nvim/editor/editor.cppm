export module telar.runtime.nvim.editor;

import std;
import telar.tbc;
import telar.msgpack;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.nvim;
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
    };

    // What something in Neovim asks the user through vim.ui.select or vim.ui.input, until it is
    // answered. `id` is zero when nothing is asked.
    struct NvimPromptRequest {
      explicit NvimPromptRequest(ConcurrentMemory& memory);

      std::uint64_t id = 0;
      NvimPromptKind kind = NvimPromptKind::none;
      ds::String<ConcurrentMemory> title;
      ds::String<ConcurrentMemory> initial;
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

      // Keys in Neovim's notation, as nvim_input() takes them. False when they do not fit.
      bool input(std::string_view keys);
      bool paste(std::string_view text);
      // A mouse event on a cell of a grid, as a client sent it.
      bool mouse(const NvimMouse& event);
      void resize(NvimSize size);
      void focus(bool focused);
      bool command(std::string_view command);
      // Shows a file, in the window that already shows it or in the current one.
      bool open(const NvimPlace& place);
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

    private:
      bool handle(std::span<const std::uint8_t> message);
      bool notified(msgpack::Reader& reader, std::span<const std::uint8_t> message);
      bool answered(msgpack::Reader& reader, std::span<const std::uint8_t> message);
      bool identified(std::span<const std::uint8_t> result);
      bool prompted(std::span<const std::uint8_t> parameters);
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
      std::uint64_t channel_ = 0;
      // The first request asks what Neovim this is.
      std::uint32_t identify_request_ = 1;
      std::uint32_t next_request_ = identify_request_ + 1;
      tbc::val_static<std::string_view> failure_;
      NvimState state_ = NvimState::identifying;
      bool focused_ = true;
    };

  }
}
