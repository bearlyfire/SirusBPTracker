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

local function GetAnyText(obj)
    if not obj then return nil end
    if obj.GetText and obj:GetText() and obj:GetText() ~= "" then return obj:GetText() end
    if obj.Text and obj.Text.GetText and obj.Text:GetText() and obj.Text:GetText() ~= "" then return obj.Text:GetText() end
    return nil
end
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

--sbpt-v108-help-button-final: ИДЕАЛЬНАЯ КРУПНАЯ КРУГЛАЯ КНОПКА СПРАВКИ БЕЗ НАЛОЖЕНИЙ
    -- Создаем круглую кнопку на базе чистого круглого шаблона Близзард
    local helpBtn = CreateFrame("Button", "SirusBPHelpButton", gui)
    helpBtn:SetSize(22, 22) -- Чуть увеличили размер для идеального баланса с шестеренкой
    helpBtn:SetPoint("RIGHT", filterBtn, "LEFT", -5, 0)
    
    -- Используем чистые круглые текстуры Blizzard без внутренних точек и скрытого мусора
    helpBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    helpBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    helpBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    
    -- Разворачиваем круглую подложку ( Blizzard-стрелочку убираем, делая невидимой)
    if helpBtn:GetNormalTexture() then helpBtn:GetNormalTexture():SetTexCoord(0, 0, 0, 0) end
    if helpBtn:GetPushedTexture() then helpBtn:GetPushedTexture():SetTexCoord(0, 0, 0, 0) end

    -- Делаем красивый круглый фон нативного цвета интерфейса
    helpBtn:SetBackdrop({
        bgFile = "Interface\\CharacterFrame\\BarBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    helpBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    helpBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

--sbpt-v109-help-font-alignment: ТОЧЕЧНЫЙ ФИКС ВЫРАВНИВАНИЯ И ЖИРНОСТИ ЗНАКА ВОПРОСА
    -- Рисуем МАССИВНЫЙ жирный знак вопроса строго по центру горизонтальной линейки шапки
    local helpBtnText = helpBtn:CreateFontString(nil, "OVERLAY")
    helpBtnText:SetFont("Fonts\\FRIZQT__.TTF", 13, "THICKOUTLINE") -- ВКЛЮЧИЛИ СВЕРХЖИРНЫЙ КОНТУР!
    helpBtnText:SetPoint("CENTER", 0, -2) -- ИСПРАВЛЕНО: Сместили на 2 пикселя вниз для идеального выравнивания
--sbpt-v109-help-font-alignment: КОНЕЦ ФИКСА ВЫРАВНИВАНИЯ
    helpBtnText:SetText("?")
    helpBtnText:SetTextColor(1, 0.82, 0) -- Золотой цвет
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



    local searchBox = CreateFrame("EditBox", "SirusBPSearchBox", gui)
    searchBox:SetSize(130, 20)
    searchBox:SetPoint("TOPRIGHT", helpBtn, "TOPLEFT", -15, -1)
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

--sbpt-v53-safe-ui: ФРАГМЕНТ 1 ИЗ 2 ОБНОВЛЕННОЙ ОТРИСОВКИ (БЕЗОПАСНЫЕ СБОРЫ)
UpdateGUIText = function()
    local gui = CreateMainGUI()
    local child = gui.scrollChild
    local sborChild = gui.sborScrollChild
    ClearFontStringPool()

    if not SirusBPTrackerConfig then SirusBPTrackerConfig = {} end
    local activeTab = SirusBPTrackerConfig.ActiveTab or 1
    local currentTime = time()

    -- Счетчик интерактивных элементов для шёпота
    local sborBtnIdx = 1

    -- ========================================================================
    -- ЛОГИКА ВКЛАДКИ 2: АКТУАЛЬНЫЕ СБОРЫ ИЗ ЧАТА СИРУСА (СНИЗУ ВВЕРХ)
    -- ========================================================================
    --sbpt-v54-ui-buttons-fix: ОГРАНИЧЕНИЕ КНОПОК ШЁПОТА И УЛИЧШЕННЫЕ ЦВЕТА СБОРОВ
--sbpt-v133-lfg-clear-widgets: УЛЬТРА-ОЧИСТКА ХОЛСТА СБОРОВ ПЕРЕД ОТРИСОВКОЙ
    if activeTab == 2 and sborChild then
        if not SirusBPTrackerDB["QUEST_LFG"] then SirusBPTrackerDB["QUEST_LFG"] = {} end
        
        -- ЖЕСТКАЯ ЗАЧИСТКА: Пробегаемся по всем старым созданным строчкам и кнопкам холста и скрываем их!
        if sborChild.widgets then
            for _, widget in ipairs(sborChild.widgets) do
                if widget and widget.Hide then widget:Hide() end
            end
        end
        sborChild.widgets = {} -- Обнуляем массив виджетов

        -- Обнуляем глобальные координаты высоты и кнопок шёпота
        yOffset = -10
        sborBtnIdx = 1
        
        local currentTime = time()
--sbpt-v136-flat-chrono-sort: АБСОЛЮТНАЯ ХРОНОЛОГИЧЕСКАЯ СТРУНА ВСЕХ КРИКОВ БЕЗ СМЕШИВАНИЯ
        local sortedSbors = {} -- Эта таблица нам больше не нужна для циклов, но оставляем для совместимости
        
        -- 1. Собираем ВСЕХ авторов из ВСЕХ квестов в один единый плоский список
        local flatAuthorsList = {}
        if SirusBPTrackerDB["QUEST_LFG"] then
            for questKey, sbor in pairs(SirusBPTrackerDB["QUEST_LFG"]) do
                -- Умный двухпозиционный фильтр ЛФГ-строк (БП / Все квесты)
                local allowedToRender = true
                if SirusBPTrackerConfig and SirusBPTrackerConfig.OnlyBpSbors == true then
                    local isDailyQuest = string.find(string.lower(sbor.questName or ""), "ежедневное")
                    local isSeasonalQuest = string.find(string.lower(sbor.questName or ""), "сезонное")
                    if not isDailyQuest and not isSeasonalQuest then
                        allowedToRender = false
                    end
                end

                if allowedToRender and sbor.authors then
                    for _, auth in ipairs(sbor.authors) do
                        if auth.name and auth.msg then
                            local elapsedSec = currentTime - (auth.time or sbor.time or currentTime)
                            -- Проверяем жесткие 20 минут (1200 сек) для каждого крика
                            if elapsedSec <= 1200 then
                                -- Запоминаем ссылку на родительский квест, чтобы вытащить ID и прогресс твинков
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

        -- 2. МАТЕМАТИЧЕСКАЯ СОРТИРОВКА: Выстраиваем абсолютно все крики по времени от свежих к старым!
        table.sort(flatAuthorsList, function(a, b)
            return (a.time or 0) > (b.time or 0)
        end)

        -- 3.ОТРИСОВКА ИДЕАЛЬНОЙ СТРУНЫ НА ЭКРАНЕ
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

            local cleanMsg = tostring(auth.msg or "")
            cleanMsg = string.gsub(cleanMsg, "|Hquest:.-|h%[.-%]|h", ""):gsub("|Hquest:.-|h.-|h", "")
            cleanMsg = string.gsub(cleanMsg, "|Hplayer:.-|h.-|h", ""):gsub("%[?" .. questFullName .. "%]?", "")
            cleanMsg = string.gsub(cleanMsg, "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            cleanMsg = string.gsub(cleanMsg, "^%s*:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if cleanMsg == "" then cleanMsg = "Ищет группу" end

            local charProgressStrings = {}
            local normalizedTargetDesc = string.gsub(string.lower(questFullName), "%s+", ""):gsub("ежедневноезадание:", ""):gsub("сезонноезадание:", ""):gsub("%[", ""):gsub("%]", "")

            for charKey, data in pairs(SirusBPTrackerDB) do
                if charKey ~= "FRAME_DUMP" and charKey ~= "QUEST_LFG" then
                    local charName = string.match(charKey, "([^-]+)") or charKey
                    charName = charName:gsub("%s+", "")
                    if SirusBPTrackerCharFilterDB[charName] ~= false and data.quests then
                        for _, q in ipairs(data.quests) do
                            if string.gsub(string.lower(q.text or ""), "%s+", "") == normalizedTargetDesc then
                                local cHex = CLASS_COLORS[data.class or ""] or "ffffff"
                                local pStr = (q.progress == "Завершено") and "|cff00ff00Вып!|r" or "|cff00ff00" .. q.progress .. "|r"
                                table.insert(charProgressStrings, string.format("|cff%s%s|r(%s)", cHex, charName, pStr))
                                break
                              end
                        end
                    end
                end
            end

            local twinsLine = ""
            if #charProgressStrings > 0 then
                twinsLine = " |cff888888[|r" .. table.concat(charProgressStrings, ", ") .. "|cff888888]|r"
            end

            local sborLine = sborChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            sborLine:SetTextColor(1, 1, 1)
            sborLine:SetPoint("TOPLEFT", sborChild, "TOPLEFT", 15, yOffset)
            sborLine:SetWidth(440)
            sborLine:SetJustifyH("LEFT")
            sborLine:SetNonSpaceWrap(true)
            
            sborLine:SetText(string.format("|cff888888(%s)|r |cff%s[%s]|r%s |cff%s[%s]|r: |cffffffff\"%s\"|r", 
                timeStr, hexColor, questFullName, twinsLine, classHex, auth.name, cleanMsg))

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

            rowBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                
                local currentQuestID = sbor.questID or "28111"
                GameTooltip:SetHyperlink("quest:" .. currentQuestID)
                
                local rawName = self.questName or "Задание"
                local isDaily = string.find(string.lower(rawName), "ежедневное")
                local isSeasonal = string.find(string.lower(rawName), "сезонное")
                
                if not isDaily and not isSeasonal then
                    GameTooltip:Show()
                    return
                end
                
                local line3Obj = _G["GameTooltipTextLeft3"]
                local serverDesc = line3Obj and line3Obj:GetText() or ""
                if serverDesc == "" then
                    local line2Obj = _G["GameTooltipTextLeft2"]
                    serverDesc = line2Obj and line2Obj:GetText() or ""
                end
                
                local charStrings = {}
                if serverDesc and serverDesc ~= "" and serverDesc ~= "пусто" then
                    local normalizedServerTarget = string.gsub(string.lower(serverDesc), "%s+", "")
                    for charKey, data in pairs(SirusBPTrackerDB) do
                        if charKey ~= "FRAME_DUMP" and charKey ~= "QUEST_LFG" then
                            local charName = string.match(charKey, "([^-]+)") or charKey
                            charName = charName:gsub("%s+", "")
                            if SirusBPTrackerCharFilterDB[charName] ~= false and data.quests then
                                for _, q in ipairs(data.quests) do
                                    local cleanQText = string.gsub(string.lower(q.text or ""), "%s+", "")
                                    if cleanQText == normalizedServerTarget then
                                        local hexColor = CLASS_COLORS[data.class or ""] or "ffffff"
                                        local progStr = (q.progress == "Завершено") and "|cff00ff00Завершено!|r" or "|cff00ff00" .. q.progress .. "|r"
                                        table.insert(charStrings, string.format("|cff%s%s|r (%s)", hexColor, charName, progStr))
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
                
                GameTooltip:AddLine(" ")
                if #charStrings > 0 then
                    table.sort(charStrings)
                    GameTooltip:AddLine("|cffffd100Персонажи:|r " .. table.concat(charStrings, ", "), 1, 1, 1, true)
                else
                    GameTooltip:AddLine("|cff888888Задание отсутствует у всех персонажей|r", 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)

            yOffset = yOffset - (sborLine:GetStringHeight() + 8)
            table.insert(sborChild.widgets, sborLine)
            table.insert(sborChild.widgets, rowBtn)
        end
        
        sborChild:SetHeight(math.abs(yOffset) + 20)
    end -- Конец блока "if activeTab == 2 and sborChild then"
 -- КОНЕЦ ГЛАВНОЙ ФУНКЦИИ UPDATEGUITEXT
--sbpt-v136-flat-chrono-sort: КОНЕЦ ФИКСА ФАЙЛА




--sbpt-v53-safe-ui: ФРАГМЕНТ 2 ИЗ 2 ОБНОВЛЕННОЙ ОТРИСОВКИ (СПИСОК ПЕРСОНАЖЕЙ)
    -- ========================================================================
    -- ЛОГИКА ВКЛАДКИ 1: СТАНДАРТНЫЙ СПИСОК КВЕСТОВ ПЕРСОНАЖЕЙ
    -- ========================================================================
    local categories = { ["Ежедневные"] = {}, ["Сезонные"] = {} }
    local stats = { ["Ежедневные"] = {}, ["Сезонные"] = {} }
    
    for charKey, data in pairs(SirusBPTrackerDB) do
        if charKey ~= "FRAME_DUMP" and charKey ~= "QUEST_LFG" then
            local name = string.match(charKey, "([^-]+)") or charKey
            name = name:gsub("%s+", "")
            
            if SirusBPTrackerCharFilterDB[name] ~= false and data.quests then
                for _, q in ipairs(data.quests) do
                    local cat = q.block or "Сезонные"
                    if cat ~= "Ежедневные" and cat ~= "Сезонные" then cat = "Сезонные" end
                    
                    if not stats[cat][name] then
                        stats[cat][name] = { total = 0, completed = 0, class = data.class }
                    end
                    stats[cat][name].total = stats[cat][name].total + 1
                    if q.progress == "Завершено" then
                        stats[cat][name].completed = stats[cat][name].completed + 1
                    end

                    if SirusBPTrackerFilterDB[q.text] ~= false then
                        if not categories[cat] then categories[cat] = {} end
                        if not categories[cat][q.text] then categories[cat][q.text] = {} end
                        table.insert(categories[cat][q.text], { name = name, class = data.class, progress = q.progress })
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
                end

                if questList then
                    for questText, characters in pairs(questList) do
                        if searchText == "" or string.find(string.lower(questText), searchText, 1, true) then
                            local qFs = AcquireFontString(child, "GameFontHighlight", 1, 0.82, 0, "LEFT", 430, 15, yOffset)
                            qFs:SetText("• " .. questText)
                            yOffset = yOffset - (qFs:GetStringHeight() + 3)
                            
                            local charStrings = {}
                            for _, char in ipairs(characters) do
                                local hexColor = CLASS_COLORS[char.class or ""] or "ffffff"
                                local progStr = char.progress == "Завершено" and "|cff00ff00Завершено!|r" or "|cff00ff00" .. char.progress .. "|r"
                                table.insert(charStrings, string.format("|cff%s%s|r - %s", hexColor, char.name, progStr))
                            end
                            if #charStrings > 0 then
                                table.sort(charStrings)
                                local blockLine = table.concat(charStrings, ", ")
                                local cFs = AcquireFontString(child, "GameFontNormalSmall", nil, nil, nil, "LEFT", 410, 30, yOffset)
                                cFs:SetText(blockLine)
                                yOffset = yOffset - (cFs:GetStringHeight() + 5)
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
    end
    child:SetHeight(math.abs(yOffset) + 20)
end
--sbpt-v53-safe-ui: КОНЕЦ ПОЛНОГО МОНОЛИТА ОТРИСОВКИ


--sbpt-v20-global-buffer: НАЧАЛО ИСПРАВЛЕННОЙ ГЛОБАЛЬНОЙ ЛОВУШКИ ЧАТА С АВТОСОЗДАНИЕМ ФРЕЙМА
chatAuthorsBuffer = chatAuthorsBuffer or {}

-- ЖЕСТКАЯ ЗАЩИТА: Если фрейм ловушки чата был удален, создаем его заново на лету!
if not chatTrackerFrame then
    chatTrackerFrame = CreateFrame("Frame")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_CHANNEL")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_YELL")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_SAY")
    chatTrackerFrame:RegisterEvent("CHAT_MSG_GUILD")
end

--sbpt-v129-radar-time-fix: ИСПРАВЛЕННЫЙ РАДАР С ДВОЙНЫМ УЧЕТОМ ВРЕМЕНИ
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

        for questID in string.gmatch(arg1, "|Hquest:(%d+)") do
            if questID then
                local questTitleName = string.match(arg1, "|h%[([^%]]+)%]")
                
                if questTitleName then
                    local dbKey = NormalizeText(questTitleName)
                    if not SirusBPTrackerDB["QUEST_LFG"] then SirusBPTrackerDB["QUEST_LFG"] = {} end
                    
                    local hexColor = "ff8040"
                    local foundQuestHex = string.match(arg1, "|cff(%x%x%x%x%x%x)")
                    if foundQuestHex then hexColor = foundQuestHex end

                    -- ИСПРАВЛЕНО: Общее sbor.time теперь ВСЕГДА обновляется, чтобы table.sort не ломал вывод списка!
                    SirusBPTrackerDB["QUEST_LFG"][dbKey] = SirusBPTrackerDB["QUEST_LFG"][dbKey] or {
                        questName = questTitleName,
                        questID = questID,
                        hexColor = hexColor,
                        time = time(),
                        authors = {}
                    }
                    SirusBPTrackerDB["QUEST_LFG"][dbKey].time = time() -- Держим общую сортировку актуальной
                    SirusBPTrackerDB["QUEST_LFG"][dbKey].questID = questID
                    SirusBPTrackerDB["QUEST_LFG"][dbKey].hexColor = hexColor

                    local authorExists = false
                    for _, auth in ipairs(SirusBPTrackerDB["QUEST_LFG"][dbKey].authors) do
                        if auth.name == arg2 then
                            auth.msg = arg1
                            auth.time = time() -- Персональное время автора
                            if classToken ~= "WHITE" then auth.class = classToken end
                            authorExists = true
                            break
                        end
                    end
                    
                    if not authorExists then
                        table.insert(SirusBPTrackerDB["QUEST_LFG"][dbKey].authors, {
                            name = arg2,
                            msg = arg1,
                            class = classToken,
                            time = time() -- Персональное время автора
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
--sbpt-v129-radar-time-fix: КОНЕЦ ОБНОВЛЕНИЯ РАДАРА

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


--****
--sbpt-v02: ПОЛНЫЙ ПРОВЕРЕННЫЙ БЛОК ОКНА ФИЛЬТРОВ (БЕЗ QUEST_LFG И БЕЗ ОШИБОК)
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

    -- 1. Новое название окна
    local title = fGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14) 
    title:SetText("Настройки")

    local closeBtn = CreateFrame("Button", nil, fGui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)

 -- 2. Кнопка "Очистить БД" теперь аккуратно выровнена справа от заголовка "Настройки"
    local clearAllBtn = CreateFrame("Button", "SirusBPClearAllBtn", fGui, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(95, 22)
    clearAllBtn:SetPoint("LEFT", title, "RIGHT", 15, -1)
    clearAllBtn:SetText("Очистить БД")
    clearAllBtn:RegisterForClicks("LeftButtonUp")
    clearAllBtn:SetScript("OnClick", function()
        SirusBPTrackerDB = {}
        SirusBPTrackerDB["QUEST_LFG"] = {}
        if chatAuthorsBuffer then chatAuthorsBuffer = {} end
        if UpdateGUIText then UpdateGUIText() end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SirusBP]|r Глобальная база данных полностью очищена! Все персонажи и сборы сброшены.")
    end)

     -- 3. Создаем новую плашку === Сборы === ниже шапки
    local sborTitle = fGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sborTitle:SetPoint("TOPLEFT", 16, -44)
    sborTitle:SetText("=== Сборы ===")

    -- Наш единственный умный чекбокс "Только БП сборы" под плашкой
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
--sbpt-v99-header-only: КОНЕЦ МИКРОХИРУРГИЧЕСКОЙ ЗАМЕНЫ ШАПКИ


    -- 3. КРАСИВЫЙ ИНПУТ ПОИСКА КВЕСТА (Возвращен на самый верх, чтобы окно было красивым!)
    local fSearchBox = CreateFrame("EditBox", "SirusBPFilterSearchBox", fGui)
    fSearchBox:SetSize(120, 20)
    fSearchBox:SetPoint("TOPRIGHT", fGui, "TOPRIGHT", -35, -14) -- Идеальная координата на уровне заголовка
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
--sbpt-v32-config-final: КОНЕЦ ИСПРАВЛЕННОЙ ПАНЕЛИ НАСТРОЕК

    local scrollFrame = CreateFrame("ScrollFrame", "SirusBPFilterScrollFrame", fGui, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -92) scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(390, 1) scrollFrame:SetScrollChild(scrollChild)
    fGui.scrollChild = scrollChild

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

        for charKey, data in pairs(SirusBPTrackerDB) do
            -- ЖЕСТКАЯ ЗАЩИТА: Полностью игнорируем технические таблицы сборов и дампов, чтобы они не лезли в ники чаров
            if charKey ~= "FRAME_DUMP" and charKey ~= "QUEST_LFG" then
                local name = string.match(charKey, "([^-]+)") or charKey
                name = name:gsub("%s+", "")
                uniqueCharacters[name] = data.class or "WARRIOR"
                if data.quests then
                    for _, q in ipairs(data.quests) do
                        local cat = q.block or "Сезонные"
                        if cat ~= "Ежедневные" and cat ~= "Сезонные" then cat = "Сезонные" end
                        questsByCat[cat][q.text] = true
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

        AddHeader("=== Задания ===", 0, 1, 1)
        fyOffset = fyOffset - 5

        for _, catName in ipairs({"Ежедневные", "Сезонные"}) do
            local sortedQuests = {}
            for qText in pairs(questsByCat[catName]) do
                if fSearchText == "" or string.find(string.lower(qText), fSearchText, 1, true) then
                    table.insert(sortedQuests, qText)
                end
            end
            table.sort(sortedQuests)

            if #sortedQuests > 0 or fSearchText == "" then
                AddHeader("--- " .. catName .. " ---", 0.7, 0.7, 0.7)

                if #sortedQuests == 0 and fSearchText == "" then
                    local emptyFs = child:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    emptyFs:SetPoint("TOPLEFT", 25, fyOffset) emptyFs:SetText("Нет обнаруженных заданий")
                    fyOffset = fyOffset - 20 table.insert(child.widgets, emptyFs)
                else
                    for _, qText in ipairs(sortedQuests) do
                        if SirusBPTrackerFilterDB[qText] == nil then SirusBPTrackerFilterDB[qText] = true end
                        local cbName = "SirusBPQuestCB_" .. widgetIdx
                        local cb = _G[cbName] or CreateFrame("CheckButton", cbName, child, "InterfaceOptionsCheckButtonTemplate")
                        cb:SetParent(child) cb:ClearAllPoints() cb:SetPoint("TOPLEFT", 20, fyOffset) cb:Show()
                        cb:SetChecked(SirusBPTrackerFilterDB[qText])
                        cb:SetScript("OnClick", function(self)
                            SirusBPTrackerFilterDB[qText] = self:GetChecked() and true or false
                            if UpdateGUIText then UpdateGUIText() end
                        end)

                        local t = cb.TextLabel or child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                        cb.TextLabel = t t:ClearAllPoints() t:SetPoint("LEFT", cb, "RIGHT", 5, 1)
                        t:SetWidth(330) t:SetJustifyH("LEFT") t:SetText(qText) t:Show()

                        local textHeight = t:GetStringHeight()
                        local spacing = (textHeight > 16) and (textHeight + 12) or 26
                        fyOffset = fyOffset - spacing
                        
                        widgetIdx = widgetIdx + 1
                        table.insert(child.widgets, cb) table.insert(child.widgets, t)
                    end
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
--sbpt-v02: КОНЕЦ ПОЛНОГО БЛОКА ОКНА ФИЛЬТРОВ
--sbpt-v110-clean-help-text: МАКСИМАЛЬНО ЛАКОНИЧНЫЙ ТЕКСТ ОКНА СПРАВКИ
--sbpt-v111-about-author: ОБНОВЛЕННАЯ СТИЛЬНАЯ КАРТОЧКА ОБ АДДОНЕ С СИНЕМ НИКОМ МАГА
CreateHelpGUI = function()
    if helpGui then return helpGui end

    local hGui = CreateFrame("Frame", "SirusBPHelpGUI", UIParent)
    hGui:SetSize(380, 110) -- Оптимальный размер под две аккуратные строки текста
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

    -- 1. Меняем заголовок окна по твоей просьбе
    local title = hGui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Об аддоне SirusBPTracker")

    local closeBtn = CreateFrame("Button", nil, hGui, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -3, -3)

    -- 2. Выводим текст благодарности с голубым ником мага Медведж
    local helpText = hGui:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    helpText:SetPoint("TOPLEFT", 16, -45)
    helpText:SetWidth(350)
    helpText:SetJustifyH("LEFT")
    
    -- Применили код цвета мага |cff3fc7eb для ника Медведж
    helpText:SetText("Если Вам понравился аддон, можете пожертвовать мне немного золота через внутриигровую почту.\n\nСервер х5, |cff3fc7ebМедведж|r")

    hGui:Hide()
    helpGui = hGui
    return helpGui
end
--sbpt-v111-about-author: КОНЕЦ ОБНОВЛЕНИЯ КАРТОЧКИ



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
            local gui = CreateMainGUI()
            if gui:IsShown() then gui:Hide() else UpdateGUIText() gui:Show() end
        end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT") GameTooltip:AddLine("Sirus BP Tracker", 1, 1, 1)
        GameTooltip:AddLine("|cff00ff00ЛКМ:|r Открыть/Закрыть окно", 0.8, 0.8, 0.8) GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UpdatePosition()
end

frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == "SirusBPTracker" then
        if not SirusBPTrackerDB then SirusBPTrackerDB = {} end
        if not SirusBPTrackerFilterDB then SirusBPTrackerFilterDB = {} end
        if not SirusBPTrackerCharFilterDB then SirusBPTrackerCharFilterDB = {} end
        if not SirusBPTrackerConfig then SirusBPTrackerConfig = { minimapPos = 45 } end
        CreateMinimapButton()
        print("|cff00ff00[SirusBPTracker]|r Успешно загружен!")
    end
end)

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

-- Единый движок отрисовки для ЛЮБОГО окна (Прогресс твинков)
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
        for charKey, data in pairs(SirusBPTrackerDB) do
            if charKey ~= "FRAME_DUMP" and charKey ~= "QUEST_LFG" then
                local charName = string.match(charKey, "([^-]+)") or charKey
                charName = charName:gsub("%s+", "")
                
                if SirusBPTrackerCharFilterDB[charName] ~= false and data.quests then
                    for _, q in ipairs(data.quests) do
                        if NormalizeText(q.text) == normalizedTooltipDesc then
                            local hexColor = CLASS_COLORS[data.class or ""] or "ffffff"
                            local progStr = (q.progress == "Завершено") and "|cff00ff00Завершено!|r" or "|cff00ff00" .. q.progress .. "|r"
                            table.insert(charStrings, string.format("|cff%s%s|r (%s)", hexColor, charName, progStr))
                            break
                        end
                    end
                end
            end
        end

        self:AddLine(" ")
        if #charStrings > 0 then
            self:AddLine("|cffffd100Персонажи:|r " .. table.concat(charStrings, ", "), 1, 1, 1, true)
            
            -- Запись в базу сборов происходит СТРОГО по клику в чате
            if isClickWindow then
                local questTitleName = string.gsub(titleText, "Ежедневное задание:%s*", ""):gsub("Сезонное задание:%s*", "")
                local searchKey = NormalizeText(questTitleName)
                
                local chatData = chatAuthorsBuffer[searchKey]
                if chatData and chatData.name then
                    if not SirusBPTrackerDB["QUEST_LFG"] then SirusBPTrackerDB["QUEST_LFG"] = {} end
                    
                    local dbKey = normalizedTooltipDesc
                    SirusBPTrackerDB["QUEST_LFG"][dbKey] = SirusBPTrackerDB["QUEST_LFG"][dbKey] or {
                        questName = realQuestDescription,
                        time = time(),
                        authors = {}
                    }
                    SirusBPTrackerDB["QUEST_LFG"][dbKey].time = time()
                    
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





