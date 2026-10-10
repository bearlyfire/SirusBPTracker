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
--]]

--[[ старая функция получения данных
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
--]]
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
	--sbpt-v466: РЕГИСТРАЦИЯ ГЛАВНОГО ОКНА АДДОНА В СИСТЕМЕ ВСПЛЫВАЮЩИХ ОКOН ДЛЯ ЗАКРЫТИЯ ПО ESC
    tinsert(UISpecialFrames, "SirusBPTrackerMainFrame")

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
--sbpt-v286: СКРЫТИЕ КАСТОМНОЙ КНОПКИ БП ДЛЯ ПЕРСОНАЖЕЙ НИЖЕ 80 УРОВНЯ
    local sirusBpOpenBtn = CreateFrame("Button", "SirusBPOpenNativeBtn", gui, "UIPanelButtonTemplate")
    sirusBpOpenBtn:SetSize(32, 20)
    sirusBpOpenBtn:SetPoint("RIGHT", helpBtn, "LEFT", -5, 0) -- Садится ровно левее золотого знака "?"
    sirusBpOpenBtn:SetText("БП")
    
    if sirusBpOpenBtn.Text then
        sirusBpOpenBtn.Text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    elseif _G[sirusBpOpenBtn:GetName() .. "Text"] then
        _G[sirusBpOpenBtn:GetName() .. "Text"]:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    end

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
--[[ бэкап рабочей версии вкладок
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
]]

