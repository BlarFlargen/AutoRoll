--=========================================================================
-- AutoRoll :: Rules.lua
--
-- Item classification helpers plus the rule registry.
--
-- A rule is a table:
--   {
--     key      = "upgrade",        -- must match a key in db.rules
--     label    = "Item upgrades",  -- shown in the options panel
--     priority = 90,               -- lower runs first; first match wins
--     fn       = function(self, ctx) ... return action, reason end,
--   }
--
-- fn returns an A.ACTION value plus a short human-readable reason, or nil
-- to fall through to the next rule. Returning A.ACTION.PASS (0) counts as a
-- match -- 0 is truthy in Lua, which is exactly what we want here.
--=========================================================================

local A = AutoRoll

--=========================================================================
-- Tooltip scanner
--=========================================================================

local scanner = CreateFrame("GameTooltip", "AutoRollScanTooltip", UIParent, "GameTooltipTemplate")
scanner:SetOwner(UIParent, "ANCHOR_NONE")

--- One reusable tooltip. Creating a frame per call, as many addons do, leaks
--  a frame every time and can never be reclaimed -- frames are permanent.
local function ScanLink(link)
    scanner:SetOwner(UIParent, "ANCHOR_NONE")
    scanner:ClearLines()
    scanner:SetHyperlink(link)
    return scanner
end

local function ScanLines(link, callback)
    local tt = ScanLink(link)
    for i = 2, tt:NumLines() do
        local fs = _G["AutoRollScanTooltipTextLeft" .. i]
        if fs then
            local text = fs:GetText()
            if text then
                local r, g, b = fs:GetTextColor()
                local result = callback(text, r, g, b, i)
                if result ~= nil then
                    tt:Hide()
                    return result
                end
            end
        end
    end
    tt:Hide()
    return nil
end

--- Red tooltip text means the client has decided you cannot use this item:
--  wrong armor class, wrong weapon skill, level too low, missing profession.
--  This is far more reliable than maintaining a class -> armor table.
function A:IsUnusable(link)
    local hit = ScanLines(link, function(text, r, g, b)
        if r > 0.9 and g < 0.2 and b < 0.2 then return text end
    end)
    return hit ~= nil, hit
end

function A:IsAlreadyKnown(link)
    local known = ITEM_SPELL_KNOWN or "Already known"
    return ScanLines(link, function(text)
        if text:find(known, 1, true) then return true end
    end) == true
end

--- Only needed for the dry-run command. During a real roll the server tells
--  us the bind type directly, which is both cheaper and authoritative.
function A:GetBindOnPickup(link)
    local bop = ITEM_BIND_ON_PICKUP or "Binds when picked up"
    local soul = ITEM_SOULBOUND or "Soulbound"
    return ScanLines(link, function(text)
        if text == bop or text == soul then return true end
        if text == (ITEM_BIND_ON_EQUIP or "Binds when equipped") then return false end
    end) == true
end

local playerClassLocalized = UnitClass("player")

--- Class tokens ("Chest of the Lost Vanquisher" and friends) list the classes
--  they convert for in the tooltip body.
function A:IsClassToken(link)
    if not playerClassLocalized then return false end
    return ScanLines(link, function(text)
        if text:find(playerClassLocalized, 1, true) then return true end
    end) == true
end

--=========================================================================
-- Item category detection
--
-- GetItemInfo returns *localized* class and subclass strings, so hardcoding
-- "Trade Goods" breaks on any non-enUS client. GetAuctionItemClasses gives us
-- the localized names in a fixed order, which we key off instead.
--=========================================================================

local LC = {}
do
    local c = { GetAuctionItemClasses() }
    LC.WEAPON     = c[1]  or "Weapon"
    LC.ARMOR      = c[2]  or "Armor"
    LC.CONTAINER  = c[3]  or "Container"
    LC.CONSUMABLE = c[4]  or "Consumable"
    LC.GLYPH      = c[5]  or "Glyph"
    LC.TRADEGOODS = c[6]  or "Trade Goods"
    LC.PROJECTILE = c[7]  or "Projectile"
    LC.QUIVER     = c[8]  or "Quiver"
    LC.RECIPE     = c[9]  or "Recipe"
    LC.GEM        = c[10] or "Gem"
    LC.MISC       = c[11] or "Miscellaneous"
