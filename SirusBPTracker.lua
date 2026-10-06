local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

-- Просто объявляем имена для БД
SirusBPTrackerDB = SirusBPTrackerDB
SirusBPTrackerFilterDB = SirusBPTrackerFilterDB
SirusBPTrackerCharFilterDB = SirusBPTrackerCharFilterDB
SirusBPTrackerConfig = SirusBPTrackerConfig

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

local function GetAnyText(obj)
    if not obj then return nil end
    if obj.GetText and obj:GetText() and obj:GetText() ~= "" then return obj:GetText() end
    if obj.Text and obj.Text.GetText and obj.Text:GetText() and obj.Text:GetText() ~= "" then return obj.Text:GetText() end
    return nil
end

--[[ страя функция получения данных
-- ИСПРАВЛЕННЫЙ Высокоточное сканирование карточки квеста
local function GetProgressDirect(questFrameName)
    local mainFrame = _G[questFrameName]
    if not mainFrame then return "0/1" end
    local bestProgress, maxTargetValue, isCompleted = nil, -1, false
    
    local function ScanElement(obj)
        if not obj then return end
        local txt = GetAnyText(obj)
        if txt and txt ~= "" then
            local cleanTxt = string.gsub(txt, "^%s*(.-)%s*$", "%1")
            
            -- Сбор цифрового прогресса (0/1, 3/5 и т.д.)
            if string.match(cleanTxt, "^%d+/%d+$") then
                local current, target = string.match(cleanTxt, "(%d+)/(%d+)")
                if current and target then
                    local targetNum = tonumber(target) or 0
                    if targetNum > maxTargetValue then maxTargetValue = targetNum; bestProgress = cleanTxt end
                end
            end
            
            -- Сбор процентного прогресса
            if string.match(cleanTxt, "^%d+%%$") then
                local num = tonumber(string.match(cleanTxt, "(%d+)")) or 0
                if num > maxTargetValue then maxTargetValue = num; bestProgress = cleanTxt end
            end
            
            -- ИСПРАВЛЕНО: Завершено должно быть ОТДЕЛЬНЫМ словом (а не частью слова "Завершите")
            -- Ищем строго точное совпадение со статусом Сируса
            if cleanTxt == "Завершено" or cleanTxt == "Выполнено" or cleanTxt == "Завершенено" then
                isCompleted = true
            end
        end
        
        if obj.GetRegions then
            local regions = { obj:GetRegions() }
            for _, r in ipairs(regions) do
                local rtxt = GetAnyText(r)
                if rtxt and rtxt ~= "" then
                    local cleanRtxt = string.gsub(rtxt, "^%s*(.-)%s*$", "%1")
                    
                    if string.match(cleanRtxt, "^%d+/%d+$") then
                        local current, target = string.match(cleanRtxt, "(%d+)/(%d+)")
                        if current and target then
                            local targetNum = tonumber(target) or 0
                            if targetNum > maxTargetValue then maxTargetValue = targetNum; bestProgress = cleanRtxt end
                        end
                    end
                    
                    if string.match(cleanRtxt, "^%d+%%$") then
                        local num = tonumber(string.match(cleanRtxt, "(%d+)")) or 0
                        if num > maxTargetValue then maxTargetValue = num; bestProgress = cleanRtxt end
                    end
                    
                    -- ИСПРАВЛЕНО И ТУТ: Жесткая проверка на отдельное статусное слово
                    if cleanRtxt == "Завершено" or cleanTxt == "Выполнено" or cleanTxt == "Завершенено" then
                        isCompleted = true
                    end
                end
            end
        end
        if obj.GetChildren then
            local children = { obj:GetChildren() }
            for _, child in ipairs(children) do ScanElement(child) end
        end
    end
    
    ScanElement(mainFrame)
    if isCompleted then return "Завершено" end
    if bestProgress then return bestProgress end
    return "0/1"
end
]]

--[[ страя функция получения данных
-- Функция записи данных в БД
local function DirectScanBattlePass()
    if not BattlePassFrame or not BattlePassFrame:IsShown() then return false end
    local charKey = UnitName("player") .. " - " .. GetRealmName()
    local tempLog = {}
    local validQuestsFound = 0
    
    for h = 1, 2 do
        local holderName = "BattlePassFrameContentQuestPageScrollFrameScrollChildQuestHolder" .. h
        local holder = _G[holderName]
        if holder and holder:IsShown() then
            local blockType = "Сезонные"
            if h == 1 then blockType = "Ежедневные" end
            
            for q = 1, 30 do
                local questFrameName = holderName .. "QuestFrame" .. q
                local questFrame = _G[questFrameName]
                if questFrame and questFrame:IsShown() then
                    local descFrame = _G[questFrameName .. "ProgressDescription"]
                    local questText = descFrame and descFrame:GetText()
                    if questText and questText ~= "" and string.len(questText) > 5 then
                        table.insert(tempLog, {
                            text = questText,
                            progress = GetProgressDirect(questFrameName),
                            block = blockType
                        })
                        validQuestsFound = validQuestsFound + 1
                    end
                end
            end
        end
    end
    
    if validQuestsFound > 0 then
        SirusBPTrackerDB[charKey] = SirusBPTrackerDB[charKey] or {}
        SirusBPTrackerDB[charKey].class = select(2, UnitClass("player"))
        SirusBPTrackerDB[charKey].quests = tempLog
        return true
    end
    return false
end
]]
-------------------------------------------------------------------------------
-- GUI ИНТЕРФЕЙС И ПОИСКОВАЯ СТРОКА
-------------------------------------------------------------------------------
local mainGui = nil
local filterGui = nil
local helpGui = nil
local UpdateGUIText
local CreateFilterGUI
local CreateHelpGUI