--sbpt-v293: МОДЕРНИЗАЦИЯ СИСТЕМЫ ВКЛАДОК: ДОБАВЛЕНИЕ ТРЕТЬЕЙ ВКЛАДКИ "АКТИВНОСТИ" И НОВОГО ХОЛСТА
    -- Инициализируем новый глобальный скролл-фрейм для холста активностей, если он еще не создан
    if not activitiesScrollFrame then
        activitiesScrollFrame = CreateFrame("ScrollFrame", "SirusBPActivitiesScrollFrame", gui, "UIPanelScrollFrameTemplate")
        activitiesScrollFrame:SetSize(gui:GetWidth() - 40, gui:GetHeight() - 95)
        activitiesScrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 15, -75)
        activitiesScrollFrame:Hide() -- По умолчанию скрыт
        
        local child = CreateFrame("Frame", nil, activitiesScrollFrame)
        child:SetSize(activitiesScrollFrame:GetWidth(), 1)
        activitiesScrollFrame:SetScrollChild(child)
        activitiesScrollFrame.child = child
    end

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
            if tID == id then
                -- АКТИВНАЯ ВКЛАДКА: Стильный темно-синий цвет
                btn:SetBackdropColor(0.12, 0.22, 0.34, 0.95)
                btn:SetBackdropBorderColor(0, 0.6, 0.9, 1) -- Голубое неоновое свечение
                btn.text:SetTextColor(1, 0.82, 0) -- Золотистый яркий текст
            else
                -- НЕАКТИВНАЯ ВКЛАДКА: Прозрачно-угольный цвет в тон главного фрейма
                btn:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
                btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) -- Тусклая серая рамка
                btn.text:SetTextColor(0.5, 0.5, 0.5) -- Приглушенный серый текст
            end
        end
        if UpdateGUIText then UpdateGUIText() end
        if DrawActivitiesTab then DrawActivitiesTab() end -- Будущий вызов отрисовки таблицы активностей
    end

    -- РАСШИРЯЕМ МАССИВ НАИМЕНОВАНИЙ ВКЛАДОК ДО ТРЕХ
    --sbpt-v448 [ЭТАП 1]: ИСПРАВЛЕНИЕ НЕОНОВОГО ХОВЕРА И СОЗДАНИЕ ВТОРОГО РЯДА СУБ-ВКЛАДОК БП
    -- РАСШИРЯЕМ МАССИВ НАИМЕНОВАНИЙ ВКЛАДКИ ДО ТРЕХ
    local tabNames = { "Квесты персонажей", "Актуальные сборы", "Активности" }
    for i = 1, 3 do
        local tab = CreateFrame("Button", nil, gui)
        tab:SetSize(140, 22)
        tab:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 10, edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        
        if i == 1 then
            tab:SetPoint("TOPLEFT", gui, "TOPLEFT", 15, -45)
        else
            tab:SetPoint("LEFT", gui.myTabs[i-1], "RIGHT", 5, 0)
        end

        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.text:SetPoint("CENTER", 0, 0)
        tab.text:SetText(tabNames[i])

        -- ИСПРАВЛЕНО: Полностью восстановлено красивое неоново-синее свечение при наведении мыши!
        tab:SetScript("OnEnter", function(self)
            if SirusBPTrackerConfig.ActiveTab ~= i then
                self:SetBackdropColor(0.08, 0.15, 0.25, 0.9) -- Мягкий синеватый фон
                self:SetBackdropBorderColor(0, 0.6, 0.9, 1)  -- Голубое неоновое свечение границ
                self.text:SetTextColor(0.9, 0.9, 0.9)
            end
        end)
        tab:SetScript("OnLeave", function(self)
            if SirusBPTrackerConfig.ActiveTab ~= i then
                self:SetBackdropColor(0.05, 0.05, 0.05, 0.85)
                self.text:SetTextColor(0.5, 0.5, 0.5)
                self:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) -- Возвращаем тусклую серую рамку
            end
        end)

        tab:SetScript("OnClick", function() SwitchTab(i) end)
        gui.myTabs[i] = tab
    end

    -- СОЗДАЕМ ВТОРОЙ РЯД СУБ-ВКЛАДОК ДЛЯ ПЕРВОЙ ВКЛАДКИ (Все / Ежедневные / Сезонные)
    gui.mySubTabs = {}
    
    local function SwitchSubTab(subID)
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
        SirusBPTrackerConfig.ActiveSubTab = subID
        
        -- Управляем цветами и неоновым свечением суб-вкладок БП
        for sID, sBtn in ipairs(gui.mySubTabs) do
            if sID == subID then
                --sBtn:SetBackdropColor(0.12, 0.22, 0.34, 0.95)
                --sBtn:SetBackdropBorderColor(0, 0.6, 0.9, 1) -- Синий неон на активной суб-вкладке
                --sBtn.text:SetTextColor(1, 0.82, 0)
				-- АКТИВНАЯ СУБ-ВКЛАДКА: Стильный изумрудно-матовый цвет
                sBtn:SetBackdropColor(0.08, 0.24, 0.14, 0.95)
                sBtn:SetBackdropBorderColor(0, 0.8, 0.4, 1) -- Зеленое неоновое свечение границ
                sBtn.text:SetTextColor(0, 1, 0.5) -- Сочный салатовый текст
            else
                sBtn:SetBackdropColor(0.03, 0.03, 0.03, 0.85)
                sBtn:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
                sBtn.text:SetTextColor(0.45, 0.45, 0.45)
            end
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
            if sID == subID then
                -- АКТИВНАЯ СУБ-ВКЛАДКА: Приглушенный серо-синий джинсовый тон
                sBtn:SetBackdropColor(0.15, 0.20, 0.28, 0.95)
                sBtn:SetBackdropBorderColor(0.3, 0.5, 0.7, 0.8) -- Мягкая стальная рамка
                sBtn.text:SetTextColor(1, 0.82, 0) -- Классический золотой текст
            else
                -- НЕАКТИВНАЯ СУБ-ВКЛАДКА: Прозрачно-угольный тон в цвет главного фрейма
                sBtn:SetBackdropColor(0.04, 0.04, 0.04, 0.85)
                sBtn:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)
                sBtn.text:SetTextColor(0.45, 0.45, 0.45)
            end
        end
        if UpdateGUIText then UpdateGUIText() end
    end
    gui.SwitchSubTab = SwitchSubTab

    local subTabNames = { "Все задания", "Ежедневные", "Сезонные" }
    for i = 1, 3 do
        local subTab = CreateFrame("Button", nil, gui)
        subTab:SetSize(140, 20)
        subTab:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        
        if i == 1 then
            subTab:SetPoint("TOPLEFT", gui, "TOPLEFT", 15, -70)
        else
            subTab:SetPoint("LEFT", gui.mySubTabs[i-1], "RIGHT", 5, 0)
        end

        subTab.text = subTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        subTab.text:SetPoint("CENTER", 0, 0)
        subTab.text:SetText(subTabNames[i])

        -- МЯГКИЙ ХОВЕР ПРИ НАВЕДЕНИИ МЫШИ (БЕЗ ЯРКОГО СВЕЧЕНИЯ)
        subTab:SetScript("OnEnter", function(self)
            if SirusBPTrackerConfig.ActiveSubTab ~= i then
                self:SetBackdropColor(0.10, 0.14, 0.20, 0.9)
                self:SetBackdropBorderColor(0.25, 0.4, 0.55, 0.8)
                self.text:SetTextColor(0.75, 0.75, 0.75)
            end
        end)
        subTab:SetScript("OnLeave", function(self)
            if SirusBPTrackerConfig.ActiveSubTab ~= i then
                self:SetBackdropColor(0.03, 0.03, 0.03, 0.85)
                self.text:SetTextColor(0.45, 0.45, 0.45)
                self:SetBackdropBorderColor(0.15, 0.15, 0.15, 1)
            end
        end)

        subTab:SetScript("OnClick", function() SwitchSubTab(i) end)
        gui.mySubTabs[i] = subTab
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
            if scrollFrame then scrollFrame:SetPoint("TOPLEFT", gui, "TOPLEFT", 12, -96) end
        else
            -- Если ушли на Сборы или Активности - намертво гасим суб-вкладки с экрана
            for _, sBtn in ipairs(gui.mySubTabs) do sBtn:Hide() end
        end
    end

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
--[[ -- бэкап функции шрифтов
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
--]]

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
                        local catFs = AcquireFontString(child, "GameFontNormalLarge", 0, 1, 1, "LEFT", 420, 10, yOffset)
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
                        for questText, characters in pairs(questList) do
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
                                    tempFs:SetWidth(child:GetWidth() - 25)
                                    tempFs:SetText("• " .. questText)
                                    local questTextHeight = math.floor(tempFs:GetStringHeight() + 0.5)
                                    tempFs:Hide()
                                    
                                    local numChars = #characters
                                    local numRows = math.ceil(numChars / 2)
                                    local rowFrameHeight = questTextHeight + 12 + (numRows * 15)
                                    
                                    local row = CreateFrame("Frame", nil, child)
                                    row:SetSize(child:GetWidth() - 10, rowFrameHeight)
                                    row:SetPoint("TOPLEFT", child, "TOPLEFT", 5, yOffset)
                                    table.insert(child.widgets, row)
                                    
                                    local qFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                                    qFs:SetPoint("TOPLEFT", row, "TOPLEFT", 15, -2)
                                    qFs:SetWidth(child:GetWidth() - 35)
                                    qFs:SetJustifyH("LEFT")
                                    qFs:SetText("• " .. questText)
                                    qFs:SetTextColor(1, 0.82, 0, 1)
                                    
                                    local questClickBtn = CreateFrame("Button", nil, row)
                                    questClickBtn:SetPoint("TOPLEFT", qFs, "TOPLEFT", -5, 2)
                                    questClickBtn:SetPoint("BOTTOMRIGHT", qFs, "BOTTOMRIGHT", 5, -2)
                                    questClickBtn:RegisterForClicks("LeftButtonUp")
                                    
                                    questClickBtn:SetScript("OnEnter", function() qFs:SetTextColor(0, 0.7, 1, 1) end)
                                    questClickBtn:SetScript("OnLeave", function() qFs:SetTextColor(1, 0.82, 0, 1) end)
                                    table.insert(child.widgets, questClickBtn)
                                    
                                    table.sort(characters, function(a, b) return a.name < b.name end)
                                    
                                    local charYOffset = -(questTextHeight + 6)
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
                                        
                                        -- ИДЕАЛЬНО ЗЕРКАЛЬНАЯ СЕТКА: Поля по 15 пикселей с обоих краев
                                        local isEven = (charIdx % 2 == 0)
                                        local charXOffset = isEven and 235 or 15
                                        local barXOffset = isEven and 355 or 135
                                        
                                        local charFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                                        charFs:SetPoint("TOPLEFT", row, "TOPLEFT", charXOffset, charYOffset)
                                        charFs:SetWidth(95)
                                        charFs:SetJustifyH("LEFT")
                                        charFs:SetText(string.format(" |cff%s%s|r", hexColor, char.name))
                                        table.insert(child.widgets, charFs)
