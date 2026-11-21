module;
#include "tbc/annotations.hpp"

export module telar.runtime.nvim.rpc;

import std;
import telar.tbc;
import telar.msgpack;
import telar.base.ds;
import telar.base.memory.allocators;

// Interface: nvim/rpc.cppm
export {
  namespace telar::runtime {

    // The messages of MessagePack-RPC, by the first item of each.
    enum class NvimMessageType : std::uint8_t {
      request = 0,
      response = 1,
      notification = 2,
    };

    // Cuts the bytes a Neovim writes into whole messages. A message that arrives in one read is
    // handed over where it was read; one that spans reads is kept until its last byte arrives.
    class NvimInbox {
    public:
      // A redraw of every cell of the largest screen the limits allow stays below this.
      static constexpr std::size_t message_limit = std::size_t{64} * 1024 * 1024;

      explicit NvimInbox(ConcurrentMemory& memory);

      // Calls `consume` with each whole message, which returns false to stop. False once the
      // bytes are not MessagePack, a message passes the limit or `consume` stopped.
      template <typename Consume>
        requires std::predicate<Consume&, std::span<const std::uint8_t>>
      TBC_GENERIC bool feed(std::span<const std::uint8_t> bytes, Consume consume) {
        while (!bytes.empty()) {
          const auto progress = scanner_.feed(bytes);

          if (progress.status == msgpack::Status::malformed) {
            return false;
          }

          const auto piece = bytes.first(progress.consumed);

          bytes = bytes.subspan(progress.consumed);
          if (progress.status == msgpack::Status::incomplete) {
            return keep(piece);
          }

          if (partial_.empty()) {
            if (!consume(piece)) {
              return false;
            }

            continue;
          }

          if (!keep(piece)) {
            return false;
          }

          const bool consumed = consume(partial_.view());

          partial_.clear();
          if (!consumed) {
            return false;
          }
        }

        return true;
      }

      // The bytes of a message still arriving.
      [[nodiscard]] std::size_t buffered() const noexcept;

    private:
      bool keep(std::span<const std::uint8_t> piece);

      msgpack::Scanner scanner_;
      ds::Vec<std::uint8_t, ConcurrentMemory> partial_;
    };

  }
}
