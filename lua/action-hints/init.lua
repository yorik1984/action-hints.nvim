local M = {}
M.is_enabled = true

local default_definition_color
local default_references_color

if vim.o.termguicolors then
	default_definition_color = "#add8e6"
	default_references_color = "#ffade6"
else
	default_definition_color = "blue"
	default_references_color = "red"
end

M.config = {
	template = {
		definition = { text = " %s", color = default_definition_color },
		references = { text = " %s", color = default_references_color },
	},
	use_virtual_text = false,
}

M.references_available = false
M.reference_count = 0
M.definition_available = false
M.definition_count = 0

local references_namespace = vim.api.nvim_create_namespace("action_hints_references")
local last_virtual_text_line = nil

local function debounce(func, delay)
	local timer_id = nil
	return function(...)
		if timer_id then
			vim.fn.timer_stop(timer_id)
		end
		local args = { ... }
		timer_id = vim.fn.timer_start(delay, function()
			func(unpack(args))
		end)
	end
end

-- Check if LSP supports a specific method for active buffer
M.supports_method = function(method)
	local clients = vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf() })
	for _, client in ipairs(clients) do
		if client.supports_method and client:supports_method(method) then
			return true
		end
	end
	return false
end

local function set_virtual_text(bufnr, line, chunks)
	-- Clear the virtual text from the previous line
	if last_virtual_text_line then
		vim.api.nvim_buf_clear_namespace(
			bufnr,
			references_namespace,
			last_virtual_text_line,
			last_virtual_text_line + 1
		)
	end

	-- Check for conditions where you might want to exit early
	if
		vim.api.nvim_buf_get_option(bufnr, "buftype") ~= ""
		or vim.api.nvim_buf_get_option(bufnr, "filetype") == "help"
		or vim.fn.bufname(bufnr) == ""
	then
		-- Reset the last virtual text line to ensure it gets cleared next time
		last_virtual_text_line = nil
		return
	end

	-- Prepare the virtual text with proper highlight groups
	local virtual_text_chunks = {}
	for _, chunk in ipairs(chunks) do
		table.insert(virtual_text_chunks, { chunk[1], chunk[2] })
	end

	-- Set the virtual text for the current line
	-- vim.api.nvim_buf_set_virtual_text(bufnr, references_namespace, line, virtual_text_chunks, {})
	vim.api.nvim_buf_set_extmark(bufnr, references_namespace, line, 0, {
		virt_text = virtual_text_chunks,
		virt_text_pos = "eol",
	})
	last_virtual_text_line = line
end

local function update_virtual_text()
	if M.config.use_virtual_text then
		local bufnr = vim.api.nvim_get_current_buf()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local definition_status = M.definition_count > 0
				and string.format(M.config.template.definition.text, tostring(M.definition_count))
			or ""
		local reference_status = M.reference_count > 0
				and string.format(M.config.template.references.text, tostring(M.reference_count))
			or ""
		local chunks = {
			{ definition_status, "ActionHintsDefinition" },
			{ reference_status, "ActionHintsReferences" },
		}

		set_virtual_text(bufnr, cursor[1] - 1, chunks)
	end
end

local function is_cursor_on_whitespace()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]
	local char = line:sub(cursor[2] + 1, cursor[2] + 1)
	return char:match("^%s$") ~= nil
end

local function references()
	if not M.supports_method("textDocument/references") then
		return
	end

	if is_cursor_on_whitespace() then
		M.clear_virtual_text()
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local bufname = vim.uri_from_bufnr(bufnr)

	local params = {
		textDocument = { uri = bufname },
		position = { line = cursor[1] - 1, character = cursor[2] },
		context = { includeDeclaration = true },
	}

	vim.lsp.buf_request(bufnr, "textDocument/references", params, function(err, result, _, _)
		if err or not result then
			M.references_available = false
			M.reference_count = 0
			M.clear_virtual_text()
			return
		end

		if vim.tbl_count(result) > 0 then
			M.references_available = true
			M.reference_count = vim.tbl_count(result) - 1
			update_virtual_text()
			return
		end

		M.references_available = false
		M.reference_count = 0
		M.clear_virtual_text()
	end)
