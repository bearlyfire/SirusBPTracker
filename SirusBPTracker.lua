local frame = CreateFrame("Frame")
--sbpt-v312: ОФИЦИАЛЬНАЯ РЕГИСТРАЦИЯ ВСЕХ ЖИВЫХ СОБЫТИЙ ДЛЯ ОСНОВНОГО ФРЕЙМА АДДОНА
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
--sbpt-v336: РЕГИСТРАЦИЯ СЕРВЕРНОГО СИГНАЛА ГОТОВНОСТИ ДАННЫХ КД
frame:RegisterEvent("QUEST_QUERY_COMPLETE")

-- Просто объявляем имена для БД
SirusBPTrackerDB = SirusBPTrackerDB
SirusBPTrackerFilterDB = SirusBPTrackerFilterDB
SirusBPTrackerCharFilterDB = SirusBPTrackerCharFilterDB
SirusBPTrackerConfig = SirusBPTrackerConfig
SirusBPTrackerNewQuestDB = SirusBPTrackerNewQuestDB

-- Таблица чистых HEX-цветов классов
local CLASS_COLORS = {
    ["WARRIOR"]     = "c79c6e", ["PALADIN"]     = "f58cba",
    ["HUNTER"]      = "abd473", ["ROGUE"]       = "fff569",
    ["PRIEST"]      = "ffffff", ["DEATHKNIGHT"] = "c41f3b",
    ["SHAMAN"]      = "0070de", ["MAGE"]        = "69ccf0",
    ["WARLOCK"]     = "9482c9", ["DRUID"]       = "ff7d0a",
}

-- Пул для FontString
local fontStringPool = {}
local activeStrings = {}
--sbpt-v173: ОБЪЯВЛЕНИЕ ВЫСОКОПРОИЗВОДИТЕЛЬНОГО ОЗУ-КЭША ДЛЯ ЗАЩИТЫ ДИСКА ОТ МИКРОФРИЗОВ
local ramCacheDB = {}
local bonusXPApiErrorReported = false

local function GetAnyText(obj)
    if not obj then return nil end
    if obj.GetText and obj:GetText() and obj:GetText() ~= "" then return obj:GetText() end
    if obj.Text and obj.Text.GetText and obj.Text:GetText() and obj.Text:GetText() ~= "" then return obj.Text:GetText() end
    return nil
end

-------------------------------------------------------------------------------
-- GUI ИНТЕРФЕЙС И ПОИСКОВАЯ СТРОКА
-------------------------------------------------------------------------------
local mainGui = nil
local filterGui = nil
local helpGui = nil
local UpdateGUIText
local CreateFilterGUI
local CreateHelpGUI
local MAIN_MIN_WIDTH = 430
local MAIN_MIN_HEIGHT = 250
local PROGRESS_COLUMN_MIN_WIDTH = 205
local PROGRESS_COLUMN_GAP = 8
local MAIN_FONT_MIN_SIZE = 9
local MAIN_FONT_MAX_SIZE = 16
local newQuestTagLabels = {}
local newQuestTagPulse = CreateFrame("Frame")
local newQuestTagPulseElapsed = 0
local newQuestTagPulseAlpha = 1
newQuestTagPulse:SetScript("OnUpdate", function(self, elapsed)
    if #newQuestTagLabels == 0 then
        self:Hide()
        return
    end
    newQuestTagPulseElapsed = newQuestTagPulseElapsed + elapsed
    if newQuestTagPulseElapsed >= 0.45 then
        newQuestTagPulseElapsed = 0
        newQuestTagPulseAlpha = newQuestTagPulseAlpha == 1 and 0.25 or 1
        for _, label in ipairs(newQuestTagLabels) do
            if label:IsShown() then label:SetAlpha(newQuestTagPulseAlpha) end
        end
    end
end)
newQuestTagPulse:Hide()

local characterSummaryItems = {}
local characterSummaryPulse = CreateFrame("Frame")
local characterSummaryElapsed = 0
local characterSummaryAlpha = 1
characterSummaryPulse:SetScript("OnUpdate", function(self, elapsed)
    characterSummaryElapsed = characterSummaryElapsed + elapsed
    if characterSummaryElapsed >= 0.45 then
        characterSummaryElapsed = 0
        characterSummaryAlpha = characterSummaryAlpha == 1 and 0.35 or 1
        for _, item in ipairs(characterSummaryItems) do
            if item.warning and item.name then
                local red, green, blue = unpack(item.classColor)
                if characterSummaryAlpha < 1 then
                    item.name:SetTextColor(0.65, 0.65, 0.65, 1)
                else
                    item.name:SetTextColor(red, green, blue, 1)
                end
            end
        end
    end
    self.refreshElapsed = (self.refreshElapsed or 0) + elapsed
    if self.refreshElapsed >= 2 then
        self.refreshElapsed = 0
        if mainGui and mainGui:IsShown() and mainGui.UpdateCharacterSummary then
            mainGui.UpdateCharacterSummary()
        end
    end
end)

local function GetQuestPeriodStart(questType, currentTime)
    local reset = date("*t", currentTime)
    reset.hour = 3
    reset.min = 0
    reset.sec = 0
    local resetTime = time(reset)
    if tonumber(questType) == 1 then
        if currentTime < resetTime then resetTime = resetTime - 86400 end
        return resetTime
    end
    local daysSinceThursday = reset.wday - 5
    if daysSinceThursday < 0 then daysSinceThursday = daysSinceThursday + 7 end
    resetTime = resetTime - (daysSinceThursday * 86400)
    if reset.wday == 5 and currentTime < resetTime then
        resetTime = resetTime - (7 * 86400)
    end
    return resetTime
end

local function GetCharacterResetWarnings(charData, currentTime)
    local lastScanTime = tonumber(charData and charData.lastScanTime)
    if not lastScanTime then return true, true end
    return lastScanTime < GetQuestPeriodStart(1, currentTime),
        lastScanTime < GetQuestPeriodStart(2, currentTime)
end

local function IsNewTrackedQuest(realm, characters)
    if not SirusBPTrackerNewQuestDB or not SirusBPTrackerNewQuestDB[realm] then return false end
    local currentTime = time()
    for _, character in ipairs(characters) do
        local questID = character.questID or (character.rawQuest and character.rawQuest.id)
        local record = SirusBPTrackerNewQuestDB[realm][character.name]
        local newQuest = record and record.newQuests and record.newQuests[tostring(questID)]
        if newQuest and newQuest.periodStart == GetQuestPeriodStart(newQuest.type, currentTime) then
            return true
        end
    end
    return false
end

local RED_BUTTON_COLOR = { 0.38, 0.07, 0.08, 0.95 }
local RED_BUTTON_HOVER_COLOR = { 0.56, 0.10, 0.10, 1 }
local BLUE_TAB_COLOR = { 0.08, 0.22, 0.38, 0.95 }
local escapeFrameUpdate = CreateFrame("Frame")

local function GetMainBackgroundColor()
    local color = SirusBPTrackerConfig and SirusBPTrackerConfig.BackgroundColor
    if type(color) == "table" then
        local r, g, b = tonumber(color[1]), tonumber(color[2]), tonumber(color[3])
        if r and g and b then return r, g, b end
    end
    return 0.12, 0.14, 0.18
end

local function GetProgressBarColor()
    local color = SirusBPTrackerConfig and SirusBPTrackerConfig.ProgressBarColor
    if type(color) == "table" then
        local r, g, b = tonumber(color[1]), tonumber(color[2]), tonumber(color[3])
        if r and g and b then return r, g, b end
    end
    return 0, 0.5, 0.6
end

local function GetMainFontSize()
    local size = tonumber(SirusBPTrackerConfig and SirusBPTrackerConfig.FontSize) or 11
    return math.max(MAIN_FONT_MIN_SIZE, math.min(MAIN_FONT_MAX_SIZE, math.floor(size + 0.5)))
end

local function SetAddonBackgroundColor(frame)
    if not frame or not frame.SetBackdropColor then return end
    local r, g, b = GetMainBackgroundColor()
    frame:SetBackdropColor(r, g, b, 0.8)
end

local function RemoveAddonEscapeFrame(frameName)
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == frameName then
            table.remove(UISpecialFrames, i)
        end
    end
end

local function UpdateAddonEscapeFrame()
    RemoveAddonEscapeFrame("SirusBPMainFrame")
    RemoveAddonEscapeFrame("SirusBPFilterGUI")
    RemoveAddonEscapeFrame("SirusBPHelpGUI")

    local activeFrameName
    if helpGui and helpGui:IsShown() then
        activeFrameName = "SirusBPHelpGUI"
    elseif filterGui and filterGui:IsShown() then
        activeFrameName = "SirusBPFilterGUI"
    elseif mainGui and mainGui:IsShown() then
        activeFrameName = "SirusBPMainFrame"
    end
    if activeFrameName then
        table.insert(UISpecialFrames, activeFrameName)
    end
end

local function ScheduleAddonEscapeFrameUpdate()
    escapeFrameUpdate.elapsed = 0
    escapeFrameUpdate:Show()
    escapeFrameUpdate:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed >= 0.1 then
            self:SetScript("OnUpdate", nil)
            UpdateAddonEscapeFrame()
        end
    end)
end

local settingsFontDefaults = setmetatable({}, { __mode = "k" })
local function ApplySettingsFontSize(root)
    if not root then return end
    local fontSize = GetMainFontSize()
    local function Visit(frame)
        local regions = { frame:GetRegions() }
        for _, region in ipairs(regions) do
            if region and region:IsObjectType("FontString") then
                local font, size, flags = region:GetFont()
                if font and size then
                    if not settingsFontDefaults[region] then
                        settingsFontDefaults[region] = { font = font, size = size, flags = flags }
                    end
                    local original = settingsFontDefaults[region]
                    region:SetFont(original.font, math.max(8, math.floor(original.size * fontSize / 11 + 0.5)), original.flags)
                end
            end
        end
        local children = { frame:GetChildren() }
        for _, child in ipairs(children) do
            Visit(child)
        end
    end
    Visit(root)
end

local function SetRedButtonStyle(button)
    if not button.SetBackdrop then return end
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    button:SetBackdropColor(unpack(RED_BUTTON_COLOR))
    button:SetBackdropBorderColor(0.65, 0.18, 0.18, 1)
    button:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(RED_BUTTON_HOVER_COLOR))
        self:SetBackdropBorderColor(0.95, 0.65, 0.2, 1)
    end)
    button:SetScript("OnLeave", function(self)
        self:SetBackdropColor(unpack(RED_BUTTON_COLOR))
        self:SetBackdropBorderColor(0.65, 0.18, 0.18, 1)
    end)
end

local function SetBlueTabStyle(button, active)
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    if active then
        button:SetBackdropColor(unpack(BLUE_TAB_COLOR))
        button:SetBackdropBorderColor(0.25, 0.65, 0.9, 1)
        if button.text then button.text:SetTextColor(1, 0.82, 0) end
    else
        button:SetBackdropColor(0.04, 0.06, 0.10, 0.85)
        button:SetBackdropBorderColor(0.18, 0.24, 0.32, 1)
        if button.text then button.text:SetTextColor(0.65, 0.7, 0.78) end
    end
end

--sbpt-v50-ui-rebuild: ПОЛНОЕ ОБНОВЛЕНИЕ СТРУКТУРЫ ОКНА (ПРАВИЛЬНЫЕ ВКЛАДКИ)
CreateMainGUI = function()
    if mainGui then return mainGui end

    if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
    local gui = CreateFrame("Frame", "SirusBPMainFrame", UIParent)
	--sbpt-v466: РЕГИСТРАЦИЯ ГЛАВНОГО ОКНА АДДОНА В СИСТЕМЕ ВСПЛЫВАЮЩИХ ОКOН ДЛЯ ЗАКРЫТИЯ ПО ESC
    gui:SetScript("OnHide", ScheduleAddonEscapeFrameUpdate)

    local savedWidth = math.min(UIParent:GetWidth(), math.max(MAIN_MIN_WIDTH, tonumber(SirusBPTrackerConfig.MainFrameWidth) or 520))
    local savedHeight = math.min(UIParent:GetHeight(), math.max(MAIN_MIN_HEIGHT, tonumber(SirusBPTrackerConfig.MainFrameHeight) or 450))
    gui:SetSize(savedWidth, savedHeight)
    gui:SetPoint("CENTER", 0, 0)
    gui:SetResizable(true)
    gui:SetMinResize(MAIN_MIN_WIDTH, MAIN_MIN_HEIGHT)
    gui:SetMaxResize(UIParent:GetWidth(), UIParent:GetHeight())
    gui:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    SetAddonBackgroundColor(gui)
    gui:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    local headerBackground = gui:CreateTexture(nil, "BACKGROUND")
    headerBackground:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerBackground:SetPoint("TOPLEFT", gui, "TOPLEFT", 4, -4)
    headerBackground:SetPoint("TOPRIGHT", gui, "TOPRIGHT", -4, -4)
    headerBackground:SetHeight(29)
    headerBackground:SetVertexColor(0, 0, 0, 0.45)

    -- Область перемещения за верхнюю рамку (высота 30 пикселей)
    gui:SetMovable(true)
    gui:EnableMouse(true)
    local titleRegion = gui:CreateTitleRegion()
    titleRegion:SetPoint("TOPLEFT", gui, "TOPLEFT", 0, 0)
    titleRegion:SetPoint("BOTTOMRIGHT", gui, "TOPRIGHT", -310, -30)

    local title = gui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -15)
    title:SetText("Sirus BP Tracker")

    local topControls = CreateFrame("Frame", nil, gui)
    topControls:SetSize(116, 28)
    topControls:SetPoint("TOP", gui, "TOP", 0, -5)

    local closeBtn = CreateFrame("Button", nil, gui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", topControls, "TOPRIGHT", 0, 4)
    SetRedButtonStyle(closeBtn)
    closeBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 10,
        insets = { left = 7, right = 7, top = 7, bottom = 7 }
    })
    closeBtn:SetBackdropColor(unpack(RED_BUTTON_COLOR))
    closeBtn:SetBackdropBorderColor(0.65, 0.18, 0.18, 1)

    local filterBtn = CreateFrame("Button", nil, gui)
    filterBtn:SetSize(20, 20)
    filterBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, -5)
    SetRedButtonStyle(filterBtn)
    filterBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    filterBtn:SetPushedTexture("Interface\\Buttons\\UI-OptionsButton")
    filterBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    filterBtn:SetScript("OnClick", function()
        if CreateFilterGUI then
            local f = CreateFilterGUI()
            if f:IsShown() then f:Hide() else f:Show() end
        end
    end)

--sbpt-v196: ПЕРЕРАБОТКА КНОПКИ СПРАВКИ "?" В ОБЩИЙ СТРОГИЙ СТИЛЬ С ПРАВИЛЬНОЙ ГЕОМЕТРИЕЙ И ПОДЛОЖКОЙ
    local helpBtn = CreateFrame("Button", "SirusBPHelpButton", gui)
    helpBtn:SetSize(20, 20) -- Установили идеальный размер 20x20 вровень с шестеренкой настроек
    helpBtn:SetPoint("RIGHT", filterBtn, "LEFT", -5, 0) -- Садится строго левее шестеренки
    SetRedButtonStyle(helpBtn)
    helpBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    
    -- Применяем фирменную темную полупрозрачную подложку нашего аддона
    helpBtn:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    helpBtn:SetBackdropColor(unpack(RED_BUTTON_COLOR))
    helpBtn:SetBackdropBorderColor(0.65, 0.18, 0.18, 1)

    -- Рисуем аккуратный, центрированный знак вопроса без сверхжирных наложений
    local helpBtnText = helpBtn:CreateFontString(nil, "OVERLAY")
    helpBtnText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    helpBtnText:SetPoint("CENTER", 0, 0) -- Идеальный центр прямоугольной кнопки
    helpBtnText:SetText("?")
    helpBtnText:SetTextColor(0.7, 0.7, 0.7, 1) -- Сдержанный серебристо-серый цвет в общий тон шапки

    helpBtn.text = helpBtnText

    -- Подсветка при наведении мыши
    helpBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(RED_BUTTON_HOVER_COLOR))
        self:SetBackdropBorderColor(0.95, 0.65, 0.2, 1)
        self.text:SetTextColor(1, 1, 1)
    end)
    helpBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(unpack(RED_BUTTON_COLOR))
        self:SetBackdropBorderColor(0.65, 0.18, 0.18, 1)
        self.text:SetTextColor(1, 0.82, 0)
    end)

    -- Скрипт клика
    helpBtn:SetScript("OnClick", function()
        if CreateHelpGUI then
            local h = CreateHelpGUI()
            if h:IsShown() then h:Hide() else h:Show() end
        end
    end)
--sbpt-v108-help-button-final: КОНЕЦ ФИКСА КНОПКИ
--sbpt-v195: КНОПКА "БП" С АДРЕСНЫМ КЛИКОМ ПО НАДЛЕЖАЩЕЙ КНОПКЕ СИРУСА И СТАБИЛЬНЫМ СДВИГОМ ПОИСКА
--sbpt-v286: СКРЫТИЕ КАСТОМНОЙ КНОПКИ БП ДЛЯ ПЕРСОНАЖЕЙ НИЖЕ 80 УРОВНЯ
    local sirusBpOpenBtn = CreateFrame("Button", "SirusBPOpenNativeBtn", gui)
    sirusBpOpenBtn:SetSize(32, 20)
    sirusBpOpenBtn:SetPoint("RIGHT", helpBtn, "LEFT", -5, 0) -- Садится ровно левее золотого знака "?"
    SetRedButtonStyle(sirusBpOpenBtn)
    local sirusBpOpenText = sirusBpOpenBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sirusBpOpenText:SetPoint("CENTER")
    sirusBpOpenText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    sirusBpOpenText:SetText("БП")

    -- ЖЕЛЕЗНЫЙ ФИЛЬТР УРОВНЯ: Если персонаж ниже 80 уровня, наша кнопка бесшумно скрывается с холста
    local playerLevel = UnitLevel("player") or 1
    if playerLevel < 80 then
        sirusBpOpenBtn:Hide()
    else
        sirusBpOpenBtn:Show()
    end

    sirusBpOpenBtn:SetScript("OnClick", function()
        -- Дополнительный рубеж безопасности: блокируем клик, если кнопку вызвали из стороннего макроса
        if (UnitLevel("player") or 1) < 80 then return end

        -- Не трогаем окно, если оно уже открыто.
        if BattlePassFrame and BattlePassFrame.IsShown and BattlePassFrame:IsShown() then
            return
        end

        -- Открываем официальное окно БП Сируса.
        if ToggleBattlePassFrame then
            pcall(ToggleBattlePassFrame)
        elseif BattlePassFrame and BattlePassFrame.Show then
            BattlePassFrame:Show()
        end

        local frame = BattlePassFrame
        if frame and frame:IsShown() and UIParent and GetScreenWidth and GetScreenHeight then
            local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
            if screenWidth > 0 and screenHeight > 0 then
                local nativeScale = math.min(screenWidth / 1920, screenHeight / 1080, 1)
                frame:SetScale(nativeScale)
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            else
                print("|cffff0000[SBPT] Не удалось определить разрешение окна игры для масштабирования Боевого пропуска.|r")
            end

            if BattlePassFrameTopPanelQuestPageButton and BattlePassFrameTopPanelQuestPageButton.Click then
                pcall(BattlePassFrameTopPanelQuestPageButton.Click, BattlePassFrameTopPanelQuestPageButton)
            end
        end
    end)


    -- ИСПРАВЛЕНО: Жесткая привязка к стабильной helpBtn со сдвигом влево на -52 (строка гарантированно на месте!)
    local searchBox = CreateFrame("EditBox", "SirusBPSearchBox", gui)
    searchBox:SetSize(130, 20)
    topControls:ClearAllPoints()
    topControls:SetPoint("TOPRIGHT", gui, "TOPRIGHT", -5, -5)
    searchBox:SetPoint("RIGHT", topControls, "LEFT", -8, 1)
    searchBox:SetWidth(math.max(90, math.min(160, gui:GetWidth() - 335)))
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject("GameFontHighlightSmall")
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 12, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    searchBox:SetBackdropColor(0, 0, 0, 0.65)
    searchBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    titleRegion:ClearAllPoints()
    titleRegion:SetPoint("TOPLEFT", gui, "TOPLEFT", 0, 0)
    titleRegion:SetPoint("BOTTOMRIGHT", searchBox, "TOPLEFT", -8, -25)

    local headerSeparator = gui:CreateTexture(nil, "BORDER")
    headerSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerSeparator:SetHeight(1)
    headerSeparator:SetPoint("TOPLEFT", gui, "TOPLEFT", 8, -32)
    headerSeparator:SetPoint("TOPRIGHT", gui, "TOPRIGHT", -8, -32)
    headerSeparator:SetVertexColor(0.85, 0.65, 0.25, 0.9)

    local contentBottomAnchor = CreateFrame("Frame", nil, gui)
    contentBottomAnchor:SetSize(1, 1)
    contentBottomAnchor:SetPoint("BOTTOMRIGHT", gui, "BOTTOMRIGHT", -30, 34)

    local searchPrompt = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchPrompt:SetPoint("LEFT", searchBox, "LEFT", 6, 0)
    searchPrompt:SetText("Поиск...")

    searchBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then searchPrompt:Hide() else searchPrompt:Show() end
        if UpdateGUIText then UpdateGUIText() end
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        gui:Hide()
    end)

    -- ИСПРАВЛЕНО: Скролл-фрейм для твинков (Вкладка 1)
    local scrollFrame = CreateFrame("ScrollFrame", "SirusBPScrollFrame", gui, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 10, -75)
    scrollFrame:SetPoint("BOTTOMRIGHT", contentBottomAnchor, "TOPRIGHT")

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(460, 1)
    scrollFrame:SetScrollChild(scrollChild)
    gui.scrollChild = scrollChild
    scrollChild:SetWidth(math.max(1, scrollFrame:GetWidth() - 20))

    -- ИСПРАВЛЕНО: Создаем независимый скролл-фрейм для сборов (Вкладка 2) без капризных чат-окон!
    local sborScrollFrame = CreateFrame("ScrollFrame", "SirusBPSborScrollFrame", gui, "UIPanelScrollFrameTemplate")
    sborScrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 10, -75)
    sborScrollFrame:SetPoint("BOTTOMRIGHT", contentBottomAnchor, "TOPRIGHT")

    local sborScrollChild = CreateFrame("Frame", nil, sborScrollFrame)
        sborScrollChild:SetSize(460, 1)
    sborScrollChild:SetAllPoints() -- Жесткое выравнивание
    -- Убираем белый фон, делая холст прозрачным
    if sborScrollChild.SetBackdrop then sborScrollChild:SetBackdrop(nil) end 

    sborScrollFrame:SetScrollChild(sborScrollChild)
	--sbpt-v121-scroll-and-timer: НЕЗАВИСИМЫЙ ТАЙМЕР + СКРОЛЛИНГ КОЛЕСИКОМ ДЛЯ ВКЛАДКИ СБОРОВ
    -- 1. ЧЕСТНЫЙ ТАЙМЕР: Обновляет окно ровно раз в 60 секунд, но только когда вкладка ОТКРЫТА!
    local realTimeTicker = 0
    sborScrollFrame:SetScript("OnUpdate", function(self, elapsed)
        realTimeTicker = realTimeTicker + elapsed
        if realTimeTicker >= 60 then -- Ровно 60 реальных секунд на часах
            realTimeTicker = 0
            if UpdateGUIText then UpdateGUIText() end -- Бесшумно перерисовываем минуты и чистим базу
        end
    end)

    -- 2. ВЫСОТА ПРОКРУТКИ: Включаем плавное пролистывание списка колесиком мыши
    sborScrollFrame:EnableMouseWheel(true)
    sborScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local currentScroll = self:GetVerticalScroll()
        -- Листаем по 24 пикселя (строго на высоту одной сочной строки сбора)
        local newScroll = currentScroll - (delta * 24)
        
        -- Ставим жесткие математические границы, чтобы список не улетал в пустоту
        if newScroll < 0 then newScroll = 0 end
        local maxScroll = self:GetVerticalScrollRange() or 0
        if newScroll > maxScroll then newScroll = maxScroll end
        
        self:SetVerticalScroll(newScroll)
    end)
