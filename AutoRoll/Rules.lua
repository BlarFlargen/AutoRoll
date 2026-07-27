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

-- Exported so rules in ServerRules.lua can scan tooltips without
-- reimplementing the two-column walk.
A.ScanTooltip = ScanLines

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
--=========================================================================
-- Class-based gear selection
--
-- You pick CLASSES, not armor types. Everything a class can equip -- its
-- armor type, its weapons, its shields and relics -- is derived from that.
-- Pick several to gear an alt or an offspec alongside your own.
--
-- Armor type is level-gated and this is where the old code was wrong: a
-- warrior does not learn Plate until level 40 and wears Mail before that.
-- Treating Plate as "the warrior type" and Mail as a mere fallback meant a
-- low-level warrior rolled on armor it could not wear and skipped the armor
-- it could. So the table lists the level each type is learned at, and the
-- derivation picks the highest one you actually qualify for.
--
-- Weapon and shield proficiency IS enforced by the client, so red tooltip
-- text catches those independently. Armor type is not enforced -- any class
-- can equip any type -- which is why it needs this table at all.
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
        LA.MISC, LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE =
            "Miscellaneous", "Cloth", "Leather", "Mail", "Plate"
        LA.SHIELD, LA.LIBRAM, LA.IDOL, LA.TOTEM, LA.SIGIL =
            "Shields", "Librams", "Idols", "Totems", "Sigils"
        LA.fellBack = true
    end

    if not sane({ LW.AXE1, LW.AXE2, LW.BOW, LW.GUN, LW.MACE1, LW.MACE2, LW.POLE,
                  LW.SWORD1, LW.SWORD2, LW.STAFF, LW.FIST, LW.DAGGER,
                  LW.THROWN, LW.XBOW, LW.WAND }) then
        LW.AXE1, LW.AXE2, LW.BOW, LW.GUN =
            "One-Handed Axes", "Two-Handed Axes", "Bows", "Guns"
        LW.MACE1, LW.MACE2, LW.POLE, LW.SWORD1 =
            "One-Handed Maces", "Two-Handed Maces", "Polearms", "One-Handed Swords"
        LW.SWORD2, LW.STAFF, LW.FIST, LW.WMISC =
            "Two-Handed Swords", "Staves", "Fist Weapons", "Miscellaneous"
        LW.DAGGER, LW.THROWN, LW.XBOW, LW.WAND =
            "Daggers", "Thrown", "Crossbows", "Wands"
        LW.fellBack = true
    end
end
A.LA, A.LW = LA, LW

A.ARMOR_TYPE_ORDER  = { LA.CLOTH, LA.LEATHER, LA.MAIL, LA.PLATE }
A.RELIC_TYPE_ORDER  = { LA.LIBRAM, LA.IDOL, LA.TOTEM, LA.SIGIL }
A.WEAPON_TYPE_ORDER = {
    LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2,
    LW.DAGGER, LW.FIST, LW.POLE, LW.STAFF,
    LW.BOW, LW.XBOW, LW.GUN, LW.THROWN, LW.WAND,
}

A.ARMOR_TYPES, A.WEAPON_TYPES, A.RELIC_TYPES = {}, {}, {}
for _, t in ipairs(A.ARMOR_TYPE_ORDER)  do A.ARMOR_TYPES[t]  = true end
for _, t in ipairs(A.WEAPON_TYPE_ORDER) do A.WEAPON_TYPES[t] = true end
for _, t in ipairs(A.RELIC_TYPE_ORDER)  do A.RELIC_TYPES[t]  = true end

A.CLASS_ORDER = {
    "WARRIOR", "PALADIN", "DEATHKNIGHT", "HUNTER", "SHAMAN",
    "ROGUE", "DRUID", "PRIEST", "MAGE", "WARLOCK",
}

A.CLASS_LABEL = {
    WARRIOR = "Warrior", PALADIN = "Paladin", DEATHKNIGHT = "Death Knight",
    HUNTER = "Hunter", SHAMAN = "Shaman", ROGUE = "Rogue", DRUID = "Druid",
    PRIEST = "Priest", MAGE = "Mage", WARLOCK = "Warlock",
}

