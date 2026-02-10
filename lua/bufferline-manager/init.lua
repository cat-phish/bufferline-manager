local api = vim.api
local M = {}

M.manager_buf = nil
M.manager_win = nil
M.origin_win = nil
M.buffer_order = {}

-- Default config
M.config = {
	width = 80,
	height = 20,
	border = "rounded",
	title = " Buffer Manager ",
	show_full_path = false,
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
	},
}

function M.setup(opts)
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

local function refresh_display()
	if not M.manager_buf or not api.nvim_buf_is_valid(M.manager_buf) then
		return
	end

	local buffers = get_bufferline_order()
	local buf_lines = {}
	M.buffer_order = {}

	for _, b in ipairs(buffers) do
		local display_name = format_buffer_name(b.bufnr, b.name)
		table.insert(buf_lines, display_name)
		table.insert(M.buffer_order, b.bufnr)
	end

	local cursor_pos = api.nvim_win_get_cursor(M.manager_win)
	vim.bo[M.manager_buf].modifiable = true
	api.nvim_buf_set_lines(M.manager_buf, 0, -1, false, buf_lines)
	vim.bo[M.manager_buf].modifiable = false

	if api.nvim_win_is_valid(M.manager_win) then
		cursor_pos[1] = math.min(cursor_pos[1], #buf_lines)
		cursor_pos[1] = math.max(cursor_pos[1], 1)
		pcall(api.nvim_win_set_cursor, M.manager_win, cursor_pos)
	end
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
		vim.defer_fn(refresh_display, 50)
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
			refresh_display()
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
			refresh_display()
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
	api.nvim_buf_set_lines(M.manager_buf, 0, -1, false, buf_lines)
	vim.bo[M.manager_buf].buftype = "nofile"
	vim.bo[M.manager_buf].bufhidden = "wipe"
	vim.bo[M.manager_buf].modifiable = false
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
			-- Use the user's current setting from origin window
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

	local opts_key = { noremap = true, silent = true, buffer = M.manager_buf }

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
		refresh_display()
	end, vim.tbl_extend("force", opts_key, { desc = "Refresh" }))
end

return M
