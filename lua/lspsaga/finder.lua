local api, lsp, fn, uv = vim.api, vim.lsp, vim.fn, vim.loop
local config = require("lspsaga").config
local window = require("lspsaga.window")
local libs = require("lspsaga.libs")
local insert = table.insert

local finder = {}
local ctx = {}

finder.__index = finder
finder.__newindex = function(t, k, v) rawset(t, k, v) end

local function get_titles(index)
  local t = {
    "● Definition",
    "● Implements",
    "● References",
  }
  return t[index]
end

local function methods(index)
  local t = {
    "textDocument/definition",
    "textDocument/implementation",
    "textDocument/references",
  }

  return index and t[index] or t
end

local function get_file_icon(bufnr)
  local res = libs.icon_from_devicon(vim.bo[bufnr].filetype)
  if #res == 0 then
    res = { "" }
  else
    res[1] = res[1] .. " "
  end
  return res
end

local function supports_implement(buf)
  local support = false
  for _, client in pairs(lsp.get_active_clients({ bufnr = buf })) do
    if client.supports_method("textDocument/implementation") then
      support = true
      break
    end
  end
  return support
end

function finder:lsp_finder()
  -- push a tag stack
  local pos = api.nvim_win_get_cursor(0)
  self.current_word = fn.expand("<cword>")
  self.main_buf = api.nvim_get_current_buf()
  self.main_win = api.nvim_get_current_win()
  self.current_file_path = api.nvim_buf_get_name(0)
  self.within_preview = false
  local from = { self.main_buf, pos[1], pos[2], 0 }
  local items = { { tagname = self.current_word, from = from } }
  fn.settagstack(api.nvim_get_current_win(), { items = items }, "t")

  self.request_result = {}
  self.request_status = {}

  local params = lsp.util.make_position_params()
  ---@diagnostic disable-next-line: param-type-mismatch
  local meths = methods()
  if not supports_implement(self.main_buf) then
    self.request_result[meths[2]] = {}
    self.request_status[meths[2]] = true
    ---@diagnostic disable-next-line: param-type-mismatch
    table.remove(meths, 2)
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  for _, method in pairs(meths) do
    self:do_request(params, method)
  end
  -- make a spinner
  self:loading_bar()
end

function finder:request_done()
  local done = true
  ---@diagnostic disable-next-line: param-type-mismatch
  for _, method in pairs(methods()) do
    if not self.request_status[method] then
      done = false
      break
    end
  end
  return done
end

function finder:loading_bar()
  local opts = {
    relative = "cursor",
    height = 2,
    width = 20,
  }

  local content_opts = {
    contents = {},
    buftype = "nofile",
    border = "solid",
    highlight = {
      normal = "finderNormal",
      border = "finderBorder",
    },
    enter = false,
  }

  local spin_buf, spin_win = window.create_win_with_border(content_opts, opts)
  local spin_config = {
    spinner = {
      "█▁▁▁▁▁▁▁▁▁",
      "██▁▁▁▁▁▁▁▁",
      "███▁▁▁▁▁▁▁",
      "████▁▁▁▁▁▁",
      "█████▁▁▁▁▁",
      "██████▁▁▁▁",
      "███████▁▁▁",
      "████████▁▁ ",
      "█████████▁",
      "██████████",
    },
    interval = 50,
    timeout = config.request_timeout,
  }
  api.nvim_buf_set_option(spin_buf, "modifiable", true)

  local spin_frame = 1
  local spin_timer = assert(uv.new_timer())
  local start_request = uv.now()
  spin_timer:start(
    0,
    spin_config.interval,
    vim.schedule_wrap(function()
      spin_frame = spin_frame == 11 and 1 or spin_frame
      local msg = " LOADING" .. string.rep(".", spin_frame > 3 and 3 or spin_frame)
      local spinner = " " .. spin_config.spinner[spin_frame]
      pcall(api.nvim_buf_set_lines, spin_buf, 0, -1, false, { msg, spinner })
      pcall(api.nvim_buf_add_highlight, spin_buf, 0, "finderSpinnerTitle", 0, 0, -1)
      pcall(api.nvim_buf_add_highlight, spin_buf, 0, "finderSpinner", 1, 0, -1)
      spin_frame = spin_frame + 1

      if uv.now() - start_request >= spin_config.timeout and not spin_timer:is_closing() then
        spin_timer:stop()
        spin_timer:close()
        if api.nvim_buf_is_loaded(spin_buf) then api.nvim_buf_delete(spin_buf, { force = true }) end
        window.nvim_close_valid_window(spin_win)
        vim.notify("request timeout")
        return
      end

      if self:request_done() and not spin_timer:is_closing() then
        spin_timer:stop()
        spin_timer:close()
        if api.nvim_buf_is_loaded(spin_buf) then api.nvim_buf_delete(spin_buf, { force = true }) end
        window.nvim_close_valid_window(spin_win)
        self:render_finder()
      end
    end)
  )
