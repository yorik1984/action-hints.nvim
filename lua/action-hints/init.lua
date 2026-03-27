local M = {}

M.is_enabled = true
M.statusline_enabled = true

local H = {}
H.ranges = {}
H.current_range = {}
H.request_id = 0
H.bufnr = vim.api.nvim_get_current_buf()
H.cancel_fn = nil
H.ns_id = vim.api.nvim_create_namespace("action_hints_highlight")

--- Get the foreground color of a highlight group as a hex string.
--- Uses vim.api.nvim_get_hl wrapped in pcall to avoid hard errors.
--- @param group_name string Name of the highlight group (e.g. "Typedef")
--- @return string|nil Hex color string like "#rrggbb" or nil if not found
M.get_fg_color = function(group_name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group_name })
    if not ok or not hl then
        return nil
    end
    local fg = hl.fg
    if not fg then
        return nil
    end
    if type(fg) == "number" then
        return string.format("#%06x", fg % 0x1000000)
    elseif type(fg) == "string" then
        if fg:sub(1, 1) == "#" then
            return fg
        else
            return "#" .. fg
        end
    end
    return nil
end

---@class ActionHintsTemplateEntry
---@field text string
---@field color string|nil
---@field link string|nil

---@class ActionHintsConfigTemplate
---@field definition ActionHintsTemplateEntry
---@field references ActionHintsTemplateEntry

---@class ActionHintsConfig
---@field template ActionHintsConfigTemplate
---@field ignored string[]
---@field use_virtual_text boolean
---@field statusline_colored boolean

---@type ActionHintsConfig
M.config = {
    template = {
        definition = {
            text = " ⊛%s",
            color = nil,
            link = "Typedef",
        },
        references = {
            text = " ↱%s",
            color = nil,
            link = "Type",
        },
    },
    ignored = {},
    use_virtual_text = true,
    statusline_colored = true,
}

M.set_highlight = function(config)
    local cfg = config or M.config
    local template = cfg.template or {}

    local def = template.definition or {}
    if def.color then
        vim.api.nvim_set_hl(0, "ActionHintsDefinition", { fg = def.color, default = true })
    else
        vim.api.nvim_set_hl(0, "ActionHintsDefinition", { link = def.link, default = true })
    end

    local ref = template.references or {}
    if ref.color then
        vim.api.nvim_set_hl(0, "ActionHintsReferences", { fg = ref.color, default = true })
    else
        vim.api.nvim_set_hl(0, "ActionHintsReferences", { link = ref.link, default = true })
    end

    vim.api.nvim_set_hl(0, "ActionHintsHighlight", { link = "ActionHintsDefinition", default = true })

    local statusline_colored = (config and config.statusline_colored ~= nil) and config.statusline_colored
        or M.config.statusline_colored

    if statusline_colored then
        vim.api.nvim_set_hl(0, "ActionHintsDefinitionStatusLine", { link = "ActionHintsDefinition" })
        vim.api.nvim_set_hl(0, "ActionHintsReferencesStatusLine", { link = "ActionHintsReferences" })
    else
        vim.api.nvim_set_hl(0, "ActionHintsDefinitionStatusLine", { fg = "NONE" })
        vim.api.nvim_set_hl(0, "ActionHintsReferencesStatusLine", { fg = "NONE" })
    end
end

---@type boolean
M.references_available = false
---@type integer
M.reference_count = 0
---@type boolean
M.definition_available = false
---@type integer
M.definition_count = 0

local references_namespace = vim.api.nvim_create_namespace("action_hints_references")
local last_virtual_text_line = nil

local function debounce(func, delay_ms)
    local timer = nil
    return function(...)
        local args = { ... }
        if timer then
            timer:stop()
            timer:close()
        end
        timer = vim.defer_fn(function()
            timer = nil
            func(unpack(args))
        end, delay_ms)
    end
end

