module;
#include "tbc/view.hpp"

export module telar.runtime.terminal.control.clipboard;

import std;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text;
import telar.config;
import telar.platform.primitives;
import telar.wire.clipboard;
import telar.wire.vocabulary;
import telar.runtime.terminal.control;

export namespace telar::runtime::control {

  enum class ClipboardOperation : std::uint8_t {
    read,
    write,
    data,
    alias,
  };

  enum class ClipboardStatus : std::uint8_t {
    ok,
    done,
    data,
    denied,
    invalid,
    too_large,
    busy,
    io_error,
    unsupported,
  };

  inline std::string_view clipboardStatusName(ClipboardStatus status) noexcept {
    switch (status) {
    case ClipboardStatus::ok:
      return "OK";
    case ClipboardStatus::done:
      return "DONE";
    case ClipboardStatus::data:
      return "DATA";
    case ClipboardStatus::denied:
      return "EPERM";
    case ClipboardStatus::invalid:
      return "EINVAL";
    case ClipboardStatus::too_large:
      return "EFBIG";
    case ClipboardStatus::busy:
      return "EBUSY";
    case ClipboardStatus::io_error:
      return "EIO";
    case ClipboardStatus::unsupported:
      return "ENOSYS";
    }

    return "EINVAL";
  }

  enum class MetadataValue : std::uint8_t {
    valid,
    invalid,
    overflow,
  };

  struct ClipboardMetadata {
    static constexpr std::size_t maximum_id = 512;
    static constexpr std::size_t maximum_mime = 256;
    static constexpr std::size_t maximum_password = 128;
    static constexpr std::size_t maximum_name = 256;

    ClipboardOperation operation{};
    bool primary = false;
    bool invalid_values = false;
    FixedText<maximum_id> id;
    FixedText<maximum_mime> mime;
    FixedText<maximum_password> password;
    FixedText<maximum_name> name;

    static std::optional<ClipboardMetadata> parse(std::string_view input) {
      std::string_view operation, location, id, mime, password, name;

      while (true) {
        const auto colon = input.find(':');
        const auto record = input.substr(0, colon);
        const auto equal = record.find('=');
        if (equal == std::string_view::npos) {
          return std::nullopt;
        }

        const auto key = record.substr(0, equal);
        const auto value = record.substr(equal + 1);

        if (key == "type") {
          operation = value;
        } else if (key == "loc") {
          location = value;
        } else if (key == "id") {
          id = value;
        } else if (key == "mime") {
          mime = value;
        } else if (key == "pw") {
          password = value;
        } else if (key == "name") {
          name = value;
        }

        if (colon == std::string_view::npos) {
          break;
        }

        input.remove_prefix(colon + 1);
      }

      ClipboardMetadata result;

      if (operation == "read") {
        result.operation = ClipboardOperation::read;
      } else if (operation == "write") {
        result.operation = ClipboardOperation::write;
      } else if (operation == "wdata") {
        result.operation = ClipboardOperation::data;
      } else if (operation == "walias") {
        result.operation = ClipboardOperation::alias;
      } else {
        return std::nullopt;
      }

      result.primary = location == "primary";
      std::array<char, maximum_id> sanitized;
      std::size_t size = 0;

      for (const auto byte : id) {
        const bool accepted = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '+' || byte == '.';

        if (size == sanitized.size()) {
          break;
        }

        if (accepted) {
          sanitized[size++] = byte;
        }
      }

      result.id.assign({sanitized.data(), size});
      result.invalid_values = decode(mime, result.mime) != MetadataValue::valid || decode(name, result.name) != MetadataValue::valid;
      // Oversized passwords cannot match a bounded grant. Their contents do not
      // need to be retained, but malformed short passwords still invalidate it.
      result.invalid_values |= decode(password, result.password) == MetadataValue::invalid;
      result.invalid_values |= result.mime.view().contains('\0');
      return result;
    }

  private:
    template <std::size_t Capacity>
    static MetadataValue decode(std::string_view encoded, FixedText<Capacity>& destination) {
      if (encoded.size() > (Capacity + 2) / 3 * 4) {
        return MetadataValue::overflow;
      }

      std::array<std::uint8_t, Capacity + 2> output;
      const auto length = base64::decode<base64::Padding::required>(encoded, output);
      if (!length) {
        return MetadataValue::invalid;
      }

      if (*length > Capacity) {
        return MetadataValue::overflow;
      }

      const std::string_view decoded{reinterpret_cast<const char*>(output.data()), *length};

      try {
        validateUtf8(decoded);
      } catch (const EncodingError&) {
        return MetadataValue::invalid;
      }

      destination.assign(decoded);
      return MetadataValue::valid;
    }
  };

  struct ClipboardRoute {
    std::uint64_t client = 0;
    std::uint64_t generation = 0;

    bool operator==(const ClipboardRoute&) const = default;
  };

  class ClipboardGrants {
  public:
    static constexpr std::size_t capacity = 32;
    static constexpr std::size_t password_length = 22;

