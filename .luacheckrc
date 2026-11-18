-- ForeverMarkets luacheck config. Thin wrapper over the shared Peavers base (wow-api).
-- Run from the repo root: WOW_FLAVOR=mainline WOW_BUILD=120105 luacheck .
-- Forever runs the 12.1.5 mainline API, so that build's dump is the accurate one.
-- (Override the package path with WOW_API_DIR.)

local apiDir = (os and os.getenv and os.getenv("WOW_API_DIR")) or "../wow-api"
local base = assert(loadfile(apiDir .. "/config/luacheckrc.base.lua"))(apiDir)

std             = base.std
ignore          = base.ignore
exclude_files   = base.exclude
max_line_length = false
codestyle       = false
allow_defined_top = base.allow_defined_top
stds.wow        = base.wow

globals = base.globals
for _, g in ipairs({
  "ForeverMarketsDB",         -- SavedVariables
  "SLASH_FOREVERMARKETS1",    -- /fm
  "ForeverMarkets_Next",      -- the "Do the next plan step" key binding (Bindings.xml)
  "BINDING_HEADER_FOREVERMARKETS",
  "BINDING_NAME_FOREVERMARKETS_NEXT",
  "ForeverMarkets_Flip",      -- the "Do the next vendor flip" key binding
  "BINDING_NAME_FOREVERMARKETS_FLIP",
}) do globals[#globals + 1] = g end

read_globals = {
  "ForeverMarkets_Data",      -- defined by the data addon Courier writes (CONTRACT "Data addons")
}

-- The fake client in tests/ stands in for the game, so it defines the game's globals and
-- ForeverMarkets_Data itself.
files["tests/run.lua"] = { ignore = { "111", "121", "122", "143", "241", "411" } }
