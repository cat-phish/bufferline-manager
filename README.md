# bufferline-manager.nvim

A text-buffer like buffer manager for
[bufferline.nvim](https://github.com/akinsho/bufferline.nvim)

## About

There are many buffer managers out there. However, none of them seemed to tick
all of the boxes for me. I'm a huge fan of text-buffer file editing plugins
like [fyler.nvim](https://github.com/A7Lavinraj/fyler.nvim) and
[oil.nvim](https://github.com/stevearc/oil.nvim). While there are some buffer
managers out there that offer a similar experience for editing, or even
re-ordering buffers. I couldn't find any that respected or integrated with
Bufferline's ordering and re-ordering.

## Features

- Text-based floating window interface
- Reorder buffers
- Rename buffers by editing buffer as text file
- Syncs with Bufferline.nvim order
- Delete buffers
- Jump to buffer in list

## Requirements

- Neovim >= 0.8.0
- [bufferline.nvim](https://github.com/akinsho/bufferline.nvim)

## Installation

### lazy.nvim

```lua
{
  'cat-phish/bufferline-manager.nvim',
  dependencies = {
    'akinsho/bufferline.nvim',
  },
  opts = {
    -- Optional: customize configuration
    width = 80,
    height = 20,
    border = 'rounded',
    title = ' Bufferline Manager ',
    show_full_path = false,
    show_numbers = true,
    smart_path = true,
    use_relative = nil,
    confirm_delete = false,
    confirm_save = true,
    auto_save_on_exit_insert = false,
    keymaps = {
      delete = 'dd',
      move_down = '<A-j>',
      move_up = '<A-k>',
      jump = '<CR>',
      close = { 'q', '<Esc>' },
    },
  },
  keys = {
    { '<leader>bm', '<cmd>BufferlineManager<cr>', desc = 'Buffer Manager' },
  },
}
```

## Usage

### Commands

- `:BufferlineManager` - Open the buffer manager
- `:BufferlineManagerToggle` - Toggle the buffer manager

### Keymaps (inside buffer manager)

Default keymaps:

- `dd` - Delete buffer
- `Alt-j` - Move buffer down/right
- `Alt-k` - Move buffer up/left
- `Enter` - Jump to buffer under cursor
- `q` or `Esc` - Close manager

## Configuration

### Default Configuration

```lua
require('bufferline-manager').setup({
  width = 80,              -- Maximum width of the floating window
  height = 20,             -- Maximum height of the floating window
  border = 'rounded',      -- Border style: 'none', 'single', 'double', 'rounded', 'solid', 'shadow'
  title = ' Buffer Manager ',
  show_full_path = false,  -- Show full file paths instead of just filename
  smart_path = true,       -- Show parent folder only for duplicate filenames
  show_numbers = true,     -- Show line numbers
  use_relative = nil,      -- nil = inherit nvim setting, true = force relative, false = force absolute
  confirm_delete = false,  -- Delete without confirmation
	confirm_save = true,     -- Confirm buffer/file renames on save
	auto_save_on_exit_insert = false, -- Automatically saves renames when exiting insert mode
  keymaps = {
    delete = 'dd',         -- Delete buffer
    move_down = '<A-j>',   -- Move buffer down/right
    move_up = '<A-k>',     -- Move buffer up/left
    jump = '<CR>',         -- Jump to buffer
    close = { 'q', '<Esc>' }, -- Close manager
  },
})
```

## License

MIT
