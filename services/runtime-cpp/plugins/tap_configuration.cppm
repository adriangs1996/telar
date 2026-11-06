module;

#include "telar_base/text/utf8.hpp"
#include <string_view>
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cinttypes>
#include <cstdio>
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <cmath>
#include <initializer_list>
#include <optional>
#include <string>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <concepts>
#include "telar_client/serializers/telar_messages.hpp"
#include <bit>


#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <cstdlib>
#include <limits.h>
#include <sys/stat.h>
#include "telar_platform/open_directory.h"
#include "telar_base/memory/fixed_text.hpp"
#include <charconv>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <unistd.h>
#include <openssl/sha.h>


#include <poll.h>
#include <sys/uio.h>
#include <utility>


#include <atomic>
#include <memory>


#include <cassert>

export module telar.runtime.plugins.tap_configuration;

export import telar.config;
export import telar.plugins;


export import telar.platform;


export import telar.runtime.platform.stream_read_buffer;


export import telar.runtime.exchange_capture.exchange;

// Interface: plugins/action_encoder.cppm
export {
namespace telar::runtime::plugins {

class ActionEncoder {
public:
  inline explicit ActionEncoder(const config::RetainedActionValidator &validator)
      : validator_(validator) {}

  inline std::span<const Byte> encode(const lua::Value &result) {
    auto output = std::span{storage_}.subspan(1);
    Byte count = 0;
    if (result.field("kind").present()) {
      count = static_cast<Byte>(append(result, output));
    } else {
      const auto length = std::min(result.listLength(), ActionProtocol::maximum_effects);
      for (std::size_t index = 0; index < length; ++index) {
        count += static_cast<Byte>(append(result.element(static_cast<lua_Integer>(index) + 1), output));
      }
    }

    storage_[0] = count;
    return std::span{storage_}.first(storage_.size() - output.size());
  }

private:
  inline bool append(const lua::Value &value, std::span<Byte> &output) const {
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

  inline static void tag(ActionTag value, std::span<Byte> &output) {
    u8::encode(static_cast<Byte>(value), output);
  }

  inline static void directional(std::string_view name, std::string_view direction, std::span<Byte> &output) {
    constexpr auto kinds = std::to_array<std::pair<std::string_view, ActionTag>>({
        {"split-pane", ActionTag::split},
        {"focus-pane", ActionTag::focus},
        {"resize-pane", ActionTag::resize},
        {"resize-sidebar", ActionTag::resize_sidebar},
        {"move-tab", ActionTag::move_tab},
    });
    const auto *found = std::ranges::find(kinds, name, &decltype(kinds)::value_type::first);
    if (found == kinds.end()) {
      throw lua::Error{"Unsupported directional plugin effect"};
    }

    const auto kind = found->second;
    constexpr std::array directions{"left", "right", "up", "down"};
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

  inline static void builtin(std::string_view name, std::span<Byte> &output) {
    constexpr auto simple = std::to_array<std::pair<std::string_view, ActionTag>>({
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
    });
    for (const auto &[known, value] : simple) {
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

    constexpr auto stems = std::to_array<std::pair<std::string_view, std::string_view>>({
        {"resize-sidebar-", "resize-sidebar"},
        {"move-tab-", "move-tab"},
        {"split-", "split-pane"},
        {"focus-", "focus-pane"},
        {"resize-", "resize-pane"},
    });
    for (const auto &[prefix, kind] : stems) {
      if (name.starts_with(prefix)) {
        directional(kind, name.substr(prefix.size()), output);
        return;
      }
    }

    for (const auto &[prefix, kind] : {std::pair{std::string_view{"select-tab-"}, ActionTag::select_tab}, std::pair{std::string_view{"select-workspace-"}, ActionTag::select_workspace}}) {
      if (name.starts_with(prefix)) {
        unsigned index = 0;
        constexpr unsigned radix = 10;
        for (const char byte : name.substr(prefix.size())) {
          if (byte != '_') {
            index = (index * radix) + static_cast<unsigned>(byte - '0');
          }
        }

        tag(kind, output);
        u8::encode(static_cast<Byte>(index - 1), output);
        return;
      }
    }

    throw lua::Error{"Action is not supported by the plugin worker protocol"};
  }

  inline static void text(std::string_view value, std::span<Byte> &output) {
    u16::encode(static_cast<std::uint16_t>(value.size()), output);
    if (value.size() > output.size()) {
      throw EncodingError{"Plugin result exceeds its bounds"};
    }

    std::ranges::copy(value, output.begin());
    output = output.subspan(value.size());
  }

  inline static void notification(const lua::Value &value, std::span<Byte> &output) {
    tag(ActionTag::notification, output);
    const auto level = value.field("level");
    constexpr std::array levels{"info", "success", "warning", "failure"};
    u8::encode(level.present() ? static_cast<Byte>(std::ranges::find(levels, level.string()) - levels.begin()) : Byte{0}, output);
    u32::encode(static_cast<std::uint32_t>(value.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms)), output);
    constexpr std::array targets{"pane_id", "tab_id", "workspace_id"};
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

  const config::RetainedActionValidator &validator_;
  std::array<Byte, ActionProtocol::maximum_bytes> storage_;
};

}
}

// Interface: plugins/package_snapshots.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
class PackageSnapshots {
public:
  inline explicit PackageSnapshots(Memory &memory) noexcept : memory_(memory) {}

  inline Package copy(const Package &package, std::size_t index) {
    if (!directory_) {
      directory_.emplace("/tmp/telar-tap-workers-XXXXXX");
    }

    std::array<char, 32> name;
    constexpr std::string_view prefix = "package-";
    std::copy(prefix.begin(), prefix.end(), name.begin());
    const auto suffix = std::to_chars(name.data() + prefix.size(), name.data() + name.size() - 1, index);
    if (suffix.ec != std::errc{}) {
      throw std::length_error{"Plugin package index exceeds its limit"};
    }
    *suffix.ptr = '\0';
    if (::mkdirat(directory_->descriptor(), name.data(), 0700) != 0) {
      throw SystemError{"Create plugin snapshot"};
    }

    auto target = openBeneath(directory_->descriptor(), name.data(), O_RDONLY | O_DIRECTORY);
    String<Memory> destination{directory_->path(), AllocatorRef<char, Memory>{memory_}};
    destination += '/';
    destination += name.data();
    return PackageCopy{memory_}.copy(package, target.get(), destination);
  }

  inline std::string_view path() const noexcept { return directory_ ? directory_->path() : std::string_view{}; }

private:
  Memory &memory_;
  std::optional<TemporaryDirectory> directory_;
};

}
}

// Interface: plugins/pipe_stream.cppm
export {
namespace telar::runtime::plugins {

template <typename Wait>
concept PipeWait = requires(Wait &wait, int descriptor, short events) {
  { wait.active() } noexcept -> std::same_as<bool>;
  { wait.ready(descriptor, events) } noexcept -> std::same_as<bool>;
};

struct BlockingPipeWait {
  inline bool active() const noexcept { return true; }
  inline bool ready(int, short) const noexcept { return true; }
};

template <PipeWait Wait = BlockingPipeWait>
class PipeStream {
public:
  inline explicit PipeStream(int input, int output, Wait wait = {}) noexcept
      : input_(input), output_(output), wait_(std::move(wait)) {}

  inline Wait &wait() noexcept { return wait_; }
  inline const Wait &wait() const noexcept { return wait_; }

  inline StreamResult read(std::span<std::uint8_t> destination) noexcept {
    while (wait_.active()) {
      const auto count = ::read(input_, destination.data(), destination.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_.ready(input_, POLLIN)) {
        continue;
      }
      if (count < 0) {
        return {StreamResult::State::failed};
      }
      if (count == 0) {
        return {StreamResult::State::ended};
      }
      return {StreamResult::State::data, static_cast<std::size_t>(count)};
    }
    return {StreamResult::State::failed};
  }

  inline void write(std::span<const std::uint8_t> prefix, std::span<const std::uint8_t> payload) {
    std::array vectors{
        iovec{const_cast<std::uint8_t *>(prefix.data()), prefix.size()},
        iovec{const_cast<std::uint8_t *>(payload.data()), payload.size()},
    };
    std::size_t first = 0;
    while (first < vectors.size()) {
      if (!wait_.active()) {
        throw SystemError{"Wait for tap pipe"};
      }

      const auto count = ::writev(output_, vectors.data() + first, static_cast<int>(vectors.size() - first));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_.ready(output_, POLLOUT)) {
        continue;
      }
      if (count <= 0) {
        throw SystemError{"Write tap frame", count == 0 ? EPIPE : errno};
      }

      auto consumed = static_cast<std::size_t>(count);
      while (first < vectors.size() && consumed >= vectors[first].iov_len) {
        consumed -= vectors[first].iov_len;
        ++first;
      }
      if (first < vectors.size()) {
        vectors[first].iov_base = static_cast<std::uint8_t *>(vectors[first].iov_base) + consumed;
        vectors[first].iov_len -= consumed;
      }
    }
  }

private:
  int input_;
  int output_;
  Wait wait_;
};

template <PipeWait Wait = BlockingPipeWait>
PipeStream(int input, int output, Wait wait = {}) -> PipeStream<Wait>;

}
}

