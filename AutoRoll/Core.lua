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

    -- Last check before committing. Anything else that answers rolls -- a
    -- server-side loot filter, another addon, or you clicking a button -- may
    -- have closed this one while we waited out the roll delay. Rolling into a
    -- closed roll is at best wasted and at worst a double answer, so confirm
    -- it is still live at the moment we act rather than only when we decided.
    if ctx.rollID then
        local ok, timeLeft = pcall(GetLootRollTimeLeft, ctx.rollID)
        if not ok or not timeLeft or timeLeft <= 0 then
            A:Debug(("roll %d was answered elsewhere; not rolling")
                :format(ctx.rollID))
            return
        end
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

--=========================================================================
-- Async data hooks
--
-- Custom servers often answer questions asynchronously: you call a Request
-- function and the reply lands in a table some milliseconds later. Deciding
-- before it arrives is the same bug class as deciding before GetItemInfo has
-- populated, so the queue treats both the same way.
--
--   A:AddPrefetch(fn)     fn(itemID, link) fires the moment a roll starts
--   A:AddReadyCheck(fn)   fn(ctx) -> true when its data has arrived
--
-- A ready check that never returns true just costs the retry budget and then
-- decides anyway, so a broken or missing server API degrades to normal
-- behaviour rather than hanging the roll.
--=========================================================================

A.prefetchers = {}
A.readyChecks = {}

function A:AddPrefetch(fn)   table.insert(A.prefetchers, fn) end
function A:AddReadyCheck(fn) table.insert(A.readyChecks, fn) end

local function RunPrefetch(itemID, link)
    for _, fn in ipairs(A.prefetchers) do
        local ok, err = pcall(fn, itemID, link)
        if not ok then A:Debug("prefetch error: " .. tostring(err)) end
    end
end

--- Returns true when every registered check is satisfied.
local function AllReady(ctx)
    for _, fn in ipairs(A.readyChecks) do
        local ok, ready = pcall(fn, ctx)
        if ok and not ready then return false end
    end
    return true