--sbpt-v461 [ФРАГМЕНТ 2 ИЗ 2]: ЦЕНТРОВКА ЦИФР, КРУПНЫЙ ТЕКСТ ЗАВЕРШЕНО И ФИНАЛИЗАЦИЯ ВКЛАДКИ 1
                                        if currentProgressText == "Завершено" or currentProgressText == "Завершено!" or curProgress >= maxProgress then
                                            local doneContainer = CreateFrame("Frame", nil, row)
                                            doneContainer:SetSize(80, 11)
                                            doneContainer:SetPoint("TOPLEFT", row, "TOPLEFT", barXOffset, charYOffset - 1)
                                            
                                            local doneFs = doneContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                                            doneFs:SetPoint("CENTER", doneContainer, "CENTER", 0, -1)
                                            doneFs:SetTextColor(0, 1, 0)
                                            doneFs:SetText("Завершено")
                                            
                                            table.insert(child.widgets, doneContainer)
                                            table.insert(child.widgets, doneFs)
                                        else
                                            local bar = CreateFrame("StatusBar", nil, row)
                                            bar:SetSize(80, 11)
                                            bar:SetPoint("TOPLEFT", row, "TOPLEFT", barXOffset, charYOffset - 1)
                                            bar:SetMinMaxValues(0, maxProgress)
                                            bar:SetValue(curProgress)
                                            
                                            local barBG = bar:CreateTexture(nil, "BACKGROUND")
                                            barBG:SetAllPoints(bar)
                                            barBG:SetTexture("Interface\\Buttons\\WHITE8X8")
                                            barBG:SetVertexColor(0.08, 0.08, 0.08, 0.9)
                                            
                                            local barTex = bar:CreateTexture(nil, "ARTWORK")
                                            barTex:SetTexture("Interface\\Buttons\\WHITE8X8")
                                            barTex:SetVertexColor(0.0, 0.5, 0.6, 0.75)
                                            bar:SetStatusBarTexture(barTex)
                                            
											--[[
                                            local barText = bar:CreateFontString(nil, "OVERLAY")
                                            barText:SetFont("Fonts\\FRIZQT__.TTF", 9.5, "THICKOUTLINE")
                                            --]]
											--sbpt-v465: ПОЛНАЯ ИЗОЛЯЦИЯ ШРИФТА ЦИФР БАРА ДЛЯ ИСКЛЮЧЕНИЯ УМЕНЬШЕНИЯ ЧАТА ELVUI
                                            -- Передаем явный шаблон "GameFontHighlightSmall" вместо nil для приватности фрейма
                                            local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                                            barText:SetFont("Fonts\\FRIZQT__.TTF", 9.5, "THICKOUTLINE")

											barText:SetPoint("CENTER", bar, "CENTER", 0, -2)
                                            barText:SetTextColor(1, 1, 1)
                                            barText:SetText(currentProgressText)
                                            
                                            table.insert(child.widgets, bar)
                                        end
                                        
                                        if isEven then
                                            charYOffset = charYOffset - 15
                                        end
                                    end
                                    
                                    if numChars % 2 ~= 0 then
                                        charYOffset = charYOffset - 15
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
                                        ChatFrame_OpenChat("/" .. finalChannel .. " ", DEFAULT_CHAT_FRAME)
                                        
                                        local l_capturedQuestID = exactQuestID or 28113
                                        local l_capturedQuestText = questText or "Задание БП"
                                        
                                        local delayFrame = CreateFrame("Frame")
                                        local frameElapsed = 0
                                        delayFrame:SetScript("OnUpdate", function(self, elapsed)
                                            frameElapsed = frameElapsed + elapsed
                                            if frameElapsed >= 0.02 then
                                                self:SetScript("OnUpdate", nil)
                                                
                                                local editBox = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() or LAST_ACTIVE_CHAT_EDIT_BOX or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
                                                if editBox then
                                                    editBox:Show()
                                                    editBox:SetFocus()
                                                    
                                                    local finalShortTitle = tostring(l_capturedQuestText)
                                                    local sirusTypeParam = 83
                                                    if string.find(string.lower(finalShortTitle), "ежедневное") then 
                                                        sirusTypeParam = 82 
                                                    end
                                                    
                                                    -- ВОССТАНОВЛЕНО: Побайтово точный оригинальный хэш Сируса с ведущим пробелом
                                                    local colorHex = "ffff8040"
                                                    local officialSirusLink = string.format(" |c%s|Hquest:%d:%d|h[%s]|h|r", 
                                                        colorHex, tonumber(l_capturedQuestID) or 28113, sirusTypeParam, finalShortTitle)
                                                    
                                                    editBox:Insert(officialSirusLink .. " ")
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
            local emptyFs = AcquireFontString(child, "GameFontNormal", 0.7, 0.7, 0.7, "LEFT", 440, 10, yOffset)
            emptyFs:SetText("База данных пуста или совпадений не найдено.")
            yOffset = yOffset - (emptyFs:GetStringHeight() + 10)
            table.insert(child.widgets, emptyFs)
        end
        child:SetHeight(math.abs(yOffset) + 20)
    end

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


--[[ бэкап обрабочика событий
--sbpt-v298: ИСПРАВЛЕННЫЙ ОБРАБОТЧИК СОБЫТИЙ С ПОДДЕРЖКОЙ КЭША АКТИВНОСТЕЙ И ЖИВЫМ ТРИГГЕРОМ СДАЧИ КВЕСТОВ
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
                                quests = {},
                                activities = {} -- ИСПРАВЛЕНО: Создаем пустой ОЗУ-путь для активностей твинка
                            }
                            -- ГЛУБОКОЕ КОПИРОВАНИЕ АКТИВНОСТЕЙ: Переносим сохраненные КД (Монеты/Охоту) с диска в ОЗУ
                            if charData.activities then
                                for actKey, actData in pairs(charData.activities) do
                                    ramCacheDB[k][charName].activities[actKey] = {
                                        status = actData.status,
                                        lastCheck = actData.lastCheck
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
        
    -- РУБЕЖ 2 (СТРАХОВОЧНЫЙ): Автоматически срабатывает при КАЖДОМ релоаде (/reload) и входе в мир
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 1. Контрольная бесшумная проверка версии структуры после загрузки мира
        if ExecuteSBPTDatabaseMigration then
            ExecuteSBPTDatabaseMigration(false)
        end
        
        -- 2. Принудительно запускаем тихий скан БП, чтобы мгновенно наполнить пустую базу квестами текущего чара
        if ExecuteSilentBPScan then
            ExecuteSilentBPScan(true)
        end
        
        -- 3. Принудительно заставляем графический движок обновить текст на вкладках
        if UpdateGUIText then
            UpdateGUIText()
        end
        
        -- 4. Вызываем наш центральный изолированный сканер активностей
        if UpdateCurrentCharacterActivities then
            UpdateCurrentCharacterActivities()
        end		

    -- РУБЕЖ 3 (ЖИВОЙ): Мгновенно перехватывает момент нажатия кнопки "Завершить" у НИП
    elseif event == "QUEST_TURNED_IN" then
        -- Срочно обновляем базу данных активностей в памяти
        if UpdateCurrentCharacterActivities then 
            UpdateCurrentCharacterActivities() 
        end
        -- Если игрок прямо сейчас сидит на Вкладке 3, мгновенно перерисовываем иконки на живые
        if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
            DrawActivitiesTab()
        end
    end
	
end)

-]] --конец бэкапа обрабочика событий

-- новый обрабочик событий

frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == "SirusBPTracker" then
        if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
        if not SirusBPTrackerVersionDB then SirusBPTrackerVersionDB = {} end
        if not SirusBPTrackerFilterDB then SirusBPTrackerFilterDB = {} end
        if not SirusBPTrackerCharFilterDB then SirusBPTrackerCharFilterDB = {} end
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = { minimapPos = 45 } end
        
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
                                quests = {},
                                activities = {}
                            }
                            if charData.activities then
                                for actKey, actData in pairs(charData.activities) do
                                    ramCacheDB[k][charName].activities[actKey] = {
                                        status = actData.status,
                                        lastCheck = actData.lastCheck
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
        if UpdateCurrentCharacterActivities then UpdateCurrentCharacterActivities() end
        
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
            DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[SirusBP]|r Обнаружено обновление структуры аддона! Старая база данных и сборы чата автоматически очищены для стабильной работы.")
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

--============== блок v1.1 конец

--[[ бэкап задвоения
--sbpt-v309: МОНОЛИТ ТОТАЛЬНОЙ ДИАГНОСТИКИ С ЗАЩИТОЙ ОТ NIL-ПАДЕНИЙ И БРОНЕБОЙНЫМ ЛОГИРОВАНИЕМ
local currentRealm = GetRealmName() or "Unknown"

function UpdateCurrentCharacterActivities(turnedInQuestID)
    local charName = UnitName("player") or "Unknown"
    if charName == "Unknown" then 
        DEFAULT_CHAT_FRAME:AddMessage("|cffff2020[SirusBP-Лог]|r Критическая ошибка: Имя персонажа не определено!")
        return 
    end
    
    -- 1. ПОШАГОВАЯ ИЗОЛИРОВАННАЯ ИНИЦИАЛИЗАЦИЯ (Исключаем любые nil-ошибки индексации)
    if not ramCacheDB then ramCacheDB = {} end
    if not ramCacheDB[currentRealm] then ramCacheDB[currentRealm] = {} end
    if not ramCacheDB[currentRealm][charName] then ramCacheDB[currentRealm][charName] = {} end
    if not ramCacheDB[currentRealm][charName].activities then ramCacheDB[currentRealm][charName].activities = {} end
    
    if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
    if not SirusBPTrackerDB[currentRealm] then SirusBPTrackerDB[currentRealm] = {} end
    if not SirusBPTrackerDB[currentRealm][charName] then SirusBPTrackerDB[currentRealm][charName] = {} end
    if not SirusBPTrackerDB[currentRealm][charName].activities then SirusBPTrackerDB[currentRealm][charName].activities = {} end
     
    -- Вытаскиваем массив сданных квестов Сируса
    local completedQuests = {}
    local getQuestsSuccess, getQuestsErr = pcall(function() GetQuestsCompleted(completedQuests) end)
    if not getQuestsSuccess then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff2020[SirusBP-Лог]|r Сбой нативной функции GetQuestsCompleted: " .. tostring(getQuestsErr))
    end
    
    local activityTargets = {
        ["KELDANAS_COIN"] = 11548, 
        ["WEEKLY_HUNT"]  = 1015000, 
        ["NORIGORN"]     = 22372,   
    }
    
    local currentTimeStamp = time()
    
    for key, qID in pairs(activityTargets) do
        local currentStatus = 0
        local reason = "Не найден ни в сданных, ни в журнале (Сброшен/Отменен)"
        
        -- Проверка А: Пойман ли живой перехват нажатия кнопки "Завершить"
        if turnedInQuestID and tonumber(turnedInQuestID) == qID then
            currentStatus = 1
            reason = "Мгновенный живой перехват события QUEST_TURNED_IN!"
            
        -- Проверка Б: Нативный серверный флаг Сируса
        elseif IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(qID) then
            currentStatus = 1
            reason = "Сервер Сируса вернул TRUE через IsQuestFlaggedCompleted"
            
        -- Проверка В: Массив сданных квестов (Проверяем числовой и строковый типы)
        elseif completedQuests and (completedQuests[qID] or completedQuests[tostring(qID)]) then
            currentStatus = 1
            reason = "Квест обнаружен в кэш-таблице GetQuestsCompleted"
            
        else
            -- Проверка Г: Сканируем живой журнал заданий персонажа
            local numEntries = GetNumQuestLogEntries() or 0
            for i = 1, numEntries do
                local title, _, _, _, _, _, _, questID = GetQuestLogTitle(i)
                local logLink = GetQuestLink(i)
                
                -- Бронебойный перекрестный поиск ID квеста в журнале WotLK
                if (questID and questID == qID) or (logLink and string.find(logLink, tostring(qID))) then
                    currentStatus = 2
                    reason = string.format("Задание висит в журнале под именем '%s' (Статус: В процессе)", tostring(title or key))
                    break
                end
            end
        end
             
        -- Безопасная точечная фиксация в ОЗУ
        ramCacheDB[currentRealm][charName].activities[key].status = currentStatus
        ramCacheDB[currentRealm][charName].activities[key].lastCheck = currentTimeStamp
        
        -- Безопасная точечная фиксация на жесткий диск WTF
        SirusBPTrackerDB[currentRealm][charName].activities[key].status = currentStatus
        SirusBPTrackerDB[currentRealm][charName].activities[key].lastCheck = currentTimeStamp
    end
end


function GetSmartActivityStatus(realm, char, activityKey)
    -- Жестко проверяем существование веток, чтобы вместо ошибок выводить прочерки
    if not ramCacheDB or not ramCacheDB[realm] or not ramCacheDB[realm][char] then return -1 end
    if not ramCacheDB[realm][char].activities or not ramCacheDB[realm][char].activities[activityKey] then return -1 end
    
    local data = ramCacheDB[realm][char].activities[activityKey]
    local savedStatus = data.status or 0
    local lastCheck = data.lastCheck or 0
    
    if savedStatus == 0 then return 0 end
    local currentTime = time()
    
    if activityKey == "KELDANAS_COIN" then
        local dateTable = date("*t", currentTime)
        dateTable.hour = 3; dateTable.min = 0; dateTable.sec = 0
        local serverResetTime = time(dateTable)
        if currentTime < serverResetTime then serverResetTime = serverResetTime - 86400 end
        if lastCheck < serverResetTime then return 0 end
    else
        local dateTable = date("*t", currentTime)
        local daysSinceThursday = dateTable.wday - 5
        if daysSinceThursday < 0 then daysSinceThursday = daysSinceThursday + 7 end
        dateTable.hour = 3; dateTable.min = 0; dateTable.sec = 0
        local thursdayResetTime = time(dateTable) - (daysSinceThursday * 86400)
        
        if dateTable.wday == 5 and currentTime < thursdayResetTime then
            thursdayResetTime = thursdayResetTime - (7 * 86400)
        end
        if lastCheck < thursdayResetTime then return 0 end
    end
    
    return savedStatus
end

if not sbptActivityTimerFrame then
    sbptActivityTimerFrame = CreateFrame("Frame")
end
local timeSinceLastUpdate = 0
sbptActivityTimerFrame:SetScript("OnUpdate", function(self, elapsed)
    timeSinceLastUpdate = timeSinceLastUpdate + elapsed
    if timeSinceLastUpdate >= 60 then
        timeSinceLastUpdate = 0
        if UpdateCurrentCharacterActivities then UpdateCurrentCharacterActivities() end
        if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
            DrawActivitiesTab()
        end
    end
end)
--]] --бэкап задвоения


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

--[[ Бэкап отрисовки 3 вкладки
--sbpt-v295: ОБНОВЛЕННЫЙ ГРАФИЧЕСКИЙ ДВИЖОК ВКЛАДКИ С ТЕКСТОВОЙ ШАПКОЙ И НОВЫМ ПОРЯДКОМ КОЛОНОК
local activityRowsPool = {} -- Пул для хранения графических строк твинков
local activitiesHeaderFrame = nil -- Фрейм текстовой шапки таблицы

function DrawActivitiesTab()
    if not activitiesScrollFrame or not activitiesScrollFrame:IsShown() then return end
    local child = activitiesScrollFrame.child
    if not child then return end
    
    -- 1. ТОТАЛЬНАЯ ОЧИСТКА: Удаляем старые строки, чтобы избежать наслоения при перерисовках
    for _, row in ipairs(activityRowsPool) do
        row:Hide()
        row:SetParent(nil)
    end
    activityRowsPool = {}
    
    -- Удаляем старую шапку, если она была создана ранее, для корректного обновления координат
    if activitiesHeaderFrame then
        activitiesHeaderFrame:Hide()
        activitiesHeaderFrame:SetParent(nil)
        activitiesHeaderFrame = nil
    end
    
    local currentRealm = GetRealmName() or "Unknown"
    
    -- СБОР И СОРТИРОВКА ПЕРСОНАЖЕЙ ТЕКУЩЕГО РЕАЛМА
    local sortedChars = {}
    if ramCacheDB and ramCacheDB[currentRealm] then
        for charName, charData in pairs(ramCacheDB[currentRealm]) do
            if type(charData) == "table" and charName ~= "QUEST_LFG" and charName ~= "Version" then
                table.insert(sortedChars, {
                    name = charName,
                    class = charData.class or "UNKNOWN"
                })
            end
        end
    end
    table.sort(sortedChars, function(a, b) return a.name < b.name end)
    
    -- 2. ИЗМЕНЕН ПОРЯДОК КОЛОНОК: Монета -> Охота -> Норигорн
    local activityConfig = {
        { key = "KELDANAS_COIN", texture = "Interface\\Icons\\INV_Misc_Coin_01",         name = "Монеты Анахорета (Кель'Данас)", desc = "Ежедневное пожертвование золота. Обновление каждые сутки в 03:00 МСК." },
        { key = "WEEKLY_HUNT",  texture = "Interface\\Icons\\INV_Weapon_Bow_05",         name = "Охота на великих чудовищ",  desc = "Еженедельное задание Лили в Даларане. Обновление в четверг в 03:00 МСК." },
        { key = "NORIGORN",     texture = "Interface\\Icons\\INV_Misc_MonsterHead_01",    name = "Норигорн (Обуздать твердыню)", desc = "Еженедельное задание на Тол'Гароде. Обновление в четверг в 03:00 МСК." },
    }
    
    -- ХАРДКОДНЫЕ КООРДИНАТЫ ДЛЯ ИДЕАЛЬНОГО ВЫРАВНИВАНИЯ ШАПКИ И ИКОНОК ПО ВЕРТИКАЛИ
    local startXOffset = 220
    local stepXOffset = 65 -- Увеличили шаг до 65 пикселей, чтобы текст шапки не слипался
    
    -- 3. СОЗДАНИЕ СТАТИЧЕСКОЙ ТЕКСТОВОЙ ШАПКИ ТАБЛИЦЫ
    activitiesHeaderFrame = CreateFrame("Frame", nil, child)
    activitiesHeaderFrame:SetSize(child:GetWidth() - 10, 20)
    activitiesHeaderFrame:SetPoint("TOPLEFT", child, "TOPLEFT", 5, -5)
    
	-- тестовя кнопка
	--sbpt-v308: ВРЕМЕННАЯ КНОПКА РУЧНОГО ВЫЗОВА ОБНОВЛЕНИЯ ДАННЫХ И ПЕРЕРИСОВКИ ХОЛСТА
    local refreshActBtn = CreateFrame("Button", "SirusBPRefreshActivitiesBtn", activitiesHeaderFrame, "UIPanelButtonTemplate")
    refreshActBtn:SetSize(110, 20)
    -- Сажаем кнопку аккуратно в правый верхний угол холста Вкладки 3
    refreshActBtn:SetPoint("TOPRIGHT", activitiesHeaderFrame, "TOPRIGHT", -20, 0)
    refreshActBtn:SetText("Обновить данные")
    refreshActBtn:SetScript("OnClick", function()
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8040[SirusBP-Лог]|r Нажата ручная кнопка 'Обновить данные'. Запуск сканирования...")
        if UpdateCurrentCharacterActivities then 
            UpdateCurrentCharacterActivities() 
        end
        if DrawActivitiesTab then 
            DrawActivitiesTab() 
        end
    end)

	
    -- Заголовок первой колонки персонажей
    local hTitle = activitiesHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hTitle:SetPoint("LEFT", activitiesHeaderFrame, "LEFT", 10, 0)
    hTitle:SetText("Персонажи")
    hTitle:SetTextColor(1, 0.82, 0) -- Красивый золотой цвет
    
    -- Отрисовка текстовых подписей над колонками активностей по сетке координат
    local headerTextMap = { "Монета", "Охота", "Норигорн" }
    local xHeaderOffset = startXOffset
    for i, label in ipairs(headerTextMap) do
        local hLabel = activitiesHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        -- Выравниваем текст строго по центру будущей пиктограммы
        hLabel:SetPoint("CENTER", activitiesHeaderFrame, "LEFT", xHeaderOffset + 10, 0)
        hLabel:SetText(label)
        hLabel:SetTextColor(0.7, 0.7, 0.7) -- Приглушенный серый цвет шапки
        xHeaderOffset = xHeaderOffset + stepXOffset
    end
    
    -- 4. ЦИКЛ ОТРИСОВКИ СТРОК ТВИНКОВ (Смещаем старт вниз на -30 пикселей из-за шапки)
    local yOffset = -32
    local rowHeight = 26
    
    for idx, charInfo in ipairs(sortedChars) do
        local row = CreateFrame("Frame", nil, child)
        row:SetSize(child:GetWidth() - 10, rowHeight)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 5, yOffset)
        
        -- Никнейм персонажа
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT", row, "LEFT", 10, 0)
        nameText:SetText(charInfo.name)
        
        -- Раскраска ника в цвет класса персонажа
        local classColor = RAID_CLASS_COLORS[charInfo.class]
        if classColor then
            nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            nameText:SetTextColor(1, 1, 1)
        end
        
        -- 5. ВЫВОД ДИНАМИЧЕСКИХ ПИКТОГРАММ СТРОГО ПО КООРДИНАТАМ ШАПКИ
        local xOffset = startXOffset
        
        for _, act in ipairs(activityConfig) do
            local actBtn = CreateFrame("Button", nil, row)
            actBtn:SetSize(20, 20)
            actBtn:SetPoint("LEFT", row, "LEFT", xOffset, 0)
            
            local tex = actBtn:CreateTexture(nil, "BACKGROUND")
            tex:SetAllPoints(actBtn)
            tex:SetTexture(act.texture)
            actBtn.texture = tex
            
            -- Вызов кросс-валидации серверного времени сброса (03:00 ночи МСК)
                       -- ВЫЗЫВАЕМ НАШУ УМНУЮ ПРОВЕРКУ ВРЕМЕНИ ДЛЯ НЕАКТИВНЫХ ТВИНКОВ
            local currentStatus = -1 -- -1 означает "Данных нет совсем"
            if ramCacheDB and ramCacheDB[currentRealm] and ramCacheDB[currentRealm][charInfo.name] then
                local charData = ramCacheDB[currentRealm][charInfo.name]
                if charData.activities and charData.activities[act.key] then
                    if GetSmartActivityStatus then
                        currentStatus = GetSmartActivityStatus(currentRealm, charInfo.name, act.key)
                    end
                end
            end
            
            -- СОЗДАЕМ ТЕКСТОВЫЙ ПРОЧЕРК НА СЛУЧАЙ ОТСУТСТВИЯ ДАННЫХ
            local dashText = actBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            dashText:SetPoint("CENTER", actBtn, "CENTER", 0, 0)
            dashText:SetTextColor(0.4, 0.4, 0.4) -- Серый приглушенный цвет
            dashText:SetText("—")
            dashText:Hide()

            -- 5. ВИЗУАЛЬНАЯ МАТРИЦА СОСТОЯНИЙ (ПРОЧЕРК / СЕРЫЙ / ЦВЕТНОЙ)
            if currentStatus == -1 then
                -- ДАННЫХ НЕТ СОВСЕМ: Скрываем круглую иконку и показываем аккуратный серый прочерк!
                tex:Hide()
                dashText:Show()
            elseif currentStatus == 1 then
                -- КВЕСТ ВЫПОЛНЕН И СДАН: Яркая цветная иконка + зеленый неоновый ободок триумфа
                tex:Show()
                tex:SetDesaturated(false)
                actBtn:SetAlpha(1.0)
                tex:SetVertexColor(1, 1, 1)
                local border = actBtn:CreateTexture(nil, "OVERLAY")
                border:SetAllPoints(actBtn)
                border:SetTexture("Interface\\Buttons\\CheckButtonHilight")
                border:SetBlendMode("ADD")
            elseif currentStatus == 2 then
                -- КВЕСТ В ПРОЦЕССЕ (ВЗЯТ): Цветная иконка с оранжевым предупреждающим тоном
                tex:Show()
                tex:SetDesaturated(false)
                actBtn:SetAlpha(0.9)
                tex:SetVertexColor(1, 0.85, 0.4)
            else
                -- КВЕСТ ДОСТУПЕН (НЕ СДЕЛАН / СБРОШЕН В 03:00): Матовая серая полупрозрачная иконка
                tex:Show()
                tex:SetDesaturated(true)
                actBtn:SetAlpha(0.35)
                tex:SetVertexColor(1, 1, 1)
            end

            
            -- Интерактивные всплывающие подсказки
            actBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(act.name, 1, 0.82, 0)
                GameTooltip:AddLine(act.desc, 0.8, 0.8, 0.8, true)
                GameTooltip:AddLine(" ")
                
                if currentStatus == 1 then
                    GameTooltip:AddLine("Статус: Выполнено и сдано сегодня", 0, 1, 0)
                elseif currentStatus == 2 then
                    GameTooltip:AddLine("Статус: Задание взято (В журнале)", 1, 0.7, 0)
                else
                    GameTooltip:AddLine("Статус: Доступно / Еще не сделано", 0.7, 0.7, 0.7)
                end
                GameTooltip:Show()
            end)
            actBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            
            xOffset = xOffset + stepXOffset -- Перемещаем следующую иконку на шаг сетки
        end
        
        row:Show()
        table.insert(activityRowsPool, row)
        yOffset = yOffset - rowHeight
    end
    
    child:SetHeight(math.max(math.abs(yOffset), 1))
end
--]]

