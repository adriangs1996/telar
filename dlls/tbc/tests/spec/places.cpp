#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace places {
  void observe(int value) {
    static_cast<void>(value);
  }

  void observeText(std::string_view text) {
    static_cast<void>(text.size());
  }

  struct pane {
    std::vector<int> cells;

    void detach() {
      cells.clear();
    }
  };

  struct tree {
    std::vector<tree> children;

    tree &add() {
      children.emplace_back();
      return children.back();
    }
  };

  struct launcher {
    std::vector<std::string> storage;
    std::vector<std::string_view> arguments;
    std::vector<std::string> history;

    void launch(std::string_view argument) {
      storage.emplace_back(argument);
      arguments.clear();
      for (const auto &stored : storage) {
        arguments.push_back(stored);
      }
    }

    void keep(std::string_view argument) {
      storage.emplace_back(argument);
    }

    void remember(std::string_view entry) {
      history.emplace_back(entry);
    }
  };

  struct message {
    std::vector<std::string> headers;
    std::string method;
  };

  struct stream {
    message request;
    message response;
  };

  message &half(stream &target, bool child) {
    return child ? target.request : target.response;
  }

  void clearResponse(stream &target) {
    target.response.headers.clear();
  }

  struct tab {
    std::vector<int> panes;
    std::string title;
  };

  struct frame_header {
    std::span<const int> spans;
    std::string_view metadata;
  };

  void observeHeader(const frame_header &header) {
    static_cast<void>(header.spans.size() + header.metadata.size());
  }

  struct query {
    std::string_view text;
    std::string_view scope;
  };

  struct browser {
    std::string text_;
    query criteria_;

    query prepare(query request) {
      text_ = request.text;
      criteria_ = request;
      criteria_.text = text_;
      return criteria_;
    }
  };

  struct arguments {
    std::vector<std::string_view> names;
    std::vector<std::string_view> defaults;
  };

  using scope_value = std::variant<std::monostate, std::string_view, std::uint64_t>;

  struct scoped_query {
    std::string_view text;
    scope_value scope;
  };

  void observeQuery(const scoped_query &query) {
    observeText(query.text);
    if (const auto *text = std::get_if<std::string_view>(&query.scope)) {
      observeText(*text);
    }
  }

  struct scoped_browser {
    std::string scope_path_;
    scoped_query criteria_;

    scoped_query prepare(scoped_query request) {
      if (const auto *path = std::get_if<std::string_view>(&request.scope)) {
        scope_path_ = *path;
      }
      criteria_ = request;
      if (std::holds_alternative<std::string_view>(criteria_.scope)) {
        criteria_.scope = std::string_view{scope_path_};
      }
      return criteria_;
    }

    scoped_query bind(scoped_query request) {
      criteria_ = request;
      if (const auto *path = std::get_if<std::string_view>(&criteria_.scope)) {
        scope_path_ = *path;
        criteria_.scope = std::string_view{scope_path_};
      }
      return criteria_;
    }

    scoped_query keep(scoped_query request) {
      criteria_ = request;
      if (std::holds_alternative<std::uint64_t>(criteria_.scope)) {
        criteria_.scope = std::monostate{};
      }
      return criteria_;
    }

    scoped_query clear(scoped_query request) {
      criteria_ = request;
      if (!std::holds_alternative<std::string_view>(criteria_.scope)) {
        return criteria_;
      }
      criteria_.scope = std::monostate{};
      return criteria_;
    }
  };

  struct frame_sync {
    std::vector<char> cells;
    std::vector<std::string_view> spans;

    void resize(std::size_t count) {
      cells.resize(count);
    }

    void prepare() {
      spans.clear();
      spans.push_back(std::string_view{cells.data(), cells.size()});
    }

    [[nodiscard]] std::size_t first() const {
      return spans.front().size();
    }
  };

  struct slots {
    std::vector<int> occupied;

    template <typename Visitor>
    void forEach(Visitor &&visit) const {
      for (const auto index : occupied) {
        visit(index);
      }
    }
  };

  struct service {
    slots indexes;
    std::vector<std::string> names;
    std::vector<int> released;

    void releaseAll() {
      indexes.forEach([this](int index) { released.push_back(index); });
    }
  };
}

