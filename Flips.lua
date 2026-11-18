-- ForeverMarkets flips: finds everything listed under what a vendor pays for it, right at the
-- auction house, and buys it one press at a time to sell at any vendor (the vendor panel in
-- Plan.lua does the selling).
--
-- A scan is one press: an empty search, the auction house's whole list. The addon loads the rest
-- of the list's pages as the game allows; that only reads. Each item's cheapest price is set
-- against what the game says a vendor pays for it, and anything under that, by enough to be worth
-- the presses, is a flip. The game's own vendor prices are used, never Blizzard's web API's, which
-- are wrong for much of Forever's gear.
--
-- The auction house limits how fast an addon may ask it things, and drops what comes too fast, so
-- the scan stops loading pages while a flip is being worked on and picks up again after. No wait
-- is left open: if the auction house doesn't answer within a few seconds, the button offers to
-- try again rather than staying greyed out.
--
-- Buying stays one action per press, as Blizzard's rules require. "Look" opens the item's
-- listings. A trade good is then bought like a plan step: buy what's under the vendor price and
-- what the gold covers, then confirm at the price the game quotes, which is refused unless it's
-- under the vendor price. Gear is bought one auction per press at its buyout, each checked against
-- what a vendor pays for that very item (its link), since gear of another item level can sell for
-- something else. Bought gear comes by mail.

local _, ns = ...
ns = ns or {}

BINDING_NAME_FOREVERMARKETS_FLIP = "Do the next vendor flip"

local SHOWN = 5 -- flips listed in the panel, best first
-- A flip is worth the presses when a vendor pays at least this much more per unit, and this share
-- of the price more: a copper on a 6-silver item isn't worth the gold it ties up.
local MIN_MARGIN = 2
local MIN_RETURN = 0.05
-- Enum.AuctionHouseSortOrder.Price, should the client not have the enum.
local PRICE_ORDER = 0
-- Seconds to wait for the auction house to answer before offering to try again; a purchase gets
-- longer. A page of the scan that doesn't come is asked for again this many times.
local WAIT = 5
local WAIT_BUYING = 10
local PAGE_RETRIES = 3

local panel, status, button, skip, rescan
local lines = {}
local scan = { rows = 0 } -- the last scan: rows read, whether it's still loading, when it finished
local flips = {} -- key -> flip, from the browse lists seen since the last scan began
local done = {} -- key -> true: bought, gone or skipped since the last scan began
local waiting = {} -- itemID -> browse rows waiting for the game to say what a vendor pays
local state = {} -- the flip being worked on: { flip, phase, ... }
local inflight -- the purchase sent and not yet answered: { kind, flip, quantity, auction }
local waits = 0 -- numbers each wait, so a timer only acts on the wait it was set for

local function money(copper)
    return ns.money(copper)
end

local function keyOf(itemKey)
    return ("%d:%d:%d"):format(itemKey.itemID or 0, itemKey.itemLevel or 0, itemKey.itemSuffix or 0)
end

local function nameOf(itemKey)
    local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(itemKey)
    return (info and info.itemName) or C_Item.GetItemInfo(itemKey.itemID) or ("item " .. itemKey.itemID)
end

--- What a vendor pays for one of an item key, as the game says: for its item level when the
--- addon has seen that level sell for something else, else for the item, asking the client first
--- and its saved answer for an item it hasn't loaded this session. Nil until known.
local function vendorOf(itemKey)
    local db = ns.db()
    local levels = db.vendorLevels and db.vendorLevels[itemKey.itemID]
    local byLevel = levels and itemKey.itemLevel and levels[itemKey.itemLevel]
    return byLevel or ns.vendorPrice(itemKey.itemID) or (db.vendorPrices and db.vendorPrices[itemKey.itemID])
end

local function worth(price, vendor)
    local margin = vendor - price
    return margin >= MIN_MARGIN and margin >= price * MIN_RETURN
end

