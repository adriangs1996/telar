#include "units/cross_unit/node.hpp"
#include "units/cross_unit/stream.hpp"

#include <array>
#include <cstddef>
#include <span>

// Each call below reaches a function whose body only `units/cross_unit/node.cpp` defines. The
// runner checks both units together, so the first pass summarizes what that body invalidates.

// CASE: cross_unit.find_keeps_children
// PAIR: cross_unit.accessor
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::find
// STATUS: implemented
// CONTRACT: A call into a function another unit defines invalidates what that function's body can invalidate, as when its body is visible; a non-const receiver alone ends no borrow of it.
// SCENARIO: A lookup through the non-const receiver mutates nothing, so the children viewed before it stay valid; accept.
std::size_t crossUnitFind(cross_unit::node<int>& root) {
  const auto children = root.children();

  static_cast<void>(root.find("name"));
  return children.size();
}

// END CASE

// CASE: cross_unit.append_ends_children
// PAIR: cross_unit.accessor
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::append
// STATUS: implemented
// CONTRACT: A call into a function another unit defines invalidates what that function's body can invalidate, as when its body is visible; a non-const receiver alone ends no borrow of it.
// SCENARIO: Appending a child can move the storage the children view designates; reject at the call.
std::size_t crossUnitAppend(cross_unit::node<int>& root) {
  const auto children = root.children();

  root.append({}); // expected-error [tbc-invalidated-borrow]
  return children.size();
}

// END CASE

// CASE: cross_unit.recursive_count_keeps_children
// PAIR: cross_unit.recursion
// SOURCE: lib/base/text/json/json.cpp :: JsonNode::appendFormatted
// STATUS: implemented
// CONTRACT: A recursive function's summary is solved in the unit that defines it, from no effect up, so recursion alone invalidates nothing.
// SCENARIO: Counting walks the tree through recursive calls and mutates nothing; accept.
std::size_t crossUnitCount(cross_unit::node<int>& root) {
  const auto children = root.children();
  const auto total = root.count();

  return total + children.size();
}

// END CASE

// CASE: cross_unit.recursive_truncate_ends_children
// PAIR: cross_unit.recursion
// SOURCE: lib/base/text/json/json.cpp :: JsonNode::appendFormatted
// STATUS: implemented
// CONTRACT: A recursive function's summary is solved in the unit that defines it, from no effect up, so recursion alone invalidates nothing.
// SCENARIO: Truncating clears the children at the deepest level it recurses to, which can be this node's; reject at the call.
std::size_t crossUnitTruncate(cross_unit::node<int>& root) {
  const auto children = root.children();

  root.truncate(2); // expected-error [tbc-invalidated-borrow]
  return children.size();
}

// END CASE

// CASE: cross_unit.final_visit_keeps_children
// PAIR: cross_unit.virtual
// SOURCE: src/cli/tab/tab.cppm :: HistoryPathVisitor
// STATUS: implemented
// CONTRACT: A virtual call may reach an override no unit summarized, so it stays known by its declaration; a call to a final override is known by its body.
// SCENARIO: The final counter only counts the node it visits; accept.
std::size_t crossUnitFinalVisit(cross_unit::counter& visit, cross_unit::node<int>& root) {
  const auto children = root.children();

  visit.visit(root);
  return children.size();
}

// END CASE

// CASE: cross_unit.virtual_visit_ends_children
// PAIR: cross_unit.virtual
// SOURCE: src/cli/tab/tab.cppm :: HistoryPathVisitor
// STATUS: implemented
// CONTRACT: A virtual call may reach an override no unit summarized, so it stays known by its declaration; a call to a final override is known by its body.
// SCENARIO: The base visitor's body mutates nothing, but an override may, so the call can invalidate the node it receives; reject at the call.
std::size_t crossUnitVirtualVisit(cross_unit::visitor& visit, cross_unit::node<int>& root) {
  const auto children = root.children();

  visit.visit(root); // expected-error [tbc-invalidated-borrow]
  return children.size();
}

// END CASE

// The proxy's relay, reduced: a stream wrapper per side over its own socket, and a transfer that
// reads one side into its buffer and writes it to the other, as `ApplicationRelay::advance` lends
// two `FlowStream`s over `SocketStream`s to `Relays::transfer`.
namespace cross_unit {
  struct flow {
    int failures = 0;

    void fail() noexcept {
      ++failures;
    }
  };

  template <typename stream>
  class flow_stream {
  public:
    flow_stream(stream& source, flow* owner) noexcept
        : stream_(source),
          flow_(owner) {}

    int read(std::span<unsigned char> destination) noexcept {
      const int result = stream_.read(destination);
      if (flow_ != nullptr && result < 0) {
        flow_->fail();
      }

      return result;
    }

    int write(std::span<const unsigned char> bytes) noexcept {
      return stream_.write(bytes);
    }

  private:
    stream& stream_;
    flow* flow_;
  };

  struct direction {
    std::array<unsigned char, 64> bytes{};
    std::size_t length = 0;

    template <typename source, typename destination>
    bool advance(source& from, destination& to) noexcept {
      const int received = from.read(bytes);
      if (received > 0) {
        length = static_cast<std::size_t>(received);
      }

      return to.write(std::span{bytes}.first(length)) > 0;
    }
  };

  struct relays {
    direction outbound;
    direction inbound;

    template <typename child, typename origin>
    bool transfer(child& to_child, origin& to_origin, flow* owner) noexcept {
      const bool outgoing = outbound.advance(to_child, to_origin);
      const bool incoming = inbound.advance(to_origin, to_child);

      return (outgoing || incoming) && (owner == nullptr || owner->failures == 0);
    }
  };
}

// CASE: cross_unit.summarized_streams_keep_wrappers
// PAIR: cross_unit.stream_wrappers
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: A wrapper keeps a reference to the stream it wraps; a call that reads and writes through the wrappers invalidates only what the streams' bodies invalidate, read from the unit that defines them.
// SCENARIO: The sockets' reads and writes change no storage the wrappers designate, and each wrapper views its own socket; accept.
bool crossUnitSummarizedStreams(cross_unit::relays& relays, cross_unit::socket_stream& child, cross_unit::socket_stream& origin, cross_unit::flow* owner) {
  cross_unit::flow_stream<cross_unit::socket_stream> to_child{child, owner};
  cross_unit::flow_stream<cross_unit::socket_stream> to_origin{origin, owner};

  return relays.transfer(to_child, to_origin, owner);
}

// END CASE

// CASE: cross_unit.opaque_streams_end_wrappers
// PAIR: cross_unit.stream_wrappers
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: A wrapper keeps a reference to the stream it wraps; a call that reads and writes through the wrappers invalidates only what the streams' bodies invalidate, read from the unit that defines them.
// SCENARIO: No checked unit defines the streams' reads and writes, so each may invalidate the stream it is called on, which the wrapper passed with it designates; reject both wrappers at the call. A run that leaves out the streams' unit reports the proxy's relay so.
bool crossUnitOpaqueStreams(cross_unit::relays& relays, cross_unit::opaque_stream& child, cross_unit::opaque_stream& origin, cross_unit::flow* owner) {
  cross_unit::flow_stream<cross_unit::opaque_stream> to_child{child, owner};
  cross_unit::flow_stream<cross_unit::opaque_stream> to_origin{origin, owner};

  return relays.transfer(
      to_child,  // expected-error [tbc-invalidated-borrow]
      to_origin, // expected-error [tbc-invalidated-borrow]
      owner
  );
}

// END CASE
