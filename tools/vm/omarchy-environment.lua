local shell_directory = os.getenv("HOME") .. "/.local/lib/telar-vm/bin"
local command_path = os.getenv("PATH") or "/usr/bin"
local directories = { shell_directory }

for directory in command_path:gmatch("[^:]+") do
  if directory ~= shell_directory then
    table.insert(directories, directory)
  end
end

hl.env("PATH", table.concat(directories, ":"))