// CASE: place.owned_object_mutation
// PAIR: place.owned_object
// SOURCE: services/gui-cpp/application/session.hpp :: Session::panes_
// STATUS: implemented
// CONTRACT: Mutating an object owned through a container element does not invalidate the container's elements.
// SCENARIO: Each owned pane is detached while the range loop keeps iterating the vector; accept.
void placeOwnedObjectMutation(std::vector<std::unique_ptr<places::pane>> &panes) {
  for (const auto &pane : panes) {
    pane->detach();
  }
}

// END CASE

// CASE: place.owned_object_destroyed
// PAIR: place.owned_object
// SOURCE: services/gui-cpp/application/session.hpp :: Session::panes_
// STATUS: implemented
// CONTRACT: Clearing a container of owners destroys the objects they own.
// SCENARIO: A pointer to an owned pane is read after the vector is cleared.
void placeOwnedObjectDestroyed(std::vector<std::unique_ptr<places::pane>> &panes) {
  const auto *raw = panes.front().get();
  panes.clear(); // expected-error [tbc-invalidated-borrow]
  places::observe(raw->cells.front());
}

// END CASE

// CASE: place.owned_object_survives_growth
// PAIR: place.growth
// SOURCE: services/runtime-cpp/plugins/service.hpp :: PluginService::workers_
// STATUS: implemented
// CONTRACT: Growing a container of owners moves the owners, not the objects they own.
// SCENARIO: A pointer to an owned pane is read after another pane is appended; accept.
void placeOwnedObjectSurvivesGrowth(std::vector<std::unique_ptr<places::pane>> &panes) {
  const auto *raw = panes.front().get();
  panes.push_back(std::make_unique<places::pane>());
  places::observe(raw->cells.front());
}

// END CASE

// CASE: place.element_slot_growth
// PAIR: place.growth
// SOURCE: services/runtime-cpp/plugins/service.hpp :: PluginService::workers_
// STATUS: implemented
// CONTRACT: Growing a container can move its elements, so a pointer to an element slot is invalidated.
// SCENARIO: A pointer to the owner stored in the vector is read after growth.
void placeElementSlotGrowth(std::vector<std::unique_ptr<places::pane>> &panes) {
  const auto *slot = &panes.front();
  panes.push_back(std::make_unique<places::pane>()); // expected-error [tbc-invalidated-borrow]
  places::observe((*slot)->cells.front());
}

// END CASE

// CASE: place.nested_child_mutation
// PAIR: place.nested
// SOURCE: services/runtime-cpp/cli/integration/hook_settings.hpp :: HookSettings::installEvents
// STATUS: implemented
// CONTRACT: Growing a child's own children leaves the child where it is inside its parent.
// SCENARIO: A child node is extended twice through the same reference; accept.
void placeNestedChildMutation(places::tree &root) {
  auto &child = root.add();
  child.add();
  child.add();
}

// END CASE

// CASE: place.sibling_iteration_mutation
// PAIR: place.nested
// SOURCE: services/runtime-cpp/cli/integration/hook_settings.hpp :: HookSettings::installEvents
// STATUS: implemented
// CONTRACT: Growing one node's children leaves its siblings, and the iteration over them, in place.
// SCENARIO: Every child of a node gains a child while the range loop iterates the children; accept.
void placeSiblingIterationMutation(places::tree &root) {
  for (auto &child : root.children) {
    child.add();
  }
}

// END CASE

// CASE: place.nested_grandchild_growth
// PAIR: place.nested
// SOURCE: services/runtime-cpp/cli/integration/hook_settings.hpp :: HookSettings::installEvents
// STATUS: implemented
// CONTRACT: Growing a child's children can move them, so a reference to a grandchild is invalidated.
// SCENARIO: A grandchild reference is used after another grandchild is added.
void placeNestedGrandchildGrowth(places::tree &root) {
  auto &child = root.add();
  auto &grandchild = child.add();
  child.add(); // expected-error [tbc-invalidated-borrow]
  grandchild.add();
}

// END CASE

// CASE: place.inline_element_growth
// PAIR: place.inline_element
// SOURCE: dlls/telar-base/include/telar_base/text/json_node.hpp :: JsonNode::ensure
// STATUS: implemented
// CONTRACT: An element that keeps its contents inline, like a short string, moves them when the container grows.
// SCENARIO: A view of a string element is read after the vector grows.
void placeInlineElementGrowth(std::vector<std::string> &names) {
  const std::string_view first = names.front();
  names.emplace_back("next"); // expected-error [tbc-invalidated-borrow]
  places::observeText(first);
}

