module;
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <thread>
#include <vector>
export module runtime_receiver_worker;

import app_context;

export struct RuntimeReceiverWorker {

  static RuntimeReceiverWorker init(const AppContext &context) {
    RuntimeReceiverWorker worker{};
    worker.reader = std::jthread{[&](std::stop_token stop) {
      std::vector<telar::Byte> buffer(telar::max_payload_size);

      while (!stop.stop_requested()) {
        const auto payload = context.client.receiveFrame(buffer);

        switch (static_cast<telar::ServerTag>(payload.front())) {
        case telar::ServerTag::workspace_snapshot: {
          break;
        }
        }
      }
    }};

    return worker;
  }

  void wait() { reader.join(); }

private:
  std::jthread reader;
};