--sbpt-v121-scroll-and-timer: КОНЕЦ ФИКСА ВКЛАДКИ СБОРОВ

    gui.sborScrollChild = sborScrollChild
    gui.sborScrollFrame = sborScrollFrame

--sbpt-v293: МОДЕРНИЗАЦИЯ СИСТЕМЫ ВКЛАДОК: ДОБАВЛЕНИЕ ТРЕТЬЕЙ ВКЛАДКИ "АКТИВНОСТИ" И НОВОГО ХОЛСТА
    -- Инициализируем новый глобальный скролл-фрейм для холста активностей, если он еще не создан
    if not activitiesScrollFrame then
        activitiesScrollFrame = CreateFrame("ScrollFrame", "SirusBPActivitiesScrollFrame", gui, "UIPanelScrollFrameTemplate")
        activitiesScrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 15, -75)
        activitiesScrollFrame:SetPoint("BOTTOMRIGHT", contentBottomAnchor, "TOPRIGHT")
        activitiesScrollFrame:Hide() -- По умолчанию скрыт
        
        local child = CreateFrame("Frame", nil, activitiesScrollFrame)
        child:SetSize(activitiesScrollFrame:GetWidth(), 1)
        activitiesScrollFrame:SetScrollChild(child)
        activitiesScrollFrame.child = child
    end

    local summaryFrame = CreateFrame("Frame", nil, gui)
    summaryFrame:SetPoint("BOTTOMLEFT", gui, "BOTTOMLEFT", 30, 4)
    summaryFrame:SetPoint("BOTTOMRIGHT", gui, "BOTTOMRIGHT", -30, 4)
    summaryFrame:SetHeight(14)
    gui.summaryBottomOffset = 34

    local summarySeparator = gui:CreateTexture(nil, "BORDER")
    summarySeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
    summarySeparator:SetHeight(1)
    summarySeparator:SetPoint("BOTTOMLEFT", summaryFrame, "TOPLEFT", -20, 7)
    summarySeparator:SetPoint("BOTTOMRIGHT", summaryFrame, "TOPRIGHT", 20, 7)
    summarySeparator:SetVertexColor(0.85, 0.65, 0.25, 0.9)

    local function UpdateCharacterSummary()
        local currentRealm = GetRealmName()
        local realmData = ramCacheDB and ramCacheDB[currentRealm]
        local characters = {}
        if realmData then
            for name, data in pairs(realmData) do
                if type(data) == "table" and (not SirusBPTrackerCharFilterDB or SirusBPTrackerCharFilterDB[name] ~= false) then
                    table.insert(characters, { name = name, data = data })
                end
            end
        end
        table.sort(characters, function(a, b) return a.name < b.name end)

        local availableWidth = math.max(1, summaryFrame:GetWidth())
        local lineHeight = 16
        local row, xOffset = 0, 0
        local usedItems = 0
        local now = time()

        for _, character in ipairs(characters) do
            usedItems = usedItems + 1
            local item = characterSummaryItems[usedItems]
            if not item then
                item = {}
                item.button = CreateFrame("Button", nil, summaryFrame)
                item.name = item.button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                item.name:SetPoint("LEFT", item.button, "LEFT", 0, 0)
                item.name:SetJustifyH("LEFT")

                item.details = summaryFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                item.separator = summaryFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

                for _, text in ipairs({ item.name, item.details, item.separator }) do
                    text:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
                end
                item.name:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")

                item.button:SetScript("OnEnter", function(self)
                    local data = self.summaryData
                    if not data then return end
                    local dailyCompleted, dailyTotal = 0, 0
                    local seasonalCompleted, seasonalTotal = 0, 0
                    for _, quest in pairs(data.quests or {}) do
                        local isComplete = quest.progress == "Завершено" or quest.progress == "Завершено!"
                        if tonumber(quest.type) == 1 then
                            dailyTotal = dailyTotal + 1
                            if isComplete then dailyCompleted = dailyCompleted + 1 end
                        elseif tonumber(quest.type) == 2 then
                            seasonalTotal = seasonalTotal + 1
                            if isComplete then seasonalCompleted = seasonalCompleted + 1 end
                        end
                    end

                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:ClearLines()
                    local classColor = CLASS_COLORS[data.class or ""] or "ffffff"
                    local red = tonumber(string.sub(classColor, 1, 2), 16) / 255
                    local green = tonumber(string.sub(classColor, 3, 4), 16) / 255
                    local blue = tonumber(string.sub(classColor, 5, 6), 16) / 255
                    GameTooltip:AddLine(self.summaryName, red, green, blue)
                    if data.battlePassLevel then
                        GameTooltip:AddLine(string.format("Уровень БП: %s (%s/%s)",
                            tostring(data.battlePassLevel),
                            tostring(data.battlePassExperience or 0),
                            tostring(data.battlePassExperienceRequired or 0)), 0.9, 0.9, 0.9)
                    else
                        GameTooltip:AddLine("Уровень БП: нет данных", 0.65, 0.65, 0.65, true)
                    end
                    GameTooltip:AddLine(string.format("Ежедневные задания %d/%d", dailyCompleted, dailyTotal), 0.9, 0.9, 0.9, true)
                    GameTooltip:AddLine(string.format("Сезонные задания %d/%d", seasonalCompleted, seasonalTotal), 0.9, 0.9, 0.9, true)
                    local dailyMayBeNew, seasonalMayBeNew = GetCharacterResetWarnings(data, time())
                    if dailyMayBeNew or seasonalMayBeNew then
                        local warning
                        if dailyMayBeNew and seasonalMayBeNew then
                            warning = "Возможны новые задания: ежедневные и сезонные."
                        elseif dailyMayBeNew then
                            warning = "Возможно новое ежедневное задание."
                        else
                            warning = "Возможно новое сезонное задание."
                        end
                        GameTooltip:AddLine(warning, 1, 0.82, 0, true)
                    end
                    GameTooltip:Show()
                end)
                item.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
                characterSummaryItems[usedItems] = item
            end

            local data = character.data
            local dailyCompleted, seasonalCompleted = 0, 0
            for _, quest in pairs(data.quests or {}) do
                if quest.progress == "Завершено" or quest.progress == "Завершено!" then
                    if tonumber(quest.type) == 1 then dailyCompleted = dailyCompleted + 1
                    elseif tonumber(quest.type) == 2 then seasonalCompleted = seasonalCompleted + 1 end
                end
            end

            local classColor = CLASS_COLORS[data.class or ""] or "ffffff"
            local red = tonumber(string.sub(classColor, 1, 2), 16) / 255
            local green = tonumber(string.sub(classColor, 3, 4), 16) / 255
            local blue = tonumber(string.sub(classColor, 5, 6), 16) / 255
            item.classColor = { red, green, blue }
            item.name:SetText(character.name)
            item.button.summaryName = character.name
            item.button.summaryData = data

            local level = data.battlePassLevel and tostring(data.battlePassLevel) or "?"
            item.details:SetText(string.format("%s/%d", level, seasonalCompleted))
            item.separator:SetText("  |  ")

            local itemWidth = item.name:GetStringWidth() + item.details:GetStringWidth()
            local separatorWidth = usedItems > 1 and item.separator:GetStringWidth() or 0
            if xOffset > 0 and xOffset + separatorWidth + itemWidth > availableWidth then
                row = row + 1
                xOffset = 0
                separatorWidth = 0
            end

            if separatorWidth > 0 then
                item.separator:ClearAllPoints()
                item.separator:SetPoint("BOTTOMLEFT", summaryFrame, "TOPLEFT", xOffset, -(row + 1) * lineHeight + 4)
                item.separator:SetTextColor(0.55, 0.55, 0.55, 1)
                item.separator:Show()
                xOffset = xOffset + separatorWidth
            else
                item.separator:Hide()
            end

            item.button:ClearAllPoints()
            item.button:SetPoint("TOPLEFT", summaryFrame, "TOPLEFT", xOffset, -row * lineHeight + 4)
            item.button:SetSize(item.name:GetStringWidth() + 1, lineHeight)
            item.name:ClearAllPoints()
            item.name:SetPoint("BOTTOMLEFT", item.button, "BOTTOMLEFT", 0, 0)
            xOffset = xOffset + item.name:GetStringWidth() + 2

            item.details:ClearAllPoints()
            item.details:SetPoint("BOTTOMLEFT", summaryFrame, "TOPLEFT", xOffset, -(row + 1) * lineHeight + 4)
            item.details:SetTextColor(0.85, 0.85, 0.85, 1)
            xOffset = xOffset + item.details:GetStringWidth()
            xOffset = xOffset + 10

            local dailyMayBeNew, seasonalMayBeNew = GetCharacterResetWarnings(data, now)
            item.warning = dailyMayBeNew or seasonalMayBeNew
            local alpha = item.warning and characterSummaryAlpha or 1
            if item.warning and alpha < 1 then item.name:SetTextColor(0.65, 0.65, 0.65, 1)
            else item.name:SetTextColor(red, green, blue, 1) end
            item.button:Show()
            item.details:Show()
        end

        for index = usedItems + 1, #characterSummaryItems do
            local item = characterSummaryItems[index]
            item.button:Hide()
            item.details:Hide()
            item.separator:Hide()
        end

        local lineCount = characters and #characters > 0 and row + 1 or 1
        summaryFrame:SetHeight(lineCount * lineHeight)
        local bottomOffset = summaryFrame:GetHeight() + 20
        gui.summaryBottomOffset = bottomOffset
        contentBottomAnchor:ClearAllPoints()
        contentBottomAnchor:SetPoint("BOTTOMRIGHT", gui, "BOTTOMRIGHT", -30, bottomOffset)
        summarySeparator:ClearAllPoints()
        summarySeparator:SetPoint("BOTTOMLEFT", summaryFrame, "TOPLEFT", -20, 7)
        summarySeparator:SetPoint("BOTTOMRIGHT", summaryFrame, "TOPRIGHT", 20, 7)
    end
    gui.UpdateCharacterSummary = UpdateCharacterSummary

    gui.myTabs = {}
    local function SwitchTab(id)
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        SirusBPTrackerConfig.ActiveTab = id
        
        -- УПРАВЛЕНИЕ ВИДИМОСТЬЮ ХОЛСТОВ ТРЕХ ВКЛАДОК
        if id == 1 then
            if scrollFrame then scrollFrame:Show() end
            if sborScrollFrame then sborScrollFrame:Hide() end
            if activitiesScrollFrame then activitiesScrollFrame:Hide() end
            if searchBox then searchBox:Show() end
        elseif id == 2 then
            if scrollFrame then scrollFrame:Hide() end
            if sborScrollFrame then sborScrollFrame:Show() end
            if activitiesScrollFrame then activitiesScrollFrame:Hide() end
            if searchBox then searchBox:Hide() end
        elseif id == 3 then
            if scrollFrame then scrollFrame:Hide() end
            if sborScrollFrame then sborScrollFrame:Hide() end
            if activitiesScrollFrame then activitiesScrollFrame:Show() end
            if searchBox then searchBox:Hide() end
        end

        -- Красивое неоновое переключение цветов для активной и неактивной вкладок
        for tID, btn in ipairs(gui.myTabs) do
            SetBlueTabStyle(btn, tID == id)
        end
		--sbpt-v589: ТОЧЕЧНЫЙ СБРОС АЛЬФЫ ВСЕХ ВКЛАДОК ПРИ ПЕРЕКЛЮЧЕНИИ
        for _, btn in ipairs(gui.myTabs) do if btn and btn.SetAlpha then btn:SetAlpha(1) end end
        if SBPT_ResetMinimapNotification and id == 2 then SBPT_ResetMinimapNotification() end

        if UpdateGUIText then UpdateGUIText() end
        if DrawActivitiesTab then DrawActivitiesTab() end -- Будущий вызов отрисовки таблицы активностей
    end

    -- РАСШИРЯЕМ МАССИВ НАИМЕНОВАНИЙ ВКЛАДОК ДО ТРЕХ
    --sbpt-v448 [ЭТАП 1]: ИСПРАВЛЕНИЕ НЕОНОВОГО ХОВЕРА И СОЗДАНИЕ ВТОРОГО РЯДА СУБ-ВКЛАДОК БП
    -- РАСШИРЯЕМ МАССИВ НАИМЕНОВАНИЙ ВКЛАДКИ ДО ТРЕХ
    local tabNames = { "Квесты персонажей", "Актуальные сборы", "Активности" }
    for i = 1, 3 do
        local tabIndex = i
        local tab = CreateFrame("Button", nil, gui)
        tab:SetSize(140, 22)
        SetBlueTabStyle(tab, false)
        
        if i == 1 then
            tab:SetPoint("TOPLEFT", gui, "TOP", -215, -45)
        else
            tab:SetPoint("LEFT", gui.myTabs[i-1], "RIGHT", 5, 0)
        end

        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.text:SetPoint("CENTER", 0, 0)
        tab.text:SetText(tabNames[i])
        SetBlueTabStyle(tab, false)

        -- ИСПРАВЛЕНО: Полностью восстановлено красивое неоново-синее свечение при наведении мыши!
        tab:SetScript("OnEnter", function(self)
            if SirusBPTrackerConfig.ActiveTab ~= tabIndex then
                self:SetBackdropColor(0.11, 0.28, 0.46, 1)
            end
        end)
        tab:SetScript("OnLeave", function(self)
            if SirusBPTrackerConfig.ActiveTab ~= tabIndex then
                SetBlueTabStyle(self, false)
            end
        end)

        tab:SetScript("OnClick", function() SwitchTab(tabIndex) end)
        gui.myTabs[tabIndex] = tab
    end

    -- СОЗДАЕМ ВТОРОЙ РЯД СУБ-ВКЛАДОК ДЛЯ ПЕРВОЙ ВКЛАДКИ (Все / Ежедневные / Сезонные)
    gui.mySubTabs = {}
    
    local function SwitchSubTab(subID)
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        SirusBPTrackerConfig.ActiveSubTab = subID
        
        -- Управляем цветами и неоновым свечением суб-вкладок БП
        for sID, sBtn in ipairs(gui.mySubTabs) do
            SetBlueTabStyle(sBtn, sID == subID)
        end
        if UpdateGUIText then UpdateGUIText() end
    end
    gui.SwitchSubTab = SwitchSubTab -- Сохраняем метод в контейнер для внешнего вызова
--sbpt-v454: ПЕРЕВОД СУБ-ВКЛАДОК НА МЯГКИЙ СТАЛЬНОЙ СТИЛЬ (БЕЗ КИСЛОТНОСТИ)
    local function SwitchSubTab(subID)
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        SirusBPTrackerConfig.ActiveSubTab = subID
        
        -- Мягкое благородное переключение цветов суб-панели
        for sID, sBtn in ipairs(gui.mySubTabs) do
            SetBlueTabStyle(sBtn, sID == subID)
        end
        if UpdateGUIText then UpdateGUIText() end
    end
    gui.SwitchSubTab = SwitchSubTab

    local subTabNames = { "Все задания", "Ежедневные", "Сезонные" }
    for i = 1, 3 do
        local tabIndex = i
        local subTab = CreateFrame("Button", nil, gui)
        subTab:SetSize(140, 20)
        SetBlueTabStyle(subTab, false)
        
        if i == 1 then
            subTab:SetPoint("TOPLEFT", gui, "TOP", -215, -70)
        else
            subTab:SetPoint("LEFT", gui.mySubTabs[i-1], "RIGHT", 5, 0)
        end

        subTab.text = subTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        subTab.text:SetPoint("CENTER", 0, 0)
        subTab.text:SetText(subTabNames[i])
        SetBlueTabStyle(subTab, false)

        -- МЯГКИЙ ХОВЕР ПРИ НАВЕДЕНИИ МЫШИ (БЕЗ ЯРКОГО СВЕЧЕНИЯ)
        subTab:SetScript("OnEnter", function(self)
            if SirusBPTrackerConfig.ActiveSubTab ~= tabIndex then
                self:SetBackdropColor(0.11, 0.28, 0.46, 1)
            end
        end)
        subTab:SetScript("OnLeave", function(self)
            if SirusBPTrackerConfig.ActiveSubTab ~= tabIndex then
                SetBlueTabStyle(self, false)
            end
        end)

        subTab:SetScript("OnClick", function() SwitchSubTab(tabIndex) end)
        gui.mySubTabs[tabIndex] = subTab
    end


    -- МОДЕРНИЗАЦИЯ СТАРЕНЬКОЙ ФУНКЦИИ ПЕРЕКЛЮЧЕНИЯ ДЛЯ АВТО-СКРЫТИЯ СУБ-ВКЛАДОК
    local originalSwitchTab = SwitchTab
    SwitchTab = function(id)
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        
        -- Вызываем оригинальное управление холстами и подсветкой главных вкладок
        originalSwitchTab(id)
        
        -- ЖЕСТКОЕ УПРАВЛЕНИЕ ВИДИМОСТЬЮ ВТОРОГО РЯДА СУБ-ВКЛАДОК
        if id == 1 then
            -- Если мы на первой вкладке - выводим суб-панель из тени
            for _, sBtn in ipairs(gui.mySubTabs) do sBtn:Show() end
            local savedSub = SirusBPTrackerConfig.ActiveSubTab or 1
            SwitchSubTab(savedSub)
            
            -- Сдвигаем основной скролл-контейнер первой вкладки чуть ниже (на -96), чтобы освободить место
            if scrollFrame then
                scrollFrame:ClearAllPoints()
                scrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 12, -96)
                scrollFrame:SetPoint("BOTTOMRIGHT", contentBottomAnchor, "TOPRIGHT")
                if gui.scrollChild then
                    gui.scrollChild:SetWidth(math.max(1, scrollFrame:GetWidth() - 20))
                end
            end
        else
            -- Если ушли на Сборы или Активности - намертво гасим суб-вкладки с экрана
            for _, sBtn in ipairs(gui.mySubTabs) do sBtn:Hide() end
        end
    end

    gui:SetScript("OnShow", function()
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        UpdateAddonEscapeFrame()
        local savedTab = SirusBPTrackerConfig.ActiveTab or 1
        SwitchTab(savedTab)
    end)

    local function CreateResizeHandle(point, xOffset, yOffset, sizingPoint, isLeft)
        local handle = CreateFrame("Button", nil, gui)
        handle:SetSize(20, 20)
        handle:SetPoint(point, gui, point, xOffset, yOffset)
        handle:SetFrameLevel(gui:GetFrameLevel() + 5)

        for i = 1, 3 do
            local stripe = handle:CreateTexture(nil, "OVERLAY")
            stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
            stripe:SetSize(10, 2)
            stripe:SetVertexColor(0.75, 0.75, 0.75, 0.75)
            stripe:SetRotation(math.pi / 4)
            if isLeft then
                stripe:SetPoint("BOTTOMLEFT", handle, "BOTTOMLEFT", 3 + (i - 1) * 4, 3 + (i - 1) * 4)
            else
                stripe:SetPoint("BOTTOMRIGHT", handle, "BOTTOMRIGHT", -3 - (i - 1) * 4, 3 + (i - 1) * 4)
            end
        end

        handle:SetScript("OnMouseDown", function(_, button)
            if button == "LeftButton" then gui:StartSizing(sizingPoint) end
        end)
        handle:SetScript("OnMouseUp", function()
            gui:StopMovingOrSizing()
        end)
        handle:SetScript("OnEnter", function(self)
            for i = 1, self:GetNumRegions() do
                local region = select(i, self:GetRegions())
                if region and region.SetVertexColor then region:SetVertexColor(1, 1, 1, 1) end
            end
        end)
        handle:SetScript("OnLeave", function(self)
            for i = 1, self:GetNumRegions() do
                local region = select(i, self:GetRegions())
                if region and region.SetVertexColor then region:SetVertexColor(0.75, 0.75, 0.75, 0.75) end
            end
        end)
    end

    CreateResizeHandle("BOTTOMLEFT", 4, 4, "BOTTOMLEFT", true)
    CreateResizeHandle("BOTTOMRIGHT", -4, 4, "BOTTOMRIGHT", false)

    gui:SetScript("OnSizeChanged", function(self, width, height)
        SirusBPTrackerConfig.MainFrameWidth = width
        SirusBPTrackerConfig.MainFrameHeight = height

        if self.scrollChild and scrollFrame then
            self.scrollChild:SetWidth(math.max(1, scrollFrame:GetWidth() - 20))
        end
        if searchBox then searchBox:SetWidth(math.max(90, math.min(160, width - 335))) end
        if activitiesScrollFrame and activitiesScrollFrame.child then
            activitiesScrollFrame.child:SetWidth(math.max(1, activitiesScrollFrame:GetWidth()))
        end

        self.resizeElapsed = 0
        self:SetScript("OnUpdate", function(frame, elapsed)
            frame.resizeElapsed = frame.resizeElapsed + elapsed
            if frame.resizeElapsed >= 0.15 then
                frame:SetScript("OnUpdate", nil)
                if self.scrollChild and scrollFrame then
                    self.scrollChild:SetWidth(math.max(1, scrollFrame:GetWidth() - 20))
                end
                if UpdateGUIText then UpdateGUIText() end
                if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
                    DrawActivitiesTab()
                end
            end
        end)
    end)

    gui:Hide()
    mainGui = gui
    return mainGui
