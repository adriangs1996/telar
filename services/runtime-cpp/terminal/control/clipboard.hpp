#pragma once

#include "tbc/view.hpp"

#include "telar_platform/random_bytes.hpp"
#include "clipboard_grants.hpp"
#include "clipboard_response.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/terminal/control/policy.hpp"
#include <chrono>

namespace telar::runtime::control {

template <Allocator Memory>
class Clipboard {
public:
  using Clock = std::chrono::steady_clock;
  static constexpr std::size_t maximum_bytes = clipboard_content_limit;
  static constexpr std::size_t maximum_encoded_bytes = (maximum_bytes + 2) / 3 * 4;
  static constexpr auto request_timeout = std::chrono::seconds{30};

  explicit Clipboard(Memory &memory)
      : memory_(memory), decoded_(AllocatorRef<std::uint8_t, Memory>{memory}),
        transaction_(nullptr, AllocationDeleter<ClipboardWrite<Memory>, Memory>{memory}),
        pending_(nullptr, AllocationDeleter<Pending, Memory>{memory}), asynchronous_replies_{Reply<Memory>{memory}, Reply<Memory>{memory}} {}

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

  void traditional(std::string_view payload, const Policy &policy) {
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
      auto &request = *pending_;
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
    } catch (const std::bad_alloc &) {
      pending_.reset();
    }
  }