    void grant(std::string_view password, ClipboardRoute route, bool write, bool once) {
      if (password.empty() || password.size() > ClipboardMetadata::maximum_password) {
        return;
      }

      Entry* entry = nullptr;

      for (auto& candidate : std::span{entries_}.first(count_)) {
        if (candidate.route == route && constantTimeEqual(candidate.password.view(), password)) {
          entry = &candidate;
          entry->once &= once;
          break;
        }
      }

      if (entry == nullptr) {
        if (count_ == entries_.size()) {
          std::move(entries_.begin() + 1, entries_.end(), entries_.begin());
          --count_;
        }

        entry = &entries_[count_++];
        entry->password.assign(password);
        entry->route = route;
        entry->read = false;
        entry->write = false;
        entry->once = once;
      }

      if (write) {
        entry->write = true;
      } else {
        entry->read = true;
      }
    }

    std::optional<ClipboardRoute> use(std::string_view password, bool write) {
      std::optional<std::size_t> matching;

      for (std::size_t index = 0; index < count_; ++index) {
        const auto& entry = entries_[index];
        if (!constantTimeEqual(entry.password.view(), password)) {
          continue;
        }

        matching = index;
        if (write ? entry.write : entry.read) {
          break;
        }
      }

      if (!matching) {
        return std::nullopt;
      }

      const auto index = *matching;
      const auto& entry = entries_[index];
      const bool permitted = write ? entry.write : entry.read;
      const auto route = entry.route;

      if (entry.once) {
        std::move(entries_.begin() + index + 1, entries_.begin() + count_, entries_.begin() + index);
        --count_;
      }

      return permitted ? std::optional{route} : std::nullopt;
    }

    void retain(std::span<const ClipboardRoute> routes) noexcept {
      std::size_t kept = 0;

      for (std::size_t index = 0; index < count_; ++index) {
        if (std::find(routes.begin(), routes.end(), entries_[index].route) != routes.end()) {
          if (kept != index) {
            entries_[kept] = entries_[index];
          }

          ++kept;
        }
      }

      count_ = kept;
    }

    void clear() noexcept {
      count_ = 0;
    }

    static FixedText<password_length> password() {
      constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
      static_assert(alphabet.size() == 64);
      std::array<std::uint8_t, password_length> random;

      randomBytes(random.data(), random.size());
      std::array<char, password_length> output;

      for (std::size_t index = 0; index < output.size(); ++index) {
        output[index] = alphabet[random[index] & (alphabet.size() - 1)];
      }

      FixedText<password_length> result;

      result.assign({output.data(), output.size()});
      return result;
    }

  private:
    struct Entry {
      FixedText<ClipboardMetadata::maximum_password> password;
      ClipboardRoute route;
      bool read = false;
      bool write = false;
      bool once = false;
    };

    std::array<Entry, capacity> entries_;
    std::size_t count_ = 0;
  };

  struct ClipboardContentView {
    std::string_view mime;
    std::span<const std::uint8_t> data;
  };

  template <Allocator Memory>
  class ClipboardWrite {
  public:
    static constexpr std::size_t maximum_mimes = 64;
    static constexpr std::size_t maximum_aliases = 64;

    // Copies the metadata; it keeps only its allocator, region `a`.
    explicit ClipboardWrite(tbc::view<Memory&, tbc::lt::a> memory, const ClipboardMetadata& metadata, std::size_t limit)
        : metadata(metadata),
          memory_(memory),
          spool_(AllocatorRef<std::uint8_t, Memory>{memory}),
          limit_(limit) {}

    // Its contents view its own spool and names, so it stays where it is built.
    ClipboardWrite(const ClipboardWrite&) = delete;
    ClipboardWrite& operator=(const ClipboardWrite&) = delete;

    ClipboardStatus data(std::string_view mime, std::string_view encoded) {
      if (!current_ || entries_[*current_].mime.view() != mime) {
        if (finishCurrent() != ClipboardStatus::ok) {
          return ClipboardStatus::invalid;
        }

        current_.reset();
        for (std::size_t index = 0; index < entry_count_; ++index) {
          if (entries_[index].mime.view() == mime) {
            current_ = index;
            break;
          }
        }

        if (!current_) {
          if (entry_count_ == maximum_mimes) {
            return ClipboardStatus::ok;
          }

          current_ = entry_count_++;
          entries_[*current_].mime.assign(mime);
        }

        auto& entry = entries_[*current_];

        entry.offset = spool_.size();
        entry.length = 0;
      }

      for (std::size_t index = 0; index < encoded.size(); ++index) {
        const auto byte = encoded[index];
        if (byte != '=' && base64::alphabet.find(byte) == std::string_view::npos) {
          return ClipboardStatus::invalid;
        }

        group_[group_size_++] = byte;
        if (group_size_ != group_.size()) {
          continue;
        }

        std::array<std::uint8_t, 3> decoded;
        const auto count = base64::decode<base64::Padding::required>({group_.data(), group_.size()}, decoded);
        if (!count || (*count != decoded.size() && index + 1 != encoded.size())) {
          return ClipboardStatus::invalid;
        }

        if (*count > limit_ - spool_.size()) {
          return ClipboardStatus::too_large;
        }

        reserve(*count);
        spool_.insert(spool_.end(), decoded.begin(), decoded.begin() + *count);
        group_size_ = 0;
      }

      return ClipboardStatus::ok;
    }

