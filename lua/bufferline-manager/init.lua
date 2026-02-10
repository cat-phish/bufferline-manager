local api = vim.api
local M = {}

M.manager_buf = nil
M.manager_win = nil
M.origin_win = nil
M.buffer_order = {}
M.deleted_buffers = {}
M.is_refreshing = false

-- Default config
M.config = {
	width = 80,
	height = 20,
	border = "rounded",
	title = " Buffer Manager ",
	show_full_path = false,
	smart_path = true,
	show_numbers = true,
	use_relative = nil,
	confirm_delete = true,
	keymaps = {
		delete = "dd",
		move_down = "<A-j>",
		move_up = "<A-k>",
		jump = "<CR>",
		close = { "q", "<Esc>" },
		refresh = "r",
		save = "<C-s>",
	},
}

function M.setup(opts)
	if M._setup_done then
		return
	end
	M._setup_done = true

	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.api.nvim_create_user_command("BufferlineManager", function()
		M.open()
	end, { desc = "Open Bufferline Manager" })

	vim.api.nvim_create_user_command("BufferlineManagerToggle", function()
		if M.manager_win and api.nvim_win_is_valid(M.manager_win) then
			M.close()
		else
			M.open()
		end
	end, { desc = "Toggle Bufferline Manager" })
end

local function get_bufferline_order()
	local ok, bufferline_state = pcall(require, "bufferline.state")
	if ok and bufferline_state then
		local components = bufferline_state.components or {}
		local ordered_buffers = {}
		for _, component in ipairs(components) do
			if component.id then
				local bufnr = component.id
				local bufinfo = vim.fn.getbufinfo(bufnr)[1]
				if bufinfo and bufinfo.listed == 1 then
					table.insert(ordered_buffers, bufinfo)
				end
			end
		end
		return ordered_buffers
	end
	return vim.fn.getbufinfo({ buflisted = 1 })
end

local function get_duplicate_names(buffers)
	local name_counts = {}
	local duplicates = {}

	for _, b in ipairs(buffers) do
		if b.name ~= "" then
			local basename = vim.fn.fnamemodify(b.name, ":t")
			name_counts[basename] = (name_counts[basename] or 0) + 1
		end
	end

	for name, count in pairs(name_counts) do
		if count > 1 then
			duplicates[name] = true
		end
	end

	return duplicates
end

