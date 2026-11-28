module;

// The commands a person pinned to the top of the history panel, kept by the window between
// sessions: their text, as the file that keeps them writes it.
export module telar.gui.features.history:pins;

import std;

import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::gui::features::history {

  class HistoryPins {
  public:
    static constexpr std::size_t capacity = 32;
    static constexpr std::size_t maximum_command_bytes = 4096;

    explicit HistoryPins(Memory& memory);

    // Pins `command`, or unpins it; true when it is pinned now. Throws std::length_error when the
    // command is too long or the pins are full.
    bool toggle(std::string_view command);

    [[nodiscard]] bool pinned(std::string_view command) const;

    [[nodiscard]] std::size_t count() const noexcept;

    // Pin `index`, newest pinned first.
    [[nodiscard]] std::string_view at(std::size_t index) const;

    // The pins as the file keeps them: one a line, a backslash and a newline escaped.
    void write(ds::String<Memory>& destination) const;

    // Replaces the pins with those `source` keeps; a line past the bounds is left out.
    void read(std::string_view source);

  private:
    struct Pin {
      std::size_t offset = 0;
      std::size_t length = 0;
    };

    void append(std::string_view command);

    ds::Array<Pin, capacity> pins_{};
    std::size_t count_ = 0;
    ds::String<Memory> text_;
  };

}
