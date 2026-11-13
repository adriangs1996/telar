
#include <cstdio>
import std;
import telar.runtime.tests.check;
import telar.runtime.tests.protocol_peer;

using namespace telar;

static void suggestion(ProtocolPeer &peer, std::ostream &dump, std::uint64_t pane, SuggestionStatus expected) {
  const auto reply = peer.exchange<CommandSuggestion>(SuggestCommand{.request_id = 2, .pane_id = pane, .text = "show git status"});
  if (reply.status != expected) {
    throw std::runtime_error{"Suggestion status for pane " + std::to_string(pane) + ": got " + std::to_string(static_cast<unsigned>(reply.status)) + ", expected " + std::to_string(static_cast<unsigned>(expected))};
  }
  check(reply.text == (expected == SuggestionStatus::ready ? "git status" : ""));
  peer.record(dump, reply);
}

static void editorFailure(ProtocolPeer &peer, std::ostream &dump, const OpenEditor &request) {
  if (request.pane_generation == 0) {
    throw std::runtime_error{"Missing pane generation for editor request " + std::to_string(request.request_id)};
  }
  peer.send(request);
  const auto reply = peer.receive<RequestFailed>();
  check(reply.request_id == request.request_id);
  peer.record(dump, reply);
}

static void admission(const char *socket, std::ostream &dump, bool configured) {
  ProtocolPeer peer{socket};
  const auto unavailable = configured ? SuggestionStatus::failed : SuggestionStatus::unavailable;
  const auto invalid_identity = std::numeric_limits<std::uint64_t>::max();
  suggestion(peer, dump, invalid_identity, unavailable);
  editorFailure(peer, dump, OpenEditor{.request_id = 3, .pane_id = invalid_identity, .pane_generation = 1, .editor = "nvim", .path = "/tmp"});

  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const auto pane = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  suggestion(peer, dump, pane.pane_id, configured ? SuggestionStatus::ready : SuggestionStatus::unavailable);
  editorFailure(peer, dump, OpenEditor{.request_id = 4, .pane_id = pane.pane_id, .pane_generation = pane.pane_generation + 1, .editor = "nvim", .path = "/tmp"});
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }

  try {
    const std::string_view workload{argv[2]};
    check(workload == "service-admission" || workload == "service-admission-engine");
    std::ofstream dump{argv[4], std::ios::binary};
    const auto started = std::chrono::steady_clock::now();
    for (unsigned iteration = 0; iteration < std::stoul(argv[3]); ++iteration) {
      admission(argv[1], dump, workload == "service-admission-engine");
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
