
import std;
import telar.runtime.terminal.control;

using namespace telar;
using namespace telar::runtime;

struct Operation {
  std::uint32_t kind;
  const std::uint8_t *bytes;
  std::size_t length;
};

extern "C" std::size_t evaluate(const Operation *operations, std::size_t count, std::uint8_t *output) {
  PtyResponseQueue queue;
  std::size_t written = 0;
  for (const auto &operation : std::span{operations, count}) {
    bool accepted = true;
    if (operation.kind == 0) {
      accepted = queue.push({operation.bytes, operation.length});
    } else if (operation.kind == 1) {
      if (const auto response = queue.peek()) {
        queue.consume(response->size());
      }
    } else {
      queue.clear();
    }

    const auto response = queue.peek();
    const auto bytes = response.value_or(std::span<const std::uint8_t>{});
    const auto snapshot = queue.snapshot();
    output[written] = accepted;
    output[written + 1] = static_cast<std::uint8_t>(snapshot.messages);
    output[written + 2] = response.has_value();
    for (unsigned index = 0; index < sizeof(snapshot.dropped); ++index) {
      output[written + 3 + index] = static_cast<std::uint8_t>(snapshot.dropped >> (index * 8));
    }
    output[written + 11] = static_cast<std::uint8_t>(bytes.size());
    output[written + 12] = static_cast<std::uint8_t>(bytes.size() >> 8);
    std::copy(bytes.begin(), bytes.end(), output + written + 13);
    written += 13 + bytes.size();
  }
  return written;
}
