#include <array>
#include <span>
#include <string>
#include <string_view>

namespace pointers {
  void observe(std::string_view text) {
    static_cast<void>(text.size());
  }

  void observeChars(const char *text) {
    static_cast<void>(text);
  }

  struct record {
    std::string_view text;
  };

  struct keeper {
    std::string_view kept;

    void keep(std::string_view text) {
      kept = text;
    }
  };

  std::string_view pointeeText(const record *pointer) {
    return pointer->text;
  }

  struct options {
    std::string_view value;
  };

  struct frame {
    std::span<const int> values;
  };

  void deliver(frame value) {
    static_cast<void>(value.values.size());
  }
}

// CASE: pointer.dereference_dead
// PAIR: pointer.dereference
// SOURCE: services/runtime-cpp/text/json_node.hpp :: JsonNode::find
// STATUS: implemented
// CONTRACT: Reading through a pointer requires its pointee to be alive.
// SCENARIO: The pointee dies at the end of its block before the pointer is dereferenced.
void pointerDereferenceDead() {
  const std::string_view *pointer = nullptr;
  {
    const std::string_view local = "x";
    pointer = &local;
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(*pointer);
}

// END CASE

// CASE: pointer.dereference_live
// PAIR: pointer.dereference
// SOURCE: services/runtime-cpp/text/json_node.hpp :: JsonNode::find
// STATUS: implemented
// CONTRACT: A pointer to a live view lends that view's referent.
// SCENARIO: The pointee and its referent outlive every read; accept.
void pointerDereferenceLive(std::string_view text) {
  const auto *pointer = &text;
  pointers::observe(*pointer);
  pointers::observeChars(pointer->data());
}

// END CASE

// CASE: pointer.referent_invalidated
// PAIR: pointer.referent
// SOURCE: services/runtime-cpp/text/json_node.hpp :: JsonNode::find
// STATUS: implemented
// CONTRACT: A member call through a pointer reads the pointee's contents, not the pointer's storage.
// SCENARIO: The view designated by the pointer loses its referent before data() is read.
void pointerReferentInvalidated() {
  std::string owner = "abc";
  const std::string_view view = owner;
  const auto *pointer = &view;
  owner.clear(); // expected-error [tbc-invalidated-borrow]
  pointers::observeChars(pointer->data());
}

// END CASE

// CASE: pointer.referent_live
// PAIR: pointer.referent
// SOURCE: services/runtime-cpp/text/json_node.hpp :: JsonNode::find
// STATUS: implemented
// CONTRACT: A member call through a pointer to a live view is valid.
// SCENARIO: The referent is unchanged before data() is read; accept.
void pointerReferentLive() {
  const std::string owner = "abc";
  const std::string_view view = owner;
  const auto *pointer = &view;
  pointers::observeChars(pointer->data());
}

// END CASE

// CASE: pointer.write_through_dead
// PAIR: pointer.write_through
// SOURCE: services/runtime-cpp/cli/integration/hook_settings.hpp :: installEvents
// STATUS: implemented
// CONTRACT: Writing through a pointer updates the variable it designates.
// SCENARIO: A view stored through the pointer outlives its source.
void pointerWriteThroughDead() {
  std::string_view slot;
  auto *pointer = &slot;
  {
    const std::string owner = "abc";
    *pointer = owner;
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(slot);
}

// END CASE

// CASE: pointer.write_through_live
// PAIR: pointer.write_through
// SOURCE: services/runtime-cpp/cli/integration/hook_settings.hpp :: installEvents
// STATUS: implemented
// CONTRACT: A view written through a pointer may be read while its source is alive.
// SCENARIO: The source outlives the read of the designated variable; accept.
void pointerWriteThroughLive(std::string_view text) {
  std::string_view slot;
  auto *pointer = &slot;
  *pointer = text;
  pointers::observe(slot);
}

// END CASE

// CASE: pointer.arrow_call_dead
// PAIR: pointer.arrow_call
// SOURCE: services/runtime-cpp/cli/integration/hook_settings.hpp :: installEvents
// STATUS: implemented
// CONTRACT: A method called through a pointer writes the pointee's state.
// SCENARIO: The pointee keeps a view of a source that dies before the read.
void pointerArrowCallDead() {
  pointers::keeper value;
  auto *pointer = &value;
  {
    const std::string owner = "abc";
    pointer->keep(owner);
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(value.kept);
}

// END CASE

// CASE: pointer.arrow_call_live
// PAIR: pointer.arrow_call
// SOURCE: services/runtime-cpp/cli/integration/hook_settings.hpp :: installEvents
// STATUS: implemented
// CONTRACT: State written through a pointer may be read while its source is alive.
// SCENARIO: The kept source outlives the read; accept.
void pointerArrowCallLive(std::string_view text) {
  pointers::keeper value;
  auto *pointer = &value;
  pointer->keep(text);
  pointers::observe(value.kept);
}

// END CASE

// CASE: pointer.parameter_pointee_live
// PAIR: pointer.parameter_pointee
// SOURCE: services/runtime-cpp/agents/manifest.hpp :: AgentManifests::find
// STATUS: implemented
// CONTRACT: A field read through a pointer parameter borrows the pointee's contents, not the pointee.
// SCENARIO: The returned text outlives the local record that held it; accept.
std::string_view pointerParameterPointeeLive(std::string_view source) {
  const pointers::record value{source};
  return pointers::pointeeText(&value);
}

// END CASE

// CASE: pointer.parameter_pointee_dead
// PAIR: pointer.parameter_pointee
// SOURCE: services/runtime-cpp/agents/manifest.hpp :: AgentManifests::find
// STATUS: implemented
// CONTRACT: Contents read through a pointer parameter keep the dependency on their own source.
// SCENARIO: The text's source dies before the returned view is read.
void pointerParameterPointeeDead() {
  std::string_view result;
  {
    const std::string owner = "abc";
    const pointers::record value{owner};
    result = pointers::pointeeText(&value);
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(result);
}

// END CASE

// CASE: lambda.copy_capture_dead
// PAIR: lambda.copy_capture
// SOURCE: services/runtime-cpp/tests/pty_response_queue_test.cpp :: testConcurrentResponses
// STATUS: implemented
// CONTRACT: A closure holds copies of its by-value captures, including the borrows of a copied view.
// SCENARIO: The captured view's source dies before the closure's result is read.
void lambdaCopyCaptureDead() {
  std::string_view result;
  {
    const std::string owner = "abc";
    const std::string_view view = owner;
    const auto read = [view] { return view; };
    result = read();
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(result);
}

// END CASE

// CASE: lambda.copy_capture_live
// PAIR: lambda.copy_capture
// SOURCE: services/runtime-cpp/tests/pty_response_queue_test.cpp :: testConcurrentResponses
// STATUS: implemented
// CONTRACT: A closure's result may be read while its captured view's source is alive.
// SCENARIO: The source outlives the read; accept.
void lambdaCopyCaptureLive(std::string_view text) {
  const auto read = [text] { return text; };
  pointers::observe(read());
}

// END CASE

// CASE: lambda.reference_capture_dead
// PAIR: lambda.reference_capture
// SOURCE: services/runtime-cpp/cli/server_options.hpp :: ServerOptions::parse
// STATUS: implemented
// CONTRACT: A by-reference capture is the caller's own variable when the enclosing function calls the lambda.
// SCENARIO: The lambda returns a view of a captured owner that dies before the read.
void lambdaReferenceCaptureDead() {
  std::string_view result;
  {
    const std::string owner = "abc";
    const auto read = [&owner] { return std::string_view{owner}; };
    result = read();
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(result);
}

// END CASE

// CASE: lambda.reference_capture_contents
// PAIR: lambda.reference_capture
// SOURCE: services/runtime-cpp/cli/server_options.hpp :: ServerOptions::parse
// STATUS: implemented
// CONTRACT: Contents read through a by-reference capture do not borrow the captured variable's storage.
// SCENARIO: The result views the argument array, not the local span that was captured; accept.
pointers::options lambdaReferenceCaptureContents(std::span<const char *const> arguments) {
  pointers::options result;
  std::size_t index = 0;
  const auto next = [&]() -> std::string_view { return arguments[index++]; };
  result.value = next();
  return result;
}

// END CASE

// CASE: lambda.write_capture_dead
// PAIR: lambda.write_capture
// SOURCE: services/runtime-cpp/cli/server_options.hpp :: ServerOptions::parse
// STATUS: implemented
// CONTRACT: A write to a by-reference capture updates the caller's variable.
// SCENARIO: The lambda stores a view whose source dies before the caller reads it.
void lambdaWriteCaptureDead() {
  std::string_view slot;
  {
    const std::string owner = "abc";
    const auto store = [&slot](std::string_view text) { slot = text; };
    store(owner);
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(slot);
}

// END CASE

// CASE: lambda.write_capture_live
// PAIR: lambda.write_capture
// SOURCE: services/runtime-cpp/cli/server_options.hpp :: ServerOptions::parse
// STATUS: implemented
// CONTRACT: A view stored through a by-reference capture may be read while its source is alive.
// SCENARIO: The source outlives the caller's read; accept.
void lambdaWriteCaptureLive(std::string_view text) {
  std::string_view slot;
  const auto store = [&slot](std::string_view value) { slot = value; };
  store(text);
  pointers::observe(slot);
}

// END CASE

// CASE: pointer.by_value_parameter_local
// PAIR: pointer.parameter_write
// SOURCE: services/gui-cpp/tests/session_fixture.hpp :: deliverSingleCell
// STATUS: implemented
// CONTRACT: A by-value parameter is the callee's own copy; filling it with local views does not reach the caller.
// SCENARIO: The parameter is filled with a view of a local array and consumed before returning; accept.
void pointerByValueParameterLocal(pointers::frame frame) {
  const std::array<int, 1> values{1};
  frame.values = values;
  pointers::deliver(frame);
}

// END CASE

// CASE: pointer.reference_parameter_escape
// PAIR: pointer.parameter_write
// SOURCE: services/gui-cpp/tests/session_fixture.hpp :: deliverSingleCell
// STATUS: implemented
// CONTRACT: A write through a reference parameter reaches the caller and must outlive the call.
// SCENARIO: The caller's frame receives a view of a local array.
void pointerReferenceParameterEscape(pointers::frame &frame) {
  const std::array<int, 1> values{1};
  frame.values = values; // expected-error [tbc-dangling-borrow]
}

// END CASE

namespace pointers {
  class view_reader {
  public:
    explicit view_reader(std::string_view &view)
        : view_(view) {}

    [[nodiscard]] std::string_view read() const {
      return view_;
    }

  private:
    std::string_view &view_;
  };

  struct buffer {
    std::array<char, 16> bytes{};

    std::span<const char> peek() const {
      return bytes;
    }
  };

  class buffer_stream {
  public:
    explicit buffer_stream(buffer &source)
        : source_(source) {}

    std::span<const char> peek() const {
      return source_.peek();
    }

  private:
    buffer &source_;
  };

  template <typename Stream>
  class gated_stream {
  public:
    explicit gated_stream(Stream &stream)
        : stream_(stream) {}

    std::span<const char> peek() const {
      return stream_.peek();
    }

  private:
    Stream &stream_;
  };

  struct relay {
    const char *pending = nullptr;

    template <typename Source>
    void advance(Source &source) {
      pending = source.peek().data();
    }
  };

  struct sink {
    std::string &target;
  };

  void attach(record *target, std::string_view text) {
    target->text = text;
  }

  void show(const record *target) {
    observe(target->text);
  }
}

// CASE: pointer.reference_field_read
// PAIR: pointer.reference_field
// SOURCE: services/runtime-cpp/tls/stream.hpp :: TlsStream::peekView
// STATUS: implemented
// CONTRACT: Reading a reference field yields what its referent holds, not the referent itself.
// SCENARIO: The local view refers to the caller's string, so the view read back may be returned; accept.
std::string_view pointerReferenceFieldRead(const std::string &text) {
  std::string_view local = text;
  const pointers::view_reader reader{local};
  return reader.read();
}

// END CASE

// CASE: pointer.reference_field_dead
// PAIR: pointer.reference_field
// SOURCE: services/runtime-cpp/tls/stream.hpp :: TlsStream::peekView
// STATUS: implemented
// CONTRACT: Reading a reference field yields what its referent holds, not the referent itself.
// SCENARIO: The view read back refers to a local string that dies on return.
std::string_view pointerReferenceFieldDead() {
  const std::string text = "temporary";
  std::string_view local = text;
  const pointers::view_reader reader{local};
  return reader.read(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: pointer.nested_reference_wrapper
// PAIR: pointer.nested_reference
// SOURCE: services/runtime-cpp/proxy/application_relay.hpp :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: Wrappers that hold references to streams reach the buffer the innermost one designates.
// SCENARIO: The relay keeps a pointer into the caller's buffer through two local wrappers; accept.
void pointerNestedReferenceWrapper(pointers::buffer &source, pointers::relay &out) {
  pointers::buffer_stream stream{source};
  pointers::gated_stream gated{stream};
  out.advance(gated);
}

// END CASE

// CASE: pointer.nested_reference_dead
// PAIR: pointer.nested_reference
// SOURCE: services/runtime-cpp/proxy/application_relay.hpp :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: Wrappers that hold references to streams reach the buffer the innermost one designates.
// SCENARIO: The relay keeps a pointer into a local buffer past its lifetime.
void pointerNestedReferenceDead(pointers::relay &out) {
  pointers::buffer source;
  pointers::buffer_stream stream{source};
  pointers::gated_stream gated{stream};
  out.advance(gated);
} // expected-error [tbc-dangling-borrow]

// END CASE

// CASE: pointer.aggregate_reference_member
// PAIR: pointer.aggregate_reference
// SOURCE: services/runtime-cpp/http1/intercepted_relay.hpp :: Http1InterceptedRelay::Sink
// STATUS: implemented
// CONTRACT: An aggregate's reference member is bound to its initializer, so operations through it reach the referent.
// SCENARIO: Clearing the string through the member invalidates an earlier view of it.
void pointerAggregateReferenceMember(std::string &text) {
  const std::string_view view = text;
  pointers::sink target{text};
  target.target.clear(); // expected-error [tbc-invalidated-borrow]
  pointers::observe(view);
}

// END CASE

// CASE: pointer.aggregate_reference_read
// PAIR: pointer.aggregate_reference
// SOURCE: services/runtime-cpp/http1/intercepted_relay.hpp :: Http1InterceptedRelay::Sink
// STATUS: implemented
// CONTRACT: An aggregate's reference member is bound to its initializer, so operations through it reach the referent.
// SCENARIO: The view is read before the string is cleared through the member; accept.
void pointerAggregateReferenceRead(std::string &text) {
  const std::string_view view = text;
  pointers::sink target{text};
  pointers::observe(view);
  target.target.clear();
}

// END CASE

// CASE: pointer.parameter_write_dead
// PAIR: pointer.parameter_write_through
// SOURCE: services/runtime-cpp/proxy/flow_state.hpp :: FlowGate::write
// STATUS: implemented
// CONTRACT: A write through a pointer parameter lands in the object the argument designates.
// SCENARIO: The record behind the pointer keeps a view of a string that dies before it is read.
void pointerParameterWriteDead() {
  pointers::record local;
  pointers::record *target = &local;
  {
    const std::string text = "temporary";
    pointers::attach(target, text);
  } // expected-error [tbc-invalidated-borrow]
  pointers::observe(local.text);
}

// END CASE

// CASE: pointer.parameter_write_live
// PAIR: pointer.parameter_write_through
// SOURCE: services/runtime-cpp/proxy/flow_state.hpp :: FlowGate::write
// STATUS: implemented
// CONTRACT: A write through a pointer parameter lands in the object the argument designates.
// SCENARIO: The record behind the pointer is read while the string lives; accept.
void pointerParameterWriteLive() {
  pointers::record local;
  pointers::record *target = &local;
  const std::string text = "temporary";
  pointers::attach(target, text);
  pointers::observe(local.text);
}

// END CASE

// CASE: pointer.parameter_read_invalidated
// PAIR: pointer.parameter_read_through
// SOURCE: services/runtime-cpp/proxy/flow_state.hpp :: FlowStream::write
// STATUS: implemented
// CONTRACT: A callee that reads through a pointer parameter uses what the argument's pointee holds.
// SCENARIO: The record's view is invalidated before the callee reads it through the pointer.
void pointerParameterReadInvalidated(std::string &text) {
  const pointers::record local{text};
  text.clear(); // expected-error [tbc-invalidated-borrow]
  pointers::show(&local);
}

// END CASE

// CASE: pointer.parameter_read_live
// PAIR: pointer.parameter_read_through
// SOURCE: services/runtime-cpp/proxy/flow_state.hpp :: FlowStream::write
// STATUS: implemented
// CONTRACT: A callee that reads through a pointer parameter uses what the argument's pointee holds.
// SCENARIO: The callee reads the record before the string is cleared; accept.
void pointerParameterReadLive(std::string &text) {
  const pointers::record local{text};
  pointers::show(&local);
  text.clear();
}

// END CASE
