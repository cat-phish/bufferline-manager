local api = vim.api
local M = {}

M.manager_buf = nil
M.manager_win = nil
M.origin_win = nil
M.buffer_order = {}
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
	show_bufnr = true,
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

local function format_buffer_name(bufnr, name)
	local display_name
	if name == "" then
		display_name = "[No Name]"
	elseif M.config.show_full_path then
		display_name = name
	else
		display_name = vim.fn.fnamemodify(name, ":t")
	end

	if M.config.show_bufnr then
		return string.format("%d: %s", bufnr, display_name)
	else
		return display_name
	end
end
local function apply_smart_path_decorations(buffers)
	if not M.config.smart_path or not M.manager_buf or not api.nvim_buf_is_valid(M.manager_buf) then
		return
	end

	local duplicates = get_duplicate_names(buffers)

	-- Clear existing virtual text
	local ns_id = api.nvim_create_namespace("bufferline_manager_smart_path")
	api.nvim_buf_clear_namespace(M.manager_buf, ns_id, 0, -1)

	for i, b in ipairs(buffers) do
		if b.name ~= "" then
			local basename = vim.fn.fnamemodify(b.name, ":t")
			if duplicates[basename] then
				local parent = vim.fn.fnamemodify(b.name, ":h:t")
				-- Add virtual text showing parent folder before the filename
				api.nvim_buf_set_extmark(M.manager_buf, ns_id, i - 1, 0, {
					virt_text = { { parent .. "/", "Comment" } },
					virt_text_pos = "inline",
					right_gravity = false,
				})
			end
		end
	end
end

local function extract_filename(line)
	if M.config.show_bufnr then
		-- Extract from "123: filename" format
		local filename = line:match("^%d+:%s*(.+)$")
		return filename
	else
		return line
	end
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
				-- Buffer has no name, just set the new name
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

	-- Mark the manager buffer as unmodified
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

	local buffers = get_bufferline_order()
	local buf_lines = {}
	M.buffer_order = {}

	for _, b in ipairs(buffers) do
		local display_name = format_buffer_name(b.bufnr, b.name)
		table.insert(buf_lines, display_name)
		table.insert(M.buffer_order, b.bufnr)
	end

	local cursor_pos = api.nvim_win_get_cursor(M.manager_win)
	api.nvim_buf_set_lines(M.manager_buf, 0, -1, false, buf_lines)

	apply_smart_path_decorations(buffers)

	if api.nvim_win_is_valid(M.manager_win) then
		cursor_pos[1] = math.min(cursor_pos[1], #buf_lines)
		cursor_pos[1] = math.max(cursor_pos[1], 1)
		pcall(api.nvim_win_set_cursor, M.manager_win, cursor_pos)
	end

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

	-- Close the window
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

	-- Handle line numbers
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

	apply_smart_path_decorations(buffers)

	-- Prevent adding/deleting lines safety net
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = M.manager_buf,
		callback = function()
			if M.is_refreshing then
				return
			end

			local current_lines = api.nvim_buf_get_lines(M.manager_buf, 0, -1, false)
			local expected_count = #M.buffer_order

			if #current_lines ~= expected_count then
				vim.notify(
					"Cannot add or delete lines. Use '" .. M.config.keymaps.delete .. "' to delete buffers.",
					vim.log.levels.WARN
				)
				M.refresh_display()
			end
		end,
	})

	-- BufWriteCmd for :w to save changes
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = M.manager_buf,
		callback = function()
			M.save_changes()
			-- Prevent "No file name" error
			vim.bo[M.manager_buf].modified = false
		end,
	})

	local opts_key = { noremap = true, silent = true, buffer = M.manager_buf }

	--TODO: not actually necessary because of how we save now
	-- Block line deletion commands (use dd keymap instead)
	-- local block_delete_keys = { "d", "D", "x", "X", "s", "S" }
	-- for _, key in ipairs(block_delete_keys) do
	-- 	vim.keymap.set("n", key, function()
	-- 		vim.notify("Use '" .. M.config.keymaps.delete .. "' to delete buffers", vim.log.levels.WARN)
	-- 	end, vim.tbl_extend("force", opts_key, { desc = "Blocked - use " .. M.config.keymaps.delete }))
	-- end

	-- Block change commands that would delete
	vim.keymap.set("n", "c", function()
		vim.notify("Use 'cw' or 'C' to edit buffer name", vim.log.levels.WARN)
	end, vim.tbl_extend("force", opts_key, { desc = "Blocked - use cw or C" }))

	-- Block visual mode deletion
	vim.keymap.set("v", "d", function()
		vim.notify("Cannot delete lines. Use '" .. M.config.keymaps.delete .. "' in normal mode", vim.log.levels.WARN)
	end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	vim.keymap.set("v", "c", function()
		vim.notify("Cannot delete lines. Use '" .. M.config.keymaps.delete .. "' in normal mode", vim.log.levels.WARN)
	end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	-- Block new line commands
	vim.keymap.set("n", "o", function()
		vim.notify("Cannot add new buffers here", vim.log.levels.WARN)
	end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	vim.keymap.set("n", "O", function()
		vim.notify("Cannot add new buffers here", vim.log.levels.WARN)
	end, vim.tbl_extend("force", opts_key, { desc = "Blocked" }))

	-- Allow editing with cw and C (skip bufnr prefix if present)
	if M.config.show_bufnr then
		vim.keymap.set("n", "cw", "0f:2lC", vim.tbl_extend("force", opts_key, { desc = "Edit buffer name" }))
		vim.keymap.set("n", "C", "0f:2lC", vim.tbl_extend("force", opts_key, { desc = "Edit buffer name" }))
	else
		vim.keymap.set("n", "cw", "0C", vim.tbl_extend("force", opts_key, { desc = "Edit buffer name" }))
		vim.keymap.set("n", "C", "0C", vim.tbl_extend("force", opts_key, { desc = "Edit buffer name" }))
	end

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

	-- Make :w call save_changes (cabbrev approach)
	vim.api.nvim_create_autocmd("CmdlineEnter", {
		buffer = M.manager_buf,
		callback = function()
			vim.cmd("cnoreabbrev <buffer> w lua require('bufferline-manager').save_changes()")
		end,
	})
end

return M
