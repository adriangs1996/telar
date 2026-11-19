export module telar.gui.foundation.text:bounded_editor;

import std;
import telar.tbc;
import telar.base.ds;

// Interface: text/grapheme_cursor.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    class GraphemeCursor {
    public:
      explicit GraphemeCursor(std::string_view text) noexcept;

      [[nodiscard]] std::size_t position() const noexcept;

      [[nodiscard]] std::uint8_t columns() const noexcept;

      [[nodiscard]] ds::Option<std::string_view> next();

      [[nodiscard]] ds::Option<std::string_view> nextReplacingInvalid() noexcept;

    private:
      template <bool ReplaceInvalid>
      [[nodiscard]] ds::Option<std::string_view> advance() noexcept(ReplaceInvalid);

      static constexpr std::size_t codepoint_window = 16;
      static constexpr unsigned char first_printable_ascii = 0x20;
      static constexpr unsigned char ascii_delete = 0x7f;
      static constexpr unsigned char first_multibyte = 0x80;
      static constexpr std::uint32_t last_control = 0x9f;

      std::string_view text_;
      std::size_t position_ = 0;
      std::uint8_t columns_ = 0;
    };

  }
}

// Interface: text/cell_text_measure.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    std::uint32_t cellTextColumns(std::string_view text);

  }
}

// Interface: text/editor_view.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    struct EditorColumns {
      std::uint16_t first = 0;
      std::uint16_t last = 0;
    };

    struct EditorView {
      std::string_view text;
      std::uint16_t cursor = 0;
      ds::Option<EditorColumns> selection;
      bool clipped_left = false;
      bool clipped_right = false;
    };

  }
}

// Interface: text/bounded_editor.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    template <std::size_t Capacity>
    class BoundedEditor {
    public:
      static_assert(Capacity <= std::numeric_limits<std::uint16_t>::max());
      static constexpr std::size_t capacity = Capacity;

      [[nodiscard]] std::string_view text() const noexcept;

      [[nodiscard]] std::size_t head() const noexcept;

      [[nodiscard]] std::size_t anchor() const noexcept;

      [[nodiscard]] std::size_t scroll() const noexcept;

      [[nodiscard]] bool hasSelection() const noexcept;

      [[nodiscard]] std::string_view selected() const noexcept;

      bool setText(std::string_view value) noexcept;

      bool selectRange(std::size_t anchor, std::size_t head) noexcept;

      void selectAll() noexcept;

      void clearSelection() noexcept;

      bool replace(std::size_t first, std::size_t last, std::string_view value) noexcept;

      void insert(std::string_view value) noexcept;

      void backspace();

      void deleteForward();

      void moveLeft(bool extend);

      void moveRight(bool extend);

      void home(bool extend) noexcept;

      void end(bool extend) noexcept;

      void moveWordLeft(bool extend) noexcept;

      [[nodiscard]] EditorView view(std::uint16_t width);

    private:
      static constexpr unsigned char continuation_mask = 0xc0;
      static constexpr unsigned char continuation_prefix = 0x80;

      [[nodiscard]] static bool validUtf8(std::string_view value) noexcept;

      [[nodiscard]] bool boundary(std::size_t position) const noexcept;

      [[nodiscard]] static bool isSpace(char byte) noexcept;

      bool deleteSelection() noexcept;

      void remove(std::size_t first, std::size_t last) noexcept;

      [[nodiscard]] ds::Option<std::size_t> clusterBefore(std::size_t position) const;

      [[nodiscard]] ds::Option<std::size_t> clusterAfter(std::size_t position) const;

      [[nodiscard]] std::size_t startOfLine(std::size_t position, std::uint16_t width) const;

      [[nodiscard]] std::uint16_t columnsBetween(std::size_t first, std::size_t last) const;

      ds::Array<char, Capacity> bytes_{};
      std::size_t length_ = 0;
      std::size_t head_ = 0;
      std::size_t anchor_ = 0;
      std::size_t scroll_ = 0;
    };

    // The native form field's text and display editors.
    extern template class BoundedEditor<512>;
    extern template class BoundedEditor<8192>;

  }
}

// Interface: text/caption_runs.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    class CaptionRuns {
    public:
      explicit CaptionRuns(std::string_view text) noexcept;

      [[nodiscard]] ds::Option<std::string_view> next() noexcept;

    private:
      static constexpr std::size_t maximum_bytes = 64;
      static constexpr std::size_t maximum_codepoints = 30;
      static constexpr unsigned char continuation_mask = 0xc0;
      static constexpr unsigned char continuation_tag = 0x80;
      static constexpr std::string_view replacement = "�";

      GraphemeCursor cursor_;
      std::size_t bytes_;
      ds::Array<char, maximum_bytes> storage_{};
    };

  }
}

// Interface: text/utf16_prefix.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    struct Utf16Encoding {
      std::size_t invalid_scalar_bytes = 0;
    };

    struct Utf16Prefix {
      static constexpr char16_t first_high_surrogate = 0xd800;
      static constexpr char16_t last_high_surrogate = 0xdbff;
      static constexpr char16_t first_low_surrogate = 0xdc00;
      static constexpr char16_t last_low_surrogate = 0xdfff;
      static constexpr std::size_t paired_units = 2;
      static constexpr std::size_t paired_bytes = 4;
      static constexpr std::size_t three_byte_scalar = 3;

      std::size_t units = 0;
      std::size_t bytes = 0;
      std::size_t requested_bytes = 0;

      [[nodiscard]] static Utf16Prefix fit(std::u16string_view text, std::size_t capacity, Utf16Encoding encoding = {}) noexcept;

    private:
      [[nodiscard]] static std::size_t encodedBytes(char16_t scalar, Utf16Encoding encoding) noexcept;
    };

  }
}

// Interface: text/wrapped_lines.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    // The lines of a text it views, region `a`: each line views the text, not these lines.
    class WrappedLines {
    public:
      explicit WrappedLines(tbc::view<std::string_view, tbc::lt::a> text, std::uint16_t columns, bool words = false) noexcept;

      [[nodiscard]] tbc::view<ds::Option<std::string_view>, tbc::lt::a> next() noexcept;

    private:
      tbc::view<std::string_view, tbc::lt::a> text_;
      std::size_t position_ = 0;
      std::uint16_t columns_;
      bool words_;
      bool finished_ = false;
    };

  }
}
