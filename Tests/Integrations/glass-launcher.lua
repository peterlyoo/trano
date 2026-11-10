local queued, invocations, focused = {}, {}, 0
local workspace = { id = "workspace", title = "Project" }
local pane = { id = "pane", title = "한국어", cwd = "/tmp/project", agent = "claude", activity = { state = "blocked" } }
local responses = {
  state = { result = { sessions = { pane }, layout = { workspaces = { workspace }, tabs = {
    { id = "tab", workspaceID = "workspace", title = "Terminal", panes = { "pane" }, focusedPaneID = "pane" }
  }, selectedTabID = "tab" } } },
  capture = { result = { text = "preview" } },
  launch = { result = { workspaceID = "workspace", tabID = "tab", pane = pane } },
  attach = { result = { attached = true } }
}
hs = {
  json = { decode = function(value) return responses[value] end },
  application = { launchOrFocusByBundleID = function(id) assert(id == "dev.trano.app"); focused = focused + 1 end },
  timer = {
    doAfter = function(_, _) return { stop = function() end } end,
    doEvery = function(_, _) return { stop = function() end } end
  },
  task = { new = function(path, callback, arguments)
    assert(path == "/test/trano")
    invocations[#invocations + 1] = arguments
    return { start = function() queued[#queued + 1] = function() callback(0, arguments[1], "") end; return true end,
      terminate = function() end }
  end }
}
local function flush()
  while #queued > 0 do table.remove(queued, 1)() end
end
local trano = dofile("integrations/glass-launcher/trano.lua").configure({ executable = "/test/trano" })
local collected
trano.collect(function(rows) collected = rows end, { preview = true })
flush()
assert(#collected == 1 and collected[1].activity == "blocked" and collected[1].preview == "preview")
trano.start(); flush()
local items = trano.items()
assert(#items == 1 and items[1].id == "trano:workspace|tab|pane")
trano.open(items[1].id); flush()
assert(focused == 1 and invocations[#invocations][1] == "attach")
local completed
trano.launch("/tmp/a'b", "do not interpolate $(anything)", function(code) completed = code end, "codex")
flush()
assert(completed == 0)
local found = false
for _, args in ipairs(invocations) do
  if args[1] == "launch" then
    assert(args[3] == "/tmp/a'b" and args[5] == "codex" and args[7] == "do not interpolate $(anything)")
    found = true
  end
end
assert(found)
trano.stop()
print("Glass Launcher adapter: launch, search rows, activity, preview and select passed")
