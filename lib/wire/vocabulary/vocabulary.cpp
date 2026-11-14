module telar.wire.vocabulary;

import std;
import telar.base.diagnostics;
import telar.tbc;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

#ifdef TELAR_DEBUG
  namespace debug {

    std::size_t columnWidth(std::size_t byte_count, const char* name, const char* value) {
      const auto bytes_width = byte_count == 0 ? 0 : byte_count * 3 - 1;
      const auto name_width = std::strlen(name);
      const auto value_width = std::strlen(value);
      const auto width = bytes_width > name_width ? bytes_width : name_width;

      return width > value_width ? width : value_width;
    }

    void printBytes(std::span<const Byte> bytes, const char* name, const char* value, std::FILE* output, bool more) {
      for (std::size_t i = 0; i < bytes.size(); ++i) {
        if (i != 0) {
          std::fputc(' ', output);
        }

        std::fprintf(output, "%02x", static_cast<unsigned>(bytes[i]));
      }

      if (more) {
        const auto bytes_width = bytes.empty() ? 0 : bytes.size() * 3 - 1;
        const auto padding = columnWidth(bytes.size(), name, value) - bytes_width;

        std::fprintf(output, "%*s | ", static_cast<int>(padding), "");
      }
    }

    void printText(const char* text, std::size_t width, std::FILE* output, const char* separator) {
      std::fputs(text, output);

      if (separator[0] != '\0') {
        const auto padding = width - std::strlen(text);

        std::fprintf(output, "%*s%s", static_cast<int>(padding), "", separator);
      }
    }

    void printLabel(std::size_t byte_count, const char* name, const char* value, std::FILE* output, bool more) {
      printText(name, columnWidth(byte_count, name, value), output, more ? "   " : "");
    }

    void printValue(std::size_t byte_count, const char* name, const char* value, std::FILE* output, bool more) {
      printText(value, columnWidth(byte_count, name, value), output, more ? " | " : "");
    }

  } // namespace debug