--sbpt-v50-ui-rebuild: ПОЛНОЕ ОБНОВЛЕНИЕ СТРУКТУРЫ ОКНА (ПРАВИЛЬНЫЕ ВКЛАДКИ)
CreateMainGUI = function()
    if mainGui then return mainGui end

    local gui = CreateFrame("Frame", "SirusBPMainFrame", UIParent)
    gui:SetSize(520, 450)
    gui:SetPoint("CENTER", 0, 0)
    gui:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    gui:SetBackdropColor(0, 0, 0, 0.9)
    gui:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    -- Область перемещения за верхнюю рамку (высота 30 пикселей)
    gui:SetMovable(true)
    gui:EnableMouse(true)
    local titleRegion = gui:CreateTitleRegion()
    titleRegion:SetPoint("TOPLEFT", gui, "TOPLEFT", 0, 0)
    titleRegion:SetPoint("BOTTOMRIGHT", gui, "TOPRIGHT", -180, -30)

    local title = gui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -15)
    title:SetText("Sirus BP Tracker")

    local closeBtn = CreateFrame("Button", nil, gui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)

    local filterBtn = CreateFrame("Button", nil, gui)
    filterBtn:SetSize(20, 20)
    filterBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, -5)
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
    helpBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    
    -- Применяем фирменную темную полупрозрачную подложку нашего аддона
    helpBtn:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    helpBtn:SetBackdropColor(0, 0, 0, 0.8)
    helpBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- Рисуем аккуратный, центрированный знак вопроса без сверхжирных наложений
    local helpBtnText = helpBtn:CreateFontString(nil, "OVERLAY")
    helpBtnText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    helpBtnText:SetPoint("CENTER", 0, 0) -- Идеальный центр прямоугольной кнопки
    helpBtnText:SetText("?")
    helpBtnText:SetTextColor(0.7, 0.7, 0.7, 1) -- Сдержанный серебристо-серый цвет в общий тон шапки

    helpBtn.text = helpBtnText

    -- Подсветка при наведении мыши
    helpBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.15, 0.25, 0.35, 0.95)
        self:SetBackdropBorderColor(0, 0.7, 1, 1)
        self.text:SetTextColor(1, 1, 1)
    end)
    helpBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
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
    local sirusBpOpenBtn = CreateFrame("Button", "SirusBPOpenNativeBtn", gui, "UIPanelButtonTemplate")
    sirusBpOpenBtn:SetSize(32, 20)
    sirusBpOpenBtn:SetPoint("RIGHT", helpBtn, "LEFT", -5, 0) -- Садится ровно левее золотого знака "?"
    sirusBpOpenBtn:SetText("БП")
    
    if sirusBpOpenBtn.Text then
        sirusBpOpenBtn.Text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    elseif _G[sirusBpOpenBtn:GetName() .. "Text"] then
        _G[sirusBpOpenBtn:GetName() .. "Text"]:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    end

    sirusBpOpenBtn:SetScript("OnClick", function()
        -- 1. Сначала открываем само официальное окно БП Сируса
        if ToggleBattlePassFrame then
            pcall(ToggleBattlePassFrame)
        elseif BattlePassFrame and BattlePassFrame.Show then
            if BattlePassFrame:IsShown() then BattlePassFrame:Hide() else BattlePassFrame:Show() end
        end

        -- 2. ИДЕАЛЬНЫЙ АДРЕСНЫЙ ТРИГГЕР: Имитируем щелчок по родной глобальной кнопке Сируса!
        if BattlePassFrame and BattlePassFrame:IsShown() then
            if BattlePassFrameTopPanelQuestPageButton and BattlePassFrameTopPanelQuestPageButton.Click then
                pcall(BattlePassFrameTopPanelQuestPageButton.Click, BattlePassFrameTopPanelQuestPageButton)
            end
        end
    end)

    -- ИСПРАВЛЕНО: Жесткая привязка к стабильной helpBtn со сдвигом влево на -52 (строка гарантированно на месте!)
    local searchBox = CreateFrame("EditBox", "SirusBPSearchBox", gui)
    searchBox:SetSize(130, 20)
    searchBox:SetPoint("TOPRIGHT", helpBtn, "TOPLEFT", -52, -1) -- Четко левее кнопки БП с красивым отступом
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject("GameFontHighlightSmall")
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 12, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    searchBox:SetBackdropColor(0, 0, 0, 1)
    searchBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local searchPrompt = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchPrompt:SetPoint("LEFT", searchBox, "LEFT", 6, 0)
    searchPrompt:SetText("Поиск...")

    searchBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then searchPrompt:Hide() else searchPrompt:Show() end
        if UpdateGUIText then UpdateGUIText() end
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- ИСПРАВЛЕНО: Скролл-фрейм для твинков (Вкладка 1)
    local scrollFrame = CreateFrame("ScrollFrame", "SirusBPScrollFrame", gui, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 10, -75)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 15)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(460, 1)
    scrollFrame:SetScrollChild(scrollChild)
    gui.scrollChild = scrollChild

    -- ИСПРАВЛЕНО: Создаем независимый скролл-фрейм для сборов (Вкладка 2) без капризных чат-окон!
    local sborScrollFrame = CreateFrame("ScrollFrame", "SirusBPSborScrollFrame", gui, "UIPanelScrollFrameTemplate")
    sborScrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 10, -75)
    sborScrollFrame:SetPoint("BOTTOMRIGHT", -30, 15)

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

