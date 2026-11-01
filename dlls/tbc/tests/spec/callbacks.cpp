#include "support.hpp"

// CASE: gui.deferred_borrowed_capture
// PAIR: gui.deferred_capture
// SOURCE: services/gui-cpp/qt/machine_profiles_source.cpp :: start
// STATUS: pending
// CONTRACT: enqueue retains its callback after the caller returns; captures must outlive execution.
// SCENARIO: Capturing a string_view by value copies a pointer, not the local string's bytes.
void deferredBorrowedCapture() {
  const std::string input{"local request"};
  const spec::text view = input;
  spec::enqueue([view] { spec::observe(view); }); // expected-error [tbc-escaping-capture]
}

// END CASE

// CASE: gui.deferred_owned_capture
// PAIR: gui.deferred_capture
// SOURCE: services/gui-cpp/qt/machine_profiles_source.hpp :: Request
// STATUS: pending
// CONTRACT: Owning request data moves into the retained callback and survives its producer.
// SCENARIO: The worker owns a copy of input instead of borrowing the input descriptor.
void deferredOwnedCapture() {
  const std::string input{"local request"};
  auto owned = spec::copyText(input);
  spec::enqueue([owned = std::move(owned)] { spec::observe(owned); });
}

// END CASE

// CASE: gui.inline_borrowed_capture
// PAIR: gui.deferred_capture
// SOURCE: services/gui-cpp/qt/history_filters_layout.cpp :: chipRecord
// STATUS: pending
// CONTRACT: invokeNow invokes and destroys its callback before returning; it does not retain captures.
// SCENARIO: A borrowed local is valid for the entire synchronous callback execution.
void inlineBorrowedCapture() {
  const std::string input{"local request"};
  const spec::text view = input;
  spec::invokeNow([view] { spec::observe(view); });
}

// END CASE

// CASE: runtime.published_borrowed_request
// PAIR: runtime.request_snapshot
// SOURCE: services/runtime-cpp/paths/query_task.hpp :: OwnedPathQuery::assign
// STATUS: pending
// CONTRACT: A request retained by a deferred task must not borrow a producer's stack strings.
// SCENARIO: An owning aggregate containing string_view fields is still a borrowed request.
void publishedBorrowedRequest() {
  struct request_view {
    spec::text root;
    spec::text query;
  };

  const std::string root{"/project"};
  const std::string query{"file"};
  const request_view request{root, query};
  spec::enqueue([request] { spec::observe(request); }); // expected-error [tbc-escaping-capture]
}

// END CASE

// CASE: runtime.published_owned_request
// PAIR: runtime.request_snapshot
// SOURCE: services/runtime-cpp/paths/query_task.hpp :: OwnedPathQuery::assign
// STATUS: pending
// CONTRACT: An owned snapshot copies each retained request field before publication.
// SCENARIO: Deep-copy root/query and move the aggregate into the deferred task.
void publishedOwnedRequest() {
  struct owned_request {
    std::string root;
    std::string query;
  };

  const std::string root{"/project"};
  const std::string query{"file"};
  owned_request request{spec::copyText(root), spec::copyText(query)};
  spec::enqueue([request = std::move(request)] { spec::observe(request); });
}

// END CASE

// CASE: gui.context_bound_capture
// PAIR: gui.callback_context
// SOURCE: services/gui-cpp/qt/window_images.cpp :: scheduleTimer / QMetaObject::invokeMethod
// STATUS: pending
// CONTRACT: The future adapter model must cancel callbacks before the captured context is destroyed.
// SCENARIO: A deferred borrow is legal when execution is bounded by that same referent's lifetime.
void contextBoundCapture() {
  const spec::callback_context context;
  spec::enqueueBound(context, [&context] { spec::observe(context); });
}

// END CASE

// CASE: gui.unrelated_context_capture
// PAIR: gui.callback_context
// SOURCE: services/gui-cpp/qt/window_images.cpp :: scheduleTimer / QMetaObject::invokeMethod
// STATUS: pending
// CONTRACT: Binding callback lifetime to one context does not protect unrelated captured storage.
// SCENARIO: The caller's context can survive the local source; reject this retained capture.
void unrelatedContextCapture(tbc::view<const spec::callback_context &> context) {
  const std::string local{"unrelated local"};
  spec::enqueueBound(context, [&local] { spec::observe(local); }); // expected-error [tbc-escaping-capture]
}

// END CASE
