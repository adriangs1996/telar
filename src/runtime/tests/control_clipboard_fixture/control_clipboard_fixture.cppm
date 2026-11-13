export module telar.runtime.tests.control_clipboard_fixture;

import std;
export import telar.runtime.tests.clipboard_task;

export {
namespace telar::runtime::control_test {

struct MemoryClipboard {
  std::vector<ClipboardContent> contents;
  ClipboardConsent consent = ClipboardConsent::deny;
  std::uint64_t reads = 0;
  std::uint64_t writes = 0;
  std::uint64_t prompts = 0;

  bool supports(bool primary) const noexcept { return !primary; }

  ClipboardResult read(const OwnedClipboardTask &task) {
    ++reads;
    ClipboardResult result{.status = ClipboardDesktopStatus::success};
    for (const auto &content : contents) {
      if (task.listing) {
        result.available.push_back(content.mime);
      }
    }
    for (const auto &mime : task.mimes) {
      for (const auto &content : contents) {
        if (mime == content.mime || (clipboardTextMime(mime) && content.mime == "text/plain")) {
          result.contents.push_back({mime, content.data});
          break;
        }
      }
    }
    return result;
  }

  ClipboardResult write(const OwnedClipboardTask &task) {
    ++writes;
    contents = task.contents;
    if (contents.empty()) {
      contents.push_back({"text/plain", {}});
    }
    return {.status = ClipboardDesktopStatus::success};
  }

  template <typename Terminal>
  void settle(Terminal &terminal) {
    auto &clipboard = terminal.clipboardControl();
    const auto request = clipboard.request(7, 11);
    if (!request) {
      return;
    }
    OwnedClipboardTask task{*request};
    clipboard.announced();
    if (!supports(task.primary)) {
      if (!clipboard.complete({1, 13}, CompleteClipboardDesktop{.ticket = task.ticket, .status = ClipboardDesktopStatus::unsupported, .prepared = true})) {
        throw std::logic_error{"Clipboard fixture capability check failed"};
      }
      terminal.resumeControl();
      return;
    }
    if (task.prompt) {
      ++prompts;
    }
    const bool allowed = !task.prompt || consent != ClipboardConsent::deny;
    if (!clipboard.complete({1, 13}, CompleteClipboardDesktop{
        .ticket = task.ticket,
        .status = allowed ? ClipboardDesktopStatus::success : ClipboardDesktopStatus::denied,
        .remember = task.rememberable && consent == ClipboardConsent::session,
        .prepared = true,
    })) {
      throw std::logic_error{"Clipboard fixture preparation failed"};
    }
    if (allowed) {
      if (!clipboard.execution()) {
        throw std::logic_error{"Clipboard fixture received no execution grant"};
      }
      clipboard.committed();
      const auto result = executeClipboard(task, consent, *this);
      std::array<ClipboardRepresentation, 4> representations;
      std::array<std::string_view, 16> available;
      for (std::size_t index = 0; index < result.contents.size(); ++index) {
        representations[index] = {result.contents[index].mime, result.contents[index].data};
      }
      std::copy(result.available.begin(), result.available.end(), available.begin());
      if (!clipboard.complete({1, 13}, CompleteClipboardDesktop{
          .ticket = task.ticket,
          .status = result.status,
          .contents = std::span{representations}.first(result.contents.size()),
          .available = std::span{available}.first(result.available.size()),
      })) {
        throw std::logic_error{"Clipboard fixture completion failed"};
      }
    }
    terminal.resumeControl();
  }
};

}
}