--sbpt-v60-tab-colors: КРАСИВЫЙ ЦВЕТ ВКЛАДОК БЕЗ УЖАСНОГО БЕЛОГО ФОНА
    gui.myTabs = {}
    local function SwitchTab(id)
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        SirusBPTrackerConfig.ActiveTab = id
        
        if id == 1 then
            scrollFrame:Show()
            sborScrollFrame:Hide()
            searchBox:Show()
        else
            scrollFrame:Hide()
            sborScrollFrame:Show()
            searchBox:Hide()
        end

        -- ИСПРАВЛЕНО: Красивые цвета для активной и неактивной вкладок
        for tID, btn in ipairs(gui.myTabs) do
            if tID == id then
                -- АКТИВНАЯ ВКЛАДКА: Стильный темно-синий цвет (R, G, B, Alpha)
                btn:SetBackdropColor(0.12, 0.22, 0.34, 0.95)
                btn:SetBackdropBorderColor(0, 0.6, 0.9, 1) -- Голубое неоновое свечение рамки
                btn.text:SetTextColor(1, 0.82, 0) -- Золотистый яркий текст
            else
                -- НЕАКТИВНАЯ ВКЛАДКА: Прозрачно-угольный цвет в тон главного фрейма
                btn:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
                btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) -- Тусклая серая рамка
                btn.text:SetTextColor(0.5, 0.5, 0.5) -- Приглушенный серый текст
            end
        end
        if UpdateGUIText then UpdateGUIText() end
    end

    local tabNames = { "Квесты персонажей", "Актуальные сборы" }
    for i = 1, 2 do
        local tab = CreateFrame("Button", nil, gui)
        tab:SetSize(140, 22)
        tab:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 10, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        
        if i == 1 then
            tab:SetPoint("TOPLEFT", gui, "TOPLEFT", 15, -45)
        else
            tab:SetPoint("LEFT", gui.myTabs[1], "RIGHT", 5, 0)
        end

        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.text:SetPoint("CENTER", 0, 0)
        tab.text:SetText(tabNames[i])

        -- ЭФФЕКТ НАВЕДЕНИЯ МЫШИ: Вкладка слегка подсвечивается при наведении курсора
        tab:SetScript("OnEnter", function(self)
            if SirusBPTrackerConfig.ActiveTab ~= i then
                self:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
                self.text:SetTextColor(0.8, 0.8, 0.8)
            end
        end)
        tab:SetScript("OnLeave", function(self)
            if SirusBPTrackerConfig.ActiveTab ~= i then
                self:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
                self.text:SetTextColor(0.5, 0.5, 0.5)
            end
        end)

        tab:SetScript("OnClick", function() SwitchTab(i) end)
        gui.myTabs[i] = tab
    end
--sbpt-v60-tab-colors: КОНЕЦ ИСПРАВЛЕНИЯ ЦВЕТОВ ВКЛАДОК


    gui:SetScript("OnShow", function()
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        local savedTab = SirusBPTrackerConfig.ActiveTab or 1
        SwitchTab(savedTab)
    end)

    gui:Hide()
    mainGui = gui
    return mainGui
end

---------------------------------------------------------------------------------------------------------------