-- Check if LSP supports a specific method for a buffer.
M.supports_method = function(method, bufnr)
    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    for _, client in ipairs(clients) do
        if client.supports_method and client:supports_method(method) then
            return true
        end
    end
    return false
end

M.is_ignored = function(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return true
    end

    local cfg = M.config or {}
    local ignored = cfg.ignored
    if not ignored or type(ignored) ~= "table" or #ignored == 0 then
        return false
    end

    local ft = vim.bo[bufnr].filetype or ""
    if ft ~= "" then
        for _, v in ipairs(ignored) do
            if v == ft then
                return true
            end
        end
    end

    local name = vim.api.nvim_buf_get_name(bufnr) or ""
    if name ~= "" then
        for _, v in ipairs(ignored) do
            if type(v) == "string" and v ~= "" then
                local matched = string.match(name, v)
                if matched then
                    return true
                end
                if name:find(v, 1, true) then
                    return true
                end
            end
        end
    else
        for _, v in ipairs(ignored) do
            if v == "" then
                return true
            end
        end
    end

    return false
end

---update id for version control
---@param id integer
---@return integer
local function update_id(id)
    if id == 1e9 then
        id = 0
    end
    id = id + 1
    return id
end

---check if the position is in the range
---@param pos table<integer> Position { line, col } (0-indexed)
---@param range { start: { line: integer, character: integer }, ["end"]: { line: integer, character: integer } } LSP range object
---@return boolean true if position is inside the range
local function is_in_range(pos, range)
    if vim.tbl_isempty(range) then
        return false
    end
    local line, col = pos[1], pos[2]
    if line < range.start.line or line > range["end"].line then
        return false
    elseif line == range.start.line and col < range["start"].character then
        return false
    elseif line == range["end"].line and col > range["end"].character then
        return false
    end
    return true
end

---check if the position is in any ranges
---@param pos table<integer>
---@param ranges table
---@return boolean
local function is_in_any_range(pos, ranges)
    if not vim.tbl_isempty(H.current_range) and is_in_range(pos, H.current_range.range) then
        return true
    else
        for _, range in ipairs(ranges) do
            if is_in_range(pos, range.range) then
                H.current_range = range
                return true
            end
        end
        return false
    end
end

---@return table
local function get_cursor_pos()
    local pos = vim.api.nvim_win_get_cursor(0)
    -- the pos is (1,0)-indexed
    return { pos[1] - 1, pos[2] }
end

---highlight the ranges
---@param bufnr integer
---@param ranges table
local function apply_highlight(bufnr, ranges)
    for _, range in ipairs(ranges) do
        vim.api.nvim_buf_set_extmark(
            bufnr,
            H.ns_id,
            range["range"]["start"]["line"],
            range["range"]["start"]["character"],
            {
                end_line = range["range"]["end"]["line"],
                end_col = range["range"]["end"]["character"],
                hl_group = "ActionHintsHighlight",
            }
        )
    end
end

---clear current highlights
---@param bufnr integer
local function clear_highlight(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, H.ns_id, 0, -1)
    end
    H.ranges = {}
    H.current_range = {}
end

---the core implementation
---@param bufnr integer
---@param id integer
local function request_highlight(bufnr, id)
    local method = "textDocument/documentHighlight"
    if not M.supports_method(method, bufnr) then
        return
    end

    if H.cancel_fn ~= nil then
        pcall(H.cancel_fn)
    end

    local winid = vim.api.nvim_get_current_win()
    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })

    if #clients == 0 then
        return
    end

    local params = function(client)
        return vim.lsp.util.make_position_params(winid, client.offset_encoding)
    end

    local cancel_fn = vim.lsp.buf_request_all(bufnr, method, params, function(results)
        if bufnr ~= H.bufnr or H.request_id ~= id then
            return
        end

        local ranges = {}
        for _, resultObj in pairs(results) do
            local result = resultObj["result"]
            if result == nil then
                return
            end
            for _, res in ipairs(result) do
                table.insert(ranges, res)
            end
        end
        H.ranges = ranges

        apply_highlight(bufnr, H.ranges)
    end)

    H.cancel_fn = cancel_fn
