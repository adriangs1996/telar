import std;
import telar.testing;
import telar.runtime.traffic.control_protocol;
import telar.runtime.vocabulary.frames;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  namespace control = telar::runtime::traffic::control;

  // A redirect.start request as a local peer frames it, declaring `targets` targets and `processes`
  // selected processes and carrying that many of each.
  std::vector<Byte> request(std::size_t targets, std::size_t processes) {
    std::vector<Byte> buffer(control::Limits::request_bytes);
    plugins::FrameWriter writer{std::span{buffer}};

    writer.integer(control::Protocol::selection_magic);
    writer.tag(control::Operation::redirect_start);
    writer.integer(static_cast<Byte>(targets));
    for (std::size_t index = 0; index < targets; ++index) {
      writer.text("fixture.test");
    }

    writer.integer(static_cast<Byte>(processes));
    for (std::size_t index = 0; index < processes; ++index) {
      writer.integer(static_cast<std::uint32_t>(index + 1));
    }

    const auto written = writer.finish();

    return {written.begin(), written.end()};
  }

  bool rejected(std::span<const Byte> bytes) {
    try {
      static_cast<void>(control::Protocol::request(bytes));
    } catch (const EncodingError&) {
      return true;
    }

    return false;
  }

  // The counts a local peer declares size the request's fixed arrays: one past them is refused
  // before any entry is read into them.
  void testRequestDecodeBounds() {
    const auto accepted = control::Protocol::request(request(control::Limits::targets, control::Limits::processes));

    check(accepted.target_count == control::Limits::targets && accepted.process_count == control::Limits::processes);
    for (const std::size_t count : {control::Limits::targets + 1, std::size_t{std::numeric_limits<Byte>::max()}}) {
      check(rejected(request(count, 0)));
    }

    for (const std::size_t count : {control::Limits::processes + 1, std::size_t{std::numeric_limits<Byte>::max()}}) {
      check(rejected(request(1, count)));
    }
  }

  const telar::testing::Case case_request_decode_bounds{"traffic_control.request_decode_bounds", testRequestDecodeBounds};

}