// END CASE

// CASE: place.detached_element_growth
// PAIR: place.inline_element
// SOURCE: dlls/telar-base/include/telar_base/text/json_node.hpp :: JsonNode::ensure
// STATUS: implemented
// CONTRACT: An element that owns its contents through an allocation leaves them in place when the container grows.
// SCENARIO: A view of a uniquely owned string is read after the vector grows; accept.
void placeDetachedElementGrowth(std::vector<std::unique_ptr<std::string>> &names) {
  const std::string_view first = *names.front();
  names.push_back(std::make_unique<std::string>("next"));
  places::observeText(first);
}

// END CASE

// CASE: place.moved_owner_cleared
// PAIR: place.moved_owner
// SOURCE: services/gui-cpp/application/session.hpp :: Session::apply(TabCreated)
// STATUS: implemented
// CONTRACT: An object moved into a container's element is destroyed when the container is cleared.
// SCENARIO: A pointer to the moved object is read after the vector is cleared.
void placeMovedOwnerCleared(std::vector<std::unique_ptr<places::pane>> &panes) {
  auto created = std::make_unique<places::pane>();
  const auto *raw = created.get();
  panes.push_back(std::move(created));
  panes.clear(); // expected-error [tbc-invalidated-borrow]
  places::observe(raw->cells.front());
}

// END CASE

// CASE: place.moved_owner_survives_growth
// PAIR: place.moved_owner
// SOURCE: services/gui-cpp/application/session.hpp :: Session::apply(TabCreated)
// STATUS: implemented
// CONTRACT: An object moved into a container's element survives the container's reallocation.
// SCENARIO: A pointer to the moved object is read after another element is appended; accept.
void placeMovedOwnerSurvivesGrowth(std::vector<std::unique_ptr<places::pane>> &panes) {
  auto created = std::make_unique<places::pane>();
  const auto *raw = created.get();
  panes.push_back(std::move(created));
  panes.push_back(std::make_unique<places::pane>());
  places::observe(raw->cells.front());
}

// END CASE

// CASE: place.sibling_field_mutation
// PAIR: place.sibling_field
// SOURCE: services/gui-cpp/application/session.hpp :: Session::launch_arguments_
// STATUS: implemented
// CONTRACT: Mutating one field of an object leaves borrows of its other fields valid, including the object's views of itself.
// SCENARIO: A closure reads arguments that view a sibling field after a third field grows; accept.
void placeSiblingFieldMutation() {
  places::launcher client;
  client.launch("shell");
  const auto observe = [&] { places::observeText(client.arguments.front()); };
  client.remember("echo");
  observe();
}

// END CASE

// CASE: place.viewed_field_growth
// PAIR: place.sibling_field
// SOURCE: services/gui-cpp/application/session.hpp :: Session::launch_arguments_
// STATUS: implemented
// CONTRACT: Growing the field that an object's own views borrow invalidates those views.
// SCENARIO: The arguments are read after the strings they view are reallocated.
void placeViewedFieldGrowth() {
  places::launcher client;
  client.launch("shell");
  client.keep("other"); // expected-error [tbc-invalidated-borrow]
  places::observeText(client.arguments.front());
}

// END CASE

// CASE: place.rebuilt_views
// PAIR: place.sibling_field
// SOURCE: services/gui-cpp/application/session.hpp :: Session::launch_arguments_
// STATUS: implemented
// CONTRACT: A call that rebuilds an object's views of itself replaces the views it held before.
// SCENARIO: The arguments are read after a second launch reallocates the strings and views them again; accept.
void placeRebuiltViews() {
  places::launcher client;
  client.launch("shell");
  client.launch("login");
  places::observeText(client.arguments.front());
}

// END CASE

// CASE: place.owned_sibling_mutation
// PAIR: place.owned_sibling
// SOURCE: services/runtime-cpp/proxy/http2_endpoint_connection.hpp :: Http2EndpointConnection::streams_
// STATUS: implemented
// CONTRACT: Mutating one field of an object owned through a pointer leaves borrows of its other fields valid.
// SCENARIO: The request method is read after the response headers of the same stream are cleared; accept.
void placeOwnedSiblingMutation(std::vector<std::unique_ptr<places::stream>> &streams) {
  auto *active = streams.front().get();
  const std::string_view method = active->request.method;
  active->response.headers.clear();
  places::observeText(method);
}

