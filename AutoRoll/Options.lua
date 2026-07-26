--=========================================================================
-- AutoRoll :: Options.lua
--
-- Interface Options panel. Built once, on ADDON_LOADED, after the database
-- exists -- widgets read their initial state straight from the profile.
--
-- The panel body is a real ScrollFrame. The Interface Options container is a
-- fixed ~620x550 and does not scroll for you, so any panel taller than that
-- just runs off the bottom with no way to reach the controls. Rule count is
-- open-ended -- every rule registered in ServerRules.lua adds another row --
-- so the content has to be scrollable rather than merely "tall enough today".
--=========================================================================

local A = AutoRoll

local refreshers = {}   -- functions that pull widget state back from the db
local uid = 0
local function NextName(prefix)
    uid = uid + 1
    return "AutoRollOpt" .. prefix .. uid
end

local CONTENT_WIDTH = 560

--=========================================================================
-- Widget factories. All take an explicit parent so they can be built into
-- the scroll content frame rather than the panel itself.
--=========================================================================

local function MakeCheck(parent, label, tooltip, x, y, get, set)
    local name  = NextName("Check")
    local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    check:SetWidth(24)
    check:SetHeight(24)
    check:SetPoint("TOPLEFT", x, y)

    local text = _G[name .. "Text"]
    text:SetText(label)
    text:SetFontObject(GameFontHighlightSmall)

    check.tooltipText = tooltip
    check:SetScript("OnEnter", function(self)
        if not self.tooltipText then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipText, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    check:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)

    table.insert(refreshers, function() check:SetChecked(get()) end)
    return check
end

local function MakeSlider(parent, label, tooltip, x, y, minV, maxV, step, get, set, fmt)
    local name   = NextName("Slider")
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetWidth(260)
    slider:SetPoint("TOPLEFT", x + 6, y)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step)

    _G[name .. "Low"]:SetText(tostring(minV))
    _G[name .. "High"]:SetText(tostring(maxV))

    local caption = _G[name .. "Text"]
    local function Caption(v)
        caption:SetText(label .. ": |cffffffff" .. (fmt and fmt(v) or tostring(v)) .. "|r")
    end

    slider.tooltipText = tooltip
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / step + 0.5) * step
        Caption(value)
        if not self.loading then set(value) end
    end)

    table.insert(refreshers, function()
        slider.loading = true
        slider:SetValue(get())
        Caption(get())
        slider.loading = false
    end)
    return slider
end