--[[
-- бэкап диагностического блока, нужен только для отладки
--sbpt-v346: АСИНХРОННЫЙ ЛАБОРАТОРНЫЙ ЗОНД-ИСКАТЕЛЬ СКРЫТЫХ ID КВЕСТОВ СИРУСА С ИНТЕРФЕЙСОМ ССЫЛОК
local sbptDiagnosticProbe = CreateFrame("Frame")

-- Регистрируем полный спектр событий, включая серверный затвор готовности КД
sbptDiagnosticProbe:RegisterEvent("QUEST_LOG_UPDATE")
sbptDiagnosticProbe:RegisterEvent("QUEST_ACCEPTED")
sbptDiagnosticProbe:RegisterEvent("QUEST_TURNED_IN")
sbptDiagnosticProbe:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
sbptDiagnosticProbe:RegisterEvent("QUEST_QUERY_COMPLETE")

local isProbeDelayActive = false -- Защита от дублирования сканирования

sbptDiagnosticProbe:SetScript("OnEvent", function(self, event, arg1, arg2, ...)
    local currentTime = date("%H:%M:%S")
    
    -- Громко пишем в чат о любом прилетевшем системном сигнале
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[Зонд-Событие %s]|r -> Поймано событие: |cffffffff%s|r", currentTime, event))
    
    if event == "QUEST_ACCEPTED" then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  |cff00ff00• МГНОВЕННЫЙ СИГНАЛ ВЗЯТИЯ:|r Индекс строки: %s, Нативный ID из аргумента: %s", tostring(arg1), tostring(arg2 or "nil")))
    elseif event == "QUEST_QUERY_COMPLETE" then
        DEFAULT_CHAT_FRAME:AddMessage("  |cff00ff00• СЕРВЕРНЫЙ ЗАТВОР:|r Пакет КД от Сируса успешно приземлился в ОЗУ вашего компьютера!")
    end

    -- АСИНХРОННЫЙ ХИРУРГИЧЕСКИЙ ХВАТ: Запускаем отложенный высокоточный скан гиперссылок журнала
    if not isProbeDelayActive then
        isProbeDelayActive = true
        
        local delayProbeFrame = CreateFrame("Frame")
        local elapsed = 0
        delayProbeFrame:SetScript("OnUpdate", function(pSelf, elap)
            elapsed = elapsed + elap
            if elapsed >= 0.5 then -- Ждем 0.5 сек, давая Сирусу время полностью сформировать линки в ОЗУ
                pSelf:SetScript("OnUpdate", nil)
                isProbeDelayActive = false
                
                -- Бежим по всему журналу и вытаскиваем ID из скрытых близзардовских ссылок по тексту!
                local numQuests = GetNumQuestLogEntries() or 0
                for i = 1, numQuests do
                    local title, _, _, _, _, _, _, logQuestID = GetQuestLogTitle(i)
                    local logLink = GetQuestLink(i)
                    
                    if title and (string.find(title, "Обуздать твердыню") or string.find(title, "Норигорн")) then
                        -- Вытаскиваем побайтовый ID из каноничной строки "quest:ID" внутри ссылки чата
                        local trueID = logLink and string.match(logLink, "quest:(%d+)") or tostring(logQuestID or "Не найден")
                        
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffaa00[Зонд-АНАЛИЗ %s]|r Найдено задание: |cffffffff'%s'|r", date("%H:%M:%S"), title))
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("  > Истинный ID из гиперссылки GetQuestLink -> |cff00ff00%s|r", tostring(trueID)))
                    end
                end
                
                -- Вызываем стандартное обновление аддона
                local success, err = pcall(function()
                    if UpdateCurrentCharacterActivities then UpdateCurrentCharacterActivities() end
                    if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
                        DrawActivitiesTab()
                    end
                end)
                if not success then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff2020[Зонд-Ошибка]|r Сбой графики: " .. tostring(err))
                end
            end
        end)
    end
end)
-- конец блока зонда
--]]

