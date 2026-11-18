module telar.runtime.plugins.tap_configuration;

import telar.lua;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime::plugins {

  ActionEncoder::ActionEncoder(const config::RetainedActionValidator& validator)
      : validator_(validator) {}

  std::span<const Byte> ActionEncoder::encode(const lua::Value& result) {
    auto output = storage_.viewMut().subspan(1);
    Byte count = 0;

    if (result.field("kind").present()) {
      count = static_cast<Byte>(append(result, output));
    } else {
      const auto length = std::min(result.listLength(), ActionProtocol::maximum_effects);

      for (std::size_t index = 0; index < length; ++index) {
        count += static_cast<Byte>(append(result.element(static_cast<lua_Integer>(index) + 1), output));
      }
    }

    storage_.atMut(0) = count;
    return std::span{storage_}.first(storage_.size() - output.size());
  }

  bool ActionEncoder::append(const lua::Value& value, std::span<Byte>& output) const {
    if (value.is(LUA_TFUNCTION)) {
      value.fail("cannot return another callback");
    }

    if (!validator_.validate(value)) {
      return false;
    }

    if (value.is(LUA_TSTRING)) {
      builtin(value.string(), output);
    } else {
      const auto kind = value.field("kind");
      const auto name = kind.string();
      if (name == "notification") {
        notification(value, output);
      } else if (name == "select-tab" || name == "select-workspace") {
        tag(name == "select-tab" ? ActionTag::select_tab : ActionTag::select_workspace, output);
        u8::encode(static_cast<Byte>(value.field("index").integer() - 1), output);
      } else if (name == "select-tab-offset") {
        tag(ActionTag::tab_offset, output);
        u8::encode(static_cast<Byte>(value.field("offset").integer()), output);
      } else if (name == "split-pane" || name == "focus-pane" || name == "resize-pane" || name == "resize-sidebar" || name == "move-tab") {
        directional(name, value.field("direction").string(), output);
      } else {
        builtin(name, output);
      }
    }

    return true;
  }

  void ActionEncoder::tag(ActionTag value, std::span<Byte>& output) {
    u8::encode(static_cast<Byte>(value), output);
  }

  void ActionEncoder::directional(std::string_view name, std::string_view direction, std::span<Byte>& output) {
    constexpr auto kinds = ds::Array<std::pair<std::string_view, ActionTag>, 5>{{
        {"split-pane", ActionTag::split},
        {"focus-pane", ActionTag::focus},
        {"resize-pane", ActionTag::resize},
        {"resize-sidebar", ActionTag::resize_sidebar},
        {"move-tab", ActionTag::move_tab},
    }};

    const auto* found = std::ranges::find(kinds, name, &decltype(kinds)::value_type::first);
    if (found == kinds.end()) {
      throw lua::Error{"Unsupported directional plugin effect"};
    }

    const auto kind = found->second;
    constexpr ds::Array directions{"left", "right", "up", "down"};
    Byte index = 0;

    if (kind == ActionTag::split) {
      index = static_cast<Byte>(direction == "vertical");
    } else if (kind == ActionTag::move_tab) {
      index = static_cast<Byte>(direction == "next");
    } else {
      index = static_cast<Byte>(std::ranges::find(directions, direction) - directions.begin());
    }

    tag(kind, output);
    u8::encode(index, output);
  }

  void ActionEncoder::builtin(std::string_view name, std::span<Byte>& output) {
    constexpr auto simple = ds::Array<std::pair<std::string_view, ActionTag>, 11>{{
        {"toggle-sidebar", ActionTag::sidebar},
        {"close-pane", ActionTag::close_pane},
        {"new-tab", ActionTag::new_tab},
        {"rename-tab", ActionTag::rename_tab},
        {"close-tab", ActionTag::close_tab},
        {"detach", ActionTag::detach},
        {"toggle-pane-fullscreen", ActionTag::fullscreen},
        {"toggle-workspace-list", ActionTag::workspace_list},
        {"new-workspace", ActionTag::new_workspace},
        {"rename-workspace", ActionTag::rename_workspace},
        {"leave-worktree", ActionTag::leave_worktree},
    }};

    for (const auto& [known, value] : simple) {
      if (name == known) {
        tag(value, output);
        return;
      }
    }

    if (name == "next-tab" || name == "previous-tab") {
      tag(ActionTag::tab_offset, output);
      u8::encode(name == "next-tab" ? Byte{1} : std::bit_cast<Byte>(std::int8_t{-1}), output);
      return;
    }

    constexpr auto stems = ds::Array<std::pair<std::string_view, std::string_view>, 5>{{
        {"resize-sidebar-", "resize-sidebar"},
        {"move-tab-", "move-tab"},
        {"split-", "split-pane"},
        {"focus-", "focus-pane"},
        {"resize-", "resize-pane"},
    }};

    for (const auto& [prefix, kind] : stems) {
      if (name.starts_with(prefix)) {
        directional(kind, name.substr(prefix.size()), output);
        return;
      }
    }

    for (const auto& [prefix, kind] : {std::pair{std::string_view{"select-tab-"}, ActionTag::select_tab}, std::pair{std::string_view{"select-workspace-"}, ActionTag::select_workspace}}) {
      if (name.starts_with(prefix)) {
        // The configuration admitted 1..255; the encoder still refuses anything else.
        const auto index = unsignedNumber<unsigned>(name.substr(prefix.size()), std::numeric_limits<Byte>::max()).value_or(0);
        if (index == 0) {
          throw std::invalid_argument{"Invalid tab or workspace index"};
        }

        tag(kind, output);
        u8::encode(static_cast<Byte>(index - 1), output);
        return;
      }
    }

    throw lua::Error{"Action is not supported by the plugin worker protocol"};
  }

  void ActionEncoder::text(std::string_view value, std::span<Byte>& output) {
    u16::encode(static_cast<std::uint16_t>(value.size()), output);
    if (value.size() > output.size()) {
      throw EncodingError{"Plugin result exceeds its bounds"};
    }

    std::ranges::copy(value, output.begin());
    output = output.subspan(value.size());
  }

  void ActionEncoder::notification(const lua::Value& value, std::span<Byte>& output) {
    tag(ActionTag::notification, output);
    const auto level = value.field("level");
    constexpr ds::Array levels{"info", "success", "warning", "failure"};

    u8::encode(level.present() ? static_cast<Byte>(std::ranges::find(levels, level.string()) - levels.begin()) : Byte{0}, output);
    u32::encode(static_cast<std::uint32_t>(value.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms)), output);
    constexpr ds::Array targets{"pane_id", "tab_id", "workspace_id"};
    Byte target_kind = 0;
    std::uint64_t target_id = 0;

    for (std::size_t index = 0; index < targets.size(); ++index) {
      const auto target = value.field(targets[index]);
      if (target.present()) {
        target_kind = static_cast<Byte>(index + 1);
        target_id = static_cast<std::uint64_t>(target.integer());
      }
    }

    u8::encode(target_kind, output);
    if (target_kind != 0) {
      u64::encode(target_id, output);
    }

    text(utf8Prefix(value.field("title").string(), max_notification_title_bytes), output);
    const auto body = value.field("body");

    text(body.present() ? utf8Prefix(body.string(), max_notification_message_bytes) : std::string_view{}, output);
  }

  template <Allocator Memory>
  PackageSnapshots<Memory>::PackageSnapshots(Memory& memory) noexcept
      : memory_(memory) {}

  template <Allocator Memory>
  Package PackageSnapshots<Memory>::copy(const Package& package, std::size_t index) {
    if (!directory_) {
      directory_.emplace("/tmp/telar-tap-workers-XXXXXX");
    }

    ds::Array<char, 32> name;
    constexpr std::string_view prefix = "package-";

    std::copy(prefix.begin(), prefix.end(), name.dataMut());
    const auto suffix = std::to_chars(name.dataMut() + prefix.size(), name.dataMut() + name.size() - 1, index);
    if (suffix.ec != std::errc{}) {
      throw std::length_error{"Plugin package index exceeds its limit"};
    }

    *suffix.ptr = '\0';
    if (::mkdirat(directory_->descriptor(), name.data(), 0700) != 0) {
      throw SystemError{"Create plugin snapshot"};
    }

    auto target = openBeneath(directory_->descriptor(), name.data(), O_RDONLY | O_DIRECTORY);
    ds::String<Memory> destination{memory_, directory_->path()};

    destination.push('/');
    destination.append(name.data());
    return PackageCopy{memory_}.copy(package, target.get(), destination);
  }

  template <Allocator Memory>
  std::string_view PackageSnapshots<Memory>::path() const noexcept {
    return directory_ ? directory_->path() : std::string_view{};
  }

  bool RestartWindow::record(std::chrono::milliseconds now) noexcept {
    if (count_ < restarts_.size()) {
      restarts_.atMut(count_++) = now;
      return count_ == restarts_.size() && now - restarts_.front() <= Limits::restart_window;
    }

    if (now - restarts_.front() <= Limits::restart_window) {
      return true;
    }

    std::move(restarts_.dataMut() + 1, (restarts_.dataMut() + restarts_.size()), restarts_.dataMut());
    restarts_.atMut(restarts_.size() - 1) = now;
    return false;
  }

  TapBudget::Charge::Charge(CaptureQuota& quota, std::size_t bytes) noexcept
      : quota_(quota),
        bytes_(bytes) {}

  TapBudget::Charge::~Charge() {
    quota_.release(bytes_);
  }

  TapBudget::Charge::Charge(Charge&& other) noexcept
      : quota_(other.quota_),
        bytes_(std::exchange(other.bytes_, 0)) {}

  TapBudget::TapBudget(std::size_t limit) noexcept
      : quota_(limit) {}

  auto TapBudget::charge(std::size_t bytes) noexcept -> ds::Option<Charge> {
    if (!quota_.reserveExact(bytes)) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return ds::none;
    }

    return Charge{quota_, bytes};
  }

  std::size_t TapBudget::used() const noexcept {
    return quota_.used();
  }

  std::uint64_t TapBudget::dropped() const noexcept {
    return dropped_.load(std::memory_order_relaxed);
  }

  SharedExchange::SharedExchange(TapBudget::Charge charge, std::uint64_t event_id, CapturedExchange exchange) noexcept
      : charge(std::move(charge)),
        event_id(event_id),
        exchange(std::move(exchange)) {}

  std::size_t SharedExchange::capturedBytes(const CapturedExchange& exchange) noexcept {
    return (exchange.request ? exchange.request->capturedBytes() : 0) + (exchange.response ? exchange.response->capturedBytes() : 0);
  }

  template <Allocator Memory>
  std::span<const ServiceSpec> TapConfiguration<Memory>::specifications() const noexcept {
    return std::span{specifications_}.first(count_);
  }

  template class PackageSnapshots<Memory>;
  template class PackageSnapshots<ConcurrentMemory>;
  template class TapConfiguration<Memory>;
  template class TapConfiguration<ConcurrentMemory>;

}
