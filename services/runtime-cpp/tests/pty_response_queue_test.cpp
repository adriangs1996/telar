#include "check.hpp"
#include "terminal/pty_response_queue.hpp"
#include <thread>
#include <atomic>
#include <vector>

using namespace telar::runtime;

static void testQueueBoundaries() {
  PtyResponseQueue queue;
  check(queue.empty() && !queue.peek());
  check(queue.push({}) && queue.peek() && queue.readable().empty());
  queue.consume(0);
  check(queue.empty());

  std::array<std::uint8_t, PtyResponseQueue::message_byte_capacity + 1> payload;
  std::fill(payload.begin(), payload.end(), 41);
  check(!queue.push(payload) && queue.snapshot().dropped == 1);
  const auto response = std::span{payload}.first(PtyResponseQueue::message_byte_capacity);
  for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    payload.front() = static_cast<std::uint8_t>(index);
    check(queue.push(response));
  }
  check(!queue.push(response) && queue.snapshot().dropped == 2);
  check(queue.snapshot().messages == PtyResponseQueue::message_capacity);
  check(queue.snapshot().bytes == PtyResponseQueue::message_capacity * response.size());

  queue.consume(3);
  check(queue.snapshot().messages == PtyResponseQueue::message_capacity);
  check(queue.readable().size() == response.size() - 3);
  check(!queue.push(response));
  queue.consume(response.size() - 3);
  check(queue.readable().front() == 1);
  payload.front() = 99;
  check(queue.push(response));
  for (std::size_t index = 1; index < PtyResponseQueue::message_capacity; ++index) {
    check(queue.readable().front() == index);
    queue.consume(response.size());
  }
  check(queue.readable().front() == 99);
  queue.clear();
  check(queue.empty() && queue.snapshot().bytes == 0 && queue.snapshot().dropped == 3);
}

static void testConcurrentResponses() {
  PtyResponseQueue queue;
  constexpr std::uint32_t responses_per_producer = 10000;
  std::array<std::uint32_t, 2> received{};
  const auto produce = [&](std::uint32_t producer) {
    for (std::uint32_t sequence = 0; sequence < responses_per_producer; ++sequence) {
      const std::array<std::uint32_t, 2> payload{producer, sequence};
      const auto bytes = std::span{reinterpret_cast<const std::uint8_t *>(payload.data()), sizeof(payload)};
      while (!queue.tryPush(bytes)) {
        std::this_thread::yield();
      }
    }
  };
  std::jthread first{produce, 0};
  std::jthread second{produce, 1};
  while (received[0] + received[1] != 2 * responses_per_producer) {
    const auto response = queue.peek();
    if (!response) {
      std::this_thread::yield();
      continue;
    }

    std::array<std::uint32_t, 2> payload;
    check(response->size() == sizeof(payload));
    std::memcpy(payload.data(), response->data(), response->size());
    check(payload[0] < received.size() && payload[1] == received[payload[0]]);
    ++received[payload[0]];
    std::this_thread::yield();
    check(std::memcmp(payload.data(), response->data(), response->size()) == 0);
    queue.consume(response->size());
  }
  check(queue.empty() && queue.snapshot().dropped == 0);
}

static void testOwnedResponseLifetime() {
  PtyResponseQueue queue;
  auto storage = std::make_shared<std::vector<std::uint8_t>>(8192, 17);
  const std::weak_ptr<std::vector<std::uint8_t>> lifetime = storage;
  check(queue.tryPushOwned(*storage, storage));
  storage.reset();
  queue.consume(8191);
  check(!lifetime.expired() && queue.readable().size() == 1 && queue.readable()[0] == 17);
  queue.consume(1);
  check(lifetime.expired() && queue.empty());
  check(queue.snapshot().dropped == 0);
  for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    check(queue.tryPush({}));
  }
  check(!queue.tryPush({}) && queue.snapshot().dropped == 0);
  queue.clear();
}

static void testBatchedResponses() {
  PtyResponseQueue queue;
  auto storage = std::make_shared<std::vector<std::uint8_t>>(8192, 42);
  const std::weak_ptr<std::vector<std::uint8_t>> lifetime = storage;
  {
    PtyResponseQueue::Producer producer{queue};
    check(producer.tryPush({}));
    check(producer.tryPushOwned(*storage, storage));
    producer.release();
    check(queue.tryPush(std::span{*storage}.first(3)));
    check(producer.tryPush(std::span{*storage}.first(2)));
  }
  storage.reset();
  auto batch = queue.peekBatch();
  check(batch.count == 4 && batch.bytes == 8197 && batch.messages[1][8191] == 42);
  queue.consumeBytes(8191);
  check(!lifetime.expired());
  batch = queue.peekBatch();
  check(batch.count == 3 && batch.bytes == 6 && batch.messages[0].size() == 1);
  queue.consumeBytes(4);
  check(lifetime.expired());
  batch = queue.peekBatch();
  check(batch.count == 1 && batch.bytes == 2);
  queue.consumeBytes(2);
  check(queue.empty());
}

static void testClosedGeneration() {
  PtyResponseQueue queue;
  auto storage = std::make_shared<std::vector<std::uint8_t>>(8192, 42);
  const std::weak_ptr<std::vector<std::uint8_t>> lifetime = storage;
  check(queue.tryPushOwned(*storage, storage));
  storage.reset();
  std::atomic<bool> callback_ready = false;
  std::atomic<bool> resume_callback = false;
  std::jthread worker{[&] {
    callback_ready.store(true, std::memory_order_release);
    while (!resume_callback.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
    const std::array<std::uint8_t, 4> response{27, '[', '0', 'n'};
    check(!queue.push(response));
    check(!queue.tryPush(response));
    PtyResponseQueue::Producer producer{queue};
    check(!producer.tryPush(response));
  }};
  while (!callback_ready.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  queue.close();
  check(lifetime.expired());
  resume_callback.store(true, std::memory_order_release);
  worker.join();
  queue.clear();
  check(queue.empty() && !queue.hasCapacity());
  check(queue.snapshot().dropped == 0);
  check(!queue.tryPushOwned({}, std::make_shared<int>(1)));
}

void testPtyResponseQueue() {
  testQueueBoundaries();
  testConcurrentResponses();
  testOwnedResponseLifetime();
  testBatchedResponses();
  testClosedGeneration();
}