end

local function set_virtual_text(bufnr, line, chunks)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        last_virtual_text_line = nil
        return
    end

    if last_virtual_text_line then
        vim.api.nvim_buf_clear_namespace(
            bufnr,
            references_namespace,
            last_virtual_text_line,
            last_virtual_text_line + 1
        )
    end

    local buftype = vim.bo[bufnr].buftype or ""
    local filetype = vim.bo[bufnr].filetype or ""
    local name = vim.api.nvim_buf_get_name(bufnr) or ""

    if buftype ~= "" or filetype == "help" or name == "" then
        last_virtual_text_line = nil
        return
    end

    local virtual_text_chunks = {}
    for _, chunk in ipairs(chunks) do
        if chunk[1] ~= "" then
            table.insert(virtual_text_chunks, { chunk[1], chunk[2] })
        end
    end

    if #virtual_text_chunks > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, references_namespace, line, 0, {
            virt_text = virtual_text_chunks,
            virt_text_pos = "eol",
        })
        last_virtual_text_line = line
    end
end

local function update_virtual_text(bufnr)
    if M.config.use_virtual_text then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local definition_status = M.definition_count > 0
            and string.format(M.config.template.definition.text, tostring(M.definition_count))
            or ""
        local reference_status = M.reference_count > 0
            and string.format(M.config.template.references.text, tostring(M.reference_count))
            or ""
        local chunks = {
            { definition_status, "ActionHintsDefinition" },
            { reference_status,  "ActionHintsReferences" },
        }

        set_virtual_text(bufnr, cursor[1] - 1, chunks)
    end
end

local function is_cursor_on_whitespace()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local lines = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)
    local line = lines and lines[1] or ""
    if not line or line == "" then
        return true
    end
    local col = cursor[2] or 0
    local char = line:sub(col + 1, col + 1)
    if not char or char == "" then
        return true
    end
    return char:match("^%s$") ~= nil
end

-- forward declarations for debounced wrappers
local debounced_references, debounced_definition, debounced_highlight

local function references()
    local bufnr = vim.api.nvim_get_current_buf()
    local method = "textDocument/references"

    if M.is_ignored(bufnr) or not M.supports_method(method, bufnr) then
        return
    end

    if is_cursor_on_whitespace() then
        M.clear_virtual_text()
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local bufname = vim.uri_from_bufnr(bufnr)

    local params = {
        textDocument = { uri = bufname },
        position = { line = cursor[1] - 1, character = cursor[2] },
        context = { includeDeclaration = true },
    }

    vim.lsp.buf_request(bufnr, method, params, function(err, result, _, _)
        if err or not result then
            M.references_available = false
            M.reference_count = 0
            M.clear_virtual_text()
            return
        end

        if vim.tbl_count(result) > 0 then
            M.references_available = true
            M.reference_count = math.max(0, vim.tbl_count(result) - 1)
            update_virtual_text(bufnr)
            return
        end

        M.references_available = false
        M.reference_count = 0
        M.clear_virtual_text()
    end)
end

local function definition()
    local bufnr = vim.api.nvim_get_current_buf()
    local method = "textDocument/definition"
    if M.is_ignored(bufnr) or not M.supports_method(method, bufnr) then
        return
    end

    if is_cursor_on_whitespace() then
        M.clear_virtual_text()
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local bufname = vim.uri_from_bufnr(bufnr)

    local params = {
        textDocument = { uri = bufname },
        position = { line = cursor[1] - 1, character = cursor[2] },
    }

    vim.lsp.buf_request(bufnr, method, params, function(err, result, _, _)
        if err or not result then
            M.definition_available = false
            M.definition_count = 0
            M.clear_virtual_text()
            return
        end

        if vim.tbl_count(result) > 0 then
            M.definition_available = true
            M.definition_count = vim.tbl_count(result)
            update_virtual_text(bufnr)
            return
        end

        M.clear_virtual_text()
        M.definition_available = false
        M.definition_count = 0
    end)
