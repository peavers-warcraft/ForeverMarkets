-- Drives ForeverMarkets.lua through a fake 12.1.5 client: run from addon/ with `lua tests/run.lua`.
-- WoW's UI can't be run here, so this is how the addon's records are checked.

local failures = 0
local function check(name, ok)
    io.write((ok and "ok   " or "FAIL ") .. name .. "\n")
    if not ok then failures = failures + 1 end
end

-- ---- the fake client --------------------------------------------------------
local handler
local registered = {}
local frame = {
    SetScript = function(_, _, fn) handler = fn end,
    RegisterEvent = function(_, event)
        if event == "EVENT_THIS_CLIENT_LACKS" then error("unknown event") end
        registered[event] = true
    end,
}
-- The first frame is the addon's event frame; the rest are the plan panel's widgets.
local function widget()
    local w = { scripts = {}, shown = false, enabled = true }
    function w:SetScript(event, fn) self.scripts[event] = fn end
    function w:SetText(t) self.text = t end
    function w:GetText() return rawget(self, "text") end
    function w:Show() self.shown = true end
    function w:Hide() self.shown = false end
    function w:IsShown() return self.shown end
    function w:Enable() self.enabled = true end
    function w:Disable() self.enabled = false end
    function w:IsEnabled() return self.enabled end
    function w:CreateFontString()
        local f = widget()
        local lines = rawget(self, "lines") or {}
        lines[#lines + 1] = f
        rawset(self, "lines", lines)
        return f
    end
    function w:Click() if self.scripts.OnClick then self.scripts.OnClick(self) end end
    return setmetatable(w, { __index = function() return function() end end })
end
local widgets, eventFrameMade = {}, false
function CreateFrame(_, name)
    if not eventFrameMade then eventFrameMade = true return frame end
    local w = widget()
    if name then widgets[name] = w end
    return w
end
UIParent = widget()
function GetMoneyString(copper) return copper .. "c" end
unpack = unpack or table.unpack -- WoW runs Lua 5.1
-- a client with a surname API somewhere, as Forever's must have under some name
C_FakeIdentity = { GetPlayerSurname = function(unit) return unit == "player" and "Peavers" or nil end }
-- and one that only reformats what it's given, as Forever's C_NameUtil does; it sorts first
C_AFakeNameUtil = { ReplaceSurnameSeparator = function(text) return text end }
-- the inbox: a sale, an unsold listing coming back, and a letter from a friend
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
local inbox = {
    { subject = "Auction successful: Linen Cloth (20)", money = 570, invoice = { "seller", "Linen Cloth", "Buyer", 0, 600, 40, 30, 0, 0, 20 } },
    { subject = "Hello", money = 0, sender = "Friend" },
    { subject = "Auction expired: Wool Cloth", money = 0, items = { "Wool Cloth", 2592, nil, 5 } },
}
function GetInboxNumItems() return #inbox, #inbox end
function GetInboxHeaderInfo(i) local m = inbox[i] return nil, nil, m.sender or "Auction House", m.subject, m.money end
function GetInboxInvoiceInfo(i) if inbox[i].invoice then return unpack(inbox[i].invoice) end end
function GetInboxItem(i) if inbox[i].items then return unpack(inbox[i].items) end end
local looted = {}
function AutoLootMailItem(i) looted[#looted + 1] = inbox[i].subject table.remove(inbox, i) end
local vendorPrices = {} -- what the game's vendors pay, by item; 10c for anything else
local unloaded = {} -- items the client hasn't loaded yet
C_Item = { GetItemInfo = function(id)
    if unloaded[id] then return nil end
    return "item " .. id, nil, 1, 1, 1, "Tradeskill", "Cloth", 200, "", 0, vendorPrices[id] or 10
end }
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
function time() return 1000 end
function UnitGUID(unit) return unit == "npc" and "Creature-0-3726-0-12-8719-000012ABCD" or "Player-1-0001" end
function UnitName(unit) return unit == "npc" and "Auctioneer Fitch" or "Trader" end
function GetZoneText() return "Stormwind City" end
function GetSubZoneText() return "Trade District" end
C_Map = { GetBestMapForUnit = function() return 84 end }
local reportedErrors = {}
function geterrorhandler() return function(err) reportedErrors[#reportedErrors + 1] = err end end
function UnitFactionGroup() return "Horde" end
local money = 12345
function GetMoney() return money end
ERR_AUCTION_SOLD_S = "A buyer has been found for your auction of %s."
Enum = { BagIndex = { Backpack = 0, Bag_1 = 1, ReagentBag = 5, CharacterBankTab_1 = 6, AccountBankTab_1 = 12, Characterbanktab = -2 } }
local contents = { [0] = { { itemID = 2589, stackCount = 20 } }, [1] = { { itemID = 2589, stackCount = 5 }, { itemID = 2592, stackCount = 1 } },
                   [6] = { { itemID = 4306, stackCount = 40 } }, [12] = { { itemID = 9999, stackCount = 1 } } }
local slots = {} -- a bag's size, when it has empty slots
local containerCalls = {}
C_Container = {
    GetContainerNumSlots = function(bag) return slots[bag] or (contents[bag] and #contents[bag]) or 0 end,
    GetContainerItemInfo = function(bag, slot) return contents[bag] and contents[bag][slot] end,
    UseContainerItem = function(...) containerCalls[#containerCalls + 1] = { "UseContainerItem", ... } end,
    SplitContainerItem = function(...) containerCalls[#containerCalls + 1] = { "SplitContainerItem", ... } end,
    PickupContainerItem = function(...) containerCalls[#containerCalls + 1] = { "PickupContainerItem", ... } end,
}
local book = { { unitPrice = 1100, quantity = 50, auctionID = 7, containsOwnerItem = false },
               { unitPrice = 1200, quantity = 10, auctionID = 8, containsOwnerItem = true } }
local calls = {} -- every auction house action the addon took, in order
local function record(name) return function(...) calls[#calls + 1] = { name, ... } end end
C_AuctionHouse = {
    GetNumCommoditySearchResults = function() return #book end,
    GetCommoditySearchResultInfo = function(_, i) return book[i] end,
    HasFullCommoditySearchResults = function() return true end,
    GetNumItemSearchResults = function() return 1 end,
    GetItemSearchResultInfo = function() return { buyoutAmount = 500000, quantity = 1, auctionID = 99, itemLink = "|Hitem:19019::::::::71|h" } end,
    GetNumOwnedAuctions = function() return 1 end,
    GetOwnedAuctionInfo = function() return { auctionID = 8, itemKey = { itemID = 2589 }, quantity = 10, buyoutAmount = 12000, status = 0 } end,
    StartCommoditiesPurchase = function() end,
    MakeItemKey = function(itemID) return { itemID = itemID } end,
    SendSearchQuery = record("SendSearchQuery"),
    SendBrowseQuery = record("SendBrowseQuery"),
    HasFullBrowseResults = function() return true end,
    RequestMoreBrowseResults = record("RequestMoreBrowseResults"),
    PlaceBid = record("PlaceBid"),
    ConfirmCommoditiesPurchase = record("ConfirmCommoditiesPurchase"),
    CancelCommoditiesPurchase = record("CancelCommoditiesPurchase"),
    ConfirmPostCommodity = record("ConfirmPostCommodity"),
    PostCommodity = function(...) calls[#calls + 1] = { "PostCommodity", ... } return false end,
    CalculateCommodityDeposit = function(_, duration, quantity) return 6 * duration * quantity end,
    GetBrowseResults = function()
        return { { itemKey = { itemID = 2589, itemLevel = 0, battlePetSpeciesID = 0 }, minPrice = 1100, totalQuantity = 500 },
                 { itemKey = { itemID = 19019, itemLevel = 71, battlePetSpeciesID = 0 }, minPrice = 500000, totalQuantity = 1 } }
    end,
}
-- timers run only when a test says the time has passed
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end
local hooks = {}
function hooksecurefunc(t, name, fn) hooks[name] = fn; local orig = t[name]; t[name] = function(...) orig(...); fn(...) end end
SlashCmdList = {}
-- What Courier's data addon defines (CONTRACT "Data addons"): Status.lua, Broadcast.lua (nothing
-- published to everyone) and Personal.lua, whose data is the plans the web app sent.
ForeverMarkets_Data = {
    status = { app = "courier", app_version = "0.2.0", sharing = true, last_upload = 1, last_download = 1 },
    broadcast = nil,
    personal = { version = 1, published_at = "2026-11-17T06:00:00.000Z", data = { version = 1, written = 1, plans = {
        ["Player-1-0001"] = { written = 1, gold = 12345, steps = {
            { kind = "sell", item = 2589, name = "Linen Cloth", units = 20, price = 30 },
            { kind = "buy", item = 2592, name = "Wool Cloth", units = 50, maxPrice = 100, sellAt = 150 },
        } },
    } } },
}
local printed = {}
function print(text) printed[#printed + 1] = text end

local function fire(event, ...) handler(frame, event, ...) end

-- ---- load it ---------------------------------------------------------------
local ns = {}
local chunk = assert(loadfile("ForeverMarkets.lua"))
chunk("ForeverMarkets", ns)
local planChunk = assert(loadfile("Plan.lua"))
planChunk("ForeverMarkets", ns)
assert(loadfile("Flips.lua"))("ForeverMarkets", ns)
fire("ADDON_LOADED", "SomethingElse")
check("ignores other addons' ADDON_LOADED", ForeverMarketsDB == nil)
fire("ADDON_LOADED", "ForeverMarkets")
fire("PLAYER_LOGIN")
local db = ForeverMarketsDB
local me = db.characters["Player-1-0001"]

check("registers the events it handles", registered.COMMODITY_SEARCH_RESULTS_UPDATED and registered.CHAT_MSG_SYSTEM)
check("records money at login", me.money == 12345)
check("records what the game's vendors pay for what's in the bags", db.vendorPrices[2589] == 10 and db.vendorPrices[2592] == 10)
check("counts bags, not the bank", me.bags[2589] == 25 and me.bags[2592] == 1 and me.bags[4306] == nil)

money = 99
fire("PLAYER_MONEY")
check("follows money changes", me.money == 99)

fire("BANKFRAME_OPENED")
check("counts the character bank, not the warband bank", me.bank[4306] == 40 and me.bank[9999] == nil)

fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
local scan = db.scans[1]
check("records a commodity order book with Blizzard's auction ids",
    scan.kind == "commodity" and scan.item == 2589 and #scan.rows == 2 and scan.rows[1][1] == 1100 and scan.rows[2][3] == 8 and scan.rows[2][4] == true)

vendorPrices["|Hitem:19019::::::::71|h"] = 4000 -- the listed item sells for more than the base item
fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 19019, itemLevel = 71, battlePetSpeciesID = 0 })
check("records an item order book", db.scans[2].kind == "item" and db.scans[2].rows[1][1] == 500000 and db.scans[2].species == nil)
check("and what a vendor pays for the base item, and for the listed item's level when that differs",
    db.vendorPrices[19019] == 10 and db.vendorLevels[19019][71] == 4000)

local getItemResult = C_AuctionHouse.GetItemSearchResultInfo
C_AuctionHouse.GetItemSearchResultInfo = function() return { quantity = 1, auctionID = 98 } end
fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 19019, itemLevel = 71, battlePetSpeciesID = 0 })
C_AuctionHouse.GetItemSearchResultInfo = getItemResult
check("an auction with no buyout is recorded at 0, so its row has no hole",
    db.scans[3].rows[1][1] == 0 and db.scans[3].rows[1][3] == 98)

fire("AUCTION_HOUSE_SHOW")
local visit = db.visits[1]
check("records where the auction house was opened, and by which auctioneer",
    visit.character == "Player-1-0001" and visit.map == 84 and visit.zone == "Stormwind City"
    and visit.subzone == "Trade District" and visit.npc == "Auctioneer Fitch" and visit.npcID == 8719)

fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
local browse = db.scans[#db.scans]
check("records the browse list a search shows first, with no holes in its rows",
    browse.kind == "browse" and #browse.rows == 2 and browse.rows[1][1] == 2589 and browse.rows[1][2] == 1100
    and browse.rows[1][3] == 500 and browse.rows[1][4] == 0 and browse.rows[2][4] == 71 and browse.rows[2][5] == 0)

local getItemInfo = C_Item.GetItemInfo
C_Item.GetItemInfo = function(id) if id ~= 3000 then return getItemInfo(id) end end -- the client hasn't loaded 3000 yet
local scansBefore = #db.scans
fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", { { itemKey = { itemID = 2592 }, minPrice = 300, totalQuantity = 80 },
    { itemKey = { itemID = 3000 }, minPrice = 50, totalQuantity = 1 }, { itemKey = { itemID = 82800, battlePetSpeciesID = 40 }, minPrice = 9, totalQuantity = 1 } })
check("an item the client hasn't loaded has no vendor price yet, and a caged pet never gets one", db.vendorPrices[3000] == nil and db.vendorPrices[82800] == nil)
C_Item.GetItemInfo = getItemInfo
fire("GET_ITEM_INFO_RECEIVED", 3000, true)
check("its price is recorded once the client has it", db.vendorPrices[3000] == 10)
check("results loaded by scrolling join the list on screen",
    #db.scans == scansBefore and #browse.rows == 5 and browse.rows[3][1] == 2592 and browse.rows[3][4] == 0)

local many = {}
for i = 1, 600 do many[i] = { itemKey = { itemID = 10000 + i }, minPrice = 100, totalQuantity = 1 } end
local getBrowse = C_AuctionHouse.GetBrowseResults
C_AuctionHouse.GetBrowseResults = function() return many end
fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
C_AuctionHouse.GetBrowseResults = getBrowse
check("a search's list keeps its first 500 rows, and every row's vendor price",
    #db.scans[#db.scans].rows == 500 and db.vendorPrices[10600] == 10)

local getBrowseResults = C_AuctionHouse.GetBrowseResults
C_AuctionHouse.GetBrowseResults = function() error("GetBrowseResults is not available") end
fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
C_AuctionHouse.GetBrowseResults = getBrowseResults
-- the recorder and the flips scanner both read the list, and both fail
check("a failing handler is kept in the saved file and still reported to WoW",
    #db.errors == 2 and db.errors[1].event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
    and db.errors[1].message:find("not available") ~= nil and #reportedErrors == 2)

money = 500
fire("PLAYER_ENTERING_WORLD")
check("reads money again on entering the world", me.money == 500)

fire("OWNED_AUCTIONS_UPDATED")
check("records the player's own listings", me.owned[1].id == 8 and me.owned[1].item == 2589)

C_AuctionHouse.StartCommoditiesPurchase(2589, 40)
fire("COMMODITY_PRICE_UPDATED", 1150, 46000)
fire("COMMODITY_PURCHASE_SUCCEEDED")
local bought = db.fills[#db.fills]
check("a commodity purchase records what, how many and at what price",
    bought.kind == "bought" and bought.item == 2589 and bought.quantity == 40 and bought.unitPrice == 1150 and bought.total == 46000)

C_AuctionHouse.StartCommoditiesPurchase(2592, 1)
fire("COMMODITY_PURCHASE_FAILED")
fire("COMMODITY_PURCHASE_SUCCEEDED")
check("a failed purchase is not recorded", #db.fills == 1)

fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Peacebloom.")
check("a sale message becomes a fill", db.fills[#db.fills].kind == "sold" and db.fills[#db.fills].name == "Peacebloom")
fire("CHAT_MSG_SYSTEM", "You are now Away.")
check("other system messages are ignored", #db.fills == 2)
local errorsBefore = #db.errors
issecretvalue = function(v) return v == "SECRET" end
fire("CHAT_MSG_SYSTEM", "SECRET")
issecretvalue = nil
check("a chat message the game keeps secret is passed over, not an error", #db.errors == errorsBefore and #db.fills == 2)

for _ = 1, 400 do fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589) end
check("order books are capped, oldest first", #db.scans == 300)

-- ---- the plan, carried out one press at a time ----------------------------
money = 1000000 -- plenty: buys here are sized by the book until the gold checks below
-- StartCommoditiesPurchase is hooked by the addon, so wrap the hooked version to record it too.
local start = C_AuctionHouse.StartCommoditiesPurchase
C_AuctionHouse.StartCommoditiesPurchase = function(...) calls[#calls + 1] = { "StartCommoditiesPurchase", ... } return start(...) end
local panel, button
local function press()
    local before = #calls
    ForeverMarkets_Next()
    return #calls - before
end

fire("AUCTION_HOUSE_SHOW")
panel, button = widgets.ForeverMarketsPlanPanel, widgets.ForeverMarketsPlanButton
check("the plan panel opens with the auction house", panel and panel.shown)
check("the first step is to list what's in the bags", button:GetText() == "List 20")
local function panelText() return rawget(panel, "lines")[2]:GetText() end -- [1] is the title
check("it says the deposit before listing", panelText():find("Deposit 240c, back when they sell", 1, true) ~= nil)

check("one press lists, and does nothing else", press() == 1)
local post = calls[#calls]
check("it lists 20 Linen Cloth from the bags at the plan's price for 24 hours",
    post[1] == "PostCommodity" and contents[post[2].bag][post[2].slot].itemID == 2589 and post[3] == 2 and post[4] == 20 and post[5] == 30)
check("while the listing goes through the button waits", not button:IsEnabled() and press() == 0)

fire("AUCTION_HOUSE_AUCTION_CREATED", 555)
check("a listing done moves to the next step", button:GetText() == "Find Wool Cloth")
local posted = ForeverMarketsDB.fills[#ForeverMarketsDB.fills]
check("the listing is recorded with what it was and its deposit",
    posted.kind == "posted" and posted.auction == 555 and posted.item == 2589 and posted.units == 20 and posted.price == 30
    and posted.deposit == 6 * 2 * 20 and posted.vendor == 10 and posted.duration == 2)
check("and the deposit is kept as a sample for the app", ForeverMarketsDB.deposits[2589].deposit == 240 and ForeverMarketsDB.deposits[2589].vendor == 10)
check("progress is kept for a /reload", ForeverMarketsDB.progress["Player-1-0001"].done[1] == true)

book = { { unitPrice = 90, quantity = 30, auctionID = 21 }, { unitPrice = 99, quantity = 10, auctionID = 22 }, { unitPrice = 120, quantity = 100, auctionID = 23 } }
check("one press searches", press() == 1 and calls[#calls][1] == "SendSearchQuery" and calls[#calls][2].itemID == 2592)
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2592)
check("it offers only what's at or under the limit", button:GetText() == "Buy 40")

check("one press starts the purchase", press() == 1 and calls[#calls][1] == "StartCommoditiesPurchase" and calls[#calls][2] == 2592 and calls[#calls][3] == 40)
fire("COMMODITY_PRICE_UPDATED", 95, 3800)
check("a quoted price within the limit asks to confirm", button:GetText() == "Confirm")
check("one press confirms", press() == 1 and calls[#calls][1] == "ConfirmCommoditiesPurchase" and calls[#calls][3] == 40)
fire("COMMODITY_PURCHASE_SUCCEEDED")
check("a partial buy stays on the step for the rest", button:GetText() == "Find Wool Cloth"
    and ForeverMarketsDB.progress["Player-1-0001"].bought[2] == 40)

book = { { unitPrice = 95, quantity = 30, auctionID = 31 } }
press()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2592)
check("the rest is only what's left of the step", button:GetText() == "Buy 10")
press()
local confirmsBefore = 0
for _, c in ipairs(calls) do if c[1] == "ConfirmCommoditiesPurchase" then confirmsBefore = confirmsBefore + 1 end end
fire("COMMODITY_PRICE_UPDATED", 130, 1300)
check("a price over the limit is cancelled, not confirmed",
    calls[#calls][1] == "CancelCommoditiesPurchase" and button:GetText() == "Look again")
local confirmsAfter = 0
for _, c in ipairs(calls) do if c[1] == "ConfirmCommoditiesPurchase" then confirmsAfter = confirmsAfter + 1 end end
check("nothing more was confirmed", confirmsAfter == confirmsBefore)

-- each buy is sized to the gold on hand, keeping back its listing deposit
ForeverMarkets_Data.personal.data.plans["Player-1-0001"].steps[2].depositPerUnit = 10
money = 50 -- not even one at the 100c limit plus 10c deposit
press()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2592)
check("when the gold on hand covers none, it says so and offers nothing to buy",
    button:GetText() == "Look again" and panelText():find("doesn't cover even one", 1, true) ~= nil)
money = 450 -- covers 4 of the 10 left: 4 x (100c + 10c)
press()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2592)
check("a buy is sized to the gold on hand, keeping back each unit's deposit",
    button:GetText() == "Buy 4" and panelText():find("covers 4 of them", 1, true) ~= nil)
timers = {}
press()
check("while the price is asked for, the button says so", not button:IsEnabled() and button:GetText() == "Asking for the price…")
runTimers()
check("a price the auction house never sends is given up on, and it offers to look again",
    calls[#calls][1] == "CancelCommoditiesPurchase" and button:IsEnabled() and button:GetText() == "Look again")
money = 1000000

local pressesBeforeSkip = #calls
widgets.ForeverMarketsPlanSkip:Click()
check("skipping the last step finishes the plan, and Skip itself trades nothing",
    #calls == pressesBeforeSkip and not button:IsEnabled())
check("with no plan step left, the plan's key goes to the vendor flips", press() == 1 and calls[#calls][1] == "SendBrowseQuery")

fire("AUCTION_HOUSE_CLOSED")
check("the panel closes with the auction house", not panel.shown)

ForeverMarkets_Data.personal.data.plans["Player-1-0001"] = { written = 2, steps = { { kind = "sell", item = 2589, name = "Linen Cloth", units = 5, price = 31 } } }
fire("AUCTION_HOUSE_SHOW")
check("a new plan starts from its first step", button:GetText() == "List 5" and ForeverMarketsDB.progress["Player-1-0001"].done[1] == nil)

local richMoney = money
money = 10 -- the deposit for 5 is 60c
fire("AUCTION_HOUSE_CLOSED")
fire("AUCTION_HOUSE_SHOW")
check("a listing the character can't pay the deposit for is refused", not button:IsEnabled() and press() == 0)
money = richMoney

ForeverMarkets_Data.personal.data.plans = { ["Player-1-9999"] = { written = 3, steps = { { kind = "sell", item = 2589, units = 1, price = 1 } } } }
fire("AUCTION_HOUSE_CLOSED")
fire("AUCTION_HOUSE_SHOW")
check("another character's plan isn't shown", not panel.shown)

-- ---- the gold ledger, the surname, and the mailbox ---------------------------
check("the surname comes from whichever API names it, not one that hands back what it's given",
    me.surname == "Peavers" and me.surnameFrom == "C_FakeIdentity.GetPlayerSurname"
    and me.surnameApis == "C_AFakeNameUtil.ReplaceSurnameSeparator, C_FakeIdentity.GetPlayerSurname")
local ledgerBefore = #me.ledger
money = 777
fire("PLAYER_MONEY")
fire("PLAYER_MONEY")
check("every change of gold is kept once in the ledger", #me.ledger == ledgerBefore + 1 and me.ledger[#me.ledger][2] == 777)

fire("MAIL_SHOW")
local mailPanel, mailButton = widgets.ForeverMarketsMailPanel, widgets.ForeverMarketsMailButton
check("the mail panel opens with the mailbox", mailPanel.shown)
check("what's waiting is recorded: the sale and the unsold listing, not the letter",
    #me.mail.waiting == 2 and me.mail.waiting[1].kind == "sold" and me.mail.waiting[1].money == 570 and me.mail.waiting[1].count == 20
    and me.mail.waiting[2].kind == "expired" and me.mail.waiting[2].name == "Wool Cloth" and me.mail.waiting[2].item == 2592)
local mailText = rawget(mailPanel, "lines")[2]:GetText()
check("the panel says what's waiting", mailText:find("1 sale worth 570c", 1, true) and mailText:find("1 listing that didn't sell", 1, true))
check("the button collects the first auction house mail", mailButton:GetText() == "Collect sale")

local fillsAtMailbox = #ForeverMarketsDB.fills
ForeverMarkets_Next() -- the key binding works at the mailbox too
check("one press collects one mail", #looted == 1 and looted[1] == "Auction successful: Linen Cloth (20)")
check("until the inbox updates, nothing more is collected or recorded", (function() ForeverMarkets_Next() return #looted == 1 end)() and #ForeverMarketsDB.fills == fillsAtMailbox)
fire("MAIL_INBOX_UPDATE")
local collected = ForeverMarketsDB.fills[#ForeverMarketsDB.fills]
check("a collected sale is recorded with its gold, cut and deposit",
    collected.kind == "collected" and collected.what == "sold" and collected.money == 570 and collected.count == 20
    and collected.buyout == 600 and collected.cut == 30 and collected.deposit == 40)
check("the next press is the unsold listing", mailButton:GetText() == "Collect unsold listing")
mailButton:Click()
fire("MAIL_INBOX_UPDATE")
check("the letter from a friend is never touched", #looted == 2 and #inbox == 1 and inbox[1].subject == "Hello")
check("then there's nothing left to collect", not mailButton:IsEnabled() and #me.mail.waiting == 0)
fire("MAIL_CLOSED")
check("the mail panel closes with the mailbox", not mailPanel.shown)

-- ---- a vendor flip: bought at the auction house, sold at a vendor -------------
money = 1000000
vendorPrices[4306] = 150
ForeverMarkets_Data.personal.data.plans["Player-1-0001"] = { written = 4, steps = {
    { kind = "buy", item = 4306, name = "Silk Cloth", units = 12, maxPrice = 149, sellAt = 150, depositPerUnit = 0, vendor = 150 },
} }
book = { { unitPrice = 55, quantity = 10, auctionID = 41 }, { unitPrice = 140, quantity = 5, auctionID = 42 }, { unitPrice = 150, quantity = 20, auctionID = 43 } }
fire("AUCTION_HOUSE_SHOW")
check("a flip says it's for a vendor", button:GetText() == "Find Silk Cloth" and panelText():find("under 150c each, to sell to a vendor", 1, true) ~= nil)
local getItemInfo = C_Item.GetItemInfo
C_Item.GetItemInfo = function() return nil end -- the client hasn't loaded the item yet
press()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
check("a flip buys nothing until the game says what a vendor pays", button:GetText() == "Look again" and panelText():find("hasn't said yet", 1, true) ~= nil)
C_Item.GetItemInfo = getItemInfo
press()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
check("a flip offers only what's under the vendor price", button:GetText() == "Buy 12")
vendorPrices[4306] = 100 -- the game's vendor pays less than the plan was told
fire("AUCTION_HOUSE_CLOSED")
fire("AUCTION_HOUSE_SHOW")
press()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
check("and the game's own vendor price wins over a stale plan's", button:GetText() == "Buy 10" and panelText():find("A vendor pays 100c each", 1, true) ~= nil)
press()
fire("COMMODITY_PRICE_UPDATED", 100, 1000)
check("a quote at or over the game's vendor price is refused", calls[#calls][1] == "CancelCommoditiesPurchase")
press()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
press()
fire("COMMODITY_PRICE_UPDATED", 55, 550)
press()
fire("COMMODITY_PURCHASE_SUCCEEDED")
check("what a flip buys is kept for the vendor", me.vendor[4306] == 10)
widgets.ForeverMarketsPlanSkip:Click() -- the last 2 are gone
check("the finished plan says to sell at a vendor", panelText():find("Sell what you bought for vendors", 1, true) ~= nil)
fire("AUCTION_HOUSE_CLOSED")

-- the 10 bought stacked onto 4 of the player's own
contents[1][3] = { itemID = 4306, stackCount = 14 }
slots[1] = 4
fire("MERCHANT_SHOW")
local vendorPanel, vendorButton = widgets.ForeverMarketsVendorPanel, widgets.ForeverMarketsVendorButton
check("the vendor panel opens with what flips bought", vendorPanel and vendorPanel.shown
    and rawget(vendorPanel, "lines")[2]:GetText():find("10 item 4306, for 1000c", 1, true) ~= nil)
check("a stack holding the player's own is split first", vendorButton:GetText() == "Split off 10 item 4306")
ForeverMarkets_Next() -- the key binding works at a vendor too
check("one press splits off exactly what flips bought, into an empty slot",
    #containerCalls == 2 and containerCalls[1][1] == "SplitContainerItem" and containerCalls[1][2] == 1 and containerCalls[1][3] == 3 and containerCalls[1][4] == 10
    and containerCalls[2][1] == "PickupContainerItem" and containerCalls[2][2] == 1 and containerCalls[2][3] == 4)
contents[1][3].stackCount, contents[1][4] = 4, { itemID = 4306, stackCount = 10 }
fire("BAG_UPDATE_DELAYED")
check("then the split stack is sold", vendorButton:GetText() == "Sell 10 item 4306")
vendorButton:Click()
check("one press sells one stack", #containerCalls == 3 and containerCalls[3][1] == "UseContainerItem" and containerCalls[3][2] == 1 and containerCalls[3][3] == 4)
check("until the bags update, nothing more is sold", (function() ForeverMarkets_Next() return #containerCalls == 3 end)())
contents[1][4] = nil
fire("BAG_UPDATE_DELAYED")
local vendored = ForeverMarketsDB.fills[#ForeverMarketsDB.fills]
check("the sale is recorded and the flip's count is cleared",
    vendored.kind == "vendored" and vendored.item == 4306 and vendored.units == 10 and vendored.money == 1000 and me.vendor[4306] == nil)
check("the player's own are never sold", contents[1][3].stackCount == 4 and not vendorButton:IsEnabled() and #containerCalls == 3)
fire("MERCHANT_CLOSED")
check("the vendor panel closes with the vendor", not vendorPanel.shown)
fire("MERCHANT_SHOW")
check("and stays shut when nothing is bought for vendors", not vendorPanel.shown)
fire("MERCHANT_CLOSED")

-- ---- vendor flips, found and bought at the auction house --------------------------------------
money = 1000000
ForeverMarkets_Data.personal.data.plans["Player-1-0001"] = nil -- no plan: the plan's key drives the flips
vendorPrices[4306], vendorPrices[5216], vendorPrices[3001] = 150, 1500, 50
unloaded[3001] = true
local pages = {
    { { itemKey = { itemID = 4306, itemLevel = 0 }, minPrice = 55, totalQuantity = 30 },
      { itemKey = { itemID = 2589, itemLevel = 0 }, minPrice = 9, totalQuantity = 100 } }, -- a copper under: not worth it
    { { itemKey = { itemID = 5216, itemLevel = 41 }, minPrice = 1200, totalQuantity = 3 },
      { itemKey = { itemID = 3001, itemLevel = 0 }, minPrice = 10, totalQuantity = 1 },
      { itemKey = { itemID = 82800, battlePetSpeciesID = 40 }, minPrice = 1, totalQuantity = 1 } },
}
local loaded = 0
C_AuctionHouse.SendBrowseQuery = function(query) calls[#calls + 1] = { "SendBrowseQuery", query } loaded = 1 end
C_AuctionHouse.HasFullBrowseResults = function() return loaded >= #pages end
C_AuctionHouse.GetBrowseResults = function()
    local out = {}
    for i = 1, loaded do for _, row in ipairs(pages[i]) do out[#out + 1] = row end end
    return out
end
C_AuctionHouse.GetItemKeyInfo = function(key) return { itemName = ({ [4306] = "Silk Cloth", [5216] = "Umbral Wand" })[key.itemID] } end

fire("AUCTION_HOUSE_CLOSED")
fire("AUCTION_HOUSE_SHOW")
local flipsPanel, flipsButton = widgets.ForeverMarketsFlipsPanel, widgets.ForeverMarketsFlipsButton
local function flipsText(n) return rawget(flipsPanel, "lines")[n]:GetText() end -- [1] title, [2] what to do, [3..] the flips
check("the flips panel opens with the auction house, plan or not", flipsPanel.shown and not widgets.ForeverMarketsPlanPanel.shown)
check("it offers to scan again (the plan's key scanned once already)", flipsButton:GetText() == "Scan again")
ForeverMarkets_Next()
local query = calls[#calls]
check("one press of the plan's key scans: an empty search, the whole list", query[1] == "SendBrowseQuery" and query[2].searchString == "")
fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
check("the first page asks for the next", calls[#calls][1] == "RequestMoreBrowseResults")
check("and its flips can be looked at while the rest loads",
    flipsText(2):find("Scanning: 2 items so far, 1 flip.", 1, true) ~= nil and flipsButton:GetText() == "Look at Silk Cloth")
loaded = 2
fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", pages[2])
check("the scan ends with the last page, the most a vendor pays over the price first",
    flipsText(2):find("Scanned 5 items: 2 flips.", 1, true) ~= nil and flipsButton:GetText() == "Look at Umbral Wand"
    and flipsText(3) == "Umbral Wand: 1200c, a vendor pays 1500c" and flipsText(4) == "Silk Cloth: 55c, a vendor pays 150c")
unloaded[3001] = nil
fire("GET_ITEM_INFO_RECEIVED", 3001, true)
check("an item counts once the game says what a vendor pays for it", flipsText(5) == "item 3001: 10c, a vendor pays 50c")

-- gear, one auction per press, each against what a vendor pays for that very item
local auctions = {
    { auctionID = 71, buyoutAmount = 1200, quantity = 1, itemLink = "wand41" },
    { auctionID = 72, buyoutAmount = 1400, quantity = 1, itemLink = "wand41" },
    { auctionID = 73, buyoutAmount = 1600, quantity = 1, itemLink = "wand41" }, -- over what a vendor pays
    { auctionID = 74, buyoutAmount = 100, quantity = 1, itemLink = "wand41", containsOwnerItem = true }, -- the player's own
}
C_AuctionHouse.GetNumItemSearchResults = function() return #auctions end
C_AuctionHouse.GetItemSearchResultInfo = function(_, i) return auctions[i] end
vendorPrices.wand41 = 1500
ForeverMarkets_Flip() -- the flips' own key binding
check("a press looks at the best flip", calls[#calls][1] == "SendSearchQuery" and calls[#calls][2].itemID == 5216 and calls[#calls][2].itemLevel == 41)
fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 5216, itemLevel = 41, battlePetSpeciesID = 0 })
check("it offers the auction a vendor pays the most over", flipsButton:GetText() == "Buy for 1200c"
    and flipsText(2):find("1 more is under vendor price", 1, true) ~= nil)
flipsButton:Click()
check("one press buys that auction at its buyout", calls[#calls][1] == "PlaceBid" and calls[#calls][2] == 71 and calls[#calls][3] == 1200)
check("and waits for it", not flipsButton:IsEnabled())
fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 71)
local gearFill = ForeverMarketsDB.fills[#ForeverMarketsDB.fills]
check("the purchase is recorded as a flip, kept for the vendor", gearFill.kind == "bought" and gearFill.auction == 71 and gearFill.flip
    and gearFill.item == 5216 and gearFill.total == 1200 and me.vendor[5216] == 1)
check("and the next press buys the next one", flipsButton:GetText() == "Buy for 1400c")
widgets.ForeverMarketsFlipsSkip:Click()
check("Skip moves on to the next flip", flipsButton:GetText() == "Look at Silk Cloth")

-- a trade good: buy what's under the vendor price, confirm at the quoted price
book = { { unitPrice = 55, quantity = 10, auctionID = 81 }, { unitPrice = 140, quantity = 5, auctionID = 82 },
         { unitPrice = 150, quantity = 20, auctionID = 83 }, { unitPrice = 60, quantity = 5, auctionID = 84, containsOwnerItem = true } }
ForeverMarkets_Flip()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
check("it offers everything under what a vendor pays, not the player's own", flipsButton:GetText() == "Buy 15")
ForeverMarkets_Flip()
check("one press starts the purchase", calls[#calls][1] == "StartCommoditiesPurchase" and calls[#calls][2] == 4306 and calls[#calls][3] == 15)
fire("COMMODITY_PRICE_UPDATED", 150, 2250)
check("a quote that isn't under the vendor price is refused", calls[#calls][1] == "CancelCommoditiesPurchase" and flipsButton:GetText() == "Next flip")
flipsButton:Click()
check("then it's on to the next", flipsButton:GetText() == "Look at item 3001")
widgets.ForeverMarketsFlipsRescan:Click()
loaded = 2
fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
check("a new scan starts over, with what was skipped back in", flipsButton:GetText() == "Look at Umbral Wand")
widgets.ForeverMarketsFlipsSkip:Click()
ForeverMarkets_Flip()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
ForeverMarkets_Flip()
fire("COMMODITY_PRICE_UPDATED", 84, 1250)
check("a quote under the vendor price asks to confirm", flipsButton:GetText() == "Confirm")
ForeverMarkets_Flip()
check("one press confirms", calls[#calls][1] == "ConfirmCommoditiesPurchase" and calls[#calls][3] == 15)
fire("COMMODITY_PURCHASE_SUCCEEDED")
local goodsFill = ForeverMarketsDB.fills[#ForeverMarketsDB.fills]
check("the purchase is a flip, kept for the vendor", goodsFill.kind == "bought" and goodsFill.item == 4306 and goodsFill.flip and me.vendor[4306] == 15)
check("and the panel says what to do with it", flipsText(2):find("Bought 15 Silk Cloth for 1250c. Sell them to any vendor for 2250c.", 1, true) ~= nil)
book = { { unitPrice = 150, quantity = 20, auctionID = 83 } }
ForeverMarkets_Flip()
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 3001)
check("a flip someone bought first is passed over", flipsText(2):find("item 3001 was gone", 1, true) ~= nil and flipsButton:GetText() == "Scan again")

-- the auction house doesn't always answer: nothing stays greyed out
local function requests()
    local n = 0
    for _, c in ipairs(calls) do if c[1] == "RequestMoreBrowseResults" then n = n + 1 end end
    return n
end
timers = {}
pages = {
    { { itemKey = { itemID = 4306, itemLevel = 0 }, minPrice = 55, totalQuantity = 30 } },
    { { itemKey = { itemID = 2589, itemLevel = 0 }, minPrice = 9, totalQuantity = 100 } },
    { { itemKey = { itemID = 3001, itemLevel = 0 }, minPrice = 10, totalQuantity = 2 } },
}
ForeverMarkets_Flip()
fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
local asked = requests()
ForeverMarkets_Flip() -- look at Silk Cloth while the rest of the list loads
loaded = 2
fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", pages[2])
check("the scan stops asking for pages while a flip is looked at", requests() == asked)
check("while it looks, the button says so", not flipsButton:IsEnabled() and flipsButton:GetText() == "Looking…")
runTimers()
check("a look the auction house never answers offers to look again", flipsButton:IsEnabled() and flipsButton:GetText() == "Look again")
ForeverMarkets_Flip()
check("which searches again", calls[#calls][1] == "SendSearchQuery" and calls[#calls][2].itemID == 4306)
book = { { unitPrice = 150, quantity = 20, auctionID = 83 } }
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 4306)
check("done with the flip, the scan picks up where it left off", requests() == asked + 1)
check("with no flips yet, the button says the scan is going", not flipsButton:IsEnabled() and flipsButton:GetText() == "Scanning…")
for _ = 1, 4 do runTimers() end -- the page never comes, nor do three more asks
check("a page that never comes is asked for again, then left to the player",
    requests() == asked + 4 and flipsButton:IsEnabled() and flipsButton:GetText() == "Keep scanning")
ForeverMarkets_Flip()
check("one press asks again", requests() == asked + 5)
loaded = 3
fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", pages[3])
check("and the scan carries on to the end", flipsButton:GetText() == "Look at item 3001" and flipsText(2):find("Scanned 3 items", 1, true) ~= nil)
ForeverMarkets_Flip()
book = { { unitPrice = 10, quantity = 2, auctionID = 91 } }
fire("COMMODITY_SEARCH_RESULTS_UPDATED", 3001)
ForeverMarkets_Flip()
fire("COMMODITY_PRICE_UPDATED", 10, 20)
timers = {} -- only the purchase's own wait
ForeverMarkets_Flip()
runTimers()
check("a purchase the auction house doesn't confirm in time says where to look", flipsButton:GetText() == "Look again"
    and flipsText(2):find("No word on that purchase yet", 1, true) ~= nil)
fire("COMMODITY_PURCHASE_SUCCEEDED")
check("and when it does go through after all, it still counts", me.vendor[3001] == 2
    and flipsText(2):find("Bought 2 item 3001", 1, true) ~= nil)
fire("AUCTION_HOUSE_CLOSED")
check("the flips panel closes with the auction house", not flipsPanel.shown)

-- what Courier writes, and what it doesn't
local delivered = ForeverMarkets_Data
ForeverMarkets_Data = { status = delivered.status, personal = nil }
check("an empty personal publication is no plan", ns.plan() == nil)
ForeverMarkets_Data = { plans = { ["Player-1-0001"] = { written = 9, steps = { { kind = "sell", item = 1, units = 1, price = 1 } } } } }
printed = {}
fire("PLAYER_LOGIN")
check("the retired desktop app's folder gives no plan, and the player is told to delete it", ns.plan() == nil
    and (printed[#printed] or ""):find("delete Interface/AddOns/ForeverMarkets_Data", 1, true) ~= nil)
ForeverMarkets_Data = { status = { app = "courier", sharing = false } }
printed = {}
SlashCmdList.FOREVERMARKETS()
check("/fm says when sharing is off in the Courier app", (printed[#printed] or ""):find("sharing is off", 1, true) ~= nil)
ForeverMarkets_Data = nil
printed = {}
SlashCmdList.FOREVERMARKETS()
check("/fm says how to get Courier when it hasn't written the data addon", (printed[#printed] or ""):find("Install the Courier app", 1, true) ~= nil)
ForeverMarkets_Data = delivered

-- a reload keeps what was there
local big = {}
for i = 1, 600 do big[i] = { i, 1, 1, 0, 0 } end
table.insert(ForeverMarketsDB.scans, { t = 1, kind = "browse", rows = big })
local fillsBeforeReload = #ForeverMarketsDB.fills
local kept = ForeverMarketsDB
chunk("ForeverMarkets")
fire("ADDON_LOADED", "ForeverMarkets")
check("a reload keeps earlier records", ForeverMarketsDB == kept and #ForeverMarketsDB.fills == fillsBeforeReload)
check("and trims search lists saved before they were capped", #big == 500)

os.exit(failures == 0 and 0 or 1)