end
A.LC = LC

A.GREEDABLE_CLASSES = {
    [LC.TRADEGOODS] = true,
    [LC.CONSUMABLE] = true,
    [LC.GEM]        = true,
    [LC.GLYPH]      = true,
    [LC.PROJECTILE] = true,
}

--=========================================================================
-- Armor types
--
-- The red-tooltip usability check cannot help here, and this is the reason:
-- armor type is NOT a client-enforced restriction. A paladin can equip a
-- cloth chestpiece perfectly well -- it is simply a terrible idea. Nothing
-- turns red, so cloth sails through every usability test and then wins on
-- item level, because lighter gear of the same tier carries a higher ilvl.
--
-- Weapon and shield proficiency IS client-enforced, so red text still covers
-- those correctly. This table only needs the four armor types.
--=========================================================================

local LA = {}
do
    local s = { GetAuctionItemSubClasses(2) }   -- 2 = Armor
    LA.MISC, LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE = s[1], s[2], s[3], s[4], s[5]

    -- If the indices are not what we expect on this client, the four types
    -- collapse into duplicates or nils. Fall back rather than silently
    -- classifying every piece of armor as the wrong type.
    local seen, sane = {}, true
    for _, v in ipairs({ LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE }) do
        if type(v) ~= "string" or v == "" or seen[v] then sane = false end
        seen[v or ""] = true
    end
    if not sane then
        LA.MISC, LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE =
            "Miscellaneous", "Cloth", "Leather", "Mail", "Plate"
        LA.fellBack = true
    end
end
A.LA = LA

-- Everything else in the Armor class -- cloaks, rings, necks, trinkets,
-- shields, relics -- is either wearable by everyone or already gated by the
-- client, so it is deliberately not listed here.
A.ARMOR_TYPES = {
    [LA.CLOTH] = true, [LA.LEATHER] = true, [LA.MAIL] = true, [LA.PLATE] = true,
}
A.ARMOR_TYPE_ORDER = { LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE }

-- Index 1 is the class's top type; index 2 is what it wears before level 40.
local CLASS_ARMOR = {
    WARRIOR     = { LA.PLATE,   LA.MAIL    },
    PALADIN     = { LA.PLATE,   LA.MAIL    },
    DEATHKNIGHT = { LA.PLATE               },
    HUNTER      = { LA.MAIL,    LA.LEATHER },
    SHAMAN      = { LA.MAIL,    LA.LEATHER },
    ROGUE       = { LA.LEATHER             },
    DRUID       = { LA.LEATHER             },
    PRIEST      = { LA.CLOTH               },
    MAGE        = { LA.CLOTH               },
    WARLOCK     = { LA.CLOTH               },
}

--- The armor types this character should roll Need on.
--  db.armorNeed nil means "work it out from class and level"; setting it to a
--  table pins the choice manually.
function A:GetArmorNeedSet()
    if A.db and A.db.armorNeed then return A.db.armorNeed end

    local _, token = UnitClass("player")
    local list = CLASS_ARMOR[token or ""] or {}
    local set  = {}
    local level = UnitLevel("player") or 80

    for i, atype in ipairs(list) do
        if i == 1 or level < 40 then set[atype] = true end
    end
    if not next(set) then
        for _, atype in ipairs(list) do set[atype] = true end
    end
    return set
end

--- Materialise the auto set into a real table so it can be edited.
function A:SetArmorType(atype, wanted)
    if not A.db.armorNeed then
        local copy = {}
        for k, v in pairs(A:GetArmorNeedSet()) do copy[k] = v end
        A.db.armorNeed = copy
    end
    A.db.armorNeed[atype] = wanted or nil
