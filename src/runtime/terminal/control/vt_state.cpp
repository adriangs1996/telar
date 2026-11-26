module;
#include "telar_base/diagnostics/config.hpp"

#if defined(__aarch64__) && defined(__AARCH64EL__)
#include <arm_neon.h>
#elifdef __SSE2__
#include <emmintrin.h>
#endif

module telar.runtime.terminal.control;

import telar.base.ds;

namespace telar::runtime::control {

  namespace styled_detail {

    namespace {

#if defined(__aarch64__) && defined(__AARCH64EL__)
      constexpr unsigned vector_match_bits = 4;
#else
      constexpr unsigned vector_match_bits = 1;
#endif

      // Bits per byte in a scanner's match mask.
      template <Isa Set>
      constexpr unsigned match_bits = 1;

      template <>
      constexpr unsigned match_bits<Isa::vector> = vector_match_bits;

      // Keys own complete validated blocks: one numeric SGR followed only by bytes
      // without ESC/ENQ. UINT64_MAX cannot equal a block beginning with ESC.
      class ShortSgrBlockCache {
      public:
        static constexpr std::size_t block_bytes = sizeof(std::uint64_t);

        [[nodiscard]] bool contains(std::uint64_t word) const noexcept {
          return word == newest_ || word == older_;
        }

        void remember(std::uint64_t word) noexcept {
          older_ = newest_;
          newest_ = word;
        }

      private:
        std::uint64_t newest_ = std::numeric_limits<std::uint64_t>::max();
        std::uint64_t older_ = std::numeric_limits<std::uint64_t>::max();
      };

    }

    template <Isa Set>
    ControlScanner<Set>::ControlScanner(std::span<const std::uint8_t> input) noexcept
        : input_(input) {}

    template <Isa Set>
    [[gnu::always_inline]] std::size_t ControlScanner<Set>::next(std::size_t offset) noexcept {
#if (defined(__aarch64__) && defined(__AARCH64EL__)) || defined(__SSE2__)
      if constexpr (Set == Isa::vector) {
        while (input_.size() - offset >= vector_bytes) {
          std::uint64_t candidates = 0;

          if (offset >= window_begin_ && offset < window_end_) {
            candidates = matches_ & (std::numeric_limits<std::uint64_t>::max() << ((offset - window_begin_) * match_bits<Set>));
          } else {
#if defined(__aarch64__) && defined(__AARCH64EL__)
            const auto bytes = vld1q_u8(input_.subspan(offset).data());
            const auto matches = vorrq_u8(vceqq_u8(bytes, vdupq_n_u8(enquiry)), vceqq_u8(bytes, vdupq_n_u8(escape)));
            const auto packed = vshrn_n_u16(vreinterpretq_u16_u8(matches), match_bits<Set>);

            matches_ = vget_lane_u64(vreinterpret_u64_u8(packed), 0);
#else
            const auto bytes = _mm_loadu_si128(reinterpret_cast<const __m128i*>(input_.subspan(offset).data()));
            const auto matches = _mm_or_si128(_mm_cmpeq_epi8(bytes, _mm_set1_epi8(enquiry)), _mm_cmpeq_epi8(bytes, _mm_set1_epi8(escape)));
            matches_ = static_cast<unsigned>(_mm_movemask_epi8(matches));
#endif
            window_begin_ = offset;
            window_end_ = offset + vector_bytes;
            candidates = matches_;
          }

          if (candidates != 0) {
            return window_begin_ + (static_cast<unsigned>(std::countr_zero(candidates)) / match_bits<Set>);
          }

          offset = window_end_;
        }
      }
#endif

      while (offset < input_.size() && input_[offset] != enquiry && input_[offset] != escape) {
        ++offset;
      }

      return offset;
    }

    template class ControlScanner<Isa::scalar>;
    template class ControlScanner<Isa::vector>;

  }

  namespace {

    using styled_detail::Isa;

    // An unaligned load of eight bytes in the target's order, which compiles to one instruction.
    [[gnu::always_inline]] inline std::uint64_t loadWord(std::span<const std::uint8_t, sizeof(std::uint64_t)> bytes) noexcept {
      ds::Array<std::uint8_t, sizeof(std::uint64_t)> word{};

      std::ranges::copy(bytes, word.dataMut());
      return std::bit_cast<std::uint64_t>(word);
    }

