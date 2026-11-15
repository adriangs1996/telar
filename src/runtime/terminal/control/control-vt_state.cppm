module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control:vt_state;

import std;
import telar.ghostty.vt;
import telar.tbc;
import telar.vocabulary;
import telar.runtime.terminal.ghostty;
import telar.runtime.terminal.kitty;

export namespace telar::runtime::control {

  struct Position {
    std::uint16_t column;
    std::uint16_t row;
  };

  struct Margins {
    std::uint16_t top;
    std::uint16_t bottom;
    std::uint16_t left;
    std::uint16_t right;
  };

  // These handles are borrowed from one nonmovable Terminal. No query is fed
  // through this adapter; getters expose only current VT state. The owner must
  // destroy the controller before freeing either handle.
  class VtState {
  public:
    // Keeps the terminal's handles, region `a`.
    void bind(tbc::view<GhosttyTerminal, tbc::lt::a> terminal, tbc::view<GhosttyRenderState, tbc::lt::a> render, bool separate_media) noexcept;

    void write(std::span<const std::uint8_t> bytes);

    // The caller verifies that each ESC begins a complete numeric SGR.
    // Partial graphics framing still observes every byte through the old path.
    void writeNonGraphics(std::span<const std::uint8_t> bytes);

    // Writes the ordinary run of `input` that starts at `offset`, which is not ESC or ENQ, and
    // returns where it ends: ASCII up to the next stop, widened in batches, or bytes up to the
    // next native controller boundary, crossing only complete bounded numeric SGRs.
    std::size_t writeOrdinaryRun(std::span<const std::uint8_t> input, std::size_t offset);

    bool canWriteAscii() const noexcept;

    constexpr void failWrite() noexcept {
      write_failed_ = true;
    }

    // An intercepted ESC must still resolve a partial UTF-8 character in the
    // non-query backend at that exact stream position. Only framing/cancellation
    // is forwarded; the query itself never enters the external handler.
    constexpr bool needsEscapeBoundary() const noexcept {
      return possibly_pending_input_;
    }

    void escapeBoundary();

    void configureSize(TerminalSize size) noexcept;

    void invalidateColors() noexcept;

    TerminalSize size() const;

    bool mode(std::uint16_t number, bool ansi = false) const;

    void setMode(std::uint16_t number, bool enabled);

    // Follows the cursor's row through reflow.
    TrackedRow trackCursorRow() const;

    Position cursor() const;

    bool primaryScreen() const;

    Margins margins() const;

    std::uint8_t keyboard() const;

    GhosttyStyle style() const;

    GhosttyRenderStateCursor visualCursor() const;

    std::optional<GhosttyColorRgb> color(unsigned selector);

    std::optional<GhosttyGridRef> reference(Position position) const;

    std::string_view title() const;

    // Only after canWriteAscii(): the engine admits the graphics scanner once
    // before entering its ASCII loop. Only synchronous widening and queue release
    // intervene; no scanner mutation occurs. The C bridge still validates its
    // input and partial application.
    void writeAscii(std::span<const std::uint32_t> codepoints);

    static constexpr unsigned foreground = 256;
    static constexpr unsigned background = 257;
    static constexpr unsigned cursor_color = 258;

  private:
    template <bool CheckGraphics>
    void writeInput(std::span<const std::uint8_t> bytes);

    // A value read once per epoch. Like a Rust `Cell`, reading it through a shared reference may refresh
    // it; it hands out copies only. Generic over the value and the caller's read, so it stays here.
    template <typename Value>
    class TBC_SHARED TBC_GENERIC Cached {
    public:
      template <typename Read>
      Value get(std::uint64_t epoch, Read&& read) const {
        if (epoch_ != epoch) {
          value_ = read();
          epoch_ = epoch;
        }

        return value_;
      }

      void store(std::uint64_t epoch, Value value) const noexcept {
        value_ = value;
        epoch_ = epoch;
      }

      void reset() const noexcept {
        epoch_ = 0;
      }

    private:
      mutable std::uint64_t epoch_ = 0;
      mutable Value value_{};
    };

    struct ModeCache {
      std::uint64_t epoch = 0;
      std::uint16_t number = 0;
      bool ansi = false;
      bool value = false;
    };

    // This adapter is the sole VT mutation boundary for the controller. Cached
    // values are copied scalars/structs, never borrowed terminal storage.
    void invalidate() noexcept;

    void resetEpoch() noexcept;

    GhosttyTerminalCursorState readCursorState() const;

    static constexpr std::uint16_t origin_mode = 6;
    static constexpr unsigned mode_ansi_hash = 32;
    std::uint64_t epoch_ = 1;
    Cached<TerminalSize> size_cache_;
    Cached<Position> cursor_cache_;
    Cached<Margins> margin_cache_;
    Cached<std::uint8_t> keyboard_cache_;
    Cached<GhosttyStyle> style_cache_;
    Cached<GhosttyRenderStateCursor> visual_cursor_cache_;
    mutable std::array<ModeCache, 64> modes_;
    std::array<std::optional<GhosttyColorRgb>, 3> colors_;
    std::array<bool, 3> color_valid_{};
    tbc::view<GhosttyTerminal, tbc::lt::a> terminal_ = nullptr;
    tbc::view<GhosttyRenderState, tbc::lt::a> render_ = nullptr;
    GraphicsCursor graphics_cursor_;
    TerminalSize size_{};
    std::array<GhosttyColorRgb, 256> palette_;
    bool palette_valid_ = false;
    bool possibly_pending_input_ = false;
    bool separate_media_ = false;
    bool write_failed_ = false;
  };

}
