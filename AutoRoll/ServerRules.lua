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
