-- ForeverMarkets: records what the web app needs, and loads the plan it sends.
--
-- Out of the game: everything below goes into SavedVariables (ForeverMarketsDB),
-- which WoW writes on /reload and logout; the Courier app uploads it to our server from there.
-- Into the game: Courier writes a data-only addon, ForeverMarkets_Data, whose
-- global this addon reads at login. Nothing here sends input to the game or acts
-- on its own: carrying out a plan stays one key press per action.

local ADDON, ns = ...
ns = ns or {} -- the namespace Plan.lua shares; a test harness may not pass one
local VERSION = 1
local MAX_SCANS = 300   -- order books kept between syncs; the oldest go first
local MAX_FILLS = 2000
local MAX_VISITS = 200
local MAX_ERRORS = 50
local MAX_LEDGER = 500  -- gold over time, per character: the challenge's scoreboard
local MAX_WANTED = 2000 -- items whose vendor price the client is still loading
-- Rows kept from one search's list. The flips panel's scan lists the whole auction house, and a
-- saved file of whole lists grew to 12 MB, slowing every /reload; every row still has its vendor
-- price recorded.
local MAX_BROWSE_ROWS = 500

local frame = CreateFrame("Frame")
local db, character

local function now()
    return time()
end

local function push(list, entry, max)
    list[#list + 1] = entry
    while #list > max do
        table.remove(list, 1)
    end
end

-- Characters are keyed by GUID: Forever has surnames and rulesets, not realms,
-- and a GUID is unique whatever the game calls the rest.
-- Forever characters have a surname, and no published API names one yet. Look for any function
-- whose name mentions it (globals and C_ namespaces), keep the first that gives the player's, and
-- record which one it was so it can be called directly once known.
local function surname()
    local found = {}
    for key, value in pairs(_G) do
        if type(key) == "string" then
            if type(value) == "function" and key:lower():find("surname") then
                found[#found + 1] = { key, value }
            elseif type(value) == "table" and key:find("^C_") then
                for inner, fn in pairs(value) do
                    if type(inner) == "string" and type(fn) == "function" and inner:lower():find("surname") then
                        found[#found + 1] = { key .. "." .. inner, fn }
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b) return a[1] < b[1] end)
    local names = {}
    for i, candidate in ipairs(found) do
        names[i] = candidate[1]
    end
    local first = UnitName("player")
    for _, candidate in ipairs(found) do
        for _, args in ipairs({ { "player" }, {}, { UnitGUID("player") } }) do
            local ok, value = pcall(candidate[2], unpack(args))
            -- a function that only reformats what it's given (Forever has
            -- C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator) hands the argument back
            if ok and type(value) == "string" and value ~= "" and value ~= args[1] and value ~= first then
                return value, candidate[1], names
            end
        end
    end
    return nil, #names > 0 and ("tried: " .. table.concat(names, ", ")) or "none found", names
end

local function loadCharacter()
    local guid = UnitGUID("player")
    if not guid then
        return
    end
    db.characters[guid] = db.characters[guid] or {}
    character = db.characters[guid]
    character.name = UnitName("player")
    character.faction = UnitFactionGroup("player")
    local apis
    character.surname, character.surnameFrom, apis = surname()
    -- every function with "surname" in its name, for finding the one that names the player
    character.surnameApis = #apis > 0 and table.concat(apis, ", ") or nil
end

-- What the game says a vendor pays, for every item the addon sees: in the bags, the bank, a
-- search's list and the listings opened. Blizzard's API vendor prices have been wrong for
-- Forever's gear, so the app checks them against these. db.vendorPrices[itemID] = copper (0:
-- vendors won't buy it). Gear of another item level can sell for something else, so an item
-- book also records, per item level its listings had, what the listed item itself sells for
-- (db.vendorLevels[itemID][itemLevel]) whenever that differs.
local wanted, wantedCount = {}, 0

local function noteVendor(itemID)
    if not db or not itemID or itemID == 0 or db.vendorPrices[itemID] then
        return
    end
    local price = select(11, C_Item.GetItemInfo(itemID))
    if price then
        db.vendorPrices[itemID] = price
    elseif not wanted[itemID] and wantedCount < MAX_WANTED then
        -- GetItemInfo has asked the server; GET_ITEM_INFO_RECEIVED says when it's here
        wanted[itemID], wantedCount = true, wantedCount + 1
    end
end