--
--sbpt-v348 [ЧАСТЬ 1]: РАСЧЕТ ТАЙМЕРОВ КД И СТАЛЬНАЯ ДВУХЭТАЖНАЯ ШАПКА ТАБЛИЦЫ АКТИВНОСТЕЙ
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
            if type(charData) == "table" and charName ~= "QUEST_LFG" and charName ~= "Version" then
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
    }
    
    local startXOffset = 220
    local stepXOffset = 65
    
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
    hTimeStr:SetFont("Fonts\\FRIZQT__.TTF", 10, "NORMAL")
    hTimeStr:SetPoint("TOPLEFT", activitiesHeaderFrame, "TOPLEFT", 10, 0)
    hTimeStr:SetTextColor(0.5, 0.5, 0.5)
    hTimeStr:SetText(string.format("КД Монета: %d ч. %d мин.  |  КД Охота/Норигорн: %d дн. %d ч. %d мин.", dHours, dMins, wDays, wHours, wMins))

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
    hTitle:SetPoint("LEFT", activitiesHeaderFrame, "LEFT", 10, -3)
    hTitle:SetText("Персонажи")
    hTitle:SetTextColor(1, 0.82, 0)

    local headerTextMap = { "Монета", "Охота", "Норигорн" }
    local xHeaderOffset = startXOffset
    for i, label in ipairs(headerTextMap) do
        local hLabel = activitiesHeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hLabel:SetPoint("CENTER", activitiesHeaderFrame, "LEFT", xHeaderOffset + 10, -3)
        hLabel:SetText(label)
        hLabel:SetTextColor(0.7, 0.7, 0.7)
        xHeaderOffset = xHeaderOffset + stepXOffset
    end