end

-- function finder:do_request(params, method)
--   if method == methods(3) then params.context = { includeDeclaration = false } end
--   lsp.buf_request_all(self.current_buf, method, params, function(results)
--     local result = {}
--     for _, res in pairs(results or {}) do
--       if res.result and not (res.result.uri or res.result.targetUri) then
--         libs.merge_table(result, res.result)
--       elseif res.result and (res.result.uri or res.result.targetUri) then
--         table.insert(result, res.result)
--       end
--     end

--     self.request_result[method] = result
--     self.request_status[method] = true
--   end)
-- end

function finder:do_request(params, method)
  if method == methods(3) then params.context = { includeDeclaration = false } end
  local _client_request_ids, cancel_all_requests, client_request_ids
  _client_request_ids, cancel_all_requests = lsp.buf_request(
    self.current_buf,
    method,
    params,
    function(err, result, _ctx)
      if not client_request_ids then
        client_request_ids = vim.tbl_deep_extend("keep", _client_request_ids, {})
      end
      if result == nil or vim.tbl_isempty(result) then
        client_request_ids[_ctx.client_id] = nil
      else
        cancel_all_requests()
        result = vim.tbl_islist(result) and result or { result }
      end
      if vim.tbl_isempty(client_request_ids) then result = {} end

      self.request_result[method] = result
      self.request_status[method] = true
    end
  )
end

function finder:get_uri_scope(method, start_lnum, end_lnum)
  if method == methods(1) then self.def_scope = { start_lnum, end_lnum } end

  if method == methods(2) then self.imp_scope = { start_lnum, end_lnum } end

  if method == methods(3) then self.ref_scope = { start_lnum, end_lnum } end
end

local function get_all_open_buffers()
  local open_buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then table.insert(open_buffers, buf) end
  end
  return open_buffers
end

function finder:render_finder()
  self.short_link = {}
  self.contents = {}
  self.wipe_buffers = {}
  self.opened_buffers = get_all_open_buffers()

  local lnum, start_lnum = 0, 0

  local generate_contents = function(tbl, method)
    if not tbl then return end
    start_lnum = lnum
    for _, val in pairs(tbl) do
      insert(self.contents, val[1])
      lnum = lnum + 1

      if val[2] then self.short_link[lnum] = val[2] end
    end
    self:get_uri_scope(method, start_lnum, lnum - 1)
  end

  ---@diagnostic disable-next-line: param-type-mismatch
  for i, method in pairs(methods()) do
    if i == 2 and #self.request_result[method] == 0 then goto skip end
    local tbl = self:create_finder_contents(self.request_result[method], method)
    generate_contents(tbl, method)
    ::skip::
  end
  self:render_finder_result()
end

local function get_msg(method)
  local idx = libs.tbl_index(methods(), method)
  local t = {
    "No Definition Found",
    "No Implement  Found",
    "No Reference  Found",
  }
  return t[idx]
end

