--=========================================================================
-- AutoRoll :: Core.lua
-- Event handling, the delayed roll queue, and slash commands.
--=========================================================================

local A = AutoRoll
local ACT = A.ACTION

local f = CreateFrame("Frame", "AutoRollFrame", UIParent)
A.frame = f

--=========================================================================
-- Roll info
--
-- The return signature of GetLootRollItemInfo drifted between expansions and
-- custom cores patch it further. Rather than assume a fixed arity we grab
-- everything and treat anything past the fifth return as best-effort.
-- Run "/ar probe" while a roll is up to see exactly what your server sends.
--=========================================================================

local function GetRollInfo(rollID)
    local r = { GetLootRollItemInfo(rollID) }
    return {
        texture       = r[1],
        name          = r[2],
        count         = r[3],
        quality       = r[4],
        bindOnPickUp  = r[5],
        canNeed       = r[6],
        canGreed      = r[7],
        canDisenchant = r[8],
        raw           = r,
    }
end

--- Returns ctx, resolved.
--
--  `resolved` is false when GetItemInfo came back empty, which happens
--  routinely at the instant a roll starts if the item is not in the local
--  cache yet. Quality and bind type arrive from the server and are always
--  present, but item level, class and equip slot are not -- so deciding on an
--  unresolved context silently disables every gear rule and drops straight
--  through to the BoE greed. Callers must retry rather than use this.
local function BuildContext(rollID)
    local link = GetLootRollItemLink(rollID)
    if not link then return nil end

    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return nil end

    local info = GetRollInfo(rollID)
    local name, _, quality, iLevel, reqLevel, itemClass, itemSubClass,
          maxStack, equipSlot = GetItemInfo(link)

    local ctx = {
        rollID        = rollID,
        link          = link,
        itemID        = itemID,
        name          = info.name or name,
        quality       = info.quality or quality,
        iLevel        = iLevel,
        reqLevel      = reqLevel,
        itemClass     = itemClass,
        itemSubClass  = itemSubClass,
        maxStack      = maxStack,
        equipSlot     = equipSlot,
        resolved      = (itemClass ~= nil),
        bindOnPickUp  = info.bindOnPickUp,
        canNeed       = info.canNeed,
        canGreed      = info.canGreed,
        canDisenchant = info.canDisenchant,
    }

    return ctx, ctx.resolved
end

--=========================================================================
-- Executing a decision
--=========================================================================

--- Downgrade an action the server will not accept, rather than firing a roll
--  that gets silently dropped and leaves the frame sitting on your screen.
local function Reconcile(action, ctx)
    if action == ACT.NEED and ctx.canNeed == false then
        A:Debug("need not offered, downgrading to greed")
        action = ACT.GREED
    end
    if action == ACT.GREED and ctx.canGreed == false then
        A:Debug("greed not offered, downgrading to pass")
        action = ACT.PASS
    end
    if action == ACT.DISENCHANT then
        if not A.db.allowDisenchant or ctx.canDisenchant == false then
            A:Debug("disenchant unavailable, downgrading to greed")
            action = ACT.GREED
        end
    end
    return action
end

function A:Execute(ctx, action, ruleKey, reason)
    action = Reconcile(action, ctx)

    if action == ACT.NONE then
        A:Debug(("%s -> IGNORE (%s)"):format(ctx.link, tostring(reason)))
        A:AddHistory(ctx, action, ruleKey, reason)
        return
    end

    RollOnLoot(ctx.rollID, action)

    -- Rolling need or greed on a bind-on-pickup item raises a confirmation
    -- popup. Without this the roll never actually goes through.
    if action > ACT.PASS and ctx.bindOnPickUp and A.db.confirmBoP then
        ConfirmLootRoll(ctx.rollID, action)
    end

    A:AddHistory(ctx, action, ruleKey, reason)

    local line = ("%s%s|r %s |cff808080(%s)|r"):format(
        A.ACTION_COLOR[action], A.ACTION_NAME[action], ctx.link, tostring(reason))

    if A.db.announce then
        A:Print(line)
    else
        A:Debug(line)
    end
end

--=========================================================================
-- Delayed queue
--
-- Rolling the instant the event fires is both bot-obvious and occasionally
-- rejected by the server, so every decision waits out db.rollDelay first.
--=========================================================================