end

--sbpt-v465: ПОЛНАЯ ИЗОЛЯЦИЯ ШРИФТОВ ОТ ГЛОБАЛЬНОЙ ПАМЯТИ WOW ДЛЯ ЗАЩИТЫ ЧАТА ELVUI
local function AcquireFontString(parent, font, r, g, b, justify, width, indent, yOffset)
    local fs
    if #fontStringPool > 0 then
        fs = table.remove(fontStringPool)
        fs:SetParent(parent)
        fs:Show()
    else
        -- ИСПРАВЛЕНО: Явно наследуем NumberFontNormal, полностью изолируя текст от чата ElvUI
        fs = parent:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    end
    fs:ClearAllPoints()
    
    local fontSize = GetMainFontSize()
    if font == "GameFontNormalLarge" then fontSize = fontSize + 2 end
    fs:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
    fs:SetPoint("TOPLEFT", indent or 10, yOffset)
    fs:SetWidth(width or 440)
    fs:SetJustifyH(justify or "LEFT")
    if r then fs:SetTextColor(r, g, b) else fs:SetTextColor(1, 1, 1) end
    table.insert(activeStrings, fs)
    return fs
end


local function ClearFontStringPool()
    for _, obj in ipairs(activeStrings) do
        obj:Hide()
        if obj.SetText and obj:IsObjectType("FontString") then
            obj:SetText("")
            table.insert(fontStringPool, obj)
        end
    end
    activeStrings = {}
end

--sbpt-v172: ПОЛНЫЙ МОНОЛИТ UI С ОБНОВЛЕНИЕМ НА ЛЕТУ И ПОИСКОМ ТВИНКОВ СТРОГО ПО ID КВЕСТОВ
UpdateGUIText = function()
    newQuestTagLabels = {}
    newQuestTagPulseElapsed = 0
    newQuestTagPulseAlpha = 1
    newQuestTagPulse:Hide()

    local gui = CreateMainGUI()
    if gui.UpdateCharacterSummary then gui.UpdateCharacterSummary() end
    local child = gui.scrollChild
    local sborChild = gui.sborScrollChild
    ClearFontStringPool()

    -- ЖЕСТКАЯ ЗАЧИСТКА ХОЛСТА КВЕСТОВ: Скрываем старые текстовые виджеты первой вкладки
    if child and child.widgets then
        for _, widget in ipairs(child.widgets) do
            if widget and widget.Hide then widget:Hide() end
        end
    end
    if child then child.widgets = {} child:SetHeight(0) end -- Обнуляем массив и высоту квестов

    if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
    local activeTab = SirusBPTrackerConfig.ActiveTab or 1
    local currentTime = time()

    -- Счетчик интерактивных элементов для шёпота
    local sborBtnIdx = 1

    -- ========================================================================
    -- ЛОГИКА ВКЛАДКИ 2: АКТУАЛЬНЫЕ СБОРЫ ИЗ ЧАТА СИРУСА (СНИЗУ ВВЕРХ)
    -- ========================================================================
    --sbpt-v175: ПЕРЕВОД ВКЛАДКИ СБОРОВ ЧАТА И ТУЛТИПОВ ТВИНКОВ НА ВЫСОКОПРОИЗВОДИТЕЛЬНЫЙ ОЗУ-КЭШ
    if activeTab == 2 and sborChild then
        if not SirusBPTrackerDB["QUEST_LFG"] then SirusBPTrackerDB["QUEST_LFG"] = {} end
        
        if sborChild.widgets then
            for _, widget in ipairs(sborChild.widgets) do
                if widget and widget.Hide then widget:Hide() end
            end
        end
        sborChild.widgets = {}

        yOffset = -10
        sborBtnIdx = 1
        
        local flatAuthorsList = {}
        if SirusBPTrackerDB["QUEST_LFG"] then
            for questKey, sbor in pairs(SirusBPTrackerDB["QUEST_LFG"]) do
                local allowedToRender = true
                if SirusBPTrackerConfig and SirusBPTrackerConfig.OnlyBpSbors == true then
                    local isDailyQuest = string.find(string.lower(sbor.questName or ""), "ежедневное")
                    local isSeasonalQuest = string.find(string.lower(sbor.questName or ""), "сезонное")
                    if not isDailyQuest and not isSeasonalQuest then
                        allowedToRender = false
                    end
                end

                if allowedToRender and sbor.authors and type(sbor.authors) == "table" then
                    for _, auth in pairs(sbor.authors) do -- Используем pairs вместо ipairs для хэш-таблиц Сируса
                        if auth.name and auth.msg then
                            local elapsedSec = currentTime - (auth.time or sbor.time or currentTime)
                            if elapsedSec <= 1200 then
                                table.insert(flatAuthorsList, {
                                    auth = auth,
                                    sbor = sbor,
                                    time = auth.time or sbor.time or currentTime,
                                    elapsedSec = elapsedSec
                                })
                            end
                        end
                    end
                end
            end
        end

        table.sort(flatAuthorsList, function(a, b)
            return (a.time or 0) > (b.time or 0)
        end)

        for _, item in ipairs(flatAuthorsList) do
            local auth = item.auth
            local sbor = item.sbor
            local elapsedSec = item.elapsedSec
            
            local elapsedMin = math.floor(elapsedSec / 60)
            local timeStr = (elapsedMin == 0) and "только что" or (elapsedMin .. " мин. назад")

            local currentClass = auth.class or "WHITE"
            if currentClass == "WHITE" or currentClass == "UNKNOWN" then
                local _, classEng = UnitClass(auth.name)
                if classEng and classEng ~= "" then currentClass = classEng end
            end
            local classHex = CLASS_COLORS[currentClass] or "ffffff"
            local hexColor = sbor.hexColor or "ff8040"
            local questFullName = sbor.questName or "Задание"
            local targetQuestID = tonumber(sbor.questID)

            local cleanMsg = tostring(auth.msg or "")
            cleanMsg = string.gsub(cleanMsg, "|Hquest:.-|h%[.-%]|h", ""):gsub("|Hquest:.-|h.-|h", "")
            cleanMsg = string.gsub(cleanMsg, "|Hplayer:.-|h.-|h", ""):gsub("%[?" .. questFullName .. "%]?", "")
            cleanMsg = string.gsub(cleanMsg, "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            cleanMsg = string.gsub(cleanMsg, "^%s*:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if cleanMsg == "" then cleanMsg = "Ищет группу" end

            local charProgressStrings = {}

            -- СОБИРАЕМ ПЕРВЫЕ ЦВЕТНЫЕ БУКВЫ ИМЕН ТВИНКОВ ПО ЧИСЛОВЫМ ID КВЕСТОВ
            local currentRealm = GetRealmName()
            local realmData = ramCacheDB[currentRealm] -- Читаем из быстрого ОЗУ-кэша твинков
            if realmData and targetQuestID then
                for charName, data in pairs(realmData) do
                    if SirusBPTrackerCharFilterDB[charName] ~= false and data.quests then
                        local q = data.quests[targetQuestID]
                        -- Проверяем текстовый лог прогресса: если квест БП завершен, букву НЕ выводим!
                        if q and q.progress ~= "Завершено" then
                            -- Вытаскиваем только первую букву имени (работает корректно с кириллицей UTF-8)
                            local firstLetter = string.sub(charName, 1, 2) 
                            local cHex = CLASS_COLORS[data.class or ""] or "ffffff"
                            
                            -- Добавляем в массив раскрашенную букву твинка
                            table.insert(charProgressStrings, string.format("|cff%s%s|r", cHex, firstLetter))
                        end
                    end
                end
            end

            -- Формируем компактный префикс твинков в квадратных скобках
            local twinsLine = ""
            if #charProgressStrings > 0 then
                table.sort(charProgressStrings)
                twinsLine = "|cff888888[|r" .. table.concat(charProgressStrings, ", ") .. "|cff888888] |r"
            end

            local rowWidth = math.max(1, gui.sborScrollFrame:GetWidth() - 35)
            local sborRow = CreateFrame("Frame", nil, sborChild)
            sborRow:SetWidth(rowWidth)
            sborRow:SetPoint("TOPLEFT", sborChild, "TOPLEFT", 15, yOffset)

            local timeText = sborRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            timeText:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize(), "OUTLINE")
            timeText:SetWidth(105)
            timeText:SetJustifyH("RIGHT")
            timeText:SetPoint("TOPLEFT", sborRow, "TOPLEFT", 0, 0)
            timeText:SetTextColor(0.65, 0.65, 0.65)
            timeText:SetText("(" .. timeStr .. ")")

            local sborLine = sborRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            sborLine:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize(), "OUTLINE")
            sborLine:SetTextColor(1, 1, 1)
            sborLine:SetPoint("TOPLEFT", sborRow, "TOPLEFT", 120, 0)
            sborLine:SetWidth(math.max(1, rowWidth - 120))
            sborLine:SetJustifyH("LEFT")
            sborLine:SetNonSpaceWrap(true)
            sborLine:SetText(string.format("%s|cff%s[%s]|r |cff%s[%s]|r: |cffffffff\"%s\"|r",
                twinsLine, hexColor, questFullName, classHex, auth.name, cleanMsg))

            local rowHeight = math.max(18, math.floor(sborLine:GetStringHeight() + 4))
            sborRow:SetHeight(rowHeight)

            local separator = sborRow:CreateTexture(nil, "BACKGROUND")
            separator:SetSize(rowWidth - 25, 1)
            separator:SetPoint("BOTTOMLEFT", sborRow, "BOTTOMLEFT", 15, 0)
            separator:SetTexture("Interface\\Buttons\\WHITE8X8")
            separator:SetVertexColor(0.4, 0.4, 0.4, 0.45)

            local rowBtn = CreateFrame("Button", "SirusBPSborRowBtn_" .. sborBtnIdx, sborRow)
            rowBtn:SetAllPoints(sborRow)
            rowBtn:RegisterForClicks("LeftButtonUp")
            rowBtn.questName = questFullName
            rowBtn.authorName = auth.name
            rowBtn.questID = targetQuestID
            sborBtnIdx = sborBtnIdx + 1

            rowBtn:SetScript("OnClick", function(self)
                if ChatFrame_OpenChat and self.authorName then
                    ChatFrame_OpenChat("/ш " .. tostring(self.authorName) .. " ", DEFAULT_CHAT_FRAME)
                end
            end)

--sbpt-v227: ЧИСТЫЙ ОЗУ-ТУЛТИП СБОРОВ: МГНОВЕННЫЙ ВЫВОД ТВИНКОВ ПО ЛОКАЛЬНОЙ БАЗЕ БЕЗ ЗАПРОСОВ К СЕРВЕРУ
            rowBtn:SetScript("OnEnter", function(self)
                if TriggerNinjaScanWithCooldown then TriggerNinjaScanWithCooldown() end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                
                -- Вытаскиваем точный числовой ID квеста созывалы
                local targetQuestID = tonumber(self.questID) or (sbor and tonumber(sbor.questID))
                if not targetQuestID then
                    GameTooltip:AddLine("|cff888888Загрузка данных задания...|r")
                    GameTooltip:Show()
                    return
                end
                
                -- Стандартный тултип Близзард для самого квеста
                GameTooltip:SetHyperlink("quest:" .. targetQuestID)
                
                -- Переменные для анализа принадлежности к Боевому Пропуску
                local isSirusBPQuest = false
                local charStrings = {}
                local currentRealm = GetRealmName()
                local realmData = ramCacheDB and ramCacheDB[currentRealm]
                
                -- ПРАВИЛО 1 и 2: Сканируем только локальное ОЗУ, проверяя флаги типа БП (1 или 2) или наличие в фильтрах
                if SirusBPTrackerFilterDB and SirusBPTrackerFilterDB[targetQuestID] ~= nil then
                    isSirusBPQuest = true
                end
                
                if realmData then
                    for charName, data in pairs(realmData) do
                        if data.quests then
                            local q = data.quests[targetQuestID] or data.quests[tostring(targetQuestID)]
                            if q then
                                -- Если нашли квест у любого твинка и у него валидный БП-тип (1 или 2) — это точно БП
                                if q.type == 1 or q.type == 2 then
                                    isSirusBPQuest = true
                                end
                                
                                -- ПРАВИЛО 3: Если персонаж прошел фильтр видимости, собираем его прогресс
                                if SirusBPTrackerCharFilterDB[charName] ~= false then
                                    local hexColor = CLASS_COLORS[data.class or ""] or "ffffff"
                                    local displayProg = tostring(q.progress or "0/0")
                                    
                                    if string.find(displayProg, "/100$") then
                                        local num = tonumber(string.match(displayProg, "^([%d%.]+)"))
                                        if num then displayProg = math.floor(num + 0.5) .. "%" end
                                    end
                                    
                                    local progStr = (displayProg == "Завершено" or displayProg == "Завершено!") and "|cff00ff00Завершено!|r" or "|cff00ff00" .. displayProg .. "|r"
                                    table.insert(charStrings, string.format("|cff%s%s|r (%s)", hexColor, charName, progStr))
                                end
                            end
                        end
                    end
                end
                
                -- ПРАВИЛО 2: Если задание НЕ относится к БП, просто выводим дефолтный тултип и ничего не пишем
                if not isSirusBPQuest then
                    GameTooltip:Show()
                    return
                end
                
                -- Дописываем данные твинков строго для заданий Боевого Пропуска
                GameTooltip:AddLine(" ")
                if #charStrings > 0 then
                    -- ПРАВИЛО 3: Совпадения найдены — выводим красивый упорядоченный список персонажей
                    table.sort(charStrings)
                    GameTooltip:AddLine("|cffffd100Персонажи:|r " .. table.concat(charStrings, ", "), 1, 1, 1, true)
                else
                    -- ПРАВИЛО 4: Это точно БП квест, но совпадений в ОЗУ нет — пишем, что отсутствует у всех
                    GameTooltip:AddLine("|cff888888Задание отсутствует у всех персонажей|r", 1, 1, 1, true)
                end
                
                GameTooltip:Show()
            end)


            rowBtn:SetScript("OnLeave", function(self)
                GameTooltip:Hide()
            end)

            yOffset = yOffset - (rowHeight + 8)
            table.insert(sborChild.widgets, sborRow)
            table.insert(sborChild.widgets, sborLine)
            table.insert(sborChild.widgets, timeText)
            table.insert(sborChild.widgets, rowBtn)
        end
        sborChild:SetHeight(math.abs(yOffset) + 20)
    end
-- КОНЕЦ ОБНОВЛЕННОГО БЛОКА ВКЛАДКИ СБОРОВ ЧАТА

    -- ========================================================================
    -- ЛОГИКА ВКЛАДКИ 1: СПИСОК КВЕСТОВ С ПОЛОСАМИ ПРОГРЕССА И РАЗДЕЛИТЕЛЯМИ
    -- ========================================================================
    if activeTab == 1 and child then
        local categories = { ["Ежедневные"] = {}, ["Сезонные"] = {} }
        local stats = { ["Ежедневные"] = {}, ["Сезонные"] = {} }
        
        local currentRealm = GetRealmName()
        local realmData = ramCacheDB[currentRealm]
        
        if realmData then
            for name, data in pairs(realmData) do
                if SirusBPTrackerCharFilterDB[name] ~= false and data.quests then
                    for questID, q in pairs(data.quests) do
                        local cat = "Сезонные"
                        if q.type == 1 then cat = "Ежедневные" end
                        
                        if not stats[cat][name] then
                            stats[cat][name] = { total = 0, completed = 0, class = data.class }
                        end
                        stats[cat][name].total = stats[cat][name].total + 1
                        if q.progress == "Завершено" or q.progress == "Завершено!" then
                            stats[cat][name].completed = stats[cat][name].completed + 1
                        end

                        local displayName = q.desc or q.text or "Задание БП"
                        local targetNumID = tonumber(questID) or tonumber(q.id)
                        if not targetNumID or SirusBPTrackerFilterDB[targetNumID] ~= false then
                            --sbpt-v449: ИНТЕЛЛЕКТУАЛЬНАЯ СУБ-ФИЛЬТРАЦИЯ КВЕСТОВ БП В ОЗУ НА ЛЕТУ
                            local activeSub = SirusBPTrackerConfig and SirusBPTrackerConfig.ActiveSubTab or 1
                            local isAllowedBySubTab = true
                            if activeSub == 2 and cat ~= "Ежедневные" then isAllowedBySubTab = false end
                            if activeSub == 3 and cat ~= "Сезонные" then isAllowedBySubTab = false end
                            
                            if isAllowedBySubTab then

							if not categories[cat] then categories[cat] = {} end
                            if not categories[cat][displayName] then categories[cat][displayName] = {} end
                            table.insert(categories[cat][displayName], { 
                                name = name, 
                                class = data.class, 
                                progress = q.progress,
                                questID = targetNumID,
                                rawQuest = q
                            })
                        end
                    end
                end
            end
        end

        local yOffset = -5
        local order = {"Ежедневные", "Сезонные"}
        local hasAnyData = false

        for _, catName in ipairs(order) do
            local questList = categories[catName]
            if stats[catName] and next(stats[catName]) then
                local searchText = ""
                if SirusBPSearchBox then searchText = string.lower(SirusBPSearchBox:GetText() or "") end

                local hasMatchingQuests = false
                if questList then
                    for questText in pairs(questList) do
                        if searchText == "" or string.find(string.lower(questText), searchText, 1, true) then
                            hasMatchingQuests = true
                            break
                        end
                    end
                end

--sbpt-v462: СОВРЕМЕННЫЕ ЛИНЕЙНЫЕ ЗАГОЛОВКИ КАТЕГОРИЙ С АВТО-СКРЫТИЕМ НА СУБ-ВКЛАДКАХ
                if hasMatchingQuests then
                    hasAnyData = true
                    
                    -- Считываем ID активной суб-вкладки (1 - Все задания)
                    local activeSub = SirusBPTrackerConfig and SirusBPTrackerConfig.ActiveSubTab or 1
                    
                    if activeSub == 1 then
                        -- Выводим чистое текстовое название без лишних знаков "==="
                        local catFs = AcquireFontString(child, "GameFontNormalLarge", 0, 1, 1, "LEFT", child:GetWidth() - 20, 10, yOffset)
                        catFs:SetText(catName)
                        table.insert(child.widgets, catFs)
                        
                        -- Вычисляем точную ширину текста, чтобы линия начиналась сразу после слова
                        local textWidth = math.floor(catFs:GetStringWidth() + 0.5)
                        
                        -- Чертим тонкую стальную линию на уровне текста до самого правого края окна
--sbpt-v463: УКРУПНЕНИЕ И ПОКРАСКА ЛИНИИ КАТЕГОРИИ В СИНХРОННЫЙ БИРЮЗОВЫЙ ЦВЕТ ШРИФТА СИРУСА
                        local titleLine = child:CreateTexture(nil, "BACKGROUND")
                        -- ИСПРАВЛЕНО: Толщина линии увеличена до 2 пикселей (шире), а правый край растянут на максимум окна (-20)
                        titleLine:SetSize(child:GetWidth() - 20 - textWidth, 2) 
                        titleLine:SetPoint("LEFT", catFs, "LEFT", textWidth + 10, -1) 
                        titleLine:SetTexture("Interface\\Buttons\\WHITE8X8")
                        -- ИСПРАВЛЕНО: Линия окрашена строго в цвет текста (0, 1, 1) и сделана сочной (Alpha 0.75)
                        titleLine:SetVertexColor(0, 1, 1, 0.75) 
                        table.insert(child.widgets, titleLine)
                        
                        yOffset = yOffset - (catFs:GetStringHeight() + 4)
                    end