// END CASE

// CASE: place.owned_field_mutation
// PAIR: place.owned_sibling
// SOURCE: services/runtime-cpp/proxy/http2_endpoint_connection.hpp :: Http2EndpointConnection::streams_
// STATUS: implemented
// CONTRACT: Reassigning the field a view borrows invalidates the view.
// SCENARIO: The request method is read after it is reassigned.
void placeOwnedFieldMutation(std::vector<std::unique_ptr<places::stream>> &streams) {
  auto *active = streams.front().get();
  const std::string_view method = active->request.method;
  active->request.method.assign("OPTIONS"); // expected-error [tbc-invalidated-borrow]
  places::observeText(method);
}

// END CASE

// CASE: place.returned_half_mutation
// PAIR: place.returned_half
// SOURCE: services/runtime-cpp/proxy/http2_endpoint_connection.hpp :: Http2EndpointConnection::Endpoint::half
// STATUS: implemented
// CONTRACT: A reference returned to a field keeps that field's place, so mutating it leaves sibling fields valid.
// SCENARIO: The request method is read after the headers of whichever half is selected are cleared; accept.
void placeReturnedHalfMutation(std::vector<std::unique_ptr<places::stream>> &streams, bool child) {
  auto *active = streams.front().get();
  const std::string_view method = active->request.method;
  places::half(*active, child).headers.clear();
  places::observeText(method);
}

// END CASE

// CASE: place.returned_half_headers
// PAIR: place.returned_half
// SOURCE: services/runtime-cpp/proxy/http2_endpoint_connection.hpp :: Http2EndpointConnection::Endpoint::half
// STATUS: implemented
// CONTRACT: Either field a returned reference can designate may be the one that is mutated.
// SCENARIO: A request header is read after the headers of whichever half is selected are cleared.
void placeReturnedHalfHeaders(std::vector<std::unique_ptr<places::stream>> &streams, bool child) {
  auto *active = streams.front().get();
  const std::string_view header = active->request.headers.front();
  places::half(*active, child).headers.clear(); // expected-error [tbc-invalidated-borrow]
  places::observeText(header);
}

// END CASE

// CASE: place.callee_sibling_mutation
// PAIR: place.callee_field
// SOURCE: services/runtime-cpp/proxy/http2_endpoint_connection.hpp :: Http2EndpointConnection::streams_
// STATUS: implemented
// CONTRACT: A callee that mutates one field of its argument leaves the argument's other fields valid.
// SCENARIO: The request method is read after a helper clears the response headers; accept.
void placeCalleeSiblingMutation(std::vector<std::unique_ptr<places::stream>> &streams) {
  auto *active = streams.front().get();
  const std::string_view method = active->request.method;
  places::clearResponse(*active);
  places::observeText(method);
}

// END CASE

// CASE: place.callee_field_mutation
// PAIR: place.callee_field
// SOURCE: services/runtime-cpp/proxy/http2_endpoint_connection.hpp :: Http2EndpointConnection::streams_
// STATUS: implemented
// CONTRACT: A callee that mutates a field of its argument invalidates borrows of that field.
// SCENARIO: A response header is read after a helper clears the response headers.
void placeCalleeFieldMutation(std::vector<std::unique_ptr<places::stream>> &streams) {
  auto *active = streams.front().get();
  const std::string_view header = active->response.headers.front();
  places::clearResponse(*active); // expected-error [tbc-invalidated-borrow]
  places::observeText(header);
}

// END CASE

// CASE: place.element_sibling_mutation
// PAIR: place.element_field
// SOURCE: services/runtime-cpp/runtime/workspace_service.hpp :: WorkspaceService
// STATUS: implemented
// CONTRACT: Mutating one field of a container element leaves borrows of the element's other fields valid.
// SCENARIO: The last tab's title is read after a pane is added to the same tab; accept.
void placeElementSiblingMutation(std::vector<places::tab> &tabs) {
  const std::string_view title = tabs.back().title;
  tabs.back().panes.push_back(1);
  places::observeText(title);
}

// END CASE