    ClipboardStatus alias(std::string_view mime, std::string_view encoded) {
      Vector<std::uint8_t, Memory> decoded{AllocatorRef<std::uint8_t, Memory>{memory_}};

      if (encoded.size() / 4 * 3 > limit_) {
        return ClipboardStatus::too_large;
      }

      decoded.resize(encoded.size() / 4 * 3);
      const auto length = base64::decode<base64::Padding::required>(encoded, decoded);
      if (!length) {
        return ClipboardStatus::invalid;
      }

      std::string_view remaining{reinterpret_cast<const char*>(decoded.data()), *length};

      try {
        validateUtf8(remaining);
      } catch (const EncodingError&) {
        return ClipboardStatus::invalid;
      }

      while (const auto name = token(remaining)) {
        if (name->contains('\0')) {
          return ClipboardStatus::invalid;
        }

        if (name->size() > ClipboardMetadata::maximum_mime) {
          continue;
        }

        auto index = alias_count_;

        for (std::size_t candidate = 0; candidate < alias_count_; ++candidate) {
          if (aliases_[candidate].name.view() == *name) {
            index = candidate;
            break;
          }
        }

        if (index == alias_count_) {
          if (alias_count_ == maximum_aliases) {
            continue;
          }

          aliases_[alias_count_++].name.assign(*name);
        }

        aliases_[index].target.assign(mime);
      }

      return ClipboardStatus::ok;
    }

    ClipboardStatus commit() {
      if (finishCurrent() != ClipboardStatus::ok) {
        return ClipboardStatus::invalid;
      }

      current_.reset();
      content_count_ = 0;
      for (const auto& entry : std::span{entries_}.first(entry_count_)) {
        contents_[content_count_++] = {entry.mime.view(), std::span<const std::uint8_t>{spool_}.subspan(entry.offset, entry.length)};
      }

      for (const auto& alias : std::span{aliases_}.first(alias_count_)) {
        std::optional<std::span<const std::uint8_t>> target;

        for (const auto& content : std::span{contents_}.first(content_count_)) {
          if (content.mime == alias.target.view()) {
            target = content.data;
            break;
          }
        }

        if (!target) {
          continue;
        }

        bool replaced = false;

        for (auto& content : std::span{contents_}.first(content_count_)) {
          if (content.mime == alias.name.view()) {
            content.data = *target;
            replaced = true;
            break;
          }
        }

        if (!replaced) {
          contents_[content_count_++] = {alias.name.view(), *target};
        }
      }

      // The desktop transport and platform clipboard have the same aggregate
      // budget, including alias representations that the desktop must copy.
      std::size_t total = 0;

      for (const auto& content : contents()) {
        if (content.data.size() > limit_ - total) {
          return ClipboardStatus::too_large;
        }

        total += content.data.size();
      }

      return ClipboardStatus::ok;
    }

    std::span<const ClipboardContentView> contents() const noexcept {
      return std::span{contents_}.first(content_count_);
    }

    static std::optional<std::string_view> token(std::string_view& remaining) noexcept {
      constexpr std::string_view whitespace = " \t\n\r\f\v";
      const auto first = remaining.find_first_not_of(whitespace);
      if (first == std::string_view::npos) {
        remaining = {};
        return std::nullopt;
      }

      remaining.remove_prefix(first);
      const auto end = remaining.find_first_of(whitespace);
      const auto result = remaining.substr(0, end);

      remaining = end == std::string_view::npos ? std::string_view{} : remaining.substr(end + 1);
      return result;
    }

    ClipboardMetadata metadata;

  private:
    struct Entry {
      FixedText<ClipboardMetadata::maximum_mime> mime;
      std::size_t offset = 0;
      std::size_t length = 0;
    };

    struct Alias {
      FixedText<ClipboardMetadata::maximum_mime> name;
      FixedText<ClipboardMetadata::maximum_mime> target;
    };

    ClipboardStatus finishCurrent() noexcept {
      if (group_size_ != 0) {
        return ClipboardStatus::invalid;
      }

      if (current_) {
        entries_[*current_].length = spool_.size() - entries_[*current_].offset;
      }

      return ClipboardStatus::ok;
    }

    void reserve(std::size_t count) {
      if (count > spool_.capacity() - spool_.size()) {
        spool_.reserve(std::min(limit_, std::max(spool_.size() + count, std::max(initial_capacity, spool_.capacity() * 2))));
      }
    }

