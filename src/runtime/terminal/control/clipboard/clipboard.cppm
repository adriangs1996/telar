module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control.clipboard;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text;
import telar.config.runtime;
import telar.platform.primitives;
import telar.wire.clipboard;
import telar.runtime.terminal.control;
import telar.base.ds;

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

  std::string_view clipboardStatusName(ClipboardStatus status) noexcept;

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

    static ds::Option<ClipboardMetadata> parse(std::string_view input);

  private:
    template <std::size_t Capacity>
    static MetadataValue decode(std::string_view encoded, FixedText<Capacity>& destination);
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

    void grant(std::string_view password, ClipboardRoute route, bool write, bool once);

    ds::Option<ClipboardRoute> use(std::string_view password, bool write);

    void retain(std::span<const ClipboardRoute> routes) noexcept;

    void clear() noexcept;

    static FixedText<password_length> password();

  private:
    struct Entry {
      FixedText<ClipboardMetadata::maximum_password> password;
      ClipboardRoute route;
      bool read = false;
      bool write = false;
      bool once = false;
    };

    ds::Array<Entry, capacity> entries_;
    std::size_t count_ = 0;
  };

  struct ClipboardContentView {
    std::string_view mime;
    std::span<const std::uint8_t> data;
  };

  class ClipboardWrite {
  public:
    static constexpr std::size_t maximum_mimes = 64;
    static constexpr std::size_t maximum_aliases = 64;

    // Copies the metadata; it keeps only its allocator, region `a`.
    explicit ClipboardWrite(tbc::mut_a<ConcurrentMemory> memory, const ClipboardMetadata& metadata, std::size_t limit);

    // Its contents view its own spool and names, so it stays where it is built.
    ClipboardWrite(const ClipboardWrite&) = delete;
    ClipboardWrite& operator=(const ClipboardWrite&) = delete;

    ClipboardStatus data(std::string_view mime, std::string_view encoded);

    ClipboardStatus alias(std::string_view mime, std::string_view encoded);

    ClipboardStatus commit();

    std::span<const ClipboardContentView> contents() const noexcept;

    static ds::Option<std::string_view> token(std::string_view& remaining) noexcept;

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

    ClipboardStatus finishCurrent() noexcept;

    void reserve(std::size_t count);

    static constexpr std::size_t initial_capacity = 4096;
    tbc::mut_a<ConcurrentMemory> memory_;
    tbc::val_a<ds::Vec<std::uint8_t, ConcurrentMemory>> spool_;
    std::size_t limit_;
    ds::Array<Entry, maximum_mimes> entries_;
    ds::Array<Alias, maximum_aliases> aliases_;
    tbc::val_self<ds::Array<ClipboardContentView, maximum_mimes + maximum_aliases>> contents_;
    std::size_t entry_count_ = 0;
    std::size_t alias_count_ = 0;
    std::size_t content_count_ = 0;
    ds::Option<std::size_t> current_;
    ds::Array<char, 4> group_;
    std::size_t group_size_ = 0;
  };

  inline constexpr std::size_t clipboard_chunk_bytes = 4096;

  struct ClipboardPacket {
    ClipboardOperation operation = ClipboardOperation::read;
    ClipboardStatus status = ClipboardStatus::ok;
    bool primary = false;
    std::string_view id{};
    ds::Option<std::string_view> mime{};
    ds::Option<std::string_view> password{};
    std::span<const std::uint8_t> payload{};
    Ending ending = Ending::escape;
  };

  void clipboardBase64(Reply<ConcurrentMemory>& reply, std::span<const std::uint8_t> input);

  void clipboardBase64(Reply<ConcurrentMemory>& reply, std::string_view input);

  void clipboardPacket(Reply<ConcurrentMemory>& reply, const ClipboardPacket& packet);

  void clipboardReadSuccess(Reply<ConcurrentMemory>& reply, const ClipboardPacket& request, std::span<const ClipboardContentView> contents, std::span<const std::string_view> available, bool listing);

  class Clipboard {
  public:
    using Clock = std::chrono::steady_clock;
    static constexpr std::size_t maximum_bytes = clipboard_content_limit;
    static constexpr std::size_t maximum_encoded_bytes = (maximum_bytes + 2) / 3 * 4;
    static constexpr auto request_timeout = std::chrono::seconds{30};

    explicit Clipboard(ConcurrentMemory& memory);

    void routes(std::span<const ClipboardRoute> routes, ds::Option<ClipboardRoute> preferred);

    void traditional(std::string_view payload, const Policy& policy);

    void kitty(std::string_view payload, Ending ending, const Policy& policy, Reply<ConcurrentMemory>& reply);

    // All views are synchronous. Connection::send must copy/encode them before
    // returning; only the owning Pending crosses event-loop turns.
    ds::Option<ClipboardDesktopRequest> request(std::uint64_t pane, std::uint64_t generation);

    ds::Option<ClipboardRoute> route() const noexcept;

    void announced() noexcept;

    bool complete(ClipboardRoute sender, const CompleteClipboardDesktop& completion);

  private:
    void completeResult(ClipboardRoute sender, const CompleteClipboardDesktop& completion);

  public:
    void discard() noexcept;

    void expire(Clock::time_point now);

    // Generic over the caller's response sink, so it stays here.
    template <typename Sink>
    TBC_GENERIC bool publish(Sink& sink) {
      while (replies_.count != 0) {
        auto& reply = replies_.replies.atMut(replies_.head);
        if (!reply.publish(sink)) {
          return false;
        }

        reply.clear();
        replies_.head = (replies_.head + 1) % replies_.replies.size();
        --replies_.count;
      }

      return true;
    }

    bool hasReply() const noexcept;

    void reset();

    bool paste(ClipboardRoute route, bool primary, std::span<const std::string_view> available);

    struct Cancellation {
      ClipboardRoute route;
      ClipboardTicket ticket;
    };

    ds::Option<Cancellation> cancellation() const noexcept;

    void cancelled() noexcept;

    ds::Option<ClipboardDesktopExecute> execution() const noexcept;

    void committed() noexcept;

  private:
    // A pending request; its views lend its own texts and contents, so it stays where it is built.
    struct Pending {
      explicit Pending(ConcurrentMemory& memory);

      Pending(const Pending&) = delete;
      Pending& operator=(const Pending&) = delete;

      // Points the views at the request's own texts and contents; how many contents there are.
      std::size_t prepareViews() noexcept;

      ClipboardMetadata metadata;
      ClipboardRoute route;
      ClipboardTicket ticket;
      Ending ending = Ending::escape;
      Clock::time_point deadline = Clock::now() + request_timeout;
      std::uint64_t nonce = 0;
      ds::Array<FixedText<ClipboardMetadata::maximum_mime>, 4> mimes;
      tbc::val_self<ds::Array<std::string_view, 4>> mime_views;
      tbc::val_self<ds::Array<ClipboardRepresentation, 128>> content_views;
      std::size_t mime_count = 0;
      ds::Vec<std::uint8_t, ConcurrentMemory> text;
      ds::Box<ClipboardWrite, ConcurrentMemory> transaction;
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

    static bool textMime(std::string_view mime) noexcept;

    bool live(ClipboardRoute route) const noexcept;

    template <base64::Padding Rule = base64::Padding::required>
    bool decode(std::string_view encoded);

    static void status(const ClipboardMetadata& metadata, ClipboardStatus status, Ending ending, Reply<ConcurrentMemory>& reply);

    void abort(ClipboardStatus result, Ending ending, Reply<ConcurrentMemory>& reply);

    void cancelPending() noexcept;

    void finish(ClipboardStatus result);

    // Uses only the grants, so the metadata may live in what this sequence holds.
    static ds::Option<ClipboardRoute> authorizedRoute(ClipboardGrants& grants, const ClipboardMetadata& metadata, bool write, bool exempt);

    void read(const ClipboardMetadata& metadata, std::string_view data, Ending ending, const Policy& policy, Reply<ConcurrentMemory>& reply);

    void commit(Ending ending, const Policy& policy, Reply<ConcurrentMemory>& reply);

    // The replies completions queue, oldest first: building one borrows these alone, so what the
    // clipboard is completing stays borrowed meanwhile.
    struct ReplyRing {
      ds::Array<Reply<ConcurrentMemory>, 2> replies;
      std::size_t head = 0;
      std::size_t count = 0;
    };

    class ReplyBuilder {
    public:
      explicit ReplyBuilder(ReplyRing& ring);

      ~ReplyBuilder();

      ReplyBuilder(const ReplyBuilder&) = delete;
      ReplyBuilder& operator=(const ReplyBuilder&) = delete;

      Reply<ConcurrentMemory>& reply() noexcept;

      void commit();

    private:
      ReplyRing& ring_;
      Reply<ConcurrentMemory>& reply_;
      bool committed_ = false;
    };

    ConcurrentMemory& memory_;
    ds::Vec<std::uint8_t, ConcurrentMemory> decoded_;
    ds::Box<ClipboardWrite, ConcurrentMemory> transaction_;
    ds::Box<Pending, ConcurrentMemory> pending_;
    ReplyRing replies_;
    ClipboardGrants grants_;
    ds::Array<ClipboardRoute, ClipboardGrants::capacity> routes_;
    std::size_t route_count_ = 0;
    ds::Option<ClipboardRoute> preferred_;
    ds::Option<Cancellation> cancellation_;
  };

}