--sbpt-v461 [ФРАГМЕНТ 1 ИЗ 2]: ИСКЛЮЧИТЕЛЬНО ЧИСЛОВОЙ ФИЛЬТР Q.TYPE И СИММЕТРИЧНЫЕ ОТСТУПЫ ОКНА
                    if questList then
                        local sortedQuestEntries = {}
                        for questText, characters in pairs(questList) do
                            table.insert(sortedQuestEntries, {
                                text = questText,
                                characters = characters,
                                isNew = IsNewTrackedQuest(currentRealm, characters)
                            })
                        end
                        table.sort(sortedQuestEntries, function(a, b)
                            if a.isNew ~= b.isNew then return a.isNew end
                            return a.text < b.text
                        end)

                        for _, questEntry in ipairs(sortedQuestEntries) do
                            local questText = questEntry.text
                            local characters = questEntry.characters
                            if searchText == "" or string.find(string.lower(questText), searchText, 1, true) then
                                
                                -- 1. СТРОГИЙ ЧИСЛОВОЙ СУБ-ФИЛЬТР (1 - Ежедневное, 2 - Сезонное)
                                local activeSub = SirusBPTrackerConfig and SirusBPTrackerConfig.ActiveSubTab or 1
                                local isAllowed = true
                                local questType = 2
                                
                                -- Извлекаем чистую цифру типа из ОЗУ без текстовых совпадений
                                if characters and type(characters) == "table" then
                                    local firstChar = characters[1]
                                    if firstChar and firstChar.rawQuest and firstChar.rawQuest.type then
                                        questType = tonumber(firstChar.rawQuest.type) or 2
                                    end
                                end
                                
                                if activeSub == 2 and questType ~= 1 then isAllowed = false end
                                if activeSub == 3 and questType == 1 then isAllowed = false end
                                
                                if isAllowed then
                                    local tempFs = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                                    tempFs:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize() + 1, "OUTLINE")
                                    local titleWidth = child:GetWidth() - 45
                                    if questEntry.isNew then
                                        tempFs:SetText("New")
                                        titleWidth = titleWidth - tempFs:GetStringWidth() - 5
                                        tempFs:SetWidth(math.max(1, titleWidth))
                                        tempFs:SetText(questText)
                                    else
                                        tempFs:SetWidth(titleWidth)
                                        tempFs:SetText("• " .. questText)
                                    end
                                    local questTextHeight = math.floor(tempFs:GetStringHeight() + 0.5)
                                    tempFs:Hide()
                                    
                                    local numChars = #characters
                                    local rowWidth = child:GetWidth() - 10
                                    local progressAreaWidth = math.max(1, rowWidth - 30)
                                    local progressColumns = math.max(1, math.floor((progressAreaWidth + PROGRESS_COLUMN_GAP) / (PROGRESS_COLUMN_MIN_WIDTH + PROGRESS_COLUMN_GAP)))
                                    local characterLineHeight = math.max(15, GetMainFontSize() + 4)
                                    local progressBarHeight = math.max(11, GetMainFontSize() + 1)
                                    local numRows = math.ceil(numChars / progressColumns)
                                    local rowFrameHeight = questTextHeight + 12 + (numRows * characterLineHeight)
                                    
                                    local row = CreateFrame("Frame", nil, child)
                                    row:SetSize(rowWidth, rowFrameHeight)
                                    row:SetPoint("TOPLEFT", child, "TOPLEFT", 5, yOffset)
                                    table.insert(child.widgets, row)
                                    
                                    local qFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                                    local questTitleLeft = 15
                                    if questEntry.isNew then
                                        local newLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                                        newLabel:SetFont("Fonts\\FRIZQT__.TTF", math.max(8, GetMainFontSize() - 3), "OUTLINE")
                                        newLabel:SetPoint("TOPLEFT", row, "TOPLEFT", questTitleLeft, -2)
                                        newLabel:SetText("New")
                                        newLabel:SetTextColor(0, 1, 0)
                                        table.insert(newQuestTagLabels, newLabel)
                                        questTitleLeft = questTitleLeft + math.floor(newLabel:GetStringWidth() + 5)
                                    end
                                    qFs:SetPoint("TOPLEFT", row, "TOPLEFT", questTitleLeft, -2)
                                    qFs:SetWidth(questEntry.isNew and (rowWidth - questTitleLeft - 20) or (rowWidth - 35))
                                    qFs:SetJustifyH("LEFT")
                                    qFs:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize() + 1, "OUTLINE")
                                    qFs:SetText((questEntry.isNew and "" or "• ") .. questText)
                                    qFs:SetTextColor(1, 0.82, 0, 1)
                                    
                                    local questClickBtn = CreateFrame("Button", nil, row)
                                    questClickBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 10, 0)
                                    questClickBtn:SetPoint("BOTTOMRIGHT", qFs, "BOTTOMRIGHT", 5, -2)
                                    questClickBtn:RegisterForClicks("LeftButtonUp")
                                    
                                    questClickBtn:SetScript("OnEnter", function() qFs:SetTextColor(0, 0.7, 1, 1) end)
                                    questClickBtn:SetScript("OnLeave", function() qFs:SetTextColor(1, 0.82, 0, 1) end)
                                    table.insert(child.widgets, questClickBtn)
                                    
                                    table.sort(characters, function(a, b) return a.name < b.name end)
                                    
                                    local exactQuestID = nil
                                    local currentOnlineCharProgress = "0/0"
                                    local activePlayerName = UnitName("player")
                                    
                                    for charIdx, char in ipairs(characters) do
                                        if char.questID then exactQuestID = tonumber(char.questID) end
                                        if char.rawQuest and char.rawQuest.id then exactQuestID = tonumber(char.rawQuest.id) end
                                        
                                        if char.name == activePlayerName then
                                            currentOnlineCharProgress = tostring(char.progress or "0/0")
                                        end
                                        
                                        local hexColor = CLASS_COLORS[char.class or ""] or "ffffff"
                                        local currentProgressText = tostring(char.progress or "0/0")
                                        local curProgress, maxProgress = 0, 1
                                        
                                        if string.find(currentProgressText, "/100$") or string.find(currentProgressText, "%%") then
                                            local num = tonumber(string.match(currentProgressText, "^([%d%.]+)"))
                                            if num then curProgress = math.floor(num + 0.5) maxProgress = 100 currentProgressText = curProgress .. "%" end
                                        elseif string.find(currentProgressText, "/") then
                                            local c, m = string.match(currentProgressText, "(%d+)/(%d+)")
                                            if c and m then curProgress = tonumber(c) or 0 maxProgress = tonumber(m) or 1 end
                                        else
                                            local singleNum = tonumber(currentProgressText)
                                            if singleNum then curProgress = singleNum maxProgress = singleNum > 1 and singleNum or 1 end
                                        end
                                        
                                        local progressColumn = (charIdx - 1) % progressColumns
                                        local progressRow = math.floor((charIdx - 1) / progressColumns)
                                        local progressCellWidth = (progressAreaWidth - (progressColumns - 1) * PROGRESS_COLUMN_GAP) / progressColumns
                                        local charXOffset = 15 + progressColumn * (progressCellWidth + PROGRESS_COLUMN_GAP)
                                        local charYOffset = -(questTextHeight + 6) - progressRow * characterLineHeight
                                        local charWidth = math.max(60, math.min(100, progressCellWidth * 0.45))
                                        local barWidth = math.max(65, math.min(125, progressCellWidth - charWidth - 10))
                                        local barXOffset = charXOffset + charWidth + 8
                                        
                                        local charFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                                        charFs:SetPoint("TOPLEFT", row, "TOPLEFT", charXOffset, charYOffset)
                                        charFs:SetWidth(charWidth)
                                        charFs:SetJustifyH("LEFT")
                                        charFs:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize(), "OUTLINE")
                                        charFs:SetText(string.format(" |cff%s%s|r", hexColor, char.name))
                                        table.insert(child.widgets, charFs)
--sbpt-v461 [ФРАГМЕНТ 2 ИЗ 2]: ЦЕНТРОВКА ЦИФР, КРУПНЫЙ ТЕКСТ ЗАВЕРШЕНО И ФИНАЛИЗАЦИЯ ВКЛАДКИ 1
                                        if currentProgressText == "Завершено" or currentProgressText == "Завершено!" or curProgress >= maxProgress then
                                            local doneContainer = CreateFrame("Frame", nil, row)
                                            doneContainer:SetSize(barWidth, progressBarHeight)
                                            doneContainer:SetPoint("TOPLEFT", row, "TOPLEFT", barXOffset, charYOffset - 1)
                                            
                                            local doneFs = doneContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                                            doneFs:SetPoint("CENTER", doneContainer, "CENTER", 0, -1)
                                            doneFs:SetFont("Fonts\\FRIZQT__.TTF", math.max(7, GetMainFontSize() - 2), "OUTLINE")
                                            doneFs:SetTextColor(0, 1, 0)
                                            doneFs:SetText("Завершено")
                                            
                                            table.insert(child.widgets, doneContainer)
                                            table.insert(child.widgets, doneFs)
                                        else
                                            local bar = CreateFrame("StatusBar", nil, row)
                                            bar:SetSize(barWidth, progressBarHeight)
                                            bar:SetPoint("TOPLEFT", row, "TOPLEFT", barXOffset, charYOffset - 1)
                                            bar:SetMinMaxValues(0, maxProgress)
                                            bar:SetValue(curProgress)
                                            
                                            local barBG = bar:CreateTexture(nil, "BACKGROUND")
                                            barBG:SetAllPoints(bar)
                                            barBG:SetTexture("Interface\\Buttons\\WHITE8X8")
                                            barBG:SetVertexColor(0.08, 0.08, 0.08, 0.9)
                                            
                                            local barTex = bar:CreateTexture(nil, "ARTWORK")
                                            barTex:SetTexture("Interface\\Buttons\\WHITE8X8")
                                            local progressR, progressG, progressB = GetProgressBarColor()
                                            barTex:SetVertexColor(progressR, progressG, progressB, 0.85)
                                            bar:SetStatusBarTexture(barTex)
                                            
											--[[
                                            local barText = bar:CreateFontString(nil, "OVERLAY")
                                            barText:SetFont("Fonts\\FRIZQT__.TTF", 9.5, "THICKOUTLINE")
                                            --]]
											--sbpt-v465: ПОЛНАЯ ИЗОЛЯЦИЯ ШРИФТА ЦИФР БАРА ДЛЯ ИСКЛЮЧЕНИЯ УМЕНЬШЕНИЯ ЧАТА ELVUI
                                            -- Передаем явный шаблон "GameFontHighlightSmall" вместо nil для приватности фрейма
                                            local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                                            barText:SetFont("Fonts\\FRIZQT__.TTF", math.max(7, GetMainFontSize() - 2), "THICKOUTLINE")

											barText:SetPoint("CENTER", bar, "CENTER", 0, -1)
                                            barText:SetTextColor(1, 1, 1)
                                            barText:SetText(currentProgressText)
                                            
                                            table.insert(child.widgets, bar)
                                        end
                                    end

                                    local capturedQuestID = exactQuestID or 28113
                                    local capturedQuestText = questText or "Задание БП"
                                    
                                    questClickBtn:SetScript("OnClick", function()
--sbpt-v477: ТОЧЕЧНОЕ ВОССТАНОВЛЕНИЕ ОРИГИНАЛЬНОГО SHIFT-КЛИКА ИЗ РАБОЧИХ БЭКАПОВ СИРУСА
                                    if IsShiftKeyDown() then
                                        local channelNum = GetChannelName("Мир")
                                        if not channelNum or channelNum == 0 then 
                                            channelNum = GetChannelName("ПоискСпутников")
                                        end
                                        
                                        local finalChannel = (channelNum and channelNum > 0) and channelNum or 4
                                        local channelCommand = "/" .. finalChannel .. " "
                                        ChatFrame_OpenChat(channelCommand, DEFAULT_CHAT_FRAME)
                                        
                                        local l_capturedQuestID = exactQuestID or 28113
                                        local l_capturedQuestText = questText or "Задание БП"
                                        
                                        local delayFrame = CreateFrame("Frame")
                                        local frameElapsed = 0
                                        delayFrame:SetScript("OnUpdate", function(self, elapsed)
                                            frameElapsed = frameElapsed + elapsed
                                            if frameElapsed >= 0.02 then
                                                self:SetScript("OnUpdate", nil)
                                                
                                                local editBox = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
                                                if editBox then
                                                    editBox:Show()
                                                    editBox:SetFocus()
                                                    
                                                    local finalShortTitle = tostring(l_capturedQuestText)
                                                    local sirusTypeParam = 83
                                                    if string.find(string.lower(finalShortTitle), "ежедневное") then
                                                        sirusTypeParam = 82
                                                    end
                                                    local colorHex = "ffff8040"
                                                    local officialSirusLink = string.format("|c%s|Hquest:%d:%d|h[%s]|h|r",
                                                        colorHex, tonumber(l_capturedQuestID) or 28113, sirusTypeParam, finalShortTitle)
                                                    
                                                    editBox:Insert(officialSirusLink .. " ")
                                                    editBox:SetFocus()
                                                end
                                            end
                                        end)

                                        else
                                            local playerLevel = UnitLevel("player") or 1
                                            if playerLevel >= 80 then
                                                if currentOnlineCharProgress == "Завершено" or currentOnlineCharProgress == "Завершено!" then
                                                    if ToggleBattlePassFrame then pcall(ToggleBattlePassFrame)
                                                    elseif BattlePassFrame and BattlePassFrame.Show then if not BattlePassFrame:IsShown() then BattlePassFrame:Show() end end
                                                    if BattlePassFrame and BattlePassFrameTopPanelQuestPageButton and BattlePassFrameTopPanelQuestPageButton.Click then
                                                        pcall(BattlePassFrameTopPanelQuestPageButton.Click, BattlePassFrameTopPanelQuestPageButton)
                                                    end
                                                end
                                            end
                                        end
                                    end)

                                    local sepLine = row:CreateTexture(nil, "BACKGROUND")
                                    sepLine:SetSize(row:GetWidth() - 25, 1)
                                    sepLine:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 15, 0)
                                    sepLine:SetTexture("Interface\\Buttons\\WHITE8X8")
                                    sepLine:SetVertexColor(0.4, 0.4, 0.4, 0.45)
                                    
                                    yOffset = yOffset - (rowFrameHeight + 6)
                                end
                                
                            end
                        end
                    end
                    yOffset = yOffset - 5
                end
            end
        end

        if not hasAnyData then
            local emptyFs = AcquireFontString(child, "GameFontNormal", 0.7, 0.7, 0.7, "LEFT", child:GetWidth() - 20, 10, yOffset)
            emptyFs:SetText("База данных пуста или совпадений не найдено.")
            yOffset = yOffset - (emptyFs:GetStringHeight() + 10)
            table.insert(child.widgets, emptyFs)
        end
        child:SetHeight(math.abs(yOffset) + 20)
    end

    if #newQuestTagLabels > 0 then newQuestTagPulse:Show() end

  end
end


--sbpt-v225: ЛФГ-ПАРСЕР ЧАТА ПИШЕТ СБОРЫ НАПРЯМУЮ В WTF-ФАЙЛ ДЛЯ ИДЕАЛЬНОЙ СИНХРОНИЗАЦИИ С ТУЛТИПАМИ
chatAuthorsBuffer = chatAuthorsBuffer or {}

if not chatTrackerFrame then
    chatTrackerFrame = CreateFrame("Frame")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_CHANNEL")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_YELL")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_SAY")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_GUILD")
end

local sborUpdateTimer = 0
chatTrackerFrame:SetScript("OnEvent", function(self, event, ...)
    local arg1, arg2, _, _, _, _, _, _, _, _, _, arg12 = ...

    sborUpdateTimer = sborUpdateTimer + 0.4
    if sborUpdateTimer > 60 then
        sborUpdateTimer = 0
        if mainGui and mainGui:IsShown() and UpdateGUIText then UpdateGUIText() end
    end

    if arg1 and arg2 and string.find(arg1, "quest:") then
        local classToken = "WHITE"
        local _, classEng = UnitClass(arg2)
        if classEng and classEng ~= "" then classToken = classEng end
        
        if classToken == "WHITE" and arg12 then
            local cleanGUID = string.upper(tostring(arg12))
            if string.find(cleanGUID, "^0X") and string.len(cleanGUID) > 10 then
                local success, _, classEngByGUID = pcall(GetPlayerInfoByGUID, cleanGUID)
                if success and classEngByGUID and classEngByGUID ~= "" then
                    classToken = classEngByGUID
                end
            end
        end

        for rawQuestID in string.gmatch(arg1, "|Hquest:(%d+)") do
            local questID = tonumber(rawQuestID)
            
            if questID then
                local questTitleName = string.match(arg1, "|h%[([^%]]+)%]")
                
                if questTitleName then
                    -- ВОЗВРАЩЕНО: Пишем сборы ЛФГ напрямую в файл жесткого диска SirusBPTrackerDB!
                    if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
                    if not SirusBPTrackerDB["QUEST_LFG"] then SirusBPTrackerDB["QUEST_LFG"] = {} end
                    
                    local hexColor = "ff8040"
                    local foundQuestHex = string.match(arg1, "|cff(%x%x%x%x%x%x)")
                    if foundQuestHex then hexColor = foundQuestHex end

                    SirusBPTrackerDB["QUEST_LFG"][questID] = SirusBPTrackerDB["QUEST_LFG"][questID] or {
                        questName = questTitleName,
                        questID = questID,
                        hexColor = hexColor,
                        time = time(),
                        authors = {}
                    }
                    
                    local currentSbor = SirusBPTrackerDB["QUEST_LFG"][questID]
                    currentSbor.time = time()
                    currentSbor.questName = questTitleName
                    currentSbor.hexColor = hexColor

                    local authorExists = false
                    
                    if currentSbor.authors and type(currentSbor.authors) == "table" then
                        for _, auth in pairs(currentSbor.authors) do
                            if auth.name == arg2 then
                                auth.msg = arg1
                                auth.time = time()
                                if classToken ~= "WHITE" then auth.class = classToken end
                                authorExists = true
                                break
                            end
                        end
                    else
                        currentSbor.authors = {}
                    end
                    
                    if not authorExists then
                        table.insert(currentSbor.authors, {
                            name = arg2,
                            msg = arg1,
                            class = classToken,
                            time = time()
                        })
                    end

--sbpt-v585: ВЫЗОВ СЧЁТЧИКА С ПЕРЕДАЧЕЙ ID КВЕСТА И ИМЕНИ АВТОРA СБОРА
                    if SBPT_CheckAndIncrementNotification then 
                        SBPT_CheckAndIncrementNotification(questID, arg2) 
                    end

                    if mainGui and mainGui:IsShown() and UpdateGUIText then
                        UpdateGUIText()
                    end
                end
            end
        end
    end
end)
-- КОНЕЦ ОБНОВЛЕНИЯ ЛФГ-ПАРСЕРА ЧАТА

-- Подключение системных хуков
GameTooltip:HookScript("OnUpdate", function(self) ProcessSirusBPTooltip(self, false) end)
GameTooltip:HookScript("OnLeave", function(self) self.SirusBPHookedText = nil end)

if ItemRefTooltip then
    ItemRefTooltip:HookScript("OnUpdate", function(self) ProcessSirusBPTooltip(self, true) end)
    local function ResetRefCacheOnClose(self) self.SirusBPHookedText = nil end
    ItemRefTooltip:HookScript("OnHide", ResetRefCacheOnClose)
    ItemRefTooltip:HookScript("OnLeave", ResetRefCacheOnClose)
end

-- ПОСТОЯННЫЙ ИНСПЕКТОР ФРЕЙМОВ ПОД МЫШЬЮ
SLASH_SIRUSBPFRAME1 = "/bpframe"
SlashCmdList["SIRUSBPFRAME"] = function()
    local focusFrame = GetMouseFocus()
    if focusFrame then
        local name = focusFrame:GetName()
        if name then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SirusBP-Inspector]|r Имя фрейма под мышью: |cffffffff" .. tostring(name) .. "|r")
            local parent = focusFrame:GetParent()
            if parent and parent:GetName() then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SirusBP-Inspector]|r Его родительский фрейм: |cffffffff" .. tostring(parent:GetName()) .. "|r")
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SirusBP-Inspector]|r У фрейма под мышью нет глобального имени.")
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SirusBP-Inspector]|r Под курсором мыши ничего не найдено.")
    end
end
--sbpt-v08-chat-fixes: КОНЕЦ БЛОКА ЧАТА И ХУКОВ