--- A browse row: a flip if its cheapest listing is under what a vendor pays by enough.
local function consider(row)
    local itemKey = row.itemKey
    if not itemKey or not itemKey.itemID or (itemKey.battlePetSpeciesID or 0) ~= 0 or not row.minPrice then
        return
    end
    local key = keyOf(itemKey)
    local vendor = vendorOf(itemKey)
    if vendor == nil then
        waiting[itemKey.itemID] = waiting[itemKey.itemID] or {}
        table.insert(waiting[itemKey.itemID], row)
    elseif vendor > 0 and worth(row.minPrice, vendor) then
        flips[key] = { key = key, itemKey = itemKey, price = row.minPrice, quantity = row.totalQuantity, vendor = vendor }
    else
        flips[key] = nil
    end
end

--- The flips not yet bought, gone or skipped, the most a vendor pays over the price first.
local function ranked()
    local out = {}
    for key, f in pairs(flips) do
        if not done[key] then
            out[#out + 1] = f
        end
    end
    table.sort(out, function(a, b)
        local ma, mb = a.vendor - a.price, b.vendor - b.price
        if ma ~= mb then
            return ma > mb
        end
        return a.key < b.key
    end)
    return out
end

--- The panel's message, and its button: `action` to press, or greyed out saying what it waits for.
local function say(message, action, waitingFor)
    status:SetText(message)
    if action then
        button:SetText(action)
        button:Enable()
    else
        button:SetText(waitingFor or "Waiting for the auction house…")
        button:Disable()
    end
end

local function after(seconds, fn)
    ns.after(seconds, fn)
end

local function plural(n, word)
    return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local function render()
    if not panel or not panel:IsShown() then
        return
    end
    local list = ranked()
    for i = 1, SHOWN do
        local f = list[i]
        lines[i]:SetText(f and ("%s: %s, a vendor pays %s"):format(nameOf(f.itemKey), money(f.price), money(f.vendor)) or "")
    end
    local found = plural(#list, "flip")
    local progress = scan.loading and ("Scanning: %d items so far, %s."):format(scan.rows, found)
        or scan.at and ("Scanned %d items: %s."):format(scan.rows, found)
        or ""
    local note = state.note and (state.note .. " ") or ""
    local f = state.flip
    local phase = state.phase or "pick"
    skip:SetShown(phase ~= "pick" or #list > 0)
    rescan:SetShown(scan.at ~= nil or scan.loading == true)
    if phase == "pick" then
        if list[1] then
            say(note .. (progress ~= "" and progress or ("From your searches: %s."):format(found)), "Look at " .. nameOf(list[1].itemKey))
        elseif not scan.at and not scan.loading then
            say(note .. "Scan the auction house for anything listed under what a vendor pays for it.", "Scan the auction house")
        elseif scan.stalled then
            say(note .. ("The auction house stopped sending the list after %d items, with no flips so far."):format(scan.rows), "Keep scanning")
        elseif scan.loading then
            say(note .. progress, nil, "Scanning…")
        else
            say(note .. progress .. " Nothing under vendor price right now; scan again later.", "Scan again")
        end
    elseif phase == "searching" then
        say(("Looking at %s…"):format(nameOf(f.itemKey)), nil, "Looking…")
    elseif phase == "slow" then
        say(state.slowFrom == "buying"
            and "No word on that purchase yet. If it went through, it's in your bags (or the mail, for gear). Look again to see what's left."
            or state.slowFrom == "quoting" and "No price came back, so nothing was bought. The auction house may be busy; look again."
            or "The auction house hasn't answered. It may be busy; look again.", "Look again")
    elseif phase == "checking" then
        say(("The game hasn't said yet what a vendor pays for %s, so nothing is bought. Look again in a moment."):format(nameOf(f.itemKey)), "Look again")
    elseif phase == "found" then
        say(("%d under the %s a vendor pays. Buy %d for about %s, which a vendor buys back for %s?"):format(
            state.available, money(state.vendor), state.quantity, money(state.cost), money(state.vendor * state.quantity)), ("Buy %d"):format(state.quantity))
    elseif phase == "quoting" then
        say("Asking the auction house for its price…", nil, "Asking for the price…")
    elseif phase == "confirm" then
        say(("Buy %d %s for %s (%s each)? A vendor pays %s each."):format(
            state.quantity, nameOf(f.itemKey), money(state.total), money(state.unitPrice), money(state.vendor)), "Confirm")
    elseif phase == "auction" then
        local a = state.auction
        local others = state.more > 0 and (" %d more %s under vendor price."):format(state.more, state.more == 1 and "is" or "are") or ""
        say(("%s for %s, and a vendor pays %s for it.%s It comes by mail."):format(nameOf(f.itemKey), money(a.buyout), money(a.vendor), others),
            "Buy for " .. money(a.buyout))
    elseif phase == "buying" then
        say("Buying…", nil, "Buying…")
    elseif phase == "poor" then
        say(("Your %s doesn't cover even one %s under the vendor price."):format(money(GetMoney()), nameOf(f.itemKey)), "Next flip")
    elseif phase == "refused" then
        say(("The auction house asked %s each, not under the %s a vendor pays, so nothing was bought."):format(money(state.unitPrice), money(state.vendor)), "Next flip")
    elseif phase == "failed" then
        say("That purchase didn't go through; nothing was bought.", "Next flip")
    end
end

--- Done with the flip being worked on: on to the next, with a word on how this one went.
--- A flip is being looked at or bought.
local function working()
    return state.phase ~= nil and state.phase ~= "pick"
end

--- Wait for the auction house to answer `phase`; if it hasn't within `seconds`, offer to try again.
local function waitFor(phase, seconds)
    waits = waits + 1
    local id = waits
    state.wait = id
    after(seconds or WAIT, function()
        if state.wait ~= id or state.phase ~= phase then
            return
        end
        if phase == "quoting" then
            C_AuctionHouse.CancelCommoditiesPurchase()
            ns.buyer, inflight = nil, nil
        end
        state.phase, state.slowFrom = "slow", phase
        render()
    end)
end

--- The next page of the scan's list, unless a flip is being worked on: the auction house drops
--- requests that come too fast, and the player's look or purchase matters more.
local function more()
    if not scan.loading then
        return
    end
    if C_AuctionHouse.HasFullBrowseResults() then
        scan.loading, scan.at, scan.stalled = false, ns.now(), false
    elseif working() then
        scan.paused = true -- finish() picks it up again
    elseif not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady() then
        scan.asked = (scan.asked or 0) + 1
        local asked, rows = scan.asked, scan.rows
        C_AuctionHouse.RequestMoreBrowseResults()
        -- a page that doesn't come is asked for again, a few times, then left to the player
        after(WAIT, function()
            if not scan.loading or scan.asked ~= asked or scan.rows ~= rows or working() then
                return
            end
            scan.retries = (scan.retries or 0) + 1
            if scan.retries <= PAGE_RETRIES then
                more()
            else
                scan.stalled = true
                render()
            end
        end)
    else
        scan.throttled = true -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY asks again
    end
end

local function finish(note)
    if state.flip then
        done[state.flip.key] = true
    end
    if not inflight then
        ns.buyer = nil
    end
    state = { note = note }
    if scan.paused then
        scan.paused = false
        more()
    end
    render()
end

local function startScan()
    flips, done, waiting = {}, {}, {}
    scan = { rows = 0, loading = true, asked = 0 }
    state = {}
    -- a first page that doesn't come is left to the player, like any other
    local this = scan
    after(WAIT * 2, function()
        if scan == this and scan.loading and scan.rows == 0 and scan.asked == 0 then
            scan.stalled = true
            render()
        end
    end)
    C_AuctionHouse.SendBrowseQuery({
        searchString = "",
        sorts = { { sortOrder = (Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or PRICE_ORDER, reverseSort = false } },
        filters = {},
        itemClassFilters = {},
    })
end

--- One action: scan, look at the best flip, buy, or confirm. Runs only inside a click or key
--- press: the panel's button, the "Do the next vendor flip" binding, or the plan's key when the
--- plan has no step left.
function ForeverMarkets_Flip()
    if not panel or not panel:IsShown() or not button:IsEnabled() then
        return
    end
    local phase = state.phase or "pick"
    local f = state.flip
    if phase == "pick" then
        local best = ranked()[1]
        if best then
            state = { flip = best, phase = "searching" }
            waitFor("searching")
            C_AuctionHouse.SendSearchQuery(best.itemKey, {}, false)
        elseif scan.stalled and (scan.rows > 0 or scan.asked > 0) then
            scan.stalled, scan.retries = false, 0
            more()
        else
            startScan()
        end
    elseif phase == "checking" or phase == "slow" then
        state.phase = "searching"
        waitFor("searching")
        C_AuctionHouse.SendSearchQuery(f.itemKey, {}, false)
    elseif phase == "found" then
        state.phase = "quoting"
        ns.buyer = "flips"
        inflight = { kind = "commodity", flip = f, quantity = state.quantity }
        waitFor("quoting")
        C_AuctionHouse.StartCommoditiesPurchase(f.itemKey.itemID, state.quantity)
    elseif phase == "confirm" then
        state.phase = "buying"
        waitFor("buying", WAIT_BUYING)
        C_AuctionHouse.ConfirmCommoditiesPurchase(f.itemKey.itemID, state.quantity)
    elseif phase == "auction" then
        state.phase = "buying"
        ns.buyer = "flips"
        inflight = { kind = "auction", flip = f, auction = state.auction }
        waitFor("buying", WAIT_BUYING)
        C_AuctionHouse.PlaceBid(state.auction.auctionID, state.auction.buyout)
    elseif phase == "poor" or phase == "refused" or phase == "failed" then
        finish(nil)
        return
    end
    render()
end
ns.flipNext = ForeverMarkets_Flip

-- ---- the scan -----------------------------------------------------------------------------
-- Any browse list counts, the player's own searches too; only the panel's scan loads more pages.
ns.listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    local rows = C_AuctionHouse.GetBrowseResults() or {}
    if scan.loading then
        scan.rows = #rows
        scan.retries, scan.stalled = 0, false
    end
    for _, row in ipairs(rows) do
        consider(row)
    end
    more()
    render()
end)

ns.listen("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added)
    if scan.loading then
        scan.rows = scan.rows + #(added or {})
        scan.retries, scan.stalled = 0, false
    end
    for _, row in ipairs(added or {}) do
        consider(row)
    end
    more()
    render()
end)

ns.listen("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    if scan.throttled then
        scan.throttled = false
        more()
    end
end)

-- The main file has recorded the price by now, when the game had it.
ns.listen("GET_ITEM_INFO_RECEIVED", function(itemID)
    local rows = waiting[itemID]
    if rows then
        waiting[itemID] = nil
        for _, row in ipairs(rows) do
            if vendorOf(row.itemKey) ~= nil then
                consider(row)
            end
        end
        render()
    end
end)

-- ---- a trade good -------------------------------------------------------------------------
ns.listen("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    local f = state.flip
    if not f or state.phase ~= "searching" or f.itemKey.itemID ~= itemID then
        return
    end
    state.wait = nil
    local vendor = ns.vendorPrice(itemID)
    if not vendor then
        state.phase = "checking"
        render()
        return
    end
    -- everything under what a vendor pays, cheapest first, and what the gold covers of it
    local rows = {}
    for n = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local row = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, n)
        if row and row.unitPrice < vendor and not row.containsOwnerItem then
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b) return a.unitPrice < b.unitPrice end)
    local available, quantity, cost, gold = 0, 0, 0, GetMoney()
    for _, row in ipairs(rows) do
        available = available + row.quantity
        local take = math.min(row.quantity, math.floor(gold / row.unitPrice))
        quantity, cost, gold = quantity + take, cost + take * row.unitPrice, gold - take * row.unitPrice
    end
    state.vendor, state.available, state.quantity, state.cost = vendor, available, quantity, cost
    if available == 0 then
        finish(("%s was gone: someone bought it first."):format(nameOf(f.itemKey)))
        return
    end
    state.phase = quantity > 0 and "found" or "poor"
    render()
end)

