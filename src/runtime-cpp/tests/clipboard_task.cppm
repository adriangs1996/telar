export module telar.runtime.tests.clipboard_task;

import std;
export import telar.client.protocol;

export {
namespace telar::runtime::control_test {

struct ClipboardContent {
  std::string mime;
  std::vector<telar::Byte> data;
};

struct OwnedClipboardTask {
  explicit OwnedClipboardTask(const telar::ClipboardDesktopRequest &request)
      : ticket(request.ticket), write(request.write), primary(request.primary), prompt(request.prompt), listing(request.listing), rememberable(request.rememberable), name(request.name) {
    request.validate();
    if (request.mimes.size() > 4 || request.contents.size() > 128 || request.name.size() > 256) {
      throw telar::EncodingError{"Invalid clipboard request bounds"};
    }
    for (const auto mime : request.mimes) {
      mimes.emplace_back(mime);
    }
    for (const auto &content : request.contents) {
      contents.push_back({std::string{content.mime}, {content.data.begin(), content.data.end()}});
    }
  }

  telar::ClipboardTicket ticket;
  bool write;
  bool primary;
  bool prompt;
  bool listing;
  bool rememberable;
  std::string name;
  std::vector<std::string> mimes;
  std::vector<ClipboardContent> contents;
};

struct ClipboardResult {
  telar::ClipboardDesktopStatus status = telar::ClipboardDesktopStatus::failure;
  std::vector<ClipboardContent> contents{};
  std::vector<std::string> available{};
};

enum class ClipboardConsent {
  deny,
  once,
  session
};

inline bool clipboardTextMime(std::string_view mime) noexcept {
  return mime == "text/plain" || mime == "text/plain;charset=utf-8" || mime == "UTF8_STRING" || mime == "STRING" || mime == "TEXT";
}

// Providers perform synchronous desktop effects on their owning UI thread.
// Consent is checked here before a provider can inspect even clipboard types.
// Results own their bytes; neither a wire frame nor a platform MIME view is
// retained after the call.
template <typename Provider>
ClipboardResult executeClipboard(const OwnedClipboardTask &task, ClipboardConsent consent, Provider &provider) {
  if (task.prompt && consent == ClipboardConsent::deny) {
    return {.status = telar::ClipboardDesktopStatus::denied};
  }
  ClipboardResult result;
  try {
    if (!provider.supports(task.primary)) {
      return {.status = telar::ClipboardDesktopStatus::unsupported};
    }
    result = task.write ? provider.write(task) : provider.read(task);
  } catch (const std::bad_alloc &) {
    return {.status = telar::ClipboardDesktopStatus::failure};
  }
  if (result.status != telar::ClipboardDesktopStatus::success) {
    return {.status = result.status};
  }
  std::size_t size = 0;
  if (result.contents.size() > 4 || result.available.size() > 16) {
    return {.status = telar::ClipboardDesktopStatus::failure};
  }
  for (const auto &content : result.contents) {
    if (content.mime.empty() || content.mime.size() > 256 || content.data.size() > telar::clipboard_content_limit - size) {
      return {.status = telar::ClipboardDesktopStatus::failure};
    }
    size += content.data.size();
  }
  for (const auto &mime : result.available) {
    if (mime.empty() || mime.size() > 256) {
      return {.status = telar::ClipboardDesktopStatus::failure};
    }
  }
  return result;
}

}
}