--sbpt-v185: ЧАСТЬ 1 ИЗ 2 МОНОЛИТА НАСТРОЕК ПОД ОЗУ-КЭШ, ЧИСЛОВЫЕ ID И ПРАВИЛЬНЫЕ ЦВЕТА
CreateFilterGUI = function()
    if filterGui then return filterGui end
    local fGui = CreateFrame("Frame", "SirusBPFilterGUI", UIParent)
    fGui:SetSize(500, 550)
    fGui:SetPoint("CENTER", 120, -40)
    fGui:SetFrameStrata("DIALOG")
    fGui:SetFrameLevel(mainGui and (mainGui:GetFrameLevel() + 5) or 10)
    
    fGui:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    SetAddonBackgroundColor(fGui)
    fGui:SetBackdropBorderColor(0.5, 0.5, 0.5, 1.0)
    fGui:EnableMouse(true) fGui:SetMovable(true) fGui:RegisterForDrag("LeftButton")
    fGui:SetScript("OnDragStart", fGui.StartMoving) fGui:SetScript("OnDragStop", fGui.StopMovingOrSizing)
    fGui:SetScript("OnHide", ScheduleAddonEscapeFrameUpdate)

    local title = fGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14) 
    title:SetText("Настройки")

    local headerBackground = fGui:CreateTexture(nil, "BACKGROUND")
    headerBackground:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerBackground:SetPoint("TOPLEFT", fGui, "TOPLEFT", 4, -4)
    headerBackground:SetPoint("TOPRIGHT", fGui, "TOPRIGHT", -4, -4)
    headerBackground:SetHeight(29)
    headerBackground:SetVertexColor(0, 0, 0, 0.45)

    local titleSeparator = fGui:CreateTexture(nil, "BORDER")
    titleSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
    titleSeparator:SetHeight(1)
    titleSeparator:SetPoint("TOPLEFT", fGui, "TOPLEFT", 10, -32)
    titleSeparator:SetPoint("TOPRIGHT", fGui, "TOPRIGHT", -10, -32)
    titleSeparator:SetVertexColor(0.85, 0.65, 0.25, 0.9)

    local closeBtn = CreateFrame("Button", nil, fGui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)
    SetRedButtonStyle(closeBtn)

    local clearAllBtn = CreateFrame("Button", "SirusBPClearAllBtn", fGui)
    clearAllBtn:SetSize(150, 22)
    clearAllBtn:SetPoint("CENTER", fGui, "TOP", 0, -17)
    SetRedButtonStyle(clearAllBtn)
    local clearAllText = clearAllBtn:CreateFontString(nil, "OVERLAY")
    clearAllText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    clearAllText:SetPoint("CENTER", clearAllBtn, "CENTER", 0, 0)
    clearAllText:SetText("Очистить базу данных")
    clearAllText:SetTextColor(1, 0.9, 0.75, 1)
    clearAllBtn:RegisterForClicks("LeftButtonUp")
    StaticPopupDialogs["SIRUSBP_CONFIRM_CLEAR_DB"] = {
        text = "Вы точно хотите очистить базу данных?",
        button1 = "Да",
        button2 = "Нет",
        OnAccept = function()
            ExecuteSBPTDatabaseMigration(true)
            if UpdateGUIText then UpdateGUIText() end
            if fGui.RefreshList then fGui.RefreshList() end
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SirusBP]|r Глобальная база данных, фильтры и ОЗУ полностью уничтожены! Аддон сброшен к первому запуску.")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    clearAllBtn:SetScript("OnClick", function()
        StaticPopup_Show("SIRUSBP_CONFIRM_CLEAR_DB")
    end)

    local settingsTabs = {}
    local settingsTabNames = { "Основные", "Персонажи", "Квесты" }
    for i = 1, 3 do
        local tabIndex = i
        local tab = CreateFrame("Button", nil, fGui)
        tab:SetSize(150, 24)
        tab:SetPoint("TOPLEFT", fGui, "TOPLEFT", 12 + (i - 1) * 155, -40)
        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.text:SetPoint("CENTER")
        tab.text:SetText(settingsTabNames[tabIndex])
        SetBlueTabStyle(tab, false)
        settingsTabs[i] = tab
    end

    local scrollFrame = CreateFrame("ScrollFrame", "SirusBPFilterScrollFrame", fGui, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", fGui, "TOPLEFT", 10, -80)
    scrollFrame:SetPoint("BOTTOMRIGHT", fGui, "BOTTOMRIGHT", -30, 10)

    local pages = {}
    for i = 1, 3 do
        local page = CreateFrame("Frame", nil, scrollFrame)
        page:SetSize(440, 1)
        page:Hide()
        pages[i] = page
    end
    fGui.pages = pages
    fGui.activePage = 1
    fGui.scrollChild = pages[1]

    local headerSeparator = fGui:CreateTexture(nil, "BORDER")
    headerSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerSeparator:SetHeight(1)
    headerSeparator:SetPoint("TOPLEFT", fGui, "TOPLEFT", 10, -70)
    headerSeparator:SetPoint("TOPRIGHT", fGui, "TOPRIGHT", -10, -70)
    headerSeparator:SetVertexColor(0.85, 0.65, 0.25, 0.85)

    local showLfgCb = CreateFrame("CheckButton", "SirusBPShowLfgCheckButton", pages[1], "InterfaceOptionsCheckButtonTemplate")
    
    local showLfgCbText = _G[showLfgCb:GetName() .. "Text"]
    if showLfgCbText then showLfgCbText:SetText("") showLfgCbText:Hide() end
    local showLfgLabel = pages[1]:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    showLfgCb:SetPoint("TOPLEFT", pages[1], "TOPLEFT", 12, -2)
    showLfgLabel:SetPoint("LEFT", showLfgCb, "RIGHT", 2, 0)
    showLfgLabel:SetText("Отображать только сборы на задания боевого пропуска")
    showLfgLabel:SetTextColor(1, 0.82, 0, 1)
    
    if SirusBPTrackerConfig == nil then SirusBPTrackerConfig = {} end
    if SirusBPTrackerConfig.OnlyBpSbors == nil then SirusBPTrackerConfig.OnlyBpSbors = false end
    showLfgCb:SetChecked(SirusBPTrackerConfig.OnlyBpSbors)
    
    showLfgCb:SetScript("OnClick", function(self)
        SirusBPTrackerConfig.OnlyBpSbors = not not self:GetChecked()
        if UpdateGUIText then UpdateGUIText() end
    end)

    local function CreateSettingsSeparator(yOffset)
        local separator = pages[1]:CreateTexture(nil, "BORDER")
        separator:SetTexture("Interface\\Buttons\\WHITE8X8")
        separator:SetPoint("TOPLEFT", pages[1], "TOPLEFT", 14, yOffset)
        separator:SetSize(400, 1)
        separator:SetVertexColor(0.45, 0.45, 0.45, 0.8)
    end

    local function CreatePaletteControl(labelText, yOffset, getColor, applyColor)
        local button = CreateFrame("Button", nil, pages[1])
        button:SetSize(92, 22)
        button:SetPoint("TOPLEFT", pages[1], "TOPLEFT", 16, yOffset)
        SetRedButtonStyle(button)

        local swatch = button:CreateTexture(nil, "ARTWORK")
        swatch:SetTexture("Interface\\Buttons\\WHITE8X8")
        swatch:SetSize(22, 14)
        swatch:SetPoint("LEFT", button, "LEFT", 5, 0)

        local buttonText = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        buttonText:SetPoint("LEFT", swatch, "RIGHT", 5, 0)
        buttonText:SetText("Палитра")

        local label = pages[1]:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", button, "RIGHT", 8, 0)
        label:SetText(labelText)

        local r, g, b = getColor()
        swatch:SetVertexColor(r, g, b, 1)
        button:SetScript("OnClick", function()
            local previousR, previousG, previousB = getColor()
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.previousValues = { r = previousR, g = previousG, b = previousB }
            ColorPickerFrame.func = function()
                local newR, newG, newB = ColorPickerFrame:GetColorRGB()
                applyColor(newR, newG, newB)
                swatch:SetVertexColor(newR, newG, newB, 1)
            end
            ColorPickerFrame.cancelFunc = function(previousValues)
                if previousValues then
                    applyColor(previousValues.r, previousValues.g, previousValues.b)
                    swatch:SetVertexColor(previousValues.r, previousValues.g, previousValues.b, 1)
                end
            end
            ColorPickerFrame:SetColorRGB(previousR, previousG, previousB)
            ColorPickerFrame:Show()
        end)
    end

    CreateSettingsSeparator(-34)
    CreatePaletteControl("Цвет фона", -42, GetMainBackgroundColor, function(r, g, b)
        SirusBPTrackerConfig.BackgroundColor = { r, g, b }
        SetAddonBackgroundColor(mainGui)
        SetAddonBackgroundColor(filterGui)
        SetAddonBackgroundColor(helpGui)
    end)
    CreateSettingsSeparator(-74)
    CreatePaletteControl("Цвет полос прогресса", -82, GetProgressBarColor, function(r, g, b)
        SirusBPTrackerConfig.ProgressBarColor = { r, g, b }
        if UpdateGUIText then UpdateGUIText() end
    end)

    CreateSettingsSeparator(-114)
    local fontSizeSlider = CreateFrame("Slider", "SirusBPFontSizeSlider", pages[1], "OptionsSliderTemplate")
    fontSizeSlider:SetWidth(180)
    fontSizeSlider:SetPoint("TOPLEFT", pages[1], "TOPLEFT", 16, -122)
    fontSizeSlider:SetMinMaxValues(MAIN_FONT_MIN_SIZE, MAIN_FONT_MAX_SIZE)
    fontSizeSlider:SetValueStep(1)
    if fontSizeSlider.SetObeyStepOnDrag then fontSizeSlider:SetObeyStepOnDrag(true) end

    local fontSizeValue = pages[1]:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fontSizeValue:SetPoint("LEFT", fontSizeSlider, "RIGHT", 8, 0)
    fontSizeValue:SetWidth(28)
    fontSizeValue:SetJustifyH("CENTER")

    local fontSizeLabel = pages[1]:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fontSizeLabel:SetPoint("LEFT", fontSizeValue, "RIGHT", 6, 0)
    fontSizeLabel:SetText("размер шрифта")

    SirusBPTrackerConfig.FontSize = GetMainFontSize()
    fontSizeSlider:SetValue(SirusBPTrackerConfig.FontSize)
    fontSizeValue:SetText(tostring(SirusBPTrackerConfig.FontSize))
    fontSizeSlider:SetScript("OnValueChanged", function(self, value)
        local size = math.max(MAIN_FONT_MIN_SIZE, math.min(MAIN_FONT_MAX_SIZE, math.floor(value + 0.5)))
        if SirusBPTrackerConfig.FontSize == size then return end
        SirusBPTrackerConfig.FontSize = size
        fontSizeValue:SetText(tostring(size))
        if UpdateGUIText then UpdateGUIText() end
        if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
            DrawActivitiesTab()
        end
        ApplySettingsFontSize(fGui)
    end)
    pages[1]:SetHeight(160)

    local questFilterHint = fGui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    questFilterHint:SetPoint("TOPLEFT", fGui, "TOPLEFT", 14, -76)
    questFilterHint:SetText("Учитывать только эти квесты")
    questFilterHint:SetTextColor(0.65, 0.65, 0.65, 1)
    questFilterHint:Hide()

    local fSearchBox = CreateFrame("EditBox", "SirusBPFilterSearchBox", fGui)
    fSearchBox:SetSize(150, 20)
    fSearchBox:SetAutoFocus(false)
    fSearchBox:SetFontObject("GameFontHighlightSmall")
    fSearchBox:SetTextInsets(6, 6, 0, 0)
    fSearchBox:ClearAllPoints()
    fSearchBox:SetPoint("TOPRIGHT", fGui, "TOPRIGHT", -40, -76)
    fSearchBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 12, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    fSearchBox:SetBackdropColor(0.01, 0.01, 0.01, 0.8)
    fSearchBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1.0)
    fSearchBox:ClearAllPoints()
    fSearchBox:SetPoint("TOPRIGHT", fGui, "TOPRIGHT", -40, -76)

    local fSearchPrompt = fSearchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fSearchPrompt:SetPoint("LEFT", fSearchBox, "LEFT", 6, 0)
    fSearchPrompt:SetText("Поиск...")
    
    fSearchBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then fSearchPrompt:Hide() else fSearchPrompt:Show() end
        if fGui.activePage == 3 and fGui.RefreshList then fGui.RefreshList() end
    end)
    fSearchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        fGui:Hide()
    end)
    fGui.searchBox = fSearchBox
    fSearchBox:Hide()

    local function SelectSettingsPage(pageIndex)
        fGui.activePage = pageIndex
        for i, page in ipairs(pages) do
            page:Hide()
            SetBlueTabStyle(settingsTabs[i], i == pageIndex)
        end
        local page = pages[pageIndex]
        scrollFrame:ClearAllPoints()
        scrollFrame:SetPoint("TOPLEFT", fGui, "TOPLEFT", 10, pageIndex == 3 and -106 or -80)
        scrollFrame:SetPoint("BOTTOMRIGHT", fGui, "BOTTOMRIGHT", -30, 10)
        page:SetWidth(math.max(1, scrollFrame:GetWidth() - 20))
        page:Show()
        scrollFrame:SetScrollChild(page)
        fGui.scrollChild = page
        if pageIndex == 3 then
            questFilterHint:Show()
            fSearchBox:Show()
        else
            questFilterHint:Hide()
            fSearchBox:Hide()
        end
        if fGui.RefreshList then fGui.RefreshList() end
        ApplySettingsFontSize(fGui)
    end
    for i, tab in ipairs(settingsTabs) do
        local tabIndex = i
        tab:SetScript("OnClick", function() SelectSettingsPage(tabIndex) end)
    end
    fGui:SetScript("OnShow", function()
        UpdateAddonEscapeFrame()
        SelectSettingsPage(fGui.activePage or 1)
        ApplySettingsFontSize(fGui)
    end)

-- КОНЕЦ ВЕРХНЕЙ ЧАСТИ ОКНА НАСТРОЕК
    fGui.RefreshList = function()
        local child = pages[fGui.activePage]
        if child.widgets then
            for _, w in ipairs(child.widgets) do w:Hide() if w.SetChecked then w:SetScript("OnClick", nil) end end
        end
        child.widgets = {}

        local fSearchText = ""
        if fGui.activePage == 3 and SirusBPFilterSearchBox then
            fSearchText = string.lower(SirusBPFilterSearchBox:GetText() or "")
        end

        if fGui.activePage == 1 then
            child:SetHeight(212)
            return
        end

        local uniqueCharacters = {}
        local questsByCat = { ["Ежедневные"] = {}, ["Сезонные"] = {} }

        -- Собираем данные персонажей и квестов из ОЗУ текущего реалма
        local currentRealm = GetRealmName()
        local realmData = ramCacheDB and ramCacheDB[currentRealm]
        
        if realmData then
            for charName, data in pairs(realmData) do
                uniqueCharacters[charName] = data.class or "WARRIOR"
                if data.quests then
                    for questID, q in pairs(data.quests) do
                        local cat = "Сезонные"
                        if q.type == 1 then cat = "Ежедневные" end
                        
                        -- Ключом таблицы квестов делаем числовой ID, а значением - красивое описание
                        local dispName = q.desc or q.text or "Задание БП"
                        questsByCat[cat][questID] = dispName
                    end
                end
            end
        end

        local fyOffset = -5
        local widgetIdx = 1

        local function AddHeader(text, colorR, colorG, colorB)
            local hFs = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            hFs:SetPoint("TOPLEFT", 10, fyOffset) hFs:SetTextColor(colorR, colorG, colorB) hFs:SetText(text)
            fyOffset = fyOffset - 20 table.insert(child.widgets, hFs)
        end

        if fGui.activePage == 2 then
            local characterHint = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            characterHint:SetPoint("TOPLEFT", 15, fyOffset)
            characterHint:SetText("Учитывать только этих персонажей")
            characterHint:SetTextColor(0.75, 0.75, 0.75, 1)
            table.insert(child.widgets, characterHint)
            fyOffset = fyOffset - 24

            local sortedChars = {}
            for cName in pairs(uniqueCharacters) do table.insert(sortedChars, cName) end
            table.sort(sortedChars)

            for i, cName in ipairs(sortedChars) do
                local characterName = cName
                if SirusBPTrackerCharFilterDB[characterName] == nil then SirusBPTrackerCharFilterDB[characterName] = true end
                local cbName = "SirusBPCharCB_" .. widgetIdx
                local cb = _G[cbName] or CreateFrame("CheckButton", cbName, child, "InterfaceOptionsCheckButtonTemplate")
                cb:SetParent(child) cb:ClearAllPoints() cb:SetPoint("TOPLEFT", 15, fyOffset) cb:Show()
                cb:SetChecked(SirusBPTrackerCharFilterDB[characterName])
                cb:SetScript("OnClick", function(self)
                    SirusBPTrackerCharFilterDB[characterName] = self:GetChecked() and true or false
                    if UpdateGUIText then UpdateGUIText() end
                    if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
                        DrawActivitiesTab()
                    end
                end)
                
                -- Выгружаем точный токен класса из ОЗУ персонажа
                local classToken = uniqueCharacters[cName]
                local hexColor = CLASS_COLORS[classToken] or "ffffff"
                local t = cb.TextLabel or child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cb.TextLabel = t t:ClearAllPoints() t:SetPoint("LEFT", cb, "RIGHT", 5, 1)
                t:SetText(string.format("|cff%s%s|r", hexColor, cName)) t:Show()
                fyOffset = fyOffset - 26 widgetIdx = widgetIdx + 1
                table.insert(child.widgets, cb) table.insert(child.widgets, t)
            end
            if #sortedChars == 0 then
                AddHeader("Данные о персонажах пока не загружены.", 0.7, 0.7, 0.7)
            end
            child:SetHeight(math.abs(fyOffset) + 15)
            return
        end

        -- Отрисовка списков отслеживания СТРОГО ПО ЧИСЛОВЫМ ID КВЕСТОВ
        local order = {"Ежедневные", "Сезонные"}
        for _, catName in ipairs(order) do
            local hasQuestsInCat = false
            if questsByCat[catName] then
                for qID, dispName in pairs(questsByCat[catName]) do
                    if fSearchText == "" or string.find(string.lower(dispName), fSearchText, 1, true) then
                        hasQuestsInCat = true
                        break
                    end
                end
            end

            if hasQuestsInCat and questsByCat[catName] then
                local categoryHeader = child:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                categoryHeader:SetPoint("TOPLEFT", 10, fyOffset)
                categoryHeader:SetText(catName)
                categoryHeader:SetTextColor(0, 1, 1)
                table.insert(child.widgets, categoryHeader)

                local textWidth = math.floor(categoryHeader:GetStringWidth() + 0.5)
                local categoryLine = child:CreateTexture(nil, "BACKGROUND")
                categoryLine:SetTexture("Interface\\Buttons\\WHITE8X8")
                categoryLine:SetSize(math.max(1, child:GetWidth() - 20 - textWidth - 10), 2)
                categoryLine:SetPoint("LEFT", categoryHeader, "LEFT", textWidth + 10, -1)
                categoryLine:SetVertexColor(0, 1, 1, 0.75)
                table.insert(child.widgets, categoryLine)
                fyOffset = fyOffset - (categoryHeader:GetStringHeight() + 4)
                
                -- Сортируем квесты по их красивым названиям для алфавитного порядка галочек
                local sortedQuests = {}
                for qID, dispName in pairs(questsByCat[catName]) do
                    if fSearchText == "" or string.find(string.lower(dispName), fSearchText, 1, true) then
                        table.insert(sortedQuests, { id = qID, text = dispName })
                    end
                end
                table.sort(sortedQuests, function(a, b) return a.text < b.text end)

                for _, qInfo in ipairs(sortedQuests) do
                    local qID = qInfo.id
                    local questID = qID
                    local dispName = qInfo.text
                    
                    if SirusBPTrackerFilterDB[questID] == nil then SirusBPTrackerFilterDB[questID] = true end
                    
                    local cbName = "SirusBPQuestCB_" .. widgetIdx
                    local cb = _G[cbName] or CreateFrame("CheckButton", cbName, child, "InterfaceOptionsCheckButtonTemplate")
                    cb:SetParent(child) cb:ClearAllPoints() cb:SetPoint("TOPLEFT", 15, fyOffset) cb:Show()
                    cb:SetChecked(SirusBPTrackerFilterDB[questID] ~= false)
                    
                    cb:SetScript("OnClick", function(self)
                        SirusBPTrackerFilterDB[questID] = self:GetChecked() and true or false
                        if UpdateGUIText then UpdateGUIText() end
                    end)

                    local t = cb.TextLabel or child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    cb.TextLabel = t t:ClearAllPoints() t:SetPoint("LEFT", cb, "RIGHT", 5, 1)
                    t:SetText(dispName) t:Show()
                    
                    fyOffset = fyOffset - 26 widgetIdx = widgetIdx + 1
                    table.insert(child.widgets, cb) table.insert(child.widgets, t)
                end
                fyOffset = fyOffset - 10
            end
        end

        if fyOffset == -5 then
            AddHeader("Квесты не найдены.", 0.7, 0.7, 0.7)
        end
        child:SetHeight(math.abs(fyOffset) + 15)
    end
    SelectSettingsPage(1)
    ApplySettingsFontSize(fGui)
    fGui:Hide()
    filterGui = fGui
    return filterGui
end

--sbpt-v139-donate-fixed: ЖЕСТКИЙ ФИКС НАЛОЖЕНИЯ ТЕКСТА И ТЕКСТУРЫ QR-КОДА
CreateHelpGUI = function()
    if helpGui then return helpGui end

    local hGui = CreateFrame("Frame", "SirusBPHelpGUI", UIParent)
    hGui:SetSize(470, 180) -- ИСПРАВЛЕНО: Увеличили высоту до 180, чтобы полностью исключить наложение!
    hGui:SetPoint("CENTER", 0, 40)
    hGui:SetFrameStrata("DIALOG")
    hGui:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    SetAddonBackgroundColor(hGui)
    hGui:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    local headerBackground = hGui:CreateTexture(nil, "BACKGROUND")
    headerBackground:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerBackground:SetPoint("TOPLEFT", hGui, "TOPLEFT", 4, -4)
    headerBackground:SetPoint("TOPRIGHT", hGui, "TOPRIGHT", -4, -4)
    headerBackground:SetHeight(29)
    headerBackground:SetVertexColor(0, 0, 0, 0.45)

    local titleSeparator = hGui:CreateTexture(nil, "BORDER")
    titleSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
    titleSeparator:SetHeight(1)
    titleSeparator:SetPoint("TOPLEFT", hGui, "TOPLEFT", 10, -32)
    titleSeparator:SetPoint("TOPRIGHT", hGui, "TOPRIGHT", -10, -32)
    titleSeparator:SetVertexColor(0.85, 0.65, 0.25, 0.9)
    
    hGui:EnableMouse(true)
    hGui:SetMovable(true)
    hGui:RegisterForDrag("LeftButton")
    hGui:SetScript("OnDragStart", hGui.StartMoving)
    hGui:SetScript("OnDragStop", hGui.StopMovingOrSizing)
    hGui:SetScript("OnShow", UpdateAddonEscapeFrame)
    hGui:SetScript("OnHide", ScheduleAddonEscapeFrameUpdate)

    -- Заголовок окна
    local title = hGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14)
    local addonVersion = GetAddOnMetadata and GetAddOnMetadata("SirusBPTracker", "Version")
    title:SetText("Об аддоне SirusBPTracker" .. (addonVersion and (" v" .. addonVersion) or ""))

    local closeBtn = CreateFrame("Button", nil, hGui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)
    SetRedButtonStyle(closeBtn)

    -- 1. ИСПРАВЛЕНО: 
    local helpText = hGui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT", 16, -42)
    helpText:SetWidth(300) -- Четко держим ширину текстового блока
    helpText:SetJustifyH("LEFT")
    helpText:SetText("Если Вам понравился аддон, можете пожертвовать мне золото через внутриигровую почту.\n\nСервер х5, |cff3fc7ebМедведж|r\n\n|cffffd100Поддержать автора вне игры можно по ссылке или QR-коду:|r")

    -- 2. ИСПРАВЛЕНО: Сдвинули EditBox ниже (на -140), теперь наложение физически невозможно!
    local editBox = CreateFrame("EditBox", "SirusBPDonateLinkEditBox", hGui)
    editBox:SetSize(290, 22)
    editBox:SetPoint("TOPLEFT", 16, -140) -- Идеальный нижний отступ
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetAutoFocus(false)
    editBox:SetText("https://pay.cloudtips.ru/p/aff01756")
    editBox:SetTextInsets(6, 6, 0, 0)
    editBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 12, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    editBox:SetBackdropColor(0.01, 0.01, 0.01, 1.0)
    editBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1.0)

    editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    editBox:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

--sbpt-v140-qr-size-fix: РАЗМЕР И ОТОБРАЖЕНИЕ QR-КОДА В ОКНЕ
    local qrFrame = CreateFrame("Frame", nil, hGui)
    qrFrame:SetSize(128, 128) -- Увеличили до 128x128 для идеальной четкости пикселей!
    qrFrame:SetPoint("TOPRIGHT", hGui, "TOPRIGHT", -18, -38) 
    
    local qrTexture = qrFrame:CreateTexture(nil, "ARTWORK")
    qrTexture:SetAllPoints(qrFrame)
    qrTexture:SetTexture("Interface\\AddOns\\SirusBPTracker\\qr")
    qrFrame.texture = qrTexture
--sbpt-v140-qr-size-fix: КОНЕЦ ФИКСА ГАБАРИТОВ


    hGui:Hide()
    helpGui = hGui
    return helpGui
end
--sbpt-v139-donate-fixed: КОНЕЦ ОБНОВЛЕНИЯ


local function CreateMinimapButton()
    if SirusBPMinimapButton then return end
    local button = CreateFrame("Button", "SirusBPMinimapButton", Minimap)
	
--sbpt-v638: КОМПАКТНЫЙ ЦВЕТНОЙ КРУЖОЧЕК С ЖЁСТКОЙ ЧЁРНОЙ ОБВОДКОЙ ПО КРАЯМ (9х9 и 7х7)
    if button and not button.NotificationDot then
        -- Создаем базовый защитный фрейм на высшем уровне (размер под черную обводку)
        button.DotFrame = CreateFrame("Frame", nil, button)
        button.DotFrame:SetSize(9, 9) -- Внешний размер обводки
        button.DotFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 4) -- Смещение ближе к центру лапы
        button.DotFrame:SetFrameLevel(button:GetFrameLevel() + 10) 

        -- СЛОЙ 1: ЧЁРНЫЙ КРУГ-ОБВОДКА (Лежит на самом дне подложки)
        local dotBorder = button.DotFrame:CreateTexture(nil, "BACKGROUND")
        dotBorder:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        dotBorder:SetAllPoints(button.DotFrame) -- Растягиваем на все 9x9 пикселей
        dotBorder:SetVertexColor(0, 0, 0, 1) -- Чистый глухой черный цвет контура

        -- СЛОЙ 2: ВНУТРЕННИЙ УМЕНЬШЕННЫЙ ЦВЕТНОЙ КРУЖОЧЕК КЛАССА
        button.NotificationDot = button.DotFrame:CreateTexture(nil, "OVERLAY")
        button.NotificationDot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        -- Делаем его аккуратным и изящным (7x7 пикселей)
        button.NotificationDot:SetSize(7, 7) 
        -- Центрируем его ровно посередине черного круга, чтобы обводка была равномерной со всех сторон
        button.NotificationDot:SetPoint("CENTER", button.DotFrame, "CENTER", 0, 0)
        
        button.NotificationDot:SetVertexColor(1, 1, 1, 1) -- Цвет на лету покрасит скрипт
        
        button.DotFrame:Hide() -- Изначально скрываем всю конструкцию
    end

	
    button:SetSize(31, 31) button:SetFrameLevel(Minimap:GetFrameLevel() + 2) button:SetToplevel(true)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20) background:SetTexture("Interface\\Icons\\Ability_Racial_BearForm") background:SetPoint("CENTER", 0, 0)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53) border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder") border:SetPoint("TOPLEFT", 0, 0)

    button:RegisterForClicks("LeftButtonUp") button:RegisterForDrag("LeftButton")

    local function UpdatePosition()
        local angle = SirusBPTrackerConfig.minimapPos or 45
        local x = math.cos(math.rad(angle)) * 80 local y = math.sin(math.rad(angle)) * 80
        button:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    button:SetScript("OnDragStart", function(self) 
        self:LockHighlight() 
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter() local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale() px, py = px / scale, py / scale
            local angle = math.deg(math.atan2(py - my, px - mx))
            if angle < 0 then angle = angle + 360 end
            SirusBPTrackerConfig.minimapPos = angle UpdatePosition()
        end) 
    end)
    button:SetScript("OnDragStop", function(self) self:UnlockHighlight() self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnClick", function(self, btn)
        if btn == "LeftButton" then
            if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
            -- СБРОС НА ДИСК: Кликнули на лапу — фиксируем ОЗУ в WTF-файл перед выводом
            if SaveRAMCacheToDisk then SaveRAMCacheToDisk() end

            local gui = CreateMainGUI()
            if gui:IsShown() then gui:Hide() else if UpdateGUIText then UpdateGUIText() end gui:Show() end
        end
    end)