--sbpt-v08-ui-fixes: ЧАСТЬ 1 ИЗ 2 ПОЛНОГО БЛОКА ИНТЕРФЕЙСА (ЦВЕТА КЛАССОВ, ГОЛУБЫЕ ПЛАШКИ, ЗОЛОТЫЕ КВЕСТЫ)
local function AcquireFontString(parent, font, r, g, b, justify, width, indent, yOffset)
    local fs
    if #fontStringPool > 0 then
        fs = table.remove(fontStringPool)
        fs:SetParent(parent)
        fs:Show()
    else
        fs = parent:CreateFontString(nil, "OVERLAY")
    end
    fs:ClearAllPoints()
    
    fs:SetFont("Fonts\\FRIZQT__.TTF", (font == "GameFontNormalLarge" and 13 or 11), "OUTLINE")
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
    local gui = CreateMainGUI()
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
                        if q then
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

            local sborLine = sborChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            sborLine:SetTextColor(1, 1, 1)
            sborLine:SetPoint("TOPLEFT", sborChild, "TOPLEFT", 15, yOffset)
            sborLine:SetWidth(440)
            sborLine:SetJustifyH("LEFT")
            sborLine:SetNonSpaceWrap(true)
            
            -- ВЫВОД НА ЭКРАН: Ставим цветные буквы [М, М] строго ПЕРЕД красивым описанием задания
            sborLine:SetText(string.format("|cff888888(%s)|r %s|cff%s[%s]|r |cff%s[%s]|r: |cffffffff\"%s\"|r", 
                timeStr, twinsLine, hexColor, questFullName, classHex, auth.name, cleanMsg))

            local rowBtn = CreateFrame("Button", "SirusBPSborRowBtn_" .. sborBtnIdx, sborChild)
            rowBtn:SetPoint("TOPLEFT", sborLine, "TOPLEFT", 0, 0)
            rowBtn:SetPoint("BOTTOMRIGHT", sborLine, "BOTTOMRIGHT", 0, 0)
            rowBtn:RegisterForClicks("LeftButtonUp")
            rowBtn.questName = questFullName
            rowBtn.authorName = auth.name
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

            yOffset = yOffset - (sborLine:GetStringHeight() + 8)
            table.insert(sborChild.widgets, sborLine)
            table.insert(sborChild.widgets, rowBtn)
        end
        sborChild:SetHeight(math.abs(yOffset) + 20)
    end
-- КОНЕЦ ОБНОВЛЕННОГО БЛОКА ВКЛАДКИ СБОРОВ ЧАТА

     -- ========================================================================
    -- ЛОГИКА ВКЛАДКИ 1: СТАНДАРТНЫЙ СПИСОК КВЕСТОВ ПЕРСОНАЖЕЙ (ИНТЕРАКТИВНЫЙ МОНОЛИТ)
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
                        
                        -- sbpt-v199: Жесткая и правильная фильтрация квестов в настройках по числовому ID
                        local targetNumID = tonumber(questID) or tonumber(q.id)
                        if not targetNumID or SirusBPTrackerFilterDB[targetNumID] ~= false then
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

                if hasMatchingQuests then
                    hasAnyData = true
                    
                    local catFs = AcquireFontString(child, "GameFontNormalLarge", 0, 1, 1, "LEFT", 440, 10, yOffset)
                    catFs:SetText("=== " .. catName .. " ===")
                    yOffset = yOffset - (catFs:GetStringHeight() + 3)
                    table.insert(child.widgets, catFs)

                    local statStrings = {}
                    for charName, charStat in pairs(stats[catName]) do
                        local hexColor = CLASS_COLORS[charStat.class or ""] or "ffffff"
                        table.insert(statStrings, string.format("|cff%s%s|r (|cffffffff%d/%d|r)", 
                            hexColor, charName, charStat.completed, charStat.total))
                    end
                    if #statStrings > 0 then
                        local statLine = table.concat(statStrings, ", ")
                        local statFs = AcquireFontString(child, "GameFontNormalSmall", 1, 1, 1, "LEFT", 440, 15, yOffset)
                        statFs:SetText(statLine)
                        yOffset = yOffset - (statFs:GetStringHeight() + 10)
                        table.insert(child.widgets, statFs)
                    end

                    if questList then
                        for questText, characters in pairs(questList) do
                            if searchText == "" or string.find(string.lower(questText), searchText, 1, true) then
