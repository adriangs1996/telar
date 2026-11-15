module;
#include "tbc/annotations.hpp"

export module telar.runtime.transport.connection;

import std;
import telar.sys.posix;

import telar.client;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.vocabulary;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.platform.error;
import telar.platform.net;

// Interface: transport/client_handshake.cppm
export {
  namespace telar::runtime {

    class ClientHandshake {
    public:
      enum class Stage {
        prefix,
        hello,
        reply,
        accepted,
        rejected,
      };

      explicit ClientHandshake(FileDescriptor descriptor, bool capacity_refused);

      void read();

      void write();

      int descriptor() const noexcept;

      FileDescriptor takeDescriptor() noexcept;

      Stage stage() const noexcept;

      bool reservesClient() const noexcept;

      bool expired(std::chrono::steady_clock::time_point now) const noexcept;

    private:
      void negotiate();

      template <typename Message>
      void reply(const Message& message);

      FileDescriptor descriptor_;
      std::array<Byte, frame_prefix_size + HandshakeCodec::max_message_size> bytes_;
      std::size_t used_bytes_ = 0;
      std::size_t expected_bytes_ = frame_prefix_size;
      std::chrono::steady_clock::time_point started_at_ = std::chrono::steady_clock::now();
      Stage stage_ = Stage::prefix;
      bool capacity_refused_;
      bool accepted_ = false;
    };

  }
}

// Interface: transport/deferred_responses.cppm
export {
  namespace telar::runtime {

    template <typename Request>
    concept DeferredRequest = std::same_as<Request, ReadPane> || std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot> || std::same_as<Request, QueryLimits>;

    using DeferredResponse = std::variant<ReadPane, RequestTabSnapshot, RequestWorkspaceSnapshot, QueryLimits>;

    struct RejectDeferredResponse {
      // Generic over the caller's consumer, so it stays a template here.
      TBC_GENERIC inline void operator()(const DeferredResponse&, auto&&) const {
        throw std::logic_error{"A deferred response requires an encoder"};
      }
    };

    template <typename Encoder>
    concept DeferredResponseEncoder = requires(Encoder& encoder, const DeferredResponse& response) {
      encoder(response, [](const auto&) {});
    };

    template <Allocator Memory>
    class DeferredResponses {
    public:
      explicit DeferredResponses(Memory& memory);

      void append(std::size_t offset, const DeferredResponse& response);

      bool precedes(std::size_t offset) const noexcept;

      std::size_t offset() const noexcept;

      const DeferredResponse& response() const noexcept;

      bool empty() const noexcept;

      void clear() noexcept;

      void resolved(std::size_t size) noexcept;

      // Offsets mark admission boundaries in the encoded byte queue. Removing a
      // higher-priority frame collapses any boundaries inside that byte range.
      void eraseBytes(std::size_t offset, std::size_t count) noexcept;

    private:
      struct Entry {
        std::size_t offset;
        DeferredResponse response;
      };

      Vector<Entry, Memory> entries_;
    };

    extern template class DeferredResponses<SystemAllocator>;
    extern template class DeferredResponses<Memory>;
    extern template class DeferredResponses<ConcurrentMemory>;
    extern template class DeferredResponses<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;
    extern template class DeferredResponses<BudgetAllocator<SystemAllocator>>;

  }
}

