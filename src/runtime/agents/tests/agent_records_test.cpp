import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.agents.screen_inference;
import telar.runtime.agents.snapshot;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr std::string_view uuid = "0123abcd-4567-89ef-0123-456789abcdef";

  std::vector<std::string> resume(AgentProvider provider, std::string_view session, bool in_pane = false) {
    AgentResume record{.provider = provider, .in_pane = in_pane};
    ds::Array<std::string_view, 4> storage;

    record.session.assign(session);
    const auto arguments = resumeArguments(record, storage);

    return {arguments.begin(), arguments.end()};
  }

  void testResumeArgumentsValidateSession() {
    // A checkpoint's session becomes argv typed into a shell: only an id of the agent's shape passes.
    check(validResumeSession(AgentProvider::claude, uuid) && validResumeSession(AgentProvider::codex, uuid));
    check(!validResumeSession(AgentProvider::claude, "--resume"));
    check(!validResumeSession(AgentProvider::claude, "0123abcd-4567-89ef-0123-456789abcde;"));
    check(!validResumeSession(AgentProvider::claude, "0123abcd 4567-89ef-0123-456789abcdef"));
    check(!validResumeSession(AgentProvider::claude, uuid.substr(1)));
    check(!validResumeSession(AgentProvider::unknown, uuid));
    check(validResumeSession(AgentProvider::opencode, "ses_0123456789abAbCdEfGh123456"));
    check(!validResumeSession(AgentProvider::opencode, "ses_0123456789ab-bCdEfGh12345;"));

    check(resume(AgentProvider::claude, uuid) == std::vector<std::string>{"claude", "--resume", std::string{uuid}});
    check(resume(AgentProvider::codex, uuid, true) == std::vector<std::string>{"codex", "resume", "--no-daemon", std::string{uuid}});
    check(resume(AgentProvider::codex, uuid) == std::vector<std::string>{"codex", "resume", std::string{uuid}});
    check(resume(AgentProvider::cursor, uuid) == std::vector<std::string>{"cursor-agent", "--resume", std::string{uuid}});
    check(resume(AgentProvider::claude, "--dangerously-skip-permissions").empty(), "an invalid session produced arguments");
  }

  void testReportTitleRejectsControlBytes() {
    Agent agent{{.id = 1, .generation = 1}};

    check(agent.reportTitle("Clean title"));
    for (const std::string_view invalid : {std::string_view{"x\x1b]0;y\x07"}, std::string_view{"line\nbreak"}, std::string_view{"\xff\xfe"}}) {
      bool refused = false;

      try {
        agent.reportTitle(invalid);
      } catch (const EncodingError&) {
        refused = true;
      }

      check(refused, "a title with control bytes or invalid UTF-8 was accepted");
      check(agent.title.view() == "Clean title", "a refused title replaced the agent's");
    }

    bool refused = false;

    try {
      agent.reportTitle(std::string(97, 't'));
    } catch (const EncodingError&) {
      refused = true;
    }

    check(refused && agent.title.view() == "Clean title");
  }

  void testRegistryCapacity() {
    SystemAllocator memory;
    AgentRegistry<SystemAllocator> registry{memory};

    for (std::uint64_t pane = 1; pane <= AgentRegistry<SystemAllocator>::capacity; ++pane) {
      registry.ensure(pane, 1);
    }

    bool refused = false;

    try {
      registry.ensure(AgentRegistry<SystemAllocator>::capacity + 1, 1);
    } catch (const RequestError& error) {
      refused = error.code() == FailureCode::resource_limit;
    }

    check(refused, "the registry took more agents than a snapshot holds");
    check(registry.ensure(5, 1).pane == 5 && registry.records().size() == AgentRegistry<SystemAllocator>::capacity);
  }

  const telar::testing::Case case_resume_arguments_validate_session{"agent_records.resume_arguments_validate_session", testResumeArgumentsValidateSession};
  const telar::testing::Case case_report_title_rejects_control_bytes{"agent_records.report_title_rejects_control_bytes", testReportTitleRejectsControlBytes};
  const telar::testing::Case case_registry_capacity{"agent_records.registry_capacity", testRegistryCapacity};

}
