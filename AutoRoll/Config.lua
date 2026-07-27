--=========================================================================
-- AutoRoll :: Config.lua
-- Defaults, saved-variable plumbing, per-character profiles.
--=========================================================================

AutoRoll = AutoRoll or {}
local A = AutoRoll

A.addonName = "AutoRoll"
A.version   = "2.0"

--- Roll actions accepted by RollOnLoot(rollID, action).
--  0/1/2 are guaranteed on 3.3.5a. 3 (disenchant) is a Cataclysm-era value
--  that some custom cores backport -- it is gated behind db.allowDisenchant
--  AND a runtime capability probe, so it is inert unless you turn it on.
A.ACTION = { NONE = -1, PASS = 0, NEED = 1, GREED = 2, DISENCHANT = 3 }

A.ACTION_NAME = {
    [-1] = "IGNORE", [0] = "PASS", [1] = "NEED", [2] = "GREED", [3] = "DISENCHANT",
}
A.ACTION_COLOR = {
    [-1] = "|cff808080", [0] = "|cff9d9d9d", [1] = "|cff1eff00",
    [2]  = "|cff0070dd", [3]  = "|cffa335ee",
}

--=========================================================================
-- Defaults
--=========================================================================

A.defaults = {
    enabled        = true,
    debug          = false,

    -- Seconds to wait after START_LOOT_ROLL before acting. Never set this to
    -- 0 on a live server: instant rolls are the single most obvious bot
    -- signature, and some cores drop rolls that arrive before the client has
    -- finished building the roll frame.
    rollDelay      = 1.5,

    onlyInInstance = false,  -- ignore rolls in the open world
    confirmBoP     = true,   -- auto-accept the "this will bind" popup
    allowDisenchant= false,  -- see note above
    announce       = false,  -- print every decision to chat
    historyLimit   = 250,

    -- Per-rule on/off switches. Keys match the rules registered in Rules.lua.
    rules = {
        manualQuality = true,
        blacklist     = true,
        passList      = true,
        needList      = true,
        greedList     = true,
        alreadyKnown  = true,
        recipe        = true,
        classToken    = true,
        duplicate     = true,
        gearType      = true,
        unusable      = true,
        lockbox       = true,
        tradeGoods    = true,
        boe           = true,
        fallback      = true,
    },

    -- Rule parameters
    manualQualityMin  = 5,        -- >= this quality: hands off entirely. 99 = never.

    requireUsable     = true,     -- never need gear the tooltip marks unusable

    -- Armor of a atype your class does not wear. Split by bind type because
    -- a BoE is worth money and a BoP is worth nothing to you.
    wrongGearBoEAction = "GREED",
    wrongGearBoPAction = "PASS",

    -- Which classes to roll gear for. Absent means "just my own class".
    -- needClasses = { PALADIN = true, WARRIOR = true }
    ignoreLevel = false,   -- derive armor as if level 80, for gearing alts

    -- Misc opt-ins layered on top of the class selection.
    miscArmor   = {},      -- extra armor types by name
    miscWeapons = false,   -- roll every weapon type
    miscOffhand = false,   -- roll shields and held-in-off-hand

    -- What to do with something you already own. NEED, GREED, PASS or IGNORE.
    duplicateAction          = "PASS",
    duplicateIncludeEquipped = false,   -- count what you are wearing too

    -- db.armorNeed and db.weaponNeed are deliberately absent here. Absent means
    -- "work it out from class and level"; the options panel writes a real table
    -- if you override.

    -- How many times to wait 0.3s for GetItemInfo to populate before giving up.
    itemInfoRetries   = 12,

    recipeAction      = "GREED",
    unusableAction    = "GREED",
    tradeGoodsAction  = "GREED",
    lockboxAction     = "GREED",
    boeAction         = "GREED",
    boeQualityMin     = 2,        -- only auto-greed BoE at/above this quality
    fallbackAction    = "PASS",

    -- Item ID lists
    blacklist = {},   -- never touch (leaves the roll frame up for you)
    needList  = {},
    greedList = {},
    passList  = {},
}

--=========================================================================
-- Utility
--=========================================================================

function A:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99AutoRoll|r: " .. tostring(msg))
end

function A:Debug(msg)
    if A.db and A.db.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99AutoRoll|r |cff808080dbg|r " .. tostring(msg))
    end
end

