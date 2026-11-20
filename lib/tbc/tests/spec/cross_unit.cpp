#include "units/cross_unit/node.hpp"
#include "units/cross_unit/stream.hpp"

#include <array>
#include <cstddef>
#include <span>

// Each call below reaches a function whose body only `units/cross_unit/node.cpp` defines. The
// runner checks both units together; each call is known by its declaration all the same, as a Rust
// call is by the callee's signature.

// CASE: cross_unit.find_keeps_children
// PAIR: cross_unit.accessor
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::find
// STATUS: implemented
// CONTRACT: A call is known by its declaration, wherever its body is: a const method lends its receiver shared, as `&self` does, and a non-const one exclusively, as `&mut self` does.
// SCENARIO: A lookup is a const method, so it ends no borrow of the receiver, even a non-const one; accept.
std::size_t crossUnitFind(cross_unit::node<int>& root) {
  const auto children = root.children();

  static_cast<void>(root.find("name"));
  return children.size();
}

// END CASE

// CASE: cross_unit.find_mut_ends_children
// PAIR: cross_unit.accessor
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::find
// STATUS: implemented
// CONTRACT: A call is known by its declaration, wherever its body is: a const method lends its receiver shared, as `&self` does, and a non-const one exclusively, as `&mut self` does.
// SCENARIO: The lookup for mutable access lends the whole node, whatever its body does, as Rust's `get_mut` does; reject at the call.
std::size_t crossUnitFindMut(cross_unit::node<int>& root) {
  const auto children = root.children();

  static_cast<void>(root.findMut("name")); // expected-error [tbc-invalidated-borrow]
  return children.size();
}

// END CASE

// CASE: cross_unit.append_ends_children
// PAIR: cross_unit.accessor
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::append
// STATUS: implemented
// CONTRACT: A call is known by its declaration, wherever its body is: a const method lends its receiver shared, as `&self` does, and a non-const one exclusively, as `&mut self` does.
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
// CONTRACT: A recursive function is known by its declaration like any other: recursion neither adds nor removes an effect.
// SCENARIO: Counting is a const method, so it ends no borrow of the receiver; accept.
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
// CONTRACT: A recursive function is known by its declaration like any other: recursion neither adds nor removes an effect.
// SCENARIO: Truncating is a non-const method, so it can invalidate the children view; reject at the call.
std::size_t crossUnitTruncate(cross_unit::node<int>& root) {
  const auto children = root.children();

  root.truncate(2); // expected-error [tbc-invalidated-borrow]
  return children.size();
}

// END CASE

// CASE: cross_unit.virtual_const_visit_keeps_children
// PAIR: cross_unit.virtual
// SOURCE: src/cli/tab/tab.cppm :: HistoryPathVisitor
// STATUS: implemented
// CONTRACT: Virtual or final, a call is known by its declaration, which binds every override.
// SCENARIO: The visitor receives the node by reference to const, so no override can invalidate it; accept.
std::size_t crossUnitVirtualConstVisit(cross_unit::visitor& visit, cross_unit::node<int>& root) {
  const auto children = root.children();

  visit.visit(root);
  return children.size();
}

// END CASE

// CASE: cross_unit.final_mutable_visit_ends_children
// PAIR: cross_unit.virtual
// SOURCE: src/cli/tab/tab.cppm :: HistoryPathVisitor
// STATUS: implemented
// CONTRACT: Virtual or final, a call is known by its declaration, which binds every override.
// SCENARIO: The final counter's prune only counts, but it receives the node by mutable reference, so the call can invalidate it; reject at the call.
std::size_t crossUnitFinalMutableVisit(cross_unit::counter& visit, cross_unit::node<int>& root) {
  const auto children = root.children();

  visit.prune(root); // expected-error [tbc-invalidated-borrow]
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

// CASE: cross_unit.defined_streams_keep_wrappers
// PAIR: cross_unit.stream_wrappers
// SOURCE: src/runtime/traffic/proxy/runtime/runtime.cppm :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: A wrapper keeps a mutable reference to the stream it wraps; a call that receives the wrapper by mutable reference may invalidate the stream's storage but not the wrapper's own reference to it, as a Rust `&mut` reborrows what its fields lend.
// SCENARIO: Each wrapper views its own socket, whose reads and writes another unit defines; accept.
bool crossUnitDefinedStreams(cross_unit::relays& relays, cross_unit::socket_stream& child, cross_unit::socket_stream& origin, cross_unit::flow* owner) {
  cross_unit::flow_stream<cross_unit::socket_stream> to_child{child, owner};
  cross_unit::flow_stream<cross_unit::socket_stream> to_origin{origin, owner};

  return relays.transfer(to_child, to_origin, owner);
}

// END CASE

// CASE: cross_unit.opaque_streams_keep_wrappers
// PAIR: cross_unit.stream_wrappers
// SOURCE: src/runtime/traffic/proxy/runtime/runtime.cppm :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: A wrapper keeps a mutable reference to the stream it wraps; a call that receives the wrapper by mutable reference may invalidate the stream's storage but not the wrapper's own reference to it, as a Rust `&mut` reborrows what its fields lend.
// SCENARIO: No checked unit defines the streams' reads and writes, which changes nothing: the calls are known by their declarations either way; accept.
bool crossUnitOpaqueStreams(cross_unit::relays& relays, cross_unit::opaque_stream& child, cross_unit::opaque_stream& origin, cross_unit::flow* owner) {
  cross_unit::flow_stream<cross_unit::opaque_stream> to_child{child, owner};
  cross_unit::flow_stream<cross_unit::opaque_stream> to_origin{origin, owner};

  return relays.transfer(to_child, to_origin, owner);
}

// END CASE

// CASE: cross_unit.shared_stream_overlaps
// PAIR: cross_unit.stream_wrappers
// SOURCE: src/runtime/traffic/proxy/runtime/runtime.cppm :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: A wrapper keeps a mutable reference to the stream it wraps; a call that receives the wrapper by mutable reference may invalidate the stream's storage but not the wrapper's own reference to it, as a Rust `&mut` reborrows what its fields lend.
// SCENARIO: Both wrappers view the same socket, so mutating it through either one invalidates the other's borrow of it; reject each wrapper at the call.
bool crossUnitSharedStream(cross_unit::relays& relays, cross_unit::socket_stream& socket, cross_unit::flow* owner) {
  cross_unit::flow_stream<cross_unit::socket_stream> to_child{socket, owner};
  cross_unit::flow_stream<cross_unit::socket_stream> to_origin{socket, owner};

  return relays.transfer(
      to_child,  // expected-error [tbc-invalidated-borrow]
      to_origin, // expected-error [tbc-invalidated-borrow]
      owner
  );
}

// END CASE