    static constexpr std::size_t initial_capacity = 4096;
    tbc::view<Memory&, tbc::lt::a> memory_;
    tbc::view<Vector<std::uint8_t, Memory>, tbc::lt::a> spool_;
    std::size_t limit_;
    std::array<Entry, maximum_mimes> entries_;
    std::array<Alias, maximum_aliases> aliases_;
    tbc::view<std::array<ClipboardContentView, maximum_mimes + maximum_aliases>, tbc::lt::self> contents_;
    std::size_t entry_count_ = 0;
    std::size_t alias_count_ = 0;
    std::size_t content_count_ = 0;
    std::optional<std::size_t> current_;
    std::array<char, 4> group_;
    std::size_t group_size_ = 0;
  };

  inline constexpr std::size_t clipboard_chunk_bytes = 4096;

  struct ClipboardPacket {
    ClipboardOperation operation = ClipboardOperation::read;
    ClipboardStatus status = ClipboardStatus::ok;
    bool primary = false;
    std::string_view id{};
    std::optional<std::string_view> mime{};
    std::optional<std::string_view> password{};
    std::span<const std::uint8_t> payload{};
    Ending ending = Ending::escape;
  };

  template <Allocator Memory>
  void clipboardBase64(Reply<Memory>& reply, std::span<const std::uint8_t> input) {
    constexpr std::size_t raw_chunk_bytes = 3072;
    std::array<char, raw_chunk_bytes / 3 * 4> encoded;

    while (!input.empty()) {
      const auto count = std::min(input.size(), raw_chunk_bytes);
      const auto size = base64::encode(input.first(count), encoded);
      if (!size) {
        throw std::logic_error{"Clipboard encoder capacity invariant failed"};
      }

      reply.append({encoded.data(), *size});
      input = input.subspan(count);
    }
  }

  template <Allocator Memory>
  void clipboardBase64(Reply<Memory>& reply, std::string_view input) {
    clipboardBase64(reply, std::span{reinterpret_cast<const std::uint8_t*>(input.data()), input.size()});
  }

  template <Allocator Memory>
  void clipboardPacket(Reply<Memory>& reply, const ClipboardPacket& packet) {
    reply.append(packet.operation == ClipboardOperation::read ? "\x1b]5522;type=read:status=" : "\x1b]5522;type=write:status=");
    reply.append(clipboardStatusName(packet.status));
    if (packet.primary) {
      reply.append(":loc=primary");
    }

    if (!packet.id.empty()) {
      reply.append(":id=");
      reply.append(packet.id);
    }

    if (packet.mime) {
      reply.append(":mime=");
      clipboardBase64(reply, *packet.mime);
    }

    if (packet.password) {
      reply.append(":pw=");
      clipboardBase64(reply, *packet.password);
    }

    if (!packet.payload.empty()) {
      reply.append(";");
      clipboardBase64(reply, packet.payload);
    }

    reply.append(packet.ending == Ending::bell ? "\a" : "\x1b\\");
  }

  template <Allocator Memory>
  void clipboardReadSuccess(Reply<Memory>& reply, const ClipboardPacket& request, std::span<const ClipboardContentView> contents, std::span<const std::string_view> available, bool listing) {
    auto packet = request;

    packet.operation = ClipboardOperation::read;
    packet.status = ClipboardStatus::ok;
    clipboardPacket(reply, packet);
    packet.primary = false;
    if (listing) {
      std::array<std::uint8_t, clipboard_chunk_bytes> joined;
      std::size_t length = 0;

      for (const auto mime : available) {
        const auto separator = length == 0 ? 0u : 1u;
        if (mime.size() + separator + 1 > joined.size() - length) {
          break;
        }

        if (separator != 0) {
          joined[length++] = ' ';
        }

        std::copy(mime.begin(), mime.end(), joined.begin() + length);
        length += mime.size();
      }

      if (length != 0) {
        joined[length++] = '\n';
      }

      packet.status = ClipboardStatus::data;
      packet.mime = ".";
      packet.payload = std::span<const std::uint8_t>{joined}.first(length);
      clipboardPacket(reply, packet);
    }

    for (const auto& content : contents) {
      auto remaining = content.data;

      while (!remaining.empty()) {
        const auto count = std::min(remaining.size(), clipboard_chunk_bytes);

        packet.status = ClipboardStatus::data;
        packet.mime = content.mime;
        packet.payload = remaining.first(count);
        clipboardPacket(reply, packet);
        remaining = remaining.subspan(count);
      }
    }

    packet.status = ClipboardStatus::done;
    packet.mime.reset();
    packet.payload = {};
    clipboardPacket(reply, packet);
  }

  template <Allocator Memory>
  class Clipboard {
  public:
    using Clock = std::chrono::steady_clock;
    static constexpr std::size_t maximum_bytes = clipboard_content_limit;
    static constexpr std::size_t maximum_encoded_bytes = (maximum_bytes + 2) / 3 * 4;
    static constexpr auto request_timeout = std::chrono::seconds{30};