// Interface: transport/delivery_lane.cppm
export {
  namespace telar::runtime {

    enum class DeliveryLane : std::uint8_t {
      stopping,
      management,
      resync,
      clipboard,
      layout,
      proxy,
      // Ahead of cells: a client deciding who gets a key must not see a frame before the state
      // of the shell that printed it.
      shell,
      // Ahead of cells too: a frame's rows are numbered as the scrollback that precedes it says.
      scrollback,
      cells,
      agents,
      metrics,
      workspaces,
      panes,
      cwd,
      foreground,
      title,
      progress,
      git,
      blocks,
      exit,
      graphics,
      // Behind everything else a pane shows: a document is large and drawn once.
      document,
      observation,
      count,
    };

    constexpr DeliveryLane deliveryLane(ServerTag tag) {
      switch (tag) {
      case ServerTag::runtime_stopping:
        return DeliveryLane::stopping;
      case ServerTag::resync_required:
        return DeliveryLane::resync;
      case ServerTag::pane_clipboard:
        return DeliveryLane::clipboard;
      case ServerTag::client_layout_snapshot:
        return DeliveryLane::layout;
      case ServerTag::proxy_status:
        return DeliveryLane::proxy;
      case ServerTag::pane_frame:
        return DeliveryLane::cells;
      case ServerTag::agent_snapshot:
        return DeliveryLane::agents;
      case ServerTag::system_metrics:
        return DeliveryLane::metrics;
      case ServerTag::workspace_list:
        return DeliveryLane::workspaces;
      case ServerTag::pane_list:
        return DeliveryLane::panes;
      case ServerTag::pane_cwd:
        return DeliveryLane::cwd;
      case ServerTag::pane_foreground:
        return DeliveryLane::foreground;
      case ServerTag::pane_title:
        return DeliveryLane::title;
      case ServerTag::pane_progress:
        return DeliveryLane::progress;
      case ServerTag::pane_shell:
        return DeliveryLane::shell;
      case ServerTag::pane_scrollback:
        return DeliveryLane::scrollback;
      case ServerTag::pane_document:
        return DeliveryLane::document;
      case ServerTag::pane_git:
        return DeliveryLane::git;
      case ServerTag::pane_blocks:
        return DeliveryLane::blocks;
      case ServerTag::pane_exited:
        return DeliveryLane::exit;
      case ServerTag::history_results:
        return DeliveryLane::observation;
      case ServerTag::graphics_snapshot:
      case ServerTag::graphics_image:
      case ServerTag::graphics_image_chunk:
      case ServerTag::graphics_placement:
      case ServerTag::graphics_delete_image:
      case ServerTag::graphics_delete_placement:
      case ServerTag::graphics_shared_image:
        return DeliveryLane::graphics;
      case ServerTag::pane_opened:
      case ServerTag::request_failed:
      case ServerTag::tab_snapshot:
      case ServerTag::workspace_snapshot:
      case ServerTag::tab_created:
      case ServerTag::tab_renamed:
      case ServerTag::tab_closed:
      case ServerTag::tab_moved:
      case ServerTag::notification:
      case ServerTag::notification_shown:
      case ServerTag::agent_sound:
      case ServerTag::pane_text:
      case ServerTag::request_completed:
      case ServerTag::pane_matches:
      case ServerTag::pane_rows:
      case ServerTag::history_pruned:
      case ServerTag::history_output:
      case ServerTag::history_stats_result:
      case ServerTag::pane_focus_command:
      case ServerTag::pane_focus_result:
      case ServerTag::command_suggestion:
      case ServerTag::client_list:
      case ServerTag::client_command:
      case ServerTag::client_command_result:
      case ServerTag::editor_opened:
      case ServerTag::path_results:
      case ServerTag::completion_words:
      case ServerTag::command_spec:
      case ServerTag::worktree_registered:
      case ServerTag::limit_list:
      case ServerTag::execution_reply:
      case ServerTag::clipboard_desktop_request:
      case ServerTag::clipboard_desktop_execute:
      case ServerTag::clipboard_desktop_cancel:
      case ServerTag::runtime_clipboard_chunk:
        return DeliveryLane::management;
      }

      throw EncodingError{"Unknown outgoing message tag"};
    }

    constexpr bool responseLane(DeliveryLane lane) noexcept {
      return lane == DeliveryLane::management || lane == DeliveryLane::observation;
    }

  }
}