local queue = {}

local RETRY_INTERVAL = 0.3

local function Enqueue(rollID)
    queue[rollID] = { fireAt = GetTime() + (A.db.rollDelay or 1.5), tries = 0 }
end

local function Dequeue(rollID)
    queue[rollID] = nil
end

local elapsed = 0
f:SetScript("OnUpdate", function(self, delta)
    elapsed = elapsed + delta
    if elapsed < 0.1 then return end
    elapsed = 0

    local now = GetTime()
    for rollID, entry in pairs(queue) do
        if now >= entry.fireAt then

            -- The roll may have expired or been cancelled while we waited.
            local ok, timeLeft = pcall(GetLootRollTimeLeft, rollID)
            if not ok or not timeLeft or timeLeft <= 0 then
                queue[rollID] = nil
                A:Debug("roll " .. rollID .. " expired before we acted")
            else
                local ctx, resolved = BuildContext(rollID)

                if not ctx then
                    queue[rollID] = nil

                elseif not resolved and entry.tries < (A.db.itemInfoRetries or 12) then
                    -- Item is not in the local cache yet. Deciding now would
                    -- silently skip every gear rule, so wait. The GetItemInfo
                    -- call inside BuildContext is itself what asks the server
                    -- for the data, so simply retrying is the fix.
                    entry.tries  = entry.tries + 1
                    entry.fireAt = now + RETRY_INTERVAL
                    A:Debug(("waiting on item data for roll %d (try %d)")
                        :format(rollID, entry.tries))

                else
                    queue[rollID] = nil
                    if not resolved then
                        A:Debug("item data never arrived for roll " .. rollID ..
                                "; gear rules will be skipped")
                    end
                    local action, ruleKey, reason = A:Decide(ctx)
                    if action ~= nil then
                        A:Execute(ctx, action, ruleKey, reason)
                    end
                end
            end
        end
    end
end)

--=========================================================================
-- Events
--=========================================================================

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("CANCEL_LOOT_ROLL")

--- Initialise exactly once.
--
--  Deliberately NOT keyed to arg1 == "AutoRoll". The ADDON_LOADED payload is
--  the *folder* name, so unzipping into "AutoRoll-master" or renaming the
--  folder at all means that comparison never matches, the database never
--  initialises, and every slash command then errors on a nil A.db. PLAYER_LOGIN
--  is a hard backstop: it always fires, whatever the folder is called.
local initialised = false
local function Initialise()
    if initialised then return end
    initialised = true

    A:InitDB()

    -- A broken options panel must not take the rest of the addon down with it.
    if A.BuildOptions then
        local ok, err = pcall(A.BuildOptions, A)
        if not ok then
            A:Print("|cffff4444options panel failed to build:|r " .. tostring(err))
            A:Print("rolling still works; use the slash commands.")
        end
    end

    A:Print(("v%s loaded. Profile: |cffffffff%s|r. /ar for options.")
        :format(A.version, A.profileName))
end

-- Raw GetLootRollItemInfo returns from the most recent roll, kept so /ar probe
-- is useful *after* the roll window closes instead of only during it.
A.lastProbe = nil
A.activeRolls = {}

f:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == A.addonName then Initialise() end
        return
    end

    if event == "PLAYER_LOGIN" then
        Initialise()
        return
    end

    if event == "CANCEL_LOOT_ROLL" then
        A.activeRolls[arg1] = nil
        Dequeue(arg1)
        return
    end

    if event == "START_LOOT_ROLL" then
        local rollID = arg1
        A.activeRolls[rollID] = true

        -- Capture before any enabled/instance filtering, so probing works even
        -- with the addon switched off. This is the diagnostic path.
        A.lastProbe = {
            rollID = rollID,
            link   = GetLootRollItemLink(rollID),
            raw    = { GetLootRollItemInfo(rollID) },
            n      = select("#", GetLootRollItemInfo(rollID)),
            when   = time(),
        }

        if not A.db or not A.db.enabled then return end

        if A.db.onlyInInstance then
            local inInstance = IsInInstance()
            if not inInstance then
                A:Debug("skipping roll: not in an instance")
                return
            end
        end

        if not GetLootRollItemLink(rollID) then
            A:Debug("roll " .. tostring(rollID) .. " has no item link yet")
            return
        end

        Enqueue(rollID)
    end
