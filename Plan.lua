-- ForeverMarkets plan: carries out the web app's plan at the auction house.
--
-- The web app sends a character's plan to our server, which publishes the plans of all the
-- player's characters through Courier as a personal publication. The Courier app writes it into
-- the data addon ForeverMarkets_Data, which the game loads at login and /reload:
--   ForeverMarkets_Data.personal = { version, published_at, data = { version, written, plans } }
-- with data.plans[guid] = { written = <time>, gold, steps = { ... } }, one plan per character.
-- A step is { kind = "buy", item, name, units, maxPrice, sellAt, depositPerUnit, vendor? } or
-- { kind = "sell", item, name, units, price }; prices are copper per unit. Courier also writes
-- .broadcast (published to every player; nothing yet) and .status (whether the player shares).
--
-- Nothing here acts on its own. Every search, purchase, confirmation and listing happens inside
-- the player's own click on the panel's button or press of the "Do the next plan step" key, one
-- action per press, as Blizzard's rules require: a commodity buy is three presses (find, buy,
-- confirm at the price the game quotes) and is refused if that price is over the plan's limit.
-- A listing shows its deposit first (kept by the auction house if nothing sells) and is refused
-- when the character can't pay it; each one is recorded with its deposit and the item's vendor
-- price, so the app learns what deposits really cost.
--
-- The app plans with the gold it last saw, which is a /reload old. Each buy is sized again here,
-- at the moment it's made, to the gold the character has: never more than it can pay for, keeping
-- back the deposit for listing what it buys (the step's depositPerUnit).
--
-- A buy with a `vendor` price is a vendor flip: listings under what a vendor pays for the item,
-- bought to sell to any vendor. Its limit is also held under the vendor price the game itself
-- gives for the item, so a stale plan can't buy at a loss. What it buys is kept in the
-- character's `vendor` counts, and a panel beside any vendor sells it one stack per press; nothing
-- else in the bags is ever sold.

local _, ns = ...
ns = ns or {}

local DURATION = 2 -- 24 hours: the plan expects the market to buy within a day
-- Seconds to wait for the auction house to answer a search or a price before offering to look
-- again: it drops requests that come too fast, and a button greyed out for good looks broken.
local WAIT = 5

local panel, title, text, button, skip
local state = {} -- the current step's progress at this auction house visit

BINDING_HEADER_FOREVERMARKETS = "ForeverMarkets"
BINDING_NAME_FOREVERMARKETS_NEXT = "Do the next plan step"

local function money(copper)
    return GetMoneyString(math.floor((copper or 0) + 0.5), true)
end

--- Every character's plan, from Courier's personal publication, or nil.
function ns.plans()
    local data = ForeverMarkets_Data
    local personal = type(data) == "table" and data.personal
    local published = type(personal) == "table" and personal.data
    if type(published) == "table" and type(published.plans) == "table" then
        return published.plans
    end
end

--- This character's plan from the app, or nil.
function ns.plan()
    local plans, guid = ns.plans(), ns.guid and ns.guid()
    return plans and guid and plans[guid] or nil
end

--- True when ForeverMarkets_Data is the folder the retired desktop app wrote ({ plans = ... },
--- nothing of Courier's). Courier never writes into a folder it didn't make, so while it is there
--- no plan can arrive: the player has to delete it.
function ns.staleDataAddon()
    local data = ForeverMarkets_Data
    return type(data) == "table" and data.plans ~= nil and data.personal == nil and data.status == nil
end

-- Which steps are done and how much each buy has bought, kept per character in SavedVariables
-- until the app writes a new plan (so a /reload mid-plan picks up where it left off).
local function progress()
    local db, plan = ns.db and ns.db(), ns.plan()
    if not db or not plan then
        return nil
    end
    db.progress = db.progress or {}
    local guid = ns.guid()
    local p = db.progress[guid]
    if not p or p.written ~= plan.written then
        p = { written = plan.written, done = {}, bought = {} }
        db.progress[guid] = p
    end
    return p
end

local function nextStep()
    local plan, p = ns.plan(), progress()
    if not plan or not p then
        return nil
    end
    for i, step in ipairs(plan.steps or {}) do
        if not p.done[i] then
            return i, step, p
        end
    end
end

local function name(step)
    return step.name or ("item " .. step.item)
end

--- What a vendor pays for one of the item, as the game says; nil until the client knows the item.
local function vendorPrice(item)
    return select(11, C_Item.GetItemInfo(item))
end

--- The most a buy pays per unit: the plan's limit, and for a flip a copper under what the game's
--- vendor pays. Nil for a flip until the game says what that is: the archive's vendor prices come
--- from Blizzard's API, which has been wrong for Forever's gear, so a flip never buys on them alone.
local function limitOf(step)
    if not step.vendor then
        return step.maxPrice
    end
    local vendor = vendorPrice(step.item)
    return vendor and math.min(step.maxPrice, vendor - 1) or nil
end

--- This character's record in the saved data, where its flips' counts are kept.
local function character()
    local db = ns.db and ns.db()
    return db and db.characters and db.characters[ns.guid()]
end

--- Count units bought to sell to a vendor: the vendor panel sells only these.
local function addVendor(item, units)
    local c = character()
    if c then
        c.vendor = c.vendor or {}
        c.vendor[item] = (c.vendor[item] or 0) + units
    end
end

-- What Flips.lua shares. `ns.buyer` says whose commodity purchase is in progress ("plan" or
-- "flips"), since both panels listen to the same purchase events.
ns.money, ns.vendorPrice, ns.addVendor = money, vendorPrice, addVendor

local function inBags(item)
    local count, first = 0, nil
    for _, bag in ipairs(ns.containers(false)) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == item then
                count = count + (info.stackCount or 1)
                first = first or { bag = bag, slot = slot }
            end
        end
    end
    return count, first
end

local function say(message, action, waitingFor)
    text:SetText(message)
    if action then
        button:SetText(action)
        button:Enable()
    else
        button:SetText(waitingFor or "Waiting for the auction house…")
        button:Disable()
    end
end

--- Run `fn` in `seconds`, its errors reported like any handler's.
local function after(seconds, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(seconds, function()
            local ok, err = pcall(fn)
            if not ok then
                geterrorhandler()(err)
            end
        end)
    end
end
ns.after = after

local waits = 0
local render -- below

--- Wait for the auction house to answer `phase`; if it hasn't in time, offer to look again.
local function waitFor(phase)
    waits = waits + 1
    local id = waits
    state.wait = id
    after(WAIT, function()
        if state.wait ~= id or state.phase ~= phase then
            return
        end
        if phase == "quoting" then
            C_AuctionHouse.CancelCommoditiesPurchase()
            ns.buyer = nil
        end
        state.phase = "slow"
        render()
    end)
end

render = function()
    if not panel or not panel:IsShown() then
        return
    end
    local i, step, p = nextStep()
    if not i then
        title:SetText("Plan done")
        local c = character()
        say(c and c.vendor and next(c.vendor)
            and "Every step is done. Sell what you bought for vendors at any vendor, then /reload for your next plan."
            or "Every step is done. Type /reload, then make your next plan on the website and send it to the game.", nil)
        skip:Hide()
        return
    end
    skip:Show()
    title:SetText(("Step %d of %d"):format(i, #ns.plan().steps))
    if state.step ~= i then
        state = { step = i, phase = step.kind == "buy" and "find" or "list" }
    end
    local phase = state.phase
    if step.kind == "buy" then
        local left = step.units - (p.bought[i] or 0)
        if phase == "find" then
            if step.vendor then
                say(("Buy up to %d %s under %s each, to sell to a vendor. You have %s."):format(left, name(step), money(step.vendor), money(GetMoney())), "Find " .. name(step))
            else
                say(("Buy up to %d %s at %s or less. You have %s."):format(left, name(step), money(step.maxPrice), money(GetMoney())), "Find " .. name(step))
            end
        elseif phase == "searching" then
            say(("Looking for %s…"):format(name(step)), nil, "Looking…")
        elseif phase == "slow" then
            say("The auction house hasn't answered, so nothing was bought. It may be busy; look again.", "Look again")
        elseif phase == "checking" then
            say(("The game hasn't said yet what a vendor pays for %s, so nothing is bought. Look again in a moment."):format(name(step)), "Look again")
        elseif phase == "found" then
            local note = state.quantity < math.min(left, state.available)
                and (" Your %s covers %d of them, with their deposit."):format(money(GetMoney()), state.quantity) or ""
            local sold = step.vendor and (" A vendor pays %s each."):format(money(vendorPrice(step.item) or step.vendor)) or ""
            say(("%d for sale at %s or less.%s%s Buy %d?"):format(state.available, money(state.limit), sold, note, state.quantity), ("Buy %d"):format(state.quantity))
        elseif phase == "poor" then
            say(("%d for sale at %s or less, but your %s doesn't cover even one with its deposit. Collect your mail or skip this step."):format(
                state.available, money(state.limit), money(GetMoney())), "Look again")
        elseif phase == "none" then
            say(("None for sale at %s or less right now%s. Skip it, or look again later."):format(
                money(state.limit or step.maxPrice), state.cheapest and (" (cheapest " .. money(state.cheapest) .. ")") or ""), "Look again")
        elseif phase == "quoting" then
            say("Asking the auction house for its price…", nil, "Asking for the price…")
        elseif phase == "confirm" then
            say(("Buy %d %s for %s (%s each)?"):format(state.quantity, name(step), money(state.total), money(state.unitPrice)), "Confirm")
        elseif phase == "buying" then
            say("Buying…", nil, "Buying…")
        elseif phase == "refused" then
            say(("The auction house asked %s each, over your %s limit, so nothing was bought."):format(money(state.unitPrice), money(state.limit)), "Look again")
        elseif phase == "failed" then
            say("That purchase didn't go through; nothing was bought.", "Look again")
        end
    else
        if phase == "list" then
            local have = inBags(step.item)
            state.quantity = math.min(step.units, have)
            state.deposit = state.quantity > 0 and C_AuctionHouse.CalculateCommodityDeposit(step.item, DURATION, state.quantity) or nil
            if state.quantity == 0 then
                say(("No %s in your bags to list. Skip this step."):format(name(step)), nil)
            elseif state.deposit and state.deposit > GetMoney() then
                say(("Listing %d %s needs a %s deposit, more than you have. Skip this step."):format(state.quantity, name(step), money(state.deposit)), nil)
            else
                say(("List %d %s at %s each, for 24 hours.%s"):format(state.quantity, name(step), money(step.price),
                    state.deposit and (" Deposit " .. money(state.deposit) .. ", back when they sell.") or ""), ("List %d"):format(state.quantity))
            end
        elseif phase == "posting" then
            say("Listing…", nil, "Listing…")
        elseif phase == "confirmPost" then
            say(("The auction house asks you to confirm listing at %s each."):format(money(step.price)), "Confirm")
        end
    end
end

-- ---- the mailbox -------------------------------------------------------------
-- A sale's gold, and a listing that didn't sell, come back by mail. A panel beside the mailbox
-- says what the auction house sent and collects one of its mails per press; mail from anyone
-- else is never touched.
local mailPanel, mailText, mailButton
local collecting -- the mail being collected, until the inbox shows it gone

local function auctionMails()
    local out = {}
    for index = 1, (GetInboxNumItems()) or 0 do
        local mail = ns.auctionMail(index)
        if mail then
            out[#out + 1] = { index = index, mail = mail }
        end
    end
    return out
end

local WHAT = { sold = "sale", won = "won auction", expired = "unsold listing", cancelled = "cancelled listing" }

local function renderMail()
    if not mailPanel or not mailPanel:IsShown() then
        return
    end
    local mails = auctionMails()
    if #mails == 0 then
        mailText:SetText("Nothing from the auction house is waiting.")
        mailButton:SetText("All collected")
        mailButton:Disable()
        return
    end
    local sales, gold, back, won = 0, 0, 0, 0
    for _, m in ipairs(mails) do
        if m.mail.kind == "sold" then
            sales, gold = sales + 1, gold + m.mail.money
        elseif m.mail.kind == "won" then
            won = won + 1
        else
            back = back + 1
        end
    end
    local parts = {}
    if sales > 0 then parts[#parts + 1] = ("%d sale%s worth %s"):format(sales, sales == 1 and "" or "s", money(gold)) end
    if won > 0 then parts[#parts + 1] = ("%d won auction%s"):format(won, won == 1 and "" or "s") end
    if back > 0 then parts[#parts + 1] = ("%d listing%s that didn't sell, coming back to your bags"):format(back, back == 1 and "" or "s") end
    mailText:SetText("From the auction house: " .. table.concat(parts, ", ") .. ".")
    mailButton:SetText("Collect " .. WHAT[mails[1].mail.kind])
    if collecting then
        mailButton:Disable()
    else
        mailButton:Enable()
    end
end

local function collectMail()
    if collecting or not mailButton:IsEnabled() then
        return
    end
    local mails = auctionMails()
    if #mails == 0 then
        return
    end
    collecting = { before = #mails, mail = mails[1].mail }
    AutoLootMailItem(mails[1].index)
    renderMail()
end

local function buildMail()
    local frame = _G.MailFrame
    mailPanel = CreateFrame("Frame", "ForeverMarketsMailPanel", frame or UIParent, "BackdropTemplate")
    mailPanel:SetSize(300, 110)
    if frame then
        mailPanel:SetPoint("TOPLEFT", frame, "TOPRIGHT", 8, 0)
    else
        mailPanel:SetPoint("CENTER")
    end
    mailPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    mailPanel:SetBackdropColor(0, 0, 0, 0.85)
    local heading = mailPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", 12, -10)
    heading:SetText("Your auction house mail")
    mailText = mailPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mailText:SetPoint("TOPLEFT", 12, -30)
    mailText:SetPoint("RIGHT", -12, 0)
    mailText:SetJustifyH("LEFT")
    mailButton = CreateFrame("Button", "ForeverMarketsMailButton", mailPanel, "UIPanelButtonTemplate")
    mailButton:SetSize(200, 24)
    mailButton:SetPoint("BOTTOMLEFT", 12, 10)
    mailButton:SetScript("OnClick", collectMail)
end

ns.listen("MAIL_SHOW", function()
    if not mailPanel then
        buildMail()
    end
    collecting = nil
    mailPanel:Show()
    renderMail()
end)

ns.listen("MAIL_INBOX_UPDATE", function()
    -- the main file has just re-read the inbox; a collected mail is recorded once it's gone
    if collecting and #auctionMails() < collecting.before then
        local m = collecting.mail
        ns.fill("collected", { what = m.kind, name = m.name, item = m.item, count = m.count, money = m.money, buyout = m.buyout, cut = m.cut, deposit = m.deposit })
        collecting = nil
    end
    renderMail()
end)

ns.listen("MAIL_CLOSED", function()
    if mailPanel then
        mailPanel:Hide()
    end
    collecting = nil
end)

-- ---- the vendor -------------------------------------------------------------
-- What a flip bought is sold at any vendor, one stack per press, and only up to the count the
-- flips bought: the player's own stock of the same item is never sold. A stack bigger than what's
-- left to sell (bought units stack onto the player's own) is split first, which is its own press.
local vendorPanel, vendorText, vendorButton
local selling -- the stack being sold, until the bags show it gone

local function toSell()
    local c = character()
    local out = {}
    for item, units in pairs(c and c.vendor or {}) do
        local have = inBags(item)
        if units > 0 and have > 0 then
            out[#out + 1] = { item = item, units = math.min(units, have), price = vendorPrice(item) }
        end
    end
    table.sort(out, function(a, b) return a.item < b.item end)
    return out
end

local function itemName(item)
    return C_Item.GetItemInfo(item) or ("item " .. item)
end

--- The stack to sell next for `want` units of an item: the biggest that isn't more than `want`,
--- else the smallest, to split.
local function stackFor(item, want)
    local fits, split
    for _, bag in ipairs(ns.containers(false)) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == item then
                local count = info.stackCount or 1
                if count <= want and (not fits or count > fits.count) then
                    fits = { bag = bag, slot = slot, count = count }
                elseif count > want and (not split or count < split.count) then
                    split = { bag = bag, slot = slot, count = count }
                end
            end
        end
    end
    return fits, split
end

local function freeSlot()
    for _, bag in ipairs(ns.containers(false)) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            if not C_Container.GetContainerItemInfo(bag, slot) then
                return bag, slot
            end
        end
    end
end

local function renderVendor()
    if not vendorPanel or not vendorPanel:IsShown() then
        return
    end
    local list = toSell()
    if #list == 0 then
        vendorText:SetText("Everything bought for vendors is sold.")
        vendorButton:SetText("All sold")
        vendorButton:Disable()
        return
    end
    local parts, total = {}, 0
    for _, s in ipairs(list) do
        parts[#parts + 1] = ("%d %s"):format(s.units, itemName(s.item))
        total = total + (s.price or 0) * s.units
    end
    local first = list[1]
    local fits = stackFor(first.item, first.units)
    vendorText:SetText(("Bought to sell to a vendor: %s, for %s."):format(table.concat(parts, ", "), money(total)))
    vendorButton:SetText(fits and ("Sell %d %s"):format(fits.count, itemName(first.item)) or ("Split off %d %s"):format(first.units, itemName(first.item)))
    if selling then
        vendorButton:Disable()
    else
        vendorButton:Enable()
    end
end

local function sellNext()
    if selling or not vendorButton:IsEnabled() then
        return
    end
    local first = toSell()[1]
    if not first then
        return
    end
    local fits, split = stackFor(first.item, first.units)
    if fits then
        selling = { item = first.item, units = fits.count, bag = fits.bag, slot = fits.slot, price = first.price }
        C_Container.UseContainerItem(fits.bag, fits.slot)
    elseif split then
        local bag, slot = freeSlot()
        if not bag then
            vendorText:SetText(("Make room in your bags for one more stack, to split off the %d %s bought for vendors."):format(first.units, itemName(first.item)))
            return
        end
        C_Container.SplitContainerItem(split.bag, split.slot, first.units)
        C_Container.PickupContainerItem(bag, slot)
    end
    renderVendor()
end

ns.listen("BAG_UPDATE_DELAYED", function()
    -- a stack is sold once its slot no longer holds it
    if selling then
        local info = C_Container.GetContainerItemInfo(selling.bag, selling.slot)
        if not info or info.itemID ~= selling.item then
            local c = character()
            local left = (c.vendor[selling.item] or 0) - selling.units
            c.vendor[selling.item] = left > 0 and left or nil
            ns.fill("vendored", { item = selling.item, units = selling.units, money = (selling.price or 0) * selling.units })
            selling = nil
        end
    end
    renderVendor()
end)

local function buildVendor()
    local frame = _G.MerchantFrame
    vendorPanel = CreateFrame("Frame", "ForeverMarketsVendorPanel", frame or UIParent, "BackdropTemplate")
    vendorPanel:SetSize(300, 110)
    if frame then
        vendorPanel:SetPoint("TOPLEFT", frame, "TOPRIGHT", 8, 0)
    else
        vendorPanel:SetPoint("CENTER")
    end
    vendorPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    vendorPanel:SetBackdropColor(0, 0, 0, 0.85)
    local heading = vendorPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", 12, -10)
    heading:SetText("Your vendor flips")
    vendorText = vendorPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    vendorText:SetPoint("TOPLEFT", 12, -30)
    vendorText:SetPoint("RIGHT", -12, 0)
    vendorText:SetJustifyH("LEFT")
    vendorButton = CreateFrame("Button", "ForeverMarketsVendorButton", vendorPanel, "UIPanelButtonTemplate")
    vendorButton:SetSize(220, 24)
    vendorButton:SetPoint("BOTTOMLEFT", 12, 10)
    vendorButton:SetScript("OnClick", sellNext)
end

ns.listen("MERCHANT_SHOW", function()
    selling = nil
    if #toSell() == 0 then
        return
    end
    if not vendorPanel then
        buildVendor()
    end
    vendorPanel:Show()
    renderVendor()
end)

ns.listen("MERCHANT_CLOSED", function()
    if vendorPanel then
        vendorPanel:Hide()
    end
    selling = nil
end)

--- One action: the next plan step at the auction house (or, with no step left, the next vendor
--- flip), the next mail at the mailbox, or the next stack at a vendor. Runs only inside a click or
--- key press: a panel's button, or the "Do the next plan step" binding.
function ForeverMarkets_Next()
    if mailPanel and mailPanel:IsShown() then
        collectMail()
        return
    end
    if vendorPanel and vendorPanel:IsShown() then
        sellNext()
        return
    end
    local i, step = nextStep()
    if not i or not panel or not panel:IsShown() then
        if ns.flipNext then
            ns.flipNext()
        end
        return
    end
    if not button:IsEnabled() then
        return
    end
    local phase = state.phase
    if step.kind == "buy" then
        if phase == "find" or phase == "none" or phase == "refused" or phase == "failed" or phase == "poor" or phase == "checking" or phase == "slow" then
            state.phase = "searching"
            waitFor("searching")
            C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(step.item), {}, false)
        elseif phase == "found" then
            state.phase = "quoting"
            ns.buyer = "plan"
            waitFor("quoting")
            C_AuctionHouse.StartCommoditiesPurchase(step.item, state.quantity)
        elseif phase == "confirm" then
            state.phase = "buying"
            C_AuctionHouse.ConfirmCommoditiesPurchase(step.item, state.quantity)
        end
    elseif phase == "list" then
        local _, slot = inBags(step.item)
        if slot then
            state.location = ItemLocation:CreateFromBagAndSlot(slot.bag, slot.slot)
            state.phase = "posting"
            if C_AuctionHouse.PostCommodity(state.location, DURATION, state.quantity, step.price) then
                state.phase = "confirmPost"
            end
        end
    elseif phase == "confirmPost" then
        state.phase = "posting"
        C_AuctionHouse.ConfirmPostCommodity(state.location, DURATION, state.quantity, step.price)
    end
    render()
end

local function build()
    local house = _G.AuctionHouseFrame
    panel = CreateFrame("Frame", "ForeverMarketsPlanPanel", house or UIParent, "BackdropTemplate")
    panel:SetSize(300, 140)
    if house then
        panel:SetPoint("TOPLEFT", house, "TOPRIGHT", 8, 0)
    else
        panel:SetPoint("CENTER")
    end
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    panel:SetBackdropColor(0, 0, 0, 0.85)
    title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", 12, -30)
    text:SetPoint("RIGHT", -12, 0)
    text:SetJustifyH("LEFT")
    button = CreateFrame("Button", "ForeverMarketsPlanButton", panel, "UIPanelButtonTemplate")
    button:SetSize(170, 24)
    button:SetPoint("BOTTOMLEFT", 12, 10)
    button:SetScript("OnClick", function()
        ForeverMarkets_Next()
    end)
    skip = CreateFrame("Button", "ForeverMarketsPlanSkip", panel, "UIPanelButtonTemplate")
    skip:SetSize(70, 24)
    skip:SetPoint("BOTTOMRIGHT", -12, 10)
    skip:SetText("Skip")
    skip:SetScript("OnClick", function()
        local i, _, p = nextStep()
        if i then
            p.done[i] = true
            state = {}
        end
        render()
    end)
end

local function current(kind)
    local i, step, p = nextStep()
    if i and step.kind == kind then
        return i, step, p
    end
end

ns.listen("AUCTION_HOUSE_SHOW", function()
    if not ns.plan() then
        return
    end
    if not panel then
        build()
    end
    state = {}
    panel:Show()
    render()
end)

ns.listen("AUCTION_HOUSE_CLOSED", function()
    if panel then
        panel:Hide()
    end
    state = {} -- the game drops a purchase in progress when the auction house closes
end)

ns.listen("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    local i, step, p = current("buy")
    if not i or state.phase ~= "searching" or itemID ~= step.item then
        return
    end
    local limit = limitOf(step)
    if not limit then
        state.phase = "checking"
        render()
        return
    end
    local rows, available, cheapest = {}, 0, nil
    for n = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0 do
        local row = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, n)
        if row then
            cheapest = cheapest and math.min(cheapest, row.unitPrice) or row.unitPrice
            if row.unitPrice <= limit then
                available = available + row.quantity
                rows[#rows + 1] = row
            end
        end
    end
    state.available, state.cheapest, state.limit = available, cheapest, limit
    -- what the gold on hand pays for right now, cheapest first, each unit with its listing deposit
    table.sort(rows, function(a, b) return a.unitPrice < b.unitPrice end)
    local gold, affordable = GetMoney(), 0
    for _, row in ipairs(rows) do
        local each = row.unitPrice + (step.depositPerUnit or 0)
        local take = math.min(row.quantity, math.floor(gold / each))
        affordable, gold = affordable + take, gold - take * each
        if take < row.quantity then
            break
        end
    end
    state.quantity = math.min(step.units - (p.bought[i] or 0), available, affordable)
    if state.quantity > 0 then
        state.phase = "found"
    else
        state.phase = available > 0 and "poor" or "none"
    end
    render()
end)

ns.listen("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
    local _, step = current("buy")
    if not step or state.phase ~= "quoting" or ns.buyer ~= "plan" then
        return
    end
    state.unitPrice, state.total = unitPrice, totalPrice
    local limit = limitOf(step)
    if limit and unitPrice <= math.min(limit, state.limit or limit) then
        state.phase = "confirm"
    else
        C_AuctionHouse.CancelCommoditiesPurchase()
        state.phase = "refused"
    end
    render()
end)

ns.listen("COMMODITY_PURCHASE_SUCCEEDED", function()
    local i, step, p = current("buy")
    if not i or state.phase ~= "buying" or ns.buyer ~= "plan" then
        return
    end
    p.bought[i] = (p.bought[i] or 0) + state.quantity
    if p.bought[i] >= step.units then
        p.done[i] = true
    end
    if step.vendor then
        addVendor(step.item, state.quantity)
    end
    ns.buyer = nil
    state = {}
    render()
end)

ns.listen("COMMODITY_PURCHASE_FAILED", function()
    if current("buy") and (state.phase == "buying" or state.phase == "quoting") and ns.buyer == "plan" then
        ns.buyer = nil
        state.phase = "failed"
        render()
    end
end)

ns.listen("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
    local i, step, p = current("sell")
    if not i or state.phase ~= "posting" then
        return
    end
    -- The main file has just recorded the listing as a fill: add what it was and what it cost.
    local db = ns.db()
    local fill = db.fills[#db.fills]
    local vendor = select(11, C_Item.GetItemInfo(step.item))
    if fill and fill.kind == "posted" and fill.auction == auctionID then
        fill.item, fill.units, fill.price, fill.deposit, fill.vendor, fill.duration = step.item, state.quantity, step.price, state.deposit, vendor, DURATION
    end
    if state.deposit and vendor then
        db.deposits = db.deposits or {}
        db.deposits[step.item] = { vendor = vendor, duration = DURATION, units = state.quantity, deposit = state.deposit, t = ns.now() }
    end
    p.done[i] = true
    state = {}
    render()
end)

ns.listen("BAG_UPDATE_DELAYED", render)