--sbpt-v202: ИСПРАВЛЕННЫЙ ВЫВОД SHIFT-ЛИНКА С ЖЕСТКОЙ ФИКСАЦИЕЙ ЧИСЛОВЫХ ID КВЕСТОВ ИЗ ОЗУ
                                local qFs = AcquireFontString(child, "GameFontHighlight", 1, 0.82, 0, "LEFT", 430, 15, yOffset)
                                qFs:SetText("• " .. questText)
                                
                                -- Создаем интерактивную кнопку на названии квеста
                                local questClickBtn = CreateFrame("Button", nil, child)
                                questClickBtn:SetPoint("TOPLEFT", qFs, "TOPLEFT", -5, 2)
                                questClickBtn:SetPoint("BOTTOMRIGHT", qFs, "BOTTOMRIGHT", 5, -2)
                                questClickBtn:RegisterForClicks("LeftButtonUp")
                                
                                questClickBtn:SetScript("OnEnter", function()
                                    qFs:SetTextColor(0, 0.7, 1, 1) -- Голубой ховер
                                end)
                                questClickBtn:SetScript("OnLeave", function()
                                    qFs:SetTextColor(1, 0.82, 0, 1) -- Золотой исходный
                                end)
                                
                                yOffset = yOffset - (qFs:GetStringHeight() + 3)
                                table.insert(child.widgets, qFs)
                                table.insert(child.widgets, questClickBtn)

                                local charStrings = {}
                                local exactQuestID = nil
                                local exactRawQuest = nil
                                
                                -- Извлекаем чистые данные квеста напрямую из ОЗУ-кэша твинков
                                for _, char in ipairs(characters) do
                                    if char.questID then exactQuestID = tonumber(char.questID) end
                                    if char.rawQuest then 
                                        exactRawQuest = char.rawQuest 
                                        if char.rawQuest.id then exactQuestID = tonumber(char.rawQuest.id) end
                                    end
                                    
                                    local hexColor = CLASS_COLORS[char.class or ""] or "ffffff"
                                    local currentProgressText = tostring(char.progress or "0/0")
                                    if string.find(currentProgressText, "/100$") then
                                        local num = tonumber(string.match(currentProgressText, "^([%d%.]+)"))
                                        if num then currentProgressText = math.floor(num + 0.5) .. "%" end
                                    end
                                    
                                    local progStr = "|cff00ff00" .. currentProgressText .. "|r"
                                    if currentProgressText == "Завершено" or currentProgressText == "Завершено!" then
                                        progStr = "|cff00ff00Завершено!|r"
                                    end
                                    
                                    table.insert(charStrings, string.format("|cff%s%s|r - %s", hexColor, char.name, progStr))
                                end

                                -- Намертво фиксируем переменные и вычисляем правильный ID категории Сируса (:82/:83)
                                local capturedQuestID = exactQuestID or 28113
                                local capturedQuestText = questText or "Задание БП"
                                local capturedRawQuest = exactRawQuest
                                
                                local sirusTypeParam = 83 -- По умолчанию ставим 83 (Сезонное)
                                if capturedRawQuest and capturedRawQuest.type == 1 then
                                    sirusTypeParam = 82 -- Выставляем 82 для Ежедневных заданий Сируса
                                elseif string.find(string.lower(capturedQuestText), "ежедневное") then
                                    sirusTypeParam = 82
                                end
                                