end

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

                elseif (not resolved or not AllReady(ctx))
                       and entry.tries < (A.db.itemInfoRetries or 12) then
                    -- Either the item is not in the local cache yet, or a
                    -- server API we asked has not answered. Deciding now would
                    -- silently skip rules, so wait. The GetItemInfo call inside
                    -- BuildContext is itself what asks the client for the data.
                    entry.tries  = entry.tries + 1
                    entry.fireAt = now + RETRY_INTERVAL
                    A:Debug(("waiting on data for roll %d (try %d)")
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

        -- Ask any server APIs now, not at decision time: an async reply needs
        -- the whole rollDelay to travel, and asking late wastes it.
        local link = GetLootRollItemLink(rollID)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if itemID then RunPrefetch(itemID, link) end

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

    if itemClass == A.LC.ARMOR or itemClass == A.LC.WEAPON then
        A:Print("  rolling for: " .. A:ClassSetString())
        A:Print("  " .. A:GearSetString())
    end

    local own, ownWhy = A:AlreadyOwn(itemID)
    A:Print(("  already own=%s%s"):format(
        own and "|cffff8800yes|r" or "|cff1eff00no|r",
        own and ("  " .. tostring(ownWhy)) or ""))

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
    -- Anything the server added under its own prefix. Loot filters and similar
    -- systems tend to namespace themselves, so this catches them without
    -- needing to know the names in advance.
    for name, value in pairs(_G) do
        if type(name) == "string" and name:find("^Peloria") then
            table.insert(candidates, name)
        end
    end
    table.sort(candidates)
    for _, apiName in ipairs(candidates) do
        A:Print(("  %-28s %s"):format(apiName,
            _G[apiName] and "|cff1eff00present|r" or "|cff808080absent|r"))
    end
    A:Print("add your own names to the candidates list in Core.lua:A.Probe")
    A:Print("---------------")
end

--- Human-readable summary of what this character rolls Need on.
function A:ClassSetString()
    local out = {}
    for _, token in ipairs(A.CLASS_ORDER) do
        if A:GetNeedClasses()[token] then
            table.insert(out, A.CLASS_LABEL[token] or token)
        end
    end
    if #out == 0 then return "|cffff4444none|r" end
    return table.concat(out, ", ") ..
        (A.db.needClasses and "  |cff808080(manual)|r" or "  |cff808080(auto)|r")
end

function A:GearSetString()
    local armor, weapons, relics, offhand = A:GetNeedSets()
    local a, w, r = {}, 0, {}
    for _, t in ipairs(A.ARMOR_TYPE_ORDER) do if armor[t] then table.insert(a, t) end end
    for _, t in ipairs(A.WEAPON_TYPE_ORDER) do if weapons[t] then w = w + 1 end end
    for _, t in ipairs(A.RELIC_TYPE_ORDER) do if relics[t] then table.insert(r, t) end end
    return ("armor: %s | weapons: %d types | relics: %s | offhand: %s")
        :format(#a > 0 and table.concat(a, ", ") or "none",
                w,
                #r > 0 and table.concat(r, ", ") or "none",
                offhand and "yes" or "no")
end

--- /ar class [add|remove|only <class>] [auto]
local function HandleClass(sub, rest)
    if sub == "" or sub == "list" then
        A:Print("rolling gear for: " .. A:ClassSetString())
        A:Print("  " .. A:GearSetString())
        A:Print(("level %d%s"):format(UnitLevel("player") or 0,
            A.db.ignoreLevel and "  |cff808080(ignoring level)|r" or ""))
        A:Print("usage: /ar class add|remove|only <class>  |  /ar class auto")
        A:Print("valid: " .. table.concat(A.CLASS_ORDER, ", "):lower())
        return
    end

    if sub == "auto" or sub == "reset" then
        A:ResetNeedClasses()
        A:Print("back to your own class: " .. A:ClassSetString())
        if A.RefreshOptions then A:RefreshOptions() end
        return
    end

    local target
    local want = rest:upper():gsub("%s+", "")
    for _, token in ipairs(A.CLASS_ORDER) do
        if token == want or token:sub(1, #want) == want then target = token end
    end
    if not target then
        A:Print("unknown class: " .. tostring(rest))
        A:Print("valid: " .. table.concat(A.CLASS_ORDER, ", "):lower())
        return
    end

    if sub == "add" then
        A:SetNeedClass(target, true)
    elseif sub == "remove" or sub == "rem" then
        A:SetNeedClass(target, false)
    elseif sub == "only" then
        A.db.needClasses = { [target] = true }
    else
        A:Print("usage: /ar class add|remove|only <class>  |  /ar class auto")
        return
    end

    A:Print("rolling gear for: " .. A:ClassSetString())
    A:Print("  " .. A:GearSetString())
    if A.RefreshOptions then A:RefreshOptions() end
end

--- /ar misc armor <type> | weapons | offhand | level
local function HandleMisc(sub, rest)
    sub = sub:lower()

    if sub == "" or sub == "list" then
        local extra = {}
        for t, on in pairs(A.db.miscArmor or {}) do
            if on then table.insert(extra, t) end
        end
        table.sort(extra)
        A:Print("misc opt-ins:")
        A:Print("  extra armor: " .. (#extra > 0 and table.concat(extra, ", ") or "none"))
        A:Print("  all weapons: " .. (A.db.miscWeapons and "yes" or "no"))
        A:Print("  offhands:    " .. (A.db.miscOffhand and "yes" or "no"))
        A:Print("  ignore level:" .. (A.db.ignoreLevel and " yes" or " no"))
        A:Print("usage: /ar misc armor <type> | weapons | offhand | level")
        return
    end

    if sub == "weapons" then
        A.db.miscWeapons = not A.db.miscWeapons
        A:Print("roll all weapon types: " .. (A.db.miscWeapons and "yes" or "no"))
    elseif sub == "offhand" then
        A.db.miscOffhand = not A.db.miscOffhand
        A:Print("roll offhands and shields: " .. (A.db.miscOffhand and "yes" or "no"))
    elseif sub == "level" then
        A.db.ignoreLevel = not A.db.ignoreLevel
        A:Print("ignore level requirements: " .. (A.db.ignoreLevel and "yes" or "no"))
    elseif sub == "armor" then
        local target
        for _, t in ipairs(A.ARMOR_TYPE_ORDER) do
            if t:lower() == rest:lower() then target = t end
        end
        if not target then
            A:Print("unknown armor type: " .. tostring(rest))
            A:Print("valid: " .. table.concat(A.ARMOR_TYPE_ORDER, ", "))
            return
        end
        A.db.miscArmor = A.db.miscArmor or {}
        local now = not A.db.miscArmor[target]
        A:SetMiscArmor(target, now)
        A:Print(("extra armor %s: %s"):format(target, now and "yes" or "no"))
    else
        A:Print("usage: /ar misc armor <type> | weapons | offhand | level")
        return
    end

    A:Print("  " .. A:GearSetString())
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

    elseif cmd == "class" or cmd == "classes" then
        HandleClass(sub, tail)

    elseif cmd == "misc" then
        HandleMisc(sub, tail)

    elseif cmd == "dupe" or cmd == "duplicate" then
        local want = rest:upper()
        if want == "NEED" or want == "GREED" or want == "PASS" or want == "IGNORE" then
            A.db.duplicateAction = want
            A:Print("items you already own: |cffffffff" .. want .. "|r")
            if A.RefreshOptions then A:RefreshOptions() end
        elseif want == "EQUIPPED" then
            A.db.duplicateIncludeEquipped = not A.db.duplicateIncludeEquipped
            A:Print("count equipped items as owned: " ..
                (A.db.duplicateIncludeEquipped and "yes" or "no"))
            if A.RefreshOptions then A:RefreshOptions() end
        else
            A:Print("usage: /ar dupe need|greed|pass|ignore  |  /ar dupe equipped")
            A:Print(("currently %s, equipped counted: %s"):format(
                A.db.duplicateAction,
                A.db.duplicateIncludeEquipped and "yes" or "no"))
        end

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
        A:Print("  /ar class               classes you roll gear for")
        A:Print("  /ar misc                extra armor, weapons, offhands")
        A:Print("  /ar dupe <action>       what to do with items you already own")
        A:Print("  /ar probe               dump server roll data (run during a roll)")
        A:Print("  /ar log                 open the roll history")
        A:Print("  /ar delay <seconds>")
        A:Print("  /ar need|greed|pass|black add|remove|list <item>")
        A:Print("  /ar profile use|copy|delete|reset <name>")
        A:Print("  /ar debug")
    end
end
