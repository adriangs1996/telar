
#include <cassert>
#include <thread>
#include <variant>

import app_context;
import debug.support.random_data;

int main() {
  EventQueue emulated_event_queue{};
  {
    // test that an empty queue returns 0 events
    int count = 0;
    for (auto event : emulated_event_queue.drain()) {
      count++;
    }
    assert(count == 0);
  }

  {
    // Test that events arrive and can be drained sequentially
    auto keys = randomAscii(100);
    int pushes = 0;
    for (auto key : keys) {
      if (emulated_event_queue.push(KeyPress{.key = key})) {
        pushes++;
      }
    }

    assert(pushes == 100);

    int count = 0;
    for (auto event : emulated_event_queue.drain()) {
      count++;
    }
    assert(count == 100);
    assert(emulated_event_queue.count() == 0);
  }

  {
    // Stress test with a concurrent workload
    const std::size_t elements = 10000000;
    auto keys = randomAscii(elements);
    std::atomic<bool> producer_finish{false};
    int read = 0;
    std::vector<char> read_sequence{};

    auto producer = std::jthread{[&](std::stop_token) {
      for (auto key : keys) {
        while (!emulated_event_queue.push(KeyPress{key})) {
          std::this_thread::yield();
        }
      }

      producer_finish.store(true);
    }};

    auto consumer = std::jthread{[&](std::stop_token) {
      while (!producer_finish.load()) {
        for (auto event : emulated_event_queue.drain()) {
          read++;
          read_sequence.push_back(std::get<KeyPress>(event).key);
        }
      }

      for (auto event : emulated_event_queue.drain()) {
        read++;
        read_sequence.push_back(std::get<KeyPress>(event).key);
      }
    }};

    producer.join();
    consumer.join();

    assert(read == elements);
    for (auto i = 0; i < read; ++i) {
      assert(read_sequence[i] == keys[i]);
    }
  }

  {
    // Run a test with two producers
    const std::size_t elements = 1000000;
    auto keys = randomAscii(elements);
    auto keys2 = randomAscii(elements);
    std::atomic<bool> producer1_finish{false};
    std::atomic<bool> producer2_finish{false};
    int read = 0;

    auto producer1 = std::jthread{[&](std::stop_token) {
      for (auto key : keys) {
        while (!emulated_event_queue.push(KeyPress{key})) {
          std::this_thread::yield();
        }
      }

      producer1_finish.store(true);
    }};

    auto producer2 = std::jthread{[&](std::stop_token) {
      for (auto key : keys2) {
        while (!emulated_event_queue.push(KeyPress{key})) {
          std::this_thread::yield();
        }
      }

      producer2_finish.store(true);
    }};

    auto consumer = std::jthread{[&](std::stop_token) {
      while (!producer1_finish.load() || !producer2_finish.load()) {
        for (auto event : emulated_event_queue.drain()) {
          read++;
        }
      }

      for (auto event : emulated_event_queue.drain()) {
        read++;
      }
    }};

    producer1.join();
    producer2.join();
    consumer.join();

    assert(read == elements * 2);
  }

  return 0;
}
