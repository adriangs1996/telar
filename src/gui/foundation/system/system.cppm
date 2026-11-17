// The services of the operating system the GUI uses: clocks, files, processes, the login
// shell, sockets, shared images and the native window.
export module telar.gui.foundation.system;

export import :awake_clock;
export import :directory_completion;
#ifdef __linux__
export import :background_effect;
#endif
export import :file_stamp;
export import :keyboard;
export import :login_shell;
export import :path_limits;
export import :managed_directory;
export import :peer_identity;
export import :private_file_stamp;
export import :process_group;
export import :runtime_endpoint;
export import :secure_random;
export import :shared_image_source;
export import :stdio_socket;
export import :wall_clock;
export import :window_lease;
