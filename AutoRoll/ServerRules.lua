--=========================================================================
-- AutoRoll :: ServerRules.lua
--
-- THIS IS THE FILE YOU EDIT.
--
-- Everything above this in the load order runs on stock 3.3.5a APIs only.
-- Custom cores add globals of their own, and no two servers agree on what
-- those are called, so they live here behind feature detection instead of
-- being welded into the engine.
--
-- Run "/ar probe" in game to see what your server exposes, then write rules
-- against whatever comes back present.
--
-- Anatomy of a rule:
--
--   A:RegisterRule{
--       key      = "myRule",          -- also the db.rules on/off key
--       label    = "My rule",         -- shown in the options panel
--       priority = 85,                -- lower runs first, first match wins
--       fn       = function(self, ctx)
--           -- return an action + reason to decide, or nil to fall through
--           return self.ACTION.NEED, "because reasons"
--       end,
--   }
--
-- ctx fields: rollID, link, itemID, name, quality, iLevel, reqLevel,
--             itemClass, itemSubClass, maxStack, equipSlot, resolved,
--             bindOnPickUp, canNeed, canGreed, canDisenchant, isTest
--
-- Priorities already taken by the built-ins:
--   10 manualQuality   20 blacklist    30 needList    40 greedList
--   50 passList        60 alreadyKnown 70 recipe      80 classToken
--   89 armorType       90 upgrade     100 unusable   110 lockbox
--  120 tradeGoods     130 boe         999 fallback
--
-- Slot your rules into the gaps. A rule that should beat the gear check goes
-- at 85; one that only fires when nothing else did goes at 140.
--
-- Any rule you register here automatically gets a checkbox in the options
-- panel and an entry in db.rules. Nothing else to wire up.
--=========================================================================

local A = AutoRoll

--=========================================================================
-- Declare defaults for your own rules here. This file loads before
-- ADDON_LOADED fires, so anything added to A.defaults is picked up by the
-- normal profile back-fill and survives a fresh install.
--=========================================================================

-- A.defaults.rules.myRule = true
-- A.defaults.myRuleSetting = 42

--=========================================================================
-- TEMPLATE -- a rule guarded on a custom global
--
-- The guard is the important part. With it, this file is inert on a server
-- that lacks the API instead of erroring on every single loot roll.
--=========================================================================

-- A.defaults.rules.customTag = true
--
-- A:RegisterRule{
--     key      = "customTag",
--     label    = "Custom item tag",
--     priority = 85,
--     fn = function(self, ctx)
--         if not GetItemTagsCustom then return end     -- guard
--
--         local tags = GetItemTagsCustom(ctx.itemID)
--         if type(tags) ~= "number" then return end
--
--         local BIT_INTERESTING = 64                   -- check your server's source
--         if bit.band(tags, BIT_INTERESTING) ~= 0 then
--             return self.ACTION.NEED, "tagged interesting"
--         end
--     end,
-- }

--=========================================================================
-- EXAMPLE -- never roll on gear above your level
--
-- Stock APIs only, so this one actually runs. Useful while levelling.
--=========================================================================

A.defaults.rules.tooHighLevel = true      -- on by default
A.defaults.maxReqLevelOver    = 0         -- allow reqLevel up to your level + this

A:RegisterRule{
    key      = "tooHighLevel",
    label    = "Gear above your level",
    priority = 86,
    fn = function(self, ctx)
        if not ctx.reqLevel or ctx.reqLevel == 0 then return end

        local cap = (UnitLevel("player") or 80) + (self.db.maxReqLevelOver or 0)
        if ctx.reqLevel > cap then
            local action = ctx.bindOnPickUp and "PASS" or "GREED"
            return self.NamedAction(action),
                   ("requires level %d, you are %d"):format(ctx.reqLevel, UnitLevel("player") or 0)
        end
    end,
}

--=========================================================================
-- Helpers available to your rules (all defined in Rules.lua):
--
--   self:IsUnusable(link)         -> bool, offendingRedLine
--   self:IsAlreadyKnown(link)     -> bool
--   self:IsClassToken(link)       -> bool
--   self:IsLockbox(link, name)    -> bool
--   self:GetUpgradeDelta(link)    -> ilvlDelta, equippedIlvl
--   self:GetArmorNeedSet()        -> { ["Plate"] = true, ... }
--   self:CountInBags(itemID)      -> number
--   self:ListContains(list, id)   -> bool  ("needList", "greedList", ...)
--   self.NamedAction(str)         -> action value for "NEED"/"GREED"/...
--   self:Debug(msg)
--=========================================================================

