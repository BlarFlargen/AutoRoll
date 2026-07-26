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

local SIDES = { "Left", "Right" }

--- Walks both columns of every line.
--
--  Reading only TextLeft is a trap. Equipment tooltips put the equip slot on
--  the left of line 2 ("Two-Hand", "Main Hand", "Chest") and the item's type
--  on the RIGHT ("Sword", "Plate") -- and when you lack the proficiency, it is
--  the right-hand string that turns red. A left-only scan therefore catches
--  "Requires Level 80" but silently misses every weapon and armor
--  proficiency restriction in the game.
local function ScanLines(link, callback)
    local tt = ScanLink(link)
    for i = 2, tt:NumLines() do
        for s = 1, #SIDES do
            local fs = _G["AutoRollScanTooltipText" .. SIDES[s] .. i]
            if fs then
                local text = fs:GetText()
                if text and text ~= "" then
                    local r, g, b = fs:GetTextColor()
                    local result = callback(text, r, g, b, i)
                    if result ~= nil then
                        tt:Hide()
                        return result
                    end
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
-- Equippable types
--
-- Armor type is not a client-enforced restriction, so any class can equip any
-- of the four types and nothing turns red. Weapon proficiency IS enforced and
-- does turn red, but relying on that alone means trusting a tooltip scrape for
-- a decision worth real loot. Both get an explicit class table instead, with
-- the red-text check kept as a second line of defence.
--
-- The type NAMES are read from the client rather than hardcoded, so matching
-- works on any locale: both these strings and ctx.itemSubClass come from the
-- same source. Only the class defaults depend on the index order below, and
-- those are user-correctable in the options panel.
--=========================================================================

local LA, LW = {}, {}
do
    local a = { GetAuctionItemSubClasses(2) }   -- 2 = Armor
    LA.MISC,   LA.CLOTH,  LA.LEATHER, LA.MAIL,  LA.PLATE  = a[1], a[2], a[3], a[4], a[5]
    LA.SHIELD, LA.LIBRAM, LA.IDOL,    LA.TOTEM, LA.SIGIL  = a[6], a[7], a[8], a[9], a[10]

    local w = { GetAuctionItemSubClasses(1) }   -- 1 = Weapon
    LW.AXE1,  LW.AXE2,   LW.BOW,   LW.GUN     = w[1],  w[2],  w[3],  w[4]
    LW.MACE1, LW.MACE2,  LW.POLE,  LW.SWORD1  = w[5],  w[6],  w[7],  w[8]
    LW.SWORD2,LW.STAFF,  LW.FIST,  LW.WMISC   = w[9],  w[10], w[11], w[12]
    LW.DAGGER,LW.THROWN, LW.XBOW,  LW.WAND    = w[13], w[14], w[15], w[16]
    LW.POLE_FISH                              = w[17]

    -- If the indices are not what we expect on this client the entries collapse
    -- into duplicates or nils. Fall back rather than silently misclassifying
    -- every drop.
    local function sane(list)
        local seen = {}
        for _, v in ipairs(list) do
            if type(v) ~= "string" or v == "" or seen[v] then return false end
            seen[v] = true
        end
        return true
    end

    if not sane({ LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE, LA.SHIELD,
                  LA.LIBRAM, LA.IDOL, LA.TOTEM, LA.SIGIL }) then
        LA.MISC,   LA.CLOTH,  LA.LEATHER, LA.MAIL,  LA.PLATE =
            "Miscellaneous", "Cloth", "Leather", "Mail", "Plate"
        LA.SHIELD, LA.LIBRAM, LA.IDOL,    LA.TOTEM, LA.SIGIL =
            "Shields", "Librams", "Idols", "Totems", "Sigils"
        LA.fellBack = true
    end

    if not sane({ LW.AXE1, LW.AXE2, LW.BOW, LW.GUN, LW.MACE1, LW.MACE2, LW.POLE,
                  LW.SWORD1, LW.SWORD2, LW.STAFF, LW.FIST, LW.DAGGER,
                  LW.THROWN, LW.XBOW, LW.WAND }) then
        LW.AXE1,   LW.AXE2,  LW.BOW,  LW.GUN   =
            "One-Handed Axes", "Two-Handed Axes", "Bows", "Guns"
        LW.MACE1,  LW.MACE2, LW.POLE, LW.SWORD1 =
            "One-Handed Maces", "Two-Handed Maces", "Polearms", "One-Handed Swords"
        LW.SWORD2, LW.STAFF,  LW.FIST, LW.WMISC =
            "Two-Handed Swords", "Staves", "Fist Weapons", "Miscellaneous"
        LW.DAGGER, LW.THROWN, LW.XBOW, LW.WAND  =
            "Daggers", "Thrown", "Crossbows", "Wands"
        LW.POLE_FISH = "Fishing Poles"
        LW.fellBack = true
    end
