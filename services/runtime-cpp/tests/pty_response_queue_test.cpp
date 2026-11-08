#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory;
import telar.runtime.terminal.control;
import telar.runtime.tests.check;
import telar.runtime.terminal.osc_scanner;

using namespace telar;
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
  check(batch.count == 4 && batch.bytes == 8197 && batch.message(1)[8191] == 42);
  queue.consumeBytes(8191);
  check(!lifetime.expired());
  batch = queue.peekBatch();
  check(batch.count == 3 && batch.bytes == 6 && batch.message(0).size() == 1);
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

static void testResponseOutbox() {
  SystemAllocator system;
  BudgetAllocator memory{system, 4096};
  const auto shared_queue = std::make_shared<PtyResponseQueue>();
  auto &queue = *shared_queue;
  const std::array<std::uint8_t, 3> ack{'A', 'C', 'K'};
  {
    ResponseOutbox first{memory, shared_queue};
    ResponseOutbox second{memory, shared_queue};
    first.append(ack);
    second.append(ack);
    check(first.drain());
    PtyResponseQueue::Producer native{queue};
    check(!native.tryPush(ack));
    check(second.drain());
    check(native.tryPush(ack));
    native.release();
    check(queue.snapshot().messages == 3);
    queue.clear();
  }
  auto storage = std::make_shared<std::vector<std::uint8_t>>(PtyResponseQueue::total_byte_capacity - 1, 42);
  check(queue.tryPushOwned(*storage, storage));
  {
    ResponseOutbox outbox{memory, shared_queue};
    outbox.append(ack);
    check(queue.hasCapacity() && !queue.hasCapacityFor(ack.size()));
    check(!outbox.drain() && outbox.nextSize() == ack.size());
    queue.consume(1);
    check(!queue.hasCapacityFor(ack.size()));
    queue.consume(2);
    check(queue.hasCapacityFor(ack.size()) && outbox.drain());
    queue.clear();
    check(!outbox.pending());
  }
  {
    ResponseOutbox outbox{memory, shared_queue};
    const std::array<std::uint8_t, 1024> message{};
    for (unsigned index = 0; index < 3; ++index) {
      outbox.append(message);
    }
    check(memory.liveBytes() == 4096);
    bool failed = false;
    try {
      outbox.append(message);
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    check(failed && outbox.pending());
    check(outbox.drain() && queue.snapshot().messages == 3);
    check(memory.liveBytes() == 0);
    queue.clear();
    outbox.append(ack);
    queue.close();
    check(outbox.drain() && !outbox.pending());
    outbox.append(ack);
    check(!outbox.pending() && queue.empty());
  }
  check(memory.liveBytes() == 0 && queue.snapshot().dropped == 0);
}

static void testWorkerPublicationFailure() {
  PtyResponseQueue queue;
  auto storage = std::make_shared<std::vector<std::uint8_t>>(8192, 42);
  const std::weak_ptr<std::vector<std::uint8_t>> lifetime = storage;
  check(queue.tryPushOwned(*storage, storage));
  storage.reset();
  const auto borrowed = queue.peekBatch();
  std::jthread worker{[&] { queue.stopProducing(); }};
  worker.join();
  check(queue.closed() && !lifetime.expired());
  check(borrowed.count == 1 && borrowed.message(0).front() == 42 && borrowed.message(0).back() == 42);
  check(!queue.tryPush({}));
  queue.close();
  check(lifetime.expired() && queue.empty());
}

template <bool Fixed = false>
static void testWorkerPriority() {
  const auto shared_queue = std::make_shared<PtyResponseQueue>();
  auto &queue = *shared_queue;
  const std::array<std::uint8_t, Fixed ? 4 : 1> native_bytes{'N'};
  const auto publish = [](PtyResponseQueue::Producer &producer, const auto &bytes) {
    if constexpr (Fixed) {
      return producer.tryPushFixed(bytes);
    } else {
      return producer.tryPush(bytes);
    }
  };
  const std::array<std::uint8_t, 3> ack{'A', 'C', 'K'};
  for (unsigned index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    check(queue.tryPush(native_bytes));
  }
  std::atomic<bool> staged = false;
  std::atomic<bool> drained = false;
  std::atomic<std::size_t> yielded = 0;
  std::jthread worker{[&] {
    SystemAllocator memory;
    ResponseOutbox outbox{memory, shared_queue};
    for (unsigned index = 0; index < 100; ++index) {
      outbox.append(ack);
    }
    staged.store(true, std::memory_order_release);
    while (!outbox.drain()) {
      std::this_thread::yield();
    }
    drained.store(true, std::memory_order_release);
  }};
  while (!staged.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  {
    PtyResponseQueue::Producer native{queue};
    check(!publish(native, native_bytes));
  }
  std::jthread native{[&] {
    while (!drained.load(std::memory_order_acquire)) {
      PtyResponseQueue::Producer producer{queue};
      if (!publish(producer, native_bytes)) {
        yielded.fetch_add(1, std::memory_order_relaxed);
      }
      producer.release();
      std::this_thread::yield();
    }
  }};
  unsigned received = 0;
  while (!drained.load(std::memory_order_acquire) || !queue.empty()) {
    if (const auto message = queue.peek()) {
      if (message->front() == ack.front()) {
        check(message->size() == ack.size() && std::equal(message->begin(), message->end(), ack.begin()));
        ++received;
      } else {
        check(message->size() == native_bytes.size() && std::equal(message->begin(), message->end(), native_bytes.begin()));
      }
      queue.consume(message->size());
    } else {
      std::this_thread::yield();
    }
  }
  worker.join();
  native.join();
  check(received == 100 && queue.snapshot().dropped == 0);
}

static void testBorrowedBatchWrap() {
  PtyResponseQueue queue;
  const std::array<std::uint8_t, 4> prefix{1, 2, 3, 4};
  for (std::size_t index = 0; index < PtyResponseQueue::message_capacity - 2; ++index) {
    check(queue.tryPush(prefix));
  }
  queue.consumeBytes(prefix.size() * (PtyResponseQueue::message_capacity - 2));
  check(queue.empty());
  for (unsigned index = 0; index < 4; ++index) {
    check(queue.tryPush(prefix));
  }
  queue.consumeBytes(1);
  const auto batch = queue.peekBatch();
  check(batch.first.size() == 2 && batch.second.size() == 2);
  check(batch.count == 4 && batch.bytes == 15);
  check(batch.message(0).size() == 3 && batch.message(0).front() == 2);

  std::atomic<bool> done = false;
  std::jthread producer{[&] {
    for (std::size_t index = batch.count; index < PtyResponseQueue::message_capacity; ++index) {
      const std::array<std::uint8_t, 1> suffix{9};
      check(queue.tryPush(suffix));
    }
    done.store(true, std::memory_order_release);
  }};
  do {
    check(batch.count == 4 && batch.bytes == 15);
    for (std::size_t index = 0; index < batch.count; ++index) {
      const auto value = batch.message(index);
      check(value.back() == 4 && value.size() == (index == 0 ? 3u : 4u));
      check(value.front() == (index == 0 ? 2u : 1u));
    }
    std::this_thread::yield();
  } while (!done.load(std::memory_order_acquire));
  producer.join();
  queue.consumeBytes(batch.bytes);
  const auto remaining = queue.peekBatch();
  check(remaining.count == PtyResponseQueue::message_capacity - 4 && remaining.bytes == remaining.count);
  for (std::size_t index = 0; index < remaining.count; ++index) {
    check(remaining.message(index).size() == 1 && remaining.message(index).front() == 9);
  }
  queue.consumeBytes(remaining.bytes);
  check(queue.empty());
}

void testPtyResponseQueue() {
  testQueueBoundaries();
  testConcurrentResponses();
  testOwnedResponseLifetime();
  testBatchedResponses();
  testBorrowedBatchWrap();
  testClosedGeneration();
  testResponseOutbox();
  testWorkerPublicationFailure();
  testWorkerPriority();
  testWorkerPriority<true>();
}