--sbpt-v166-lapa-debug: КОНЕЦ ФИКСА КЛИКА ЛАПЫ


    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT") GameTooltip:AddLine("Sirus BP Tracker", 1, 1, 1)
        GameTooltip:AddLine("|cff00ff00ЛКМ:|r Открыть/Закрыть окно", 0.8, 0.8, 0.8) GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UpdatePosition()
end

--sbpt-v242: ДВУХРУБЕЖНЫЙ АВТОЗАПУСК МИГРАЦИИ 1.1: СРАБАТЫВАЕТ И ПРИ ЗАГРУЗКЕ АДДОНА, И ПРИ КАЖДОМ РЕЛОАДЕ (/RELOAD)
frame:RegisterEvent("PLAYER_ENTERING_WORLD") -- Дополнительно регистрируем триггер релоада

-- новый обрабочик событий

frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == "SirusBPTracker" then
        if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
        if not SirusBPTrackerVersionDB then SirusBPTrackerVersionDB = {} end
        if not SirusBPTrackerFilterDB then SirusBPTrackerFilterDB = {} end
        if not SirusBPTrackerCharFilterDB then SirusBPTrackerCharFilterDB = {} end
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = { minimapPos = 45 } end
        if not SirusBPTrackerNewQuestDB then SirusBPTrackerNewQuestDB = {} end
        
        if ExecuteSBPTDatabaseMigration then
            ExecuteSBPTDatabaseMigration(false)
        end
        
        if SirusBPTrackerDB then
            for k, v in pairs(SirusBPTrackerDB) do
                if type(v) == "table" then
                    ramCacheDB[k] = {}
                    for charName, charData in pairs(v) do
                        if type(charData) == "table" then
                            ramCacheDB[k][charName] = {
                                name = charData.name,
                                class = charData.class,
                                battlePassLevel = charData.battlePassLevel,
                                battlePassExperience = charData.battlePassExperience,
                                battlePassExperienceRequired = charData.battlePassExperienceRequired,
                                experienceBonusPercent = charData.experienceBonusPercent,
                                lastScanTime = charData.lastScanTime,
                                quests = {},
                                activities = {}
                            }
                            if charData.activities then
                                for actKey, actData in pairs(charData.activities) do
                                    ramCacheDB[k][charName].activities[actKey] = {
                                        status = actData.status,
                                        lastCheck = actData.lastCheck,
                                        questID = actData.questID,
                                        questName = actData.questName,
                                        questProgress = actData.questProgress
                                    }
                                end
                            end
                            if charData.quests then
                                for qID, qData in pairs(charData.quests) do
                                    ramCacheDB[k][charName].quests[qID] = {
                                        id = qData.id,
                                        type = qData.type,
                                        text = qData.text,
                                        desc = qData.desc,
                                        progress = qData.progress
                                    }
                                end
                            end
                        end
                    end
                else
                    ramCacheDB[k] = v
                end
            end
        end
		
        CreateMinimapButton()
        
    elseif event == "PLAYER_ENTERING_WORLD" then
        if ExecuteSBPTDatabaseMigration then ExecuteSBPTDatabaseMigration(false) end
        if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
        if UpdateGUIText then UpdateGUIText() end
        
        if UpdateCurrentCharacterActivities then UpdateCurrentCharacterActivities() end
        if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
            DrawActivitiesTab()
        end

--sbpt-v391: ДВУХЭТАПНЫЙ СИНХРОННЫЙ ЗАТВОР QUEST_LOG_UPDATE ДЛЯ МГНОВЕННОГО ОБНОВЛЕНИЯ БП
    elseif event == "QUEST_TURNED_IN" or event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" or event == "UNIT_QUEST_LOG_CHANGED" then
        -- Выполняем базовое обновление КД активностей третьей вкладки твинков
        if QueryQuestsCompleted then QueryQuestsCompleted() end
        if UpdateCurrentCharacterActivities then
            UpdateCurrentCharacterActivities(event == "QUEST_TURNED_IN" and arg1 or nil)
        end
        
        -- ИСПРАВЛЕНО (ТВОЙ АЛГОРИТМ): Если вылетело QUEST_LOG_UPDATE и наш флаг ожидания сдачи БП активен!
        if sbptBPNeedRefresh or event == "QUEST_TURNED_IN" then
            sbptBPNeedRefresh = false -- Сбрасываем триггер ожидания Сируса
            
            -- Сирус гарантированно применил данные в ОЗУ компьютера! Обновляем БП и Сборы мгновенно!
            if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
            if UpdateGUIText then UpdateGUIText() end
        end
        
        if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then DrawActivitiesTab() end

--sbpt-v393: АБСОЛЮТНО БЕЗОПАСНЫЙ КАСКАДНЫЙ СЕТЕВОЙ ТРИГГЕР ДЛЯ ОБНОВЛЕНИЯ БП И СБОРОВ БЕЗ КАДРОВ
    elseif event == "QUEST_QUERY_COMPLETE" then
        if UpdateCurrentCharacterActivities then UpdateCurrentCharacterActivities() end
        if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
        if UpdateGUIText then UpdateGUIText() end
        if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then DrawActivitiesTab() end

    elseif event == "CHAT_MSG_ADDON" then
        -- ЭТАП 1: Сервер Сируса прислал стартовый пакет о сдаче задания БП
        if arg1 and arg1 == "ASMSG_BATTLEPASS_QUEST_REWARD" then
            sbptBPClaimTimeStamp = GetTime() -- Запоминаем точную внутреннюю секунду сдачи квеста
            sbptBPNeedCascadeCheck = true    -- Взводим скрытый каскадный затвор
            
        -- ЭТАП 2: Ловим каскадные пакеты бонусов, которыми Сирус завершает обновление памяти ПК
        elseif arg1 and arg1 == "ASMSG_BATTLEPASS_QUEST_BONUS" and sbptBPNeedCascadeCheck then
            local currentTime = GetTime()
            local timeDiff = currentTime - (sbptBPClaimTimeStamp or 0)
            
            -- Если с момента сдачи квеста прошло больше 0.4 сек, значит Сирус прислал финальный пакет каскада!
            -- Вся транзакция Сируса завершена, и ОЗУ компьютера гарантированно разблокировано!
            if timeDiff >= 0.4 then
                sbptBPNeedCascadeCheck = false -- Сбрасываем триггер ожидания
                
                -- Выполняем кристально чистый скан БП и сиюминутно перерисовываем интерфейс нашего аддона!
                if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
                if UpdateGUIText then UpdateGUIText() end
                if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then 
                    DrawActivitiesTab() 
                end
            end
        end
    end
end)


SLASH_SIRUSBPVIEW1 = "/bp"
SlashCmdList["SIRUSBPVIEW"] = function()
    local gui = CreateMainGUI()
    if gui:IsShown() then gui:Hide() else UpdateGUIText() gui:Show() end
end
-------------------------------------------------------------------------------
-- конец доверенного кода
-------------------------------------------------------------------------------
--sbpt-v13-monolith: СБОРКА ЧАТА, ХУКОВ И КЛАССОВ (БЕЗ ДУБЛИКАТОВ)
function NormalizeText(text)
    if not text then return "" end
    return string.gsub(string.lower(text), "%s+", "")
end

--sbpt-v231: АДАПТАЦИЯ ОРИГИНАЛЬНОГО ДВИЖКА ТУЛТИПОВ ПОД СТРУКТУРУ ОПИСАНИЙ И ОЗУ-КЭШ RAMCACHEDB
function ProcessSirusBPTooltip(self, isClickWindow)
    if not self or not self:IsShown() then return end
    
    local fName = self:GetName()
    if not fName then return end
    
    local titleTextObj = _G[fName .. "TextLeft1"]
    local titleText = titleTextObj and titleTextObj:GetText() or ""
    
    if titleText == "" then return end

    -- Проверяем, БП-линк ли это на Сирусе
    if string.find(titleText, "Ежедневное задание:") or string.find(titleText, "Сезонное задание:") then
        
        local hasOurLine = false
        for i = 2, self:NumLines() do
            local leftLine = _G[fName .. "TextLeft" .. i]
            local lineTxt = leftLine and leftLine:GetText()
            if lineTxt and (string.find(lineTxt, "Персонажи:") or string.find(lineTxt, "Задание отсутствует")) then
                hasOurLine = true
                break
            end
        end

        if not hasOurLine then self.SirusBPHookedText = nil end
        if self.SirusBPHookedText == titleText and hasOurLine then return end

        local realQuestDescription = nil
        for i = 2, 6 do
            local textLeft = _G[fName .. "TextLeft" .. i]
            local txt = textLeft and textLeft:GetText()
            
            if txt and txt ~= "" then
                local cleanTxt = string.gsub(txt, "^%s*(.-)%s*$", "%1")
                if cleanTxt ~= "" and cleanTxt ~= "Requirements:" and cleanTxt ~= "Требования:" and not string.find(cleanTxt, "Прогресс") and not string.find(cleanTxt, "^%-") and not string.find(cleanTxt, "Персонажи:") and not string.find(cleanTxt, "Задание отсутствует") then
                    realQuestDescription = cleanTxt
                    break
                end
            end
        end

        if not realQuestDescription or string.len(realQuestDescription) < 4 then return end
        self.SirusBPHookedText = titleText

        for i = 2, self:NumLines() do
            local leftLine = _G[fName .. "TextLeft" .. i]
            local lineTxt = leftLine and leftLine:GetText()
            if lineTxt and (string.find(lineTxt, "Персонажи:") or string.find(lineTxt, "Задание отсутствует")) then
                leftLine:SetText("")
                local prevLine = _G[fName .. "TextLeft" .. (i-1)]
                if prevLine and prevLine:GetText() == " " then prevLine:SetText("") end
            end
        end

        local normalizedTooltipDesc = NormalizeText(realQuestDescription)
        local charStrings = {}

        -- ИСПРАВЛЕНО: Переводим перебор на наш быстрый, каскадный ОЗУ-кэш ramCacheDB по текущему реалму
        local currentRealm = GetRealmName()
        local realmData = ramCacheDB and ramCacheDB[currentRealm]
        
        if realmData then
            for charName, data in pairs(realmData) do
                if SirusBPTrackerCharFilterDB[charName] ~= false and data.quests then
                    for _, q in pairs(data.quests) do
                        -- ИСПРАВЛЕНО: Сверяем описание и с q.text, и с q.desc, убирая слепоту тултипа!
                        if NormalizeText(q.desc or "") == normalizedTooltipDesc or NormalizeText(q.text or "") == normalizedTooltipDesc then
                            local hexColor = CLASS_COLORS[data.class or ""] or "ffffff"
                            
                            local displayProg = tostring(q.progress or "0/0")
                            if string.find(displayProg, "/100$") then
                                local num = tonumber(string.match(displayProg, "^([%d%.]+)"))
                                if num then displayProg = math.floor(num + 0.5) .. "%" end
                            end
                            
                            local progStr = (displayProg == "Завершено" or displayProg == "Завершено!") and "|cff00ff00Завершено!|r" or "|cff00ff00" .. displayProg .. "|r"
                            table.insert(charStrings, string.format("|cff%s%s|r (%s)", hexColor, charName, progStr))
                            break
                        end
                    end
                end
            end
        end

        self:AddLine(" ")
        if #charStrings > 0 then
            table.sort(charStrings)
            self:AddLine("|cffffd100Персонажи:|r " .. table.concat(charStrings, ", "), 1, 1, 1, true)
            
            -- Запись в базу сборов происходит СТРОГО по клику в чате
            if isClickWindow then
                local questTitleName = string.gsub(titleText, "Ежедневное задание:%s*", ""):gsub("Сезонное задание:%s*", "")
                local searchKey = NormalizeText(questTitleName)
                
                local chatData = chatAuthorsBuffer[searchKey]
                if chatData and chatData.name then
                    if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
                    if not SirusBPTrackerDB["QUEST_LFG"] then SirusBPTrackerDB["QUEST_LFG"] = {} end
                    
                    local dbKey = realQuestDescription or questTitleName
                    SirusBPTrackerDB["QUEST_LFG"][dbKey] = SirusBPTrackerDB["QUEST_LFG"][dbKey] or {
                        questName = realQuestDescription,
                        time = time(),
                        authors = {}
                    }
                    SirusBPTrackerDB["QUEST_LFG"][dbKey].time = time()
                    
                    local authorExists = false
                    if SirusBPTrackerDB["QUEST_LFG"][dbKey].authors then
                        for _, auth in ipairs(SirusBPTrackerDB["QUEST_LFG"][dbKey].authors) do
                            if auth.name == chatData.name then
                                auth.msg = chatData.msg
                                auth.class = chatData.class or "WHITE"
                                authorExists = true
                                break
                            end
                        end
                    else
                        SirusBPTrackerDB["QUEST_LFG"][dbKey].authors = {}
                    end
                    
                    if not authorExists then
                        table.insert(SirusBPTrackerDB["QUEST_LFG"][dbKey].authors, {
                            name = chatData.name,
                            msg = chatData.msg,
                            class = chatData.class or "WHITE"
                        })
                    end
                end
            end
        else
            self:AddLine("|cff888888Задание отсутствует у всех персонажей|r", 1, 1, 1, true)
        end
        
        self:Show()
    end
end


-- Подключение системных хуков подсказок
GameTooltip:HookScript("OnUpdate", function(self) ProcessSirusBPTooltip(self, false) end)
GameTooltip:HookScript("OnLeave", function(self) self.SirusBPHookedText = nil end)

if ItemRefTooltip then
    ItemRefTooltip:HookScript("OnUpdate", function(self) ProcessSirusBPTooltip(self, true) end)
    local function ResetRefCacheOnClose(self) self.SirusBPHookedText = nil end
    ItemRefTooltip:HookScript("OnHide", ResetRefCacheOnClose)
    ItemRefTooltip:HookScript("OnLeave", ResetRefCacheOnClose)
end

--sbpt-v38-click-fix: ЗАПИСЬ ЦВЕТА И ID КВЕСТА НАПРЯМУЮ В БАЗУ ДАННЫХ
local orig_SetItemRef = SetItemRef
function SetItemRef(link, text, button, chatFrame)
    if ItemRefTooltip then
        ItemRefTooltip.SirusBPHookedText = nil
    end

    if link and string.find(link, "^quest:") and text then
        local questID = string.match(link, "quest:(%d+)")
        local questTitleName = string.match(text, "%[([^%]]+)%]")
        
        if questID and questTitleName then
            local chatData = chatAuthorsBuffer[tostring(questID)]
            
            if chatData and chatData.name then
                if not SirusBPTrackerDB["QUEST_LFG"] then SirusBPTrackerDB["QUEST_LFG"] = {} end
                
                local questCleanName = string.gsub(questTitleName, "Ежедневное задание:%s*", ""):gsub("Сезонное задание:%s*", "")
                local dbKey = NormalizeText(questCleanName)
                
                -- Вытаскиваем HEX-цвет скобок Сируса, если он есть в сообщении
                local hexColor = "ffffd100" -- Дефолтный золотой
                if chatData.msg then
                    local foundHex = string.match(chatData.msg, "|cff(%x%x%x%x%x%x)")
                    if foundHex then hexColor = foundHex end
                end

                SirusBPTrackerDB["QUEST_LFG"][dbKey] = SirusBPTrackerDB["QUEST_LFG"][dbKey] or {
                    questName = questCleanName,
                    questID = questID, -- НАМЕРТВО ЗАПОМИНАЕМ ИСТИННЫЙ ID КВЕСТА
                    hexColor = hexColor, -- НАМЕРТВО ЗАПОМИНАЕМ ЦВЕТ СИРУСА
                    time = chatData.time or time(),
                    authors = {}
                }
                SirusBPTrackerDB["QUEST_LFG"][dbKey].time = chatData.time or time()
                SirusBPTrackerDB["QUEST_LFG"][dbKey].questID = questID
                SirusBPTrackerDB["QUEST_LFG"][dbKey].hexColor = hexColor

                local authorExists = false
                for _, auth in ipairs(SirusBPTrackerDB["QUEST_LFG"][dbKey].authors) do
                    if auth.name == chatData.name then
                        auth.msg = chatData.msg
                        auth.class = chatData.class or "WHITE"
                        authorExists = true
                        break
                    end
                end
                
                if not authorExists then
                    table.insert(SirusBPTrackerDB["QUEST_LFG"][dbKey].authors, {
                        name = chatData.name,
                        msg = chatData.msg,
                        class = chatData.class or "WHITE"
                    })
                end
            end
        end
    end

    orig_SetItemRef(link, text, button, chatFrame)
    
    if link and string.find(link, "^quest:") and ItemRefTooltip and ItemRefTooltip:IsShown() then
        if ProcessSirusBPTooltip then ProcessSirusBPTooltip(ItemRefTooltip, true) end
        if mainGui and mainGui:IsShown() and UpdateGUIText then
            UpdateGUIText()
        end
    end
end

-- Функция принудительного сохранения ОЗУ-кэша в WTF-файл на жесткий диск
--sbpt-v191: ТАЙМЕР ДИСКА РАБОТАЕТ СТРОГО С ПЕРСОНАЖАМИ, НЕ ТРОГАЯ ПРЯМУЮ ЗАПИСЬ ЛФГ-СБОРОВ
function SaveRAMCacheToDisk()
    if InCombatLockdown() or not ramCacheDB then return end
    if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
    
    -- СОХРАНЯЕМ ПЕРСОНАЖЕЙ: Каскадный сброс твинков по реалмам на жесткий диск из ОЗУ
    for realm, chars in pairs(ramCacheDB) do
        if realm ~= "FRAME_DUMP" and realm ~= "QUEST_LFG" and type(chars) == "table" then
            if not SirusBPTrackerDB[realm] then SirusBPTrackerDB[realm] = {} end
            for name, data in pairs(chars) do
                if type(data) == "table" then
                    if not SirusBPTrackerDB[realm][name] then SirusBPTrackerDB[realm][name] = {} end
                    local diskChar = SirusBPTrackerDB[realm][name]
                    diskChar.name = data.name
                    diskChar.class = data.class
                    diskChar.battlePassLevel = data.battlePassLevel
                    diskChar.battlePassExperience = data.battlePassExperience
                    diskChar.battlePassExperienceRequired = data.battlePassExperienceRequired
                    diskChar.experienceBonusPercent = data.experienceBonusPercent
                    diskChar.lastScanTime = data.lastScanTime
                    diskChar.quests = {}
                    if data.quests then
                        for qID, qData in pairs(data.quests) do
                            diskChar.quests[qID] = {
                                id = qData.id,
                                type = qData.type,
                                text = qData.text,
                                desc = qData.desc,
                                progress = qData.progress
                            }
                        end
                    end
                end
            end
        end
    end
end


--sbpt-v164-pure-memory-core: МГНОВЕННЫЙ И БЕСШУМНЫЙ СБОР ДАННЫХ ИЗ НАПРАВЛЕННОЙ ПАМЯТИ СИРУСА
local lastScanTime = 0

local function UpdateNewQuestTracking(realm, charName, quests)
    if not SirusBPTrackerNewQuestDB then SirusBPTrackerNewQuestDB = {} end
    if not SirusBPTrackerNewQuestDB[realm] then SirusBPTrackerNewQuestDB[realm] = {} end

    local record = SirusBPTrackerNewQuestDB[realm][charName]
    local currentSnapshot = {}
    for questID, quest in pairs(quests) do
        local id = tostring(questID)
        local questType = tonumber(quest.type) or 2
        currentSnapshot[id] = questType
    end

    if not record or type(record.snapshot) ~= "table" then
        SirusBPTrackerNewQuestDB[realm][charName] = {
            snapshot = currentSnapshot,
            newQuests = {}
        }
        return
    end

    local currentTime = time()
    if type(record.newQuests) ~= "table" then record.newQuests = {} end
    for questID, questType in pairs(currentSnapshot) do
        if record.snapshot[questID] ~= questType then
            record.newQuests[questID] = {
                type = questType,
                periodStart = GetQuestPeriodStart(questType, currentTime)
            }
        end
    end

    for questID, newQuest in pairs(record.newQuests) do
        if newQuest.periodStart ~= GetQuestPeriodStart(newQuest.type, currentTime) then
            record.newQuests[questID] = nil
        end
    end

    record.snapshot = currentSnapshot
end