------------ блок 2    
--sbpt-v348 [ЧАСТЬ 2]: ЦИКЛ ОТРИСОВКИ СТРОК ТВИНКОВ И РЕАЛИЗАЦИЯ МАТРИЦЫ ИНДИКАТОРОВ
    local yOffset = -46
    local rowHeight = 28
    
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
        nameText:SetPoint("LEFT", row, "LEFT", 10, 2)
        nameText:SetText(charInfo.name)
        
        local classColor = RAID_CLASS_COLORS[charInfo.class]
        if classColor then
            nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            nameText:SetTextColor(1, 1, 1)
        end
        
        local xOffset = startXOffset
        
        for _, act in ipairs(activityConfig) do
            local actBtn = CreateFrame("Button", nil, row)
            actBtn:SetSize(20, 20)
            actBtn:SetPoint("LEFT", row, "LEFT", xOffset, 2)
            
            local tex = actBtn:CreateTexture(nil, "BACKGROUND")
            tex:SetAllPoints(actBtn)
            tex:SetTexture(act.texture)
            actBtn.texture = tex
            
            local currentStatus = -1
            if ramCacheDB and ramCacheDB[currentRealm] and ramCacheDB[currentRealm][charInfo.name] then
                local charData = ramCacheDB[currentRealm][charInfo.name]
                if charData.activities and charData.activities[act.key] then
                    if GetSmartActivityStatus then
                        currentStatus = GetSmartActivityStatus(currentRealm, charInfo.name, act.key)
                    end
                end
            end
            
            local statusText = actBtn:CreateFontString(nil, "OVERLAY")
            statusText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
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
                
                statusText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
                statusText:SetTextColor(1, 1, 1)
                statusText:SetText("?")
                statusText:Show()
                
--sbpt-v373: ЖИВАЯ ПУЛЬСАЦИЯ ВСЕЙ ИКОНКИ ЦЕЛИКОМ ДЛЯ МАКСИМАЛЬНОГО ВЫДЕЛЕНИЯ ГОТОВЫХ КВЕСТОВ
            elseif currentStatus == 3 then
                -- ВЗЯТ И ВЫПОЛНЕН: Включаем сочный цветной режим для иконки и готовим её к анимации
                tex:Show()
                tex:SetDesaturated(false) -- Возвращаем иконке сочные родные цвета, чтобы мигание выглядело красиво!
                
                statusText:SetFont("Fonts\\FRIZQT__.TTF", 18, "THICKOUTLINE")
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
                statusText:SetText("—")
                statusText:Show()
            end
            
            actBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(act.name, 1, 0.82, 0)
                
                if currentStatus == 1 then
                    GameTooltip:AddLine("Статус: Выполнено и сдано", 0, 1, 0)
                elseif currentStatus == 2 then
                    GameTooltip:AddLine("Статус: В процессе выполнения", 0.6, 0.6, 0.6)
                elseif currentStatus == 3 then
                    GameTooltip:AddLine("Статус: Выполнено!", 1, 1, 0)
                elseif currentStatus == -1 then
                    GameTooltip:AddLine("Статус: Нет информации (Требуется зайти на персонажа)", 0.5, 0.5, 0.5)
                else
                    GameTooltip:AddLine("Статус: Можно взять", 0.4, 1, 0.4)
                end
                GameTooltip:Show()
            end)
            actBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            
            xOffset = xOffset + stepXOffset
        end
        row:Show()
        table.insert(activityRowsPool, row)
        yOffset = yOffset - rowHeight
    end
    child:SetHeight(math.max(math.abs(yOffset), 1))
end