ns.listen("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
    if ns.buyer ~= "flips" or state.phase ~= "quoting" then
        return
    end
    state.wait = nil
    state.unitPrice, state.total = unitPrice, totalPrice
    if unitPrice < state.vendor then
        state.phase = "confirm"
    else
        C_AuctionHouse.CancelCommoditiesPurchase()
        ns.buyer, inflight = nil, nil
        state.phase = "refused"
    end
    render()
end)

-- A purchase counts when the game says it went through, even if the panel had stopped waiting.
ns.listen("COMMODITY_PURCHASE_SUCCEEDED", function()
    if ns.buyer ~= "flips" or not inflight or inflight.kind ~= "commodity" then
        return
    end
    local f, quantity = inflight.flip, inflight.quantity
    inflight, ns.buyer = nil, nil
    ns.addVendor(f.itemKey.itemID, quantity)
    -- the main file has just recorded the purchase as a fill
    local fills = ns.db().fills
    if fills[#fills] and fills[#fills].kind == "bought" then
        fills[#fills].flip = true
    end
    if state.flip == f and (state.phase == "buying" or state.phase == "slow") then
        finish(("Bought %d %s for %s. Sell them to any vendor for %s."):format(
            quantity, nameOf(f.itemKey), money(state.total), money(state.vendor * quantity)))
    else
        render()
    end
end)

ns.listen("COMMODITY_PURCHASE_FAILED", function()
    if ns.buyer == "flips" and inflight and inflight.kind == "commodity" then
        ns.buyer, inflight = nil, nil
        if state.phase == "buying" or state.phase == "quoting" or state.phase == "slow" then
            state.phase = "failed"
        end
        render()
    end
end)

-- ---- gear: one auction per press ------------------------------------------------------------
--- The auction to buy next: under what a vendor pays for that very item, and covered by the gold,
--- the most a vendor pays over its buyout first.
local function pickAuction()
    local f = state.flip
    state.bought = state.bought or {}
    local best, under, unchecked, poor = nil, 0, 0, false
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(f.itemKey) or 0 do
        local a = C_AuctionHouse.GetItemSearchResultInfo(f.itemKey, i)
        if a and a.buyoutAmount and not a.containsOwnerItem and not state.bought[a.auctionID] then
            local each = a.itemLink and select(11, C_Item.GetItemInfo(a.itemLink))
            local quantity = a.quantity or 1
            if each == nil then
                unchecked = unchecked + 1
            elseif a.buyoutAmount < each * quantity then
                under = under + 1
                local gain = each * quantity - a.buyoutAmount
                if a.buyoutAmount > GetMoney() then
                    poor = true
                elseif not best or gain > best.gain then
                    best = { auctionID = a.auctionID, buyout = a.buyoutAmount, quantity = quantity, vendor = each * quantity, gain = gain }
                end
            end
        end
    end
    if best then
        state.auction, state.more, state.phase = best, under - 1, "auction"
    elseif poor then
        state.phase = "poor"
    elseif unchecked > 0 then
        state.phase = "checking"
    else
        finish(state.boughtCount and ("Bought %s of %s; it comes by mail. Collect it, then sell it to any vendor."):format(
            plural(state.boughtCount, "auction"), nameOf(f.itemKey)) or ("%s was gone: someone bought it first."):format(nameOf(f.itemKey)))
        return
    end
    render()
end

ns.listen("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local f = state.flip
    if f and state.phase == "searching" and keyOf(itemKey) == f.key then
        state.wait = nil
        pickAuction()
    end
end)

ns.listen("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    if ns.buyer ~= "flips" or not inflight or inflight.kind ~= "auction" or inflight.auction.auctionID ~= auctionID then
        return
    end
    local f, a = inflight.flip, inflight.auction
    inflight, ns.buyer = nil, nil
    ns.addVendor(f.itemKey.itemID, a.quantity)
    local fills = ns.db().fills
    local fill = fills[#fills]
    if fill and fill.kind == "bought" and fill.auction == auctionID then
        fill.item, fill.quantity, fill.total, fill.flip = f.itemKey.itemID, a.quantity, a.buyout, true
    end
    if state.flip == f then
        state.bought = state.bought or {}
        state.bought[auctionID] = true
        state.boughtCount = (state.boughtCount or 0) + 1
        if state.phase == "buying" then
            state.wait = nil
            pickAuction() -- the next one under vendor price, from the same listings
            return
        end
    end
    render()
end)

ns.listen("AUCTION_HOUSE_SHOW_ERROR", function()
    if ns.buyer == "flips" and inflight and inflight.kind == "auction" then
        ns.buyer, inflight = nil, nil
        if state.phase == "buying" or state.phase == "slow" then
            state.phase = "failed"
        end
        render()
    end
end)

-- ---- the panel ------------------------------------------------------------------------------
local function build()
    local house = _G.AuctionHouseFrame
    panel = CreateFrame("Frame", "ForeverMarketsFlipsPanel", house or UIParent, "BackdropTemplate")
    panel:SetSize(300, 230)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    panel:SetBackdropColor(0, 0, 0, 0.85)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Vendor flips")
    status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", 12, -30)
    status:SetPoint("RIGHT", -12, 0)
    status:SetJustifyH("LEFT")
    for i = 1, SHOWN do
        lines[i] = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lines[i]:SetPoint("TOPLEFT", 12, -90 - (i - 1) * 16)
        lines[i]:SetPoint("RIGHT", -12, 0)
        lines[i]:SetJustifyH("LEFT")
    end
    button = CreateFrame("Button", "ForeverMarketsFlipsButton", panel, "UIPanelButtonTemplate")
    button:SetSize(170, 24)
    button:SetPoint("BOTTOMLEFT", 12, 10)
    button:SetScript("OnClick", function()
        ForeverMarkets_Flip()
    end)
    skip = CreateFrame("Button", "ForeverMarketsFlipsSkip", panel, "UIPanelButtonTemplate")
    skip:SetSize(50, 24)
    skip:SetPoint("BOTTOMRIGHT", -62, 10)
    skip:SetText("Skip")
    skip:SetScript("OnClick", function()
        if state.phase == "quoting" or state.phase == "confirm" then
            C_AuctionHouse.CancelCommoditiesPurchase()
            ns.buyer, inflight = nil, nil
        end
        if state.flip then
            finish(nil)
        else
            local best = ranked()[1]
            if best then
                done[best.key] = true
            end
            render()
        end
    end)
    rescan = CreateFrame("Button", "ForeverMarketsFlipsRescan", panel, "UIPanelButtonTemplate")
    rescan:SetSize(50, 24)
    rescan:SetPoint("BOTTOMRIGHT", -12, 10)
    rescan:SetText("Scan")
    rescan:SetScript("OnClick", function()
        if state.phase == "quoting" or state.phase == "confirm" then
            C_AuctionHouse.CancelCommoditiesPurchase()
            ns.buyer, inflight = nil, nil
        end
        startScan()
        render()
    end)
end

ns.listen("AUCTION_HOUSE_SHOW", function()
    if not panel then
        build()
    end
    -- beside the auction house, under the plan's panel when it's open
    local plan = _G.ForeverMarketsPlanPanel
    panel:ClearAllPoints()
    if plan and plan:IsShown() then
        panel:SetPoint("TOPLEFT", plan, "BOTTOMLEFT", 0, -8)
    elseif _G.AuctionHouseFrame then
        panel:SetPoint("TOPLEFT", _G.AuctionHouseFrame, "TOPRIGHT", 8, 0)
    else
        panel:SetPoint("CENTER")
    end
    state = {}
    panel:Show()
    render()
end)

ns.listen("AUCTION_HOUSE_CLOSED", function()
    if panel then
        panel:Hide()
    end
    -- the game drops a purchase in progress, and stops loading the list, when the house closes
    if ns.buyer == "flips" then
        ns.buyer, inflight = nil, nil
    end
    state = {}
    if scan.loading then
        scan.loading, scan.at = false, ns.now()
    end
end)