// CASE: place.element_field_mutation
// PAIR: place.element_field
// SOURCE: services/runtime-cpp/runtime/workspace_service.hpp :: WorkspaceService
// STATUS: implemented
// CONTRACT: Mutating a field of a container element invalidates borrows of that field.
// SCENARIO: The last tab's title is read after it is reassigned.
void placeElementFieldMutation(std::vector<places::tab> &tabs) {
  const std::string_view title = tabs.back().title;
  tabs.back().title.assign("renamed"); // expected-error [tbc-invalidated-borrow]
  places::observeText(title);
}

// END CASE

// CASE: place.element_member_growth
// PAIR: place.element_member
// SOURCE: services/runtime-cpp/runtime/workspace_service.hpp :: WorkspaceService
// STATUS: implemented
// CONTRACT: A pointer to a field of a container element is invalidated when the container moves its elements.
// SCENARIO: A pointer to the last tab's title is read after another tab is appended.
void placeElementMemberGrowth(std::vector<places::tab> &tabs) {
  const auto *title = &tabs.back().title;
  tabs.emplace_back(); // expected-error [tbc-invalidated-borrow]
  places::observeText(*title);
}

// END CASE

// CASE: place.owned_member_growth
// PAIR: place.element_member
// SOURCE: services/runtime-cpp/runtime/workspace_service.hpp :: WorkspaceService
// STATUS: implemented
// CONTRACT: A pointer to a field of an object owned by a container element survives the container's growth.
// SCENARIO: A pointer to the last owned tab's title is read after another tab is appended; accept.
void placeOwnedMemberGrowth(std::vector<std::unique_ptr<places::tab>> &tabs) {
  const auto *title = &tabs.back()->title;
  tabs.push_back(std::make_unique<places::tab>());
  places::observeText(*title);
}

// END CASE

// CASE: place.field_overwrite
// PAIR: place.field_overwrite
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::encode
// STATUS: implemented
// CONTRACT: Assigning one field of a local aggregate replaces what that field borrowed.
// SCENARIO: The spans field is pointed at the new storage after the old storage is cleared; accept.
void placeFieldOverwrite(std::vector<int> &spans, std::string_view metadata) {
  places::frame_header header{.spans = spans, .metadata = metadata};
  spans.clear();
  spans.push_back(1);
  header.spans = spans;
  places::observeHeader(header);
}

// END CASE

// CASE: place.sibling_overwrite
// PAIR: place.field_overwrite
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::encode
// STATUS: implemented
// CONTRACT: Assigning one field of an aggregate leaves what its other fields borrow.
// SCENARIO: Only the metadata field is reassigned, so the header still views the cleared spans.
void placeSiblingOverwrite(std::vector<int> &spans, std::string_view metadata) {
  places::frame_header header{.spans = spans, .metadata = metadata};
  spans.clear(); // expected-error [tbc-invalidated-borrow]
  header.metadata = metadata;
  places::observeHeader(header);
}

// END CASE

// CASE: place.copied_field_overwrite
// PAIR: place.copied_field
// SOURCE: services/gui-cpp/history/browser.hpp :: HistoryBrowser::prepareQuery
// STATUS: implemented
// CONTRACT: Copying an argument into a field and then reassigning one of its fields replaces that field's borrow.
// SCENARIO: The returned query views the browser's own copy of the text, so the caller may reuse its string; accept.
void placeCopiedFieldOverwrite() {
  places::browser browser;
  std::string text = "compiler errors";
  const auto started = browser.prepare({.text = text, .scope = "/work"});
  text.assign("reused query storage");
  places::observeText(started.text);
}

// END CASE

// CASE: place.copied_field_kept
// PAIR: place.copied_field
// SOURCE: services/gui-cpp/history/browser.hpp :: HistoryBrowser::prepareQuery
// STATUS: implemented
// CONTRACT: A field copied from an argument and not reassigned still borrows what the argument's field borrowed.
// SCENARIO: The returned query still views the caller's scope string after it is reassigned.
void placeCopiedFieldKept() {
  places::browser browser;
  std::string scope = "/work/project";
  const auto started = browser.prepare({.text = "compiler errors", .scope = scope});
  scope.assign("/reused/directory"); // expected-error [tbc-invalidated-borrow]
  places::observeText(started.scope);
}

// END CASE

