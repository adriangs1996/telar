#pragma once

#include "classification.hpp"
#include "capabilities.hpp"
#include "checksum.hpp"
#include "clipboard.hpp"
#include "glyph.hpp"
#include "graphics_query.hpp"
#include "reports.hpp"
#include "color_queries.hpp"
#include "cursor_report.hpp"
#include "size_report.hpp"
#include "identity.hpp"
#include "parser.hpp"
#include "policy.hpp"
#include "reply.hpp"
#include "vt_state.hpp"
#include "styled_ordinary.hpp"
#include "ascii_ordinary.hpp"

namespace telar::runtime::control {

template <Allocator Memory>
class Engine {
public:
  explicit Engine(Memory &memory, PtyResponseQueue &responses, bool enabled, GraphicsQueryResources resources = {})
      : parser_(memory), reply_(memory), checksum_(memory), clipboard_(memory), graphics_queries_(memory, resources), reports_(memory), colors_(state_, reply_, policy), responses_(responses), enabled_(enabled) {}

  void bind(GhosttyTerminal terminal, GhosttyRenderState render, bool separate_media) noexcept {
    state_.bind(terminal, render, separate_media);
  }

  void failWrite() noexcept {
    closed_ = true;
    state_.failWrite();
  }

  void enableMediaBoundaries() noexcept { media_boundaries_ = true; }
  bool awaitingMedia() const noexcept { return awaiting_media_; }
  void mediaComplete() noexcept { awaiting_media_ = false; }

  void discard() noexcept {
    closed_ = true;
    responses_.release();
    parser_.discard();
    reply_.discard();
    checksum_.discard();
    clipboard_.discard();
    graphics_queries_.discard();
    reports_.discard();
    colors_.discard();
    prepared_ = false;
    clipboard_before_reply_ = false;
    capability_offset_ = 0;
    awaiting_media_ = false;
    streamed_media_ = false;
  }

  std::size_t feed(std::span<const std::uint8_t> input) {
    if (closed_) {
      return input.size();
    }
    if (awaiting_media_) {
      return 0;
    }
    const ReleaseProducer release{responses_};
    if (parser_.blocked()) {
      parser_.feed({}, *this);
      if (parser_.blocked()) {
        return 0;
      }
    }
    if ((clipboard_.hasReply() && !clipboard_.publish(responses_)) || !reports_.publish(responses_, state_, facts_, enabled_)) {
      return 0;
    }
    return parser_.feed(input, *this);
  }

  // Only a verified quiet atomic envelope may cross multiple graphics
  // boundaries. Its fixed suffix has no queries; the caller bounds the group.
  std::size_t feedAtomicMedia(std::span<const std::uint8_t> input) {
    assert(media_boundaries_ && !blocked() && parser_.ground());
    media_boundaries_ = false;
    try {
      const auto consumed = feed(input);
      media_boundaries_ = true;
      if (consumed != input.size()) {
        throw std::logic_error{"Atomic graphics envelope was interrupted"};
      }
      awaiting_media_ = true;
      return consumed;
    } catch (...) {
      media_boundaries_ = true;
      throw;
    }
  }

  bool blocked() const noexcept {
    return awaiting_media_ || parser_.blocked() || reports_.pending() || clipboard_.hasReply();
  }

  bool ground() const noexcept {
    return parser_.ground();
  }

  void ordinary(std::span<const std::uint8_t> input) {
    responses_.release();
    state_.write(input);
  }

  [[gnu::noinline]] std::size_t ordinaryRun(std::span<const std::uint8_t> input, std::size_t offset) {
    const auto remaining = input.subspan(offset);
    if (ascii_detail::eligible(remaining) && state_.canWriteAscii()) {
      return offset + ordinaryAscii(remaining);
    }

    const auto end = styledOrdinaryLength(input, offset);
    responses_.release();
    state_.writeNonGraphics(input.subspan(offset, end - offset));
    return end;
  }

  void escapeBoundary() {
    if (state_.needsEscapeBoundary()) {
      responses_.release();
      state_.escapeBoundary();
    }
  }

  bool streamable(Sequence sequence) noexcept {
    const bool stream = control::streamable(sequence);
    if (stream && media_boundaries_ && sequence.kind == Kind::apc && sequence.body().starts_with('G')) {
      streamed_media_ = true;
    }
    return stream;
  }