--=========================================================================
-- PELORIA SOULBIND
--
-- Sacrifice an item to keep part of its stats. Each item type can only be
-- soulbound once, so the decision is:
--
--   eligible (not yet soulbound)  -> worth taking
--   not eligible                  -> worth nothing to you
--
-- The server exposes:
--
--   PeloriaRequestSoulbindEligibility   function
--   PeloriaSoulbindEligibility          table
--   PeloriaRequestSoulbindPreview       function
--   PeloriaSoulbindPreviews             table
--   PeloriaRefreshSoulbindTooltips      function
--
-- Request + table is an ASYNCHRONOUS pattern: you ask, the server answers a
-- few milliseconds later, and the answer appears in the table. So the first
-- time a given item drops the table is empty, and a rule that read it
-- immediately would decide on a blank. The prefetch and ready-check hooks
-- below handle that: the request fires the instant the roll starts, and the
-- queue waits for the reply before deciding.
--
-- WHAT IS STILL GUESSWORK: the argument the Request functions take, the key
-- format of the tables, and the value format. The readers below accept
-- several plausible shapes, and everything is wrapped so a wrong guess
-- degrades to "cannot tell" rather than erroring on every roll.
--
-- Run this on an item and paste the output if anything looks off:
--
--     /ar soulbind [Some Item]
--=========================================================================

A.defaults.rules.soulbind         = true
A.defaults.soulbindEligibleAction = "NEED"    -- not yet soulbound
A.defaults.soulbindDoneAction     = "GREED"   -- already soulbound, BoE
A.defaults.soulbindDoneBoPAction  = "PASS"    -- already soulbound, BoP
A.defaults.soulbindIneligibleAsDone = false   -- act on already-collected, vs defer
-- Need every soulbindable item even when we cannot tell if you already
-- collected it. Off by default: it would re-Need things you finished with.
A.defaults.soulbindNeedWithoutCollectedCheck = false

local function HasSoulbindAPI()
    return type(PeloriaRequestSoulbindEligibility) == "function"
       and type(PeloriaSoulbindEligibility) == "table"
end

--- Tables may be keyed by number or by string; try both.
local function TableLookup(t, itemID)
    if type(t) ~= "table" then return nil end
    local v = t[itemID]
    if v == nil then v = t[tostring(itemID)] end
    return v
end

--=========================================================================
-- Refresh flicker
--
-- Observed: calling PeloriaRequestSoulbindEligibility CLEARS the table entry
-- and then repopulates it a moment later. So an entry read mid-refresh comes
-- back nil even though the server already told us the answer.
--
-- Left alone that would make the rule intermittently blind: any refresh
-- triggered by the soulbind UI, another addon, or our own prefetch could
-- happen to land in the window where we read. So every value we ever see is
-- remembered, and a nil falls back to the last known good answer.
--
-- Cleared on logout with the session, which is correct -- soulbind state can
-- change between sessions and stale data would be worse than none.
--=========================================================================

local lastKnown = {}

--- True while an entry is absent but we have seen it before -- i.e. a refresh
--  is probably in flight rather than the server having no answer.
local function IsRefreshing(itemID)
    return TableLookup(PeloriaSoulbindEligibility, itemID) == nil
       and lastKnown[itemID] ~= nil
end

local function LiveOrCached(itemID)
    local v = TableLookup(PeloriaSoulbindEligibility, itemID)
    if v ~= nil then
        lastKnown[itemID] = v
        return v
    end
    return lastKnown[itemID]
end

--=========================================================================
-- ALREADY SOULBOUND -- the missing second signal
--
-- Eligibility only says "this type is soulbindable". To avoid Needing items
-- you have already collected, we also need to know that. Fill in ONE of these
-- once /ar sbsnap + /ar sbdiff reveal where the state lives.
--
-- Until one is filled in, AlreadySoulbound returns nil ("cannot tell") and
-- the rule falls back to the conservative behaviour described on the rule
-- itself. Nothing here guesses.
--=========================================================================

-- Lowercase fragments that appear in the tooltip of an item you HAVE
-- soulbound. Take these from the /ar sbdiff output.
local SOULBOUND_TOOLTIP = {
    -- "soulbind: collected",
    -- "already soulbound",
}

-- Name of a global that answers it directly, if one turns up.
local SOULBOUND_API = nil     -- e.g. "PeloriaHasSoulbound"

--- If a preview only exists while there is something left to gain, then the
--  absence of a preview IS the already-collected signal. Turn this on only if
--  /ar sbdiff shows that pattern.
local PREVIEW_ABSENCE_MEANS_DONE = false

