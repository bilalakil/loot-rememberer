-- BEGIN GLOBALS
local ceil = ceil
local C_Timer = C_Timer
local ConfirmLootRoll = ConfirmLootRoll
local GameTooltip = GameTooltip
local GetItemInfo = GetItemInfo
local GetLootRollItemLink = GetLootRollItemLink
local ITEM_QUALITY_COLORS = ITEM_QUALITY_COLORS
local RollOnLoot = RollOnLoot
local SlashCmdList = SlashCmdList
local sort = table.sort
local tinsert = tinsert
local UnitGUID = UnitGUID
local UISpecialFrames = UISpecialFrames
-- END GLOBALS

local GUI_NUM_RECORDS_PER_PAGE = 10
local STORAGE_SCOPES = {
    CHAR = "char",
    ACCOUNT = "account",
}
local STORAGE_SCOPE_ICONS = {
    [STORAGE_SCOPES.CHAR] = "Interface\\Icons\\INV_Misc_GroupLooking",
    [STORAGE_SCOPES.ACCOUNT] = "Interface\\Icons\\INV_Misc_GroupNeedMore",
}
local ROLL_TYPES = {
    [0] = {
        normalTexture = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        pushedTexture = "Interface\\Buttons\\UI-GroupLoot-Pass-Down",
        highlightTexture = nil,
    },
    [1] = {
        normalTexture = "Interface\\Buttons\\UI-GroupLoot-Dice-Up",
        pushedTexture = "Interface\\Buttons\\UI-GroupLoot-Dice-Down",
        highlightTexture = "Interface\\Buttons\\UI-GroupLoot-Dice-Highlight",
    },
    [2] = {
        normalTexture = "Interface\\Buttons\\UI-GroupLoot-Coin-Up",
        pushedTexture = "Interface\\Buttons\\UI-GroupLoot-Coin-Down",
        highlightTexture = "Interface\\Buttons\\UI-GroupLoot-Coin-Highlight",
    },
    [3] = {
        normalTexture = "Interface\\Buttons\\UI-GroupLoot-DE-Up",
        pushedTexture = "Interface\\Buttons\\UI-GroupLoot-DE-Down",
        highlightTexture = "Interface\\Buttons\\UI-GroupLoot-DE-Highlight",
    },
}

LootRememberer = CreateFrame("Frame", "LootRemembererFrame", UIParent)
local L = {
    ["Loot Rememberer"] = "Loot Rememberer",
    ["Filter:"] = "Filter:",
    ["Loaded with %d remembered loot rolls. Type |cff33ff99/lr|r to manage."] = "Loaded with %d remembered loot rolls. Type |cff33ff99/lr|r to manage.",
    ["No loot remembered..."] = "No loot remembered...",
    ["Specific to this character"] = "Specific to this character",
    ["Affect entire account"] = "Affect entire account",
}

LootRememberer:SetScript("OnEvent", function (_, event, ...)
    local handler = LootRememberer[event]
    if handler then
        handler(LootRememberer, ...)
    end
end)
LootRememberer:RegisterEvent("ADDON_LOADED")

function LootRememberer:ADDON_LOADED(addonName)
    if addonName ~= "LootRememberer" then
        return
    end

    self.TRACE = false
    self:Trace("Initializing...")
    self:EnsureDatabase()
    self:RegisterEvent("START_LOOT_ROLL")
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    self:HookIntoStockUI()
    SLASH_LOOTREMEMBERER1 = "/lootrememberer"
    SLASH_LOOTREMEMBERER2 = "/lr"
    SlashCmdList.LOOTREMEMBERER = function ()
        LootRememberer:SlashProcessor()
    end
    self:GUIPrepare()
    self:GUISetTotalRecordCount()

    if self.guiState.totalRecordCount ~= 0 then
        self:Print(string.format(
            L["Loaded with %d remembered loot rolls. Type |cff33ff99/lr|r to manage."],
            self.guiState.totalRecordCount
        ))
    end

    self:Trace("Initialization complete.")
end

function LootRememberer:START_LOOT_ROLL(rollId)
    C_Timer.After(0, function ()
        self:DeferredLootRollHandler(rollId)
    end)
end

function LootRememberer:GET_ITEM_INFO_RECEIVED(_, success)
    if success == false then
        return
    end

    -- Unloaded vs loaded items have very different names, which can severely affect sorting.
    self:GUIMarkSortedEntriesDirty()