--sbpt-v223: МOНОЛИТ СКРИПТА КЛИКА: УСТРАНЕНА ОШИБКА СКОБОК 876, ЖЕСТКИЙ КАНАЛ [4. МИР] ДЛЯ ELVUI
                                questClickBtn:SetScript("OnClick", function()
                                    -- МЕХАНИКА А: Shift+Клик по названию открывает /4 Мир и шлет оригинальный линк БП Сируса
                                    if IsShiftKeyDown() then
                                        -- Ищем канал "Мир", если не найден - резервный "ПоискСпутников", иначе дефолт 4
                                        local channelNum = GetChannelName("Мир")
                                        if not channelNum or channelNum == 0 then 
                                            channelNum = GetChannelName("ПоискСпутников")
                                        end
                                        
                                        local finalChannel = (channelNum and channelNum > 0) and channelNum or 4
                                        ChatFrame_OpenChat("/" .. finalChannel .. " ", DEFAULT_CHAT_FRAME)
                                        
                                        -- Локальный буфер для передачи данных внутрь покадрового триггера
                                        local l_capturedQuestID = exactQuestID or 28113
                                        local l_capturedQuestText = questText or "Задание БП"
                                        local l_capturedRawQuest = exactRawQuest
                                        
                                        -- Запускаем покадровый триггер задержки, чтобы чат ElvUI успел получить фокус ввода
                                        local delayFrame = CreateFrame("Frame")
                                        local frameElapsed = 0
                                        delayFrame:SetScript("OnUpdate", function(self, elapsed)
                                            frameElapsed = frameElapsed + elapsed
                                            if frameElapsed >= 0.02 then
                                                self:SetScript("OnUpdate", nil) -- Выключаем таймер кадра
                                                
                                                local editBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() or LAST_ACTIVE_CHAT_EDIT_BOX or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
                                                if editBox then
                                                    editBox:Show()
                                                    editBox:SetFocus()
                                                    
                                                    -- Извлекаем чистое короткое название квеста из ОЗУ
                                                    local finalShortTitle = tostring(l_capturedQuestText)
                                                    if l_capturedRawQuest and l_capturedRawQuest.text and l_capturedRawQuest.text ~= "" then
                                                        finalShortTitle = tostring(l_capturedRawQuest.text)
                                                    end
                                                    
                                                    -- Выставляем скрытый тип задания БП Сируса (83)
                                                    local sirusTypeParam = 83
                                                    if l_capturedRawQuest and l_capturedRawQuest.type == 1 then 
                                                        sirusTypeParam = 82 
                                                    elseif string.find(string.lower(finalShortTitle), "ежедневное") then
                                                        sirusTypeParam = 82
                                                    end
                                                    
                                                    -- СБОРКА ОРИГИНАЛЬНОГО ХЭША: Родной оранжевый цвет БП, ведущий пробел (код 32) по дампу!
                                                    local colorHex = "ffff8040"
                                                    local officialSirusLink = string.format(" |c%s|Hquest:%d:%d|h[%s]|h|r", 
                                                        colorHex, tonumber(l_capturedQuestID) or 28113, sirusTypeParam, finalShortTitle)
                                                    
                                                    editBox:Insert(officialSirusLink .. " ")
                                                end
                                            end
                                        end)
                                        
                                    -- МЕХАНИКА Б: Обычный клик по названию со статусом "Завершено" открывает задания БП Сируса
                                    else
                                        if capturedRawQuest then
                                            local currentProgressText = tostring(capturedRawQuest.progress or "0/0")
                                            if currentProgressText == "Завершено" or currentProgressText == "Завершено!" then
                                                if ToggleBattlePassFrame then
                                                    pcall(ToggleBattlePassFrame)
                                                elseif BattlePassFrame and BattlePassFrame.Show then
                                                    if not BattlePassFrame:IsShown() then BattlePassFrame:Show() end
                                                end
                                                if BattlePassFrame and BattlePassFrameTopPanelQuestPageButton and BattlePassFrameTopPanelQuestPageButton.Click then
                                                    pcall(BattlePassFrameTopPanelQuestPageButton.Click, BattlePassFrameTopPanelQuestPageButton)
                                                end
                                            end
                                        end
                                    end
                                end)

                                if #charStrings > 0 then
                                    table.sort(charStrings)
                                    local blockLine = table.concat(charStrings, ", ")
                                    local cFs = AcquireFontString(child, "GameFontNormalSmall", nil, nil, nil, "LEFT", 410, 30, yOffset)
                                    cFs:SetText(blockLine)
                                    yOffset = yOffset - (cFs:GetStringHeight() + 5)
                                    table.insert(child.widgets, cFs)
                                end
                                yOffset = yOffset - 3

                            end
                        end
                    end
                    yOffset = yOffset - 12
                end
            end
        end

        if not hasAnyData then
            local emptyFs = AcquireFontString(child, "GameFontNormal", 0.7, 0.7, 0.7, "LEFT", 440, 10, yOffset)
            emptyFs:SetText("База данных пуста или совпадений не найдено.")
            yOffset = yOffset - (emptyFs:GetStringHeight() + 10)
            table.insert(child.widgets, emptyFs)
        end
        child:SetHeight(math.abs(yOffset) + 20)
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
    fGui:SetSize(450, 490)
    fGui:SetPoint("CENTER", 120, -40)
    fGui:SetFrameStrata("DIALOG")
    fGui:SetFrameLevel(mainGui and (mainGui:GetFrameLevel() + 5) or 10)
    
    fGui:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    fGui:SetBackdropColor(0.05, 0.05, 0.05, 1.0)
    fGui:SetBackdropBorderColor(0.5, 0.5, 0.5, 1.0)
    fGui:EnableMouse(true) fGui:SetMovable(true) fGui:RegisterForDrag("LeftButton")
    fGui:SetScript("OnDragStart", fGui.StartMoving) fGui:SetScript("OnDragStop", fGui.StopMovingOrSizing)
    tinsert(UISpecialFrames, "SirusBPFilterGUI")

    local title = fGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14) 
    title:SetText("Настройки")

    local closeBtn = CreateFrame("Button", nil, fGui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)

    -- Кнопка "Очистить БД" (Очищает и диск, и живое ОЗУ мгновенно)
--sbpt-v190: ВОССТАНОВЛЕНИЕ ФРЕЙМА КНОПКИ И АБСОЛЮТНОЕ ОБНУЛЕНИЕ БАЗ ДАННЫХ И ОЗУ БЕЗ ХВОСТОВ
    local clearAllBtn = CreateFrame("Button", "SirusBPClearAllBtn", fGui, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(95, 22)
    clearAllBtn:SetPoint("LEFT", title, "RIGHT", 15, -1)
    clearAllBtn:SetText("Очистить БД")
    clearAllBtn:RegisterForClicks("LeftButtonUp")
    clearAllBtn:SetScript("OnClick", function()
        -- Полностью уничтожаем все таблицы в файле WTF на жестком диске
        -- Полностью выжигаем оперативную память (ОЗУ-кэш) аддона
        ExecuteSBPTDatabaseMigration(true)
        -- Принудительно командуем интерфейсу перерисовать абсолютно пустые экраны
        if UpdateGUIText then UpdateGUIText() end
        if fGui.RefreshList then fGui.RefreshList() end
        
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SirusBP]|r Глобальная база данных, фильтры и ОЗУ полностью уничтожены! Аддон сброшен к первому запуску.")
    end)
