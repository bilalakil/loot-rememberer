-- BEGIN GLOBALS
local ceil = ceil
local C_Timer = C_Timer
local ConfirmLootRoll = ConfirmLootRoll
local GameTooltip = GameTooltip
local GetItemInfo = GetItemInfo
local GetLootRollItemInfo = GetLootRollItemInfo
local GetLootRollItemLink = GetLootRollItemLink
local ITEM_QUALITY_COLORS = ITEM_QUALITY_COLORS
local LibStub = LibStub
local RollOnLoot = RollOnLoot
local tinsert = tinsert
local UISpecialFrames = UISpecialFrames
-- END GLOBALS

local GUI_NUM_RECORDS_PER_PAGE = 10
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

LootRememberer = LibStub("AceAddon-3.0"):NewAddon("LootRememberer", "AceConsole-3.0", "AceEvent-3.0", "AceHook-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("LootRememberer", true)
local AceGUI = LibStub("AceGUI-3.0")

function LootRememberer:OnInitialize()
    self.TRACE = false

    self.db = LibStub("AceDB-3.0"):New("LootRemembererDB")
    self.db:SetProfile("Global")
    self.nextElvUIRollFrameIndex = 1
end

function LootRememberer:Trace(...)
    if not self.TRACE then
        return
    end

    self:Print("Trace:", ...)
end

function LootRememberer:OnEnable()
    self:Trace("Enabling...")
    self:HookIntoStockUI()
    self:HookIntoElvUI()
    self:RegisterEvent("START_LOOT_ROLL")
    self:RegisterChatCommand("lootrememberer", "SlashProcessor")
    self:RegisterChatCommand("lr", "SlashProcessor")
    self:GUIPrepare()
    self:Trace("Enabled")
end

function LootRememberer:OnDisable()
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
        self:HookInto(lootFrame.passButton, rollIdGetter, 0)
        self:HookInto(lootFrame.needButton, rollIdGetter, 1)
        self:HookInto(lootFrame.greedButton, rollIdGetter, 2)
        self:HookInto(lootFrame.disenchantButton, rollIdGetter, 3)
    end
end

local function CreateElvUIRollIdGetter(lootFrame)
    return function ()
        return lootFrame.rollID
    end
end

function LootRememberer:HookIntoElvUI()
    while true do
        local lootRollIndex = self.nextElvUIRollFrameIndex
        local lootFrame = _G["ElvUI_GroupLootFrame" .. lootRollIndex]
        if lootFrame == nil then
            return
        end
        self:Trace("HookIntoElvUI", lootRollIndex)

        local rollIdGetter = CreateElvUIRollIdGetter(lootFrame)
        self:HookInto(lootFrame.passButton, rollIdGetter, 0)
        self:HookInto(lootFrame.needButton, rollIdGetter, 1)
        self:HookInto(lootFrame.greedButton, rollIdGetter, 2)
        self:HookInto(lootFrame.disenchantButton, rollIdGetter, 3)

        self.nextElvUIRollFrameIndex = lootRollIndex + 1
    end
end

function LootRememberer:HookInto(button, rollIdGetter, rollMode)
    if button == nil then
        return
    end

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    self:RawHookScript(button, "OnClick", function (...)
        local _, triggerringButton = ...
        if triggerringButton == "LeftButton" then
            self.hooks[button]["OnClick"](...)
            return
        end

        local rollId = rollIdGetter()
        self:Trace("OnClick", rollId, rollMode)

        if not self:RecordLootRoll(rollId, rollMode) then
            self.hooks[button]["OnClick"](...)
            return
        end

        RollOnLoot(rollId, rollMode)
        C_Timer.After(0, function () ConfirmLootRoll(rollId, rollMode) end)
    end)
end

function LootRememberer:RecordLootRoll(rollId, rollMode)
    local itemLink = GetLootRollItemLink(rollId)
    self:Trace("RecordLootRoll", rollId, itemLink)

    if itemLink == nil then
        return false
    end

    local _, _, itemCount = GetLootRollItemInfo(rollId)
    local _, _, _, itemLevel = GetItemInfo(itemLink)

    local record = self.db.profile[itemLink]

    if record == nil then
        record = { itemCount or 1, itemLevel or 1, rollMode }
    else
        record = {
            math.max(record.itemCount, itemCount),
            math.max(record.itemLevel, itemLevel),
            rollMode
        }
    end

    self.db.profile[itemLink] = record
    return true
end

function LootRememberer:START_LOOT_ROLL(_, rollId)
    C_Timer.After(0, function ()
        -- ElvUI creates its loot frames as START_LOOT_ROLL events occur so we need to repeatedly try hooking up.
        self:HookIntoElvUI()

        self:DeferredLootRollHandler(rollId)
    end)
end

function LootRememberer:DeferredLootRollHandler(rollId)
    local itemLink = GetLootRollItemLink(rollId)
    local record = self.db.profile[itemLink]
    self:Trace("HandleNewLootRoll", rollId, itemLink, record)

    if record == nil then
        return
    end

    local _, _, itemCount = GetLootRollItemInfo(rollId)
    local _, _, _, itemLevel = GetItemInfo(itemLink)

    local recordedItemCount, recordedItemLevel, rollMode = unpack(record)

    if itemCount > recordedItemCount or itemLevel > recordedItemLevel then
        return
    end

    RollOnLoot(rollId, rollMode)
    C_Timer.After(0, function () ConfirmLootRoll(rollId, rollMode) end)
end

function LootRememberer:DeleteRecordedLootRoll(itemLink)
    self.db.profile[itemLink] = nil
end

function LootRememberer:SlashProcessor()
    if self.guiContainer:IsVisible() then
        self.guiContainer:Hide()
    else
        self.guiContainer:Show()
    end
end

function LootRememberer:GUIPrepare()
    -- Very suboptimal 😦 Dunno how to align text, or to set up a "regular" close button (e.g. bag frame close button)...
    -- Also struggling to keep control of frame positioning;
    -- e.g. if I put the rollModeIcon into the countLabel (using SetImage) then it would wrap onto two lines regardless of what height settings I tried providing 🤔
    -- Also couldn't call :Hide() on the recordFrame SimpleGroup for some reason 😱

    self.guiState = {
        filter = "",
        currentPage = 1,
        lastPage = 1,
        totalRecordCount = 0,
    }

    self.guiContainer = AceGUI:Create("Frame")
    self.guiContainer:EnableResize(false)
    self.guiContainer:SetTitle(L["Loot Rememberer"])
    self.guiContainer:SetStatusText(L["Left click on an item to remove its record"])
    self.guiContainer:SetLayout("List")
    self.guiContainer:SetWidth(514)
    self.guiContainer:SetHeight(350)
    self.guiContainer:SetAutoAdjustHeight(false)
    self.guiContainer:Hide()
    self:Hook(self.guiContainer, "Show", function () self:GUIRefreshPagination() end)
    _G["LootRemembererGUIContainer"] = self.guiContainer.frame
    self.guiContainer:SetCallback("OnShow", function () tinsert(UISpecialFrames, "LootRemembererGUIContainer") end)

    local horizontalContainer = AceGUI:Create("SimpleGroup")
    horizontalContainer:SetFullWidth(true)
    horizontalContainer:SetLayout("Flow")
    horizontalContainer:SetHeight(80)
    horizontalContainer:SetAutoAdjustHeight(false)

    local searchInput = AceGUI:Create("EditBox")
    searchInput:SetLabel(L["Filter:"])
    searchInput:SetWidth(200)
    searchInput:SetHeight(50)
    searchInput:SetCallback("OnEnterPressed", function (_, _, text) self:GUIUseFilter(text) end)
    horizontalContainer:AddChild(searchInput)

    local spacer = AceGUI:Create("SimpleGroup")
    spacer:SetWidth(10)
    spacer:SetLayout("Flow")
    horizontalContainer:AddChild(spacer)

    local firstButton = AceGUI:Create("Button")
    firstButton:SetText("<<")
    firstButton:SetWidth(50)
    firstButton:SetCallback("OnClick", function () self:GUIChangeToPage(1) end)
    horizontalContainer:AddChild(firstButton)

    local previousButton = AceGUI:Create("Button")
    previousButton:SetText("<")
    previousButton:SetWidth(50)
    previousButton:SetCallback("OnClick", function () self:GUIChangeToPage(self.guiState.currentPage - 1) end)
    horizontalContainer:AddChild(previousButton)

    local spacer2 = AceGUI:Create("SimpleGroup")
    spacer2:SetWidth(15)
    spacer2:SetLayout("Flow")
    horizontalContainer:AddChild(spacer2)

    self.guiContainer.paginationText = AceGUI:Create("Label")
    self.guiContainer.paginationText:SetText("99 / 99")
    self.guiContainer.paginationText:SetWidth(54)
    horizontalContainer:AddChild(self.guiContainer.paginationText)

    local nextButton = AceGUI:Create("Button")
    nextButton:SetText(">")
    nextButton:SetWidth(50)
    nextButton:SetCallback("OnClick", function () self:GUIChangeToPage(self.guiState.currentPage + 1) end)
    horizontalContainer:AddChild(nextButton)

    local lastButton = AceGUI:Create("Button")
    lastButton:SetText(">>")
    lastButton:SetWidth(50)
    lastButton:SetCallback("OnClick", function () self:GUIChangeToPage(self.guiState.lastPage) end)
    horizontalContainer:AddChild(lastButton)

    self.guiContainer:AddChild(horizontalContainer)

    local recordContainer = AceGUI:Create("SimpleGroup")
    recordContainer:SetFullWidth(true)
    recordContainer:SetLayout("List")

    self.guiContainer.entries = {}
    for i = 1, GUI_NUM_RECORDS_PER_PAGE do
        local recordFrame = AceGUI:Create("SimpleGroup")
        recordFrame:SetHeight(18)
        recordFrame:SetFullWidth(true)
        recordFrame:SetAutoAdjustHeight(false)
        recordFrame:SetLayout("Flow")

        local rollModeIcon = AceGUI:Create("Icon")
        rollModeIcon:SetWidth(18)
        rollModeIcon:SetHeight(18)
        rollModeIcon:SetImageSize(18, 18)
        recordFrame:AddChild(rollModeIcon)

        local countLabel = AceGUI:Create("Label")
        countLabel:SetWidth(21)
        recordFrame:AddChild(countLabel)

        local itemLabel = AceGUI:Create("InteractiveLabel")
        itemLabel:SetWidth(439)
        local enterItemLabel = function ()
            if recordFrame.itemLink == nil then
                return
            end

            GameTooltip:SetOwner(itemLabel.frame, "ANCHOR_TOPLEFT")
            GameTooltip:SetHyperlink(recordFrame.itemLink)
            GameTooltip:Show()
        end
        local leaveItemLabel = function ()
            if recordFrame.itemLink == nil then
                return
            end

            GameTooltip:Hide()
        end
        itemLabel:SetCallback("OnClick", function ()
            self:DeleteRecordedLootRoll(recordFrame.itemLink)
            leaveItemLabel()
            self:GUIRefreshPagination()
            enterItemLabel()
        end)
        itemLabel:SetCallback("OnEnter", enterItemLabel)
        itemLabel:SetCallback("OnLeave", leaveItemLabel)
        recordFrame:AddChild(itemLabel)

        recordFrame.Update = function (_, itemLink, details)
            local itemCount, _, rollMode = unpack(details)

            recordFrame.itemLink = itemLink
            local itemName, _, itemQuality, _, _, _, _, _, _, itemTexture = GetItemInfo(itemLink)

            rollModeIcon:SetImage(ROLL_TYPES[rollMode].normalTexture)

            if itemCount == 1 then
                countLabel:SetText("")
            else
                countLabel:SetText("(" .. itemCount .. ")")
            end

            itemLabel:SetText("[" .. itemName .. "]")
            local color = ITEM_QUALITY_COLORS[itemQuality]
            itemLabel:SetColor(color.r, color.g, color.b)
            itemLabel:SetImage(itemTexture)
        end

        recordFrame.Clear = function ()
            recordFrame.itemLink = nil
            rollModeIcon:SetImage(nil)
            countLabel:SetText("")
            itemLabel:SetText("")
            itemLabel:SetImage(nil)
        end

        self.guiContainer.entries[i] = recordFrame
        recordContainer:AddChild(recordFrame)
    end

    self.guiContainer:AddChild(recordContainer)
end

function LootRememberer:GUIRefreshPagination()
    self:GUISetTotalRecordCount()
    self:GUIClampCurrentPage()
    self:GUIRefreshCurrentPageDisplay()
    self:GUIRefreshPageNumberLabel()
end

function LootRememberer:GUISetTotalRecordCount()
    local count = 0
    for itemLink, _ in pairs(self.db.profile) do
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
    local firstRecordIndex = (self.guiState.currentPage - 1) * 10 + 1
    local lastRecordIndex = firstRecordIndex + GUI_NUM_RECORDS_PER_PAGE - 1
    local currentRecordIndex = 1
    local recordFrameIndex = 1

    for itemLink, details in pairs(self.db.profile) do
        if self:GUIDoesItemLinkMatchFilter(itemLink) then
            local thisRecordIndex = currentRecordIndex
            currentRecordIndex = currentRecordIndex + 1

            if thisRecordIndex > lastRecordIndex then
                break
            end
            if thisRecordIndex >= firstRecordIndex then
                self.guiContainer.entries[recordFrameIndex]:Update(itemLink, details)
                recordFrameIndex = recordFrameIndex + 1
            end
        end
    end

    for i = recordFrameIndex, GUI_NUM_RECORDS_PER_PAGE do
        self.guiContainer.entries[i]:Clear()
    end
end

function LootRememberer:GUIRefreshPageNumberLabel()
    self.guiContainer.paginationText:SetText(self.guiState.currentPage .. " / " .. self.guiState.lastPage)
end

function LootRememberer:GUIUseFilter(text)
    self.guiState.filter = text:lower()
    self:GUIRefreshPagination()
end

function LootRememberer:GUIDoesItemLinkMatchFilter(itemLink)
    if self.guiState.filter == "" or self.guiState.filter == nil then
        return true
    end
    return string.find(itemLink:lower(), self.guiState.filter)
end

function LootRememberer:GUIChangeToPage(pageNumber)
    self.guiState.currentPage = pageNumber
    self:GUIClampCurrentPage()
    self:GUIRefreshPageNumberLabel()
    self:GUIRefreshCurrentPageDisplay()
end