// CASE: place.cleared_field
// PAIR: place.cleared_field
// SOURCE: services/gui-cpp/application/session.hpp :: Session::launch
// STATUS: implemented
// CONTRACT: Clearing a container field forgets only the borrows its elements held.
// SCENARIO: The cleared names viewed the local string, which is then reassigned; accept.
void placeClearedField(std::string_view fallback) {
  places::arguments arguments;
  std::string shell = "zsh";
  arguments.names.push_back(shell);
  arguments.defaults.push_back(fallback);
  arguments.names.clear();
  shell.assign("bash");
  places::observeText(arguments.defaults.front());
}

// END CASE

// CASE: place.cleared_sibling
// PAIR: place.cleared_field
// SOURCE: services/gui-cpp/application/session.hpp :: Session::launch
// STATUS: implemented
// CONTRACT: Clearing one container field keeps the borrows held by the object's other fields.
// SCENARIO: The defaults still view the local string after the names are cleared and the string is reassigned.
void placeClearedSibling(std::string_view fallback) {
  places::arguments arguments;
  std::string shell = "zsh";
  arguments.defaults.push_back(shell);
  arguments.names.push_back(fallback);
  arguments.names.clear();
  shell.assign("bash"); // expected-error [tbc-invalidated-borrow]
  places::observeText(arguments.defaults.front());
}

// END CASE

// CASE: place.reassigned_result
// PAIR: place.assignment
// SOURCE: services/runtime-cpp/platform/observation_worker.hpp :: ObservationWorker::run
// STATUS: implemented
// CONTRACT: Assigning an object replaces what it borrowed without reading it.
// SCENARIO: An optional view of an invalidated element is reassigned before it is read; accept.
void placeReassignedResult(std::vector<std::string> &names) {
  std::optional<std::string_view> result = names.front();
  names.emplace_back("next");
  result = names.back();
  places::observeText(*result);
}

// END CASE

// CASE: place.assigned_through_dangling
// PAIR: place.assignment
// SOURCE: services/runtime-cpp/platform/observation_worker.hpp :: ObservationWorker::run
// STATUS: implemented
// CONTRACT: Writing through a pointer needs the object it designates to be live.
// SCENARIO: A string is assigned through a pointer to an element the vector has moved.
void placeAssignedThroughDangling(std::vector<std::string> &names) {
  auto *slot = &names.front();
  names.emplace_back("next"); // expected-error [tbc-invalidated-borrow]
  *slot = "renamed";
}

// END CASE

// CASE: place.captured_receiver_sibling
// PAIR: place.captured_receiver
// SOURCE: services/runtime-cpp/proxy/service.hpp :: ProxyService::run
// STATUS: implemented
// CONTRACT: Inside a lambda, `this` is the captured object, so a field it mutates belongs to that object, not to the closure.
// SCENARIO: A name is read after a callback passed through a template helper releases slots; accept.
void placeCapturedReceiverSibling(places::service &service) {
  const std::string_view name = service.names.front();
  service.releaseAll();
  places::observeText(name);
}

// END CASE

// CASE: place.captured_receiver_field
// PAIR: place.captured_receiver
// SOURCE: services/runtime-cpp/proxy/service.hpp :: ProxyService::run
// STATUS: implemented
// CONTRACT: A field a lambda mutates through its captured `this` is invalidated in the captured object.
// SCENARIO: A pointer to a released slot is read after the callback grows the released slots.
void placeCapturedReceiverField(places::service &service) {
  const auto *first = &service.released.front();
  service.releaseAll(); // expected-error [tbc-invalidated-borrow]
  places::observe(*first);
}

// END CASE

// CASE: place.rebuilt_before_read
// PAIR: place.used_inputs
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::prepare
// STATUS: implemented
// CONTRACT: A call uses only what the called function reads, so views it rebuilds before reading are not used stale.
// SCENARIO: The spans view cells that were resized, but the next prepare clears and rebuilds them; accept.
void placeRebuiltBeforeRead() {
  places::frame_sync sync;
  sync.resize(8);
  sync.prepare();
  sync.resize(16);
  sync.prepare();
  places::observe(static_cast<int>(sync.first()));
}

// END CASE

// CASE: place.read_before_rebuild
// PAIR: place.used_inputs
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::prepare
// STATUS: implemented
// CONTRACT: A call that reads an object's views uses them.
// SCENARIO: The first span is read after the cells it views are resized.
void placeReadBeforeRebuild() {
  places::frame_sync sync;
  sync.resize(8);
  sync.prepare();
  sync.resize(16); // expected-error [tbc-invalidated-borrow]
  places::observe(static_cast<int>(sync.first()));
}