end

function LootRememberer:Print(...)
    print("|cff33ff99LootRememberer:|r", ...)
end

function LootRememberer:Trace(...)
    if not self.TRACE then
        return
    end

    self:Print("Trace:", ...)
end

function LootRememberer:SlashProcessor()
    if self.guiContainer:IsShown() then
        self.guiContainer:Hide()
    else
        self.guiContainer:Show()
    end
end

function LootRememberer:EnsureDatabase()
    if type(LootRemembererDB) ~= "table" then
        LootRemembererDB = {}
    end

    local db = LootRemembererDB
    if type(db.account) ~= "table" then
        db.account = {}
    end
    if type(db.chars) ~= "table" then
        db.chars = {}
    end

    self.characterKey = UnitGUID("player")
    if type(db.chars[self.characterKey]) ~= "table" then
        db.chars[self.characterKey] = {}
    end

    self.db = {
        profile = db.account,
        char = db.chars[self.characterKey],
    }
end

function LootRememberer:HookIntoStockUI()
    local createRollIdGetter = function (lootRollIndex)
        local lootFrame = _G["GroupLootFrame" .. lootRollIndex]
        return function ()
            return lootFrame.rollID
        end
    end

    for lootRollIndex = 1, 4 do
        local lootFrame = _G["GroupLootFrame" .. lootRollIndex]
        local rollIdGetter = createRollIdGetter(lootRollIndex)
        self:HookInto(lootFrame.PassButton, rollIdGetter, 0)
        self:HookInto(lootFrame.NeedButton, rollIdGetter, 1)
        self:HookInto(lootFrame.GreedButton, rollIdGetter, 2)
        --self:HookInto(lootFrame.DisenchantButton, rollIdGetter, 3)
    end
end

function LootRememberer:HookInto(button, rollIdGetter, rollMode)
    if button == nil then
        self:Trace("Failed to hook into button for roll mode", rollMode, "- button not found")
        return
    end

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local originalOnClick = button:GetScript("OnClick")
    button:SetScript("OnClick", function (...)
        local _, triggeringButton = ...
        if triggeringButton == "LeftButton" then
            if originalOnClick then
                originalOnClick(...)
            end
            return
        end

        local rollId = rollIdGetter()
        local shouldSaveToAccount = IsShiftKeyDown()
        self:Trace("OnClick", rollId, rollMode, shouldSaveToAccount and STORAGE_SCOPES.ACCOUNT or STORAGE_SCOPES.CHAR)

        if not self:RecordLootRoll(rollId, rollMode, shouldSaveToAccount) then
            if originalOnClick then
                originalOnClick(...)
            end
            return
        end

        RollOnLoot(rollId, rollMode)
        C_Timer.After(0, function () ConfirmLootRoll(rollId, rollMode) end)
    end)
end

function LootRememberer:BuildLootRollRecord(details, scopeStorage)
    return { details = details, storageScope = scopeStorage }
end

function LootRememberer:SetLootRollRecord(itemLink, details, storageScope)
    if storageScope == STORAGE_SCOPES.ACCOUNT then
        self.db.profile[itemLink] = details
        self.db.char[itemLink] = nil
    else
        self.db.profile[itemLink] = nil
        self.db.char[itemLink] = details
    end

    self:GUIMarkSortedEntriesDirty()
end

function LootRememberer:FindLootRollRecord(itemLink)
    local accountDetails = self.db.profile[itemLink]
    if accountDetails ~= nil then
        return self:BuildLootRollRecord(accountDetails, STORAGE_SCOPES.ACCOUNT)
    end

    local charDetails = self.db.char[itemLink]
    if charDetails ~= nil then
        return self:BuildLootRollRecord(charDetails, STORAGE_SCOPES.CHAR)
    end

    return nil
end

function LootRememberer:GetAllLootRollRecords()
    local records = {}

    for itemLink, details in pairs(self.db.char) do
        records[itemLink] = self:BuildLootRollRecord(details, STORAGE_SCOPES.CHAR)
    end

    for itemLink, details in pairs(self.db.profile) do
        records[itemLink] = self:BuildLootRollRecord(details, STORAGE_SCOPES.ACCOUNT)
    end

    return records
end

