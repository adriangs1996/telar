#include "support.hpp"

#include <cstdint>
#include <cstring>

namespace flow {
  // A reply is copied into the queue's slot unless an owner keeps the caller's bytes alive.
  class reply_queue {
  public:
    void push(std::span<const std::uint8_t> reply, std::shared_ptr<const void> owner) {
      if (owner) {
        owner_ = std::move(owner);
      } else {
        std::memcpy(bytes_.data(), reply.data(), reply.size());
      }

      view_ = owner_ ? reply : std::span<const std::uint8_t>{bytes_}.first(reply.size());
    }

    std::span<const std::uint8_t> peek() const {
      return view_;
    }

  private:
    std::array<std::uint8_t, 64> bytes_{};
    std::shared_ptr<const void> owner_;
    std::span<const std::uint8_t> view_;
  };

  // The same queue with copying and retaining as separate functions.
  class split_reply_queue {
  public:
    void push(std::span<const std::uint8_t> reply) {
      std::memcpy(bytes_.data(), reply.data(), reply.size());
      view_ = std::span<const std::uint8_t>{bytes_}.first(reply.size());
    }

    void push(std::span<const std::uint8_t> reply, std::shared_ptr<const void> owner) {
      owner_ = std::move(owner);
      view_ = reply;
    }

    std::span<const std::uint8_t> peek() const {
      return view_;
    }

  private:
    std::array<std::uint8_t, 64> bytes_{};
    std::shared_ptr<const void> owner_;
    std::span<const std::uint8_t> view_;
  };
} // namespace flow

// CASE: flow.branch_invalidates
// PAIR: flow.branch_paths
// SOURCE: dlls/telar-base/include/telar_base/memory/byte_queue.hpp :: reserve
// STATUS: pending
// CONTRACT: A borrow needed after a join must survive every incoming reachable path.
// SCENARIO: Only one branch reallocates, but that path still reaches the old view's read.
void branchInvalidates(tbc::view<spec::byte_queue &> queue, bool grow) {
  const auto view = queue.readable();
  if (grow) {
    queue.reserve(1024); // expected-error [tbc-invalidated-borrow]
  }
  spec::observe(view);
}

// END CASE

// CASE: flow.invalidating_branch_returns
// PAIR: flow.branch_paths
// SOURCE: dlls/telar-base/include/telar_base/memory/byte_queue.hpp :: reserve
// STATUS: pending
// CONTRACT: A view need not stay live on a path which cannot reach a later use.
// SCENARIO: The invalidating branch returns; the read is reachable only without growth.
void invalidatingBranchReturns(tbc::view<spec::byte_queue &> queue, bool grow) {
  const auto view = queue.readable();
  if (grow) {
    queue.reserve(1024);
    return;
  }
  spec::observe(view);
}

// END CASE

// CASE: flow.unwind_destroys_source
// PAIR: flow.exception_cleanup
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: makeOwned exception cleanup
// STATUS: pending
// CONTRACT: Unwinding destroys local owners before entering the surrounding handler.
// SCENARIO: A descriptor assigned outside try still points into an unwound local string.
void unwindDestroysSource() {
  spec::text view;
  try {
    const std::string local{"temporary"};
    view = local;
    throw 1; // expected-error [tbc-invalidated-borrow]
  } catch (...) {
    spec::observe(view);
  }
}

// END CASE

// CASE: flow.unwind_preserves_owned_copy
// PAIR: flow.exception_cleanup
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: makeOwned exception cleanup
// STATUS: pending
// CONTRACT: An owned copy declared outside try is not destroyed by unwinding its inner scope.
// SCENARIO: Copy the text before throwing; catch may safely read the independent owner.
void unwindPreservesOwnedCopy() {
  std::string copied;
  try {
    const std::string local{"temporary"};
    copied = spec::copyText(local);
    throw 1;
  } catch (...) {
    spec::observe(copied);
  }
}

// END CASE

// CASE: flow.conditional_retention
// PAIR: flow.retention_paths
// SOURCE: services/runtime-cpp/terminal/pty_response_queue.hpp :: PtyResponseQueue::append
// STATUS: implemented
// CONTRACT: A function that retains an argument on one path retains it for every call.
// SCENARIO: The queue copies a reply without an owner, but one store keeps either the copy or the reply depending on a field; the local reply dies before the read.
void conditionalRetention() {
  flow::reply_queue queue;
  {
    const std::array<std::uint8_t, 2> reply{1, 2};
    queue.push(reply, {});
  } // expected-error [tbc-invalidated-borrow]
  spec::observe(queue.peek());
}

// END CASE

// CASE: flow.split_retention_copied
// PAIR: flow.retention_paths
// SOURCE: services/runtime-cpp/terminal/pty_response_queue.hpp :: PtyResponseQueue::append
// STATUS: implemented
// CONTRACT: A function that only copies an argument does not retain it.
// SCENARIO: Copying and retaining are separate functions; the copying one keeps nothing of the local reply.
void splitRetentionCopied() {
  flow::split_reply_queue queue;
  {
    const std::array<std::uint8_t, 2> reply{1, 2};
    queue.push(reply);
  }
  spec::observe(queue.peek());
}

// END CASE

// CASE: flow.unrelated_owner
// PAIR: flow.reply_owner
// SOURCE: services/runtime-cpp/terminal/control/reply.hpp :: Reply::publish
// STATUS: implemented
// CONTRACT: An owner retained beside a view keeps alive only the object it owns.
// SCENARIO: The retaining function keeps the local reply; the owner is unrelated to its bytes, so the read is rejected.
void unrelatedOwner() {
  flow::split_reply_queue queue;
  {
    const std::array<std::uint8_t, 2> reply{1, 2};
    queue.push(reply, std::make_shared<int>(0));
  } // expected-error [tbc-invalidated-borrow]
  spec::observe(queue.peek());
}

// END CASE

// CASE: flow.shared_owner_alive
// PAIR: flow.reply_owner
// SOURCE: services/runtime-cpp/terminal/control/reply.hpp :: Reply::publish
// STATUS: pending
// CONTRACT: An owner retained beside a view keeps alive only the object it owns.
// SCENARIO: The queue keeps a copy of the shared owner of the reply's bytes, so the local owner's destruction does not destroy them; accept.
void sharedOwnerAlive() {
  flow::split_reply_queue queue;
  {
    const auto storage = std::make_shared<std::array<std::uint8_t, 2>>();
    queue.push(*storage, storage);
  }
  spec::observe(queue.peek());
}

// END CASE