// END CASE

// CASE: place.counted_stale_views
// PAIR: place.structural_use
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::prepare
// STATUS: implemented
// CONTRACT: Counting, clearing, or growing a sequence container does not read what its elements borrow.
// SCENARIO: The number of views is read after the strings they view are reallocated; accept.
void placeCountedStaleViews(std::vector<std::string> &names) {
  std::vector<std::string_view> views{names.front()};
  names.emplace_back("next");
  places::observe(static_cast<int>(views.size()));
}

// END CASE

// CASE: place.read_stale_views
// PAIR: place.structural_use
// SOURCE: services/runtime-cpp/terminal/frame_sync.hpp :: FrameSync::prepare
// STATUS: implemented
// CONTRACT: Reading an element of a container reads what it borrows.
// SCENARIO: The first view is read after the strings it views are reallocated.
void placeReadStaleViews(std::vector<std::string> &names) {
  std::vector<std::string_view> views{names.front()};
  names.emplace_back("next"); // expected-error [tbc-invalidated-borrow]
  places::observeText(views.front());
}

// END CASE

// CASE: place.variant_rebound
// PAIR: place.variant_alternative
// SOURCE: services/gui-cpp/history/browser.hpp :: HistoryBrowser::prepareQuery
// STATUS: implemented
// CONTRACT: A variant whose other alternatives cannot borrow holds nothing borrowed once a test rules out the one that can.
// SCENARIO: The scope view is rebound to the browser's copy when it holds a view and otherwise holds no view; accept.
void placeVariantRebound() {
  places::scoped_browser browser;
  std::string directory = "/work/project";
  const auto started = browser.prepare({.text = "query", .scope = std::string_view{directory}});
  directory.assign("/reused/directory");
  places::observeQuery(started);
}

// END CASE

// CASE: place.variant_kept
// PAIR: place.variant_alternative
// SOURCE: services/gui-cpp/history/browser.hpp :: HistoryBrowser::prepareQuery
// STATUS: implemented
// CONTRACT: Ruling out an alternative that cannot borrow says nothing about the one that can.
// SCENARIO: Only an integer scope is cleared, so a scope view of the caller's string is returned.
void placeVariantKept() {
  places::scoped_browser browser;
  std::string directory = "/work/project";
  const auto started = browser.keep({.text = "query", .scope = std::string_view{directory}});
  directory.assign("/reused/directory"); // expected-error [tbc-invalidated-borrow]
  places::observeQuery(started);
}

// END CASE

// CASE: place.variant_negated
// PAIR: place.variant_alternative
// SOURCE: services/gui-cpp/history/browser.hpp :: HistoryBrowser::prepareQuery
// STATUS: implemented
// CONTRACT: A negated alternative test tells each branch which alternatives remain.
// SCENARIO: The query is returned early only when its scope holds no view, and is cleared otherwise; accept.
void placeVariantNegated() {
  places::scoped_browser browser;
  std::string directory = "/work/project";
  const auto started = browser.clear({.text = "query", .scope = std::string_view{directory}});
  directory.assign("/reused/directory");
  places::observeQuery(started);
}

// END CASE

// CASE: place.variant_bound_view
// PAIR: place.variant_alternative
// SOURCE: services/gui-cpp/history/browser.hpp :: HistoryBrowser::prepareQuery
// STATUS: implemented
// CONTRACT: A condition that declares `std::get_if` of an alternative tests that alternative.
// SCENARIO: A scope view is copied and rebound inside the branch, and the other branch holds no view; accept.
void placeVariantBoundView() {
  places::scoped_browser browser;
  std::string directory = "/work/project";
  const auto started = browser.bind({.text = "query", .scope = std::string_view{directory}});
  directory.assign("/reused/directory");
  places::observeQuery(started);
}

// END CASE

// CASE: place.variant_other_condition
// PAIR: place.variant_alternative
// SOURCE: services/gui-cpp/history/browser.hpp :: HistoryBrowser::prepareQuery
// STATUS: implemented
// CONTRACT: A branch on any other standard call, such as an operator, is not an alternative test.
// SCENARIO: The query is read when an optional flag it comes with is set; accept.
void placeVariantOtherCondition(const places::scoped_query &query, const std::optional<bool> &enabled) {
  if (*enabled) {
    places::observeQuery(query);
  }
}

// END CASE