  bool borrowableApc(Sequence header) const noexcept {
    return graphicsQuery(header.body());
  }

  bool streamComplete() noexcept {
    if (std::exchange(streamed_media_, false)) {
      awaiting_media_ = true;
      return false;
    }
    return true;
  }

  bool enquire() {
    escapeBoundary();
    if (!enabled_ || policy.answerback_length == 0) {
      return true;
    }
    return responses_.tryPush({reinterpret_cast<const std::uint8_t *>(policy.answerback.data()), policy.answerback_length});
  }

  // The first attempt snapshots state and applies mutations once. Retrying a
  // full queue only publishes that owned reply; it never re-executes setters.
  bool complete(Sequence sequence) {
    if (awaiting_media_) {
      return false;
    }
    if (sequence.kind == Kind::osc) {
      const auto operation = oscOperation(sequence.body().substr(0, sequence.body().find(';')));
      if (operation == 4 || operation == 5) {
        return colors_.palette(sequence, enabled_, responses_);
      }
    }
    if (sequence.kind == Kind::dcs) {
      const auto header_end = sequence.body().find_first_of("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~");
      if (header_end != std::string_view::npos) {
        const auto parameters = Parameters::parse(sequence.body().substr(0, header_end + 1));
        if (parameters && !parameters->colon && parameters->final == 'q' && parameters->modifiers() == "+") {
          return termcap(sequence.body().substr(header_end + 1));
        }
      }
    }

    if (!prepared_) {
      reply_.clear();
      switch (sequence.kind) {
      case Kind::escape: escape(sequence); break;
      case Kind::csi: csi(sequence); break;
      case Kind::dcs: dcs(sequence); break;
      case Kind::osc: osc(sequence); break;
      case Kind::apc: apc(sequence); break;
      }
      clipboard_before_reply_ = clipboard_.hasReply();
      prepared_ = true;
      if (media_boundaries_ && sequence.kind == Kind::apc && sequence.body().starts_with('G')) {
        awaiting_media_ = true;
        return false;
      }
    }

    if (enabled_ && clipboard_before_reply_ && clipboard_.hasReply() && !clipboard_.publish(responses_)) {
      return false;
    }
    if (enabled_ && !reply_.publish(responses_)) {
      return false;
    }

    reply_.clear();
    if (enabled_ && clipboard_.hasReply() && !clipboard_.publish(responses_)) {
      return false;
    }
    prepared_ = false;
    clipboard_before_reply_ = false;
    return true;
  }

  void configureSize(TerminalSize size) {
    state_.configureSize(size);
    if (!closed_ && state_.mode(size_events_mode)) {
      reports_.changed(Report::size);
    }
  }

  void configureFacts(ClientFacts facts) noexcept {
    if (closed_) {
      facts_ = facts;
      return;
    }
    if (facts.light != facts_.light) {
      reports_.changed(Report::scheme);
    }
    if (facts.visible != facts_.visible) {
      reports_.changed(Report::visibility);
    }
    if (facts.focused != facts_.focused) {
      reports_.changed(Report::focus);
    }
    facts_ = facts;
  }

  void publishReports() {
    if (closed_ || awaiting_media_) {
      return;
    }
    const ReleaseProducer release{responses_};
    if (!parser_.blocked() && (!clipboard_.hasReply() || clipboard_.publish(responses_))) {
      reports_.publish(responses_, state_, facts_, enabled_);
    }
  }

  void externalColorsChanged() noexcept {
    state_.invalidateColors();
    if (!closed_ && state_.mode(scheme_events_mode)) {
      reports_.changed(Report::scheme);
    }
  }

  Clipboard<Memory> &clipboard() noexcept {
    return clipboard_;
  }

  bool pasteEvents() const noexcept {
    return paste_events_;
  }