    explicit Clipboard(Memory& memory)
        : memory_(memory),
          decoded_(AllocatorRef<std::uint8_t, Memory>{memory}),
          transaction_(nullptr, AllocationDeleter<ClipboardWrite<Memory>, Memory>{memory}),
          pending_(nullptr, AllocationDeleter<Pending, Memory>{memory}),
          asynchronous_replies_{Reply<Memory>{memory}, Reply<Memory>{memory}} {}

    void routes(std::span<const ClipboardRoute> routes, std::optional<ClipboardRoute> preferred) {
      if (routes.size() > routes_.size()) {
        throw std::logic_error{"Too many clipboard client routes"};
      }

      std::copy(routes.begin(), routes.end(), routes_.begin());
      route_count_ = routes.size();
      preferred_ = preferred;
      grants_.retain(routes);
      if (pending_ && !live(pending_->route)) {
        cancelPending();
        finish(ClipboardStatus::denied);
      }
    }

    void traditional(std::string_view payload, const Policy& policy) {
      const auto separator = payload.find(';');
      if (separator == std::string_view::npos || separator > 1) {
        return;
      }

      const char kind = separator == 0 ? 'c' : payload.front();
      const char selection = kind == 'p' || kind == 's' ? kind : 'c';
      const auto encoded = payload.substr(separator + 1);
      const bool read = encoded == "?";
      const auto access = read ? policy.clipboard_read : policy.clipboard_write;
      if (access == Access::deny || pending_ || cancellation_ || reply_count_ != 0 || !preferred_) {
        return;
      }

      try {
        if (!read && !decode<base64::Padding::optional>(encoded)) {
          return;
        }

        pending_ = makeOwned<Pending>(memory_, memory_);
        auto& request = *pending_;

        request.traditional = true;
        request.selection = selection;
        request.write = !read;
        // Application OSC52 reads use the standard desktop clipboard while
        // echoing the requested selection name in the terminal response.
        request.metadata.primary = !read && (selection == 'p' || selection == 's');
        request.metadata.operation = read ? ClipboardOperation::read : ClipboardOperation::write;
        request.route = *preferred_;
        request.prompt = access == Access::ask;
        request.mimes[request.mime_count++].assign("text/plain");
        if (!read) {
          request.text.assign(decoded_.begin(), decoded_.end());
        }
      } catch (const std::bad_alloc&) {
        pending_.reset();
      }
    }

    void kitty(std::string_view payload, Ending ending, const Policy& policy, Reply<Memory>& reply) {
      const auto separator = payload.find(';');
      const auto metadata = ClipboardMetadata::parse(payload.substr(0, separator));
      if (!metadata) {
        return;
      }

      const auto data = separator == std::string_view::npos ? std::string_view{} : payload.substr(separator + 1);

      if (metadata->invalid_values) {
        if (transaction_ && (metadata->operation == ClipboardOperation::data || metadata->operation == ClipboardOperation::alias)) {
          abort(ClipboardStatus::invalid, ending, reply);
        }

        return;
      }

      const bool had_pending = pending_ != nullptr;

      try {
        switch (metadata->operation) {
        case ClipboardOperation::read:
          read(*metadata, data, ending, policy, reply);
          return;
        case ClipboardOperation::write:
          transaction_.reset();
          if (policy.clipboard_write == Access::deny) {
            status(*metadata, ClipboardStatus::denied, ending, reply);
          } else {
            transaction_ = makeOwned<ClipboardWrite<Memory>>(memory_, memory_, *metadata, maximum_bytes);
          }

          return;
        case ClipboardOperation::data:
        case ClipboardOperation::alias:
          if (!transaction_) {
            return;
          }

          if (metadata->operation == ClipboardOperation::data && metadata->mime.view().empty()) {
            commit(ending, policy, reply);
            return;
          }

          if (metadata->mime.view().empty()) {
            abort(ClipboardStatus::invalid, ending, reply);
            return;
          }

          const auto result = metadata->operation == ClipboardOperation::data ? transaction_->data(metadata->mime.view(), data) : transaction_->alias(metadata->mime.view(), data);
          if (result != ClipboardStatus::ok) {
            abort(result, ending, reply);
          }

          return;
        }
      } catch (const std::bad_alloc&) {
        if (!had_pending) {
          pending_.reset();
        }

        if (transaction_) {
          abort(ClipboardStatus::io_error, ending, reply);
        } else {
          status(*metadata, ClipboardStatus::io_error, ending, reply);
        }
      }
    }

    // All views are synchronous. Connection::send must copy/encode them before
    // returning; only the owning Pending crosses event-loop turns.
    std::optional<ClipboardDesktopRequest> request(std::uint64_t pane, std::uint64_t generation) {
      if (!pending_ || pending_->announced) {
        return std::nullopt;
      }

      auto& pending = *pending_;

      pending.ticket = {pane, generation, pending.route.generation, pending.nonce};
      const auto contents = pending.prepareViews();

      return ClipboardDesktopRequest{
          .ticket = pending.ticket,
          .write = pending.write,
          .primary = pending.metadata.primary,
          .prompt = pending.prompt,
          .listing = pending.listing,
          .rememberable = !pending.traditional && !pending.metadata.name.view().empty() && !pending.metadata.password.view().empty(),
          .name = pending.metadata.name.view(),
          .mimes = std::span{pending.mime_views}.first(pending.mime_count),
          .contents = std::span{pending.content_views}.first(contents),
      };
    }