// Interface: plugins/restart_window.cppm
export {
namespace telar::runtime::plugins {

class RestartWindow {
public:
  inline bool record(std::chrono::milliseconds now) noexcept {
    if (count_ < restarts_.size()) {
      restarts_[count_++] = now;
      return count_ == restarts_.size() && now - restarts_.front() <= Limits::restart_window;
    }
    if (now - restarts_.front() <= Limits::restart_window) {
      return true;
    }

    std::move(restarts_.begin() + 1, restarts_.end(), restarts_.begin());
    restarts_.back() = now;
    return false;
  }

private:
  std::array<std::chrono::milliseconds, Limits::restarts> restarts_;
  std::size_t count_ = 0;
};

}
}

// Interface: plugins/service_spec.cppm
export {
namespace telar::runtime::plugins {

struct ServiceSpec {
  std::uint8_t package_index = 0;
  std::uint64_t plugin_id = 0;
  PackageDigest digest{};
  std::uint64_t generation = 0;
  FixedText<PackageLimits::id_bytes> name;
  FixedText<PATH_MAX> entry;
  Capabilities declared;
  Capabilities granted;
  std::shared_ptr<std::atomic<bool>> permission;

  inline bool allows(Capability capability) const noexcept {
    return authorized() && declared.contains(capability) && granted.contains(capability);
  }

  inline bool authorized() const noexcept { return !permission || permission->load(std::memory_order_acquire); }

  inline bool traffic() const noexcept { return allows(Capability::traffic_observe) || allows(Capability::traffic_intercept) || allows(Capability::traffic_control) || allows(Capability::traffic_record); }

  inline bool stillAuthorized(Capabilities current) const noexcept { return current.containsAll(declared.intersection(granted)); }
};

}
}