    // The scans are inlined into each caller, writeOrdinaryRun and the exported entry points for
    // the tests, whichever of them the link keeps.
    template <Isa Set>
    [[gnu::always_inline]] std::size_t styledLength(std::span<const std::uint8_t> input, std::size_t prefix) noexcept {
      using styled_detail::ShortSgrBlockCache;

      styled_detail::ControlScanner<Set> scanner{input};
      ShortSgrBlockCache cache;
      auto length = scanner.next(prefix);

      while (input.size() - length >= 3) {
        std::uint64_t word = 0;
        const bool has_block = input.size() - length >= ShortSgrBlockCache::block_bytes;
        if (has_block) {
          word = loadWord(input.subspan(length).template first<ShortSgrBlockCache::block_bytes>());
          if (cache.contains(word)) {
            length = scanner.next(length + ShortSgrBlockCache::block_bytes);
            continue;
          }
        }

        if (input[length] != styled_detail::escape || input[length + 1] != '[') {
          break;
        }

        auto end = length + 2;
        const auto limit = end + std::min(input.size() - end, Parameters::capacity + 1);

        while (end < limit && styled_detail::numericSgrByte(input[end])) {
          ++end;
        }

        if (end == limit || input[end] != 'm') {
          break;
        }

        const auto next = scanner.next(end + 1);
        if (has_block && end + 1 - length <= ShortSgrBlockCache::block_bytes && next - length >= ShortSgrBlockCache::block_bytes) {
          cache.remember(word);
        }

        length = next;
      }

      return length;
    }

    // The first byte that is not a C0 control.
    constexpr std::uint8_t first_printable = 0x20;

    constexpr bool asciiStop(std::uint8_t byte) noexcept {
      return byte >= ascii_detail::non_ascii_first || byte == styled_detail::escape || byte == styled_detail::enquiry;
    }

#if defined(__aarch64__) && defined(__AARCH64EL__)
    using ByteVector = uint8x16_t;

    ByteVector load(const std::uint8_t* input) noexcept {
      return vld1q_u8(input);
    }

    std::uint64_t stopMask(ByteVector bytes) noexcept {
      const auto controls = vorrq_u8(vceqq_u8(bytes, vdupq_n_u8(styled_detail::enquiry)), vceqq_u8(bytes, vdupq_n_u8(styled_detail::escape)));
      const auto stops = vorrq_u8(controls, vcgeq_u8(bytes, vdupq_n_u8(ascii_detail::non_ascii_first)));

      return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(stops), styled_detail::vector_match_bits)), 0);
    }

    void widenBlock(ByteVector bytes, std::span<std::uint32_t, styled_detail::vector_bytes> output) noexcept {
      const auto low = vmovl_u8(vget_low_u8(bytes));
      const auto high = vmovl_high_u8(bytes);

      vst1q_u32(output.data(), vmovl_u16(vget_low_u16(low)));
      vst1q_u32(output.subspan<4>().data(), vmovl_high_u16(low));
      vst1q_u32(output.subspan<8>().data(), vmovl_u16(vget_low_u16(high)));
      vst1q_u32(output.subspan<12>().data(), vmovl_high_u16(high));
    }
#elifdef __SSE2__
    using ByteVector = __m128i;

    ByteVector load(const std::uint8_t* input) noexcept {
      return _mm_loadu_si128(reinterpret_cast<const __m128i*>(input));
    }

    std::uint64_t stopMask(ByteVector bytes) noexcept {
      const auto controls = _mm_or_si128(_mm_cmpeq_epi8(bytes, _mm_set1_epi8(styled_detail::enquiry)), _mm_cmpeq_epi8(bytes, _mm_set1_epi8(styled_detail::escape)));
      return static_cast<unsigned>(_mm_movemask_epi8(_mm_or_si128(controls, bytes)));
    }

    void widenBlock(ByteVector bytes, std::span<std::uint32_t, styled_detail::vector_bytes> output) noexcept {
      const auto zero = _mm_setzero_si128();
      const auto low = _mm_unpacklo_epi8(bytes, zero);
      const auto high = _mm_unpackhi_epi8(bytes, zero);
      _mm_storeu_si128(reinterpret_cast<__m128i*>(output.data()), _mm_unpacklo_epi16(low, zero));
      _mm_storeu_si128(reinterpret_cast<__m128i*>(output.subspan<4>().data()), _mm_unpackhi_epi16(low, zero));
      _mm_storeu_si128(reinterpret_cast<__m128i*>(output.subspan<8>().data()), _mm_unpacklo_epi16(high, zero));
      _mm_storeu_si128(reinterpret_cast<__m128i*>(output.subspan<12>().data()), _mm_unpackhi_epi16(high, zero));
    }