end

function A:ResetArmorTypes()
    A.db.armorNeed = nil
end

function A:IsLockbox(link, name)
    local n = (name or ""):lower()
    if n:find("lockbox") or n:find("strongbox") or n:find("footlocker") then
        return true
    end
    -- Lockboxes are the only common items whose tooltip mentions a lock.
    return ScanLines(link, function(text)
        local t = text:lower()
        if t:find("locked") or t:find("requires lockpicking") then return true end
    end) == true
end

--=========================================================================
-- Item level comparison
--=========================================================================

A.SLOT_MAP = {
    INVTYPE_HEAD            = { 1 },
    INVTYPE_NECK            = { 2 },
    INVTYPE_SHOULDER        = { 3 },
    INVTYPE_BODY            = { 4 },
    INVTYPE_CHEST           = { 5 },
    INVTYPE_ROBE            = { 5 },
    INVTYPE_WAIST           = { 6 },
    INVTYPE_LEGS            = { 7 },
    INVTYPE_FEET            = { 8 },
    INVTYPE_WRIST           = { 9 },
    INVTYPE_HAND            = { 10 },
    INVTYPE_FINGER          = { 11, 12 },
    INVTYPE_TRINKET         = { 13, 14 },
    INVTYPE_CLOAK           = { 15 },
    INVTYPE_WEAPON          = { 16, 17 },
    INVTYPE_2HWEAPON        = { 16 },
    INVTYPE_WEAPONMAINHAND  = { 16 },
    INVTYPE_WEAPONOFFHAND   = { 17 },
    INVTYPE_SHIELD          = { 17 },
    INVTYPE_HOLDABLE        = { 17 },
    INVTYPE_RANGED          = { 18 },
    INVTYPE_RANGEDRIGHT     = { 18 },
    INVTYPE_THROWN          = { 18 },
    INVTYPE_RELIC           = { 18 },
    INVTYPE_TABARD          = { 19 },
}

--- Positive result means the drop beats your weakest matching equipped slot.
--  Empty slots count as item level 0, so anything is an upgrade over nothing.
function A:GetUpgradeDelta(link)
    local _, _, _, iLevel, _, _, _, _, equipSlot = GetItemInfo(link)
    if not iLevel or not equipSlot then return nil end

    local slots = A.SLOT_MAP[equipSlot]
    if not slots then return nil end

    local weakest
    for _, slotID in ipairs(slots) do
        local eqLink = GetInventoryItemLink("player", slotID)
        local eqLevel = 0
        if eqLink then
            local _, _, _, lvl = GetItemInfo(eqLink)
            eqLevel = lvl or 0
        end
        if not weakest or eqLevel < weakest then weakest = eqLevel end
    end

    return iLevel - (weakest or 0), weakest
end

function A:CountInBags(itemID)
    local count = 0
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link and tonumber(link:match("item:(%d+)")) == itemID then
                count = count + 1
            end
        end
    end
    return count
end

--=========================================================================
-- Rule registry
--=========================================================================

A.ruleList = {}

function A:RegisterRule(def)
    if not def or not def.key or type(def.fn) ~= "function" then
        A:Print("RegisterRule: rule needs a key and an fn")
        return
    end
    def.priority = def.priority or 500
    def.label    = def.label or def.key

    for i, existing in ipairs(A.ruleList) do
        if existing.key == def.key then
            A.ruleList[i] = def
            table.sort(A.ruleList, function(a, b) return a.priority < b.priority end)
            return
        end
    end

    table.insert(A.ruleList, def)
    table.sort(A.ruleList, function(a, b) return a.priority < b.priority end)
end