--- Generic dropdown over a fixed list of string values stored at db[key].
local function MakeDropdown(parent, label, x, y, key, choices, width, onSet)
    local name = NextName("Drop")
    local dd   = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", x, y)
    UIDropDownMenu_SetWidth(dd, width or 110)

    local caption = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 20, 2)
    caption:SetText(label)

    UIDropDownMenu_Initialize(dd, function()
        for _, choice in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = choice.text or choice
            info.value   = choice.value or choice
            info.checked = (A.db[key] == (choice.value or choice))
            info.func    = function(self)
                A.db[key] = self.value
                UIDropDownMenu_SetText(dd, self:GetText())
                CloseDropDownMenus()
                if onSet then onSet(self.value) end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    table.insert(refreshers, function()
        local shown = A.db[key]
        for _, choice in ipairs(choices) do
            if (choice.value or choice) == A.db[key] then
                shown = choice.text or choice
                break
            end
        end
        UIDropDownMenu_SetText(dd, shown)
    end)
    return dd
end

local function MakeButton(parent, label, width, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(22)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeHeader(parent, label, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText("|cffffd100" .. label .. "|r")

    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(1, 0.82, 0, 0.35)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
    line:SetWidth(CONTENT_WIDTH - x - 20)
    return fs
end

local ACTION_CHOICES = { "NEED", "GREED", "PASS", "IGNORE" }

local function QualityChoices()
    local out = {}
    for q = 2, 6 do
        local desc = _G["ITEM_QUALITY" .. q .. "_DESC"] or tostring(q)
        local col  = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        table.insert(out, { text = (col and col.hex or "|cffffffff") .. desc .. "|r",
                            value = q })
    end
    table.insert(out, { text = "|cff808080Never|r", value = 99 })
    return out
end

--=========================================================================
-- Panel
--=========================================================================

function A:BuildOptions()
    if A.optionsPanel then return end

    local panel = CreateFrame("Frame", "AutoRollOptionsPanel", UIParent)
    panel.name = "AutoRoll"
    A.optionsPanel = panel

    ------------------------------------------------------------ fixed header
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AutoRoll " .. A.version)

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 16, -40)
    sub:SetJustifyH("LEFT")
    sub:SetText("Rolls on group loot automatically.")

    ------------------------------------------------------------ scroll body
    local scroll = CreateFrame("ScrollFrame", "AutoRollOptionsScroll", panel,
                               "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -60)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)

    local content = CreateFrame("Frame", "AutoRollOptionsContent", scroll)
    content:SetWidth(CONTENT_WIDTH)
    content:SetHeight(1200)         
    scroll:SetScrollChild(content)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local bar = _G[self:GetName() .. "ScrollBar"]
        if bar then bar:SetValue(bar:GetValue() - delta * 40) end
    end)

    local C, X = content, 16
    local y = -12

    ---------------------------------------------------------------- general
    MakeHeader(C, "General", X - 2, y);  y = y - 26

    MakeCheck(C, "Enable automatic rolling", "Turn auto rolling on or off.",
        X, y, function() return A.db.enabled end, function(v) A.db.enabled = v end)
    y = y - 26
    MakeCheck(C, "Announce decisions in chat", "Print every roll decision to chat.",
        X, y, function() return A.db.announce end, function(v) A.db.announce = v end)
    y = y - 26
    MakeCheck(C, "Only roll inside instances", "Ignore loot rolls out in the world.",
        X, y, function() return A.db.onlyInInstance end, function(v) A.db.onlyInInstance = v end)
    y = y - 26
    MakeCheck(C, "Auto-confirm bind-on-pickup", "Accept the 'this will bind to you' popup.",
        X, y, function() return A.db.confirmBoP end, function(v) A.db.confirmBoP = v end)
    y = y - 26
    MakeCheck(C, "Allow disenchant rolls", "Enable disenchant rolls.",
        X, y, function() return A.db.allowDisenchant end, function(v) A.db.allowDisenchant = v end)
    y = y - 26
    MakeCheck(C, "Debug output", "Verbose logging, including why a rule declined.",
        X, y, function() return A.db.debug end, function(v) A.db.debug = v end)
    y = y - 44

    MakeDropdown(C, "Hands off at this quality and above", X - 4, y,
        "manualQualityMin", QualityChoices(), 130)
    y = y - 50

    ------------------------------------------------------------------ armor
    MakeHeader(C, "Armor types", X - 2, y);  y = y - 30

    local ay = y
    for i, atype in ipairs(A.ARMOR_TYPE_ORDER) do
        local t = atype
        local col = ((i - 1) % 2 == 0) and X or (X + 190)
        MakeCheck(C, t, "Roll Need on " .. t .. ".",
            col, ay,
            function() return A:GetArmorNeedSet()[t] and true or false end,
            function(v) A:SetArmorType(t, v) end)
        if (i % 2 == 0) or i == #A.ARMOR_TYPE_ORDER then ay = ay - 24 end
    end
    y = ay - 8

    MakeButton(C, "Auto (by class)", 130, X, y, function()
        A:ResetArmorTypes()
        A:RefreshOptions()
        A:Print("armor types back to class default: " .. A:ArmorSetString())
    end)
    y = y - 44

    MakeDropdown(C, "Unchecked armor, BoE", X - 4, y, "wrongArmorBoEAction", ACTION_CHOICES, 100)
    MakeDropdown(C, "Unchecked armor, BoP", X + 190, y, "wrongArmorBoPAction", ACTION_CHOICES, 100)
    y = y - 52

    ---------------------------------------------------------------- weapons
    MakeHeader(C, "Weapon types", X - 2, y);  y = y - 30

    local wy = y
    for i, wtype in ipairs(A.WEAPON_TYPE_ORDER) do
        local t = wtype
        local col = ((i - 1) % 2 == 0) and X or (X + 190)
        MakeCheck(C, t, "Roll Need on " .. t .. ".",
            col, wy,
            function() return A:GetWeaponNeedSet()[t] and true or false end,
            function(v) A:SetWeaponType(t, v) end)
        if (i % 2 == 0) or i == #A.WEAPON_TYPE_ORDER then wy = wy - 24 end
    end
    y = wy - 8

    MakeButton(C, "Auto (by class)", 130, X, y, function()
        A:ResetWeaponTypes()
        A:RefreshOptions()
        A:Print("weapon types back to class default: " .. A:WeaponSetString())
    end)
    y = y - 44

    MakeDropdown(C, "Unchecked weapon, BoE", X - 4, y, "wrongWeaponBoEAction", ACTION_CHOICES, 100)
    MakeDropdown(C, "Unchecked weapon, BoP", X + 190, y, "wrongWeaponBoPAction", ACTION_CHOICES, 100)
    y = y - 52

    MakeCheck(C, "Require the item be usable",
        "Second check on top of the type lists: never Need gear the tooltip marks in red.",
        X, y, function() return A.db.requireUsable end, function(v) A.db.requireUsable = v end)
    y = y - 42

    ----------------------------------------------------------------- timing
    MakeHeader(C, "Timing", X - 2, y);  y = y - 40

    MakeSlider(C, "Roll delay", "How long to wait before rolling.",
        X, y, 0, 10, 0.5,
        function() return A.db.rollDelay end,
        function(v) A.db.rollDelay = v end,
        function(v) return ("%.1fs"):format(v) end)
    y = y - 58

    MakeSlider(C, "Item cache retries", "How many times to wait 0.3s for item data before deciding without it. Too low and gear rules get skipped on uncached drops.",
        X, y, 0, 30, 1,
        function() return A.db.itemInfoRetries end,
        function(v) A.db.itemInfoRetries = v end)
    y = y - 58

    ---------------------------------------------------------------- actions
    MakeHeader(C, "Actions", X - 2, y);  y = y - 40

    local acts = {
        { "Unusable gear",  "unusableAction"   },
        { "Trade goods",    "tradeGoodsAction" },
        { "Bind-on-equip",  "boeAction"        },
        { "Unknown recipes","recipeAction"     },
        { "Lockboxes",      "lockboxAction"    },
        { "Nothing matched","fallbackAction"   },
    }
    for i = 1, #acts, 2 do
        MakeDropdown(C, acts[i][1], X - 4, y, acts[i][2], ACTION_CHOICES, 100)
        if acts[i + 1] then
            MakeDropdown(C, acts[i + 1][1], X + 190, y, acts[i + 1][2], ACTION_CHOICES, 100)
        end
        y = y - 46
    end
    y = y - 12

    ------------------------------------------------------------------ rules
    MakeHeader(C, "Active rules", X - 2, y);  y = y - 26

    for _, rule in ipairs(A.ruleList) do
        local key = rule.key
        MakeCheck(C, ("|cff808080[%d]|r %s"):format(rule.priority, rule.label),
            "Rule key: " .. key,
            X, y,
            function() return A.db.rules[key] end,
            function(v) A.db.rules[key] = v end)
        y = y - 24
    end
    y = y - 20

    --------------------------------------------------------------- profiles
    MakeHeader(C, "Profile", X - 2, y);  y = y - 40

    local profileDrop = CreateFrame("Frame", "AutoRollProfileDropdown", C, "UIDropDownMenuTemplate")
    profileDrop:SetPoint("TOPLEFT", X - 4, y)
    UIDropDownMenu_SetWidth(profileDrop, 200)
    UIDropDownMenu_Initialize(profileDrop, function()
        for _, pname in ipairs(A:GetProfileNames()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = pname
            info.value   = pname
            info.checked = (pname == A.profileName)
            info.func    = function(self)
                A:SetProfile(self.value)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    table.insert(refreshers, function() UIDropDownMenu_SetText(profileDrop, A.profileName) end)
    y = y - 36

    MakeButton(C, "Reset profile", 120, X, y, function()
        A:ResetProfile()
        A:Print("profile reset to defaults")
    end)
    MakeButton(C, "Roll history", 120, X + 130, y, function() A:ToggleHistoryFrame() end)
    y = y - 40

    ----------------------------------------------------------------- finish
    content:SetHeight(math.abs(y) + 20)

    panel.refresh = function() A:RefreshOptions() end
    panel:SetScript("OnShow", function() A:RefreshOptions() end)

    InterfaceOptions_AddCategory(panel)
    A:RefreshOptions()
end

function A:RefreshOptions()
    if not A.db then return end
    for _, fn in ipairs(refreshers) do
        local ok, err = pcall(fn)
        if not ok then A:Debug("options refresh error: " .. tostring(err)) end
    end
end