end

local function highlight()
    local bufnr = vim.api.nvim_get_current_buf()

    if M.is_ignored(bufnr) then
        return
    end

    if not vim.tbl_isempty(H.ranges) then
        if is_in_any_range(get_cursor_pos(), H.ranges) then
            return
        else
            clear_highlight(H.bufnr)
        end
    end

    H.bufnr = bufnr
    H.request_id = update_id(H.request_id)
    request_highlight(bufnr, H.request_id)
end

-- assign debounced wrappers after functions are defined
debounced_references = debounce(references, 100)
debounced_definition = debounce(definition, 100)
debounced_highlight = debounce(highlight, 50)

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

M.update = function()
    if not M.is_enabled then
        return
    end

    local mode = vim.api.nvim_get_mode().mode
    if mode == "n" or mode == "v" or mode == "V" or mode == "\22" then
        debounced_references()
        debounced_definition()
        debounced_highlight()
    else
        M.clear_virtual_text()
        clear_highlight(vim.api.nvim_get_current_buf())
    end
end

M.statusline = function()
    if not M.statusline_enabled then
        return ""
    end
    local definition_status = M.definition_count > 0
        and string.format(M.config.template.definition.text, tostring(M.definition_count))
        or ""
    local reference_status = M.reference_count > 0
        and string.format(M.config.template.references.text, tostring(M.reference_count))
        or ""

    local chunks = {
        { definition_status, "ActionHintsDefinitionStatusLine" },
        { reference_status,  "ActionHintsReferencesStatusLine" },
    }

    local colored = M.config.statusline_colored
    local text = ""
    for _, chunk in ipairs(chunks) do
        if chunk[1] ~= "" then
            if colored then
                text = text .. "%#" .. chunk[2] .. "#" .. chunk[1] .. "%#StatusLine#"
            else
                text = text .. chunk[1]
            end
        end
    end

    return text
end

-- Merge helper for template tables (shallow merge for two levels)
local function merge_template(dst, src)
    if not src then
        return
    end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            for k2, v2 in pairs(v) do
                dst[k][k2] = v2
            end
        else
            dst[k] = v
        end
    end
end

M.setup = function(options)
    local aug = vim.api.nvim_create_augroup("ActionHintsAutocmds", { clear = false })
    options = options or {}

    -- Apply options to config: merge template subfields instead of replacing whole subtables
    for k, v in pairs(options) do
        if k == "template" and type(v) == "table" then
            merge_template(M.config.template, v)
        else
            M.config[k] = v
        end
    end

    -- apply highlight from merged config
    M.set_highlight(M.config)

    -- Create autocommands once, callbacks use M directly (no extra require)
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = aug,
        callback = function(evt)
            if evt.event == "CursorMoved" then
                local mode = vim.api.nvim_get_mode().mode
                if vim.tbl_contains({ "n", "v", "V", "\22" }, mode) then
                    M.update()
                end
            else
                -- CursorMovedI
                M.clear_virtual_text()
                clear_highlight(vim.api.nvim_get_current_buf())
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        group = aug,
        callback = function()
            clear_highlight(vim.api.nvim_get_current_buf())
        end,
    })

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = aug,
        pattern = "*",
        callback = function()
            if type(M.set_highlight) == "function" then
                pcall(M.set_highlight, M.config)
                vim.schedule(function()
                    pcall(vim.api.nvim_command, "redrawstatus")
                end)
            end
        end,
    })
end

vim.api.nvim_create_user_command("ChangeActionHintsStat", function()
    if M.is_enabled then
        M.is_enabled = false
        M.statusline_enabled = false
        M.clear_virtual_text()
        clear_highlight(vim.api.nvim_get_current_buf())
    else
        M.is_enabled = true
        M.statusline_enabled = true
        M.update()
    end
end, {})

return M