  Policy policy;

private:
  [[gnu::noinline]] std::size_t ordinaryAscii(std::span<const std::uint8_t> input) {
    static_assert(ascii_detail::codepoint_capacity == GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT);
    std::array<std::uint32_t, ascii_detail::codepoint_capacity> codepoints;
    assert(input.size() >= ascii_detail::gate_bytes);

    // ordinaryRun has already validated these bytes synchronously. Only the
    // remaining input needs stop detection; the C bridge still validates all.
#if (defined(__aarch64__) && defined(__AARCH64EL__)) || defined(__SSE2__)
    for (std::size_t offset = 0; offset < ascii_detail::gate_bytes; offset += styled_detail::vector_bytes) {
      ascii_detail::widenBlock(ascii_detail::load(input.data() + offset), codepoints.data() + offset);
    }
#else
    std::copy_n(input.data(), ascii_detail::gate_bytes, codepoints.data());
#endif

    const auto count = ascii_detail::gate_bytes + ascii_detail::widen(input.subspan(ascii_detail::gate_bytes), std::span{codepoints}.subspan(ascii_detail::gate_bytes));
    responses_.release();
    state_.writeAscii(std::span{codepoints}.first(count));
    return count;
  }

  struct ReleaseProducer {
    PtyResponseQueue::Producer &producer;

    ~ReleaseProducer() { producer.release(); }
  };

  void passthrough(Sequence sequence) {
    responses_.release();
    state_.write(sequence.bytes);
    if (sequence.ending != Ending::final_byte) {
      const auto terminator = sequence.terminator();
      state_.write({reinterpret_cast<const std::uint8_t *>(terminator.data()), terminator.size()});
    }
  }

  void escape(Sequence sequence) {
    if (sequence.body() == "\\") {
      return;
    }
    if (sequence.body() == "Z") {
      attributes(false);
      return;
    }

    if (sequence.body() == "c") {
      checksum_.flags = 0;
      paste_events_ = false;
      saved_desktop_modes_.fill(false);
      clipboard_.reset();
    }
    passthrough(sequence);
  }

  void attributes(bool secondary) {
    if (!enabled_) {
      return;
    }
    if (secondary) {
      reply_.append("\x1b[>1;0;0c");
    } else {
      reply_.append(policy.clipboard_write == Access::deny ? "\x1b[?62;22c" : "\x1b[?62;22;52c");
    }
  }

  void csi(Sequence sequence) {
    const auto body = sequence.body();
    if (body == "5n") {
      operatingStatus();
      return;
    }
    if (body == "6n" || body == "?6n") {
      reportCursor(body.size() == 3);
      return;
    }

    const auto parsed = Parameters::parse(body);
    if (!parsed) {
      return;
    }

    const auto &parameters = *parsed;
    const auto modifiers = parameters.modifiers();
    if (parameters.colon && parameters.final != 'm') {
      return;
    }

    switch (parameters.final) {
    case 'h':
    case 'l':
      if (modifiers == "?") {
        privateModes(parameters);
        return;
      }
      break;
    case 's':
    case 'r':
      if (modifiers == "?") {
        privateModes(parameters);
        return;
      }
      break;
    case 'y':
      if (modifiers == "*" && parameters.count <= 6) {
        if (enabled_ && policy.checksum_report) {
          reply_.append("\x1bP");
          reply_.number(parameters.count == 0 ? 0 : parameters.values[0]);
          reply_.append("!~");
          reply_.hex(checksum_.compute(state_, parameters), 4, true);
          reply_.append("\x1b\\");
        }
        return;
      }
      if (modifiers == "#" && parameters.count <= 1) {
        if (policy.checksum_report) {
          checksum_.flags = parameters.count == 0 ? 0 : parameters.values[0] & 31;
        }
        return;
      }
      break;
    case 'c':
      if (modifiers.empty() || modifiers == ">") {
        attributes(modifiers == ">");
      }
      return;
    case 'n':
      if (modifiers.empty() || modifiers == "?") {
        status(parameters);
        return;
      }
      break;
    case 'p':
      if (modifiers == "!") {
        checksum_.flags = 0;
      }
      if (modifiers == "$" || modifiers == "?$") {
        modeReport(parameters);
        return;
      }
      break;
    case 'q':
      if (modifiers == ">") {
        if (enabled_) {
          reply_.append("\x1bP>|telar ");
          reply_.append(program_version);
          reply_.append("\x1b\\");
        }
        return;
      }
      break;
    case 't':
      if (modifiers.empty() && parameters.count == 1 && parameters.values[0] >= 14 && parameters.values[0] <= 21) {
        sizeReport(parameters.values[0]);
        return;
      }
      break;
    case 'u':
      if (modifiers == "?") {
        if (enabled_) {
          reply_.append("\x1b[?");
          reply_.number(state_.keyboard());
          reply_.append("u");
        }
        return;
      }
      break;
    default:
      break;
    }

    passthrough(sequence);
  }