    std::optional<ClipboardRoute> route() const noexcept {
      return pending_ ? std::optional{pending_->route} : std::nullopt;
    }

    void announced() noexcept {
      if (pending_) {
        pending_->announced = true;
      }
    }

    bool complete(ClipboardRoute sender, const CompleteClipboardDesktop& completion) {
      if (!pending_ || !pending_->announced || pending_->route != sender || pending_->ticket != completion.ticket || !live(sender)) {
        return false;
      }

      completion.validate();
      if (completion.prepared) {
        if (pending_->committed) {
          return false;
        }

        if (completion.status != ClipboardDesktopStatus::success) {
          if (pending_->traditional && !pending_->write && completion.status == ClipboardDesktopStatus::denied) {
            auto builder = buildReply();

            builder.reply().append("\x1b]52;");
            builder.reply().append({&pending_->selection, 1});
            builder.reply().append(";\x1b\\");
            builder.commit();
          }

          finish(completion.status == ClipboardDesktopStatus::unsupported ? ClipboardStatus::unsupported : completion.status == ClipboardDesktopStatus::denied ? ClipboardStatus::denied
                                                                                                                                                               : ClipboardStatus::io_error);
          return true;
        }

        pending_->prepared = true;
        pending_->remember = completion.remember;
        return true;
      }

      if (!pending_->committed) {
        return false;
      }

      try {
        completeResult(sender, completion);
      } catch (const std::bad_alloc&) {
        finish(ClipboardStatus::io_error);
      }

      return true;
    }

  private:
    void completeResult(ClipboardRoute sender, const CompleteClipboardDesktop& completion) {
      const auto result = completion.status == ClipboardDesktopStatus::success ? ClipboardStatus::done : completion.status == ClipboardDesktopStatus::denied    ? ClipboardStatus::denied
                                                                                                     : completion.status == ClipboardDesktopStatus::unsupported ? ClipboardStatus::unsupported
                                                                                                                                                                : ClipboardStatus::io_error;
      auto& pending = *pending_;

      if (result != ClipboardStatus::done) {
        finish(result);
        return;
      }

      if (pending.remember && !pending.metadata.name.view().empty() && !pending.metadata.password.view().empty()) {
        grants_.grant(pending.metadata.password.view(), sender, pending.write, false);
      }

      auto builder = buildReply();
      auto& asynchronous_reply = builder.reply();

      if (pending.traditional) {
        if (!pending.write) {
          asynchronous_reply.append("\x1b]52;");
          asynchronous_reply.append({&pending.selection, 1});
          asynchronous_reply.append(";");
          for (const auto& content : completion.contents) {
            if (textMime(content.mime)) {
              clipboardBase64(asynchronous_reply, content.data);
              break;
            }
          }

          asynchronous_reply.append("\x1b\\");
        }
      } else if (pending.write) {
        status(pending.metadata, ClipboardStatus::done, pending.ending, asynchronous_reply);
      } else {
        std::array<ClipboardContentView, 4> contents;
        std::size_t count = 0;
        std::size_t total = 0;

        for (std::size_t index = 0; index < pending.mime_count; ++index) {
          const auto mime = pending.mimes[index].view();

          for (const auto& content : completion.contents) {
            if (content.mime != mime && !(textMime(mime) && textMime(content.mime))) {
              continue;
            }

            if (content.data.size() > maximum_bytes - total) {
              status(pending.metadata, ClipboardStatus::too_large, pending.ending, asynchronous_reply);
              builder.commit();
              pending_.reset();
              return;
            }

            contents[count++] = {mime, content.data};
            total += content.data.size();
            break;
          }
        }

        clipboardReadSuccess(asynchronous_reply, ClipboardPacket{.primary = pending.metadata.primary, .id = pending.metadata.id.view(), .ending = pending.ending}, std::span{contents}.first(count), completion.available, pending.listing);
      }

      builder.commit();
      pending_.reset();
      return;
    }

  public:
    void discard() noexcept {
      if (pending_) {
        cancelPending();
      }

      pending_.reset();
      transaction_.reset();
      grants_.clear();
      Vector<std::uint8_t, Memory>{decoded_.get_allocator()}.swap(decoded_);
      for (auto& reply : asynchronous_replies_) {
        reply.discard();
      }

      reply_count_ = 0;
      reply_head_ = 0;
    }

    void expire(Clock::time_point now) {
      if (pending_ && now >= pending_->deadline) {
        cancelPending();
        finish(ClipboardStatus::denied);
      }
    }