-- armor: { { level = N, type = T }, ... }, highest qualifying level wins.
local CLASS_GEAR = {
    WARRIOR = {
        armor  = { { level = 40, type = LA.PLATE }, { level = 1, type = LA.MAIL } },
        shield = true,
        weapons = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2,
                    LW.DAGGER, LW.FIST, LW.POLE, LW.STAFF,
                    LW.BOW, LW.XBOW, LW.GUN, LW.THROWN },
    },
    PALADIN = {
        armor  = { { level = 40, type = LA.PLATE }, { level = 1, type = LA.MAIL } },
        shield = true, relics = { LA.LIBRAM },
        weapons = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2, LW.POLE },
    },
    DEATHKNIGHT = {
        armor  = { { level = 1, type = LA.PLATE } },
        relics = { LA.SIGIL },
        weapons = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.SWORD1, LW.SWORD2, LW.POLE },
    },
    HUNTER = {
        armor  = { { level = 40, type = LA.MAIL }, { level = 1, type = LA.LEATHER } },
        weapons = { LW.AXE1, LW.AXE2, LW.SWORD1, LW.SWORD2, LW.POLE, LW.STAFF,
                    LW.DAGGER, LW.FIST, LW.BOW, LW.XBOW, LW.GUN, LW.THROWN },
    },
    SHAMAN = {
        armor  = { { level = 40, type = LA.MAIL }, { level = 1, type = LA.LEATHER } },
        shield = true, relics = { LA.TOTEM },
        weapons = { LW.AXE1, LW.AXE2, LW.MACE1, LW.MACE2, LW.STAFF, LW.FIST, LW.DAGGER },
    },
    ROGUE = {
        armor  = { { level = 1, type = LA.LEATHER } },
        weapons = { LW.AXE1, LW.MACE1, LW.SWORD1, LW.DAGGER, LW.FIST,
                    LW.BOW, LW.XBOW, LW.GUN, LW.THROWN },
    },
    DRUID = {
        armor  = { { level = 1, type = LA.LEATHER } },
        relics = { LA.IDOL },
        weapons = { LW.MACE1, LW.MACE2, LW.POLE, LW.STAFF, LW.FIST, LW.DAGGER },
    },
    PRIEST = {
        armor  = { { level = 1, type = LA.CLOTH } },
        weapons = { LW.MACE1, LW.STAFF, LW.DAGGER, LW.WAND },
    },
    MAGE = {
        armor  = { { level = 1, type = LA.CLOTH } },
        weapons = { LW.SWORD1, LW.STAFF, LW.DAGGER, LW.WAND },
    },
    WARLOCK = {
        armor  = { { level = 1, type = LA.CLOTH } },
        weapons = { LW.SWORD1, LW.STAFF, LW.DAGGER, LW.WAND },
    },
}
A.CLASS_GEAR = CLASS_GEAR

local function PlayerClass()
    local _, token = UnitClass("player")
    return token or ""
end
A.PlayerClass = PlayerClass

--- The armor type a class wears at a given level. Highest qualifying entry.
function A:ArmorTypeForClass(token, level)
    local def = CLASS_GEAR[token]
    if not def then return nil end

    local best, bestLevel
    for _, entry in ipairs(def.armor) do
        if level >= entry.level and (not bestLevel or entry.level > bestLevel) then
            best, bestLevel = entry.type, entry.level
        end
    end
    return best
end

--- Which classes we are rolling for. Absent means "just mine".
function A:GetNeedClasses()
    if A.db and A.db.needClasses and next(A.db.needClasses) then
        return A.db.needClasses
    end
    local mine = PlayerClass()
    return CLASS_GEAR[mine] and { [mine] = true } or {}
end

function A:SetNeedClass(token, wanted)
    if not A.db.needClasses then
        local copy = {}
        for k, v in pairs(A:GetNeedClasses()) do copy[k] = v end
        A.db.needClasses = copy
    end
    A.db.needClasses[token] = wanted or nil
    if not next(A.db.needClasses) then A.db.needClasses = nil end
end

function A:ResetNeedClasses() A.db.needClasses = nil end

--- Everything the selected classes can use, plus the misc opt-ins.
--  Returns armorSet, weaponSet, relicSet, offhandWanted.
function A:GetNeedSets()
    local armor, weapons, relics = {}, {}, {}
    local offhand = false

    local level = A.db.ignoreLevel and 80 or (UnitLevel("player") or 80)

    for token in pairs(A:GetNeedClasses()) do
        local def = CLASS_GEAR[token]
        if def then
            local atype = A:ArmorTypeForClass(token, level)
            if atype then armor[atype] = true end
            for _, w in ipairs(def.weapons or {}) do weapons[w] = true end
            for _, r in ipairs(def.relics  or {}) do relics[r]  = true end
            if def.shield then offhand = true end
        end
    end

    -- Misc opt-ins sit on top of whatever the classes gave us.
    for atype, on in pairs(A.db.miscArmor or {}) do
        if on then armor[atype] = true end
    end
    if A.db.miscWeapons then
        for _, w in ipairs(A.WEAPON_TYPE_ORDER) do weapons[w] = true end
    end
    if A.db.miscOffhand then offhand = true end

    return armor, weapons, relics, offhand