// Interface: transport/outgoing_frames.cppm
export {
  namespace telar::runtime {

    class ResponseQueueFull : public std::exception {
    public:
      const char* what() const noexcept override;
    };

    template <Allocator Memory>
    class OutgoingFrames {
    public:
      static constexpr std::size_t response_capacity = 128;

      explicit OutgoingFrames(Memory& memory);

      void reserve(std::size_t capacity);

      // Generic over the protocol's messages, an open set, so it stays a template here.
      template <typename Message>
      TBC_GENERIC inline void append(const Message& message) {
        static_assert(MessageSchema<Message>::direction == Direction::server);
        const auto lane = deliveryLane(MessageSchema<Message>::tag);

        requireCapacity(lane);
        const auto size = Codec::encodedSize(message);
        const auto previous_size = bytes_.size();

        try {
          auto frame = bytes_.appendUninitialized(frame_prefix_size + size);

          u32::encode(static_cast<std::uint32_t>(size), frame);
          Codec::encode(message, frame);
        } catch (...) {
          bytes_.truncate(previous_size);
          throw;
        }

        inserted(lane);
      }

      void appendPayload(std::span<const Byte> payload);

      // Appends a fixed-size confirmation whose fields are known only later, and returns where its
      // payload starts. Appending more frames may relocate storage but keeps the offset; nothing may be
      // written out until the confirmation is completed. Generic over the protocol's messages, so it stays
      // a template here.
      template <typename Message>
      TBC_GENERIC inline std::size_t reserve(const Message& message) {
        static_assert(MessageSchema<Message>::fixed_size);
        const auto offset = bytes_.size() + frame_prefix_size;

        append(message);
        return offset;
      }

      // Re-encodes a reserved confirmation in place. Generic over the protocol's messages, so it stays a
      // template here.
      template <typename Message>
      TBC_GENERIC inline void complete(std::size_t offset, const Message& message) {
        std::array<Byte, MessageSchema<Message>::payload_size> payload;

        Codec::encode(message, payload);
        bytes_.overwrite(offset, payload);
      }

      // Generic over the deferred requests, so it stays a template here.
      template <DeferredRequest Request>
      TBC_GENERIC inline void defer(const Request& request) {
        requireCapacity(DeliveryLane::management);
        deferred_.append(bytes_.size(), request);
        inserted(DeliveryLane::management);
      }

      // Generic over the caller's encoder, so it stays a template here.
      template <DeferredResponseEncoder Encoder = RejectDeferredResponse>
      TBC_GENERIC inline std::span<const Byte> prepare(std::size_t limit, Encoder&& encode = {}) {
        if (empty() || limit == 0) {
          return {};
        }

        if (active_remaining_ != 0) {
          prepared_size_ = std::min(active_remaining_, limit);
          return bytes_.readable().subspan(active_offset_, prepared_size_);
        }

        const auto lane = static_cast<DeliveryLane>(std::countr_zero(pending_lanes_));
        auto offset = std::size_t{0};

        while (offset < bytes_.size() && inspect(offset).lane != lane) {
          offset += inspect(offset).size;
        }

        if (lane == DeliveryLane::management && deferred_.precedes(offset)) {
          offset = deferred_.offset();
          resolve(encode);
        }

        const auto frame = inspect(offset);

        start(offset, frame);
        auto end = offset + frame.size;

        while (end < bytes_.size() && end - offset < limit) {
          if (lane == DeliveryLane::management && deferred_.precedes(end)) {
            break;
          }

          const auto next = inspect(end);
          if (next.lane != lane) {
            break;
          }

          end += next.size;
        }

        prepared_size_ = std::min(end - offset, limit);
        return bytes_.readable().subspan(offset, prepared_size_);
      }

      void consume(std::size_t count) noexcept;

      void clear() noexcept;

      void recordDrop() noexcept;

      bool active() const noexcept;

      DeliveryLane nextLane() const noexcept;

      bool empty() const noexcept;

      std::size_t size() const noexcept;

      std::size_t responseDepth() const noexcept;

      std::size_t responseHighWater() const noexcept;

      std::uint64_t dropped() const noexcept;

    private:
      // Generic over the caller's encoder, so it stays a template here.
      template <DeferredResponseEncoder Encoder>
      TBC_GENERIC inline void resolve(Encoder& encode) {
        const auto offset = deferred_.offset();
        std::size_t resolved_size = 0;

        encode(deferred_.response(), [&](const auto& message) {
          using Message = std::remove_cvref_t<decltype(message)>;
          static_assert(deliveryLane(MessageSchema<Message>::tag) == DeliveryLane::management);

          if (resolved_size != 0) {
            throw std::logic_error{"A deferred response must produce exactly one frame"};
          }

          const auto size = Codec::encodedSize(message);
          auto frame = bytes_.insertUninitialized(offset, frame_prefix_size + size);

          try {
            u32::encode(static_cast<std::uint32_t>(size), frame);
            Codec::encode(message, frame);
          } catch (...) {
            bytes_.erase(offset, frame_prefix_size + size);
            throw;
          }

          resolved_size = frame_prefix_size + size;
        });

        if (resolved_size == 0) {
          throw std::logic_error{"A deferred response must produce exactly one frame"};
        }

        deferred_.resolved(resolved_size);
      }

      struct Frame {
        std::size_t size;
        DeliveryLane lane;
      };

      Frame inspect(std::size_t offset) const noexcept;

      void requireCapacity(DeliveryLane lane) const;

      void inserted(DeliveryLane lane) noexcept;

      void start(std::size_t offset, Frame frame) noexcept;

      static constexpr std::size_t byte_limit = 2 * (max_payload_size + frame_prefix_size);
      ByteQueue<Memory> bytes_;
      DeferredResponses<Memory> deferred_;
      std::array<std::size_t, static_cast<std::size_t>(DeliveryLane::count)> lane_counts_{};
      std::uint32_t pending_lanes_ = 0;
      std::size_t response_depth_ = 0;
      std::size_t high_water_ = 0;
      std::uint64_t dropped_ = 0;
      std::size_t active_offset_ = 0;
      std::size_t active_remaining_ = 0;
      std::size_t prepared_size_ = 0;
    };

    extern template class OutgoingFrames<SystemAllocator>;
    extern template class OutgoingFrames<Memory>;
    extern template class OutgoingFrames<ConcurrentMemory>;
    extern template class OutgoingFrames<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;
    extern template class OutgoingFrames<BudgetAllocator<SystemAllocator>>;

  }
}