--- Walk the rules in priority order and return the first decision.
--  Pass a table as `trace` to collect every rule's verdict along the way.
function A:Decide(ctx, trace)
    for _, rule in ipairs(A.ruleList) do
        local enabled = A.db.rules[rule.key]
        if enabled == nil then enabled = true end

        if not enabled then
            if trace then
                table.insert(trace, { key = rule.key, priority = rule.priority, status = "off" })
            end
        else
            local ok, action, reason = pcall(rule.fn, A, ctx)

            if not ok then
                A:Debug("rule '" .. rule.key .. "' errored: " .. tostring(action))
                if trace then
                    table.insert(trace, { key = rule.key, priority = rule.priority,
                                          status = "error", reason = tostring(action) })
                end
            elseif action ~= nil then
                if trace then
                    table.insert(trace, { key = rule.key, priority = rule.priority,
                                          status = "match", action = action, reason = reason })
                end
                return action, rule.key, reason or rule.label
            else
                if trace then
                    table.insert(trace, { key = rule.key, priority = rule.priority, status = "skip" })
                end
            end
        end
    end
    return nil
end

--=========================================================================
-- Built-in rules
--=========================================================================

local ACT = A.ACTION

local function NamedAction(str)
    if str == "NEED"  then return ACT.NEED  end
    if str == "GREED" then return ACT.GREED end
    if str == "PASS"  then return ACT.PASS  end
    if str == "IGNORE" then return ACT.NONE end
    return ACT.PASS
end
A.NamedAction = NamedAction

-- 10 -- Very high quality drops are worth a human decision.
A:RegisterRule{
    key = "manualQuality", label = "Leave high quality to me", priority = 10,
    fn = function(self, ctx)
        if ctx.quality and ctx.quality >= self.db.manualQualityMin then
            return ACT.NONE, "quality " .. ctx.quality .. " reserved for manual roll"
        end
    end,
}

-- 20 -- Explicit blacklist: hands off, leave the frame up.
A:RegisterRule{
    key = "blacklist", label = "Blacklist (never roll)", priority = 20,
    fn = function(self, ctx)
        if self:ListContains("blacklist", ctx.itemID) then
            return ACT.NONE, "blacklisted"
        end
    end,
}

-- 30/40/50 -- User lists.
A:RegisterRule{
    key = "needList", label = "Always need list", priority = 30,
    fn = function(self, ctx)
        if self:ListContains("needList", ctx.itemID) then return ACT.NEED, "need list" end
    end,
}
A:RegisterRule{
    key = "greedList", label = "Always greed list", priority = 40,
    fn = function(self, ctx)
        if self:ListContains("greedList", ctx.itemID) then return ACT.GREED, "greed list" end
    end,
}
A:RegisterRule{
    key = "passList", label = "Always pass list", priority = 50,
    fn = function(self, ctx)
        if self:ListContains("passList", ctx.itemID) then return ACT.PASS, "pass list" end
    end,
}

-- 60 -- Recipes, mounts and pets you already have.
A:RegisterRule{
    key = "alreadyKnown", label = "Pass on already-known", priority = 60,
    fn = function(self, ctx)
        if self:IsAlreadyKnown(ctx.link) then return ACT.PASS, "already known" end
    end,
}

-- 70 -- Unknown recipes are worth money even when useless to you.
A:RegisterRule{
    key = "recipe", label = "Unknown recipes", priority = 70,
    fn = function(self, ctx)
        if ctx.itemClass == LC.RECIPE then
            return NamedAction(self.db.recipeAction), "unknown recipe"
        end
    end,
}

-- 80 -- Tier tokens that convert for your class.
A:RegisterRule{
    key = "classToken", label = "Class tokens", priority = 80,
    fn = function(self, ctx)
        if ctx.itemClass == LC.MISC and self:IsClassToken(ctx.link) then
            return ACT.NEED, "class token"
        end
    end,
}