function LootRememberer:RecordLootRoll(rollId, rollMode, shouldSaveToAccount)
    local itemLink = GetLootRollItemLink(rollId)
    self:Trace("RecordLootRoll", rollId, itemLink, shouldSaveToAccount and STORAGE_SCOPES.ACCOUNT or STORAGE_SCOPES.CHAR)

    if itemLink == nil then
        return false
    end

    self:SetLootRollRecord(
        itemLink,
        { rollMode },
        shouldSaveToAccount and STORAGE_SCOPES.ACCOUNT or STORAGE_SCOPES.CHAR
    )

    return true
end

function LootRememberer:DeferredLootRollHandler(rollId)
    local itemLink = GetLootRollItemLink(rollId)
    local record = self:FindLootRollRecord(itemLink)
    self:Trace("HandleNewLootRoll", rollId, itemLink, record)

    if record == nil then
        return
    end

    local rollMode = unpack(record.details)

    RollOnLoot(rollId, rollMode)
    C_Timer.After(0, function () ConfirmLootRoll(rollId, rollMode) end)
end

function LootRememberer:DeleteLootRollRecord(itemLink)
    self.db.profile[itemLink] = nil
    self.db.char[itemLink] = nil
    self:GUIMarkSortedEntriesDirty()
end

function LootRememberer:MoveLootRollRecordScope(itemLink, storageScope)
    local record = self:FindLootRollRecord(itemLink)
    if record == nil then
        return
    end

    self:SetLootRollRecord(itemLink, record.details, storageScope)
end

function LootRememberer:SetLootRollRecordMode(itemLink, rollMode)
    if ROLL_TYPES[rollMode] == nil then
        return
    end

    local record = self:FindLootRollRecord(itemLink)
    if record == nil then
        return
    end

    self:SetLootRollRecord(itemLink, { rollMode }, record.storageScope)
end