  void privateModes(const Parameters &parameters) {
    for (std::size_t index = 0; index < parameters.count; ++index) {
      const auto mode = parameters.values[index];
      const auto owned = std::find(desktop_modes.begin(), desktop_modes.end(), mode);
      if (owned != desktop_modes.end()) {
        const auto slot = static_cast<std::size_t>(owned - desktop_modes.begin());
        if (parameters.final == 's') {
          saved_desktop_modes_[slot] = state_.mode(mode);
          continue;
        }
        const bool enabled = parameters.final == 'r' ? saved_desktop_modes_[slot] : parameters.final == 'h';
        state_.setMode(mode, enabled);
        modeEffect(mode, enabled);
        continue;
      }

      forwardPrivateMode(mode, parameters.final, [this](auto command) { ordinary(command); });
    }
  }

  void modeEffect(unsigned mode, bool set) {
    switch (mode) {
    case paste_events_mode:
      paste_events_ = set;
      break;
    case focus_events_mode:
      if (set && enabled_) {
        reply_.append(facts_.focused ? "\x1b[I" : "\x1b[O");
      }
      break;
    case visibility_mode:
      if (set && enabled_) {
        reply_.append(facts_.visible ? "\x1b[?999;1n" : "\x1b[?999;2n");
      }
      break;
    case size_events_mode:
      if (set) {
        sizeEvent();
      }
      break;
    default:
      break;
    }
  }

  void operatingStatus() {
    if (!enabled_) {
      return;
    }

    static constexpr std::array<std::uint8_t, 4> response{0x1b, '[', '0', 'n'};
    if (!clipboard_.hasReply() && responses_.tryPushFixed(response)) {
      return;
    }
    reply_.append("\x1b[0n");
  }

  void status(const Parameters &parameters) {
    if (!enabled_ || parameters.count != 1) {
      return;
    }

    const auto request = parameters.values[0];
    const bool private_request = parameters.modifiers() == "?";
    if (request == 5 && !private_request) {
      operatingStatus();
    } else if (request == 6) {
      reportCursor(private_request);
    } else if (private_request && request == scheme_request) {
      reply_.append(facts_.light ? "\x1b[?997;2n" : "\x1b[?997;1n");
    } else if (private_request && request == visibility_request) {
      reply_.append(facts_.visible ? "\x1b[?999;1n" : "\x1b[?999;2n");
    }
  }

  void reportCursor(bool extended) {
    if (!enabled_) {
      return;
    }

    auto position = state_.cursor();
    if (state_.mode(origin_mode)) {
      const auto margins = state_.margins();
      position.column -= std::min(position.column, margins.left);
      position.row -= std::min(position.row, margins.top);
    }

    cursorReport(reply_, position, extended);
  }

  static bool knownMode(std::uint16_t value, bool ansi) noexcept {
    if (ansi) {
      return value == 2 || value == 4 || value == 12 || value == 20;
    }

    switch (value) {
    case 1: case 3: case 4: case 5: case 6: case 7: case 8: case 9: case 12: case 25: case 40: case 45: case 47: case 66: case 67: case 69:
    case 1000: case 1002: case 1003: case 1004: case 1005: case 1006: case 1007: case 1015: case 1016: case 1035: case 1036: case 1039:
    case 1045: case 1047: case 1048: case 1049: case 2004: case 2026: case 2027: case 2031: case 2033: case 2048:
      return true;
    default:
      return false;
    }
  }