--sbpt-v372: ОФИЦИАЛЬНЫЙ СКАНЕР АКТИВНОСТЕЙ С АВТО-ДЕТЕКЦИЕЙ ЦЕЛЕЙ ДЛЯ ИДЕАЛЬНОГО ТРЕКИНГА НОРИГОРНА
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
    }
    
    local currentTimeStamp = time()
    
    for key, idList in pairs(activityTargets) do
        local currentStatus = 0
        local isQuestDoneServer = false
        
        -- 1. СЕРВЕРНАЯ ПРОВЕРКА СДАННЫХ КД
        for _, qID in ipairs(idList) do
            if turnedInQuestID and tonumber(turnedInQuestID) == qID then
                isQuestDoneServer = true
                break
            elseif IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(qID) then
                isQuestDoneServer = true
                break
            elseif completedQuests and (completedQuests[qID] or completedQuests[tostring(qID)]) then
                isQuestDoneServer = true
                break
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
                        -- Квест 100% взят персонажем! Проверяем его внутренние цели (критерии) Сируса
                        local isFinishedByObjectives = false
                        local numObjectives = GetNumQuestLeaderBoards(internalIndex) or 0
                        
                        if numObjectives > 0 then
                            local goalCount = 0 -- Инициализируем наш новый счетчик закрытых целей
                            for objIdx = 1, numObjectives do
                                local _, _, finished = GetQuestLogLeaderBoard(objIdx, internalIndex)
                                if finished then
                                    goalCount = goalCount + 1 -- Суммируем каждого убитого босса/закрытую цель
                                end
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
        end
        
        -- Бережно сохраняем выверенный статус в ОЗУ-кэш и на жесткий диск WTF
        ramCacheDB[currentRealm][charName].activities[key] = {
            status = currentStatus,
            lastCheck = currentTimeStamp
        }
        SirusBPTrackerDB[currentRealm][charName].activities[key] = {
            status = currentStatus,
            lastCheck = currentTimeStamp
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
        local dateTable = date("*t", currentTime)
        local daysSinceThursday = dateTable.wday - 5
        if daysSinceThursday < 0 then daysSinceThursday = daysSinceThursday + 7 end
        dateTable.hour = 3; dateTable.min = 0; dateTable.sec = 0
        local thursdayResetTime = time(dateTable) - (daysSinceThursday * 86400)
        
        if dateTable.wday == 5 and currentTime < thursdayResetTime then
            thursdayResetTime = thursdayResetTime - (7 * 86400)
        end
        if lastCheck < thursdayResetTime then return 0 end
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

--[[ кусочек для работы с id квестов
--sbpt-v346: АСИНХРОННЫЙ ЛАБОРАТОРНЫЙ ЗОНД-ИСКАТЕЛЬ СКРЫТЫХ ID КВЕСТОВ СИРУСА С ИНТЕРФЕЙСОМ ССЫЛОК
local sbptDiagnosticProbe = CreateFrame("Frame")
sbptDiagnosticProbe:RegisterEvent("QUEST_LOG_UPDATE")
sbptDiagnosticProbe:RegisterEvent("QUEST_ACCEPTED")
sbptDiagnosticProbe:RegisterEvent("QUEST_TURNED_IN")
sbptDiagnosticProbe:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
sbptDiagnosticProbe:RegisterEvent("QUEST_QUERY_COMPLETE")

local isProbeDelayActive = false

sbptDiagnosticProbe:SetScript("OnEvent", function(self, event, arg1, arg2, ...)
    local currentTime = date("%H:%M:%S")
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[Зонд-Событие %s]|r -> Поймано событие: |cffffffff%s|r", currentTime, event))
    
    if event == "QUEST_ACCEPTED" then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  |cff00ff00• МГНОВЕННЫЙ СИГНАЛ ВЗЯТИЯ:|r Индекс строки: %s, Нативный ID из аргумента: %s", tostring(arg1), tostring(arg2 or "nil")))
    elseif event == "QUEST_QUERY_COMPLETE" then
        DEFAULT_CHAT_FRAME:AddMessage("  |cff00ff00• СЕРВЕРНЫЙ ЗАТВОР:|r Пакет КД от Сируса успешно приземлился в ОЗУ вашего компьютера!")
    end

    if not isProbeDelayActive then
        isProbeDelayActive = true
        local delayProbeFrame = CreateFrame("Frame")
        local elapsed = 0
        delayProbeFrame:SetScript("OnUpdate", function(pSelf, elap)
            elapsed = elapsed + elap
            if elapsed >= 0.5 then
                pSelf:SetScript("OnUpdate", nil)
                isProbeDelayActive = false
                
                local numQuests = GetNumQuestLogEntries() or 0
                for i = 1, numQuests do
                    local title, _, _, _, _, _, _, logQuestID = GetQuestLogTitle(i)
                    local logLink = GetQuestLink(i)
                    
                    if title and (string.find(title, "Обуздать твердыню") or string.find(title, "Норигорн")) then
                        local trueID = logLink and string.match(logLink, "quest:(%d+)") or tostring(logQuestID or "Не найден")
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffaa00[Зонд-АНАЛИЗ %s]|r Найдено задание: |cffffffff'%s'|r", date("%H:%M:%S"), title))
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("  > Истинный ID из гиперссылки GetQuestLink -> |cff00ff00%s|r", tostring(trueID)))
                    end
                end
                
                if UpdateCurrentCharacterActivities then UpdateCurrentCharacterActivities() end
                if DrawActivitiesTab and activitiesScrollFrame and activitiesScrollFrame:IsShown() then
                    DrawActivitiesTab()
                end
            end
        end)
    end
end)
--]]

--sbpt-v473: ВСЕЯДНЫЙ СКАНЕР ОКOН ВВОДА ДЛЯ ПОЛНОГО ОБХОДА ИЗОЛЯЦИИ ЧАТА ELVUI
function DumpSirusLink()
    local foundEditBox = nil
    
    -- 1. Проверяем стандартные указатели WoW API
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
        foundEditBox = ChatEdit_GetActiveWindow()
    elseif LAST_ACTIVE_CHAT_EDIT_BOX and LAST_ACTIVE_CHAT_EDIT_BOX:IsShown() then
        foundEditBox = LAST_ACTIVE_CHAT_EDIT_BOX
    end
    
    -- 2. Если ElvUI спрятал окно, жестко перебираем все 10 каналов чата Сируса
    if not foundEditBox then
        for i = 1, 10 do
            local eb = _G["ChatFrame"..i.."EditBox"]
            if eb and eb:IsShown() then
                foundEditBox = eb
                break
            end
        end
    end
    
    -- 3. Извлекаем и дампим хэш ссылки Сируса
    if foundEditBox then
        local currentText = foundEditBox:GetText() or ""
        if currentText ~= "" then
            local cleanDump = string.gsub(currentText, "\124", "\\124")
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SBPT-Анализатор]:|r " .. cleanDump)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff2020[SBPT-Ошибка]: Строка ввода чата пуста! Сначала линкните квест с Shift.|r")
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff2020[SBPT-Ошибка]: Активное окно ввода чата ElvUI не найдено в ОЗУ!|r")
    end
end

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
