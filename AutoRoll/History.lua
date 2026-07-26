--=========================================================================
-- AutoRoll :: History.lua
-- Records every decision and shows them in a scrollable window (/ar log).
-- History is stored per character, since that is the only scope where a
-- roll log actually means anything.
--=========================================================================

local A = AutoRoll

local ROW_HEIGHT     = 18
local VISIBLE_ROWS   = 16

--=========================================================================
-- Recording
--=========================================================================

function A:AddHistory(ctx, action, ruleKey, reason)
    local hist = AutoRollCharDB.history
    if not hist then return end

    table.insert(hist, 1, {
        t       = time(),
        link    = ctx.link,
        name    = ctx.name,
        quality = ctx.quality,
        action  = action,
        rule    = ruleKey,
        reason  = reason,
    })

    local limit = A.db.historyLimit or 250
    while #hist > limit do
        table.remove(hist)
    end

    if A.historyFrame and A.historyFrame:IsShown() then
        A:UpdateHistoryList()
    end
end

function A:ClearHistory()
    AutoRollCharDB.history = {}
    if A.historyFrame then A:UpdateHistoryList() end
end

--=========================================================================
-- Window
--=========================================================================

local function CreateHistoryFrame()
    local frame = CreateFrame("Frame", "AutoRollHistoryFrame", UIParent)
    frame:SetWidth(520)
    frame:SetHeight(ROW_HEIGHT * VISIBLE_ROWS + 90)
    frame:SetPoint("CENTER")
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()
    tinsert(UISpecialFrames, "AutoRollHistoryFrame")  -- closes on Escape

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("AutoRoll History")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetWidth(90)
    clear:SetHeight(22)
    clear:SetPoint("BOTTOMRIGHT", -18, 16)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function() A:ClearHistory() end)

    local count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("BOTTOMLEFT", 20, 22)
    frame.countText = count

    local scroll = CreateFrame("ScrollFrame", "AutoRollHistoryScroll", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -44)
    scroll:SetWidth(470)
    scroll:SetHeight(ROW_HEIGHT * VISIBLE_ROWS)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function()
            A:UpdateHistoryList()
        end)
    end)
    frame.scroll = scroll

    frame.rows = {}
    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetWidth(462)
        row:SetHeight(ROW_HEIGHT)
        if i == 1 then
            row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", frame.rows[i - 1], "BOTTOMLEFT", 0, 0)
        end

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", 2, 0)
        text:SetWidth(458)
        text:SetJustifyH("LEFT")
        row.text = text

        row:SetScript("OnEnter", function(self)
            if not self.link then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.link)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if self.link and ChatEdit_InsertLink then
                ChatEdit_InsertLink(self.link)
            end
        end)

        frame.rows[i] = row
    end

    return frame
end

function A:UpdateHistoryList()
    local frame = A.historyFrame
    if not frame then return end

    local hist = AutoRollCharDB.history or {}
    FauxScrollFrame_Update(frame.scroll, #hist, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(frame.scroll)

    frame.countText:SetText(("%d entries  |  profile: %s"):format(#hist, A.profileName))

    for i = 1, VISIBLE_ROWS do
        local row   = frame.rows[i]
        local entry = hist[i + offset]

        if entry then
            local stamp  = date("%H:%M:%S", entry.t)
            local action = ("%s%s|r"):format(
                A.ACTION_COLOR[entry.action] or "|cffffffff",
                A.ACTION_NAME[entry.action] or "?")

            row.link = entry.link
            row.text:SetText(("|cff808080%s|r  %-11s %s  |cff808080%s|r")
                :format(stamp, action, entry.link or entry.name or "?", entry.reason or ""))
            row:Show()
        else
            row.link = nil
            row.text:SetText("")
            row:Hide()
        end
    end
end

function A:ToggleHistoryFrame()
    if not A.historyFrame then
        A.historyFrame = CreateHistoryFrame()
    end
    if A.historyFrame:IsShown() then
        A.historyFrame:Hide()
    else
        A.historyFrame:Show()
        A:UpdateHistoryList()
    end
end