function finder:create_finder_contents(result, method)
  local contents = {}
  local title = get_titles(libs.tbl_index(methods(), method))
  insert(contents, { title .. "  " .. #result, false })
  insert(contents, { " ", false })

  local icon_data = get_file_icon(self.main_buf)
  if #result == 0 then
    insert(contents, { "    " .. icon_data[1] .. get_msg(method), false })
    insert(contents, { " ", false })
    self.short_link[#contents - 1] = {
      content = { "Sorry does not any Definition Found" },
      link = api.nvim_buf_get_name(0),
    }
    return contents
  end

  local root_dir = libs.get_lsp_root_dir()
  for _, res in ipairs(result) do
    local uri = res.targetUri or res.uri
    if not uri then
      vim.notify("miss uri in server response")
      return
    end
    local bufnr = vim.uri_to_bufnr(uri)
    local link = vim.uri_to_fname(uri) -- returns lowercase drive letters on Windows
    if not api.nvim_buf_is_loaded(bufnr) then
      --ignore the FileType event avoid trigger the lsp
      vim.opt.eventignore:append({ "FileType" })
      fn.bufload(bufnr)
      --restore eventignore
      vim.opt.eventignore:remove({ "FileType" })
      if not vim.tbl_contains(self.wipe_buffers, bufnr) then
        table.insert(self.wipe_buffers, bufnr)
      end
    elseif fn.bufwinnr(bufnr) == -1 then
      if not vim.tbl_contains(self.wipe_buffers, bufnr) then
        table.insert(self.wipe_buffers, bufnr)
      end
    end

    if libs.iswin then link = link:gsub("^%l", link:sub(1, 1):upper()) end
    local short_name
    local path_sep = libs.path_sep
    -- reduce filename length by root_dir or home dir
    if root_dir and link:find(root_dir, 1, true) then
      local root_parts = vim.split(root_dir, libs.path_sep, { trimempty = true })
      local link_parts = vim.split(link, libs.path_sep, { trimempty = true })
      short_name = table.concat({ unpack(link_parts, #root_parts + 1) }, libs.path_sep)
    else
      local _split = vim.split(link, path_sep)
      if #_split >= 4 then short_name = table.concat(_split, path_sep, #_split - 2, #_split) end
    end

    short_name = short_name ~= nil and short_name or "No Definition Found"
    local target_line = "    " .. icon_data[1] .. short_name

    local range = res.targetRange or res.range

    local link_with_preview = {
      bufnr = bufnr,
      link = link,
      row = range.start.line,
      col = range.start.character,
      _end_col = range["end"].character,
    }

    insert(contents, { target_line, link_with_preview })
  end
  insert(contents, { " ", false })
  return contents
end

local function get_position(height)
  local winline = fn.winline()
  if config.finder.position == "relative" then
    local row = winline + 1
    if vim.o.lines - 6 - height - winline <= 0 then row = winline - height - 4 end
    return { row = row, col = 10 }
  elseif config.finder.position == "above" then
    local row = winline - height - 4
    if row <= 0 then row = winline + 1 end
    return { row = row, col = 10 }
  elseif config.finder.position == "top" then
    local row = 3
    local col = 10
    if -vim.o.lines + 6 + height + winline <= 0 then row = winline + 1 end
    if fn.winwidth(0) > 120 then col = math.floor(fn.winwidth(0) * 0.2) end
    return { row = row, col = col }
  end
  -- prevent config typo
  local row = winline + 1
  if vim.o.lines - 6 - height - winline <= 0 then
    vim.cmd("normal! zz")
    row = math.floor(0.5 * vim.o.lines)
  end
  return { row = row, col = 10 }
end

function finder:render_finder_result()
  --clean data
  self.request_result = nil
  self.request_status = nil

  if vim.tbl_isempty(self.contents) then return end

  self.group = api.nvim_create_augroup("lspsaga_finder", { clear = true })

  local opt = {
    relative = "win",
    width = window.get_max_content_length(self.contents) + 1, -- for scroll bar
  }

  local max_height = math.floor(vim.o.lines * config.finder.max_height)
  opt.height = #self.contents > max_height and max_height or #self.contents
  if opt.height <= 0 or not opt.height then opt.height = max_height end

  local _position = get_position(opt.height)
  opt.row = _position.row
  opt.col = _position.col

  local r = window.border_chars()["right"][config.ui.border]
  local rtop = window.border_chars()["righttop"][config.ui.border]
  local rbottom = window.border_chars()["rightbottom"][config.ui.border]
  local content_opts = {
    contents = self.contents,
    filetype = "lspsagafinder",
    bufhidden = "wipe",
    enter = true,
    border_side = {
      ["right"] = r,
      ["righttop"] = rtop,
      ["rightbottom"] = rbottom,
    },
    highlight = {
      border = "finderBorder",
      normal = "finderNormal",
    },
  }
  --clean contents
  self.contents = nil

  if fn.has("nvim-0.9") == 1 and config.ui.title then
    opt.title = {
      { " ", "TitleIcon" },
      { self.current_word, "TitleString" },
    }
  end
  --clean
  self.current_word = nil

  self.bufnr, self.winid = window.create_win_with_border(content_opts, opt)
  api.nvim_win_set_option(self.winid, "cursorline", false)

  -- make sure close preview window by using wincmd
  api.nvim_create_autocmd("WinClosed", {
    buffer = self.bufnr,
    once = true,
    callback = function()
      local ok, buf = pcall(api.nvim_win_get_buf, self.preview_winid)
      if ok then pcall(api.nvim_buf_clear_namespace, buf, self.preview_hl_ns, 0, -1) end
      self:close_auto_preview_win()
      if self.group ~= nil then api.nvim_del_augroup_by_id(self.group) end
      self:clean_data()
      self:clean_ctx()
    end,
  })

  self:set_cursor()

  api.nvim_create_autocmd("CursorMoved", {
    buffer = self.bufnr,
    callback = function()
      self:set_cursor()
      self:open_preview()
    end,
  })

  api.nvim_create_autocmd("WinLeave", {
    buffer = self.bufnr,
    callback = function()
      if not self.within_preview then
        local ok, buf = pcall(api.nvim_win_get_buf, self.preview_winid)
        if ok then pcall(api.nvim_buf_clear_namespace, buf, self.preview_hl_ns, 0, -1) end
        vim.fn.win_gotoid(self.main_win)
        self:quit_float_window()
        self:clean_data()
        self:clean_ctx()
      end
    end,
  })

  local virt_hi = "finderVirtText"

  local ns_id = api.nvim_create_namespace("lspsagafinder")
  api.nvim_buf_set_extmark(0, ns_id, 1, 0, {
    virt_text = { { "│", virt_hi } },
    virt_text_pos = "overlay",
  })

  local icon, icon_hl = unpack(get_file_icon(self.main_buf))
  for i = self.def_scope[1] + 2, self.def_scope[2] - 1, 1 do
    local virt_texts = {}
    api.nvim_buf_add_highlight(self.bufnr, -1, "finderFileName", 1 + i, 0, -1)
    if icon_hl then api.nvim_buf_add_highlight(self.bufnr, -1, icon_hl, i, 0, 4 + #icon) end

    if i == self.def_scope[2] - 1 then
      insert(virt_texts, { "└", virt_hi })
      insert(virt_texts, { "───", virt_hi })
    else
      insert(virt_texts, { "├", virt_hi })
      insert(virt_texts, { "───", virt_hi })
    end

    api.nvim_buf_set_extmark(0, ns_id, i, 0, {
      virt_text = virt_texts,
      virt_text_pos = "overlay",
    })
  end

  if self.imp_scope then
    api.nvim_buf_set_extmark(0, ns_id, self.imp_scope[1] + 1, 0, {
      virt_text = { { "│", virt_hi } },
      virt_text_pos = "overlay",
    })

    for i = self.imp_scope[1] + 2, self.imp_scope[2] - 1, 1 do
      local virt_texts = {}
      api.nvim_buf_add_highlight(self.bufnr, -1, "TargetFileName", 1 + i, 0, -1)
      if icon_hl then api.nvim_buf_add_highlight(self.bufnr, -1, icon_hl, i, 0, 4 + #icon) end

      if i == self.imp_scope[2] - 1 then
        insert(virt_texts, { "└", virt_hi })
        insert(virt_texts, { "───", virt_hi })
      else
        insert(virt_texts, { "├", virt_hi })
        insert(virt_texts, { "───", virt_hi })
      end

      api.nvim_buf_set_extmark(0, ns_id, i, 0, {
        virt_text = virt_texts,
        virt_text_pos = "overlay",
      })
    end
  end

  api.nvim_buf_set_extmark(0, ns_id, self.ref_scope[1] + 1, 0, {
    virt_text = { { "│", virt_hi } },
    virt_text_pos = "overlay",
  })

  for i = self.ref_scope[1] + 2, self.ref_scope[2] - 1 do
    local virt_texts = {}
    api.nvim_buf_add_highlight(self.bufnr, -1, "TargetFileName", i, 0, -1)
    if icon_hl then api.nvim_buf_add_highlight(self.bufnr, -1, icon_hl, i, 0, 4 + #icon) end

    if i == self.ref_scope[2] - 1 then
      insert(virt_texts, { "└", virt_hi })
      insert(virt_texts, { "───", virt_hi })
    else
      insert(virt_texts, { "├", virt_hi })
      insert(virt_texts, { "───", virt_hi })
    end

    api.nvim_buf_set_extmark(0, ns_id, i, 0, {
      virt_text = virt_texts,
      virt_text_pos = "overlay",
    })
  end

  -- disable some move keys in finder window
  libs.disable_move_keys(self.bufnr)
  -- load float window map
  self:apply_map()
  self:lsp_finder_highlight()
end

local function unpack_map()
  local map = {}
  for k, v in pairs(config.finder.keys) do
    if k ~= "jump_to" and k ~= "close_in_preview" then map[k] = v end
  end
  return map
end

function finder:apply_map()
  local opts = {
    buffer = self.bufnr,
    nowait = true,
    silent = true,
  }
  local unpacked = unpack_map()

  for action, map in pairs(unpacked) do
    if type(map) == "string" then map = { map } end
    for _, key in pairs(map) do
      if key ~= "quit" then
        vim.keymap.set("n", key, function() self:open_link(action) end, opts)
      end
    end
  end

  for _, key in pairs(config.finder.keys.quit) do
    vim.keymap.set("n", key, function()
      local ok, buf = pcall(api.nvim_win_get_buf, self.preview_winid)
      if ok then pcall(api.nvim_buf_clear_namespace, buf, self.preview_hl_ns, 0, -1) end
      vim.fn.win_gotoid(self.main_win)
      self:quit_float_window()
      self:clean_data()
      self:clean_ctx()
    end, opts)
  end

  vim.keymap.set("n", config.finder.keys.jump_to, function()
    if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
      self.within_preview = true
      api.nvim_set_current_win(self.preview_winid)
    end
  end, opts)
end

function finder:lsp_finder_highlight()
  local len = string.len("Definition")

  for _, v in pairs({ 0, self.ref_scope[1], self.imp_scope and self.imp_scope[1] or nil }) do
    api.nvim_buf_add_highlight(self.bufnr, -1, "FinderIcon", v, 0, 3)
    api.nvim_buf_add_highlight(self.bufnr, -1, "FinderType", v, 4, 4 + len)
    api.nvim_buf_add_highlight(self.bufnr, -1, "FinderCount", v, 4 + len, -1)
  end
end

local finder_ns = api.nvim_create_namespace("finder_select")

function finder:set_cursor()
  local current_line = api.nvim_win_get_cursor(0)[1]
  local icon = get_file_icon(self.main_buf)[1]
  local column = 5 + #icon

  local first_def_uri_lnum = self.def_scope[1] + 3
  local last_def_uri_lnum = self.def_scope[2]
  local first_ref_uri_lnum = self.ref_scope[1] + 3
  local last_ref_uri_lnum = self.ref_scope[2]

  local first_imp_uri_lnum = self.imp_scope and self.imp_scope[1] + 3 or -2
  local last_imp_uri_lnum = self.imp_scope and self.imp_scope[2] or -2

  if current_line == 1 then
    fn.cursor({ first_def_uri_lnum, column })
  elseif current_line == last_def_uri_lnum + 1 then
    fn.cursor({ first_imp_uri_lnum > 0 and first_imp_uri_lnum or first_ref_uri_lnum, column })
  elseif current_line == last_imp_uri_lnum + 1 then
    fn.cursor({ first_ref_uri_lnum, column })
  elseif current_line == last_ref_uri_lnum + 1 then
    fn.cursor({ first_def_uri_lnum, column })
  elseif current_line == first_ref_uri_lnum - 1 then
    fn.cursor({ last_imp_uri_lnum > 0 and last_imp_uri_lnum or last_def_uri_lnum, column })
  elseif current_line == first_imp_uri_lnum - 1 then
    fn.cursor({ last_def_uri_lnum, column })
  elseif current_line == first_def_uri_lnum - 1 then
    fn.cursor({ last_ref_uri_lnum, column })
  end

  local actual_line = api.nvim_win_get_cursor(0)[1]
  if actual_line == first_def_uri_lnum then
    api.nvim_buf_add_highlight(0, finder_ns, "finderSelection", 2, 4 + #icon, -1)
  end

  api.nvim_buf_clear_namespace(0, finder_ns, 0, -1)
  api.nvim_buf_add_highlight(0, finder_ns, "finderSelection", actual_line - 1, 4 + #icon, -1)
end

local function create_preview_window(finder_winid, main_win, main_buf)
  if not finder_winid or not api.nvim_win_is_valid(finder_winid) then return end

  local opts = {
    relative = "win",
    win = main_win,
    no_size_override = true,
  }

  local winconfig = api.nvim_win_get_config(finder_winid)
  opts.col = winconfig.col + winconfig.width + 3
  opts.row = winconfig.row
  opts.height = winconfig.height
  local max_width = api.nvim_win_get_width(main_win) - opts.col - 4
  -- TODO: move preview to the left of finder window
  local min_width = vim.o.columns
    - api.nvim_win_get_position(main_win)[2]
    - api.nvim_win_get_cursor(0)[2]
    - api.nvim_win_get_width(finder_winid)
    - 6
  min_width = min_width > 0 and min_width or 1
  min_width = min_width > config.finder.preview_min_width and config.finder.preview_min_width
    or min_width
  local textwidth = vim.bo[main_buf].textwidth == 0 and 80 or vim.bo[main_buf].textwidth
  opts.width = (min_width > max_width and min_width)
    or (max_width > textwidth and textwidth)
    or max_width

  local ltop = window.border_chars()["lefttop"][config.ui.border]
  local lbottom = window.border_chars()["leftbottom"][config.ui.border]
  local content_opts = {
    contents = {},
    border_side = {
      ["lefttop"] = ltop,
      ["leftbottom"] = lbottom,
    },
    highlight = {
      border = "finderPreviewBorder",
      normal = "finderNormal",
    },
  }

  return window.create_win_with_border(content_opts, opts)
end

local function clear_preview_ns(ns, buf) pcall(api.nvim_buf_clear_namespace, buf, ns, 0, -1) end

function finder:open_preview()
  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    local before_buf = api.nvim_win_get_buf(self.preview_winid)
    clear_preview_ns(self.preview_hl_ns, before_buf)
  end

  local current_line = api.nvim_win_get_cursor(self.winid)[1]
  if not self.short_link[current_line] then return end

  local data = self.short_link[current_line]

  if not self.preview_winid or not api.nvim_win_is_valid(self.preview_winid) then
    self.preview_bufnr, self.preview_winid =
      create_preview_window(self.winid, self.main_win, self.main_buf)
  end

  if data.content then
    if not data.bufnr then data.bufnr = self.preview_bufnr end
    api.nvim_win_set_buf(self.preview_winid, data.bufnr)
    api.nvim_set_option_value("bufhidden", "", { buf = self.preview_bufnr })
    vim.bo[self.preview_bufnr].modifiable = true
    api.nvim_buf_set_lines(self.preview_bufnr, 0, -1, false, data.content)
    vim.bo[self.preview_bufnr].modifiable = false
    return
  end

  if data.bufnr then
    api.nvim_win_set_buf(self.preview_winid, data.bufnr)
    local path = vim.split(data.link, libs.path_sep, { trimempty = true })
    local icon = get_file_icon(self.main_buf)
    if fn.has("nvim-0.9") ~= 0 then
      api.nvim_win_set_config(self.preview_winid, {
        border = config.ui.border,
        title = {
          { icon[1], icon[2] or "TitleString" },
          { path[#path], "TitleString" },
        },
        title_pos = "center",
      })
    else
      api.nvim_win_set_config(self.preview_winid, {
        border = config.ui.border,
      })
    end
    api.nvim_set_option_value("winbar", "", { scope = "local", win = self.preview_winid })
  end

  api.nvim_set_option_value(
    "winhl",
    "Normal:finderNormal,FloatBorder:finderPreviewBorder",
    { scope = "local", win = self.preview_winid }
  )

  if data.row then api.nvim_win_set_cursor(self.preview_winid, { data.row + 1, data.col }) end

  local lang = require("nvim-treesitter.parsers").ft_to_lang(vim.bo[self.main_buf].filetype)
  if fn.has("nvim-0.9") then
    vim.treesitter.start(data.bufnr, lang)
  else
    vim.bo[data.bufnr].syntax = "on"
    pcall(
      vim.cmd,
      string.format("syntax include %s syntax/%s.vim", "@" .. lang, vim.bo[self.main_buf].filetype)
    )
  end

  libs.scroll_in_preview(self.bufnr, self.preview_winid)

  if not self.preview_hl_ns then self.preview_hl_ns = api.nvim_create_namespace("finderPreview") end
  -- api.nvim_win_set_hl_ns(self.preview_winid, self.preview_hl_ns)

  if data.row then
    api.nvim_buf_add_highlight(
      data.bufnr,
      self.preview_hl_ns,
      "finderPreviewSearch",
      data.row,
      data.col,
      data._end_col
    )
  end

  -- TODO: restore map
  local original_mapping = api.nvim_buf_get_keymap(0, "n")
  local original_close_in_preview = nil
  for _, map in ipairs(original_mapping) do
    if map.lhs == config.finder.keys.close_in_preview then
      original_close_in_preview = map
      break
    end
  end

  vim.keymap.set("n", config.finder.keys.close_in_preview, function()
    -- if self.winid and api.nvim_win_is_valid(self.winid) then
    --   api.nvim_win_close(self.winid, true)
    -- end
    if original_close_in_preview then
      vim.api.nvim_buf_set_keymap(
        data.bufnr,
        "n",
        original_close_in_preview.lhs,
        original_close_in_preview.rhs or original_close_in_preview.lhs,
        { noremap = true }
      )
    end
    if not self.within_preview then vim.api.nvim_feedkeys("q", "n", false) end
    self.within_preview = false
    if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
      api.nvim_win_close(self.preview_winid, true)
    end
    -- self:clean_data()
    -- self:clean_ctx()
  end, { buffer = data.bufnr, nowait = true, silent = true })

  api.nvim_create_autocmd("WinLeave", {
    group = self.group,
    buffer = data.bufnr,
    callback = function()
      if self.within_preview then
        local ok, buf = pcall(api.nvim_win_get_buf, self.preview_winid)
        if ok then pcall(api.nvim_buf_clear_namespace, buf, self.preview_hl_ns, 0, -1) end
        vim.fn.win_gotoid(self.main_win)
        self:quit_float_window()
        self:clean_data()
        self:clean_ctx()
      end
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    buffer = data.bufnr,
    callback = function(opt)
      local curwin = api.nvim_get_current_win()
      if curwin == self.preview_winid then
        clear_preview_ns(self.preview_hl_ns, opt.buf)
        if self.winid and api.nvim_win_is_valid(self.winid) then
          api.nvim_set_current_win(self.winid)
          vim.defer_fn(function() self:open_preview() end, 0)
        end
        self.preview_winid = nil
      end
    end,
  })
end

function finder:close_auto_preview_win()
  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    api.nvim_win_close(self.preview_winid, true)
    self.preview_winid = nil
  end
end

function finder:get_winnr_from_filepath(path)
  local all_wins = vim.api.nvim_list_wins()
  for _, win in ipairs(all_wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buf_name = vim.api.nvim_buf_get_name(buf)
    if buf_name == path then return win end
  end
  return nil
end
function finder:get_open_file_bufnr(path)
  local open_buffers = vim.api.nvim_list_bufs()
  for _, buf in ipairs(open_buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == path then return buf end
  end
  return nil
end

local win_opts = {
  winfixwidth = true,
  winfixheight = true,
  cursorbind = false,
  scrollbind = false,
}

local float_win_opts = {
  "number",
  "relativenumber",
  "cursorline",
  "cursorcolumn",
  "foldcolumn",
  "spell",
  "list",
  "signcolumn",
  "colorcolumn",
  "fillchars",
  "winhighlight",
}

function finder:restore_win_opts(parent_winnr, current_winnr)
  for opt, _ in pairs(win_opts) do
    if not vim.tbl_contains(float_win_opts, opt) then
      local value = vim.api.nvim_win_get_option(parent_winnr, opt)
      vim.api.nvim_win_set_option(current_winnr, opt, value)
    end
  end

  for _, opt in ipairs(float_win_opts) do
    local value = vim.api.nvim_win_get_option(parent_winnr, opt)
    vim.api.nvim_win_set_option(current_winnr, opt, value)
  end
end

function finder:open_link(action)
  local current_line = api.nvim_win_get_cursor(0)[1]
  local current_file_path = self.current_file_path
  local current_file_win = self.main_win

  if not self.short_link[current_line] then
    vim.notify("[LspSaga] no file link in current line", vim.log.levels.WARN)
    return
  end

  local short_link = self.short_link

  if short_link[current_line].row == nil then
    vim.notify("[LspSaga] no definition found in current line", vim.log.levels.WARN)
    return
  end

  local pbuf = api.nvim_win_get_buf(self.preview_winid)
  clear_preview_ns(self.preview_hl_ns, pbuf)
  self:quit_float_window()
  self:clean_data()

  -- if buffer not saved save it before jump
  if vim.bo.modified then vim.cmd("write") end
  if short_link[current_line].link ~= current_file_path then
    local parent_winnr = self:get_winnr_from_filepath(short_link[current_line].link)
    local parent_bufnr = self:get_open_file_bufnr(short_link[current_line].link)
    vim.cmd(action .. " " .. uv.fs_realpath(short_link[current_line].link))
    if (parent_winnr ~= nil) and (parent_bufnr ~= nil) then
      self:restore_win_opts(parent_winnr, current_file_win)
    end
  else
    api.nvim_set_current_win(current_file_win)
  end
  api.nvim_win_set_cursor(0, { short_link[current_line].row + 1, short_link[current_line].col })
  local width = #api.nvim_get_current_line()
  libs.jump_beacon({ short_link[current_line].row, 0 }, width)
  if action == "edit" then vim.cmd("normal! zz") end
  self:clean_ctx()
end

function finder:clean_data()
  for _, buf in pairs(self.wipe_buffers or {}) do
    if not vim.tbl_contains(self.opened_buffers, buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
    pcall(vim.keymap.del, "n", config.finder.keys.close_in_preview, { buffer = buf })
  end

  if self.group then pcall(api.nvim_del_augroup_by_id, self.group) end
end

function finder:quit_float_window()
  self:close_auto_preview_win()
  if self.winid and self.winid > 0 then
    window.nvim_close_valid_window(self.winid)
    self.winid = nil
  end
end

function finder:clean_ctx()
  for k, _ in pairs(ctx) do
    ctx[k] = nil
  end
end

return setmetatable(ctx, finder)
