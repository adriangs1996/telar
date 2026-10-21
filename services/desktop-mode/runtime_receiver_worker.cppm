module;
#include "runtime_session.hpp"
#include <stop_token>
#include <thread>
#include <utility>
export module runtime_receiver_worker;

import app_context;

export struct RuntimeReceiverWorker {
  template <Notifier INotifier>
  static RuntimeReceiverWorker init(const AppContext<INotifier> &context) {
    RuntimeReceiverWorker worker{};
    worker.reader = std::jthread{[&context](std::stop_token stop) {
      std::stop_callback interrupt{stop, [&context]() noexcept {
                                     context.runtime.interrupt();
                                   }};

      context.runtime.run(stop, [&context, stop](RuntimeState state) {
        Event event{RuntimeUpdated{std::move(state)}};

        while (!stop.stop_requested()) {
          if (context.input_queue.push(std::move(event))) {
            break;
          }

          std::this_thread::yield();
        }
      });
    }};

    return worker;
  }

  void stop() {
    reader.request_stop();

    if (reader.joinable()) {
      reader.join();
    }
  }

private:
  std::jthread reader;
};