--- Returns true (already soulbound), false (not yet), or nil (cannot tell).
local function AlreadySoulbound(ctx)
    if SOULBOUND_API and type(_G[SOULBOUND_API]) == "function" then
        local ok, result = pcall(_G[SOULBOUND_API], ctx.itemID)
        if ok and result ~= nil then
            return (result == true or result == 1)
        end
    end

    if SOULBOUND_TOOLTIP[1] and ctx.link then
        local hit = A.ScanTooltip(ctx.link, function(text)
            local t = text:lower()
            for _, frag in ipairs(SOULBOUND_TOOLTIP) do
                if t:find(frag, 1, true) then return true end
            end
        end)
        if hit then return true end
        return false      -- we know the wording and it is absent
    end

    if PREVIEW_ABSENCE_MEANS_DONE and type(PeloriaSoulbindPreviews) == "table" then
        local preview = TableLookup(PeloriaSoulbindPreviews, ctx.itemID)
        if preview ~= nil then return false end
        -- Absent could also just mean the request has not answered yet, so
        -- only trust it once we have an eligibility answer for the same item.
        if LiveOrCached(ctx.itemID) ~= nil then return true end
    end

    return nil
end
--=========================================================================
-- Eligibility status codes
--
-- CONFIRMED BY TESTING: this table is static item metadata. It reports
-- whether an item type CAN be soulbound, not whether you have already done
-- it -- a soulbound item keeps reporting 2 indefinitely.
--
--   0 = this item type cannot be soulbound
--   2 = this item type can be soulbound
--
-- So on its own this is not enough to drive a roll: without an
-- already-collected signal the rule would Need every soulbindable item
-- forever, including ones you have finished with. See ALREADY_SOULBOUND
-- below for where that second signal has to come from.
--=========================================================================

local ELIGIBILITY_CODES = {
    [0] = { eligible = false, label = "not soulbindable" },
    [2] = { eligible = true,  label = "soulbindable" },
}
A.SOULBIND_CODES = ELIGIBILITY_CODES

--- Returns eligible (bool), label (string), raw value.
--  A nil first return means "no usable answer", which the rule treats as
--  "no opinion" rather than guessing.
local function ReadEligibility(itemID)
    local v = LiveOrCached(itemID)
    if v == nil then return nil, "no entry", nil end

    if type(v) == "boolean" then
        return v, v and "soulbindable" or "not soulbindable", v
    end

    if type(v) == "number" then
        local code = ELIGIBILITY_CODES[v]
        if code then return code.eligible, code.label, v end
        A:Debug("soulbind: unrecognised eligibility code " .. v ..
                " -- run /ar sbcodes and add it to ELIGIBILITY_CODES")
        return nil, "unknown code " .. v, v
    end

    if type(v) == "table" then
        for _, key in ipairs({ "eligible", "isEligible", "canSoulbind", "allowed" }) do
            if v[key] ~= nil then
                local yes = (v[key] == true or v[key] == 1)
                return yes, yes and "soulbindable" or "not soulbindable", v[key]
            end
        end
        for _, key in ipairs({ "soulbound", "bound", "collected", "done" }) do
            if v[key] ~= nil then
                local done = (v[key] == true or v[key] == 1)
                return not done, done and "already soulbound" or "soulbindable", v[key]
            end
        end
        return nil, "table with no known field", nil
    end

    return nil, "unhandled type " .. type(v), v
end

--- Fire the request as early as possible so the reply has time to arrive.
--  Skipped when we already have an answer: a redundant request would clear
--  the entry and put us back to waiting for no benefit.
local function RequestEligibility(itemID, link)
    if not HasSoulbindAPI() then return end
    if lastKnown[itemID] ~= nil then return end
    if TableLookup(PeloriaSoulbindEligibility, itemID) ~= nil then return end

    if not pcall(PeloriaRequestSoulbindEligibility, itemID) then
        if link then pcall(PeloriaRequestSoulbindEligibility, link) end
    end
end

A:AddPrefetch(function(itemID, link)
    RequestEligibility(itemID, link)
end)

--- The queue waits on this before deciding.
A:AddReadyCheck(function(ctx)
    if not HasSoulbindAPI() then return true end            -- nothing to wait for
    if not A.db.rules.soulbind then return true end          -- rule disabled
    if ctx.itemClass ~= A.LC.ARMOR and ctx.itemClass ~= A.LC.WEAPON then
        return true                                          -- not gear, irrelevant
    end
    -- A cached answer counts as ready even mid-refresh, so a refresh started
    -- by something else cannot stall the roll.
    return LiveOrCached(ctx.itemID) ~= nil
end)