end

function A:SetMiscArmor(atype, wanted)
    A.db.miscArmor = A.db.miscArmor or {}
    A.db.miscArmor[atype] = wanted or nil
end

--- Shields and held-in-off-hand items. Shields are an armor subclass;
--  held-in-off-hand is a Miscellaneous armor item identified by equip slot.
function A:IsOffhandItem(ctx)
    if ctx.itemSubClass == LA.SHIELD then return true end
    if ctx.equipSlot == "INVTYPE_HOLDABLE" then return true end
    return false
end

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

--- Bags do not include what you are wearing, so this is a separate question.
function A:IsEquipped(itemID)
    for slotID = 1, 19 do
        local link = GetInventoryItemLink("player", slotID)
        if link and tonumber(link:match("item:(%d+)")) == itemID then
            return true, slotID
        end
    end
    return false
end

--- True when you already own a copy, honouring the include-equipped setting.
--  Returns the reason text as a second value so rules and /ar trace agree.
function A:AlreadyOwn(itemID)
    local inBags = A:CountInBags(itemID)
    if inBags > 0 then
        return true, (inBags == 1) and "1 already in your bags"
                                    or (inBags .. " already in your bags")
    end
    if A.db and A.db.duplicateIncludeEquipped and A:IsEquipped(itemID) then
        return true, "one already equipped"
    end
    return false
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

-- 87 -- Items you already own.
--
--       Sits ahead of the type rules at 88/89 so a second copy of something is
--       judged on the fact that you already have one, rather than on what it
--       is. Still behind the explicit lists, so /ar need add always wins.
A:RegisterRule{
    key = "duplicate", label = "Already have one", priority = 87,
    fn = function(self, ctx)
        local own, why = self:AlreadyOwn(ctx.itemID)
        if not own then return end
        return NamedAction(self.db.duplicateAction), why
    end,
}

-- 89 -- Gear, judged against the classes you selected.
--
--       One rule for armor, weapons, relics and offhands: they all reduce to
--       "does any class I roll for use this". Ahead of the BoE rule at 130, so
--       a bind-on-equip drop is judged by what it is rather than as loot.
A:RegisterRule{
    key = "gearType", label = "Gear for my classes", priority = 89,
    fn = function(self, ctx)
        if ctx.itemClass ~= LC.ARMOR and ctx.itemClass ~= LC.WEAPON then return end

        local armorSet, weaponSet, relicSet, offhandWanted = self:GetNeedSets()

        local wanted, what
        if ctx.itemClass == LC.WEAPON then
            if not ctx.itemSubClass or not A.WEAPON_TYPES[ctx.itemSubClass] then
                return                              -- fishing pole, misc: not gear
            end
            wanted, what = weaponSet[ctx.itemSubClass], ctx.itemSubClass

        elseif self:IsOffhandItem(ctx) then
            wanted, what = offhandWanted, "offhand"

        elseif A.RELIC_TYPES[ctx.itemSubClass or ""] then
            wanted, what = relicSet[ctx.itemSubClass], ctx.itemSubClass

        elseif A.ARMOR_TYPES[ctx.itemSubClass or ""] then
            wanted, what = armorSet[ctx.itemSubClass], ctx.itemSubClass

        else
            -- Cloaks, rings, necks, trinkets: no type, everyone can wear them.
            if self.db.requireUsable then
                local unusable, why = self:IsUnusable(ctx.link)
                if unusable then
                    self:Debug("gear declined: " .. tostring(why))
                    return
                end
            end
            return ACT.NEED, "usable gear"
        end

        if wanted then
            -- Needing gear you cannot equip is never right. Reads red tooltip
            -- text; a server that colours its own requirement lines red will
            -- trip this, so /ar trace reports which line did it.
            if self.db.requireUsable then
                local unusable, why = self:IsUnusable(ctx.link)
                if unusable then
                    self:Debug("gear selected but unusable: " .. tostring(why))
                    return
                end
            end
            return ACT.NEED, ("gear: %s"):format(what)
        end

        local action = ctx.bindOnPickUp and self.db.wrongGearBoPAction
                                        or  self.db.wrongGearBoEAction
        return NamedAction(action), ("%s not selected"):format(what)
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
