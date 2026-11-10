local M = { BUNDLE = "dev.trano.app" }
local executable = "/Applications/Trano.app/Contents/MacOS/trano"
local jobs, cached, refreshing = {}, {}, false

function M.configure(options)
  if options and options.executable then executable = options.executable end
  return M
end

local function request(arguments, callback)
  local task, timer, finished
  local function finish(code, stdout, stderr)
    if finished then return end
    finished = true
    if timer then timer:stop() end
    if task then jobs[task] = nil end
    local ok, response = pcall(hs.json.decode, stdout or "")
    if code ~= 0 or not ok or type(response) ~= "table" or response.error then
      if callback then callback(nil, stderr or "Trano request failed") end
    elseif callback then callback(response.result) end
  end
  task = hs.task.new(executable, finish, arguments)
  if not task then finish(1, "", "Could not start Trano CLI"); return end
  jobs[task] = true
  if not task:start() then finish(1, "", "Could not start Trano CLI"); return end
  timer = hs.timer.doAfter(10, function() finish(124, "", "Trano request timed out"); task:terminate() end)
end

function M.select(workspaceID, tabID, paneID)
  hs.application.launchOrFocusByBundleID(M.BUNDLE)
  if paneID then request({ "attach", paneID })
  elseif tabID then request({ "do", "session.refresh", "--workspace", workspaceID, "--tab", tabID })
  else request({ "select", workspaceID }) end
end

function M.launch(directory, prompt, done, agent)
  local arguments = { "launch", "--cwd", directory, "--agent", agent or "claude" }
  if prompt and prompt ~= "" then arguments[#arguments + 1] = "--prompt"; arguments[#arguments + 1] = prompt end
  request(arguments, function(result, err)
    if result then M.select(result.workspaceID, result.tabID, result.pane.id); M.refresh() end
    if done then done(result and 0 or 1, err) end
  end)
end

function M.collect(callback, options)
  request({ "state" }, function(state)
    if not state then callback({}); return end
    local workspaces, panes, rows = {}, {}, {}
    for _, workspace in ipairs(state.layout.workspaces or {}) do workspaces[workspace.id] = workspace end
    for _, pane in ipairs(state.sessions or {}) do panes[pane.id] = pane end
    for index, tab in ipairs(state.layout.tabs or {}) do
      local workspace = workspaces[tab.workspaceID]
      local pane = panes[tab.focusedPaneID] or panes[(tab.panes or {})[1]]
      if workspace and pane then
        rows[#rows + 1] = {
          sid = workspace.id, wid = tab.id, bid = pane.id,
          session = workspace.title, tab = tab.title, title = pane.title,
          cwd = pane.cwd, program = pane.agent, activity = pane.activity.state,
          active = state.layout.selectedTabID == tab.id,
          tabIndex = index, preview = ""
        }
      end
    end
    if not (options and options.preview) or #rows == 0 then callback(rows); return end
    local pending = #rows
    for _, row in ipairs(rows) do
      request({ "capture", row.bid, "--lines", "40" }, function(result)
        row.preview = result and result.text or ""
        pending = pending - 1
        if pending == 0 then callback(rows) end
      end)
    end
  end)
end

function M.refresh()
  if refreshing then return end
  refreshing = true
  M.collect(function(rows) cached = rows; refreshing = false end)
end

function M.items()
  local items = {}
  for _, row in ipairs(cached) do
    items[#items + 1] = {
      id = "trano:" .. row.sid .. "|" .. row.wid .. "|" .. row.bid,
      title = row.session .. " · " .. row.title,
      subtitle = "Trano · " .. row.tab .. " · " .. row.cwd,
      section = "Trano Sessions", icon = "sf:terminal", accessory = row.activity,
      keywords = { row.session, row.tab, row.title, row.cwd, row.program }
    }
  end
  return items
end

function M.open(id)
  local workspace, tab, pane = id:gsub("^trano:", ""):match("^([^|]+)|([^|]+)|([^|]+)$")
  if workspace then M.select(workspace, tab, pane) end
end

function M.start()
  if M.timer then M.timer:stop() end
  M.refresh()
  M.timer = hs.timer.doEvery(15, M.refresh)
  return M
end

function M.stop()
  if M.timer then M.timer:stop(); M.timer = nil end
  for task in pairs(jobs) do task:terminate() end
end

return M