#endif

  void RequestRuntimeState::validate() const {
    if (client_identity == 0) {
      throw std::runtime_error{"Invalid client identity"};
    }
  }

  void SystemMetrics::validate() const {
    if (revision == 0 || cpu_percent > 100) {
      throw std::runtime_error{"Invalid system metrics"};
    }

    if ((has_battery && battery_percent > 100) || (!has_battery && battery_percent != 0)) {
      throw std::runtime_error{"Invalid battery metrics"};
    }
  }

  tbc::view<std::string_view, tbc::lt::a> notificationLinkHost(tbc::view<std::string_view, tbc::lt::a> link) noexcept {
    if (!link.starts_with(notification_link_scheme)) {
      return {};
    }

    const auto rest = link.substr(notification_link_scheme.size());

    return rest.substr(0, rest.find_first_of("/?#"));
  }

  void BodySchema<TerminalSize>::validate(const TerminalSize& value) {
    const auto cells = static_cast<std::uint32_t>(value.cols) * value.rows;
    if (value.cols == 0 || value.rows == 0 || cells > max_cells) {
      throw EncodingError{"Invalid terminal dimensions"};
    }
  }

  std::size_t BodySchema<HistoryScopeValue>::encodedSize(const HistoryScopeValue& value, HistoryScope scope) {
    EnumByte<HistoryScope, 3>::validate(scope);
    switch (scope) {
    case HistoryScope::global:
      if (std::holds_alternative<std::monostate>(value)) {
        return 0;
      }

      break;
    case HistoryScope::cwd:
    case HistoryScope::workspace:
      if (const auto* path = std::get_if<std::string_view>(&value)) {
        return PathCodec::encodedSize(*path);
      }

      break;
    case HistoryScope::pane:
      if (const auto* id = std::get_if<std::uint64_t>(&value)) {
        NonzeroU64::validate(*id);
        return 8;
      }

      break;
    }

    throw EncodingError{"History scope and value do not match"};
  }

  void BodySchema<HistoryScopeValue>::encodeBody(const HistoryScopeValue& value, std::span<Byte>& output, HistoryScope scope) {
    (void)encodedSize(value, scope);
    switch (scope) {
    case HistoryScope::global:
      break;
    case HistoryScope::cwd:
    case HistoryScope::workspace:
      PathCodec::encode(std::get<std::string_view>(value), output);
      break;
    case HistoryScope::pane:
      NonzeroU64::encode(std::get<std::uint64_t>(value), output);
      break;
    }
  }

  void BodySchema<HistoryScopeValue>::decodeBody(DecodeInput input, tbc::view<HistoryScopeValue&, tbc::lt::a> value, DecodeStorage&, HistoryScope scope) {
    EnumByte<HistoryScope, 3>::validate(scope);
    switch (scope) {
    case HistoryScope::global:
      value = std::monostate{};
      break;
    case HistoryScope::cwd:
    case HistoryScope::workspace:
      value = PathCodec::decode(input);
      break;
    case HistoryScope::pane:
      value = NonzeroU64::decode(input);
      break;
    }
  }

  void BodySchema<CoordinatorReference>::validate(const CoordinatorReference& value) {
    for (const auto byte : value.session_id) {
      if (byte != 0) {
        return;
      }
    }

    throw EncodingError{"Missing coordinator session identity"};
  }

  void BodySchema<EnvironmentEntry>::validate(const EnvironmentEntry& value) {
    if (value.name.find('=') != std::string_view::npos) {
      throw EncodingError{"Invalid environment name"};
    }
  }

  void BodySchema<Launch>::validate(const Launch& value) {
    if (value.arguments.empty() || value.arguments.size() > 64 ||
        value.arguments.front().empty() || value.environment.size() > 256) {
      throw EncodingError{"Invalid launch collections"};
    }

    std::size_t arguments = 0;

    for (const auto argument : value.arguments) {
      arguments = checkedWireSize(arguments, argument.size());
    }

    std::size_t environment = 0;

    for (const auto& entry : value.environment) {
      environment = checkedWireSize(environment, entry.name.size());
      environment = checkedWireSize(environment, entry.value.size());
    }

    if (arguments > 128 * 1024 || environment > 512 * 1024) {
      throw EncodingError{"Launch byte budget exceeded"};
    }
  }

  void BodySchema<PaneListEntry>::validate(const PaneListEntry& value) {
    if (std::ranges::adjacent_find(value.ports, std::ranges::greater_equal{}) != value.ports.end()) {
      throw EncodingError{"Listening ports must ascend without repeats"};
    }
  }

  void BodySchema<TabDescriptor>::validate(const TabDescriptor& value) {
    if (value.panes.size() > value.pane_count) {
      throw EncodingError{"Too many tab pane entries"};
    }

    for (std::size_t i = 0; i < value.panes.size(); ++i) {
      for (std::size_t j = 0; j < i; ++j) {
        if (value.panes[i].pane_id == value.panes[j].pane_id) {
          throw EncodingError{"Duplicate tab pane"};
        }
      }
    }
  }

  void BodySchema<WorktreeListEntry>::validate(const WorktreeListEntry& value) {
    if (value.path.empty() || value.path.front() != '/') {
      throw EncodingError{"Worktree path must be absolute"};
    }
  }

  void BodySchema<AgentSnapshotEntry>::validate(const AgentSnapshotEntry& value) {
    if (value.expires_at_ms < value.observed_at_ms || value.plan_done > value.plan_total ||
        (value.status != AgentStatus::blocked &&
            value.blocked_reason != AgentBlockedReason::none)) {
      throw EncodingError{"Invalid agent state"};
    }

    switch (value.title_source) {
    case AgentTitleSource::telar:
      if (value.title_state == AgentTitleState::ready) {
        throw EncodingError{"Invalid agent title"};
      }

      break;
    case AgentTitleSource::generated:
    case AgentTitleSource::manual:
    case AgentTitleSource::agent:
      if (value.title_state != AgentTitleState::ready || value.session_title.empty()) {
        throw EncodingError{"Invalid agent title"};
      }

      break;
    case AgentTitleSource::terminal:
      if (value.session_title.empty()) {
        throw EncodingError{"Invalid agent title"};
      }

      break;
    }
  }

  std::size_t BodySchema<ClientLayoutNode>::encodedSize(const ClientLayoutNode& value) {
    if (const auto* pane = std::get_if<ClientLayoutPane>(&value)) {
      return 1 + ValueCodec<ClientLayoutPane>::encodedSize(*pane);
    }

    if (const auto* split = std::get_if<ClientLayoutSplit>(&value)) {
      return 1 + ValueCodec<ClientLayoutSplit>::encodedSize(*split);
    }

    throw EncodingError{"Invalid layout node"};
  }

  void BodySchema<ClientLayoutNode>::encodeBody(const ClientLayoutNode& value, std::span<Byte>& output) {
    if (const auto* pane = std::get_if<ClientLayoutPane>(&value)) {
      u8::encode(0, output);
      ValueCodec<ClientLayoutPane>::encode(*pane, output);
    } else if (const auto* split = std::get_if<ClientLayoutSplit>(&value)) {
      u8::encode(1, output);
      ValueCodec<ClientLayoutSplit>::encode(*split, output);
    } else {
      throw EncodingError{"Invalid layout node"};
    }
  }

  void BodySchema<ClientLayoutNode>::decodeBody(std::span<const Byte>& input, ClientLayoutNode& value, DecodeStorage& storage) {
    switch (u8::decode(input)) {
    case 0:
      value = ValueCodec<ClientLayoutPane>::decode(input, storage);
      break;
    case 1:
      value = ValueCodec<ClientLayoutSplit>::decode(input, storage);
      break;
    default:
      throw EncodingError{"Unknown layout node tag"};
    }
  }

  void BodySchema<ClientTabLayout>::validate(const ClientTabLayout& value) {
    if (value.nodes.empty() || value.nodes.size() > 127) {
      throw EncodingError{"Invalid layout node count"};
    }

    std::array<std::uint64_t, 64> panes{};
    std::size_t pane_count = 0;
    std::size_t pending = 1;
    bool focused = false;

    for (const auto& node : value.nodes) {
      if (pending == 0) {
        throw EncodingError{"Invalid layout tree"};
      }

      --pending;
      if (const auto* pane = std::get_if<ClientLayoutPane>(&node)) {
        if (pane_count == panes.size()) {
          throw EncodingError{"Too many layout panes"};
        }

        for (std::size_t i = 0; i < pane_count; ++i) {
          if (panes[i] == pane->pane_id) {
            throw EncodingError{"Duplicate layout pane"};
          }
        }

        panes[pane_count++] = pane->pane_id;
        focused = focused || pane->pane_id == value.focused_pane;
      } else {
        pending += 2;
      }
    }

    if (pending != 0 || !focused) {
      throw EncodingError{"Invalid layout tree or focus"};
    }
  }

  void BodySchema<NotificationBody>::validate(const NotificationBody& value) {
    const auto link = value.link;
    if (link.empty()) {
      return;
    }

    if (!link.starts_with(notification_link_scheme)) {
      throw EncodingError{"Notification link must use HTTPS"};
    }

    for (const auto character : link) {
      const auto byte = static_cast<Byte>(character);
      if (byte <= 0x20 || byte >= 0x7f || byte == '\\') {
        throw EncodingError{"Invalid notification link"};
      }
    }

    const auto host = notificationLinkHost(link);
    if (host.empty() || host.front() == '.' || host.front() == '-' || host.back() == '.') {
      throw EncodingError{"Invalid notification host"};
    }

    for (const auto byte : host) {
      const auto alphanumeric = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                                (byte >= '0' && byte <= '9');
      if (!alphanumeric && byte != '.' && byte != '-') {
        throw EncodingError{"Invalid notification host"};
      }
    }
  }

  void BodySchema<CompletionWord>::validate(const CompletionWord& value) {
    if (value.text.empty()) {
      throw EncodingError{"Empty completion word"};
    }
  }

  void BodySchema<CommandBlock>::validate(const CommandBlock& value) {
    if (value.rows == 0) {
      throw EncodingError{"Command block without rows"};
    }
  }

  void BodySchema<PathMatch>::validate(const PathMatch& value) {
    if (value.path.empty() || (value.kind == PathKind::directory) != (value.path.back() == '/')) {
      throw EncodingError{"Invalid path kind"};
    }

    std::size_t next = 0;

    for (const auto position : value.positions) {
      if (position < next || position >= value.path.size()) {
        throw EncodingError{"Invalid path match positions"};
      }

      next = static_cast<std::size_t>(position) + 1;
    }
  }

  void BodySchema<LimitReach>::validate(const LimitReach& value) {
    const auto alphanumeric = [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
             (byte >= '0' && byte <= '9');
    };

    for (const auto byte : value.name) {
      if (!alphanumeric(byte) && byte != '.' && byte != '_' && byte != '-') {
        throw EncodingError{"Invalid limit name"};
      }
    }

    for (const auto character : value.noun) {
      const auto byte = static_cast<Byte>(character);
      if (byte < 0x20 || byte >= 0x7f) {
        throw EncodingError{"Invalid limit noun"};
      }
    }

    for (const auto byte : value.route) {
      if (!alphanumeric(byte) && byte != '_') {
        throw EncodingError{"Invalid limit route"};
      }
    }
  }

  void BodySchema<ImageDescription>::validate(const ImageDescription& value) {
    const auto pixels = static_cast<std::uint64_t>(value.width) * value.height;
    const auto channels = value.format == ImageFormat::rgb ? 3u : 4u;
    constexpr std::uint64_t maximum = 256 * 1024 * 1024;

    if (pixels > maximum / channels || value.byte_len != pixels * channels) {
      throw EncodingError{"Invalid image byte length"};
    }
  }

  void validateAgentSession(std::string_view session, bool empty_allowed) {
    if (session.empty()) {
      if (!empty_allowed) {
        throw EncodingError{"Missing agent session"};
      }

      return;
    }

    if (session.size() > 64 || session.front() == '-') {
      throw EncodingError{"Invalid agent session"};
    }

    for (const auto character : session) {
      const auto byte = static_cast<Byte>(character);
      if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
              (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-' ||
              byte == ':')) {
        throw EncodingError{"Invalid agent session"};
      }
    }
  }

  void validateWorkspaceClosure(const WorkspaceLocation& workspace, bool closed, std::optional<std::uint64_t> previous) {
    if (previous && (!closed || workspace.kind != WorkspaceLocation::Kind::workspace ||
                        *previous == workspace.id)) {
      throw EncodingError{"Invalid previous workspace"};
    }
  }

  void validateSharedImageName(std::string_view name) {
    if (name.size() < 2 || name.size() > 31 || name.front() != '/') {
      throw EncodingError{"Invalid shared image name"};
    }

    for (const auto byte : name.substr(1)) {
      if (!((byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-')) {
        throw EncodingError{"Invalid shared image name"};
      }
    }
  }

  void validateLayoutCollection(std::optional<TabLocation> active, std::span<const ClientTabLayout> tabs) {
    std::size_t nodes = 0;
    bool active_found = !active;

    for (std::size_t i = 0; i < tabs.size(); ++i) {
      nodes += tabs[i].nodes.size();
      for (std::size_t j = 0; j < i; ++j) {
        if (sameTab(tabs[i].location, tabs[j].location) ||
            (tabs[i].workspace_active && tabs[j].workspace_active &&
                sameWorkspace(tabs[i].location.workspace, tabs[j].location.workspace))) {
          throw EncodingError{"Duplicate client layout location"};
        }
      }

      if (active && sameTab(*active, tabs[i].location) && tabs[i].workspace_active) {
        active_found = true;
      }
    }

    if (nodes > 511 || !active_found) {
      throw EncodingError{"Invalid active client layout"};
    }
  }

  std::size_t ScopedHistoryValue::encodedSize(const value_type& value, HistoryScope scope) {
    return BodySchema<HistoryScopeValue>::encodedSize(value, scope);
  }

  void ScopedHistoryValue::encode(const value_type& value, std::span<Byte>& output, HistoryScope scope) {
    BodySchema<HistoryScopeValue>::encodeBody(value, output, scope);
  }

  auto ScopedHistoryValue::decode(DecodeInput input, DecodeStorage& storage, HistoryScope scope) -> Decoded<value_type> {
    value_type value{};

    BodySchema<HistoryScopeValue>::decodeBody(input, value, storage, scope);
    return value;
  }

  std::size_t TargetLaunch::encodedSize(const value_type& value, const PaneTarget& target) {
    if ((target.kind == PaneTarget::Kind::default_target) != value.has_value()) {
      throw EncodingError{"Launch and pane target do not match"};
    }

    return value ? ValueCodec<Launch>::encodedSize(*value) : 0;
  }

  void TargetLaunch::encode(const value_type& value, std::span<Byte>& output, const PaneTarget& target) {
    (void)encodedSize(value, target);
    if (value) {
      ValueCodec<Launch>::encode(*value, output);
    }
  }

  auto TargetLaunch::decode(DecodeInput input, DecodeStorage& storage, const PaneTarget& target) -> Decoded<value_type> {
    if (target.kind != PaneTarget::Kind::default_target) {
      return std::nullopt;
    }

    return ValueCodec<Launch>::decode(input, storage);
  }

}
}
