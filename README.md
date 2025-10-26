# ⚡️ Action Hints

![action-hints Screenshot](https://raw.githubusercontent.com/new-paper/newpaper/main/assets/previews/nvim/plugins/action-hints/action-hints.gif)

> [!tip]
> Just install the [newpaper.nvim](https://github.com/yorik1984/newpaper.nvim) colorscheme so that it is like in the screenshot

## ✨ Features

- 🔍 Shows available actions for the word under the cursor (definition / references).
- 🖼️ Can display indicators inline as virtual text (e.g. next to the current line).
- 💬 Can output a statusline fragment (compatible with statusline and lualine).
- ⚙️ Configurable templates and colors for definition/references indicators.
- ⛔ Ignored patterns support (filetypes, filename substrings or Lua patterns).
- 🔒 Works only when LSP methods textDocument/definition and textDocument/references are available.
- ⚡️ Minimal and lightweight — forked to simplify and adapt behavior.

## 📦 Installation

Install via your favorite package manager:

**[lazy.nvim](https://github.com/folke/lazy.nvim)**

```lua
{
    "yorik1984/action-hints.nvim",
    opts = {}
},
```

## 🔧 Quick configuration reference

#### Default (important fields)
```lua
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
{
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
```

#### How it works

- 🎨 Priority: if `template.*.color` is set → plugin applies that hex as `fg`.
- 🔗 Otherwise → plugin applies `{ link = template.*.link }` (default config always provides a link).
- ⚡ No extra heuristics: "color" wins, otherwise "link".

#### Fields

- template.definition / template.references
  - `text` — format for virtual text.
  - `color` — `"#rrggbb"` or `nil`. If set, this fixed color is used.
  - `link` — hl group name (e.g. `"Typedef"`, `"Type"`) used when `color` is `nil`.
- `ignored` — list of patterns/items to ignore.
- `use_virtual_text` — show virtual text (true/false).
- `statusline_colored` — if true, statusline groups link to main plugin groups.

#### Examples:

- Force a color:
  - `template.definition.color = "#AF0000"` → plugin applies `fg = "#AF0000"` and respects it across theme changes.
```lua
{
    template = {
        definition = {
            color = "#AF0000",
        },
        references = {
            -- use built-in function to extract fg color from any group
            color = require("action-hints").get_fg_color("Type"),
        },
    },
}
```

- Theme-controlled (recommended default):
  - `template.definition.color = nil; template.definition.link = "Typedef"` → plugin links to `"Typedef"`, so the colorscheme decides the color.
```lua
{
    template = {
        definition = {
            link = "Typedef",
        },
        references = {
            link = "Type",
        },
    },
}
```
- Ignored:
    - `ignored` field accepts Lua patterns (not shell globs). Patterns are matched against file paths (relative or absolute) — use `^` / `$` anchors, `.` and `*` for "any char" / "repeat", and escape special characters with `%` (e.g. `.` → `%.`).

  - `%.min%.js$` — ignore files ending with `.min.js` (`.` must be escaped)
  - `_spec%.lua$` — ignore Lua spec files ending with `_spec.lua`
  - Lua pattern special chars include: `^$()%.[]*+-?`. Prefix with `%` to match them literally.
  - Patterns are case‑sensitive by default on POSIX filesystems.

#### Recommendations

- ✅ Ship defaults with `color = nil` so themes control appearance; let users override with `color` when they want a fixed hue.
- 🖨️ When providing explicit colors, consider adding `ctermfg` for terminal compatibility.
- 🔍 Ensure linked groups exist in common themes (Typedef/Type are commonly present).

## 🚀 Lualine status

Lualine and other statusline frameworks will respect these markers and apply the highlight groups accordingly.
As a lualine component:

```lua
require("lualine").setup({
    sections = {
        lualine_x = { require("action-hints").statusline },
    },
})
```

## Commands

| Command                 | Description                    |
| ----------------------- | ------------------------------ |
|`:ChangeActionHintsStat` | Change the global plugin state |

Optionally add user keymap:

```lua
vim.keymap.set("n", "<leader>aa", ":ChangeActionHintsStat<CR>", { noremap = true })
```

## 🎨✨ Highlight groups

Quick reference for the highlight groups used by the plugin.

- 🟣 `ActionHintsDefinition`
  - Purpose: rendering "definition" indicators (Go to Definition).
  - Source: uses `M.config.template.definition.color` if set; otherwise falls back to `link = M.config.template.definition.link` (default `"Typedef"`).
  - Applied to: virtual text (virt_text).

- 🔵 `ActionHintsReferences`
  - Purpose: rendering "references" indicators (Go to Reference(s)).
  - Source: uses `M.config.template.references.color` if set; otherwise falls back to `link = M.config.template.references.link` (default `"Type"`).
  - Applied to: virtual text (virt_text).

- 🟢 `ActionHintsDefinitionStatusLine`
  - Purpose: statusline-specific styling for definition markers.
  - Behavior: when `statusline_colored = true` this group is linked to `ActionHintsDefinition`; otherwise it is set to `NONE` (no color).
  - Usage: use `%#ActionHintsDefinitionStatusLine#` in statusline segments.

- 🟡 `ActionHintsReferencesStatusLine`
  - Purpose: statusline-specific styling for references markers.
  - Behavior: when `statusline_colored = true` this group is linked to `ActionHintsReferences`; otherwise it is set to `NONE`.
  - Usage: use `%#ActionHintsReferencesStatusLine#` in statusline segments.

> [!note]
> - ⚡ Priority rule: `color` (if provided) overrides `link`. If `color == nil` the plugin uses the configured `link` so the active colorscheme controls appearance.
> - 🖥️ Statusline groups exist to keep statusline visuals consistent and optionally decoupled from virt_text groups.

Examples of how to set or change these highlight groups in your config or `init.lua`:

- Set highlight groups directly (hex color):

```lua
vim.api.nvim_set_hl(0, "ActionHintsDefinition", { fg = "#AF0000" })
vim.api.nvim_set_hl(0, "ActionHintsReferences", { fg = "#007200" })
```

- Link to an existing highlight group:

```lua
vim.api.nvim_set_hl(0, "ActionHintsDefinition", { link = "Typedef" })
vim.api.nvim_set_hl(0, "ActionHintsReferences", { link = "Type" })
```

- Foreground color from existing highlight group:

```lua
vim.api.nvim_set_hl(0, "ActionHintsDefinition", { fg = require("action-hints").get_fg_color("Typedef") })
vim.api.nvim_set_hl(0, "ActionHintsReferences", { fg = require("action-hints").get_fg_color("Type") })
```

> [!tip]
> To make the icons and the words use the same highlighting(like in screenshot), configure your colorscheme so those highlight groups use the same colors. For example:
```lua
vim.api.nvim_set_hl(0, "LspReferenceRead",  { link = "ActionHintsReferences", default = false })
vim.api.nvim_set_hl(0, "LspReferenceWrite", { link = "ActionHintsDefinition", default = false })
```

## ©️ Credits
- [roobert/action-hints.nvim](https://github.com/roobert/action-hints.nvim)(original)
- [lgh597/action-hints.nvim](https://github.com/lgh597/action-hints.nvim)