// Interface: transport/connection.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class Connection {
    public:
      explicit Connection(Memory& memory, FileDescriptor descriptor);

      // Not inlined: its 64 KiB buffer would join the frame of every caller for as long as that caller
      // runs, and after a pane's fork() each stack page the runtime writes again costs a page fault.
      [[gnu::noinline]] bool read();

      // A client's buffered frames and decode storage, which the runtime takes out of the connection while
      // the requests they carry change any client, this one included, as Rust's `mem::take` would.
      struct Frames {
        explicit Frames(Memory& memory);

        ByteQueue<Memory> input;
        Vector<Byte, Memory> decode;
      };

      // Lends the connection's frames, or takes them back: the same exchange both ways.
      void exchange(Frames& frames) noexcept;

      // Hands each complete frame to a visitor while the client is ready for more, at most one batch;
      // whether a complete frame remains. Generic over the caller's predicate and visitor, so it stays a
      // template here.
      template <typename Ready, typename Visitor>
      TBC_GENERIC inline static bool dispatch(Frames& frames, Ready&& ready, Visitor&& visitor) {
        constexpr unsigned messages_per_batch = 64;

        for (unsigned index = 0; index < messages_per_batch; ++index) {
          if (!ready()) {
            return frames.input.size() >= frame_prefix_size;
          }

          auto bytes = frames.input.readable();
          if (bytes.size() < frame_prefix_size) {
            return false;
          }

          const auto length = u32::decode(bytes);
          if (length == 0 || length > max_payload_size) {
            throw EncodingError{"Invalid transport frame size"};
          }

          if (length > bytes.size()) {
            return false;
          }

          DecodeStorage storage{frames.decode};

          visitor(bytes.first(length), storage);
          frames.input.consume(frame_prefix_size + length);
        }

        return frames.input.size() >= frame_prefix_size;
      }

      // Generic over the caller's encoder, so it stays a template here.
      template <DeferredResponseEncoder Encoder = RejectDeferredResponse>
      TBC_GENERIC inline void write(Encoder&& encode = {}) {
        constexpr std::size_t write_batch_size = 256 * 1024;
        const auto bytes = output_.prepare(write_batch_size, std::forward<Encoder>(encode));
        if (bytes.empty()) {
          return;
        }

        const auto count = ::write(descriptor_.get(), bytes.data(), bytes.size());
        if (count > 0) {
          output_.consume(static_cast<std::size_t>(count));
          return;
        }

        if (count < 0 && socketWouldBlock(sys::lastError())) {
          return;
        }

        throw SystemError{"write runtime client"};
      }

      // Generic over the protocol's messages, so it stays a template here.
      template <typename Message>
      TBC_GENERIC inline void send(const Message& message) {
        output_.append(message);
      }

      // Generic over the deferred requests, so it stays a template here.
      template <DeferredRequest Request>
      TBC_GENERIC inline void defer(const Request& request) {
        output_.defer(request);
      }

      // Generic over the protocol's messages, so it stays a template here.
      template <typename Message>
      TBC_GENERIC inline bool trySend(const Message& message) {
        try {
          output_.append(message);
          return true;
        } catch (const ResponseQueueFull&) {
          output_.recordDrop();
        } catch (const std::bad_alloc&) {
          output_.recordDrop();
        }

        return false;
      }

      // A confirmation reserved now and completed by its offset once its fields are known. Generic over the
      // protocol's messages, so it stays a template here.
      template <typename Message>
      TBC_GENERIC inline std::size_t reserve(const Message& message) {
        return output_.reserve(message);
      }

      // Generic over the protocol's messages, so it stays a template here.
      template <typename Message>
      TBC_GENERIC inline void complete(std::size_t offset, const Message& message) {
        output_.complete(offset, message);
      }

      void sendPayload(std::span<const Byte> payload);

      bool trySendPayload(std::span<const Byte> payload);

      void closeImmediately() noexcept;

      std::size_t responseDepth() const noexcept;

      std::size_t responseHighWater() const noexcept;

      std::uint64_t droppedResponses() const noexcept;

      bool writing() const noexcept;

      DeliveryLane nextLane() const noexcept;

      int descriptor() const noexcept;

      bool hasOutput() const noexcept;

      std::size_t queuedBytes() const noexcept;

      bool negotiated = false;
      bool closing = false;
      bool buffered_requests = false;
      bool write_interest = false;
      bool read_paused = false;
      bool read_interest = true;

    private:
      static constexpr std::size_t read_batch_size = 64 * 1024;
      static constexpr std::size_t decode_capacity = 128 * 1024;
      static constexpr std::size_t input_limit = max_payload_size + read_batch_size + frame_prefix_size;
      FileDescriptor descriptor_;
      ByteQueue<Memory> input_;
      OutgoingFrames<Memory> output_;
      Vector<Byte, Memory> decode_bytes_;
    };

    extern template class Connection<SystemAllocator>;
    extern template class Connection<Memory>;
    extern template class Connection<ConcurrentMemory>;
    extern template class Connection<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  }
}

// Interface: transport/encoded_reply.cppm
export {
  namespace telar::runtime {

    // Kept whole: path_service_test instantiates it with its own allocator (GatedPathMemory).
    template <Allocator Memory>
    class TBC_GENERIC EncodedReply {
    public:
      inline explicit EncodedReply(Memory& memory)
          : bytes_(AllocatorRef<Byte, Memory>{memory}) {
        bytes_.reserve(failure_capacity);
      }

      template <typename Message>
      inline void send(const Message& message) {
        static_assert(MessageSchema<Message>::direction == Direction::server);
        const auto length = Codec::encodedSize(message);
        if (length > max_payload_size) {
          throw std::bad_alloc{};
        }

        bytes_.resize(length);
        Codec::encode(message, bytes_);
      }

      inline std::span<const Byte> payload() const noexcept {
        return bytes_;
      }

    private:
      static constexpr std::size_t failure_capacity = 256;
      Vector<Byte, Memory> bytes_;
    };

  }
}
