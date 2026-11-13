export module telar.runtime.tests.backpressure;

import std;
export import telar.runtime.tests.check;
export import telar.runtime.tests.protocol_peer;

export {
inline void waitForText(ProtocolPeer &peer, std::uint64_t pane, std::string_view expected) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (std::chrono::steady_clock::now() < deadline) {
    if (peer.exchange<telar::PaneText>(telar::ReadPane{.request_id = 1, .pane_id = pane, .rows = 24}).text == expected) {
      return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  }
  throw std::runtime_error{"Pane text did not reach the expected state"};
}

inline void blockOutput(ProtocolPeer &slow, ProtocolPeer &observer, ProtocolPeer &control) {
  const std::string text(512, 'n');
  const telar::ShowNotification notification{.request_id = 10, .notification = telar::NotificationBody{.title = "Backpressure", .message = text}};
  bool full = false;
  for (unsigned index = 0; index < 4096; ++index) {
    const auto shown = control.exchange<telar::NotificationShown>(notification);
    check(observer.receive<telar::Notification>().message == text);
    if (shown.delivered_clients == 1) {
      full = true;
      break;
    }
    check(shown.delivered_clients == 2);
  }
  check(full);

  // Free only a small part of the 128 pending responses. The remaining
  // notifications keep later reads behind socket backpressure.
  for (unsigned index = 0; index < 32; ++index) {
    check(slow.receive<telar::Notification>().message == text);
  }
  for (unsigned attempt = 0; attempt < 100; ++attempt) {
    const auto shown = control.exchange<telar::NotificationShown>(notification);
    check(observer.receive<telar::Notification>().message == text);
    if (shown.delivered_clients == 2) {
      return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  }
  throw std::runtime_error{"The blocked client did not release response capacity"};
}

inline void barrier(ProtocolPeer &slow, ProtocolPeer &observer) {
  slow.send(telar::ShowNotification{.request_id = 99, .notification = telar::NotificationBody{.title = "Deferred requests admitted"}});
  check(observer.receive<telar::Notification>().title == "Deferred requests admitted");
}
}
