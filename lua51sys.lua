#!/usr/bin/env lua
-- -*- mode: lua -*-
-- LUA COMPATIBILITY: LuaJIT, 5.1, 5.2, 5.3, 5.4

--- This module provides the core "lua51sys" functionality which can be used by other Lua scripts.
--- It is recommended that all system-level Lua scripts import this module.
--- Everything has been tested for compatibility with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- Wrapper functions have been implemented to ensure backward/forward compatibility for essential operations.
--- When a new version of Lua is released, this module should be reviewed (e.g., with AI assistance) and updated to align with the latest standards if necessary.
--- Backward and forward compatibility must always be preserved, especially for Lua 5.1 and LuaJIT.

local lfs = require("lfs")

local lua51sys = {}

--- Executes a system command and normalizes the return values across diffrent Lua versions.
--- @param cmd string The system command to execute.
--- @return boolean success True if the command executed successfully (exit code == 0), false otherwise (or if the command couldn't run).
--- @return number code The exit code (or error/signal code if applicable).
function lua51sys.execute(cmd)
	-- Execute the system command
	local result, exit_type, code = os.execute(cmd)

	-- Check the type of the returned value to adjust for the Lua version:
	if type(result) == "number" then
		-- Lua 5.1: returns a number (exit code)
		-- Lua 5.1: Convert the exit code to Lua 5.4 format
		-- Lua 5.1: Get the proper exit code, POSIX-compliant for Linux:
		local exit_code = math.floor(result / 256)
		return exit_code == 0, exit_code
	else
		-- Lua 5.2/5.3/5.4: returns 3 values: success (boolean or nil), exit_type (string), code (number)
		-- Lua 5.2/5.3/5.4: Transform these 3 values to Lua 5.4 format (success, code)
		-- Lua 5.2/5.3/5.4: Ignore exit_type
		-- To make consistent with 5.1: success only if code == 0 (and command ran); false if couldn't run or code != 0
		if result == nil then
			return false, code -- Couldn't execute; treat as failure
		else
			return code == 0, code -- Command ran; success based on code == 0
		end
	end
end

--- Create directories recursively, equivalent to the shell command "mkdir -p"
--- Attempts to create the named directory only if it does not already exist.
--- Returns true on success, false and an error message on failure.
--- @param folderName string Directory path to create
--- @return boolean success true when directory exists or was created successfully
--- @return string|nil err Error message when creation failed, nil on success
function lua51sys.mkdir(folderName)
	-- Check if the folder exists
	if not lfs.attributes(folderName, "mode") then
		local success, err = lfs.mkdir(folderName)
		if not success then
			print("Error creating folder: " .. err)
			return false
		end
		return true
	end
end

--- Remove a directory and its contents using command "rm -rf" if the directory exists.
--- @param dir_path string Path to the directory to remove.
--- @return boolean|nil true when directory was removed successfully.
--- @return string|nil Error message when removal failed or directory does not exist.
function lua51sys.remove_dir(dir_path)
	if lua51sys.directory_exists(dir_path) then
		local success, err = lua51sys.execute("rm -rf " .. dir_path)
		if success then
			return true
		else
			return nil, err
		end
	end
	return nil, "directory does not exists"
end

--- Wrapper around os.remove.
--- @param file_path string Path to the file to remove.
--- @return boolean|nil true on success; nil plus error message on failure.
function lua51sys.remove(file_path)
	-- Currently all versions work the same, but this may change in the future (5.4++)
	return os.remove(file_path)
end

--- Wrapper around os.rename.
--- @param file_path string Current path of the file.
--- @param new_file_path string New path for the file.
--- @return boolean|nil true on success; nil plus error message on failure.
function lua51sys.rename(file_path, new_file_path)
	-- Currently all versions work the same, but this may change in the future (5.4++)
	return os.rename(file_path, new_file_path)
end

--- Copies the file from "src" to "dst", preserving content and permissions where possible.
--- @param src string The source file path (must be a non-empty string).
--- @param dst string The destination file path (must be a non-empty string).
--- @return boolean true on success.
function lua51sys.copy_file(src, dst)
	-- Check parameters
	if type(src) ~= "string" or src == "" then
		error("Invalid source path (src)")
	end
	if type(dst) ~= "string" or dst == "" then
		error("Invalid destination path (dst)")
	end

	-- Check if src exists and is a file
	if not lua51sys.file_exists(src) then
		error("Source does not exist or is not a file: " .. tostring(src))
	end

	-- Open source file for binary read
	local src_file, err = io.open(src, "rb")
	if not src_file then
		error("Cannot open source file: " .. err)
	end

	-- Open destination file for binary write
	local dst_file, err = io.open(dst, "wb")
	if not dst_file then
		src_file:close()
		error("Cannot create destination file: " .. err)
	end

	-- Copy content (in chunks)
	while true do
		local chunk = src_file:read(4096)
		if not chunk then
			break
		end
		dst_file:write(chunk)
	end

	-- Close files
	src_file:close()
	dst_file:close()

	-- Copy permissions (chmod, Unix-only)
	local src_attr = lfs.attributes(src)
	if src_attr.permissions then
		-- Parse symbolic permissions string (e.g., "rw-r--r--") to octal number
		local function parse_permissions(perm)
			if #perm ~= 9 then
				return nil
			end
			local function bits(s)
				return (s:find("r") and 4 or 0) + (s:find("w") and 2 or 0) + (s:find("x") and 1 or 0) + (s:find("[sStT]") and 0 or 0)
			end -- Ignore setuid/sticky for basic chmod
			return bits(perm:sub(1, 3)) * 64 + bits(perm:sub(4, 6)) * 8 + bits(perm:sub(7, 9))
		end

		-- chmod via os.execute (Unix only)
		local perm_str = src_attr.permissions
		local mode_num = parse_permissions(perm_str)
		if mode_num then
			local success = lua51sys.execute(string.format("chmod %o %s", mode_num, "'" .. dst:gsub("'", "'\\''") .. "'"))
			if not success then
				-- Optionally warn or error; here we ignore failure silently
			end
		end
	end

	return true
end

--- Lua equivalent of Python "os.path.dirname(__file__)".
--- Returns the real location of the executing script.
--- @return string The directory path of the script, or "." if not found.
function lua51sys.get_script_dir()
	for i = 2, math.huge do
		local info = debug.getinfo(i, "S")
		if not info then
			break
		end
		if info.source:sub(1, 1) == "@" then
			return info.source:match("@?(.*/)") or "."
		end
	end
	return "."
end

--- Wrapper for os.exit for Lua 5.1-5.4, ensuring consistent behavior across versions.
--- In Lua 5.1/LuaJIT, the close parameter is always treated as true (Lua state is closed).
--- @param code boolean|number|nil The exit code (boolean true/false maps to 0/1, number used directly, defaults to 0).
--- @param close boolean|nil Whether to close the Lua environment (defaults to true; ignored in Lua 5.1/LuaJIT).
function lua51sys.exit(code, close)
	-- Handle boolean code properly (true -> 0, false -> 1)
	if type(code) == "boolean" then
		code = code and 0 or 1
	else
		code = tonumber(code) or 0 -- Ensure code is a number
	end
	close = not (close == false) -- Normalize close to true/false

	if _VERSION == "Lua 5.1" or _VERSION:match("LuaJIT") then
		os.exit(code) -- Ignore close, as Lua 5.1 and LuaJIT do not support the second argument (always closes Lua state)
	else
		os.exit(code, close) -- Lua 5.2+ supports both arguments
	end
end

--- Wrapper for io.popen, returning stdout/err.
--- Executes the command with stderr redirected to stdout.
--- Normalizes return to: success (true if code == 0), code (exit code or approx), output (stdout/err combined).
--- If the process cannot be opened, returns false, 1, "Cannot open process".
--- @param cmd string The command to execute.
--- @return boolean success True if the command succeeded (exit code == 0), false otherwise.
--- @return number code The exit code (or error code if applicable).
--- @return string output The combined stdout/stderr output.
function lua51sys.iopopen_stdout_err(cmd)
	local is_lua51 = (_VERSION == "Lua 5.1" or _VERSION:match("LuaJIT"))
	local full_cmd = cmd .. " 2>&1"

	if is_lua51 then
		-- Add unique marker to distinguish exit code line safely
		full_cmd = full_cmd .. "; echo __EXITCODE:$?"
	end

	-- Try to open the process
	local pipe = io.popen(full_cmd, "r")
	if not pipe then
		return false, 1, "Cannot open process"
	end

	-- Read entire output
	local output = pipe:read("*a") or ""

	-- Collect result and exit code
	local result, code
	if not is_lua51 then
		local ok, why, c = pipe:close()
		result = ok or false
		code = c or 1
	else
		pipe:close()
		-- Extract exit code marker
		local code_marker = output:match("__EXITCODE:(%d+)%s*$")
		code = tonumber(code_marker or "1") or 1
		-- Remove the marker line from output
		output = output:gsub("\n?__EXITCODE:%d+%s*$", "")
		result = (code == 0)
	end

	-- Normalize result
	if result == nil then
		result = false
		code = code or 1
	end

	if result then
		result = (code == 0)
	else
		code = code or 1
	end

	return result, code, output
end

--- Calculate file MD5 using the system md5sum command.
--- @param file_path string Path to the file to hash.
--- @return string|nil Lowercase 32-character hexadecimal MD5 digest on success; nil on error.
function lua51sys.calculate_md5(file_path)
	-- Validate argument
	if type(file_path) ~= "string" or file_path == "" then
		return nil
	end

	-- Safely escape the argument for the shell: replace each single quote ' -> '\''
	local escaped_path = "'" .. file_path:gsub("'", "'\\''") .. "'"
	local command = "md5sum " .. escaped_path

	-- Execute command (assumes lua51sys.iopopen_stdout_err is available and tested)
	local success, code, output = lua51sys.iopopen_stdout_err(command)

	-- Check execution result
	if not success or code ~= 0 then
		return nil
	end

	-- Parse output: md5sum returns "<hash>  <path>"
	local md5 = output:match("^([0-9a-fA-F]+)")

	-- Trim trailing whitespace
	if md5 then
		md5 = md5:match("^(.-)%s*$")
	end

	-- Validate hash (32 hex characters) and normalize to lowercase
	if md5 and #md5 == 32 and md5:match("^[0-9a-fA-F]+$") then
		return md5:lower()
	end

	return nil
end

--- Find an executable in PATH (Unix/Linux only).
--- Works like "shutil.which"; returns the absolute path to the executable or nil if not found.
--- @param cmd string Command name to search for.
--- @return string|nil Absolute path to executable on success; nil if not found or on error.
function lua51sys.which(cmd)
	-- Validate argument
	if type(cmd) ~= "string" or cmd == "" then
		return nil
	end

	-- Safely escape the argument for the shell: replace each single quote ' -> '\''
	local escaped_cmd = "'" .. cmd:gsub("'", "'\\''") .. "'"
	local command = "which " .. escaped_cmd

	-- Execute command (assumes lua51sys.iopopen_stdout_err is available and tested)
	local success, code, stdout = lua51sys.iopopen_stdout_err(command)

	-- Check execution result
	if not success or code ~= 0 then
		return nil
	end

	-- Trim trailing whitespace
	local path = stdout:match("^(.-)%s*$")

	-- Return path only if non-empty and file exists (assumes lua51sys.file_exists is available)
	if path and path ~= "" then
		if lua51sys.file_exists(path) then
			return path
		else
			return nil
		end
	end

	return nil
end

--- Returns the host name.
--- @return string hostname Host name without trailing newline.
function lua51sys.get_hostname()
	local success, code, stdout = lua51sys.iopopen_stdout_err("hostname")
	if not success then
		error("Failed to obtain host name: " .. stdout)
	end
	return (stdout:gsub("\n", ""))
end

--- Execute a main function protected with pcall and ignore Ctrl+C interrupts.
--- Use `local function main()` and pass that function as the `main` argument.
--- The function dismiss errors equal to "interrupted" or "interrupted!" (typical from Ctrl+C handlers)
--- and prints other errors to stdout.
--- @param main function Function to call under pcall.
function lua51sys.pcall_interrupted(main)
	-- Use `pcall` to handle the error caused by Ctrl+C:
	local status, err = pcall(main)
	if not status then
		if err and err ~= "interrupted" and err ~= "interrupted!" then
		-- in case of Ctrl+C (err as interrupted) do nothing
		else
			print("An error occurred: " .. tostring(err))
		end
	end
end

--- Check SSH reachability by pinging a host and exit on failure.
--- This function only checks the boolean success value returned by that call.
--- @param ip string IP address or hostname to ping
--- @return nil Terminates the process with `lua51sys.exit(1)` when ping fails
function lua51sys.ssh_check_connection(ip)
	local success, code = lua51sys.execute("ping -i 0.3 -c 2 " .. ip .. " > /dev/null 2>&1")

	-- We only check `success`, which is a boolean in the `lua51sys.execute`
	if not success then
		print("WARNING - SSH CONNECTION NOT WORKING! CHECK SSH! Exit code: " .. tostring(code))
		lua51sys.exit(1)
	end
end

--- Get current working directory.
--- Returns the value of the PWD environment variable when available.
--- Falls back to calling the system `pwd` command if PWD is not set.
--- @return string current working directory path or "." when unknown
function lua51sys.pwd()
	local path = os.getenv("PWD")
	if not path then
		local p = io.popen("pwd")
		if p then
			path = p:read("*l")
			p:close()
		end
	end
	return path or "."
end

--- Pretty-print a given lua table recursively to stdout.
--- Prints keys and values; when a value is a table, recurses with increased indentation.
--- @param tbl table Table to print
--- @param indent string|nil Current indentation prefix (optional)
function lua51sys.printTable(tbl, indent)
	indent = indent or "" -- default indentation
	for key, value in pairs(tbl) do
		if type(value) == "table" then
			print(indent .. key .. ":")
			lua51sys.printTable(value, indent .. "  ") -- recursion with increased indentation
		else
			print(indent .. key .. ": " .. tostring(value))
		end
	end
end

--- Check whether a path points to an existing regular file.
--- Implementation without lfs is possible but will be slower.
--- @param path string Path to the file.
--- @return boolean True if the path exists and is a regular file, false otherwise.
function lua51sys.file_exists(path)
	local attr = lfs.attributes(path, "mode")
	return attr ~= nil and attr == "file"
end

--- Check whether a path points to an existing directory.
--- Implementation without lfs is possible but will be slower.
--- @param path string Path to the directory.
--- @return boolean True if the path exists and is a directory, false otherwise.
function lua51sys.directory_exists(path)
	local attr = lfs.attributes(path, "mode")
	return attr ~= nil and attr == "directory"
end

--- Check whether a path is a symbolic link (Linux/Unix only).
--- Uses the external shell "test -L" command.
--- This function validates its argument and raises an error for invalid input.
--- @param path string Non-empty file system path to check.
--- @return boolean True if the path is a symbolic link, false otherwise.
function lua51sys.symlink_exists(path)
	-- Validate argument
	if type(path) ~= "string" or path == "" then
		error("Invalid path: expected a non-empty string")
	end

	-- Escape path to handle spaces and special characters.
	-- Use single quotes and escape single quotes inside the path.
	local escaped_path = "'" .. path:gsub("'", "'\\''") .. "'"
	local cmd = "test -L " .. escaped_path

	-- Execute the test command; success == true means path is a symlink.
	local success, _ = lua51sys.execute(cmd)
	return success
end

--- Performs a file-name search inside `dir` using a glob-like `pattern_base`.
--- The function converts `pattern_base` into a Lua pattern by escaping
--- magic characters, preserving `*` and `?` semantics, and then wrapping the
--- pattern with `.*` on both ends so partial matches succeed.
--- Example:
---     local matches = lua51sys.find("/var/log", "*.log")
---     for _, name in ipairs(matches) do print(name) end
--- @param dir string Directory path where the search will be performed.
--- @param pattern_base string Glob-like pattern to match against file names.
--- @return table Array (integer-keyed) of file names (strings) in `dir` that match the converted pattern.
function lua51sys.find(dir, pattern_base)
	local files = {}
	-- local lua_pattern = pattern_base
	-- :gsub("([%.%+%-%%%[%]%^%$%(%)])", "%%%1") -- Escape for special marks
	-- :gsub("\\", "%%\\") -- Escape for `\`
	-- :gsub("%?", ".")   -- Change `?` na `.`

	local lua_pattern = pattern_base:gsub("([%.%+%-%%%[%]%^%$%(%)%*%?])", "%%%1"):gsub("\\", "%%\\")
	-- Dodajemy .* na poczatku i koncu
	lua_pattern = ".*" .. lua_pattern .. ".*"

	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local full_path = dir .. "/" .. entry
			local attr = lfs.attributes(full_path)
			if attr and attr.mode == "file" then
				if entry:match(lua_pattern) then
					table.insert(files, entry)
				end
			end
		end
	end
	return files
end

--- Lists regular files (non-recursive) in a given directory.
--- Returns only entries that are regular files (not directories, symlinks, etc.).
--- On error (e.g. invalid directory), returns `nil`.
--- @param dir string Path to the directory to list.
--- @return string[]|nil files A numerically indexed array of file names, or `nil` on error.
function lua51sys.ls_dir(dir)
	local files = {}
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local full_path = dir .. "/" .. entry
			local attr = lfs.attributes(full_path)
			if attr and attr.mode == "file" then
				table.insert(files, entry)
			end
		end
	end
	return files
end

return lua51sys