// Interface: plugins/tap_budget.cppm
export {
namespace telar::runtime::plugins {

class TapBudget {
public:
  class Charge {
  public:
    inline explicit Charge(CaptureQuota &quota, std::size_t bytes) noexcept : quota_(quota), bytes_(bytes) {}
    inline ~Charge() { quota_.release(bytes_); }

    Charge(const Charge &) = delete;
    Charge &operator=(const Charge &) = delete;
    inline Charge(Charge &&other) noexcept : quota_(other.quota_), bytes_(std::exchange(other.bytes_, 0)) {}

  private:
    CaptureQuota &quota_;
    std::size_t bytes_;
  };

  inline explicit TapBudget(std::size_t limit = Limits::held_bytes) noexcept : quota_(limit) {}

  inline std::optional<Charge> charge(std::size_t bytes) noexcept {
    if (!quota_.reserveExact(bytes)) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return std::nullopt;
    }
    return Charge{quota_, bytes};
  }

  inline std::size_t used() const noexcept { return quota_.used(); }
  inline std::uint64_t dropped() const noexcept { return dropped_.load(std::memory_order_relaxed); }

private:
  CaptureQuota quota_;
  std::atomic<std::uint64_t> dropped_{0};
};

}
}

// Interface: plugins/shared_exchange.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
struct SharedExchange {
  inline explicit SharedExchange(TapBudget::Charge charge, std::uint64_t event_id, CapturedExchange<Memory> exchange) noexcept
      : charge(std::move(charge)), event_id(event_id), exchange(std::move(exchange)) {}

  inline static std::size_t capturedBytes(const CapturedExchange<Memory> &exchange) noexcept {
    return (exchange.request ? exchange.request->capturedBytes() : 0) + (exchange.response ? exchange.response->capturedBytes() : 0);
  }

  TapBudget::Charge charge;
  std::uint64_t event_id;
  CapturedExchange<Memory> exchange;
};

}
}

// Interface: plugins/tap_configuration.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
class TapConfiguration {
public:
  template <EnvironmentLookup Environment>
  inline explicit TapConfiguration(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> configured, const Environment &environment)
      : snapshots_(memory) {
    if (directory.empty()) {
      return;
    }

    const auto trust = loadTrust(memory, environment);
    const PackageRegistry registry{memory, directory, configured};
    for (const auto &package : registry.packages()) {
      const auto granted = trust.granted(package.manifest.id.view(), package.digest);
      const auto allowed = [&](Capability capability) { return package.manifest.capabilities.contains(capability) && granted.contains(capability); };
      if (!allowed(Capability::proxy_tap) && !allowed(Capability::traffic_observe) && !allowed(Capability::traffic_intercept) && !allowed(Capability::traffic_control) && !allowed(Capability::traffic_record)) {
        continue;
      }
      if (count_ == specifications_.size()) {
        throw std::invalid_argument{"Too many tap plugins"};
      }

      const auto copied = snapshots_.copy(package, count_);
      auto &specification = specifications_[count_];
      specification.package_index = static_cast<std::uint8_t>(count_);
      specification.plugin_id = stableId(copied.manifest.id.view());
      specification.digest = copied.digest;
      specification.generation = initial_generation;
      specification.name = copied.manifest.id;
      specification.declared = copied.manifest.capabilities;
      specification.granted = granted;
      String<Memory> entry{copied.root.view(), AllocatorRef<char, Memory>{memory}};
      entry += '/';
      entry += copied.manifest.entry.view();
      specification.entry.assign(entry);
      ++count_;
    }
  }

  inline std::span<const ServiceSpec> specifications() const noexcept { return std::span{specifications_}.first(count_); }

private:
  template <EnvironmentLookup Environment>
  inline static TrustStore loadTrust(Memory &memory, const Environment &environment) {
    return TrustStore::load(memory, Paths::trust(memory, environment));
  }

  static constexpr std::uint64_t initial_generation = 1;
  PackageSnapshots<Memory> snapshots_;
  std::array<ServiceSpec, Limits::workers> specifications_;
  std::size_t count_ = 0;
};

template <Allocator Memory, EnvironmentLookup Environment>
TapConfiguration(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> configured, const Environment &environment) -> TapConfiguration<Memory>;

}
}
