#include <algorithm>
#include <array>
#include <cstddef>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace standard {
  void observe(std::string_view text) {
    static_cast<void>(text.size());
  }

  void observeChars(const char *text) {
    static_cast<void>(text);
  }

  struct record {
    std::string_view text;
  };

  std::optional<std::string_view> lookup(std::string_view text) {
    return text;
  }

  struct node {
    int value = 0;
  };
}

// CASE: std.optional_arrow_escape
// PAIR: std.optional_arrow
// SOURCE: dlls/ebnf/tests/lifetime_test.cpp :: getText
// STATUS: implemented
// CONTRACT: std::optional::operator-> points into the optional's own storage, like operator*.
// SCENARIO: The pointer into a local optional is returned.
const std::string_view *optionalArrowEscape() {
  const std::optional<std::string_view> maybe{"x"};
  return maybe.operator->(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.optional_arrow_read
// PAIR: std.optional_arrow
// SOURCE: dlls/ebnf/tests/lifetime_test.cpp :: getText
// STATUS: implemented
// CONTRACT: A member read through operator-> of a temporary optional is valid within its full expression.
// SCENARIO: The ebnf tests read getText(rule)->data(); accept.
void optionalArrowRead(std::string_view text) {
  standard::observeChars(standard::lookup(text)->data());
}

// END CASE

// CASE: std.unique_get_escape
// PAIR: std.unique_get
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: Owned
// STATUS: implemented
// CONTRACT: unique_ptr::get points into storage that the owner releases when it dies.
// SCENARIO: The pointer from a local owner is returned.
const standard::record *uniqueGetEscape(std::string_view text) {
  const auto owner = std::make_unique<standard::record>(standard::record{text});
  return owner.get(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.unique_get_read
// PAIR: std.unique_get
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: Owned
// STATUS: implemented
// CONTRACT: Contents read through a smart pointer borrow what the owned object borrows.
// SCENARIO: The owned record's text outlives the owner; accept.
std::string_view uniqueGetRead(std::string_view text) {
  const auto owner = std::make_unique<standard::record>(standard::record{text});
  return owner->text;
}

// END CASE

// CASE: std.value_or_dangling
// PAIR: std.value_or
// SOURCE: services/runtime-cpp/cli/hooks/map.hpp :: optionalText
// STATUS: implemented
// CONTRACT: value_or copies a contained view, keeping that view's dependency.
// SCENARIO: The contained view's source dies before the copy is read.
void valueOrDangling() {
  std::string_view result;
  {
    const std::string owner = "abc";
    const std::optional<std::string_view> maybe{owner};
    result = maybe.value_or("x");
  } // expected-error [tbc-invalidated-borrow]
  standard::observe(result);
}

// END CASE

// CASE: std.value_or_temporary
// PAIR: std.value_or
// SOURCE: services/runtime-cpp/cli/hooks/map.hpp :: optionalText
// STATUS: implemented
// CONTRACT: value_or on a temporary optional does not borrow the temporary optional.
// SCENARIO: The copied view outlives the optional that held it; accept.
void valueOrTemporary(std::string_view text) {
  const auto result = standard::lookup(text).value_or("");
  standard::observe(result);
}

// END CASE

// CASE: std.iterator_invalidated
// PAIR: std.iterator
// SOURCE: dlls/telar-config/include/telar_config/agents/manifest.hpp :: AgentManifests::tryAdd
// STATUS: implemented
// CONTRACT: A vector iterator points into the vector's storage, which growth may reallocate.
// SCENARIO: push_back can invalidate the iterator before it is dereferenced.
void iteratorInvalidated() {
  std::vector<std::string_view> values{"a"};
  const auto first = values.begin();
  values.push_back("b"); // expected-error [tbc-invalidated-borrow]
  standard::observe(*first);
}

// END CASE

// CASE: std.iterator_range_for
// PAIR: std.iterator
// SOURCE: dlls/telar-config/include/telar_config/agents/manifest.hpp :: AgentManifests::tryAdd
// STATUS: implemented
// CONTRACT: Dereferencing an iterator designates the element, not the iterator object.
// SCENARIO: A range-for element and a pointer to it come from the caller's vector; accept.
const std::string_view *iteratorRangeFor(const std::vector<std::string_view> &values) {
  for (const auto &item : values) {
    standard::observe(item);
    return &item;
  }
  return nullptr;
}

// END CASE

// CASE: std.element_escape
// PAIR: std.element
// SOURCE: dlls/telar-base/include/telar_base/text/json_node.hpp :: JsonNode::find
// STATUS: implemented
// CONTRACT: An element reference from a range-for borrows the iterated container.
// SCENARIO: A pointer to an element of a local vector is returned.
const std::string_view *elementEscape() {
  const std::vector<std::string_view> values{"a"};
  for (const auto &item : values) {
    return &item; // expected-error [tbc-dangling-borrow]
  }
  return nullptr;
}

// END CASE

// CASE: std.initializer_list_copy
// PAIR: std.element
// SOURCE: dlls/telar-base/include/telar_base/text/json_node.hpp :: JsonNode::find
// STATUS: implemented
// CONTRACT: A container copies an initializer list instead of borrowing its backing array.
// SCENARIO: Elements built from an initializer list are read after the list's full expression; accept.
void initializerListCopy(std::string_view text) {
  const std::vector<std::string_view> values{text};
  standard::observe(*values.begin());
}

// END CASE

// CASE: std.find_escape
// PAIR: std.algorithm
// SOURCE: dlls/telar-base/include/telar_base/diagnostics/limit_ledger.hpp :: LimitLedger
// STATUS: implemented
// CONTRACT: An iterator returned by an algorithm comes from its iterator arguments.
// SCENARIO: The found element of a local vector is returned as a view.
std::string_view findEscape() {
  const std::vector<std::string> owners{"a", "b"};
  const auto found = std::find(owners.begin(), owners.end(), "b");
  return *found; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.find_parameter
// PAIR: std.algorithm
// SOURCE: dlls/telar-base/include/telar_base/diagnostics/limit_ledger.hpp :: LimitLedger
// STATUS: implemented
// CONTRACT: A needle argument does not become part of the found iterator's dependency.
// SCENARIO: The found element comes from the caller's vector and a temporary needle; accept.
std::string_view findParameter(const std::vector<std::string> &owners) {
  const auto found = std::find(owners.begin(), owners.end(), std::string{"b"});
  return found == owners.end() ? std::string_view{} : std::string_view{*found};
}

// END CASE

// CASE: std.exchange_dangling
// PAIR: std.exchange
// SOURCE: dlls/telar-base/include/telar_base/memory/sensitive_allocation.hpp :: SensitiveAllocation
// STATUS: implemented
// CONTRACT: std::exchange returns a copy of its object's previous value.
// SCENARIO: The previous view's source dies before it is read.
void exchangeDangling() {
  std::string_view previous;
  {
    const std::string owner = "abc";
    std::string_view slot = owner;
    previous = std::exchange(slot, "x");
  } // expected-error [tbc-invalidated-borrow]
  standard::observe(previous);
}

// END CASE

// CASE: std.exchange_live
// PAIR: std.exchange
// SOURCE: dlls/telar-base/include/telar_base/memory/sensitive_allocation.hpp :: SensitiveAllocation
// STATUS: implemented
// CONTRACT: An exchanged previous value may be read while its source is alive.
// SCENARIO: The source outlives the read; accept.
void exchangeLive(std::string_view text) {
  std::string_view slot = text;
  standard::observe(std::exchange(slot, "next"));
}

// END CASE

// CASE: std.get_if_escape
// PAIR: std.get_if
// SOURCE: services/runtime-cpp/proxy/authenticate.hpp :: ProxyDecision
// STATUS: implemented
// CONTRACT: std::get_if points into the variant passed by address.
// SCENARIO: A pointer into a local variant is returned.
const std::string_view *getIfEscape() {
  const std::variant<std::string_view, int> value{"x"};
  return std::get_if<std::string_view>(&value); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.get_if_parameter
// PAIR: std.get_if
// SOURCE: services/runtime-cpp/proxy/authenticate.hpp :: ProxyDecision
// STATUS: implemented
// CONTRACT: A pointer into a caller's variant may outlive the call.
// SCENARIO: The variant belongs to the caller; accept.
const std::string_view *getIfParameter(const std::variant<std::string_view, int> &value) {
  return std::get_if<std::string_view>(&value);
}

// END CASE

// CASE: std.map_escape
// PAIR: std.map
// SOURCE: services/runtime-cpp/cli/hooks/object.hpp :: Object::find
// STATUS: implemented
// CONTRACT: Associative containers are tracked like other standard containers.
// SCENARIO: A view into a local map's string is returned.
std::string_view mapEscape() {
  const std::map<int, std::string> owners{{1, "a"}};
  return owners.find(1)->second; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.map_view
// PAIR: std.map
// SOURCE: services/runtime-cpp/cli/hooks/object.hpp :: Object::find
// STATUS: implemented
// CONTRACT: A view stored in a map keeps its own source rather than the map.
// SCENARIO: The mapped view outlives the local map; accept.
std::string_view mapView(std::string_view text) {
  const std::map<int, std::string_view> values{{1, text}};
  return values.at(1);
}

// END CASE

// CASE: std.function_dangling
// PAIR: std.function
// SOURCE: services/runtime-cpp/platform/request_worker.hpp :: RequestWorker::run
// STATUS: implemented
// CONTRACT: A std::function keeps the borrows of the callable it wraps.
// SCENARIO: The stored callback is invoked after its captured owner dies.
void functionDangling() {
  std::function<void()> callback;
  {
    const std::string owner = "abc";
    callback = [&owner] { standard::observe(owner); };
  } // expected-error [tbc-invalidated-borrow]
  callback();
}

// END CASE

// CASE: std.function_live
// PAIR: std.function
// SOURCE: services/runtime-cpp/platform/request_worker.hpp :: RequestWorker::run
// STATUS: implemented
// CONTRACT: A stored callback may run while its captures are alive.
// SCENARIO: The owner outlives the invocation; accept.
void functionLive() {
  const std::string owner = "abc";
  const std::function<void()> callback = [&owner] { standard::observe(owner); };
  callback();
}

// END CASE

// CASE: std.converted_owner_escape
// PAIR: std.converted_owner
// SOURCE: services/runtime-cpp/worktrees/linked_worktree.hpp :: LinkedWorktree
// STATUS: implemented
// CONTRACT: A wrapper whose element is a view borrows an owner converted into that element.
// SCENARIO: An optional view of a local string is returned.
std::optional<std::string_view> convertedOwnerEscape() {
  const std::string owner = "abc";
  return std::optional<std::string_view>{owner}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.converted_owner_copied
// PAIR: std.converted_owner
// SOURCE: services/runtime-cpp/worktrees/linked_worktree.hpp :: LinkedWorktree
// STATUS: implemented
// CONTRACT: An owner stored in an owning element of a pair is copied, not borrowed.
// SCENARIO: Only the first element is a view; the temporary string fills the owned second element; accept.
std::pair<std::string_view, std::string> convertedOwnerCopied(std::string_view text) {
  return std::pair<std::string_view, std::string>{text, std::string{"owned"}};
}

// END CASE

// CASE: std.range_copy
// PAIR: std.range_construction
// SOURCE: services/gui-cpp/tests/font_fixture.hpp :: fontData
// STATUS: implemented
// CONTRACT: A container built from an iterator range copies the designated elements, not the range's storage.
// SCENARIO: The copied views outlive the local vector they were read from; accept.
std::vector<std::string_view> rangeCopy(std::string_view text) {
  const std::vector<std::string_view> source{text};
  return std::vector<std::string_view>{source.begin(), source.end()};
}

// END CASE

// CASE: std.range_copy_dangling
// PAIR: std.range_construction
// SOURCE: services/gui-cpp/tests/font_fixture.hpp :: fontData
// STATUS: implemented
// CONTRACT: Copied elements keep the dependencies of the elements they copy.
// SCENARIO: The copied views point into strings owned by a local vector.
std::vector<std::string_view> rangeCopyDangling() {
  const std::vector<std::string> owners{"a"};
  std::vector<std::string_view> views;
  views.push_back(owners.front());
  return std::vector<std::string_view>{views.begin(), views.end()}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.initializer_list_range
// PAIR: std.initializer_list_range
// SOURCE: services/runtime-cpp/tests/worktree_probe_test.cpp :: worktree
// STATUS: implemented
// CONTRACT: Elements copied out of an initializer list keep their own dependencies, not the backing array's.
// SCENARIO: Literal pointers copied by a range-for are used after the loop; accept.
void initializerListRange() {
  std::array<const char *, 2> complete{};
  std::size_t count = 0;
  for (const auto prefix : {"git", "-c"}) {
    complete[count++] = prefix;
  }
  standard::observeChars(complete[0]);
}

// END CASE

// CASE: std.initializer_list_range_dangling
// PAIR: std.initializer_list_range
// SOURCE: services/runtime-cpp/tests/worktree_probe_test.cpp :: worktree
// STATUS: implemented
// CONTRACT: A view copied out of an initializer list keeps its referent's dependency.
// SCENARIO: The listed view's string dies before the copied view is read.
void initializerListRangeDangling() {
  std::string_view last;
  {
    const std::string owner = "abc";
    for (const auto item : {std::string_view{owner}}) {
      last = item;
    }
  } // expected-error [tbc-invalidated-borrow]
  standard::observe(last);
}

// END CASE

// CASE: std.moved_into_caller_owner
// PAIR: std.moved_owner
// SOURCE: services/gui-cpp/qt/terminal_scene.cpp :: TerminalScene
// STATUS: implemented
// CONTRACT: Moving a unique_ptr hands its object to the destination, so a raw pointer follows the new owner.
// SCENARIO: The replacement moves into the caller's owner before the raw pointer is returned; accept.
standard::node *movedIntoCallerOwner(std::unique_ptr<standard::node> &owner) {
  auto replacement = std::make_unique<standard::node>();
  auto *raw = replacement.get();
  owner = std::move(replacement);
  return raw;
}

// END CASE

// CASE: std.moved_into_container
// PAIR: std.moved_owner
// SOURCE: services/gui-cpp/application/session.hpp :: Session::apply(TabCreated)
// STATUS: implemented
// CONTRACT: A unique_ptr moved into a container keeps its object alive for as long as the container.
// SCENARIO: A reference to the created object outlives the moved-from local; accept.
standard::node &movedIntoContainer(std::vector<std::unique_ptr<standard::node>> &owners) {
  auto created = std::make_unique<standard::node>();
  auto &result = *created;
  owners.push_back(std::move(created));
  return result;
}

// END CASE

// CASE: std.moved_into_local_owner
// PAIR: std.moved_owner
// SOURCE: services/gui-cpp/qt/terminal_scene.cpp :: TerminalScene
// STATUS: implemented
// CONTRACT: An object moved into a local owner dies with that owner.
// SCENARIO: The raw pointer is returned after its new local owner goes out of scope.
standard::node *movedIntoLocalOwner() {
  auto replacement = std::make_unique<standard::node>();
  auto *raw = replacement.get();
  std::unique_ptr<standard::node> owner;
  owner = std::move(replacement);
  return raw; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.emplaced_view_escape
// PAIR: std.emplaced_view
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::encode
// STATUS: implemented
// CONTRACT: A view element emplaced from a pointer and a size designates what the pointer designates.
// SCENARIO: The emplaced view points into a local string that dies before the returned vector.
std::vector<std::string_view> emplacedViewEscape() {
  const std::string text = "temporary";
  std::vector<std::string_view> views;
  views.emplace_back(text.data(), text.size());
  return views; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.emplaced_view_parameter
// PAIR: std.emplaced_view
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::encode
// STATUS: implemented
// CONTRACT: A view element emplaced from a pointer and a size designates what the pointer designates.
// SCENARIO: The emplaced view points into the caller's string; accept.
std::vector<std::string_view> emplacedViewParameter(const std::string &text) {
  std::vector<std::string_view> views;
  views.emplace_back(text.data(), text.size());
  return views;
}

// END CASE

// CASE: std.pointer_element_escape
// PAIR: std.pointer_element
// SOURCE: services/gui-cpp/platform/runtime_endpoint.cpp :: spawn
// STATUS: implemented
// CONTRACT: A pointer element, pushed or emplaced, designates the object it points to.
// SCENARIO: The stored pointers designate a local that dies before the returned vector.
std::vector<const int *> pointerElementEscape() {
  const int value = 1;
  std::vector<const int *> pointers;
  pointers.push_back(&value);
  pointers.emplace_back(&value);
  return pointers; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.pointer_element_position
// PAIR: std.pointer_element
// SOURCE: services/gui-cpp/platform/runtime_endpoint.cpp :: spawn
// STATUS: implemented
// CONTRACT: The position an insertion or an emplacement takes is not stored as an element.
// SCENARIO: The stored pointers designate the caller's object, inserted at a position of the local vector; accept.
std::vector<const int *> pointerElementPosition(const int &value) {
  std::vector<const int *> pointers;
  pointers.insert(pointers.begin(), &value);
  pointers.emplace(pointers.begin(), &value);
  return pointers;
}

// END CASE

// CASE: std.inserted_range_escape
// PAIR: std.inserted_range
// SOURCE: services/gui-cpp/fonts/row_text_layout.hpp :: RowTextLayout::appendPrimary
// STATUS: implemented
// CONTRACT: An inserted iterator range copies the elements it designates, with their dependencies.
// SCENARIO: The copied views point into a local string that dies before the returned vector.
std::vector<std::string_view> insertedRangeEscape() {
  const std::string text = "temporary";
  const std::vector<std::string_view> source{text};
  std::vector<std::string_view> views;
  views.insert(views.end(), source.begin(), source.end());
  return views; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: std.inserted_range_parameter
// PAIR: std.inserted_range
// SOURCE: services/gui-cpp/fonts/row_text_layout.hpp :: RowTextLayout::appendPrimary
// STATUS: implemented
// CONTRACT: An inserted iterator range copies the elements it designates, not the source container's storage.
// SCENARIO: The copied views point into the caller's string, while the local source vector dies; accept.
std::vector<std::string_view> insertedRangeParameter(const std::string &text) {
  const std::vector<std::string_view> source{text};
  std::vector<std::string_view> views;
  views.insert(views.end(), source.begin(), source.end());
  return views;
}

// END CASE