function LootRememberer:GUIPrepare()
    self.guiState = {
        filter = "",
        currentPage = 1,
        lastPage = 1,
        totalRecordCount = 0,
        sortedEntries = {},
        sortedEntriesDirty = true,
    }

    self.guiContainer = CreateFrame("Frame", "LootRemembererGUIContainer", UIParent, "BackdropTemplate")
    tinsert(UISpecialFrames, "LootRemembererGUIContainer")
    self.guiContainer:SetSize(515, 304)
    self.guiContainer:SetPoint("CENTER")
    self.guiContainer:SetFrameStrata("DIALOG")
    self.guiContainer:SetClampedToScreen(true)
    self.guiContainer:SetMovable(true)
    self.guiContainer:EnableMouse(true)
    self.guiContainer:RegisterForDrag("LeftButton")
    self.guiContainer:SetScript("OnDragStart", function (frame) frame:StartMoving() end)
    self.guiContainer:SetScript("OnDragStop", function (frame) frame:StopMovingOrSizing() end)
    self.guiContainer:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    self.guiContainer:SetBackdropColor(0, 0, 0, 1)
    self.guiContainer:Hide()
    self.guiContainer:SetScript("OnShow", function () self:GUIRefreshPagination() end)
    self.guiContainer:SetScript("OnUpdate", function () self:GUIHandleUpdate() end)

    self.guiContainer.title = self.guiContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.guiContainer.title:SetPoint("TOP", 0, -14)
    self.guiContainer.title:SetText(L["Loot Rememberer"])

    local closeButton = CreateFrame("Button", nil, self.guiContainer, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -2, -2)

    self.guiContainer.filterLabel = self.guiContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.guiContainer.filterLabel:SetPoint("TOPLEFT", 15, -42)
    self.guiContainer.filterLabel:SetText(L["Filter:"])

    self.guiContainer.searchInput = CreateFrame("EditBox", nil, self.guiContainer, "InputBoxTemplate")
    self.guiContainer.searchInput:SetSize(246, 20)
    self.guiContainer.searchInput:SetPoint("LEFT", self.guiContainer.filterLabel, "RIGHT", 10, 0)
    self.guiContainer.searchInput:SetAutoFocus(false)
    self.guiContainer.searchInput:SetScript("OnEnterPressed", function (editBox)
        self:GUIUseFilter(editBox:GetText())
        editBox:ClearFocus()
    end)

    self.guiContainer.clearFilterButton = CreateFrame("Button", nil, self.guiContainer.searchInput)
    self.guiContainer.clearFilterButton:SetSize(18, 18)
    self.guiContainer.clearFilterButton:SetPoint("RIGHT", self.guiContainer.searchInput, "RIGHT", 0, 0)
    self.guiContainer.clearFilterButton:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    self.guiContainer.clearFilterButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    self.guiContainer.clearFilterButton:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    self.guiContainer.clearFilterButton:SetScript("OnClick", function ()
        self.guiContainer.searchInput:SetText("")
        self:GUIUseFilter("")
    end)
    self.guiContainer.clearFilterButton:Hide()

    local firstButton = CreateFrame("Button", nil, self.guiContainer, "UIPanelButtonTemplate")
    firstButton:SetSize(36, 20)
    firstButton:SetText("<<")
    firstButton:SetPoint("TOPLEFT", self.guiContainer.searchInput, "TOPRIGHT", 10, 0)
    firstButton:SetScript("OnClick", function () self:GUIChangeToPage(1) end)

    local previousButton = CreateFrame("Button", nil, self.guiContainer, "UIPanelButtonTemplate")
    previousButton:SetSize(30, 20)
    previousButton:SetText("<")
    previousButton:SetPoint("LEFT", firstButton, "RIGHT", 4, 0)
    previousButton:SetScript("OnClick", function () self:GUIChangeToPage(self.guiState.currentPage - 1) end)

    self.guiContainer.paginationText = self.guiContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.guiContainer.paginationText:SetPoint("LEFT", previousButton, "RIGHT", 0, 0)
    self.guiContainer.paginationText:SetWidth(50)

    local nextButton = CreateFrame("Button", nil, self.guiContainer, "UIPanelButtonTemplate")
    nextButton:SetSize(30, 20)
    nextButton:SetText(">")
    nextButton:SetPoint("LEFT", self.guiContainer.paginationText, "RIGHT", 0, 0)
    nextButton:SetScript("OnClick", function () self:GUIChangeToPage(self.guiState.currentPage + 1) end)

    local lastButton = CreateFrame("Button", nil, self.guiContainer, "UIPanelButtonTemplate")
    lastButton:SetSize(36, 20)
    lastButton:SetText(">>")
    lastButton:SetPoint("LEFT", nextButton, "RIGHT", 4, 0)
    lastButton:SetScript("OnClick", function () self:GUIChangeToPage(self.guiState.lastPage) end)

    self.guiContainer.recordContainer = CreateFrame("Frame", nil, self.guiContainer)
    self.guiContainer.recordContainer:SetSize(485, 220)
    self.guiContainer.recordContainer:SetPoint("TOPLEFT", 15, -72)

    self.guiContainer.emptyText = self.guiContainer.recordContainer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.guiContainer.emptyText:SetPoint("CENTER", self.guiContainer.recordContainer, "CENTER", 0, 0)
    self.guiContainer.emptyText:SetText(L["No loot remembered..."])

    self.guiContainer.rows = {}
    for i = 1, GUI_NUM_RECORDS_PER_PAGE do
        local recordFrame = CreateFrame("Frame", nil, self.guiContainer.recordContainer)
        recordFrame:SetSize(485, 18)
        recordFrame:SetPoint("TOPLEFT", 0, -(i - 1) * 22)

        if i % 2 == 0 then
            local rowBackground = recordFrame:CreateTexture(nil, "BACKGROUND")
            rowBackground:SetAllPoints()
            rowBackground:SetColorTexture(1, 1, 1, 0.04)
        end

        recordFrame.rollModeButtons = {}
        local rollModeIconOrder = { 1, 2, 0 }
        for iconIndex, mode in ipairs(rollModeIconOrder) do
            local iconButton = CreateFrame("Button", nil, recordFrame)
            iconButton.rollMode = mode
            iconButton:SetSize(18, 18)
            iconButton:SetNormalTexture(ROLL_TYPES[mode].normalTexture)
            if ROLL_TYPES[mode].highlightTexture then
                iconButton:SetHighlightTexture(ROLL_TYPES[mode].highlightTexture)
            end
            iconButton:SetPushedTexture(ROLL_TYPES[mode].pushedTexture)
            if iconIndex == 1 then
                iconButton:SetPoint("LEFT", 0, 0)
            else
                iconButton:SetPoint("LEFT", recordFrame.rollModeButtons[iconIndex - 1], "RIGHT", 2, 0)
            end
            iconButton:SetScript("OnClick", function ()
                if recordFrame.itemLink == nil then
                    return
                end

                self:SetLootRollRecordMode(recordFrame.itemLink, mode)
                self:GUIRefreshPagination()
            end)
            recordFrame.rollModeButtons[iconIndex] = iconButton
        end

        recordFrame.itemLabel = CreateFrame("Button", nil, recordFrame)
        recordFrame.itemLabel:SetSize(360, 18)
        recordFrame.itemLabel:SetPoint("LEFT", recordFrame.rollModeButtons[#rollModeIconOrder], "RIGHT", 2, 0)
        recordFrame.itemLabel.icon = recordFrame.itemLabel:CreateTexture(nil, "ARTWORK")
        recordFrame.itemLabel.icon:SetSize(16, 16)
        recordFrame.itemLabel.icon:SetPoint("LEFT", 0, 0)
        recordFrame.itemLabel.text = recordFrame.itemLabel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        recordFrame.itemLabel.text:SetPoint("LEFT", recordFrame.itemLabel.icon, "RIGHT", 3, 0)
        recordFrame.itemLabel.text:SetPoint("RIGHT", 0, 0)
        recordFrame.itemLabel.text:SetJustifyH("LEFT")

        local enterItemLabel = function ()
            if recordFrame.itemLink == nil then
                return
            end

            GameTooltip:SetOwner(recordFrame.itemLabel, "ANCHOR_TOPLEFT")
            GameTooltip:SetHyperlink(recordFrame.itemLink)
            GameTooltip:Show()
        end

        local leaveItemLabel = function ()
            if recordFrame.itemLink == nil then
                return
            end

            GameTooltip:Hide()
        end

        recordFrame.itemLabel:SetScript("OnEnter", enterItemLabel)
        recordFrame.itemLabel:SetScript("OnLeave", leaveItemLabel)

        local enterScopeIcon = function (scopeIcon, text)
            GameTooltip:SetOwner(scopeIcon, "ANCHOR_TOPLEFT")
            GameTooltip:SetText(text)
            GameTooltip:Show()
        end

        local leaveScopeIcon = function ()
            GameTooltip:Hide()
        end

        recordFrame.charScopeIcon = CreateFrame("Button", nil, recordFrame)
        recordFrame.charScopeIcon:SetSize(18, 18)
        recordFrame.charScopeIcon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        recordFrame.charScopeIcon:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
        recordFrame.charScopeIcon.icon = recordFrame.charScopeIcon:CreateTexture(nil, "BACKGROUND")
        recordFrame.charScopeIcon.icon:SetAllPoints()
        recordFrame.charScopeIcon.icon:SetTexture(STORAGE_SCOPE_ICONS[STORAGE_SCOPES.CHAR])
        recordFrame.charScopeIcon:SetPoint("LEFT", recordFrame.itemLabel, "RIGHT", 4, 0)
        recordFrame.charScopeIcon:SetScript("OnClick", function ()
            if recordFrame.itemLink == nil then
                return
            end

            self:MoveLootRollRecordScope(recordFrame.itemLink, STORAGE_SCOPES.CHAR)
            self:GUIRefreshPagination()
        end)
        recordFrame.charScopeIcon:SetScript("OnEnter", function () enterScopeIcon(recordFrame.charScopeIcon, L["Specific to this character"]) end)
        recordFrame.charScopeIcon:SetScript("OnLeave", leaveScopeIcon)

        recordFrame.accountScopeIcon = CreateFrame("Button", nil, recordFrame)
        recordFrame.accountScopeIcon:SetSize(18, 18)
        recordFrame.accountScopeIcon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        recordFrame.accountScopeIcon:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
        recordFrame.accountScopeIcon.icon = recordFrame.accountScopeIcon:CreateTexture(nil, "BACKGROUND")
        recordFrame.accountScopeIcon.icon:SetAllPoints()
        recordFrame.accountScopeIcon.icon:SetTexture(STORAGE_SCOPE_ICONS[STORAGE_SCOPES.ACCOUNT])
        recordFrame.accountScopeIcon:SetPoint("LEFT", recordFrame.charScopeIcon, "RIGHT", 4, 0)
        recordFrame.accountScopeIcon:SetScript("OnClick", function ()
            if recordFrame.itemLink == nil then
                return
            end

            self:MoveLootRollRecordScope(recordFrame.itemLink, STORAGE_SCOPES.ACCOUNT)
            self:GUIRefreshPagination()
        end)
        recordFrame.accountScopeIcon:SetScript("OnEnter", function () enterScopeIcon(recordFrame.accountScopeIcon, L["Affect entire account"]) end)
        recordFrame.accountScopeIcon:SetScript("OnLeave", leaveScopeIcon)

        recordFrame.deleteButton = CreateFrame("Button", nil, recordFrame)
        recordFrame.deleteButton:SetSize(18, 18)
        recordFrame.deleteButton:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        recordFrame.deleteButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
        recordFrame.deleteButton:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
        recordFrame.deleteButton:SetPoint("LEFT", recordFrame.accountScopeIcon, "RIGHT", 8, 0)
        recordFrame.deleteButton:SetScript("OnClick", function ()
            if recordFrame.itemLink == nil then
                return
            end

            self:DeleteLootRollRecord(recordFrame.itemLink)
            leaveItemLabel()
            self:GUIRefreshPagination()
            enterItemLabel()
        end)

        recordFrame.Update = function (_, itemLink, details, storageScope)
            recordFrame:Show()
            local rollMode = unpack(details)

            recordFrame.itemLink = itemLink
            recordFrame.storageScope = storageScope
            local itemName, _, itemQuality, _, _, _, _, _, _, itemTexture = GetItemInfo(itemLink)
            local displayName = itemName or itemLink
            local color = itemQuality and ITEM_QUALITY_COLORS[itemQuality] or nil

            for _, button in pairs(recordFrame.rollModeButtons) do
                if button.rollMode == rollMode then
                    button:SetAlpha(1)
                else
                    button:SetAlpha(0.35)
                end
            end

            if storageScope == STORAGE_SCOPES.CHAR then
                recordFrame.charScopeIcon:SetAlpha(1)
                recordFrame.accountScopeIcon:SetAlpha(0.35)
            else
                recordFrame.charScopeIcon:SetAlpha(0.35)
                recordFrame.accountScopeIcon:SetAlpha(1)
            end

            recordFrame.itemLabel.text:SetText("[" .. displayName .. "]")
            if color then
                recordFrame.itemLabel.text:SetTextColor(color.r, color.g, color.b)
            else
                recordFrame.itemLabel.text:SetTextColor(1, 1, 1)
            end
            recordFrame.itemLabel.icon:SetTexture(itemTexture)
        end

        recordFrame.Clear = function ()
            recordFrame:Hide()
            recordFrame.itemLink = nil
            recordFrame.storageScope = nil
            for _, button in pairs(recordFrame.rollModeButtons) do
                button:SetAlpha(0.35)
            end
            recordFrame.charScopeIcon:SetAlpha(0.35)
            recordFrame.accountScopeIcon:SetAlpha(0.35)
            recordFrame.itemLabel.text:SetText("")
            recordFrame.itemLabel.text:SetTextColor(1, 1, 1)
            recordFrame.itemLabel.icon:SetTexture(nil)
        end

        self.guiContainer.rows[i] = recordFrame
    end
end

function LootRememberer:GUIHandleUpdate()
    if not (self.guiContainer:IsShown() and self.guiState.sortedEntriesDirty) then return end
    self:Trace("Refreshing display for newly loaded items...")
    self:GUIRefreshCurrentPageDisplay()
end

function LootRememberer:GUIMarkSortedEntriesDirty()
    self.guiState.sortedEntriesDirty = true
end

function LootRememberer:GUIRefreshSortedItemLinksIfDirty()
    if self.guiState.sortedEntriesDirty ~= true then
        return
    end

    local sortedEntries = {}
    for itemLink, record in pairs(self:GetAllLootRollRecords()) do
        tinsert(sortedEntries, {
            itemLink = itemLink,
            details = record.details,
            storageScope = record.storageScope,
        })
    end

    sort(sortedEntries, function (leftEntry, rightEntry)
        local leftItemName = GetItemInfo(leftEntry.itemLink) or leftEntry.itemLink
        local rightItemName = GetItemInfo(rightEntry.itemLink) or rightEntry.itemLink

        leftItemName = leftItemName:lower()
        rightItemName = rightItemName:lower()
        return leftItemName < rightItemName
    end)

    self.guiState.sortedEntries = sortedEntries
    self.guiState.sortedEntriesDirty = false
end

function LootRememberer:GUIRefreshPagination()
    self:GUISetTotalRecordCount()
    self:GUIClampCurrentPage()
    self:GUIRefreshCurrentPageDisplay()
    self:GUIRefreshPageNumberLabel()
end

function LootRememberer:GUISetTotalRecordCount()
    self:GUIRefreshSortedItemLinksIfDirty()

    local count = 0
    for _, entry in ipairs(self.guiState.sortedEntries) do
        local itemLink = entry.itemLink
        if self:GUIDoesItemLinkMatchFilter(itemLink) then
            count = count + 1
        end
    end
    self.guiState.totalRecordCount = count

    if count == 0 then
        self.guiState.lastPage = 1
    else
        self.guiState.lastPage = ceil(count / GUI_NUM_RECORDS_PER_PAGE)
    end
end

function LootRememberer:GUIClampCurrentPage()
    if self.guiState.totalRecordCount == 0 or self.guiState.currentPage < 1 then
        self.guiState.currentPage = 1
        return
    end

    local currentLastVisibleRecordIndex = self.guiState.currentPage * GUI_NUM_RECORDS_PER_PAGE
    if currentLastVisibleRecordIndex <= self.guiState.totalRecordCount then
        return
    end

    local difference = currentLastVisibleRecordIndex - self.guiState.totalRecordCount
    local differenceFitsOnCurrentPage =
        difference < GUI_NUM_RECORDS_PER_PAGE and
        -self.guiState.totalRecordCount % GUI_NUM_RECORDS_PER_PAGE <= difference
    if differenceFitsOnCurrentPage then
        return
    end

    self.guiState.currentPage = self.guiState.lastPage
end

function LootRememberer:GUIRefreshCurrentPageDisplay()
    self:GUIRefreshSortedItemLinksIfDirty()

    local firstRecordIndex = (self.guiState.currentPage - 1) * GUI_NUM_RECORDS_PER_PAGE + 1
    local lastRecordIndex = firstRecordIndex + GUI_NUM_RECORDS_PER_PAGE - 1
    local currentRecordIndex = 1
    local recordFrameIndex = 1

    for _, entry in ipairs(self.guiState.sortedEntries) do
        local itemLink = entry.itemLink
        if self:GUIDoesItemLinkMatchFilter(itemLink) then
            local thisRecordIndex = currentRecordIndex
            currentRecordIndex = currentRecordIndex + 1

            if thisRecordIndex > lastRecordIndex then
                break
            end
            if thisRecordIndex >= firstRecordIndex then
                self.guiContainer.rows[recordFrameIndex]:Update(itemLink, entry.details, entry.storageScope)
                recordFrameIndex = recordFrameIndex + 1
            end
        end
    end

    for i = recordFrameIndex, GUI_NUM_RECORDS_PER_PAGE do
        self.guiContainer.rows[i]:Clear()
    end

    if (not self.guiState.filter or self.guiState.filter == "") and recordFrameIndex == 1 then
        self.guiContainer.emptyText:Show()
    else
        self.guiContainer.emptyText:Hide()
    end
end

function LootRememberer:GUIRefreshPageNumberLabel()
    self.guiContainer.paginationText:SetText(self.guiState.currentPage .. " / " .. self.guiState.lastPage)
end

function LootRememberer:GUIUseFilter(text)
    self.guiState.filter = (text or ""):lower()

    if self.guiContainer and self.guiContainer.clearFilterButton then
        if self.guiState.filter == "" then
            self.guiContainer.clearFilterButton:Hide()
        else
            self.guiContainer.clearFilterButton:Show()
        end
    end

    self:GUIRefreshPagination()
end

function LootRememberer:GUIDoesItemLinkMatchFilter(itemLink)
    if self.guiState.filter == "" or self.guiState.filter == nil then
        return true
    end
    return string.find(itemLink:lower(), self.guiState.filter) ~= nil
end

function LootRememberer:GUIChangeToPage(pageNumber)
    self.guiState.currentPage = pageNumber
    self:GUIClampCurrentPage()
    self:GUIRefreshPageNumberLabel()
    self:GUIRefreshCurrentPageDisplay()
end