end)

--=========================================================================
-- Dry run
--
-- Deliberately reuses A:Decide, so the preview can never drift out of sync
-- with what actually happens on a real roll.
--=========================================================================

--- Like TestItem, but shows every rule's verdict instead of only the winner.
--  This is the tool for "why did it greed that?"
function A:TraceItem(input)
    local itemID = A:ResolveItemID(input)
    if not itemID then
        A:Print("could not resolve an item from: " .. tostring(input))
        return
    end

    local name, link, quality, iLevel, reqLevel, itemClass, itemSubClass,
          maxStack, equipSlot = GetItemInfo(itemID)
    if not name then
        A:Print("item " .. itemID .. " is not cached yet. Link it in chat once, then retry.")
        return
    end

    if type(input) == "string" and input:find("|H") then link = input end

    local ctx = {
        link = link, itemID = itemID, name = name, quality = quality,
        iLevel = iLevel, reqLevel = reqLevel, itemClass = itemClass,
        itemSubClass = itemSubClass, maxStack = maxStack, equipSlot = equipSlot,
        resolved = true, bindOnPickUp = A:GetBindOnPickup(link), isTest = true,
    }

    A:Print("---- trace " .. link .. " ----")
    A:Print(("  class=%s sub=%s ilvl=%s slot=%s quality=%s bop=%s")
        :format(tostring(itemClass), tostring(itemSubClass), tostring(iLevel),
                tostring(equipSlot), tostring(quality), tostring(ctx.bindOnPickUp)))

    local unusable, why = A:IsUnusable(link)
    A:Print(("  usable=%s%s"):format(
        unusable and "|cffff4444no|r" or "|cff1eff00yes|r",
        unusable and ("  red line: " .. tostring(why)) or ""))

    local typeSet, needSet, report
    if itemClass == A.LC.ARMOR and itemSubClass and A.ARMOR_TYPES[itemSubClass] then
        typeSet, needSet, report = "armor", A:GetArmorNeedSet(), A:ArmorSetString()
    elseif itemClass == A.LC.WEAPON and itemSubClass and A.WEAPON_TYPES[itemSubClass] then
        typeSet, needSet, report = "weapon", A:GetWeaponNeedSet(), A:WeaponSetString()
    end
    if typeSet then
        local ticked = needSet[itemSubClass]
        A:Print(("  %s type=%s  ticked: %s")
            :format(typeSet,
                    ticked and ("|cff1eff00" .. itemSubClass .. "|r")
                            or ("|cffff4444" .. itemSubClass .. "|r"),
                    report))
    end

    local delta, equipped = A:GetUpgradeDelta(link)
    if delta then
        A:Print(("  ilvl %d vs equipped %d (%+d)  |cff808080informational only|r")
            :format(iLevel or 0, equipped or 0, delta))
    end

    local trace = {}
    local action, ruleKey = A:Decide(ctx, trace)

    for _, t in ipairs(trace) do
        local mark
        if t.status == "match" then
            mark = ("%s=> %s|r  %s"):format(A.ACTION_COLOR[t.action],
                A.ACTION_NAME[t.action], tostring(t.reason))
        elseif t.status == "off" then
            mark = "|cff808080disabled|r"
        elseif t.status == "error" then
            mark = "|cffff4444error:|r " .. tostring(t.reason)
        else
            mark = "|cff808080no|r"
        end
        A:Print(("  [%3d] %-16s %s"):format(t.priority, t.key, mark))
    end

    if action == nil then
        A:Print("  |cffff4444no rule matched and no fallback|r")
    end
    A:Print("--------")
end