A:RegisterRule{
    key      = "soulbind",
    label    = "Soulbind eligibility",
    priority = 84,          -- ahead of the gear rule (89)
    fn = function(self, ctx)
        if not HasSoulbindAPI() then return end
        if ctx.itemClass ~= self.LC.ARMOR and ctx.itemClass ~= self.LC.WEAPON then
            return
        end

        local eligible, label = ReadEligibility(ctx.itemID)
        if eligible == nil then return end       -- unknown code: let normal rules run

        if not eligible then
            -- Type cannot be soulbound. No soulbind opinion; the item may
            -- still be good gear, so let the type rules judge it on merit.
            return
        end

        -- Soulbindable. But eligibility is static metadata, so on its own it
        -- cannot tell us whether you already collected this one.
        local done = AlreadySoulbound(ctx)

        if done == true then
            if not self.db.soulbindIneligibleAsDone then
                self:Debug("soulbind: already collected, deferring to normal rules")
                return
            end
            local action = ctx.bindOnPickUp and self.db.soulbindDoneBoPAction
                                            or  self.db.soulbindDoneAction
            return self.NamedAction(action), "soulbind: already collected"
        end

        if done == false then
            return self.NamedAction(self.db.soulbindEligibleAction),
                   "soulbind: not yet collected"
        end

        -- done == nil: we know it is soulbindable but not whether you have
        -- done it. Needing everything soulbindable would mean re-Needing
        -- items you finished with long ago, so this is gated behind a setting
        -- that is OFF by default. Fill in the ALREADY SOULBOUND section above
        -- to make this branch unnecessary.
        if self.db.soulbindNeedWithoutCollectedCheck then
            return self.NamedAction(self.db.soulbindEligibleAction),
                   "soulbind: soulbindable (collected state unknown)"
        end

        self:Debug("soulbind: soulbindable but collected state unknown, deferring")
    end,
}

--=========================================================================
-- SERVER LOOT FILTER -- deferral scaffold
--
-- If the server has its own loot filter, there are two sane ways to combine
-- it with this addon, and which one you want depends on what the filter does.
--
--   A. THE SERVER DECIDES, the addon fills the gaps.
--      Point SERVER_FILTER_API at a function that returns the server's verdict
--      for an item. When it has an opinion, the addon uses it. When it does
--      not, the normal rules run. Rule priority 5 -- ahead of everything.
--
--   B. THE SERVER ACTS ON ITS OWN and the addon should stay out of the way.
--      If the filter answers rolls itself, you do not want a deferral rule at
--      all -- you want the addon to not roll on those items. Use the blacklist
--      (/ar black add) or turn the addon off in those instances. The
--      "roll already answered" check in Core.lua:Execute covers the race, but
--      avoiding the overlap entirely is better than racing it.
--
-- To find out which you have, run:
--
--     /ar probe                 (lists every Peloria* global)
--     /ar findapi loot
--     /ar findapi filter
--
-- If the filter is purely server-side with no client globals, the client
-- cannot query it and only option B is available.
--=========================================================================

-- Name of a global taking an itemID (or link) and returning the server's
-- verdict. Leave nil to disable this rule entirely.
local SERVER_FILTER_API = nil     -- e.g. "PeloriaGetLootFilterVerdict"

-- How the server's return value maps onto a roll action. Extend as needed;
-- the keys are matched against tostring(verdict):lower().
local VERDICT_MAP = {
    need = "NEED",   greed = "GREED", pass = "PASS",
    keep = "NEED",   vendor = "GREED", ignore = "IGNORE",
    ["1"] = "NEED",  ["2"] = "GREED", ["0"] = "PASS",
}

A.defaults.rules.serverFilter = true

A:RegisterRule{
    key      = "serverFilter",
    label    = "Server loot filter",
    priority = 5,           -- ahead of everything, including the manual-quality guard
    fn = function(self, ctx)
        if not SERVER_FILTER_API then return end

        local fn = _G[SERVER_FILTER_API]
        if type(fn) ~= "function" then return end

        local ok, verdict = pcall(fn, ctx.itemID)
        if not ok or verdict == nil then
            if ctx.link then
                ok, verdict = pcall(fn, ctx.link)
            end
            if not ok or verdict == nil then return end
        end

        local mapped = VERDICT_MAP[tostring(verdict):lower()]
        if not mapped then
            self:Debug("server filter returned an unmapped verdict: " .. tostring(verdict))
            return                      -- unknown answer: fall through, do not guess
        end

        return self.NamedAction(mapped), "server filter: " .. tostring(verdict)
    end,
}