  void modeReport(const Parameters &parameters) {
    if (!enabled_ || parameters.count != 1) {
      return;
    }

    enum class ModeStatus : unsigned { unknown, set, reset, permanently_set, permanently_reset };
    const auto value = parameters.values[0];
    const bool ansi = parameters.modifiers() == "$";
    ModeStatus report = ModeStatus::unknown;
    if (!ansi && value == paste_events_mode) {
      report = paste_events_ ? ModeStatus::set : ModeStatus::reset;
    } else if (knownMode(value, ansi)) {
      report = state_.mode(value, ansi) ? ModeStatus::set : ModeStatus::reset;
    } else if (!ansi && value == erase_color_mode) {
      report = ModeStatus::permanently_reset;
    } else if (ansi) {
      switch (value) {
      case 1: case 5: case 7: case 10: case 11: case 13: case 14: case 15: case 16: case 17: case 18: case 19:
        report = ModeStatus::permanently_reset;
        break;
      default:
        break;
      }
    }

    reply_.append(ansi ? "\x1b[" : "\x1b[?");
    reply_.number(value);
    reply_.append(";");
    reply_.number(static_cast<unsigned>(report));
    reply_.append("$y");
  }

  void sizeEvent() {
    if (!enabled_) {
      return;
    }
    control::sizeReport<SizeReport::event>(reply_, state_.size());
  }

  void sizeReport(unsigned request) {
    if (!enabled_) {
      return;
    }
    if (request == title_request) {
      if (policy.title_report) {
        reply_.append("\x1b]l");
        auto title = state_.title();
        while (!title.empty()) {
          const auto first = static_cast<std::uint8_t>(title.front());
          const std::size_t count = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4;
          if (title.size() < count) {
            break;
          }
          const auto text = title.substr(0, count);
          title.remove_prefix(count);
          if ((count == 1 && (first < ' ' || first == '\x7f')) || (count == 2 && first == 0xc2 && static_cast<std::uint8_t>(text[1]) < 0xa0)) {
            continue;
          }
          try {
            validateUtf8(text);
          } catch (const EncodingError &) {
            continue;
          }
          reply_.append(text);
        }
        reply_.append("\x1b\\");
      }
      return;
    }

    const auto size = state_.size();
    switch (request) {
    case pixels_request:
      control::sizeReport<SizeReport::pixels>(reply_, size);
      break;
    case cell_request:
      control::sizeReport<SizeReport::cell>(reply_, size);
      break;
    case text_request:
      control::sizeReport<SizeReport::text>(reply_, size);
      break;
    case screen_request:
      control::sizeReport<SizeReport::screen>(reply_, size);
      break;
    default:
      break;
    }
  }

  // Only an offset survives retries; the parser owns the complete request
  // until this method has published every admitted capability response.
  bool termcap(std::string_view request) {
    if (!enabled_) {
      return true;
    }
    while (capability_offset_ < request.size()) {
      const auto end = request.find(';', capability_offset_);
      const auto count = (end == std::string_view::npos ? request.size() : end) - capability_offset_;
      const auto response = capability(request.substr(capability_offset_, count));
      if (!response.empty() && !responses_.tryPush(response)) {
        return false;
      }
      capability_offset_ += count + 1;
    }
    capability_offset_ = 0;
    return true;
  }

  void dcs(Sequence sequence) {
    const auto end = sequence.body().find_first_of("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~");
    if (end != std::string_view::npos) {
      const auto parameters = Parameters::parse(sequence.body().substr(0, end + 1));
      if (parameters && !parameters->colon && parameters->final == 'q' && parameters->modifiers() == "$") {
        statusString(sequence.body().substr(end + 1));
        return;
      }
    }
    if (sequence.body().starts_with("+q")) {
      return;
    }

    passthrough(sequence);
  }

  void statusString(std::string_view request) {
    if (!enabled_ || request.size() > 2) {
      return;
    }

    const bool horizontal = request == "s" && state_.mode(left_right_margin_mode);
    const bool valid = request == "m" || request == " q" || request == "r" || horizontal;
    reply_.append(valid ? "\x1bP1$r" : "\x1bP0$r");
    if (request == "m") {
      attributesString();
      reply_.append("m");
    } else if (request == " q") {
      const auto cursor = state_.visualCursor();
      const auto shape = cursor.visual_style;
      const unsigned style = shape == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR ? 5 : shape == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE ? 3 : 1;
      reply_.number(style + !state_.mode(cursor_blink_mode));
      reply_.append(" q");
    } else if (request == "r" || horizontal) {
      const auto margins = state_.margins();
      reply_.number(static_cast<unsigned>(horizontal ? margins.left : margins.top) + 1);
      reply_.append(";");
      reply_.number(static_cast<unsigned>(horizontal ? margins.right : margins.bottom) + 1);
      reply_.append(horizontal ? "s" : "r");
    }
    reply_.append("\x1b\\");
  }

