module;

module telar.cli.hooks.session;
import telar.sys.posix;
import telar.wire.pane_io;
import telar.base.ds;

namespace telar::runtime::cli::hooks {

  void CodexSubagents::read(std::string_view path) noexcept {
    count_ = 0;
    if (!path.starts_with('/') || !path.ends_with(".jsonl") || path.size() >= PATH_MAX || path.contains('\0')) {
      return;
    }

    ds::Array<char, PATH_MAX> terminated{};

    std::ranges::copy(path, terminated.viewMut().begin());
    FileDescriptor file{::open(terminated.data(), combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat status{};
    if (!file || ::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != ::getuid()) {
      return;
    }

    constexpr std::size_t window_bytes = std::size_t{64} * 1024;
    ds::Array<char, window_bytes> window{};
    std::size_t held = 0;

    for (;;) {
      const auto space = window.viewMut().subspan(held);
      const auto received = ::read(file.get(), space.data(), space.size());
      if (received < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (received < 0) {
        count_ = 0;
        return;
      }

      const auto filled = held + static_cast<std::size_t>(received);
      const auto consumed = scan({window.data(), filled}, received == 0);

      if (received == 0) {
        return;
      }

      held = filled - consumed;
      static_cast<void>(std::ranges::shift_left(window.viewMut().first(filled), static_cast<std::ptrdiff_t>(consumed)));
    }
  }

  std::size_t CodexSubagents::countExcept(std::string_view finished) const noexcept {
    return count_ - static_cast<std::size_t>(find(finished) != count_);
  }

  tbc::val_a<std::string_view> CodexSubagents::value(tbc::val_a<std::string_view> item, std::string_view key) noexcept {
    const auto offset = item.find(key);
    if (offset == std::string_view::npos) {
      return {};
    }

    item.remove_prefix(offset + key.size());
    const auto end = item.find('"');

    return end == std::string_view::npos ? std::string_view{} : std::string_view{item.data(), end};
  }

  std::size_t CodexSubagents::find(std::string_view identifier) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      if (identifiers_[index].view() == identifier) {
        return index;
      }
    }

    return count_;
  }

  void CodexSubagents::apply(std::string_view item) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which the size check rules out
    const auto kind = value(item, R"("kind":")");
    const auto identifier = value(item, R"("agent_thread_id":")");
    if (identifier.empty() || identifier.size() > identifier_bytes) {
      return;
    }

    const auto index = find(identifier);
    if (kind == "started" && index == count_ && count_ != identifiers_.size()) {
      identifiers_.atMut(count_++).assign(identifier);
    } else if (kind == "completed" && index != count_) {
      // The last identifier fills the gap; copied first, as one element is read while another is written.
      const auto last = identifiers_[--count_];

      identifiers_.atMut(index) = last;
    }
  }

  std::size_t CodexSubagents::scan(std::string_view bytes, bool at_end) noexcept {
    constexpr std::string_view marker = R"("item":{"type":"SubAgentActivity")";
    constexpr std::size_t maximum_item_bytes = 1024;
    std::size_t cursor = 0;

    for (;;) {
      const auto start = bytes.find(marker, cursor);
      if (start == std::string_view::npos) {
        break;
      }

      const auto limit = std::min(bytes.size(), start + maximum_item_bytes);
      const auto close = std::string_view{bytes.data(), limit}.find('}', start + marker.size());
      if (close == std::string_view::npos) {
        if (limit == bytes.size() && !at_end) {
          return start;
        }

        cursor = start + marker.size();
        continue;
      }

      auto item = bytes;

      item.remove_prefix(start);
      apply({item.data(), close - start});
      cursor = close + 1;
    }

    const auto tail = std::min(bytes.size(), marker.size() - 1);

    return at_end ? bytes.size() : std::max(cursor, bytes.size() - tail);
  }

  bool Reports::empty() const noexcept {
    return !lifecycle && !command && !title && !progress;
  }

  Session::Session(Memory& memory, const char* socket, PaneTarget target)
      : control_(memory, socket, reply_bytes),
        target_(target) {
    constexpr unsigned timeout_seconds = 30;

    control_.receiveTimeout(timeout_seconds);
    exchange(VerifyPaneDescent{});
  }

  void Session::reportLimit(std::uint64_t received, std::size_t capacity) noexcept {
    try {
      control_.send(ReportLimit{.reach = {.name = "hooks.max_input_bytes", .noun = "bytes", .value = capacity, .requested = received}, .hits = 1});
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): the limit's report is best effort, as every report is.
    }
  }

}
