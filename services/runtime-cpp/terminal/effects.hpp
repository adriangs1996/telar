#pragma once

#include "ghostty_handle.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <charconv>

namespace telar::runtime {

template <Allocator Memory>
class TerminalEffects {
public:
  explicit TerminalEffects(Memory &memory)
      : clipboard(AllocatorRef<Byte, Memory>{memory}) {}

  void refresh(GhosttyTerminal terminal) {
    if (title_pending) {
      GhosttyString value{};
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value));
      updateTitle({reinterpret_cast<const char *>(value.ptr), value.len});
      title_pending = false;
    }

    if (cwd_pending) {
      GhosttyString value{};
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &value));
      updateCwd({reinterpret_cast<const char *>(value.ptr), value.len});
      cwd_pending = false;
    }
  }

  GhosttyClipboardWriteResult receiveClipboard(const GhosttyClipboardWrite &write) noexcept {
    constexpr std::size_t clipboard_limit = 1024 * 1024;
    if (write.size < sizeof(GhosttyClipboardWrite)) {
      return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
    }

    if (write.contents_len == 0) {
      clipboard.clear();
      ++clipboard_revision;
      return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
    }

    for (std::size_t index = 0; index < write.contents_len; ++index) {
      const auto &content = write.contents[index];
      const std::string_view mime{reinterpret_cast<const char *>(content.mime.ptr), content.mime.len};
      if (mime != "text/plain") {
        continue;
      }

      if (content.data.len > clipboard_limit) {
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
      }

      try {
        clipboard.assign(content.data.ptr, content.data.ptr + content.data.len);
        ++clipboard_revision;
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
      } catch (...) {
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY;
      }
    }

    return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
  }

  std::string_view title() const noexcept {
    return {title_.data(), title_length_};
  }

  std::string_view cwd() const noexcept {
    return {cwd_.data(), cwd_length_};
  }

  void setProgress(PaneProgressState state, std::optional<Byte> percent) noexcept {
    if (state == progress_state && percent == progress_percent) {
      return;
    }

    progress_state = state;
    progress_percent = percent;
    ++progress_revision;
  }

  Vector<Byte, Memory> clipboard;
  std::uint64_t title_revision = 1;
  std::uint64_t cwd_revision = 0;
  std::uint64_t clipboard_revision = 0;
  std::uint64_t progress_revision = 1;
  PaneProgressState progress_state = PaneProgressState::remove;
  std::optional<Byte> progress_percent;
  bool title_pending = false;
  bool cwd_pending = false;

private:
  void updateTitle(std::string_view raw) {
    std::array<char, 256> candidate{};
    std::size_t length = 0;
    while (!raw.empty()) {
      const auto first = static_cast<Byte>(raw.front());
      const std::size_t count = first < 0x80 ? 1 : first < 0xe0 ? 2
                                               : first < 0xf0   ? 3
                                                                : 4;
      if (raw.size() < count || count > candidate.size() - length) {
        break;
      }

      const auto sequence = raw.substr(0, count);
      raw.remove_prefix(count);
      if (count == 1 && (first < 0x20 || first == 0x7f)) {
        continue;
      }

      try {
        validateUtf8(sequence);
      } catch (const EncodingError &) {
        continue;
      }

      std::copy(sequence.begin(), sequence.end(), candidate.begin() + length);
      length += count;
    }

    if (title() != std::string_view{candidate.data(), length}) {
      title_ = candidate;
      title_length_ = length;
      ++title_revision;
    }
  }

  void updateCwd(std::string_view raw) {
    bool encoded = false;
    for (const auto prefix : {std::string_view{"file://"}, std::string_view{"kitty-shell-cwd://"}}) {
      if (raw.starts_with(prefix)) {
        raw.remove_prefix(prefix.size());
        const auto slash = raw.find('/');
        if (slash == std::string_view::npos) {
          return;
        }
        raw.remove_prefix(slash);
        encoded = true;
        break;
      }
    }

    if (raw.empty() || raw.front() != '/' || raw.size() > cwd_.size()) {
      return;
    }

    std::array<char, 4096> candidate{};
    std::size_t length = 0;
    while (!raw.empty()) {
      char character = raw.front();
      if (encoded && character == '%') {
        if (raw.size() < 3) {
          return;
        }
        unsigned byte = 0;
        const auto parsed = std::from_chars(raw.data() + 1, raw.data() + 3, byte, 16);
        if (parsed.ec != std::errc{} || parsed.ptr != raw.data() + 3) {
          return;
        }
        character = static_cast<char>(byte);
        raw.remove_prefix(2);
      }
      if (character == '\0') {
        return;
      }
      candidate[length++] = character;
      raw.remove_prefix(1);
    }

    if (cwd() != std::string_view{candidate.data(), length}) {
      cwd_ = candidate;
      cwd_length_ = length;
      ++cwd_revision;
    }
  }

  std::array<char, 256> title_{};
  std::array<char, 4096> cwd_{};
  std::size_t title_length_ = 0;
  std::size_t cwd_length_ = 0;
};

}
