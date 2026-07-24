-- lvim-rest: filetype detection for the `.http` / `.rest` request documents.
--
-- Both extensions map to the `http` filetype so the buffer-local maps attach and the lvim-ts `http`
-- treesitter grammar (highlight-only) applies uniformly. This runs at startup regardless of whether
-- `require("lvim-rest").setup()` was called, so opening a `.http` file always gets the right ft.
--
---@module "lvim-rest.plugin"

vim.filetype.add({
    extension = {
        http = "http",
        rest = "http",
    },
})