    template <typename Sink>
    bool publish(Sink& sink) {
      while (reply_count_ != 0) {
        auto& reply = asynchronous_replies_[reply_head_];
        if (!reply.publish(sink)) {
          return false;
        }

        reply.clear();
        reply_head_ = (reply_head_ + 1) % asynchronous_replies_.size();
        --reply_count_;
      }

      return true;
    }

    bool hasReply() const noexcept {
      return reply_count_ != 0;
    }

    void reset() {
      if (pending_) {
        cancelPending();
        finish(ClipboardStatus::denied);
      }

      transaction_.reset();
      grants_.clear();
    }

    bool paste(ClipboardRoute route, bool primary, std::span<const std::string_view> available) {
      if (!live(route) || reply_count_ != 0) {
        return false;
      }

      try {
        const auto password = ClipboardGrants::password();
        auto builder = buildReply();
        auto& asynchronous_reply = builder.reply();

        clipboardReadSuccess(asynchronous_reply, ClipboardPacket{.primary = primary, .password = password.view()}, {}, available, true);
        grants_.grant(password.view(), route, false, true);
        builder.commit();
        return true;
      } catch (const std::bad_alloc&) {
        return false;
      }
    }

    struct Cancellation {
      ClipboardRoute route;
      ClipboardTicket ticket;
    };

    std::optional<Cancellation> cancellation() const noexcept {
      return cancellation_;
    }

    void cancelled() noexcept {
      cancellation_.reset();
    }

    std::optional<ClipboardDesktopExecute> execution() const noexcept {
      if (pending_ && pending_->prepared && !pending_->committed) {
        return ClipboardDesktopExecute{pending_->ticket};
      }

      return std::nullopt;
    }

    void committed() noexcept {
      if (pending_) {
        pending_->committed = true;
      }
    }

  private:
    // A pending request; its views lend its own texts and contents, so it stays where it is built.
    struct Pending {
      explicit Pending(Memory& memory)
          : text(AllocatorRef<std::uint8_t, Memory>{memory}),
            transaction(nullptr, AllocationDeleter<ClipboardWrite<Memory>, Memory>{memory}) {
        randomBytes(&nonce, sizeof(nonce));
        if (nonce == 0) {
          nonce = 1;
        }
      }

      Pending(const Pending&) = delete;
      Pending& operator=(const Pending&) = delete;

      // Points the views at the request's own texts and contents; how many contents there are.
      std::size_t prepareViews() noexcept {
        for (std::size_t index = 0; index < mime_count; ++index) {
          mime_views[index] = mimes[index].view();
        }

        std::size_t contents = 0;

        if (transaction) {
          for (const auto& content : transaction->contents()) {
            content_views[contents++] = {content.mime, content.data};
          }
        } else if (traditional && write) {
          content_views[contents++] = {"text/plain", text};
        }

        return contents;
      }

      ClipboardMetadata metadata;
      ClipboardRoute route;
      ClipboardTicket ticket;
      Ending ending = Ending::escape;
      Clock::time_point deadline = Clock::now() + request_timeout;
      std::uint64_t nonce = 0;
      std::array<FixedText<ClipboardMetadata::maximum_mime>, 4> mimes;
      tbc::view<std::array<std::string_view, 4>, tbc::lt::self> mime_views;
      tbc::view<std::array<ClipboardRepresentation, 128>, tbc::lt::self> content_views;
      std::size_t mime_count = 0;
      Vector<std::uint8_t, Memory> text;
      Owned<ClipboardWrite<Memory>, Memory> transaction;
      bool write = false;
      bool listing = false;
      bool prompt = false;
      bool traditional = false;
      bool announced = false;
      bool prepared = false;
      bool committed = false;
      bool remember = false;
      char selection = 'c';
    };

    static bool textMime(std::string_view mime) noexcept {
      return mime == "text/plain" || mime == "text/plain;charset=utf-8" || mime == "UTF8_STRING" || mime == "STRING" || mime == "TEXT";
    }

    bool live(ClipboardRoute route) const noexcept {
      return std::find(routes_.begin(), routes_.begin() + route_count_, route) != routes_.begin() + route_count_;
    }

    template <base64::Padding Rule = base64::Padding::required>
    bool decode(std::string_view encoded) {
      if (encoded.size() > maximum_encoded_bytes) {
        return false;
      }

      decoded_.resize(std::min(maximum_bytes, encoded.size() / 4 * 3 + encoded.size() % 4 * 3 / 4));
      const auto size = base64::decode<Rule>(encoded, decoded_);
      if (!size) {
        return false;
      }

      decoded_.resize(*size);
      return true;
    }

    static void status(const ClipboardMetadata& metadata, ClipboardStatus status, Ending ending, Reply<Memory>& reply) {
      clipboardPacket(reply, ClipboardPacket{.operation = metadata.operation == ClipboardOperation::read ? ClipboardOperation::read : ClipboardOperation::write, .status = status, .id = metadata.id.view(), .ending = ending});
    }