  void kitty(std::string_view payload, Ending ending, const Policy &policy, Reply<Memory> &reply) {
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
    } catch (const std::bad_alloc &) {
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
    auto &pending = *pending_;
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

  bool complete(ClipboardRoute sender, const CompleteClipboardDesktop &completion) {
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
        finish(completion.status == ClipboardDesktopStatus::unsupported ? ClipboardStatus::unsupported : completion.status == ClipboardDesktopStatus::denied ? ClipboardStatus::denied : ClipboardStatus::io_error);
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
    } catch (const std::bad_alloc &) {
      finish(ClipboardStatus::io_error);
    }
    return true;
  }

private:
  void completeResult(ClipboardRoute sender, const CompleteClipboardDesktop &completion) {
    const auto result = completion.status == ClipboardDesktopStatus::success ? ClipboardStatus::done : completion.status == ClipboardDesktopStatus::denied ? ClipboardStatus::denied : completion.status == ClipboardDesktopStatus::unsupported ? ClipboardStatus::unsupported : ClipboardStatus::io_error;
    auto &pending = *pending_;
    if (result != ClipboardStatus::done) {
      finish(result);
      return;
    }
    if (pending.remember && !pending.metadata.name.view().empty() && !pending.metadata.password.view().empty()) {
      grants_.grant(pending.metadata.password.view(), sender, pending.write, false);
    }
    auto builder = buildReply();
    auto &asynchronous_reply = builder.reply();
    if (pending.traditional) {
      if (!pending.write) {
        asynchronous_reply.append("\x1b]52;");
        asynchronous_reply.append({&pending.selection, 1});
        asynchronous_reply.append(";");
        for (const auto &content : completion.contents) {
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
        for (const auto &content : completion.contents) {
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
    for (auto &reply : asynchronous_replies_) {
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
  bool publish(Sink &sink) {
    while (reply_count_ != 0) {
      auto &reply = asynchronous_replies_[reply_head_];
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
      auto &asynchronous_reply = builder.reply();
      clipboardReadSuccess(asynchronous_reply, ClipboardPacket{.primary = primary, .password = password.view()}, {}, available, true);
      grants_.grant(password.view(), route, false, true);
      builder.commit();
      return true;
    } catch (const std::bad_alloc &) {
      return false;
    }
  }

  struct Cancellation {
    ClipboardRoute route;
    ClipboardTicket ticket;
  };

  std::optional<Cancellation> cancellation() const noexcept { return cancellation_; }
  void cancelled() noexcept { cancellation_.reset(); }

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
    explicit Pending(Memory &memory)
        : text(AllocatorRef<std::uint8_t, Memory>{memory}), transaction(nullptr, AllocationDeleter<ClipboardWrite<Memory>, Memory>{memory}) {
      randomBytes(&nonce, sizeof(nonce));
      if (nonce == 0) {
        nonce = 1;
      }
    }

    Pending(const Pending &) = delete;
    Pending &operator=(const Pending &) = delete;

    // Points the views at the request's own texts and contents; how many contents there are.
    std::size_t prepareViews() noexcept {
      for (std::size_t index = 0; index < mime_count; ++index) {
        mime_views[index] = mimes[index].view();
      }
      std::size_t contents = 0;
      if (transaction) {
        for (const auto &content : transaction->contents()) {
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

  static void status(const ClipboardMetadata &metadata, ClipboardStatus status, Ending ending, Reply<Memory> &reply) {
    clipboardPacket(reply, ClipboardPacket{.operation = metadata.operation == ClipboardOperation::read ? ClipboardOperation::read : ClipboardOperation::write, .status = status, .id = metadata.id.view(), .ending = ending});
  }

  void abort(ClipboardStatus result, Ending ending, Reply<Memory> &reply) {
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

  std::optional<ClipboardRoute> authorizedRoute(const ClipboardMetadata &metadata, bool write, bool exempt) {
    if (!exempt && !metadata.name.view().empty()) {
      if (const auto granted = grants_.use(metadata.password.view(), write)) {
        return granted;
      }
    }
    return std::nullopt;
  }

  void read(const ClipboardMetadata &metadata, std::string_view data, Ending ending, const Policy &policy, Reply<Memory> &reply) {
    if (!decode(data)) {
      return;
    }
    std::string_view decoded{reinterpret_cast<const char *>(decoded_.data()), decoded_.size()};
    try {
      validateUtf8(decoded);
    } catch (const EncodingError &) {
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
    auto &request = *pending_;
    request.metadata = metadata;
    request.ending = ending;
    while (const auto mime = ClipboardWrite<Memory>::token(decoded)) {
      if (*mime == ".") {
        request.listing = true;
      } else if (request.mime_count < request.mimes.size() && mime->size() <= ClipboardMetadata::maximum_mime && !mime->contains('\0')) {
        request.mimes[request.mime_count++].assign(*mime);
      }
    }
    const auto granted = authorizedRoute(metadata, false, request.mime_count == 0);
    request.route = granted.value_or(*preferred_);
    request.prompt = policy.clipboard_read == Access::ask && request.mime_count != 0 && !granted;
  }

  void commit(Ending ending, const Policy &policy, Reply<Memory> &reply) {
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
    auto &request = *pending_;
    request.metadata = transaction_->metadata;
    request.write = true;
    request.ending = ending;
    const auto granted = authorizedRoute(request.metadata, true, false);
    request.route = granted.value_or(*preferred_);
    request.prompt = policy.clipboard_write == Access::ask && !granted;
    request.transaction = std::move(transaction_);
  }

  class ReplyBuilder {
  public:
    explicit ReplyBuilder(Clipboard &owner) : owner_(owner), reply_(owner.asynchronous_replies_[(owner.reply_head_ + owner.reply_count_) % owner.asynchronous_replies_.size()]) {
      if (owner.reply_count_ == owner.asynchronous_replies_.size()) {
        throw std::logic_error{"Clipboard completion capacity invariant failed"};
      }
    }

    ~ReplyBuilder() {
      if (!committed_) {
        reply_.clear();
      }
    }

    ReplyBuilder(const ReplyBuilder &) = delete;
    ReplyBuilder &operator=(const ReplyBuilder &) = delete;

    Reply<Memory> &reply() noexcept { return reply_; }

    void commit() {
      reply_.seal();
      ++owner_.reply_count_;
      committed_ = true;
    }

  private:
    Clipboard &owner_;
    Reply<Memory> &reply_;
    bool committed_ = false;
  };

  ReplyBuilder buildReply() { return ReplyBuilder{*this}; }

  Memory &memory_;
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