-- Конец фикса фрейма кнопки очистки


    local sborTitle = fGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sborTitle:SetPoint("TOPLEFT", 16, -44)
    sborTitle:SetText("=== Сборы ===")

    local showLfgCb = CreateFrame("CheckButton", "SirusBPShowLfgCheckButton", fGui, "InterfaceOptionsCheckButtonTemplate")
    showLfgCb:SetPoint("TOPLEFT", 16, -62)
    
    local showLfgCbText = _G[showLfgCb:GetName() .. "Text"]
    if showLfgCbText then showLfgCbText:SetText("Только БП сборы") end
    
    if SirusBPTrackerConfig == nil then SirusBPTrackerConfig = {} end
    if SirusBPTrackerConfig.OnlyBpSbors == nil then SirusBPTrackerConfig.OnlyBpSbors = false end
    showLfgCb:SetChecked(SirusBPTrackerConfig.OnlyBpSbors)
    
    showLfgCb:SetScript("OnClick", function(self)
        SirusBPTrackerConfig.OnlyBpSbors = not not self:GetChecked()
        if UpdateGUIText then UpdateGUIText() end
    end)

    local fSearchBox = CreateFrame("EditBox", "SirusBPFilterSearchBox", fGui)
    fSearchBox:SetSize(120, 20)
    fSearchBox:SetPoint("TOPRIGHT", fGui, "TOPRIGHT", -35, -14)
    fSearchBox:SetAutoFocus(false)
    fSearchBox:SetFontObject("GameFontHighlightSmall")
    fSearchBox:SetTextInsets(6, 6, 0, 0)
    fSearchBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 12, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    fSearchBox:SetBackdropColor(0.01, 0.01, 0.01, 1.0)
    fSearchBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1.0)

    local fSearchPrompt = fSearchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fSearchPrompt:SetPoint("LEFT", fSearchBox, "LEFT", 6, 0)
    fSearchPrompt:SetText("Поиск...")
    
    fSearchBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then fSearchPrompt:Hide() else fSearchPrompt:Show() end
        if fGui.RefreshList then fGui.RefreshList() end
    end)
    fSearchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    fGui.searchBox = fSearchBox

    local scrollFrame = CreateFrame("ScrollFrame", "SirusBPFilterScrollFrame", fGui, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -92) scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(390, 1) scrollFrame:SetScrollChild(scrollChild)
    fGui.scrollChild = scrollChild