--- Dry run: one line, same code path a real roll takes.
function A:TestItem(input)
    local itemID = A:ResolveItemID(input)
    if not itemID then
        A:Print("could not resolve an item from: " .. tostring(input))
        return
    end

    local name, link, quality, iLevel, reqLevel, itemClass, itemSubClass,
          maxStack, equipSlot = GetItemInfo(itemID)
    if not name then
        A:Print("item " .. itemID .. " is not in your client cache yet. Link it in chat once, then retry.")
        return
    end

    -- If the caller handed us a real link, keep it: it carries enchant,
    -- gem and any custom suffix data that a bare item ID throws away.
    if type(input) == "string" and input:find("|H") then
        link = input:match("|H.-|h.-|h") and input or link
    end

    local ctx = {
        rollID       = nil,
        link         = link,
        itemID       = itemID,
        name         = name,
        quality      = quality,
        iLevel       = iLevel,
        reqLevel     = reqLevel,
        itemClass    = itemClass,
        itemSubClass = itemSubClass,
        maxStack     = maxStack,
        equipSlot    = equipSlot,
        bindOnPickUp = A:GetBindOnPickup(link),
        canNeed      = nil,
        canGreed     = nil,
        canDisenchant= nil,
        isTest       = true,
    }

    local action, ruleKey, reason = A:Decide(ctx)
    if action == nil then
        A:Print(link .. " => no decision (all rules disabled?)")
        return
    end

    A:Print(("%s => %s%s|r via |cffffffff%s|r (%s)"):format(
        link, A.ACTION_COLOR[action], A.ACTION_NAME[action],
        tostring(ruleKey), tostring(reason)))
end

--- Field names as they appear on a Blizzlike 3.3.5a core. If your server
--  returns something different at one of these positions, that is exactly
--  what we need to know.
local PROBE_LABELS = {
    "texture", "name", "count", "quality", "bindOnPickUp",
    "canNeed", "canGreed", "canDisenchant",
    "(9?)", "(10?)", "(11?)", "(12?)",
}

local function DumpRoll(label, rollID, raw, count, link)
    A:Print(("|cffffff00%s|r rollID=%s  %s"):format(label, tostring(rollID), tostring(link)))
    A:Print(("  returns %d values"):format(count or 0))
    for i = 1, math.max(count or 0, 12) do
        local v = raw[i]
        if v ~= nil or i <= (count or 0) then
            A:Print(("  [%2d] %-14s = %s |cff808080(%s)|r")
                :format(i, PROBE_LABELS[i] or "?", tostring(v), type(v)))
        end
    end
end

--- Works three ways, in order of preference: any roll currently on screen,
--  otherwise the last roll we saw this session, otherwise just the API report.
function A:Probe()
    A:Print("---- probe ----")
    A:Print(("addon initialised: %s   database: %s")
        :format(initialised and "|cff1eff00yes|r" or "|cffff4444NO|r",
                A.db and "|cff1eff00ok|r" or "|cffff4444nil|r"))

    local found = false

    for rollID in pairs(A.activeRolls) do
        local ok, timeLeft = pcall(GetLootRollTimeLeft, rollID)
        if ok and timeLeft and timeLeft > 0 then
            found = true
            DumpRoll("LIVE", rollID, { GetLootRollItemInfo(rollID) },
                select("#", GetLootRollItemInfo(rollID)), GetLootRollItemLink(rollID))
        end
    end

    if not found and A.lastProbe then
        found = true
        local p = A.lastProbe
        DumpRoll("LAST SEEN (" .. (date("%H:%M:%S", p.when) or "?") .. ")",
            p.rollID, p.raw, p.n, p.link)
    end

    if not found then
        A:Print("|cffff8800No roll data yet.|r Roll on one item in a group, then")
        A:Print("run /ar probe again -- the last roll is remembered.")
    end

    A:Print("custom API availability:")
    local candidates = {
        "GetItemInfoCustom", "GetItemTagsCustom", "IsUsableItem",
    }
    for _, apiName in ipairs(candidates) do
        A:Print(("  %-28s %s"):format(apiName,
            _G[apiName] and "|cff1eff00present|r" or "|cff808080absent|r"))
    end
    A:Print("add your own names to the candidates list in Core.lua:A.Probe")
    A:Print("---------------")
end

--- Human-readable list of the types this character rolls Need on.
local function SetString(order, set, manual)
    local out = {}
    for _, t in ipairs(order) do
        if set[t] then table.insert(out, t) end
    end
    if #out == 0 then return "|cffff4444none|r" end
    return table.concat(out, ", ") ..
        (manual and "  |cff808080(manual)|r" or "  |cff808080(auto)|r")
end

