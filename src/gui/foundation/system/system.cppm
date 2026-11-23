// The services of the operating system the GUI uses: clocks, files, processes, the login
// shell, sockets, shared images, the native window, the private file profiles live in, and the commands that post desktop
// notifications and play sounds.
export module telar.gui.foundation.system;

export import :awake_clock;
export import :directory_completion;
#ifdef __linux__
export import :background_effect;
#endif
export import :file_stamp;
export import :file_tree;
export import :keyboard;
export import :login_shell;
export import :path_limits;
export import :managed_directory;
export import :notification_commands;
export import :notification_payload;
export import :peer_identity;
export import :private_file_stamp;
export import :process_group;
export import :profile_file;
export import :runtime_endpoint;
export import :secure_random;
export import :shared_image_source;
export import :stdio_socket;
export import :wall_clock;
export import :window_lease;
