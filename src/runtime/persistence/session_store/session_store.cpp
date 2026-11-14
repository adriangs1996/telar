module telar.runtime.persistence.session_store;

import telar.platform.error;
import telar.platform.fs;
import telar.sys.posix;

namespace telar::runtime::checkpoint {

  void validatePath(std::string_view path) {
    if (path.empty() || path.size() > 4096 || path.find('\0') != std::string_view::npos) {
      throw EncodingError{"Invalid checkpoint directory"};
    }
  }

  void validateTitle(std::string_view title, AgentTitleSource source) {
    if (title.empty()) {
      if (source != AgentTitleSource::telar) {
        throw EncodingError{"Empty checkpoint title has a source"};
      }

      return;
    }

    DisplayText16<96, false>::validate(title);
    if (source != AgentTitleSource::generated && source != AgentTitleSource::manual && source != AgentTitleSource::agent) {
      throw EncodingError{"Checkpoint title is not durable"};
    }
  }

  template <Allocator Memory>
  FileStore<Memory>::FileStore(Memory& memory, std::string_view path)
      : parent_(openPrivateParent(path)),
        name_(path.substr(path.rfind('/') + 1), AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  bool FileStore<Memory>::load(Vector<Byte, Memory>& bytes) {
    return readPrivateFile(parent_.get(), name_, bytes, maximum_bytes);
  }

  template <Allocator Memory>
  FileDescriptor FileStore<Memory>::lock() const {
    std::array<char, NAME_MAX + 1> name;
    const auto length = std::snprintf(name.data(), name.size(), "%s.lock", name_.c_str());
    if (length < 0 || static_cast<std::size_t>(length) >= name.size()) {
      throw SystemError{"Session lock path is too long", ENAMETOOLONG};
    }

    FileDescriptor file{::openat(parent_.get(), name.data(), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0) {
      throw SystemError{"Open session lock"};
    }

    if (!S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || state.st_nlink != 1 || (state.st_mode & 0077) != 0) {
      throw SystemError{"Unsafe session lock", EACCES};
    }

    while (::flock(file.get(), LOCK_EX) != 0) {
      if (sys::lastError() != EINTR) {
        throw SystemError{"Lock session"};
      }
    }

    return file;
  }

  template <Allocator Memory>
  typename FileStore<Memory>::Result FileStore<Memory>::observe(const Request& bytes) noexcept {
    return writePrivateFile(parent_.get(), name_, bytes, PrivateFileMode::replace);
  }

  template <Allocator Memory>
  void FileStore<Memory>::quarantine() noexcept {
    std::array<char, NAME_MAX + 1> destination;
    const auto length = std::snprintf(destination.data(), destination.size(), "%s.corrupt", name_.c_str());
    if (length >= 0 && static_cast<std::size_t>(length) < destination.size()) {
      ::renameat(parent_.get(), name_.c_str(), parent_.get(), destination.data());
    }
  }

  template <Allocator Memory>
  void FileStore<Memory>::stop() noexcept {}

  template <Allocator Memory>
  void FileStore<Memory>::setAside(Memory& memory, std::string_view path) {
    const auto parent = openPrivateParent(path);
    const String<Memory> name{path.substr(path.rfind('/') + 1), AllocatorRef<char, Memory>{memory}};
    String<Memory> previous{name, AllocatorRef<char, Memory>{memory}};

    previous += ".previous";
    if (::renameat(parent.get(), name.c_str(), parent.get(), previous.c_str()) != 0 && sys::lastError() != ENOENT) {
      throw SystemError{"Set previous session aside"};
    }
  }

  template class FileStore<SystemAllocator>;
  template class FileStore<ConcurrentMemory>;

  Reader::Reader(std::span<const Byte> bytes)
      : input_(bytes) {
    if (bytes.size() > maximum_bytes || text(magic.size()) != magic) {
      throw EncodingError{"Invalid checkpoint header"};
    }

    version_ = u16::decode(input_);
    if (version_ == 0 || version_ > current_version) {
      throw EncodingError{"Unsupported checkpoint version"};
    }

    counters = {u64::decode(input_), u64::decode(input_), u64::decode(input_), u64::decode(input_)};
    if (counters.workspace == 0 || counters.tab == 0 || counters.pane == 0 || counters.generation == 0) {
      throw EncodingError{"Invalid checkpoint counters"};
    }
  }

  bool Reader::boolean() {
    const auto value = u8::decode(input_);
    if (value > 1) {
      throw EncodingError{"Invalid checkpoint boolean"};
    }

    return value != 0;
  }

  std::string_view Reader::text(std::size_t length) {
    if (length > input_.size()) {
      throw EncodingError{"Truncated checkpoint text"};
    }

    const std::string_view result{reinterpret_cast<const char*>(input_.data()), length};

    input_ = input_.subspan(length);
    return result;
  }

  std::string_view Reader::text16() {
    return text(u16::decode(input_));
  }

  std::span<const Byte> Reader::bytes32() {
    const auto value = text(u32::decode(input_));

    return {reinterpret_cast<const Byte*>(value.data()), value.size()};
  }

  std::optional<PaneRecord> Reader::pane() {
    PaneRecord record{u64::decode(input_), u64::decode(input_), u64::decode(input_), text16(), u16::decode(input_), u16::decode(input_), u16::decode(input_), {}};

    record.arguments = version_ >= 9 ? text(u32::decode(input_)) : text16();
    validatePath(record.cwd);
    if (record.argument_count > 64 || record.arguments.size() > 128 * 1024 || std::ranges::count(record.arguments, '\0') != record.argument_count) {
      throw EncodingError{"Invalid checkpoint launch arguments"};
    }

    record.provider = static_cast<AgentProvider>(u8::decode(input_));
    record.session = text16();
    if (!record.session.empty()) {
      validateAgentSession(record.session, false);
    }

    if (version_ >= 2) {
      record.title = text16();
      record.title_source = static_cast<AgentTitleSource>(u8::decode(input_));
    }

    validateTitle(record.title, record.title_source);

    record.in_pane = version_ >= 8 && boolean();
    if (version_ == 4 && boolean()) {
      return std::nullopt;
    }

    if (record.argument_count == 0) {
      throw EncodingError{"Checkpoint launch has no arguments"};
    }

    return record;
  }

  WorktreeRecord Reader::worktree() {
    WorktreeRecord record{};

    record.id = u64::decode(input_);
    auto& registration = record.registration;

    registration.request_id = 1;
    registration.source = u64::decode(input_);
    record.workspace = u64::decode(input_);
    const auto created_by = u64::decode(input_);
    if (created_by != 0) {
      registration.created_by = created_by;
    }

    registration.origin = static_cast<WorktreeOrigin>(u8::decode(input_));
    registration.path = text16();
    registration.branch = text16();
    registration.base = text16();
    registration.title = text16();
    registration.brief = text16();
    if (version_ >= 7) {
      registration.dispatched_from = text16();
    }

    if (version_ >= 10 && boolean()) {
      CoordinatorReference coordinator;
      const auto session = text(coordinator.session_id.size());

      std::copy(session.begin(), session.end(), coordinator.session_id.begin());
      coordinator.pane_id = u64::decode(input_);
      coordinator.pane_generation = u64::decode(input_);
      registration.coordinator = coordinator;
    }

    return record;
  }

  Writer::Writer(tbc::view<std::span<Byte>, tbc::lt::a> buffer, Counters counters)
      : buffer_(buffer),
        remaining_(buffer.empty() ? buffer : buffer.first(buffer.size() - 1)) {
    constexpr std::size_t header_bytes = magic.size() + sizeof(current_version) + 4 * sizeof(std::uint64_t);
    if (buffer.size() <= header_bytes) {
      throw EncodingError{"Checkpoint buffer cannot hold its header"};
    }

    raw(magic);
    integer(current_version);
    integer(counters.workspace);
    integer(counters.tab);
    integer(counters.pane);
    integer(counters.generation);
  }

  template <typename Record>
  void Writer::append(const Record& record) {
    if (dropped != 0) {
      ++dropped;
      return;
    }

    const auto previous = remaining_;

    try {
      write(record);
    } catch (const CapacityReached&) {
      remaining_ = previous;
      dropped = 1;
    }
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Writer::finish() {
    const auto count = buffer_.size() - remaining_.size() - 1;

    buffer_[count] = static_cast<Byte>(Kind::end);
    return buffer_.first(count + 1);
  }

  void Writer::require(std::size_t count) {
    if (count > remaining_.size()) {
      throw CapacityReached{};
    }
  }

  template <std::unsigned_integral Integer>
  void Writer::integer(Integer value) {
    require(sizeof(value));
    LittleEndian<Integer>::encode(value, remaining_);
  }

  void Writer::raw(std::string_view value) {
    require(value.size());
    std::copy(value.begin(), value.end(), remaining_.begin());
    remaining_ = remaining_.subspan(value.size());
  }

  void Writer::text16(std::string_view value) {
    if (value.size() > std::numeric_limits<std::uint16_t>::max()) {
      throw EncodingError{"Checkpoint text exceeds its length field"};
    }

    integer(static_cast<std::uint16_t>(value.size()));
    raw(value);
  }

  void Writer::text32(std::string_view value) {
    if (value.size() > maximum_bytes) {
      throw EncodingError{"Checkpoint data exceeds file limit"};
    }

    integer(static_cast<std::uint32_t>(value.size()));
    raw(value);
  }

  void Writer::kind(Kind value) {
    integer(static_cast<Byte>(value));
  }

  void Writer::write(const WorkspaceRecord& record) {
    validatePath(record.path);
    if (record.name.size() > 256 || record.first_label.size() > 128) {
      throw EncodingError{"Invalid checkpoint workspace label"};
    }

    kind(Kind::workspace);
    integer(record.id);
    text16(record.path);
    text16(record.name);
    integer(record.first_tab);
    text16(record.first_label);
  }

  void Writer::write(const TabRecord& record) {
    kind(Kind::tab);
    integer(record.workspace);
    integer(record.id);
    text16(record.label);
  }

  void Writer::write(const PaneRecord& record) {
    validatePath(record.cwd);
    validateTitle(record.title, record.title_source);
    if (record.argument_count == 0 || record.argument_count > 64 || record.arguments.size() > 128 * 1024 || record.session.size() > 64) {
      throw EncodingError{"Invalid checkpoint launch record"};
    }

    kind(Kind::pane);
    integer(record.id);
    integer(record.workspace);
    integer(record.tab);
    text16(record.cwd);
    integer(record.columns);
    integer(record.rows);
    integer(record.argument_count);
    text32(record.arguments);
    integer(static_cast<Byte>(record.provider));
    text16(record.session);
    text16(record.title);
    integer(static_cast<Byte>(record.title_source));
    integer(static_cast<Byte>(record.in_pane));
  }

  void Writer::write(const WorktreeRecord& record) {
    const auto& registration = record.registration;
    auto checked = registration;

    checked.request_id = 1;
    Codec::encodedSize(checked);
    if (record.id == 0) {
      throw EncodingError{"Invalid checkpoint worktree identity"};
    }

    kind(Kind::worktree);
    integer(record.id);
    integer(registration.source);
    integer(record.workspace);
    integer(registration.created_by.value_or(0));
    integer(static_cast<Byte>(registration.origin));
    text16(registration.path);
    text16(registration.branch);
    text16(registration.base);
    text16(registration.title);
    text16(registration.brief);
    text16(registration.dispatched_from);
    integer(static_cast<Byte>(registration.coordinator.has_value()));
    if (registration.coordinator) {
      const auto& coordinator = *registration.coordinator;

      raw({reinterpret_cast<const char*>(coordinator.session_id.data()), coordinator.session_id.size()});
      integer(coordinator.pane_id);
      integer(coordinator.pane_generation);
    }
  }

  void Writer::write(const LayoutRecord& record) {
    if (record.payload.empty() || record.payload.size() > 16 * 1024) {
      throw EncodingError{"Invalid checkpoint layout size"};
    }

    kind(Kind::layout);
    integer(record.identity);
    integer(record.last_used);
    text32({reinterpret_cast<const char*>(record.payload.data()), record.payload.size()});
  }

  template void Writer::append<WorkspaceRecord>(const WorkspaceRecord& record);
  template void Writer::append<TabRecord>(const TabRecord& record);
  template void Writer::append<PaneRecord>(const PaneRecord& record);
  template void Writer::append<WorktreeRecord>(const WorktreeRecord& record);
  template void Writer::append<LayoutRecord>(const LayoutRecord& record);

}