function ExecuteSilentBPScan(force) 
    local pName = UnitName("player")
    local pRealm = GetRealmName()
    local playerLevel = UnitLevel("player") or 1    
	if playerLevel < 80 then 
        return 
    end
	
	if not C_BattlePass then 
        print("|cffff0000[SBPT-MEM-DEBUG] Критическая ошибка: C_BattlePass отсутствует!|r")
        return 
    end
    
    if C_BattlePass.RequestQuests then C_BattlePass.RequestQuests() end
    
    -- ЗАПИСЬ В ОЗУ: Работаем строго внутри локальной RAM-таблицы без нагрузки на жесткий диск
    if not ramCacheDB[pRealm] then ramCacheDB[pRealm] = {} end
    if not ramCacheDB[pRealm][pName] then ramCacheDB[pRealm][pName] = {} end
    
    local charData = ramCacheDB[pRealm][pName]
    charData.name = pName
    local _, classEng = UnitClass("player")
    if classEng then charData.class = classEng end
    local levelInfoSuccess, bpLevel, bpExperience, bpExperienceRequired = pcall(C_BattlePass.GetLevelInfo)
    if levelInfoSuccess then
        charData.battlePassLevel = tonumber(bpLevel)
        charData.battlePassExperience = tonumber(bpExperience)
        charData.battlePassExperienceRequired = tonumber(bpExperienceRequired)
    end
    charData.quests = {}
    local experienceBonusPercent
    
    local totalQuestsFound = 0
    
    for questType = 1, 2 do
        local success, numQuests = pcall(function() return C_BattlePass.GetNumQuests(questType) end)
        
        if not success then
            print("|cffff0000[SBPT-MEM-DEBUG] КРИТИЧЕСКИЙ СБОЙ: C_BattlePass.GetNumQuests вызвал ошибку ядра Сируса!|r")
            numQuests = 0
        end
        
        numQuests = numQuests or 0
        
        for i = 1, numQuests do
            local idSuccess, questID = pcall(function() return C_BattlePass.GetQuestID(questType, i) end)
            
            if idSuccess and questID then
                if experienceBonusPercent == nil and type(C_BattlePass.GetQuestBonusXP) == "function" then
                    local bonusSuccess, bonusXP = pcall(C_BattlePass.GetQuestBonusXP, questID)
                    if bonusSuccess then
                        experienceBonusPercent = tonumber(bonusXP)
                        if experienceBonusPercent and experienceBonusPercent > 0 and experienceBonusPercent <= 1 then
                            experienceBonusPercent = experienceBonusPercent * 100
                        end
                    elseif not bonusXPApiErrorReported then
                        print("|cffff0000[SBPT] Ошибка C_BattlePass.GetQuestBonusXP: " .. tostring(bonusXP) .. "|r")
                        bonusXPApiErrorReported = true
                    end
                end

                local infoSuccess, qTitle, b, c, d, curProg, maxGoal = pcall(function() 
                    return C_BattlePass.GetQuestInfoID(questID) 
                end)
                
                if infoSuccess and qTitle and curProg and maxGoal then
                    totalQuestsFound = totalQuestsFound + 1
                    local progressText = curProg .. "/" .. maxGoal
                    
                    if tonumber(curProg) >= tonumber(maxGoal) or (C_BattlePass.IsQuestCompleteByID and C_BattlePass.IsQuestCompleteByID(questID)) then
                        progressText = "Завершено"
                    end
 -- Сохраняем адресно внутри RAM
                    charData.quests[questID] = {
                        id = questID,
                        type = questType,
                        text = qTitle,
                        desc = b or qTitle,
                        progress = progressText
                    }
                end
            end
        end
    end
    
    if experienceBonusPercent ~= nil then
        charData.experienceBonusPercent = experienceBonusPercent
    end

    if totalQuestsFound > 0 then
        charData.lastScanTime = time()
        UpdateNewQuestTracking(pRealm, pName, charData.quests)
    end

    lastScanTime = time()

    if mainGui and mainGui:IsShown() and UpdateGUIText then
        UpdateGUIText()
    end
end


function TriggerNinjaScanWithCooldown()
    if InCombatLockdown() then return end
    local currentTime = time()
    -- Живой кулдаун 5 минут для чата
    if (currentTime - lastScanTime) >= 300 then
        ExecuteSilentBPScan()
    end
end

local memoryFrame = CreateFrame("Frame")
memoryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
memoryFrame:RegisterEvent("PLAYER_LOGOUT")
memoryFrame:RegisterEvent("QUEST_WATCH_UPDATE")

local memoryTimer = 0
local diskTimer = 0
local delayEnterScan = false
local delayLiveScan = false
local liveScanTimer = 0

memoryFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        delayEnterScan = true
        memoryTimer = -3
    elseif event == "PLAYER_LOGOUT" then
        if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
        if SaveRAMCacheToDisk then SaveRAMCacheToDisk() end
    elseif event == "QUEST_WATCH_UPDATE" then
        -- Если наше окно открыто, взводим безопасный флаг задержки на 0.3 секунды
        if mainGui and mainGui:IsShown() then
            delayLiveScan = true
            liveScanTimer = -0.3 -- Ждем ровно 300 миллисекунд
        end
    end
end)

memoryFrame:SetScript("OnUpdate", function(self, elapsed)
    if delayEnterScan then
        memoryTimer = memoryTimer + elapsed
        if memoryTimer >= 0 then
            delayEnterScan = false
            if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
        end
    end
    
    if delayLiveScan then
        liveScanTimer = liveScanTimer + elapsed
        if liveScanTimer >= 0 then
            delayLiveScan = false
            if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
        end
    end
    
    -- ИСПРАВЛЕНО: Ускоренный таймер сброса ОЗУ на диск раз в 1 минуту (60 секунд) вне боя
    diskTimer = diskTimer + elapsed
    if diskTimer >= 60 then
        diskTimer = 0
        if not InCombatLockdown() and SaveRAMCacheToDisk then
            SaveRAMCacheToDisk()
        end
    end
end)

--sbpt-v258: УМНАЯ ЦЕНТРАЛЬНАЯ ФУНКЦИЯ ТОТАЛЬНОЙ МИГРАЦИИ И ОЧИСТКИ ВСЕХ БАЗ ДАННЫХ И ХЛАМА В WTF
local CURRENT_SBPT_VERSION = 110 -- Целевая версия структуры данных 1.1.0

function ExecuteSBPTDatabaseMigration(forceClear)
    if not SirusBPTrackerConfig then SirusBPTrackerConfig = { minimapPos = 45 } end
    if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
    
    -- Считываем сохраненную версию из верхней базы на жестком диске
    local savedVersion = tonumber(SirusBPTrackerDB.Version) or 0
    
    -- УНИВЕРСАЛЬНЫЙ ТРИГГЕР: Срабатывает при изменении версии структуры в коде или ручном сбросе (forceClear)
    if forceClear or savedVersion < CURRENT_SBPT_VERSION then
        
        -- Выводим оранжевое уведомление в чат строго в момент автоматического обновления структуры
        if not forceClear then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[SirusBP]|r Обнаружено обновление структуры аддона! Старая база данных и сборы чата автоматически очищены для стабильной работы.")
        end

        -- 1. ТОТАЛЬНЫЙ СБРОС: Пересоздаем дисковые таблицы как абсолютно чистые пустые структуры
        SirusBPTrackerDB = {}
        SirusBPTrackerFilterDB = {}
        SirusBPTrackerCharFilterDB = {}
        SirusBPTrackerNewQuestDB = {}
        
        -- Намертво защищаем фоновый парсер чата от миллисекундного вакуума (nil), создавая буфер сборов мгновенно
        SirusBPTrackerDB["QUEST_LFG"] = {} 
        
        -- 2. СТРОКИ-ЛАСТИКИ: Принудительно зануляем старый дисковый хлам, заставляя WoW API навсегда стереть его из файла!
        SirusBPTrackerVersionDB = nil
        SirusBPTrackerConfigDB = nil
        SirusBPTrackerConfig.Version = nil
        
        -- 3. Полностью выжигаем оперативную память (ОЗУ-кэш твинков)
        if ramCacheDB then
            for realm in pairs(ramCacheDB) do
                ramCacheDB[realm] = nil
            end
        end
        ramCacheDB = {}
        
        -- 4. Подготавливаем чистый ОЗУ-путь для текущего реалма персонажа
        local currentRealm = GetRealmName() or "Unknown"
        SirusBPTrackerDB[currentRealm] = {}
        ramCacheDB[currentRealm] = {}
        
        -- 5. Намертво записываем маркер актуальной целой версии структуры в верхнюю базу
        SirusBPTrackerDB.Version = CURRENT_SBPT_VERSION
        
        -- 6. ПРИНУДИТЕЛЬНЫЙ ДИСКОВЫЙ СЛЕСАРЬ: Мгновенно выгружаем чистую структуру в WTF-файл
        if SaveRAMCacheToDisk then
            SaveRAMCacheToDisk()
        end
        return true
    end
    return false
end


-- ЗАПУСКАЕМ СКАНЕР НА ДВУХ СТАРТОВЫХ СОБЫТИЯХ ДЛЯ ТОЧНОГО КОНТРОЛЯ
local migrationInitFrame = CreateFrame("Frame")
migrationInitFrame:RegisterEvent("VARIABLES_LOADED")
migrationInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
migrationInitFrame:SetScript("OnEvent", function(self, event)
    -- Вызываем бесшумную проверку версии структуры базы данных на каждом этапе загрузки
    ExecuteSBPTDatabaseMigration(false)
end)

--============== блок v1.1 конец

--sbpt-v291: ЧАТ-СКАНЕР /СБПТСКАН ДЛЯ МГНОВЕННОГО ИЗВЛЕЧЕНИЯ СКРЫТЫХ ID ИЗ ССЫЛОК ЧАТА
SLASH_SBPTFINDER1 = "/сбптскан"
SLASH_SBPTFINDER2 = "/sbptscan"
SlashCmdList["SBPTFINDER"] = function(msg)
    -- Пытаемся захватить текст напрямую из активной строки ввода чата игры
    local editBox = ChatEdit_GetActiveWindow()
    local text = editBox and editBox:GetText() or msg
    
    if text and text ~= "" then
        -- Ищем каноничный паттерн близзардовской ссылки квеста |Hquest:ID
        local questID = string.match(text, "quest:(%d+)")
        
        if questID then
            -- Вытаскиваем чистое имя квеста из ссылки, очищая текстовые теги
            local questName = string.match(text, "|h%[(.-)%]|h") or "Задание"
            return
        end
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cffff2020[Внимание]|r Ссылка квеста не найдена. Инструкция: Откройте чат, зажмите Shift и кликните по квесту в журнале, чтобы ссылка появилась в строке ввода, затем введите /сбптскан и нажмите Enter!")
end
--
--sbpt-v348 [ЧАСТЬ 1]: РАСЧЕТ ТАЙМЕРОВ КД И СТАЛЬНАЯ ДВУХЭТАЖНАЯ ШАПКА ТАБЛИЦЫ АКТИВНОСТЕЙ
local LANDALOCK_QUEST_NAMES = {
    [24580] = "Ануб'Рекан должен умереть!",
    [24582] = "Нот Чумной должен умереть!",
    [24583] = "Лоскутик должен умереть!",
    [24579] = "Сартарион должен умереть!",
    [24584] = "Малигос должен умереть!",
    [24581] = "Огненный Левиафан должен умереть!",
    [24586] = "Острокрылая должна умереть!",
    [24585] = "Игнис Повелитель Горнов должен умереть!",
    [24587] = "Разрушитель XT-002 должен умереть!",
    [24589] = "Лорд Джараксус должен умереть!",
    [24590] = "Лорд Ребрад должен умереть!",
}

local activityRowsPool = {}
local activitiesHeaderFrame = nil
local currentRealm = GetRealmName() or "Unknown"

function DrawActivitiesTab()
    if not activitiesScrollFrame or not activitiesScrollFrame:IsShown() then return end
    local child = activitiesScrollFrame.child
    if not child then return end
    
    for _, row in ipairs(activityRowsPool) do
        row:Hide()
        row:SetParent(nil)
    end
    activityRowsPool = {}
    
    if activitiesHeaderFrame then
        activitiesHeaderFrame:Hide()
        activitiesHeaderFrame:SetParent(nil)
        activitiesHeaderFrame = nil
    end
    
    local sortedChars = {}
    if ramCacheDB and ramCacheDB[currentRealm] then
        for charName, charData in pairs(ramCacheDB[currentRealm]) do
            if type(charData) == "table"
                and charName ~= "QUEST_LFG"
                and charName ~= "Version"
                and (not SirusBPTrackerCharFilterDB or SirusBPTrackerCharFilterDB[charName] ~= false) then
                table.insert(sortedChars, {
                    name = charName,
                    class = charData.class or "UNKNOWN"
                })
            end
        end
    end
    table.sort(sortedChars, function(a, b) return a.name < b.name end)
    
    local activityConfig = {
        { key = "KELDANAS_COIN", texture = "Interface\\Icons\\INV_Misc_Coin_01",         name = "Щедрое пожертвование", type = "daily" },
        { key = "WEEKLY_HUNT",  texture = "Interface\\Icons\\INV_Weapon_Bow_05",         name = "Охота на Великих Чудовищ", type = "weekly" },
        { key = "NORIGORN",     texture = "Interface\\Icons\\Ability_Creature_Cursed_05",    name = "Обуздать твердыню", type = "weekly" },
        { key = "LANDALOCK",    texture = "Interface\\Icons\\INV_Misc_Note_01",          name = "Недельное задание Лан'далока", type = "weekly" },
        { key = "GLOBAL_THREAT", texture = "Interface\\Icons\\INV_Misc_GroupNeedMore",   name = "Глобальная угроза", type = "weekly" },
    }
    
    local startXOffset = 150
    
    activitiesHeaderFrame = CreateFrame("Frame", nil, child)
    activitiesHeaderFrame:SetSize(child:GetWidth() - 10, 42)
    activitiesHeaderFrame:SetPoint("TOPLEFT", child, "TOPLEFT", 5, -5)
    
    local currentTime = time()
    local dDate = date("*t", currentTime)
    dDate.hour = 3; dDate.min = 0; dDate.sec = 0
    local dailyReset = time(dDate)
    if currentTime >= dailyReset then dailyReset = dailyReset + 86400 end
    local dDiff = dailyReset - currentTime
    local dHours = math.floor(dDiff / 3600)
    local dMins = math.floor((dDiff % 3600) / 60)

    local wDate = date("*t", currentTime)
    local daysSinceThursday = wDate.wday - 5
    if daysSinceThursday < 0 then daysSinceThursday = daysSinceThursday + 7 end
    wDate.hour = 3; wDate.min = 0; wDate.sec = 0
    local weeklyReset = time(wDate) - (daysSinceThursday * 86400) + (7 * 86400)
    local wDiff = weeklyReset - currentTime
    local wDays = math.floor(wDiff / 86400)
    local wHours = math.floor((wDiff % 86400) / 3600)
    local wMins = math.floor((wDiff % 3600) / 60)

    local hTimeStr = activitiesHeaderFrame:CreateFontString(nil, "OVERLAY")
    hTimeStr:SetFont("Fonts\\FRIZQT__.TTF", math.max(8, GetMainFontSize() - 1), "NORMAL")
    hTimeStr:SetPoint("TOPLEFT", activitiesHeaderFrame, "TOPLEFT", 10, 0)
    hTimeStr:SetTextColor(0.5, 0.5, 0.5)
    hTimeStr:SetText(string.format("КД дейли: %d ч. %d мин.  |  КД викли: %d дн. %d ч. %d мин.", dHours, dMins, wDays, wHours, wMins))

    local topHeaderLine = activitiesHeaderFrame:CreateTexture(nil, "BACKGROUND")
    topHeaderLine:SetSize(activitiesHeaderFrame:GetWidth() - 10, 1)
    topHeaderLine:SetPoint("TOPLEFT", activitiesHeaderFrame, "TOPLEFT", 5, -14)
    topHeaderLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    topHeaderLine:SetVertexColor(0.45, 0.45, 0.45)
    topHeaderLine:SetAlpha(0.35)

    local bottomHeaderLine = activitiesHeaderFrame:CreateTexture(nil, "BACKGROUND")
    bottomHeaderLine:SetSize(activitiesHeaderFrame:GetWidth() - 10, 1)
    bottomHeaderLine:SetPoint("TOPLEFT", activitiesHeaderFrame, "TOPLEFT", 5, -34)
    bottomHeaderLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    bottomHeaderLine:SetVertexColor(0.45, 0.45, 0.45)
    bottomHeaderLine:SetAlpha(0.35)

    local hTitle = activitiesHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hTitle:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize(), "OUTLINE")
    hTitle:SetPoint("LEFT", activitiesHeaderFrame, "LEFT", 10, -3)
    hTitle:SetText("Персонажи")
    hTitle:SetTextColor(1, 0.82, 0)

    local compactHeaderText = { "Монета", "Охота", "Норигорн", "Лан'далок", "Глоб. угроза" }
    local headerLabels = {}
    for i, act in ipairs(activityConfig) do
        local hLabel = activitiesHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hLabel:SetText(act.name)
        hLabel:SetTextColor(0.7, 0.7, 0.7)
        headerLabels[i] = hLabel
    end

    local availableColumnWidth = math.max(1, activitiesHeaderFrame:GetWidth() - startXOffset - 10)
    local preferredHeaderFontSize = math.min(math.max(GetMainFontSize(), 11), 14)
    local headerFontSize = preferredHeaderFontSize
    local fullHeaderWidth
    while headerFontSize >= 9 do
        fullHeaderWidth = 0
        for _, hLabel in ipairs(headerLabels) do
            hLabel:SetFont("Fonts\\FRIZQT__.TTF", headerFontSize, "OUTLINE")
            fullHeaderWidth = fullHeaderWidth + hLabel:GetStringWidth()
        end
        if fullHeaderWidth + 8 * (#activityConfig - 1) <= availableColumnWidth then break end
        headerFontSize = headerFontSize - 1
    end

    local showFullHeaders = headerFontSize >= 9
    local columnCenters = {}
    if showFullHeaders then
        local fullHeaderGap = (availableColumnWidth - fullHeaderWidth) / math.max(1, #activityConfig - 1)
        local xHeaderOffset = startXOffset
        for i, hLabel in ipairs(headerLabels) do
            local labelWidth = hLabel:GetStringWidth()
            hLabel:SetWidth(labelWidth + 2)
            hLabel:SetJustifyH("CENTER")
            hLabel:SetPoint("CENTER", activitiesHeaderFrame, "LEFT", xHeaderOffset + labelWidth / 2, -3)
            columnCenters[i] = xHeaderOffset + labelWidth / 2
            xHeaderOffset = xHeaderOffset + labelWidth + fullHeaderGap
        end
    else
        local stepXOffset = availableColumnWidth / #activityConfig
        headerFontSize = preferredHeaderFontSize
        while headerFontSize > 8 do
            local fits = true
            for i, hLabel in ipairs(headerLabels) do
                hLabel:SetText(compactHeaderText[i])
                hLabel:SetFont("Fonts\\FRIZQT__.TTF", headerFontSize, "OUTLINE")
                if hLabel:GetStringWidth() > stepXOffset - 2 then fits = false end
            end
            if fits then break end
            headerFontSize = headerFontSize - 1
        end

        for i, hLabel in ipairs(headerLabels) do
            hLabel:SetFont("Fonts\\FRIZQT__.TTF", headerFontSize, "OUTLINE")
            hLabel:SetWidth(stepXOffset - 2)
            hLabel:SetJustifyH("CENTER")
            local center = startXOffset + (i - 0.5) * stepXOffset
            hLabel:SetPoint("CENTER", activitiesHeaderFrame, "LEFT", center, -3)
            columnCenters[i] = center
        end
    end

------------ блок 2    
--sbpt-v348 [ЧАСТЬ 2]: ЦИКЛ ОТРИСОВКИ СТРОК ТВИНКОВ И РЕАЛИЗАЦИЯ МАТРИЦЫ ИНДИКАТОРОВ
    local yOffset = -46
    local rowHeight = math.max(28, GetMainFontSize() + 12)
    
    for idx, charInfo in ipairs(sortedChars) do
        local row = CreateFrame("Frame", nil, child)
        row:SetSize(child:GetWidth() - 10, rowHeight)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 5, yOffset)
        
        local line = row:CreateTexture(nil, "BACKGROUND")
        line:SetSize(row:GetWidth() - 10, 1)
        line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 5, 0)
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        line:SetVertexColor(0.45, 0.45, 0.45)
        line:SetAlpha(0.35)
        
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize(), "OUTLINE")
        nameText:SetPoint("LEFT", row, "LEFT", 10, 2)
        nameText:SetWidth(125)
        nameText:SetJustifyH("LEFT")
        nameText:SetText(charInfo.name)
        
        local classColor = RAID_CLASS_COLORS[charInfo.class]
        if classColor then
            nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            nameText:SetTextColor(1, 1, 1)
        end

        for actIndex, act in ipairs(activityConfig) do
            local actBtn = CreateFrame("Button", nil, row)
            actBtn:SetSize(20, 20)
            actBtn:SetPoint("LEFT", row, "LEFT", columnCenters[actIndex] - 10, 2)
            
            local tex = actBtn:CreateTexture(nil, "BACKGROUND")
            tex:SetAllPoints(actBtn)
            tex:SetTexture(act.texture)
            actBtn.texture = tex
            
            local currentStatus = -1
            local currentQuestID
            local currentQuestName
            local currentQuestProgress
            if ramCacheDB and ramCacheDB[currentRealm] and ramCacheDB[currentRealm][charInfo.name] then
                local charData = ramCacheDB[currentRealm][charInfo.name]
                if charData.activities and charData.activities[act.key] then
                    currentQuestID = charData.activities[act.key].questID
                    currentQuestName = charData.activities[act.key].questName
                    currentQuestProgress = charData.activities[act.key].questProgress
                    if GetSmartActivityStatus then
                        currentStatus = GetSmartActivityStatus(currentRealm, charInfo.name, act.key)
                    end
                end
            end
            if act.key == "LANDALOCK" and currentQuestID then
                currentQuestName = currentQuestName or LANDALOCK_QUEST_NAMES[tonumber(currentQuestID)]
            end
            
            local statusText = actBtn:CreateFontString(nil, "OVERLAY")
            statusText:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize(), "OUTLINE")
            statusText:SetPoint("CENTER", actBtn, "CENTER", 0, 0)
            statusText:Hide()

            if currentStatus == -1 then
                tex:Hide()
                statusText:SetTextColor(0.45, 0.45, 0.45)
                statusText:SetText("(?)")
                statusText:Show()
                
            elseif currentStatus == 1 then
                tex:Show()
                tex:SetDesaturated(false)
                actBtn:SetAlpha(1.0)
                tex:SetVertexColor(1, 1, 1)
                
                local checkMark = actBtn:CreateTexture(nil, "OVERLAY")
                checkMark:SetSize(14, 14)
                checkMark:SetPoint("BOTTOMRIGHT", actBtn, "BOTTOMRIGHT", 2, -2)
                checkMark:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
                
                local pulseFrame = CreateFrame("Frame", nil, actBtn)
                local pulseElapsed = 0
                pulseFrame:SetScript("OnUpdate", function(self, elapsed)
                    pulseElapsed = pulseElapsed + elapsed
                    local alpha = 0.5 + math.sin(pulseElapsed * 3.5) * 0.5
                    checkMark:SetAlpha(alpha)
                end)
                
            elseif currentStatus == 2 then
                tex:Show()
                tex:SetDesaturated(true)
                actBtn:SetAlpha(0.4)
                
                statusText:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize() + 2, "OUTLINE")
                statusText:SetTextColor(1, 1, 1)
                statusText:SetText("?")
                statusText:Show()
                