local function noteVendorOfLink(itemID, level, link)
    if not db or not itemID or not level or level == 0 or not link then
        return
    end
    local price = select(11, C_Item.GetItemInfo(link))
    local base = db.vendorPrices[itemID]
    if price and base and price ~= base then
        db.vendorLevels[itemID] = db.vendorLevels[itemID] or {}
        db.vendorLevels[itemID][level] = price
    end
end

local function countContainers(bags)
    local counts = {}
    for _, bag in ipairs(bags) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
                noteVendor(info.itemID)
            end
        end
    end
    return counts
end

-- Bag and bank container ids differ between clients, so they come from
-- Enum.BagIndex by name rather than from a hard-coded list.
local function containers(wantBank)
    local out = {}
    for name, index in pairs(Enum.BagIndex or {}) do
        local isBank = name:find("Bank") ~= nil
        local isBag = name == "Backpack" or name:find("^Bag_") or name == "ReagentBag"
        if (wantBank and isBank and not name:find("Account")) or (not wantBank and isBag) then
            out[#out + 1] = index
        end
    end
    return out
end

local function recordMoney()
    if not character then
        return
    end
    character.money = GetMoney()
    character.updated = now()
    -- the ledger: every change of gold, so the app can show 50 silver becoming more
    character.ledger = character.ledger or {}
    local last = character.ledger[#character.ledger]
    if not last or last[2] ~= character.money then
        push(character.ledger, { character.updated, character.money }, MAX_LEDGER)
    end
end

-- Mail from the auction house: sold auctions' gold, unsold listings coming back, won auctions.
-- A sale's gold only reaches the bags once the mail is collected, so the app needs to know.
local function pattern(format)
    if not format then
        return nil
    end
    local escaped = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    return "^" .. escaped:gsub("%%s", "(.+)") .. "$"
end
local subjects = {
    sold = pattern(AUCTION_SOLD_MAIL_SUBJECT),
    expired = pattern(AUCTION_EXPIRED_MAIL_SUBJECT),
    won = pattern(AUCTION_WON_MAIL_SUBJECT),
    cancelled = pattern(AUCTION_REMOVED_MAIL_SUBJECT),
}

--- One auction house mail as { kind, name, count, money, item, buyout, cut, deposit }, or nil.
function ns.auctionMail(index)
    local _, _, _, subject, money = GetInboxHeaderInfo(index)
    local invoiceType, itemName, _, _, buyout, deposit, cut, _, _, count = GetInboxInvoiceInfo(index)
    local kind, name = nil, nil
    if invoiceType == "seller" then
        kind, name = "sold", itemName
    elseif invoiceType == "buyer" then
        kind, name = "won", itemName
    else
        for k, p in pairs(subjects) do
            local match = p and subject and subject:match(p)
            if match then
                kind, name = k, match
                break
            end
        end
    end
    if not kind then
        return nil
    end
    local _, item, _, itemCount = GetInboxItem(index, 1)
    return {
        kind = kind,
        name = name,
        count = count or itemCount,
        money = money or 0,
        item = item,
        buyout = buyout,
        cut = cut,
        deposit = deposit,
    }
end

local function recordMail()
    if not character then
        return
    end
    local waiting = {}
    for index = 1, (GetInboxNumItems()) or 0 do
        local mail = ns.auctionMail(index)
        if mail then
            waiting[#waiting + 1] = mail
        end
    end
    character.mail = { t = now(), waiting = waiting }
end

local function recordBags()
    if character then
        character.bags = countContainers(containers(false))
        character.updated = now()
    end
end

local function recordBank()
    if character then
        character.bank = countContainers(containers(true))
        character.bankUpdated = now()
    end
end

-- Order books seen in the auction house. Auction ids are Blizzard's, the same
-- ones the archive stores, which is how the app knows which house this was.
local function recordCommodityBook(itemID)
    noteVendor(itemID)
    local rows = {}
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if info then
            rows[#rows + 1] = { info.unitPrice, info.quantity, info.auctionID, info.containsOwnerItem or nil }
        end
    end
    push(db.scans, {
        t = now(),
        kind = "commodity",
        item = itemID,
        full = C_AuctionHouse.HasFullCommoditySearchResults(itemID) or nil,
        rows = rows,
    }, MAX_SCANS)
end

local function recordItemBook(itemKey)
    local pet = (itemKey.battlePetSpeciesID or 0) ~= 0
    if not pet then
        noteVendor(itemKey.itemID)
    end
    local rows = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 do
        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if info then
            if not pet and i == 1 then
                noteVendorOfLink(itemKey.itemID, itemKey.itemLevel, info.itemLink)
            end
            -- 0 for an auction with no buyout, so the row has no hole
            rows[#rows + 1] = { info.buyoutAmount or 0, info.quantity, info.auctionID, info.containsOwnerItem or nil }
        end
    end
    push(db.scans, {
        t = now(),
        kind = "item",
        item = itemKey.itemID,
        level = itemKey.itemLevel,
        species = itemKey.battlePetSpeciesID ~= 0 and itemKey.battlePetSpeciesID or nil,
        rows = rows,
    }, MAX_SCANS)
end

-- The list a search shows first: one row per item with its cheapest price and
-- total quantity. It carries no auction ids (those arrive only when an item's
-- listings are opened), but it prices many items in one search. Rows are
-- { itemID, minPrice, totalQuantity, itemLevel, petSpeciesID }, with 0 for
-- none, so no row has holes.
local function browseRow(info)
    local key = info.itemKey or {}
    if (key.battlePetSpeciesID or 0) == 0 then
        noteVendor(key.itemID)
    end
    return { key.itemID, info.minPrice, info.totalQuantity, key.itemLevel or 0, key.battlePetSpeciesID or 0 }
end

local function recordBrowse()
    local rows = {}
    for _, info in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
        local row = browseRow(info)
        if #rows < MAX_BROWSE_ROWS then
            rows[#rows + 1] = row
        end
    end
    push(db.scans, { t = now(), kind = "browse", rows = rows }, MAX_SCANS)
end

-- Scrolling a long list loads more results; they belong to the list on screen.
local function addBrowse(added)
    local last = db.scans[#db.scans]
    if not (last and last.kind == "browse") then
        return recordBrowse()
    end
    for _, info in ipairs(added or {}) do
        local row = browseRow(info)
        if #last.rows < MAX_BROWSE_ROWS then
            last.rows[#last.rows + 1] = row
        end
    end
end

local function npcID()
    local ok, id = pcall(function()
        return tonumber(UnitGUID("npc"):match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
    end)
    return ok and id or nil
end

-- Where the auction house was opened. Forever has five houses per faction and
-- nothing in the API names them, so the place and the auctioneer are the clues
-- for telling them apart.
local function recordVisit()
    push(db.visits, {
        t = now(),
        character = UnitGUID("player"),
        map = C_Map.GetBestMapForUnit("player"),
        zone = GetZoneText(),
        subzone = GetSubZoneText(),
        npc = UnitName("npc"),
        npcID = npcID(),
    }, MAX_VISITS)
end

local function recordOwned()
    if not character then
        return
    end
    local owned = {}
    for i = 1, C_AuctionHouse.GetNumOwnedAuctions() or 0 do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if info then
            owned[#owned + 1] = {
                id = info.auctionID,
                item = info.itemKey and info.itemKey.itemID,
                quantity = info.quantity,
                buyout = info.buyoutAmount,
                status = info.status,
            }
        end
    end
    character.owned = owned
    character.ownedUpdated = now()
end

local function fill(kind, fields)
    fields.t = now()
    fields.kind = kind
    fields.character = character and UnitGUID("player")
    push(db.fills, fields, MAX_FILLS)
end

-- A commodity purchase is announced without saying what was bought, so the
-- request is remembered when it starts and the price when the game quotes it.
local pendingCommodity
hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, quantity)
    pendingCommodity = { item = itemID, quantity = quantity }
end)

local soldPattern = ERR_AUCTION_SOLD_S and ("^" .. ERR_AUCTION_SOLD_S:gsub("%%s", "(.+)") .. "$")

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON then
        return
    end
    ForeverMarketsDB = ForeverMarketsDB or {}
    db = ForeverMarketsDB
    db.version = VERSION
    db.characters = db.characters or {}
    db.scans = db.scans or {}
    db.fills = db.fills or {}
    db.visits = db.visits or {}
    db.errors = db.errors or {}
    db.vendorPrices = db.vendorPrices or {}
    db.vendorLevels = db.vendorLevels or {}
    -- lists saved before they were capped
    for _, scan in ipairs(db.scans) do
        if scan.kind == "browse" and scan.rows and #scan.rows > MAX_BROWSE_ROWS then
            for i = #scan.rows, MAX_BROWSE_ROWS + 1, -1 do
                scan.rows[i] = nil
            end
        end
    end
end

function handlers.PLAYER_LOGIN()
    loadCharacter()
    recordMoney()
    recordBags()
    if ns.staleDataAddon and ns.staleDataAddon() then
        -- The retired desktop app's folder: Courier won't write over it, so no plan can arrive.
        print("|cff33ff99ForeverMarkets|r: the old desktop app's ForeverMarkets_Data folder is still installed, so Courier can't deliver your plans. Quit the game, delete Interface/AddOns/ForeverMarkets_Data, and start it again.")
        return
    end
    local plan = ns.plan and ns.plan()
    if plan and #plan.steps > 0 then
        print(("|cff33ff99ForeverMarkets|r: plan loaded, %d step(s). Open the auction house to start."):format(#plan.steps))
    end
end

handlers.PLAYER_MONEY = recordMoney
handlers.MAIL_SHOW = recordMail
handlers.MAIL_INBOX_UPDATE = recordMail
-- Read again once in the world, in case the client reports money late at login.
handlers.PLAYER_ENTERING_WORLD = recordMoney
handlers.BAG_UPDATE_DELAYED = recordBags
handlers.AUCTION_HOUSE_SHOW = recordVisit
handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = recordBrowse
handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED = addBrowse
handlers.BANKFRAME_OPENED = recordBank
handlers.PLAYERBANKSLOTS_CHANGED = recordBank
handlers.COMMODITY_SEARCH_RESULTS_UPDATED = recordCommodityBook
handlers.ITEM_SEARCH_RESULTS_UPDATED = recordItemBook
handlers.OWNED_AUCTIONS_UPDATED = recordOwned

function handlers.GET_ITEM_INFO_RECEIVED(itemID, success)
    if wanted[itemID] then
        wanted[itemID], wantedCount = nil, wantedCount - 1
        if success then
            noteVendor(itemID)
        end
    end
end

function handlers.COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
    if pendingCommodity then
        pendingCommodity.unitPrice = unitPrice
        pendingCommodity.total = totalPrice
    end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
    if pendingCommodity then
        fill("bought", pendingCommodity)
        pendingCommodity = nil
    end
end

function handlers.COMMODITY_PURCHASE_FAILED()
    pendingCommodity = nil
end

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
    fill("bought", { auction = auctionID })
end

function handlers.AUCTION_HOUSE_AUCTION_CREATED(auctionID)
    fill("posted", { auction = auctionID })
end

function handlers.CHAT_MSG_SYSTEM(message)
    -- WoW 12 hands addons some chat text as a secret value, which can't be read
    if type(message) ~= "string" or (issecretvalue and issecretvalue(message)) then
        return
    end
    local item = soldPattern and message:match(soldPattern)
    if item then
        fill("sold", { name = item })
    end
end

-- WoW hides Lua errors unless the player turns them on, so a handler that
-- breaks in a real client would fail without a trace. Errors are kept in the
-- saved file, where the app can show them, and still go to WoW's own handler.
local listeners = {} -- event -> functions Plan.lua added, run after the handler

local function run(event, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        if db then
            push(db.errors, { t = now(), event = event, message = tostring(err) }, MAX_ERRORS)
        end
        geterrorhandler()(err)
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if handlers[event] then
        run(event, handlers[event], ...)
    end
    for _, fn in ipairs(listeners[event] or {}) do
        run(event, fn, ...)
    end
end)

-- A client that lacks an event refuses to register it with an error, and an
-- error here would stop the addon loading at all; parses-desktop learned that on
-- Classic. Register each one on its own.
for event in pairs(handlers) do
    pcall(frame.RegisterEvent, frame, event)
end

-- What Plan.lua shares.
function ns.listen(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], fn)
    pcall(frame.RegisterEvent, frame, event)
end
ns.db = function() return db end
ns.guid = function() return UnitGUID("player") end
ns.now = now
ns.containers = containers
ns.fill = fill
ns.recordMail = recordMail

SLASH_FOREVERMARKETS1 = "/fm"
SlashCmdList.FOREVERMARKETS = function()
    local plan = ns.plan and ns.plan()
    print(("|cff33ff99ForeverMarkets|r: %d order book(s), %d fill(s), %d auction house visit(s) and %d error(s) recorded; plan has %d step(s). /reload to send them (the Courier app uploads them).")
        :format(#db.scans, #db.fills, #db.visits, #db.errors, plan and #plan.steps or 0))
    local status = type(ForeverMarkets_Data) == "table" and ForeverMarkets_Data.status
    if type(status) ~= "table" then
        print("|cff33ff99ForeverMarkets|r: Courier hasn't written ForeverMarkets_Data yet. Install the Courier app, sign in, share ForeverMarkets, then restart the game.")
    elseif status.sharing == false then
        print("|cff33ff99ForeverMarkets|r: sharing is off in the Courier app, so nothing is sent and no new plan arrives.")
    end
end