function A:ArmorSetString()
    return SetString(A.ARMOR_TYPE_ORDER, A:GetArmorNeedSet(), A.db.armorNeed)
end

function A:WeaponSetString()
    return SetString(A.WEAPON_TYPE_ORDER, A:GetWeaponNeedSet(), A.db.weaponNeed)
end

--- One handler for both /ar armor and /ar weapon; they differ only in data.
local function HandleTypes(kind, sub, rest)
    local isArmor = (kind == "armor")
    local order   = isArmor and A.ARMOR_TYPE_ORDER or A.WEAPON_TYPE_ORDER
    local setter  = isArmor and A.SetArmorType     or A.SetWeaponType
    local resetFn = isArmor and A.ResetArmorTypes  or A.ResetWeaponTypes
    local report  = isArmor and A.ArmorSetString   or A.WeaponSetString
    local fellBack = isArmor and A.LA.fellBack or A.LW.fellBack

    if sub == "" or sub == "list" then
        local _, token = UnitClass("player")
        A:Print(("%s %s level %d rolls Need on:"):format(
            kind, tostring(token), UnitLevel("player") or 0))
        A:Print("  " .. report(A))
        A:Print("  available: " .. table.concat(order, ", ") ..
            (fellBack and "  |cffff8800(detection fell back to English)|r" or ""))
        A:Print(("usage: /ar %s add|remove <type>  |  /ar %s auto"):format(kind, kind))
        return
    end

    if sub == "auto" or sub == "reset" then
        resetFn(A)
        A:Print(kind .. " types back to class default: " .. report(A))
        if A.RefreshOptions then A:RefreshOptions() end
        return
    end

    -- Match what was typed case-insensitively against what the client uses.
    local target
    for _, t in ipairs(order) do
        if t:lower() == rest:lower() then target = t end
    end
    if not target then
        A:Print("unknown " .. kind .. " type: " .. tostring(rest))
        A:Print("valid: " .. table.concat(order, ", "))
        return
    end

    if sub == "add" then
        setter(A, target, true)
    elseif sub == "remove" or sub == "rem" then
        setter(A, target, false)
    else
        A:Print(("usage: /ar %s add|remove <type>  |  /ar %s auto"):format(kind, kind))
        return
    end

    A:Print("now rolling Need on: " .. report(A))
    if A.RefreshOptions then A:RefreshOptions() end
end

--=========================================================================
-- Slash commands
--=========================================================================

local LIST_ALIAS = {
    need = "needList", greed = "greedList", pass = "passList",
    black = "blacklist", blacklist = "blacklist",
}