end
A.LA, A.LW = LA, LW

-- Armor with no type of its own -- cloaks, rings, necks, trinkets -- is
-- wearable by everyone and is deliberately absent here.
A.ARMOR_TYPE_ORDER = {
    LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE,
    LA.SHIELD, LA.LIBRAM, LA.IDOL, LA.TOTEM, LA.SIGIL,
}
A.WEAPON_TYPE_ORDER = {
    LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2,
    LW.DAGGER, LW.FIST, LW.POLE, LW.STAFF,
    LW.BOW, LW.XBOW, LW.GUN, LW.THROWN, LW.WAND,
}

A.ARMOR_TYPES, A.WEAPON_TYPES = {}, {}
for _, t in ipairs(A.ARMOR_TYPE_ORDER)  do A.ARMOR_TYPES[t]  = true end
for _, t in ipairs(A.WEAPON_TYPE_ORDER) do A.WEAPON_TYPES[t] = true end

-- Shields and relics were added after the first release; migration uses this
-- to top up a set the player had already customised.
A.ARMOR_TYPES_ADDED_V3 = {
    [LA.SHIELD] = true, [LA.LIBRAM] = true,
    [LA.IDOL]   = true, [LA.TOTEM]  = true, [LA.SIGIL] = true,
}

-- top: the class's main armor type. low: what it wears before level 40.
-- extra: shields and relics, which have no level gate.
local CLASS_ARMOR = {
    WARRIOR     = { top = LA.PLATE,   low = LA.MAIL,    extra = { LA.SHIELD } },
    PALADIN     = { top = LA.PLATE,   low = LA.MAIL,    extra = { LA.SHIELD, LA.LIBRAM } },
    DEATHKNIGHT = { top = LA.PLATE,                     extra = { LA.SIGIL } },
    HUNTER      = { top = LA.MAIL,    low = LA.LEATHER },
    SHAMAN      = { top = LA.MAIL,    low = LA.LEATHER, extra = { LA.SHIELD, LA.TOTEM } },
    ROGUE       = { top = LA.LEATHER },
    DRUID       = { top = LA.LEATHER,                   extra = { LA.IDOL } },
    PRIEST      = { top = LA.CLOTH },
    MAGE        = { top = LA.CLOTH },
    WARLOCK     = { top = LA.CLOTH },
}

local CLASS_WEAPONS = {
    WARRIOR     = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2,
                    LW.DAGGER, LW.FIST, LW.POLE, LW.STAFF,
                    LW.BOW, LW.XBOW, LW.GUN, LW.THROWN },
    PALADIN     = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2, LW.POLE },
    DEATHKNIGHT = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2, LW.POLE },
    HUNTER      = { LW.AXE1, LW.AXE2, LW.SWORD1, LW.SWORD2, LW.POLE, LW.STAFF,
                    LW.DAGGER, LW.FIST, LW.BOW, LW.XBOW, LW.GUN, LW.THROWN },
    ROGUE       = { LW.AXE1, LW.MACE1, LW.SWORD1, LW.DAGGER, LW.FIST,
                    LW.BOW, LW.XBOW, LW.GUN, LW.THROWN },
    SHAMAN      = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.STAFF, LW.FIST, LW.DAGGER },
    DRUID       = { LW.MACE1, LW.MACE2, LW.POLE, LW.STAFF, LW.FIST, LW.DAGGER },
    PRIEST      = { LW.MACE1, LW.STAFF, LW.DAGGER, LW.WAND },
    MAGE        = { LW.SWORD1, LW.STAFF, LW.DAGGER, LW.WAND },
    WARLOCK     = { LW.SWORD1, LW.STAFF, LW.DAGGER, LW.WAND },
}

local function PlayerClass()
    local _, token = UnitClass("player")
    return token or ""
end