function A:DeepCopy(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for k, v in pairs(src) do out[k] = A:DeepCopy(v) end
    return out
end

--- Recursively add any missing default keys without clobbering user values.
function A:FillDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            A:FillDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end

function A:CharKey()
    return (UnitName("player") or "Unknown") .. " - " .. (GetRealmName() or "Unknown")
end

--=========================================================================
-- Profiles
--
-- AutoRollDB.profiles[name]  -> a settings table
-- AutoRollDB.charKeys[char]  -> which profile that character uses
--
-- Every character gets its own profile named after itself on first login.
-- Point two characters at the same profile name and they share settings
-- live -- no copying, no syncing.
--=========================================================================

--=========================================================================
-- Migration
--
-- Profiles persist across updates, and FillDefaults deliberately never
-- overwrites an existing value -- which means a renamed or removed setting
-- would otherwise sit in the saved variables forever, doing nothing.
--=========================================================================

A.DB_VERSION = 4

local function Migrate(profile)
    local from = profile.__version or 1

    if from < 2 then
        -- gearNeedMode and upgradeThreshold were folded into the armor type
        -- selection: picking a type is now the instruction to Need it.
        profile.gearNeedMode     = nil
        profile.upgradeThreshold = nil

        if profile.rules then
            profile.rules.upgrade = nil          -- renamed to usableGear
            if profile.rules.usableGear == nil then
                profile.rules.usableGear = true
            end
            -- Shipped disabled in v1; now on by default.
            profile.rules.tooHighLevel = true
        end
    end

    if from < 3 then
        -- Shields and relics became tickable armor types, and weapons gained a
        -- type list of their own. A player who had already customised their
        -- armor set has no entry for the new types, and absent means unticked
        -- -- so top those up from the class default rather than silently
        -- passing on every shield.
        if profile.armorNeed and A.GetArmorDefaultSet then
            for atype, wanted in pairs(A:GetArmorDefaultSet()) do
                if A.ARMOR_TYPES_ADDED_V3 and A.ARMOR_TYPES_ADDED_V3[atype]
                   and profile.armorNeed[atype] == nil then
                    profile.armorNeed[atype] = wanted
                end
            end
        end
        if profile.rules then profile.rules.weaponType = true end
    end

    if from < 4 then
        -- Armor and weapon type lists collapsed into class selection. The old
        -- per-type tables cannot be mapped back onto classes reliably -- two
        -- classes share Plate -- so they are dropped and the selection resets
        -- to the player's own class, which is what almost everyone had anyway.
        profile.armorNeed  = nil
        profile.weaponNeed = nil
        profile.wrongGearBoEAction = profile.wrongArmorBoEAction or "GREED"
        profile.wrongGearBoPAction = profile.wrongArmorBoPAction or "PASS"
        profile.wrongArmorBoEAction  = nil
        profile.wrongArmorBoPAction  = nil
        profile.wrongWeaponBoEAction = nil
        profile.wrongWeaponBoPAction = nil

        if profile.rules then
            profile.rules.armorType  = nil
            profile.rules.weaponType = nil
            profile.rules.usableGear = nil
            if profile.rules.gearType == nil then profile.rules.gearType = true end
        end
    end

    profile.__version = A.DB_VERSION
end

function A:InitDB()
    AutoRollDB     = AutoRollDB or {}
    AutoRollCharDB = AutoRollCharDB or {}

    local g = AutoRollDB
    g.profiles = g.profiles or {}
    g.charKeys = g.charKeys or {}

    local char = A:CharKey()
    local name = g.charKeys[char]

    if not name or not g.profiles[name] then
        name = char
        g.charKeys[char] = name
    end
    if not g.profiles[name] then
        g.profiles[name] = A:DeepCopy(A.defaults)
    end

    A:FillDefaults(g.profiles[name], A.defaults)
    Migrate(g.profiles[name])
    A.db          = g.profiles[name]
    A.profileName = name

    AutoRollCharDB.history = AutoRollCharDB.history or {}
end

function A:GetProfileNames()
    local out = {}
    for name in pairs(AutoRollDB.profiles) do table.insert(out, name) end
    table.sort(out)
    return out
end

function A:SetProfile(name)
    if not name or name == "" then return false end
    if not AutoRollDB.profiles[name] then
        AutoRollDB.profiles[name] = A:DeepCopy(A.defaults)
    end
    A:FillDefaults(AutoRollDB.profiles[name], A.defaults)
    Migrate(AutoRollDB.profiles[name])
    AutoRollDB.charKeys[A:CharKey()] = name
    A.db          = AutoRollDB.profiles[name]
    A.profileName = name
    if A.RefreshOptions then A:RefreshOptions() end
    return true
end

function A:CopyProfile(fromName)
    local src = AutoRollDB.profiles[fromName]
    if not src or fromName == A.profileName then return false end
    AutoRollDB.profiles[A.profileName] = A:DeepCopy(src)
    A.db = AutoRollDB.profiles[A.profileName]
    if A.RefreshOptions then A:RefreshOptions() end
    return true
end

function A:DeleteProfile(name)
    if name == A.profileName then return false, "cannot delete the active profile" end
    if not AutoRollDB.profiles[name] then return false, "no such profile" end
    AutoRollDB.profiles[name] = nil
    for char, prof in pairs(AutoRollDB.charKeys) do
        if prof == name then AutoRollDB.charKeys[char] = nil end
    end
    return true
end

function A:ResetProfile()
    AutoRollDB.profiles[A.profileName] = A:DeepCopy(A.defaults)
    A.db = AutoRollDB.profiles[A.profileName]
    if A.RefreshOptions then A:RefreshOptions() end
end

--=========================================================================
-- Item ID list helpers (shared by slash commands and the options panel)
--=========================================================================

local VALID_LISTS = { blacklist = true, needList = true, greedList = true, passList = true }

function A:ListAdd(listName, itemID)
    if not VALID_LISTS[listName] then return false end
    local list = A.db[listName]
    for _, id in ipairs(list) do
        if id == itemID then return false, "already present" end
    end
    table.insert(list, itemID)
    return true
end

function A:ListRemove(listName, itemID)
    if not VALID_LISTS[listName] then return false end
    local list = A.db[listName]
    for i = #list, 1, -1 do
        if list[i] == itemID then
            table.remove(list, i)
            return true
        end
    end
    return false, "not in list"
end

function A:ListContains(listName, itemID)
    local list = A.db and A.db[listName]
    if not list then return false end
    for _, id in ipairs(list) do
        if id == itemID then return true end
    end
    return false
end

--- Accepts an item link, a numeric ID, an ID as a string, or an exact name
--  that is already in the client's item cache.
function A:ResolveItemID(input)
    if not input then return nil end
    if type(input) == "number" then return input end

    input = tostring(input)

    local fromLink = tonumber(input:match("item:(%d+)"))
    if fromLink then return fromLink end

    local direct = tonumber(input:match("^%s*(%d+)%s*$"))
    if direct then return direct end

    local _, link = GetItemInfo(input)
    if link then return tonumber(link:match("item:(%d+)")) end

    return nil
end