--sbpt-v373: ЖИВАЯ ПУЛЬСАЦИЯ ВСЕЙ ИКОНКИ ЦЕЛИКОМ ДЛЯ МАКСИМАЛЬНОГО ВЫДЕЛЕНИЯ ГОТОВЫХ КВЕСТОВ
            elseif currentStatus == 3 then
                -- ВЗЯТ И ВЫПОЛНЕН: Включаем сочный цветной режим для иконки и готовим её к анимации
                tex:Show()
                tex:SetDesaturated(false) -- Возвращаем иконке сочные родные цвета, чтобы мигание выглядело красиво!
                
                statusText:SetFont("Fonts\\FRIZQT__.TTF", GetMainFontSize() + 4, "THICKOUTLINE")
                statusText:SetTextColor(1, 1, 0) -- Кристально чистый неоново-желтый цвет
                statusText:SetText("?")
                statusText:Show()
                
                -- Запускаем скрипт синхронного мягкого мигания (Pulse Fade) для ВСЕЙ кнопки целиком!
                local pulseFrame = CreateFrame("Frame", nil, actBtn)
                local pulseElapsed = 0
                pulseFrame:SetScript("OnUpdate", function(self, elapsed)
                    pulseElapsed = pulseElapsed + elapsed
                    -- Вычисляем мягкую синусоиду прозрачности в диапазоне от 0.3 (блеклая) до 1.0 (яркая)
                    local currentAlpha = 0.65 + math.sin(pulseElapsed * 4.5) * 0.35
                    
                    -- Применяем прозрачность одновременно и к иконке, и к тексту знака вопроса!
                    actBtn:SetAlpha(currentAlpha)
                end)


            else
                tex:Hide()
                statusText:SetTextColor(0.4, 0.4, 0.4)
                statusText:SetText(act.key == "LANDALOCK" and currentStatus == 0 and "?" or "—")
                statusText:Show()
            end
            
            actBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(act.name, 1, 0.82, 0)
                local statusText, statusRed, statusGreen, statusBlue
                
                if currentStatus == 1 then
                    statusText = "Статус: Выполнено и сдано"
                    statusRed, statusGreen, statusBlue = 0, 1, 0
                elseif currentStatus == 2 then
                    statusText = "Статус: В процессе выполнения"
                    statusRed, statusGreen, statusBlue = 0.6, 0.6, 0.6
                elseif currentStatus == 3 then
                    statusText = "Статус: Выполнено!"
                    statusRed, statusGreen, statusBlue = 1, 1, 0
                elseif currentStatus == -1 then
                    statusText = "Статус: Нет информации (Требуется зайти на персонажа)"
                    statusRed, statusGreen, statusBlue = 0.5, 0.5, 0.5
                elseif act.key == "LANDALOCK" and currentStatus == 0 then
                    GameTooltip:AddLine("Поговорите с Лан'далоком, чтобы узнать задание этой недели.", 0.7, 0.7, 0.7, true)
                    statusText = "Статус: Задание не взято или пока неизвестно"
                    statusRed, statusGreen, statusBlue = 0.7, 0.7, 0.7
                else
                    statusText = "Статус: Можно взять"
                    statusRed, statusGreen, statusBlue = 0.4, 1, 0.4
                end
                if act.key == "LANDALOCK" and currentStatus > 0 then
                    GameTooltip:AddLine("Задание: " .. (currentQuestName or "Название пока недоступно"), 0.7, 0.7, 0.7, true)
                end
                if act.key == "GLOBAL_THREAT" and currentStatus > 0 and currentQuestProgress then
                    GameTooltip:AddLine("Прогресс: " .. currentQuestProgress, 0.7, 0.7, 0.7, true)
                end
                GameTooltip:AddLine(statusText, statusRed, statusGreen, statusBlue, true)
                GameTooltip:Show()
            end)
            actBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        row:Show()
        table.insert(activityRowsPool, row)
        yOffset = yOffset - rowHeight
    end
    child:SetHeight(math.max(math.abs(yOffset), 1))
end

--sbpt-v372: ОФИЦИАЛЬНЫЙ СКАНЕР АКТИВНОСТЕЙ С АВТО-ДЕТЕКЦИЕЙ ЦЕЛЕЙ ДЛЯ ИДЕАЛЬНОГО ТРЕКИНГА НОРИГОРНА
local function GetWeeklyActivityResetTime(currentTime)
    local dateTable = date("*t", currentTime)
    local daysSinceThursday = dateTable.wday - 5
    if daysSinceThursday < 0 then daysSinceThursday = daysSinceThursday + 7 end
    dateTable.hour = 3
    dateTable.min = 0
    dateTable.sec = 0
    local resetTime = time(dateTable) - (daysSinceThursday * 86400)
    if dateTable.wday == 5 and currentTime < resetTime then
        resetTime = resetTime - (7 * 86400)
    end
    return resetTime
end

function UpdateCurrentCharacterActivities(turnedInQuestID)
    local charName = UnitName("player") or "Unknown"
    if charName == "Unknown" then return end
    
    if not ramCacheDB then ramCacheDB = {} end
    if not ramCacheDB[currentRealm] then ramCacheDB[currentRealm] = {} end
    if not ramCacheDB[currentRealm][charName] then ramCacheDB[currentRealm][charName] = {} end
    if not ramCacheDB[currentRealm][charName].activities then ramCacheDB[currentRealm][charName].activities = {} end
    
    if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
    if not SirusBPTrackerDB[currentRealm] then SirusBPTrackerDB[currentRealm] = {} end
    if not SirusBPTrackerDB[currentRealm][charName] then SirusBPTrackerDB[currentRealm][charName] = {} end
    if not SirusBPTrackerDB[currentRealm][charName].activities then SirusBPTrackerDB[currentRealm][charName].activities = {} end
    
    local completedQuests = {}
    GetQuestsCompleted(completedQuests)
    
    local activityTargets = {
        ["KELDANAS_COIN"] = { 11548 }, 
        ["WEEKLY_HUNT"]  = { 1015000 }, 
        ["NORIGORN"]     = { 22356, 22357, 22358, 22359, 22371, 22372, 22373 },   
        ["LANDALOCK"]    = { 24580, 24582, 24583, 24579, 24584, 24581, 24586, 24585, 24587, 24589, 24590 },
        ["GLOBAL_THREAT"] = { 21097 },
    }
    
    local currentTimeStamp = time()
    local weeklyResetTime = GetWeeklyActivityResetTime(currentTimeStamp)
    
    for key, idList in pairs(activityTargets) do
        local currentStatus = 0
        local isQuestDoneServer = false
        local matchedQuestID
        local matchedQuestName
        local questProgress
        
        -- 1. СЕРВЕРНАЯ ПРОВЕРКА СДАННЫХ КД
        for _, qID in ipairs(idList) do
            if turnedInQuestID and tonumber(turnedInQuestID) == qID then
                isQuestDoneServer = true
                matchedQuestID = qID
                matchedQuestName = LANDALOCK_QUEST_NAMES[qID]
                break
            end
        end
        if not isQuestDoneServer then
            for _, qID in ipairs(idList) do
                if (IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(qID))
                    or (completedQuests and (completedQuests[qID] or completedQuests[tostring(qID)])) then
                    isQuestDoneServer = true
                    matchedQuestID = qID
                    matchedQuestName = LANDALOCK_QUEST_NAMES[qID]
                    break
                end
            end
        end
        
        if isQuestDoneServer then
            currentStatus = 1 -- Выполнено и сдано (Зелёная галочка)
        else
            -- 2. СЕРВЕРНАЯ ПРОВЕРКА СОСТОЯНИЙ ВЗЯТОГО КВЕСТА ПО СКРЫТОМУ ИНДЕКСУ ОЗУ
            for _, qID in ipairs(idList) do
                if GetQuestLogIndexByID then
                    local internalIndex = GetQuestLogIndexByID(qID) or 0
                    if internalIndex > 0 then
                        matchedQuestID = qID
                        local questTitle = GetQuestLogTitle(internalIndex)
                        matchedQuestName = questTitle or LANDALOCK_QUEST_NAMES[qID]
                        -- Квест 100% взят персонажем! Проверяем его внутренние цели (критерии) Сируса
                        local isFinishedByObjectives = false
                        local numObjectives = GetNumQuestLeaderBoards(internalIndex) or 0
                        
                        if numObjectives > 0 then
                            local goalCount = 0 -- Инициализируем наш новый счетчик закрытых целей
                            local objectiveProgress = {}
                            for objIdx = 1, numObjectives do
                                local objectiveText, _, finished = GetQuestLogLeaderBoard(objIdx, internalIndex)
                                if finished then
                                    goalCount = goalCount + 1 -- Суммируем каждого убитого босса/закрытую цель
                                end
                                if objectiveText and objectiveText ~= "" then
                                    table.insert(objectiveProgress, objectiveText)
                                end
                            end
                            if #objectiveProgress > 0 then
                                questProgress = table.concat(objectiveProgress, "; ")
                            end
                            -- Подтверждаем выполнение только если количество закрытых целей строго совпало с общим числом!
                            if goalCount == numObjectives then
                                isFinishedByObjectives = true
                            end
                        end
                        
                        -- Дополнительная близзардовская проверка на случай кастомных изменений Сируса
                        local _, _, _, _, _, isComplete = GetQuestLogTitle(internalIndex)
                        
                        if isComplete == 1 or isComplete == true or isFinishedByObjectives then
                            currentStatus = 3 -- Взят и выполнен! (Яркий жёлтый мерцающий ?)
                        else
                            currentStatus = 2 -- Взят, но находится в процессе (Белый ?)
                        end
                        break
                    end
                end
            end

            if currentStatus == 0 and key == "LANDALOCK" then
                local previousActivity = ramCacheDB[currentRealm][charName].activities[key]
                if previousActivity and previousActivity.status == 1
                    and (previousActivity.lastCheck or 0) >= weeklyResetTime then
                    currentStatus = 1
                    matchedQuestID = previousActivity.questID
                    matchedQuestName = previousActivity.questName
                end
            end
        end

        if currentStatus == 1 or currentStatus == 0 then
            local previousActivity = ramCacheDB[currentRealm][charName].activities[key]
            if previousActivity and previousActivity.questID == matchedQuestID
                and (key ~= "LANDALOCK" or currentStatus == 1) then
                questProgress = questProgress or previousActivity.questProgress
            end
        end

        if key == "GLOBAL_THREAT" and currentStatus == 1 then
            questProgress = questProgress or "Сдано"
        end

        if key == "LANDALOCK" and matchedQuestID then
            matchedQuestName = matchedQuestName or LANDALOCK_QUEST_NAMES[matchedQuestID]
        end
        
        -- Бережно сохраняем выверенный статус в ОЗУ-кэш и на жесткий диск WTF
        ramCacheDB[currentRealm][charName].activities[key] = {
            status = currentStatus,
            lastCheck = currentTimeStamp,
            questID = matchedQuestID,
            questName = matchedQuestName,
            questProgress = questProgress
        }
        SirusBPTrackerDB[currentRealm][charName].activities[key] = {
            status = currentStatus,
            lastCheck = currentTimeStamp,
            questID = matchedQuestID,
            questName = matchedQuestName,
            questProgress = questProgress
        }
    end
end

function GetSmartActivityStatus(realm, char, activityKey)
    if not ramCacheDB or not ramCacheDB[realm] or not ramCacheDB[realm][char] then return -1 end
    if not ramCacheDB[realm][char].activities or not ramCacheDB[realm][char].activities[activityKey] then return -1 end
    
    local data = ramCacheDB[realm][char].activities[activityKey]
    local savedStatus = data.status or 0
    local lastCheck = data.lastCheck or 0
    
    local currentTime = time()
    
    if activityKey == "KELDANAS_COIN" then
        local dateTable = date("*t", currentTime)
        dateTable.hour = 3; dateTable.min = 0; dateTable.sec = 0
        local serverResetTime = time(dateTable)
        if currentTime < serverResetTime then serverResetTime = serverResetTime - 86400 end
        if lastCheck < serverResetTime then return 0 end
    else
        if lastCheck < GetWeeklyActivityResetTime(currentTime) then return 0 end
    end
    
    return savedStatus
end

--sbpt-v380: ЭКОНОМИЧНЫЙ ТИХИЙ ТАЙМЕР АКТИВНОСТЕЙ (БЕЗ ПРОЦЕССОРНОГО СПАМА КАЖДЫЕ 2 СЕКУНДЫ)
if not sbptActivityTimerFrame then
    sbptActivityTimerFrame = CreateFrame("Frame")
end

local timeSinceLastUpdate = 0
sbptActivityTimerFrame:SetScript("OnUpdate", function(self, elapsed)
    timeSinceLastUpdate = timeSinceLastUpdate + elapsed
    if timeSinceLastUpdate >= 60 then
        timeSinceLastUpdate = 0
        -- Проверка выполняется строго раз в минуту в фоновом режиме для оффлайн КД
        if QueryQuestsCompleted then QueryQuestsCompleted() end
        if UpdateCurrentCharacterActivities then UpdateCurrentCharacterActivities() end
        if ExecuteSilentBPScan then ExecuteSilentBPScan(true) end
        if UpdateGUIText then UpdateGUIText() end
        if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
            DrawActivitiesTab()
        end
    end
end)

--- ===========================
--sbpt-v640: МОДУЛЬ ДИСКРЕТНОЙ КАРУСЕЛИ С ЗАЩИТОЙ ОТ ПОВТОРНОГО СПАМА ПРОЧИТАННЫХ СБОРОВ
local SBPT_ActiveNotifications = {} -- Текущие уведомления, зажигающие кружок
local SBPT_ReadInSession = {}       -- Чёрный список прочитанных сборов ["ID_Лидер"] = время_чтения
local SBPT_DisplayRotationList = {} 
local currentRotationIndex = 1

local pulseFrame = CreateFrame("Frame")
pulseFrame:Hide() 

local colorTimer = 0 
local tabAlpha = 1
local tabDirection = -1

local function UpdateNextClassColorDiscrete()
    if #SBPT_DisplayRotationList == 0 then
        if SirusBPMinimapButton and SirusBPMinimapButton.DotFrame then SirusBPMinimapButton.DotFrame:Hide() end
        pulseFrame:Hide()
        return
    end

    currentRotationIndex = currentRotationIndex + 1
    if currentRotationIndex > #SBPT_DisplayRotationList then currentRotationIndex = 1 end

    local currentItem = SBPT_DisplayRotationList[currentRotationIndex]
    if currentItem and SirusBPMinimapButton and SirusBPMinimapButton.NotificationDot then
        local colorTable = RAID_CLASS_COLORS[currentItem.class] or { r = 1, g = 0.5, b = 0 }
        SirusBPMinimapButton.NotificationDot:SetVertexColor(colorTable.r, colorTable.g, colorTable.b, 1)
        SirusBPMinimapButton.NotificationDot:SetAlpha(1)
    end
end

pulseFrame:SetScript("OnUpdate", function(self, elapsed)
    -- 1. СВЕТОФОР ЦВЕТОВ КЛАССОВ (100% яркости, шаг 2 секунды)
    if #SBPT_DisplayRotationList > 1 then
        colorTimer = colorTimer + elapsed
        if colorTimer >= 2.0 then
            colorTimer = 0
            UpdateNextClassColorDiscrete()
        end
    else
        colorTimer = 0
        local currentItem = SBPT_DisplayRotationList[1]
        if currentItem and SirusBPMinimapButton and SirusBPMinimapButton.NotificationDot then
            local colorTable = RAID_CLASS_COLORS[currentItem.class] or { r = 1, g = 0.5, b = 0 }
            SirusBPMinimapButton.NotificationDot:SetVertexColor(colorTable.r, colorTable.g, colorTable.b, 1)
            SirusBPMinimapButton.NotificationDot:SetAlpha(1)
        end
    end
    
    -- 2. НЕОНОВОЕ ДЫХАНИЕ ФОНА ВКЛАДКИ СБОРОВ
    tabAlpha = tabAlpha + (tabDirection * elapsed * 0.5)
    if tabAlpha <= 0.1 then tabAlpha = 0.1 tabDirection = 1
    elseif tabAlpha >= 0.85 then tabAlpha = 0.85 tabDirection = -1 end

    if mainGui and mainGui:IsShown() and mainGui.myTabs then
        local currentTab = SirusBPTrackerConfig and SirusBPTrackerConfig.ActiveTab or 1
        if mainGui.myTabs[2] and mainGui.myTabs[2].SetBackdropColor and currentTab ~= 2 then
            mainGui.myTabs[2]:SetBackdropColor(0.10, 0.28, 0.46, tabAlpha)
            mainGui.myTabs[2]:SetBackdropBorderColor(0.25, 0.65, 0.9, tabAlpha)
        end
    end
end)

local function RebuildDisplayRotationList()
    SBPT_DisplayRotationList = {}
    local seenChars = {}
    for _, info in pairs(SBPT_ActiveNotifications) do
        local uniqueKey = info.charName
        if not seenChars[uniqueKey] then
            seenChars[uniqueKey] = true
            table.insert(SBPT_DisplayRotationList, { charName = info.charName, class = info.class })
        end
    end
    
    if #SBPT_DisplayRotationList == 0 then
        if SirusBPMinimapButton and SirusBPMinimapButton.DotFrame then SirusBPMinimapButton.DotFrame:Hide() end
        pulseFrame:Hide()
    elseif not pulseFrame:IsShown() then
        currentRotationIndex = 0
        colorTimer = 0
        UpdateNextClassColorDiscrete()
        tabAlpha = 0.85
        tabDirection = -1
        if SirusBPMinimapButton and SirusBPMinimapButton.DotFrame then SirusBPMinimapButton.DotFrame:Show() end
        pulseFrame:Show()
    end
end

function SBPT_CheckAndIncrementNotification(questID, leaderName)
    if not questID or type(questID) ~= "number" or not leaderName then return end
    
    local isMainFrameShown = mainGui and mainGui:IsShown()
    local currentTab = SirusBPTrackerConfig and SirusBPTrackerConfig.ActiveTab or 1
    if isMainFrameShown and currentTab == 2 then return end
    
    -- ЗАЩИТНЫЙ РУБЕЖ: Если эта связка Квест+Лидер находится в черном списке прочитанного — ПОЛНОСТЬЮ ИГНОРИРУЕМ СПАМ!
    local mainSyncKey = tostring(questID) .. "_" .. tostring(leaderName)
    if SBPT_ReadInSession[mainSyncKey] then
        SBPT_ReadInSession[mainSyncKey] = time() -- Просто обновляем время активности лидера
        return
    end
    
    local currentTime = time()
    local currentRealm = GetRealmName()
    local hasChanges = false
    
    if ramCacheDB and ramCacheDB[currentRealm] then
        local realmData = ramCacheDB[currentRealm]
        for charName, data in pairs(realmData) do
            if charName ~= "QUEST_LFG" and type(data) == "table" and data.quests then
                if SirusBPTrackerCharFilterDB and SirusBPTrackerCharFilterDB[charName] ~= false then
                    local q = data.quests[questID]
                    if q and q.progress ~= "Завершено" then
                        local uniqueSyncKey = mainSyncKey .. "_" .. tostring(charName)
                        
                        if SBPT_ActiveNotifications[uniqueSyncKey] then
                            SBPT_ActiveNotifications[uniqueSyncKey].time = currentTime
                        else
                            SBPT_ActiveNotifications[uniqueSyncKey] = {
                                time = currentTime,
                                charName = charName,
                                class = data.class or "WARRIOR"
                            }
                            hasChanges = true
                        end
                    end
                end
            end
        end
    end
    if hasChanges then RebuildDisplayRotationList() end
end

-- Функция сброса индикации при посещении вкладки Сборов
function SBPT_ResetMinimapNotification()
    -- ИСПРАВЛЕНО: Перед тем как стереть текущие уведомления, переносим их заголовки в черный список прочитанного!
    for uniqueSyncKey, info in pairs(SBPT_ActiveNotifications) do
        -- Вырезаем чистый ключ Квест_Лидер (первые два элемента до имени твинка)
        local questID, leaderName = string.match(uniqueSyncKey, "^([%d]+)_([^_]+)")
        if questID and leaderName then
            local mainSyncKey = questID .. "_" .. leaderName
            SBPT_ReadInSession[mainSyncKey] = time() -- Запоминаем, что этот сбор прочитан Медведжем!
        end
    end

    SBPT_ActiveNotifications = {} 
    SBPT_DisplayRotationList = {}
    pulseFrame:Hide() 
    if SirusBPMinimapButton and SirusBPMinimapButton.DotFrame then SirusBPMinimapButton.DotFrame:Hide() end
    
    if mainGui and mainGui.myTabs and mainGui.myTabs[2] and mainGui.myTabs[2].SetBackdropColor then
        local currentTab = SirusBPTrackerConfig and SirusBPTrackerConfig.ActiveTab or 1
        if currentTab ~= 2 then
            SetBlueTabStyle(mainGui.myTabs[2], false)
        end
    end
end

-- Автоматический 5-секундный цензор времени старения (Лимит 10 минут)
local SBPT_TimeUpdaterFrame = CreateFrame("Frame")
local SBPT_LastTickTime = 0
SBPT_TimeUpdaterFrame:SetScript("OnUpdate", function(self, elapsed)
    SBPT_LastTickTime = SBPT_LastTickTime + elapsed
    if SBPT_LastTickTime >= 5 then
        SBPT_LastTickTime = 0
        local currentTime = time()
        
        if mainGui and mainGui:IsShown() then
            local currentTab = SirusBPTrackerConfig and SirusBPTrackerConfig.ActiveTab or 1
            if currentTab == 2 then SBPT_ResetMinimapNotification() return end
        end
        
        -- 1. Ревизия старения текущих уведомлений
        local hasChanges = false
        for syncKey, info in pairs(SBPT_ActiveNotifications) do
            if (currentTime - info.time) > 600 then
                SBPT_ActiveNotifications[syncKey] = nil
                hasChanges = true
            end
        end
        
        -- 2. Ревизия старения черного списка ПРОЧИТАННОГО (Если лидер молчит больше 10 минут — даем ему право зажечь лапу снова когда-то потом)
        for mainSyncKey, readTime in pairs(SBPT_ReadInSession) do
            if (currentTime - readTime) > 600 then
                SBPT_ReadInSession[mainSyncKey] = nil
            end
        end
        
        if hasChanges then
            RebuildDisplayRotationList()
            local aliveCount = 0
            for _, _ in pairs(SBPT_ActiveNotifications) do aliveCount = aliveCount + 1 end
            if aliveCount == 0 and mainGui and mainGui.myTabs and mainGui.myTabs[2] and mainGui.myTabs[2].SetBackdropColor then
                SetBlueTabStyle(mainGui.myTabs[2], false)
            end
        end
    end
end)