end

local function definition()
	if not M.supports_method("textDocument/definition") then
		return
	end

	if is_cursor_on_whitespace() then
		M.clear_virtual_text()
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local bufname = vim.uri_from_bufnr(bufnr)

	local params = {
		textDocument = { uri = bufname },
		position = { line = cursor[1] - 1, character = cursor[2] },
	}

	vim.lsp.buf_request(bufnr, "textDocument/definition", params, function(err, result, _, _)
		if err or not result then
			M.definition_available = false
			M.definition_count = 0
			M.clear_virtual_text()
			return
		end

		if vim.tbl_count(result) > 0 then
			M.definition_available = true
			M.definition_count = vim.tbl_count(result)
			update_virtual_text()
			return
		end

		M.clear_virtual_text()
		M.definition_available = false
		M.definition_count = 0
	end)
end

M.clear_virtual_text = function()
	local bufnr = vim.api.nvim_get_current_buf()
	if last_virtual_text_line then
		vim.api.nvim_buf_clear_namespace(
			bufnr,
			references_namespace,
			last_virtual_text_line,
			last_virtual_text_line + 1
		)
		last_virtual_text_line = nil
	end
end

local debounced_references = debounce(references, 100)
local debounced_definition = debounce(definition, 100)

M.update = function()
	if M.is_enabled then
		local mode = vim.api.nvim_get_mode().mode
		if mode == "n" or mode == "v" or mode == "V" or mode == "\22" then
			debounced_references()
			debounced_definition()
		else
			M.clear_virtual_text()
		end
	end
end

M.statusline = function()
	local definition_status = M.definition_count > 0
			and string.format(M.config.template.definition.text, tostring(M.definition_count))
		or ""
	local reference_status = M.reference_count > 0
			and string.format(M.config.template.references.text, tostring(M.reference_count))
		or ""
	local chunks = {
		{ definition_status, "ActionHintsDefinition" },
		{ reference_status, "ActionHintsReferences" },
	}

	local text = ""
	for _, chunk in ipairs(chunks) do
		text = text .. chunk[1]
	end

	return text
end

M.set_highlight = function()
	if vim.o.termguicolors then
		vim.api.nvim_command(
			"highlight ActionHintsDefinition ctermfg=NONE guifg=" .. M.config.template.definition.color
		)
		vim.api.nvim_command(
			"highlight ActionHintsReferences ctermfg=NONE guifg=" .. M.config.template.references.color
		)
	else
		vim.api.nvim_command(
			"highlight ActionHintsDefinition guifg=NONE ctermfg=" .. M.config.template.definition.color
		)
		vim.api.nvim_command(
			"highlight ActionHintsReferences guifg=NONE ctermfg=" .. M.config.template.references.color
		)
	end
end

M.setup = function(options)
	if options == nil then
		options = {}
	end

	-- Merge keys
	for k, v in pairs(options) do
		if k == "template" and type(v) == "table" then
			for tk, tv in pairs(v) do
				M.config.template[tk] = tv
			end
		else
			M.config[k] = v
		end
		vim.api.nvim_command(
			[[autocmd CursorMoved * lua if vim.fn.index({'n', 'v', 'V','\22'}, vim.api.nvim_get_mode().mode) >= 0 then require('action-hints').update() end]]
		)
		vim.api.nvim_command([[autocmd CursorMovedI * lua require('action-hints').clear_virtual_text()]])
	end

	M.set_highlight()

	vim.api.nvim_command([[autocmd OptionSet termguicolors lua require("action-hints").set_highlight()]])
	vim.api.nvim_command([[autocmd CursorMoved * lua require("action-hints").update()]])
	vim.api.nvim_command([[autocmd CursorMovedI * lua require("action-hints").update()]])
end

vim.api.nvim_create_user_command("ChangeActionHintsStat", function()
	if M.is_enabled then
		M.is_enabled = false
		M.clear_virtual_text()
	else
		M.is_enabled = true
		M.update()
	end
end, {})
vim.api.nvim_set_keymap("n", "<leader>aa", ":ChangeActionHintsStat<CR>", { noremap = true })
return M
