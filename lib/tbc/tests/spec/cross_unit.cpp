#include "units/cross_unit/node.hpp"

#include <cstddef>

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