local function get_minimum_unique_path(target_path, all_paths)
	local target_parts = vim.split(vim.fn.fnamemodify(target_path, ":h"), "/", { plain = true })

	-- Parent directory
	for depth = 1, #target_parts do
		local candidate = table.concat(vim.list_slice(target_parts, #target_parts - depth + 1), "/")

		-- Check if unique
		local is_unique = true
		for _, other_path in ipairs(all_paths) do
			if other_path ~= target_path then
				local other_parts = vim.split(vim.fn.fnamemodify(other_path, ":h"), "/", { plain = true })
				local other_candidate =
					table.concat(vim.list_slice(other_parts, math.max(1, #other_parts - depth + 1)), "/")

				if candidate == other_candidate then
					is_unique = false
					break
				end
			end
		end

		if is_unique then
			return candidate
		end
	end

	-- If not unique, return full path minus home
	local full = vim.fn.fnamemodify(target_path, ":h")
	return full:gsub("^" .. vim.fn.expand("~"), "~")
end

local function format_buffer_name(bufnr, name)
	if name == "" then
		return "[No Name]"
	elseif M.config.show_full_path then
		return name
	else
		return vim.fn.fnamemodify(name, ":t")
	end
end

local function apply_smart_path_decorations()
	if not M.config.smart_path or not M.manager_buf or not api.nvim_buf_is_valid(M.manager_buf) then
		return
	end

	-- Clear existing virtual text first
	local ns_id = api.nvim_create_namespace("bufferline_manager_smart_path")
	api.nvim_buf_clear_namespace(M.manager_buf, ns_id, 0, -1)

	local lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local name_counts = {}

	-- Identify duplicatesn
	for _, line in ipairs(lines) do
		if line ~= "" and line ~= "[No Name]" then
			name_counts[line] = (name_counts[line] or 0) + 1
		end
	end

	for i, line in ipairs(lines) do
		if name_counts[line] and name_counts[line] > 1 then
			local bufnr = M.buffer_order[i]
			if bufnr and api.nvim_buf_is_valid(bufnr) then
				local full_path = api.nvim_buf_get_name(bufnr)

				-- Collect all paths with name to find min unique
				local sibling_paths = {}
				for j, other_line in ipairs(lines) do
					if other_line == line then
						local other_buf = M.buffer_order[j]
						if other_buf and api.nvim_buf_is_valid(other_buf) then
							table.insert(sibling_paths, api.nvim_buf_get_name(other_buf))
						end
					end
				end

				local min_path = get_minimum_unique_path(full_path, sibling_paths)

				api.nvim_buf_set_extmark(M.manager_buf, ns_id, i - 1, 0, {
					virt_text = { { min_path .. "/", "Comment" } },
					virt_text_pos = "inline",
					right_gravity = false,
				})
			end
		end
	end
end

local function extract_filename(line)
	return line
end

local function has_unsaved_changes()
	if not M.manager_buf or not api.nvim_buf_is_valid(M.manager_buf) then
		return false
	end

	local lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)

	for i, line in ipairs(lines) do
		local bufnr = M.buffer_order[i]
		if bufnr and api.nvim_buf_is_valid(bufnr) then
			local new_name = extract_filename(line)
			local old_name = vim.fn.bufname(bufnr)
			local old_display = old_name ~= "" and vim.fn.fnamemodify(old_name, ":t") or "[No Name]"

			if new_name and new_name ~= old_display and new_name ~= "[No Name]" then
				return true
			end
		end
	end

	return false
end

local function update_window_title()
	if not M.manager_win or not api.nvim_win_is_valid(M.manager_win) then
		return
	end

	local title = M.config.title
	if has_unsaved_changes() then
		title = M.config.title .. " [+]"
	end

	pcall(api.nvim_win_set_config, M.manager_win, {
		title = title,
		title_pos = "center",
	})
end

local function get_pending_changes()
	if not M.manager_buf or not api.nvim_buf_is_valid(M.manager_buf) then
		return {}
	end

	local lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local changes = {}

	for i, line in ipairs(lines) do
		local bufnr = M.buffer_order[i]
		if bufnr and api.nvim_buf_is_valid(bufnr) then
			local new_name = extract_filename(line)
			local old_name = vim.fn.bufname(bufnr)
			local old_display = old_name ~= "" and vim.fn.fnamemodify(old_name, ":t") or "[No Name]"

			if new_name and new_name ~= old_display and new_name ~= "[No Name]" then
				table.insert(changes, {
					old = old_display,
					new = new_name,
				})
			end
		end
	end

	return changes
end

local function smart_undo()
	local before_lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local before_count = #before_lines

	vim.cmd("silent! undo")

	local after_lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local after_count = #after_lines

	if after_count > before_count then
		if #M.deleted_buffers > 0 then
			local deleted = table.remove(M.deleted_buffers)
			local new_bufnr = api.nvim_create_buf(true, false)

			if deleted.name and deleted.name ~= "" then
				pcall(api.nvim_buf_set_name, new_bufnr, deleted.name)
			end
			api.nvim_buf_set_lines(new_bufnr, 0, -1, false, deleted.content)
			vim.bo[new_bufnr].modified = deleted.modified

			if M.origin_win and api.nvim_win_is_valid(M.origin_win) then
				vim.fn.win_execute(M.origin_win, "buffer " .. new_bufnr)
				for i = 1, 100 do
					vim.fn.win_execute(M.origin_win, "BufferLineMovePrev")
				end
				for i = 1, deleted.position - 1 do
					vim.fn.win_execute(M.origin_win, "BufferLineMoveNext")
				end
			end

			table.insert(M.buffer_order, deleted.position, new_bufnr)
			vim.notify("Restored: " .. (deleted.name ~= "" and deleted.name or "[No Name]"), vim.log.levels.INFO)
		end
	end

	vim.schedule(function()
		update_window_title()
		apply_smart_path_decorations()
	end)
end

local function smart_redo()
	local before_lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local before_count = #before_lines

	vim.cmd("silent! redo")

	local after_lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local after_count = #after_lines

	if after_count < before_count then
		local deleted_index = 1
		for i = 1, after_count do
			if before_lines[i] ~= after_lines[i] then
				deleted_index = i
				break
			end
		end
		if
			deleted_index == 1
			and before_count > after_count
			and before_lines[before_count] ~= (after_lines[after_count] or "")
		then
			deleted_index = before_count
		end

		local bufnr = M.buffer_order[deleted_index]
		if bufnr and api.nvim_buf_is_valid(bufnr) then
			local buf_info = {
				bufnr = bufnr,
				name = vim.fn.bufname(bufnr),
				position = deleted_index,
				content = api.nvim_buf_get_lines(bufnr, 0, -1, false),
				modified = vim.bo[bufnr].modified,
			}
			table.insert(M.deleted_buffers, buf_info)
			pcall(vim.cmd, "bdelete " .. bufnr)
			table.remove(M.buffer_order, deleted_index)
		end
	end

	vim.schedule(function()
		update_window_title()
		apply_smart_path_decorations()
	end)
end

function M.save_changes()
	if not M.manager_buf or not api.nvim_buf_is_valid(M.manager_buf) then
		return
	end

	local lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local changes = {}

	-- Collect changes
	for i, line in ipairs(lines) do
		local bufnr = M.buffer_order[i]
		if bufnr and api.nvim_buf_is_valid(bufnr) then
			local new_name = extract_filename(line)
			local old_name = vim.fn.bufname(bufnr)
			local old_display = old_name ~= "" and vim.fn.fnamemodify(old_name, ":t") or "[No Name]"

			if new_name and new_name ~= old_display and new_name ~= "[No Name]" then
				table.insert(changes, { bufnr = bufnr, old = old_name, new = new_name })
			end
		end
	end

	-- Apply changes
	if #changes > 0 then
		local success_count = 0
		for _, change in ipairs(changes) do
			local old_path = change.old
			if old_path == "" then
				-- Buffer has no name, just set new name
				local ok = pcall(vim.api.nvim_buf_set_name, change.bufnr, change.new)
				if ok then
					success_count = success_count + 1
				end
			else
				-- Rename the file
				local old_dir = vim.fn.fnamemodify(old_path, ":h")
				local new_path = vim.fn.fnamemodify(old_dir .. "/" .. change.new, ":p")

				-- Check if target file already exists
				if vim.fn.filereadable(new_path) == 1 then
					local choice = vim.fn.confirm(
						string.format("File '%s' already exists. Overwrite?", change.new),
						"&Yes\n&No",
						2 -- default to No
					)
					if choice ~= 1 then
						vim.notify("Skipped: " .. change.new, vim.log.levels.WARN)
						goto continue
					end
				end

				-- Check if file exists
				if vim.fn.filereadable(old_path) == 1 then
					-- vim.fn.rename returns 0 on success, -1 on failure
					local result = vim.fn.rename(old_path, new_path)

					if result == 0 then
						-- Success - update buffer name
						local ok = pcall(vim.api.nvim_buf_set_name, change.bufnr, new_path)
						if ok then
							-- Mark buffer as unchanged
							vim.bo[change.bufnr].modified = false
							success_count = success_count + 1
						else
							vim.notify("Failed to update buffer name for: " .. change.new, vim.log.levels.ERROR)
						end
					else
						vim.notify(
							"Failed to rename file: " .. vim.fn.fnamemodify(old_path, ":t"),
							vim.log.levels.ERROR
						)
					end
				else
					-- File doesn't exist yet, just update buffer name
					local ok = pcall(vim.api.nvim_buf_set_name, change.bufnr, new_path)
					if ok then
						success_count = success_count + 1
					end
				end
			end
			::continue::
		end

		if success_count > 0 then
			vim.notify("Renamed " .. success_count .. " buffer(s)", vim.log.levels.INFO)
		end

		-- Call refresh with a small delay to avoid conflicts
		vim.defer_fn(M.refresh_display, 100)
	else
		vim.notify("No changes to save", vim.log.levels.INFO)
	end

	update_window_title()

	vim.bo[M.manager_buf].modified = false
end

function M.refresh_display()
	if not M.manager_buf or not api.nvim_buf_is_valid(M.manager_buf) then
		return
	end

	if M.is_refreshing then
		return
	end

	M.is_refreshing = true

	-- Save current lines to preserve any edits
	local current_lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
	local edited_lines = {}

	-- Check which lines were edited
	for i, line in ipairs(current_lines) do
		local bufnr = M.buffer_order[i]
		if bufnr and api.nvim_buf_is_valid(bufnr) then
			local expected = format_buffer_name(bufnr, vim.fn.bufname(bufnr))
			if line ~= expected then
				-- This line was edited, preserve it
				edited_lines[bufnr] = line
			end
		end
	end

	local buffers = get_bufferline_order()
	local buf_lines = {}
	M.buffer_order = {}

	for _, b in ipairs(buffers) do
		-- Use edited line if it exists, otherwise use formatted name
		local display_name
		if edited_lines[b.bufnr] then
			display_name = edited_lines[b.bufnr]
		else
			display_name = format_buffer_name(b.bufnr, b.name)
		end
		table.insert(buf_lines, display_name)
		table.insert(M.buffer_order, b.bufnr)
	end

	local cursor_pos = api.nvim_win_get_cursor(M.manager_win)
	api.nvim_buf_set_lines(M.manager_buf, 0, -1, false, buf_lines)

	-- Apply virtual text for duplicate filenames
	apply_smart_path_decorations(buffers)

	if api.nvim_win_is_valid(M.manager_win) then
		cursor_pos[1] = math.min(cursor_pos[1], #buf_lines)
		cursor_pos[1] = math.max(cursor_pos[1], 1)
		pcall(api.nvim_win_set_cursor, M.manager_win, cursor_pos)
	end

	-- Update window title to show unsaved changes
	update_window_title()

	M.is_refreshing = false
end

function M.delete_line()
	if not M.manager_win or not api.nvim_win_is_valid(M.manager_win) then
		return
	end

	local cursor = api.nvim_win_get_cursor(M.manager_win)
	local line_num = cursor[1]

	local bufnr = M.buffer_order[line_num]
	if bufnr then
		if M.config.confirm_delete then
			local bufname = vim.fn.bufname(bufnr)
			local display_name = bufname ~= "" and bufname or "[No Name]"
			local choice = vim.fn.confirm("Delete buffer " .. bufnr .. ": " .. display_name .. "?", "&Yes\n&No", 2)
			if choice ~= 1 then
				return
			end
		end

		-- Store buffer info before deleting for potential undo
		local buf_info = {
			bufnr = bufnr,
			name = vim.fn.bufname(bufnr),
			position = line_num,
			content = api.nvim_buf_get_lines(bufnr, 0, -1, false),
			modified = vim.bo[bufnr].modified,
		}
		table.insert(M.deleted_buffers, buf_info)

		-- Check if this is the current buffer in origin window
		local is_current = false
		if M.origin_win and api.nvim_win_is_valid(M.origin_win) then
			local current_buf = api.nvim_win_get_buf(M.origin_win)
			is_current = (current_buf == bufnr)
		end

		-- If deleting current buffer, switch to another buffer first
		if is_current then
			local next_bufnr = nil

			-- Try next buffer
			if line_num < #M.buffer_order then
				next_bufnr = M.buffer_order[line_num + 1]
			elseif line_num > 1 then
				-- If last buffer, try previous
				next_bufnr = M.buffer_order[line_num - 1]
			end

			-- Switch to alt buffer before deleting
			if
				next_bufnr
				and api.nvim_buf_is_valid(next_bufnr)
				and M.origin_win
				and api.nvim_win_is_valid(M.origin_win)
			then
				vim.fn.win_execute(M.origin_win, "buffer " .. next_bufnr)
			end
		end

		pcall(vim.cmd, "bdelete " .. bufnr)
		vim.defer_fn(M.refresh_display, 50)
	end
end

function M.move_line_down()
	if not M.manager_win or not api.nvim_win_is_valid(M.manager_win) then
		return
	end

	local cursor = api.nvim_win_get_cursor(M.manager_win)
	local line_num = cursor[1]

	if line_num >= #M.buffer_order then
		return
	end

	local bufnr = M.buffer_order[line_num]
	if bufnr then
		if M.origin_win and api.nvim_win_is_valid(M.origin_win) then
			vim.fn.win_execute(M.origin_win, "buffer " .. bufnr)
			vim.fn.win_execute(M.origin_win, "BufferLineMoveNext")
		end

		vim.defer_fn(function()
			M.refresh_display()
			if api.nvim_win_is_valid(M.manager_win) then
				cursor[1] = math.min(cursor[1] + 1, #M.buffer_order)
				pcall(api.nvim_win_set_cursor, M.manager_win, cursor)
			end
		end, 50)
	end
end

function M.move_line_up()
	if not M.manager_win or not api.nvim_win_is_valid(M.manager_win) then
		return
	end

	local cursor = api.nvim_win_get_cursor(M.manager_win)
	local line_num = cursor[1]

	if line_num <= 1 then
		return
	end

	local bufnr = M.buffer_order[line_num]
	if bufnr then
		if M.origin_win and api.nvim_win_is_valid(M.origin_win) then
			vim.fn.win_execute(M.origin_win, "buffer " .. bufnr)
			vim.fn.win_execute(M.origin_win, "BufferLineMovePrev")
		end

		vim.defer_fn(function()
			M.refresh_display()
			if api.nvim_win_is_valid(M.manager_win) then
				cursor[1] = math.max(cursor[1] - 1, 1)
				pcall(api.nvim_win_set_cursor, M.manager_win, cursor)
			end
		end, 50)
	end
end

function M.jump_to_buffer()
	if not M.manager_win or not api.nvim_win_is_valid(M.manager_win) then
		return
	end

	local cursor = api.nvim_win_get_cursor(M.manager_win)
	local bufnr = M.buffer_order[cursor[1]]
	if bufnr then
		if M.manager_win and api.nvim_win_is_valid(M.manager_win) then
			api.nvim_win_close(M.manager_win, true)
		end
		if M.origin_win and api.nvim_win_is_valid(M.origin_win) then
			api.nvim_set_current_win(M.origin_win)
		end
		vim.cmd("buffer " .. bufnr)
	end
end

function M.close()
	local pending = get_pending_changes()

	if #pending > 0 then
		-- Build change summary
		local change_summary = "Unsaved changes:\n\n"
		for _, change in ipairs(pending) do
			change_summary = change_summary .. string.format("  %s → %s\n", change.old, change.new)
		end
		change_summary = change_summary .. "\nSave changes?"

		local choice = vim.fn.confirm(change_summary, "&Yes\n&No\n&Cancel", 1)

		if choice == 1 then
			-- Yes - Save and close
			M.save_changes()
		elseif choice == 2 then
			-- No - Close without saving
		elseif choice == 3 or choice == 0 then
			-- Cancel or ESC - Don't close
			return
		end
	end

	if M.manager_win and api.nvim_win_is_valid(M.manager_win) then
		api.nvim_win_close(M.manager_win, true)
	end
	M.manager_win = nil
	M.manager_buf = nil
	if M.origin_win and api.nvim_win_is_valid(M.origin_win) then
		api.nvim_set_current_win(M.origin_win)
	end
end

function M.open()
	M.origin_win = api.nvim_get_current_win()
	M.deleted_buffers = {}

	local buffers = get_bufferline_order()
	local buf_lines = {}
	M.buffer_order = {}

	for _, b in ipairs(buffers) do
		local display_name = format_buffer_name(b.bufnr, b.name)
		table.insert(buf_lines, display_name)
		table.insert(M.buffer_order, b.bufnr)
	end

	M.manager_buf = api.nvim_create_buf(false, true)
	pcall(api.nvim_buf_set_name, M.manager_buf, "[Buffer Manager]")
	api.nvim_buf_set_lines(M.manager_buf, 0, -1, false, buf_lines)
	vim.bo[M.manager_buf].buftype = "acwrite"
	vim.bo[M.manager_buf].bufhidden = "wipe"
	vim.bo[M.manager_buf].modifiable = true
	vim.bo[M.manager_buf].filetype = "bufferline-manager"

	-- Clear undo history to prevent 'u' from undoing to empty state
	vim.api.nvim_buf_call(M.manager_buf, function()
		local old_undolevels = vim.bo.undolevels
		vim.bo.undolevels = -1
		vim.cmd([[execute "normal! a \<BS>\<Esc>"]])
		vim.bo.undolevels = old_undolevels
	end)

	local width = math.min(M.config.width, math.floor(vim.o.columns * 0.8))
	local height = math.min(M.config.height, #buf_lines + 2)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	M.manager_win = api.nvim_open_win(M.manager_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = M.config.border,
		title = M.config.title,
		title_pos = "center",
	})

	vim.wo[M.manager_win].cursorline = true
	vim.wo[M.manager_win].number = true

	-- Handle line number settings
	if M.config.show_numbers then
		vim.wo[M.manager_win].number = true

		if M.config.use_relative == nil then
			if M.origin_win and api.nvim_win_is_valid(M.origin_win) then
				vim.wo[M.manager_win].relativenumber = vim.wo[M.origin_win].relativenumber
			else
				vim.wo[M.manager_win].relativenumber = vim.wo.relativenumber
			end
		else
			vim.wo[M.manager_win].relativenumber = M.config.use_relative
		end
	else
		vim.wo[M.manager_win].number = false
		vim.wo[M.manager_win].relativenumber = false
	end

	-- Apply virtual text for dupe filenames
	apply_smart_path_decorations(buffers)

	-- Handle text changes and undo/redo
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = M.manager_buf,
		callback = function()
			if M.is_refreshing then
				return
			end

			local current_lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
			local expected_count = #M.buffer_order

			-- Check if line count changed
			if #current_lines ~= expected_count then
				-- Check if undo is trying to restore a deleted buffer's line
				if #current_lines > expected_count then
					-- Lines were added (likely from undo)
					-- Refresh to the current state - don't allow undo of deletions
					vim.notify("Cannot undo buffer deletion. Buffer is already closed.", vim.log.levels.WARN)
					M.refresh_display()
				elseif #current_lines < expected_count then
					-- Lines were removed (not through dd)
					vim.notify(
						"Cannot delete lines directly. Use '" .. M.config.keymaps.delete .. "' to delete buffers.",
						vim.log.levels.WARN
					)
					M.refresh_display()
				end
			else
				-- Line count is correct, update title for potential renames
				update_window_title()
			end
		end,
	})

	-- Set up BufWriteCmd for :w to save changes
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = M.manager_buf,
		callback = function()
			M.save_changes()
			-- Prevent the "No file name" error
			vim.bo[M.manager_buf].modified = false
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = M.manager_buf,
		callback = function()
			if not M.is_refreshing then
				update_window_title()
			end
		end,
	})

	local opts_key = { noremap = true, silent = true, buffer = M.manager_buf }

	--TODO: not actually necessary because of how we save now and check for errors now
	-- Block line deletion commands (use dd keymap instead)
	-- local block_delete_keys = { "d", "D", "x", "X", "s", "S" }
	-- for _, key in ipairs(block_delete_keys) do
	-- 	vim.keymap.set("n", key, function()
	-- 		vim.notify("Use '" .. M.config.keymaps.delete .. "' to delete buffers", vim.log.levels.WARN)
	-- 	end, vim.tbl_extend("force", opts_key, { desc = "Blocked - use " .. M.config.keymaps.delete }))
	-- end

	-- Block change commands that would delete
	-- vim.keymap.set("n", "c", function()
	-- 	vim.notify("Use 'cw' or 'C' to edit buffer name", vim.log.levels.WARN)
	-- end, vim.tbl_extend("force", opts_key, { desc = "Blocked - use cw or C" }))

	-- Block visual mode deletion
	-- vim.keymap.set("v", "d", function()
	-- 	vim.notify("Cannot delete lines. Use '" .. M.config.keymaps.delete .. "' in normal mode", vim.log.levels.WARN)
	-- end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	-- vim.keymap.set("v", "c", function()
	-- 	vim.notify("Cannot delete lines. Use '" .. M.config.keymaps.delete .. "' in normal mode", vim.log.levels.WARN)
	-- end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	-- Allow editing with cw and C
	-- vim.keymap.set("n", "cw", "0C", vim.tbl_extend("force", opts_key, { desc = "Edit buffer name" }))
	-- vim.keymap.set("n", "C", "0C", vim.tbl_extend("force", opts_key, { desc = "Edit buffer name" }))

	-- Block new line below
	vim.keymap.set("n", "o", function()
		vim.notify("Cannot add new buffers here", vim.log.levels.WARN)
	end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	-- Block new line above
	vim.keymap.set("n", "O", function()
		vim.notify("Cannot add new buffers here", vim.log.levels.WARN)
	end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	-- Delete keymap
	vim.keymap.set("n", M.config.keymaps.delete, function()
		M.delete_line()
	end, vim.tbl_extend("force", opts_key, { desc = "Delete buffer" }))

	-- Move down keymap
	vim.keymap.set("n", M.config.keymaps.move_down, function()
		M.move_line_down()
	end, vim.tbl_extend("force", opts_key, { desc = "Move buffer down/right" }))

	-- Move up keymap
	vim.keymap.set("n", M.config.keymaps.move_up, function()
		M.move_line_up()
	end, vim.tbl_extend("force", opts_key, { desc = "Move buffer up/left" }))

	-- Jump keymap
	vim.keymap.set("n", M.config.keymaps.jump, function()
		M.jump_to_buffer()
	end, vim.tbl_extend("force", opts_key, { desc = "Jump to buffer" }))

	-- Smart undo
	vim.keymap.set("n", "u", function()
		smart_undo()
	end, vim.tbl_extend("force", opts_key, { desc = "Smart undo (text only)" }))

	-- Smart redo
	vim.keymap.set("n", "<C-r>", function()
		smart_redo()
	end, vim.tbl_extend("force", opts_key, { desc = "Smart redo (text only)" }))

	-- Close keymaps
	local close_keys = type(M.config.keymaps.close) == "table" and M.config.keymaps.close or { M.config.keymaps.close }
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, function()
			M.close()
		end, vim.tbl_extend("force", opts_key, { desc = "Close manager" }))
	end

	-- Refresh keymap
	vim.keymap.set("n", M.config.keymaps.refresh, function()
		M.refresh_display()
	end, vim.tbl_extend("force", opts_key, { desc = "Refresh" }))

	-- Save keymap (normal)
	vim.keymap.set("n", M.config.keymaps.save, function()
		M.save_changes()
	end, vim.tbl_extend("force", opts_key, { desc = "Save changes" }))

	-- Save keymap (insert mode)
	vim.keymap.set("i", M.config.keymaps.save, function()
		vim.cmd("stopinsert")
		M.save_changes()
	end, vim.tbl_extend("force", opts_key, { desc = "Save changes" }))

	-- Make :w call save_changes
	vim.api.nvim_create_autocmd("CmdlineEnter", {
		buffer = M.manager_buf,
		callback = function()
			vim.cmd("cnoreabbrev <buffer> w lua require('bufferline-manager').save_changes()")
		end,
	})
end

return M