--- What this class would roll Need on, ignoring any manual override.
function A:GetArmorDefaultSet()
    local def = CLASS_ARMOR[PlayerClass()]
    local set = {}
    if not def then return set end

    if def.top then set[def.top] = true end
    if def.low and (UnitLevel("player") or 80) < 40 then set[def.low] = true end
    for _, t in ipairs(def.extra or {}) do set[t] = true end
    return set
end

function A:GetWeaponDefaultSet()
    local set = {}
    for _, t in ipairs(CLASS_WEAPONS[PlayerClass()] or {}) do set[t] = true end
    return set
end

--- db.armorNeed / db.weaponNeed nil means "work it out from class and level";
--  a table pins the choice manually.
function A:GetArmorNeedSet()
    if A.db and A.db.armorNeed then return A.db.armorNeed end
    return A:GetArmorDefaultSet()
end

function A:GetWeaponNeedSet()
    if A.db and A.db.weaponNeed then return A.db.weaponNeed end
    return A:GetWeaponDefaultSet()
end

--- Materialise an auto set into a real table so it can be edited.
local function Materialise(key, defaultFn)
    if not A.db[key] then
        local copy = {}
        for k, v in pairs(defaultFn(A)) do copy[k] = v end
        A.db[key] = copy
    end
    return A.db[key]
end

function A:SetArmorType(atype, wanted)
    Materialise("armorNeed", A.GetArmorDefaultSet)[atype] = wanted or nil
end

function A:SetWeaponType(wtype, wanted)
    Materialise("weaponNeed", A.GetWeaponDefaultSet)[wtype] = wanted or nil
end

function A:ResetArmorTypes()  A.db.armorNeed  = nil end
function A:ResetWeaponTypes() A.db.weaponNeed = nil end

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

-- 88 / 89 -- Weapon and armor type. This is where gear is decided.
--
--   Ticking a type in the options IS the instruction to Need it, so there is
--   no separate "should I need gear" setting to keep in sync. An unticked type
--   falls to the BoE/BoP actions.
--
--   Both sit ahead of the BoE rule at 130, so a bind-on-equip drop is judged
--   by what it is before anyone treats it as generic loot.

--- Shared body: ticked -> Need (if usable), unticked -> the configured action.
local function TypedGearRule(self, ctx, typeSet, needSet, boeKey, bopKey, label)
    local itype = ctx.itemSubClass
    if not itype or not typeSet[itype] then return end          -- untyped, not ours

    if needSet[itype] then
        -- Needing gear you cannot equip is never right. This reads red tooltip
        -- text, and a custom server that colours its own requirement lines red
        -- will trip it -- turn requireUsable off if /ar trace shows that.
        if self.db.requireUsable then
            local unusable, why = self:IsUnusable(ctx.link)
            if unusable then
                self:Debug(label .. " ticked but item is unusable: " .. tostring(why))
                return
            end
        end
        return ACT.NEED, ("%s %s"):format(label, itype)
    end

    local action = ctx.bindOnPickUp and self.db[bopKey] or self.db[boeKey]
    return NamedAction(action), ("%s not ticked"):format(itype)
end

A:RegisterRule{
    key = "weaponType", label = "Weapon type", priority = 88,
    fn = function(self, ctx)
        if ctx.itemClass ~= LC.WEAPON then return end
        return TypedGearRule(self, ctx, A.WEAPON_TYPES, self:GetWeaponNeedSet(),
                             "wrongWeaponBoEAction", "wrongWeaponBoPAction", "weapon type")
    end,
}

A:RegisterRule{
    key = "armorType", label = "Armor type", priority = 89,
    fn = function(self, ctx)
        if ctx.itemClass ~= LC.ARMOR then return end
        return TypedGearRule(self, ctx, A.ARMOR_TYPES, self:GetArmorNeedSet(),
                             "wrongArmorBoEAction", "wrongArmorBoPAction", "armor type")
    end,
}

-- 90 -- Armor with no type of its own: cloaks, rings, necks, trinkets. Every
--       class can wear these, so there is nothing to tick.
A:RegisterRule{
    key = "usableGear", label = "Cloaks, rings, trinkets", priority = 90,
    fn = function(self, ctx)
        if ctx.itemClass ~= LC.ARMOR then return end                      -- weapons: rule 88
        if ctx.itemSubClass and A.ARMOR_TYPES[ctx.itemSubClass] then return end  -- typed: rule 89

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