local function HandleList(listName, sub, rest)
    if sub == "list" or sub == nil or sub == "" then
        A:Print(listName .. " (" .. #A.db[listName] .. " entries):")
        if #A.db[listName] == 0 then
            A:Print("  empty")
        end
        for i, id in ipairs(A.db[listName]) do
            local _, link = GetItemInfo(id)
            A:Print(("  [%d] %s"):format(i, link or ("item:" .. id)))
        end
        return
    end

    local itemID = A:ResolveItemID(rest)
    if not itemID then
        A:Print("could not resolve: " .. tostring(rest))
        return
    end
    local _, link = GetItemInfo(itemID)
    link = link or ("item:" .. itemID)

    if sub == "add" then
        local ok, why = A:ListAdd(listName, itemID)
        A:Print(ok and ("added " .. link .. " to " .. listName)
                   or (link .. ": " .. tostring(why)))
    elseif sub == "remove" or sub == "rem" or sub == "del" then
        local ok, why = A:ListRemove(listName, itemID)
        A:Print(ok and ("removed " .. link .. " from " .. listName)
                   or (link .. ": " .. tostring(why)))
    else
        A:Print("usage: /ar " .. sub .. " add|remove|list <item>")
    end
end

local function HandleProfile(sub, rest)
    if not sub or sub == "" or sub == "list" then
        A:Print("active profile: |cffffffff" .. A.profileName .. "|r")
        for _, name in ipairs(A:GetProfileNames()) do
            A:Print("  " .. name .. (name == A.profileName and "  |cff1eff00<--|r" or ""))
        end
        A:Print("usage: /ar profile use|copy|delete|reset <name>")
    elseif sub == "use" or sub == "set" then
        if A:SetProfile(rest) then A:Print("now using profile: " .. rest) end
    elseif sub == "copy" then
        if A:CopyProfile(rest) then
            A:Print("copied settings from " .. rest .. " into " .. A.profileName)
        else
            A:Print("could not copy from: " .. tostring(rest))
        end
    elseif sub == "delete" then
        local ok, why = A:DeleteProfile(rest)
        A:Print(ok and ("deleted " .. rest) or ("cannot delete: " .. tostring(why)))
    elseif sub == "reset" then
        A:ResetProfile()
        A:Print("profile " .. A.profileName .. " reset to defaults")
    end
end

SLASH_AUTOROLL1 = "/autoroll"
SLASH_AUTOROLL2 = "/ar"
SlashCmdList["AUTOROLL"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    local sub, tail = rest:match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()

    -- probe and help must keep working in a broken state -- that is the whole
    -- point of them. Everything else needs a database to read.
    if cmd ~= "probe" and cmd ~= "help" and cmd ~= "" and not A.db then
        A:Print("|cffff4444not initialised.|r Run |cffffffff/ar probe|r for a diagnostic.")
        return
    end

    if cmd == "" or cmd == "config" or cmd == "options" then
        if InterfaceOptionsFrame_OpenToCategory then
            InterfaceOptionsFrame_OpenToCategory(A.optionsPanel)
            InterfaceOptionsFrame_OpenToCategory(A.optionsPanel) -- known 3.3.5a quirk
        end

    elseif cmd == "on" then
        A.db.enabled = true;  A:Print("enabled")
    elseif cmd == "off" then
        A.db.enabled = false; A:Print("disabled")
    elseif cmd == "toggle" then
        A.db.enabled = not A.db.enabled
        A:Print(A.db.enabled and "enabled" or "disabled")

    elseif cmd == "debug" then
        A.db.debug = not A.db.debug
        A:Print("debug " .. (A.db.debug and "on" or "off"))

    elseif cmd == "delay" then
        local n = tonumber(rest)
        if n and n >= 0 and n <= 10 then
            A.db.rollDelay = n
            A:Print(("roll delay set to %.1fs"):format(n))
        else
            A:Print("usage: /ar delay <0-10 seconds>")
        end

    elseif cmd == "log" or cmd == "history" then
        A:ToggleHistoryFrame()

    elseif cmd == "test" then
        A:TestItem(rest)

    elseif cmd == "trace" or cmd == "why" then
        A:TraceItem(rest)

    elseif cmd == "probe" then
        A:Probe()

    elseif cmd == "armor" or cmd == "armour" then
        HandleTypes("armor", sub, tail)

    elseif cmd == "weapon" or cmd == "weapons" then
        HandleTypes("weapon", sub, tail)

    elseif cmd == "profile" then
        HandleProfile(sub, tail)

    elseif LIST_ALIAS[cmd] then
        HandleList(LIST_ALIAS[cmd], sub, tail)

    elseif cmd == "status" then
        A:Print(("enabled=%s delay=%.1fs profile=%s rules=%d")
            :format(tostring(A.db.enabled), A.db.rollDelay, A.profileName, #A.ruleList))
        for _, rule in ipairs(A.ruleList) do
            A:Print(("  [%3d] %-14s %s"):format(rule.priority, rule.key,
                A.db.rules[rule.key] ~= false and "|cff1eff00on|r" or "|cffff4444off|r"))
        end

    else
        A:Print("commands:")
        A:Print("  /ar                     open the options panel")
        A:Print("  /ar on | off | toggle")
        A:Print("  /ar status              list rules and their priority")
        A:Print("  /ar test <item>         dry run a link, ID or name")
        A:Print("  /ar trace <item>        show every rule's verdict")
        A:Print("  /ar armor               armor types you roll Need on")
        A:Print("  /ar weapon              weapon types you roll Need on")
        A:Print("  /ar probe               dump server roll data (run during a roll)")
        A:Print("  /ar log                 open the roll history")
        A:Print("  /ar delay <seconds>")
        A:Print("  /ar need|greed|pass|black add|remove|list <item>")
        A:Print("  /ar profile use|copy|delete|reset <name>")
        A:Print("  /ar debug")
    end
end