#endif

    template <Isa Set>
    [[gnu::always_inline]] bool asciiEligible(std::span<const std::uint8_t> input) noexcept {
      if (input.size() < ascii_detail::gate_bytes) {
        return false;
      }

#if (defined(__aarch64__) && defined(__AARCH64EL__)) || defined(__SSE2__)
      if constexpr (Set == Isa::vector) {
        return stopMask(load(input.data())) == 0 && stopMask(load(input.subspan(styled_detail::vector_bytes).data())) == 0;
      }
#endif

      return std::ranges::none_of(input.first(ascii_detail::gate_bytes), asciiStop);
    }

    template <Isa Set>
    [[gnu::always_inline]] std::size_t asciiWiden(std::span<const std::uint8_t> input, std::span<std::uint32_t> output) noexcept {
      const auto capacity = std::min(input.size(), output.size());
      std::size_t offset = 0;

#if (defined(__aarch64__) && defined(__AARCH64EL__)) || defined(__SSE2__)
      if constexpr (Set == Isa::vector) {
        while (capacity - offset >= styled_detail::vector_bytes) {
          const auto bytes = load(input.subspan(offset).data());
          const auto stops = stopMask(bytes);

          widenBlock(bytes, output.subspan(offset).first<styled_detail::vector_bytes>());
          if (stops != 0) {
            return offset + (static_cast<unsigned>(std::countr_zero(stops)) / styled_detail::vector_match_bits);
          }

          offset += styled_detail::vector_bytes;
        }
      }
#endif

      while (offset < capacity) {
        const auto byte = input[offset];
        if (asciiStop(byte)) {
          break;
        }

        output[offset++] = byte;
      }

      return offset;
    }

    // Widens an eligible ASCII run in one batch and writes it. Out of line, so that only this path
    // reserves the codepoint scratch on the stack.
    [[gnu::noinline]] std::size_t writeAsciiRun(VtState& state, std::span<const std::uint8_t> input) {
      ds::Array<std::uint32_t, ascii_detail::codepoint_capacity> codepoints; // NOLINT(cppcoreguidelines-pro-type-member-init): the widening writes each codepoint the run keeps before ghostty reads it, so zeroing 16 KiB per run is work the hottest path never needs

      TELAR_ASSERT(input.size() >= ascii_detail::gate_bytes);

      // asciiEligible has already validated these bytes synchronously. Only the
      // remaining input needs stop detection; the C bridge still validates all.
#if (defined(__aarch64__) && defined(__AARCH64EL__)) || defined(__SSE2__)
      for (std::size_t offset = 0; offset < ascii_detail::gate_bytes; offset += styled_detail::vector_bytes) {
        widenBlock(load(input.subspan(offset).data()), codepoints.viewMut().subspan(offset).first<styled_detail::vector_bytes>());
      }
#else
      std::copy_n(input.data(), ascii_detail::gate_bytes, codepoints.data());
#endif

      const auto count = ascii_detail::gate_bytes + asciiWiden<Isa::vector>(input.subspan(ascii_detail::gate_bytes), codepoints.viewMut().subspan(ascii_detail::gate_bytes));

      state.writeAscii(std::span{codepoints}.first(count));
      return count;
    }

  }

  std::size_t styledOrdinaryLength(std::span<const std::uint8_t> input, std::size_t prefix) noexcept {
    return styledLength<Isa::vector>(input, prefix);
  }

  std::size_t styledOrdinaryLengthScalar(std::span<const std::uint8_t> input, std::size_t prefix) noexcept {
    return styledLength<Isa::scalar>(input, prefix);
  }

  namespace ascii_detail {

    bool eligible(std::span<const std::uint8_t> input) noexcept {
      return asciiEligible<Isa::vector>(input);
    }

    bool eligibleScalar(std::span<const std::uint8_t> input) noexcept {
      return asciiEligible<Isa::scalar>(input);
    }

    std::size_t widen(std::span<const std::uint8_t> input, std::span<std::uint32_t> output) noexcept {
      return asciiWiden<Isa::vector>(input, output);
    }

    std::size_t widenScalar(std::span<const std::uint8_t> input, std::span<std::uint32_t> output) noexcept {
      return asciiWiden<Isa::scalar>(input, output);
    }

  }

  void VtState::bind(tbc::val_a<GhosttyTerminal> terminal, tbc::val_a<GhosttyRenderState> render, bool separate_media) noexcept {
    terminal_ = terminal;
    render_ = render;
    separate_media_ = separate_media;
  }

  // Inlined into the write paths of this unit, as the scans are.
  template <bool CheckGraphics>
  [[gnu::always_inline]] void VtState::writeInput(std::span<const std::uint8_t> bytes) {
    invalidate();
    if (!bytes.empty()) {
      const auto last = bytes.back();

      possibly_pending_input_ = last >= ascii_detail::non_ascii_first || last < first_printable;
    }

    if (separate_media_ && (CheckGraphics || !graphics_cursor_.ground())) {
      graphics_cursor_.feed(terminal_, bytes, size_);
    } else {
      ghostty_terminal_vt_write(terminal_, bytes.data(), bytes.size());
    }

    if (write_failed_) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  void VtState::write(std::span<const std::uint8_t> bytes) {
    writeInput<true>(bytes);
  }

  void VtState::writeNonGraphics(std::span<const std::uint8_t> bytes) {
    writeInput<false>(bytes);
  }

  // Out of line, so that the scans and writes it inlines stay together in one body: the engine
  // reaches it once per run.
  [[gnu::noinline]] std::size_t VtState::writeOrdinaryRun(std::span<const std::uint8_t> input, std::size_t offset) {
    const auto remaining = input.subspan(offset);
    if (asciiEligible<Isa::vector>(remaining) && canWriteAscii()) {
      return offset + writeAsciiRun(*this, remaining);
    }

    const auto end = styledLength<Isa::vector>(input, offset);

    writeInput<false>(input.subspan(offset, end - offset));
    return end;
  }

  bool VtState::canWriteAscii() const noexcept {
    return !separate_media_ || graphics_cursor_.ground();
  }

  void VtState::escapeBoundary() {
    if (!possibly_pending_input_) {
      return;
    }

    bool ground = false;

    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground));
    if (!ground) {
      constexpr ds::Array<std::uint8_t, 2> boundary{0x1b, 0x18};

      write(boundary);
    }

    possibly_pending_input_ = false;
  }

  void VtState::configureSize(TerminalSize size) noexcept {
    size_ = size;
    invalidate();
  }

  void VtState::invalidateColors() noexcept {
    palette_valid_ = false;
    color_valid_.fill(false);
  }

  TerminalSize VtState::size() const {
    return size_cache_.get(epoch_, [&] {
      auto result = size_;

      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_COLS, &result.cols));
      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_ROWS, &result.rows));
      return result;
    });
  }

  bool VtState::mode(std::uint16_t number, bool ansi) const {
    const auto& slot = modes_[(number ^ (ansi ? mode_ansi_hash : 0)) % modes_.size()];
    auto entry = slot.get();
    if (entry.epoch != epoch_ || entry.number != number || entry.ansi != ansi) {
      GhosttyTerminalModeConfig query{.mode = ghostty::mode(number, ansi), .value = false};

      entry.value = ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_MODE, &query) == GHOSTTY_SUCCESS && query.value;
      entry.number = number;
      entry.ansi = ansi;
      entry.epoch = epoch_;
      slot.set(entry);
    }

    return entry.value;
  }

  void VtState::setMode(std::uint16_t number, bool enabled) {
    const GhosttyTerminalModeConfig config{.mode = ghostty::mode(number, false), .value = enabled};

    checkGhostty(ghostty_terminal_set(terminal_, GHOSTTY_TERMINAL_OPT_MODE, &config));
    invalidate();
  }

  tbc::val_a<TrackedRow> VtState::trackCursorRow() const {
    return TrackedRow::active(terminal_, cursor().row);
  }

  [[gnu::always_inline]] Position VtState::cursor() const {
    [[clang::noinline]] return cursor_cache_.get(epoch_, [&] {
      const auto snapshot = readCursorState();
      const Position result{.column = snapshot.x, .row = snapshot.y};

      return result;
    });
  }

  bool VtState::primaryScreen() const {
    GhosttyTerminalScreen screen{};

    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
    return screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  }

  Margins VtState::margins() const {
    return margin_cache_.get(epoch_, [&] {
      Margins result{};
      const ds::Array<GhosttyTerminalData, 4> keys{GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_TOP, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_LEFT, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_RIGHT};
      ds::Array<void*, keys.size()> values{&result.top, &result.bottom, &result.left, &result.right};

      checkGhostty(ghostty_terminal_get_multi(terminal_, keys.size(), keys.data(), values.dataMut(), nullptr));
      return result;
    });
  }

  std::uint8_t VtState::keyboard() const {
    return keyboard_cache_.get(epoch_, [&] {
      std::uint8_t result = 0;

      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &result));
      return result;
    });
  }

  GhosttyStyle VtState::style() const {
    return style_cache_.get(epoch_, [&] {
      auto result = ghosttySized<GhosttyStyle>();

      checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_CURSOR_STYLE, &result));
      return result;
    });
  }

  GhosttyRenderStateCursor VtState::visualCursor() const {
    return visual_cursor_cache_.get(epoch_, [&] {
      checkGhostty(ghostty_render_state_update(render_, terminal_));
      auto result = ghosttySized<GhosttyRenderStateCursor>();

      checkGhostty(ghostty_render_state_get(render_, GHOSTTY_RENDER_STATE_DATA_CURSOR, &result));
      return result;
    });
  }

  ds::Option<GhosttyColorRgb> VtState::color(unsigned selector) {
    if (selector < palette_.size()) {
      if (!palette_valid_) {
        checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, palette_.dataMut()));
        palette_valid_ = true;
      }

      return palette_[selector];
    }

    if (selector > cursor_color) {
      return ds::none;
    }

    const auto index = selector - foreground;
    if (!color_valid_[index]) {
      auto key = GHOSTTY_TERMINAL_DATA_COLOR_CURSOR;

      if (selector == foreground) {
        key = GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND;
      } else if (selector == background) {
        key = GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND;
      }

      GhosttyColorRgb result{};

      colors_.atMut(index) = ghostty_terminal_get(terminal_, key, &result) == GHOSTTY_SUCCESS ? ds::Option{result} : ds::none;
      color_valid_.atMut(index) = true;
    }

    return colors_[index];
  }

  ds::Option<GhosttyGridRef> VtState::reference(Position position) const {
    auto result = ghosttySized<GhosttyGridRef>();
    const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {.x = position.column, .y = position.row}}};
    if (ghostty_terminal_grid_ref(terminal_, point, &result) != GHOSTTY_SUCCESS) {
      return ds::none;
    }

    return result;
  }

  std::string_view VtState::title() const {
    GhosttyString result{};

    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_TITLE, &result));
    return {reinterpret_cast<const char*>(result.ptr), result.len}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): ghostty hands the title as a pointer to bytes and a length, which char may alias
  }

  void VtState::writeAscii(std::span<const std::uint32_t> codepoints) {
    if (codepoints.empty()) {
      return;
    }

    invalidate();
    possibly_pending_input_ = codepoints.back() < first_printable;
    std::size_t consumed = 0;

    checkGhostty(ghostty_terminal_vt_write_ascii(terminal_, codepoints.data(), codepoints.size(), &consumed));
    if (consumed != codepoints.size()) {
      throw TerminalError{GHOSTTY_INVALID_VALUE};
    }

    if (write_failed_) {
      throw TerminalError{GHOSTTY_OUT_OF_MEMORY};
    }
  }

  void VtState::invalidate() noexcept {
    if (++epoch_ == 0) {
      resetEpoch();
    }

    invalidateColors();
  }

  [[gnu::cold, gnu::noinline]] void VtState::resetEpoch() noexcept {
    epoch_ = 1;
    size_cache_.reset();
    cursor_cache_.reset();
    margin_cache_.reset();
    keyboard_cache_.reset();
    style_cache_.reset();
    visual_cursor_cache_.reset();
    for (const auto& entry : modes_) {
      entry.set({});
    }
  }

  GhosttyTerminalCursorState VtState::readCursorState() const {
    const auto snapshot = ghostty_terminal_cursor_snapshot(terminal_);
    if (!snapshot.valid) {
      throw TerminalError{GHOSTTY_INVALID_VALUE};
    }

    const auto& result = snapshot.state;

    margin_cache_.store(epoch_, {.top = result.top, .bottom = result.bottom, .left = result.left, .right = result.right});
    modes_[origin_mode % modes_.size()].set({.epoch = epoch_, .number = origin_mode, .ansi = false, .value = result.origin != 0});
    return result;
  }

}