  void attributesString() {
    const auto style = state_.style();
    reply_.append("0");
    const std::array<bool, 9> flags{style.bold, style.faint, style.italic, style.underline != 0, style.overline, style.blink, style.inverse, style.invisible, style.strikethrough};
    constexpr std::array<unsigned, flags.size()> codes{1, 2, 3, 4, 53, 5, 7, 8, 9};
    for (std::size_t index = 0; index < flags.size(); ++index) {
      if (flags[index]) {
        reply_.append(";");
        reply_.number(codes[index]);
        if (codes[index] == 4 && style.underline != 1) {
          reply_.append(":");
          reply_.number(style.underline);
        }
      }
    }

    styleColor(style.fg_color, false);
    styleColor(style.bg_color, true);
  }

  void styleColor(const GhosttyStyleColor &color, bool background) {
    if (color.tag == GHOSTTY_STYLE_COLOR_NONE) {
      return;
    }

    reply_.append(";");
    if (color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
      const auto index = color.value.palette;
      if (index < 16) {
        reply_.number((background ? (index < 8 ? 40 : 100) : (index < 8 ? 30 : 90)) + index % 8);
      } else {
        reply_.append(background ? "48:5:" : "38:5:");
        reply_.number(index);
      }
    } else if (color.tag == GHOSTTY_STYLE_COLOR_RGB) {
      reply_.append(background ? "48:2::" : "38:2::");
      reply_.number(color.value.rgb.r);
      reply_.append(":");
      reply_.number(color.value.rgb.g);
      reply_.append(":");
      reply_.number(color.value.rgb.b);
    }
  }

  void osc(Sequence sequence) {
    responses_.release();
    if (colors_.handle(sequence, enabled_)) {
      return;
    }
    auto remaining = sequence.body();
    const auto operation = oscOperation(takeField(remaining));
    if (operation == 52) {
      if (enabled_) {
        clipboard_.traditional(remaining, policy);
      }
      return;
    }
    if (operation == 5522) {
      if (enabled_) {
        clipboard_.kitty(remaining, sequence.ending, policy, reply_);
      }
      return;
    }
    passthrough(sequence);
  }

  void apc(Sequence sequence) {
    if (sequence.body().starts_with("25a1;")) {
      if (enabled_) {
        glyph(sequence.body().substr(5), reply_);
      }
      return;
    }
    if (sequence.body().starts_with('G') && graphics_queries_.handle(sequence.body(), reply_, enabled_)) {
      return;
    }
    passthrough(sequence);
  }

  static constexpr unsigned paste_events_mode = 5522;
  static constexpr unsigned focus_events_mode = 1004;
  static constexpr unsigned visibility_mode = 2033;
  static constexpr unsigned size_events_mode = 2048;
  static constexpr unsigned origin_mode = 6;
  static constexpr unsigned cursor_blink_mode = 12;
  static constexpr unsigned left_right_margin_mode = 69;
  static constexpr unsigned erase_color_mode = 117;
  static constexpr unsigned scheme_events_mode = 2031;
  static constexpr unsigned scheme_request = 996;
  static constexpr unsigned visibility_request = 998;
  static constexpr unsigned pixels_request = 14;
  static constexpr unsigned cell_request = 16;
  static constexpr unsigned text_request = 18;
  static constexpr unsigned screen_request = 19;
  static constexpr unsigned title_request = 21;


  Parser<Memory> parser_;
  Reply<Memory> reply_;
  VtState state_;
  Checksum<Memory> checksum_;
  Clipboard<Memory> clipboard_;
  GraphicsQueries<Memory> graphics_queries_;
  Reports<Memory> reports_;
  ColorQueries<Memory> colors_;
  ClientFacts facts_;
  PtyResponseQueue::Producer responses_;
  bool enabled_;
  bool closed_ = false;
  bool media_boundaries_ = false;
  bool awaiting_media_ = false;
  bool streamed_media_ = false;
  bool prepared_ = false;
  bool clipboard_before_reply_ = false;
  std::array<bool, desktop_modes.size()> saved_desktop_modes_{};
  std::size_t capability_offset_ = 0;
  bool paste_events_ = false;
};

}