-- КОНЕЦ ВЕРХНЕЙ ЧАСТИ ОКНА НАСТРОЕК
    fGui.RefreshList = function()
        local child = fGui.scrollChild
        if child.widgets then
            for _, w in ipairs(child.widgets) do w:Hide() if w.SetChecked then w:SetScript("OnClick", nil) end end
        end
        child.widgets = {}

        local fSearchText = ""
        if SirusBPFilterSearchBox then
            fSearchText = string.lower(SirusBPFilterSearchBox:GetText() or "")
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

        if fSearchText == "" then
            AddHeader("=== Персонажи ===", 1, 0.82, 0)
            local sortedChars = {}
            for cName in pairs(uniqueCharacters) do table.insert(sortedChars, cName) end
            table.sort(sortedChars)

            for i, cName in ipairs(sortedChars) do
                if SirusBPTrackerCharFilterDB[cName] == nil then SirusBPTrackerCharFilterDB[cName] = true end
                local cbName = "SirusBPCharCB_" .. widgetIdx
                local cb = _G[cbName] or CreateFrame("CheckButton", cbName, child, "InterfaceOptionsCheckButtonTemplate")
                cb:SetParent(child) cb:ClearAllPoints() cb:SetPoint("TOPLEFT", 15, fyOffset) cb:Show()
                cb:SetChecked(SirusBPTrackerCharFilterDB[cName])
                cb:SetScript("OnClick", function(self)
                    SirusBPTrackerCharFilterDB[cName] = self:GetChecked() and true or false
                    if UpdateGUIText then UpdateGUIText() end
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
            fyOffset = fyOffset - 10
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
                AddHeader("=== " .. catName .. " ===", 0, 1, 1)
                
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
                    local dispName = qInfo.text
                    
                    if SirusBPTrackerFilterDB[qID] == nil then SirusBPTrackerFilterDB[qID] = true end
                    
                    local cbName = "SirusBPQuestCB_" .. widgetIdx
                    local cb = _G[cbName] or CreateFrame("CheckButton", cbName, child, "InterfaceOptionsCheckButtonTemplate")
                    cb:SetParent(child) cb:ClearAllPoints() cb:SetPoint("TOPLEFT", 15, fyOffset) cb:Show()
                    cb:SetChecked(SirusBPTrackerFilterDB[qID] ~= false)
                    
                    cb:SetScript("OnClick", function(self)
                        SirusBPTrackerFilterDB[qID] = self:GetChecked() and true or false
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

        child:SetHeight(math.abs(fyOffset) + 15)
    end
    fGui:SetScript("OnShow", fGui.RefreshList)
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
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    hGui:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    hGui:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    
    hGui:EnableMouse(true)
    hGui:SetMovable(true)
    hGui:RegisterForDrag("LeftButton")
    hGui:SetScript("OnDragStart", hGui.StartMoving)
    hGui:SetScript("OnDragStop", hGui.StopMovingOrSizing)
    tinsert(UISpecialFrames, "SirusBPHelpGUI")

    -- Заголовок окна
    local title = hGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Об аддоне SirusBPTracker")

    local closeBtn = CreateFrame("Button", nil, hGui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)

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

frame:SetScript("OnEvent", function(self, event, arg1, ...)
    -- РУБЕЖ 1: Срабатывает один раз при первоначальной загрузке SavedVariables с диска
    if event == "ADDON_LOADED" and arg1 == "SirusBPTracker" then
        if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
        if not SirusBPTrackerVersionDB then SirusBPTrackerVersionDB = {} end
        if not SirusBPTrackerFilterDB then SirusBPTrackerFilterDB = {} end
        if not SirusBPTrackerCharFilterDB then SirusBPTrackerCharFilterDB = {} end
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = { minimapPos = 45 } end
        
        -- Вызываем бесшумную проверку версии структуры ДО наполнения ОЗУ-кэша
        if ExecuteSBPTDatabaseMigration then
            ExecuteSBPTDatabaseMigration(false)
        end
        
        -- Копируем чистые данные из файла WTF в ОЗУ-кэш при загрузке аддона
        if SirusBPTrackerDB then
            for k, v in pairs(SirusBPTrackerDB) do
                if type(v) == "table" then
                    ramCacheDB[k] = {}
                    for charName, charData in pairs(v) do
                        if type(charData) == "table" then
                            ramCacheDB[k][charName] = {
                                name = charData.name,
                                class = charData.class,
                                quests = {}
                            }
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
        
    -- РУБЕЖ 2 (СТРАХОВОЧНЫЙ): Автоматически срабатывает при КАЖДОМ релоаде (/reload) и входе в мир
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 1. Контрольная бесшумная проверка версии структуры после загрузки мира
        if ExecuteSBPTDatabaseMigration then
            ExecuteSBPTDatabaseMigration(false)
        end
        
        -- 2. ИСПРАВЛЕНО: Принудительно запускаем тихий скан БП, чтобы мгновенно наполнить пустую базу квестами текущего чара!
        if ExecuteSilentBPScan then
            ExecuteSilentBPScan(true)
        end
        
        -- 3. Принудительно заставляем графический движок обновить текст на вкладках
        if UpdateGUIText then
            UpdateGUIText()
        end
		
    end
end)


--sbpt-v197: ОТКЛЮЧЕНИЕ СТАРОГО ГРАФИЧЕСКОГО ТАЙМЕРА ОБНОВЛЕНИЯ СКРАПЕРА ОКНА СИРУСА
--[[
local tickerFrame = CreateFrame("Frame")
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
    self.timer = (self.timer or 0) + elapsed
    if self.timer > 0.4 then
        self.timer = 0
        if BattlePassFrame and BattlePassFrame:IsShown() then 
            local updated = DirectScanBattlePass()
            if updated and mainGui and mainGui:IsShown() then UpdateGUIText() end
        end
    end
end)
]]
-- Конец комментирования старого таймера

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

function ExecuteSilentBPScan(force) 
    if not C_BattlePass then 
        print("|cffff0000[SBPT-MEM-DEBUG] Критическая ошибка: C_BattlePass отсутствует!|r")
        return 
    end
    
    if C_BattlePass.RequestQuests then C_BattlePass.RequestQuests() end

    local pName = UnitName("player")
    local pRealm = GetRealmName()
    
    -- ЗАПИСЬ В ОЗУ: Работаем строго внутри локальной RAM-таблицы без нагрузки на жесткий диск
    if not ramCacheDB[pRealm] then ramCacheDB[pRealm] = {} end
    if not ramCacheDB[pRealm][pName] then ramCacheDB[pRealm][pName] = {} end
    
    local charData = ramCacheDB[pRealm][pName]
    charData.name = pName
    local _, classEng = UnitClass("player")
    if classEng then charData.class = classEng end
    charData.quests = {}

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
            DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[SirusBP]|r Обнаружено обновление структуры аддона до версии 1.1! Старая база данных и сборы чата автоматически очищены для стабильной работы.")
        end

        -- 1. ТОТАЛЬНЫЙ СБРОС: Пересоздаем дисковые таблицы как абсолютно чистые пустые структуры
        SirusBPTrackerDB = {}
        SirusBPTrackerFilterDB = {}
        SirusBPTrackerCharFilterDB = {}
        
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

