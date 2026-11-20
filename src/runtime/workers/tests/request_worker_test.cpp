#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <poll.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.workers.request_worker;
import telar.wire.clients;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.runtime.transport.connection;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A message far longer than any reply carries.
  const std::string long_failure(2048, 'f');

  // Fails the first request with an exception it does not own, the second with a request error,
  // and answers the rest.
  class FailingService {
  public:
    template <Allocator Memory>
    void process(std::span<const Byte> payload, EncodedReply<Memory>& reply) {
      ds::Array<Byte, 256> bytes;
      DecodeStorage storage{bytes.viewMut()};
      const auto identity = Codec::decode<QueryClients>(payload, storage).request_id;

      if (identity == 1) {
        throw std::runtime_error{"secret internal detail"};
      }

      if (identity == 2) {
        throw RequestError{FailureCode::permission_denied, long_failure.c_str()};
      }

      reply.send(RequestCompleted{.request_id = identity});
    }
  };

  struct Reply {
    std::uint64_t request_id;
    ds::Option<FailureCode> failure;
    std::string message;
  };

  // A failing service answers its client with a failure instead of taking the worker down: what it
  // meant to say reaches the client, cut to fit a reply, and an internal error's text does not.
  void testServiceFailureReplies() {
    SystemAllocator memory;
    FailingService service;
    RequestWorker worker{memory, service};

    for (std::uint64_t identity = 1; identity <= 3; ++identity) {
      worker.submit(1, QueryClients{.request_id = identity});
    }

    std::vector<Reply> replies;

    while (replies.size() < 3) {
      pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};

      check(::poll(&ready, 1, 2000) == 1);
      worker.collect([&](std::uint64_t, ClientTag, std::span<const Byte> payload) {
        ds::Array<Byte, 4096> bytes;
        DecodeStorage storage{bytes.viewMut()};

        if (payload.front() == static_cast<Byte>(ServerTag::request_failed)) {
          const auto failed = Codec::decode<RequestFailed>(payload, storage);

          replies.push_back({failed.request_id, failed.code, std::string{failed.message}});
        } else {
          replies.push_back({Codec::decode<RequestCompleted>(payload, storage).request_id, ds::none, {}});
        }
      });
    }

    std::ranges::sort(replies, {}, &Reply::request_id);
    check(replies[0].failure == FailureCode::invalid_request && !replies[0].message.contains("secret"));
    check(replies[1].failure == FailureCode::permission_denied && !replies[1].message.empty() && long_failure.starts_with(replies[1].message));
    check(replies[2].request_id == 3 && !replies[2].failure);
  }

  const telar::testing::Case case_service_failure_replies{"request_worker.service_failure_replies", testServiceFailureReplies};

}