    void abort(ClipboardStatus result, Ending ending, Reply<Memory>& reply) {
      status(transaction_->metadata, result, ending, reply);
      transaction_.reset();
    }

    void cancelPending() noexcept {
      if (pending_->announced) {
        cancellation_ = Cancellation{pending_->route, pending_->ticket};
      }
    }

    void finish(ClipboardStatus result) {
      if (!pending_->traditional) {
        auto builder = buildReply();

        status(pending_->metadata, result, pending_->ending, builder.reply());
        builder.commit();
      }

      pending_.reset();
    }

    // Uses only the grants, so the metadata may live in what this sequence holds.
    static std::optional<ClipboardRoute> authorizedRoute(ClipboardGrants& grants, const ClipboardMetadata& metadata, bool write, bool exempt) {
      if (!exempt && !metadata.name.view().empty()) {
        if (const auto granted = grants.use(metadata.password.view(), write)) {
          return granted;
        }
      }

      return std::nullopt;
    }

    void read(const ClipboardMetadata& metadata, std::string_view data, Ending ending, const Policy& policy, Reply<Memory>& reply) {
      if (!decode(data)) {
        return;
      }

      std::string_view decoded{reinterpret_cast<const char*>(decoded_.data()), decoded_.size()};

      try {
        validateUtf8(decoded);
      } catch (const EncodingError&) {
        return;
      }

      if (policy.clipboard_read == Access::deny || !preferred_) {
        status(metadata, ClipboardStatus::denied, ending, reply);
        return;
      }

      if (pending_ || cancellation_ || reply_count_ != 0) {
        status(metadata, ClipboardStatus::busy, ending, reply);
        return;
      }

      pending_ = makeOwned<Pending>(memory_, memory_);
      auto& request = *pending_;

      request.metadata = metadata;
      request.ending = ending;
      while (const auto mime = ClipboardWrite<Memory>::token(decoded)) {
        if (*mime == ".") {
          request.listing = true;
        } else if (request.mime_count < request.mimes.size() && mime->size() <= ClipboardMetadata::maximum_mime && !mime->contains('\0')) {
          request.mimes[request.mime_count++].assign(*mime);
        }
      }

      const auto granted = authorizedRoute(grants_, metadata, false, request.mime_count == 0);

      request.route = granted.value_or(*preferred_);
      request.prompt = policy.clipboard_read == Access::ask && request.mime_count != 0 && !granted;
    }

    void commit(Ending ending, const Policy& policy, Reply<Memory>& reply) {
      const auto result = transaction_->commit();
      if (result != ClipboardStatus::ok) {
        abort(result, ending, reply);
        return;
      }

      if (policy.clipboard_write == Access::deny || !preferred_) {
        abort(ClipboardStatus::denied, ending, reply);
        return;
      }

      if (pending_ || cancellation_ || reply_count_ != 0) {
        abort(ClipboardStatus::busy, ending, reply);
        return;
      }

      pending_ = makeOwned<Pending>(memory_, memory_);
      auto& request = *pending_;

      request.metadata = transaction_->metadata;
      request.write = true;
      request.ending = ending;
      const auto granted = authorizedRoute(grants_, request.metadata, true, false);

      request.route = granted.value_or(*preferred_);
      request.prompt = policy.clipboard_write == Access::ask && !granted;
      request.transaction = std::move(transaction_);
    }

    class ReplyBuilder {
    public:
      explicit ReplyBuilder(Clipboard& owner)
          : owner_(owner),
            reply_(owner.asynchronous_replies_[(owner.reply_head_ + owner.reply_count_) % owner.asynchronous_replies_.size()]) {
        if (owner.reply_count_ == owner.asynchronous_replies_.size()) {
          throw std::logic_error{"Clipboard completion capacity invariant failed"};
        }
      }

      ~ReplyBuilder() {
        if (!committed_) {
          reply_.clear();
        }
      }

      ReplyBuilder(const ReplyBuilder&) = delete;
      ReplyBuilder& operator=(const ReplyBuilder&) = delete;

      Reply<Memory>& reply() noexcept {
        return reply_;
      }

      void commit() {
        reply_.seal();
        ++owner_.reply_count_;
        committed_ = true;
      }

    private:
      Clipboard& owner_;
      Reply<Memory>& reply_;
      bool committed_ = false;
    };

    ReplyBuilder buildReply() {
      return ReplyBuilder{*this};
    }

    Memory& memory_;
    Vector<std::uint8_t, Memory> decoded_;
    Owned<ClipboardWrite<Memory>, Memory> transaction_;
    Owned<Pending, Memory> pending_;
    std::array<Reply<Memory>, 2> asynchronous_replies_;
    std::size_t reply_head_ = 0;
    std::size_t reply_count_ = 0;
    ClipboardGrants grants_;
    std::array<ClipboardRoute, ClipboardGrants::capacity> routes_;
    std::size_t route_count_ = 0;
    std::optional<ClipboardRoute> preferred_;
    std::optional<Cancellation> cancellation_;
  };

}