-- 89 -- Armor type. This is where gear is decided.
--
--       Selecting a type in the options IS the instruction to Need it, so
--       there is no separate "should I need gear" setting to keep in sync.
--       An unselected type falls to the BoE/BoP actions below.
--
--       Must sit ahead of the BoE rule at 130, or a bind-on-equip drop would
--       be judged as generic loot before anyone looked at what it is.
A:RegisterRule{
    key = "armorType", label = "Armor type", priority = 89,
    fn = function(self, ctx)
        if ctx.itemClass ~= LC.ARMOR then return end

        local atype = ctx.itemSubClass
        if not atype or not A.ARMOR_TYPES[atype] then return end   -- cloak, ring, shield...

        if self:GetArmorNeedSet()[atype] then
            -- Needing gear you cannot equip is never right. This reads red
            -- tooltip text, and a custom server that colours its own
            -- requirement lines red will trip it -- turn requireUsable off if
            -- /ar trace shows that happening.
            if self.db.requireUsable then
                local unusable, why = self:IsUnusable(ctx.link)
                if unusable then
                    self:Debug("armor type selected but item is unusable: " .. tostring(why))
                    return
                end
            end
            return ACT.NEED, ("armor type %s"):format(atype)
        end

        local action = ctx.bindOnPickUp and self.db.wrongArmorBoPAction
                                        or  self.db.wrongArmorBoEAction
        return NamedAction(action), ("%s not selected"):format(atype)
    end,
}

-- 90 -- Everything else you can equip: weapons, and armor with no type of its
--       own (cloaks, rings, necks, trinkets, shields, relics). Typed armor was
--       already settled at 89.
A:RegisterRule{
    key = "usableGear", label = "Other usable gear", priority = 90,
    fn = function(self, ctx)
        if ctx.itemClass ~= LC.ARMOR and ctx.itemClass ~= LC.WEAPON then return end
        if ctx.itemClass == LC.ARMOR and ctx.itemSubClass
           and A.ARMOR_TYPES[ctx.itemSubClass] then return end

        if self.db.requireUsable then
            local unusable, why = self:IsUnusable(ctx.link)
            if unusable then
                self:Debug("gear rule declined: red tooltip line '" .. tostring(why) .. "'")
                return
            end
        end

        return ACT.NEED, "usable gear"
    end,
}

-- 100 -- Gear you cannot wear. Greed it for the vendor value / shards.
A:RegisterRule{
    key = "unusable", label = "Unusable gear", priority = 100,
    fn = function(self, ctx)
        if ctx.itemClass ~= LC.ARMOR and ctx.itemClass ~= LC.WEAPON then return end
        local unusable, why = self:IsUnusable(ctx.link)
        if unusable then
            return NamedAction(self.db.unusableAction), "unusable (" .. tostring(why) .. ")"
        end
    end,
}

-- 110 -- Lockboxes.
A:RegisterRule{
    key = "lockbox", label = "Lockboxes", priority = 110,
    fn = function(self, ctx)
        if self:IsLockbox(ctx.link, ctx.name, ctx.itemClass, ctx.itemSubClass) then
            return NamedAction(self.db.lockboxAction), "lockbox"
        end
    end,
}

-- 120 -- Mats, flasks, gems, glyphs.
A:RegisterRule{
    key = "tradeGoods", label = "Trade goods & consumables", priority = 120,
    fn = function(self, ctx)
        if A.GREEDABLE_CLASSES[ctx.itemClass] then
            return NamedAction(self.db.tradeGoodsAction), "tradeable (" .. tostring(ctx.itemClass) .. ")"
        end
    end,
}

-- 130 -- Anything BoE has resale value.
A:RegisterRule{
    key = "boe", label = "Bind-on-equip", priority = 130,
    fn = function(self, ctx)
        -- Without item data the gear rules above could not run, so greeding
        -- here would be deciding on a coin flip. Fall through to the fallback.
        if not ctx.itemClass then return end
        if not ctx.bindOnPickUp and (ctx.quality or 0) >= self.db.boeQualityMin then
            return NamedAction(self.db.boeAction), "BoE"
        end
    end,
}

-- 999 -- Nothing matched.
A:RegisterRule{
    key = "fallback", label = "Fallback for everything else", priority = 999,
    fn = function(self)
        return NamedAction(self.db.fallbackAction), "no rule matched"
    end,
}
