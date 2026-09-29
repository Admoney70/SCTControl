-- SCT Control: custom display for Blizzard's incoming combat text.
--
-- This client uses secret combat values, so the addon never calls into
-- Blizzard_CombatText or writes its state. Blizzard still decides which
-- messages to show (via the CVars below); a post-hook on
-- CombatText:AddMessage receives each message and this addon draws it
-- itself, with Blizzard's own copy hidden via SetAlpha(0). Secret text
-- is only passed to SetText, never compared or modified.
--
-- /sctc                 open options
-- /sctc test            show sample messages
-- /sctc move            unlock/lock the text area
-- /sctc reset           restore defaults
-- /sctc cvars [filter]  list matching CVars on this client
-- /sctc debug           show hook state

local ADDON = ...

local RawGetCV     = (C_CVar and C_CVar.GetCVar) or GetCVar
local RawSetCV     = (C_CVar and C_CVar.SetCVar) or SetCVar
local GetCVDefault = (C_CVar and C_CVar.GetCVarDefault) or GetCVarDefault

local DEFAULTS = {
    cvars = {}, enforce = true,
    areaX = 0, areaY = 60,
    speed = 80, distance = 150, fadeTime = 0.8, fontSize = 0, critScale = 1.25,
    font = "", outline = "DEFAULT", damageFont = false,
}

local db
local hooked = false
local mover

local function Print(msg) print("|cff33ff99SCT Control:|r " .. msg) end

---------------------------------------------------------------------------
-- CVars (newer clients use a "_v2" suffix on most FCT CVars)
---------------------------------------------------------------------------
local resolved = {}
local function Resolve(cv)
    if resolved[cv] then return resolved[cv] end
    for _, name in ipairs({ cv .. "_v2", cv }) do
        if RawGetCV(name) ~= nil then
            resolved[cv] = name
            return name
        end
    end
end

local function GetCV(cv) local n = Resolve(cv); return n and RawGetCV(n) end
local function SetCV(cv, v) local n = Resolve(cv); if n then RawSetCV(n, tostring(v)) end end
local function CVarExists(cv) return Resolve(cv) ~= nil end

local function SetCVarSaved(cv, value)
    if not CVarExists(cv) then return end
    value = tostring(value)
    SetCV(cv, value)
    db.cvars[cv] = value
end

local function DumpCVars(filter)
    if not (C_Console and C_Console.GetAllCommands) then
        Print("C_Console.GetAllCommands not available on this client.")
        return
    end
    local names = {}
    for _, c in ipairs(C_Console.GetAllCommands()) do
        local name = c.command
        if name then
            local l = strlower(name)
            local hit
            if filter and filter ~= "" then hit = l:find(filter, 1, true)
            else hit = l:find("combattext", 1, true) or l:find("worldtext", 1, true) end
            if hit and RawGetCV(name) ~= nil then table.insert(names, name) end
        end
    end
    table.sort(names)
    for _, n in ipairs(names) do Print(n .. " = " .. tostring(RawGetCV(n))) end
    Print(#names .. " CVar(s) listed.")
end

---------------------------------------------------------------------------
-- Option definitions
---------------------------------------------------------------------------
local TARGET_TOGGLES = {
    { cvar = "floatingCombatTextCombatDamage",            label = "Damage" },
    { cvar = "floatingCombatTextCombatLogPeriodicSpells", label = "DoT / periodic damage" },
    { cvar = "floatingCombatTextPetMeleeDamage",          label = "Pet melee damage" },
    { cvar = "floatingCombatTextPetSpellDamage",          label = "Pet spell damage" },
    { cvar = "floatingCombatTextCombatHealing",           label = "Healing done" },
}

local SELF_TOGGLES = {
    { cvar = "enableFloatingCombatText",              label = "Enable self combat text",
      tip = "Master switch for the scrolling text over your character. May need /reload after turning it on." },
    { cvar = "floatingCombatTextFriendlyHealers",     label = "Healer names on incoming heals" },
    { cvar = "floatingCombatTextDodgeParryMiss",      label = "Dodge / parry / miss" },
    { cvar = "floatingCombatTextDamageReduction",     label = "Resists / blocks / absorbs" },
    { cvar = "floatingCombatTextAuras",               label = "Aura gains" },
    { cvar = "floatingCombatTextAuraFade",            label = "Aura fades" },
    { cvar = "floatingCombatTextCombatState",         label = "Entering / leaving combat" },
    { cvar = "floatingCombatTextLowManaHealth",       label = "Low health / mana" },
    { cvar = "floatingCombatTextEnergyGains",         label = "Mana / rage / energy gains" },
    { cvar = "floatingCombatTextPeriodicEnergyGains", label = "Periodic resource gains" },
    { cvar = "floatingCombatTextComboPoints",         label = "Combo points" },
    { cvar = "floatingCombatTextReactives",           label = "Reactives (Overpower, etc)" },
    { cvar = "floatingCombatTextRepChanges",          label = "Reputation changes" },
    { cvar = "floatingCombatTextHonorGains",          label = "Honor gains" },
}

local SELF_SLIDERS = {
    { key = "areaX",    label = "Horizontal position",   min = -1500, max = 1500, step = 5,   fmt = "%d" },
    { key = "areaY",    label = "Vertical position",     min = -1000, max = 1000, step = 5,   fmt = "%d" },
    { key = "speed",    label = "Scroll speed (px/sec)", min = 10,    max = 400,  step = 5,   fmt = "%d" },
    { key = "distance", label = "Scroll distance (px)",  min = 30,    max = 800,  step = 10,  fmt = "%d" },
    { key = "fadeTime", label = "Fade time (sec)",       min = 0,     max = 3,    step = 0.1, fmt = "%.1f" },
    { key = "fontSize", label = "Font size",             min = 0,     max = 64,   step = 1,   fmt = "%d", zeroDefault = true },
    { key = "critScale", label = "Crit size",            min = 1,     max = 2,    step = 0.05, fmt = "%.2fx" },
}

local FLOAT_MODES = { "Scroll up", "Scroll down", "Arc" }

local BASE_FONTS = {
    { "Default",       "" },
    { "Friz Quadrata", "Fonts\\FRIZQT__.TTF" },
    { "Arial Narrow",  "Fonts\\ARIALN.TTF" },
    { "Morpheus",      "Fonts\\MORPHEUS.TTF" },
    { "Skurri",        "Fonts\\SKURRI.TTF" },
}

local OUTLINES = {
    { "Default",       "DEFAULT" },
    { "None",          "" },
    { "Outline",       "OUTLINE" },
    { "Thick outline", "THICKOUTLINE" },
    { "Mono outline",  "OUTLINE, MONOCHROME" },
}

local function GetFontList()
    local list, seen = {}, {}
    for _, f in ipairs(BASE_FONTS) do list[#list + 1] = f; seen[f[2]] = true end
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        for _, name in ipairs(LSM:List("font")) do
            local path = LSM:Fetch("font", name)
            if path and not seen[path] then
                list[#list + 1] = { name, path }
                seen[path] = true
            end
        end
    end
    return list
end

---------------------------------------------------------------------------
-- Renderer
---------------------------------------------------------------------------
local isSecret = issecretvalue or function() return false end
local area = CreateFrame("Frame", "SCTControlArea", UIParent)
area:SetSize(1, 1)
area:SetFrameStrata("MEDIUM")

local pool, active = {}, {}
local renderFailed = false
local baseFont
local xDir = 1
local MAX_MESSAGES = 30

local function BaseFont()
    if not baseFont then
        local face, size, flags
        if CombatTextFont then face, size, flags = CombatTextFont:GetFont() end
        baseFont = { face or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 24, flags or "OUTLINE" }
    end
    return baseFont
end

local function FontSpec()
    local b = BaseFont()
    local face  = (db.font ~= "" and db.font) or b[1]
    local size  = (db.fontSize > 0 and db.fontSize) or b[2]
    local flags = (db.outline ~= "DEFAULT" and db.outline) or b[3]
    return face, size, flags
end

local function MessageSize(crit)
    local _, size = FontSpec()
    if crit then size = size * db.critScale end
    return math.floor(size + 0.5)  -- fractional sizes rasterise blurry
end

local function LineHeight(crit)
    return MessageSize(crit) * 1.15 + 2
end

local function FloatMode() return tonumber(GetCV("floatingCombatTextFloatMode")) or 1 end

local function PositionArea()
    area:ClearAllPoints()
    area:SetPoint("CENTER", UIParent, "CENTER", db.areaX, db.areaY)
end

local function StyleMessage(m)
    local face, _, flags = FontSpec()
    m.fs:SetFont(face, MessageSize(m.crit), flags)
    if flags == "" then m.fs:SetShadowOffset(1, -1) else m.fs:SetShadowOffset(0, 0) end
end

local function PlaceMessage(m)
    local mode = FloatMode()
    local y = m.pos * (mode == 2 and -1 or 1)
    local x = m.x
    if mode == 3 then x = x + m.xDir * m.pos * 0.5 end
    m.fs:ClearAllPoints()
    if PixelUtil and PixelUtil.SetPoint then
        PixelUtil.SetPoint(m.fs, "CENTER", area, "CENTER", x, y)
    else
        -- Manual snap to whole physical pixels
        local ph = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize()) or 768
        local px = area:GetEffectiveScale() * ph / 768  -- physical pixels per unit
        m.fs:SetPoint("CENTER", area, "CENTER",
            math.floor(x * px + 0.5) / px, math.floor(y * px + 0.5) / px)
    end
end

local function Release(i)
    local m = table.remove(active, i)
    m.fs:Hide()
    m.fs:SetText("")
    pool[#pool + 1] = m.fs
end

local function OnUpdate(_, elapsed)
    local speed, dist = db.speed, db.distance
    local fadeDist = speed * db.fadeTime
    for i = #active, 1, -1 do
        local m = active[i]
        m.pos = m.pos + speed * elapsed
        if m.pos >= dist then
            Release(i)
        else
            local remain = dist - m.pos
            m.fs:SetAlpha((fadeDist > 0 and remain < fadeDist) and (remain / fadeDist) or 1)
            PlaceMessage(m)
        end
    end
    if #active == 0 then area:SetScript("OnUpdate", nil) end
end

local function Fallback(err)
    renderFailed = true
    for i = #active, 1, -1 do Release(i) end
    if CombatText then CombatText:SetAlpha(1) end
    Print("custom display failed, showing Blizzard's text instead: " .. tostring(err))
end

local function Spawn(msg, r, g, b, displayType, isStaggered)
    if renderFailed or not db then return end
    if #active >= MAX_MESSAGES then Release(1) end

    local crit = false
    if not isSecret(displayType) then crit = (displayType == "crit" or displayType == "sticky") end
    local staggered = false
    if not isSecret(isStaggered) then staggered = isStaggered and true or false end

    local fs = table.remove(pool) or area:CreateFontString(nil, "OVERLAY")
    local m = { fs = fs, crit = crit, x = staggered and math.random(-30, 30) or 0 }
    xDir = -xDir
    m.xDir = xDir
    StyleMessage(m)

    local ok, err = pcall(fs.SetText, fs, msg)
    if not ok then
        fs:Hide(); pool[#pool + 1] = fs
        Fallback(err)
        return
    end
    if not pcall(fs.SetTextColor, fs, r, g, b) then fs:SetTextColor(1, 1, 1) end

    -- Start below (or above, when scrolling down) the newest message so they
    -- never overlap; all messages move at the same speed so gaps persist.
    local lh = LineHeight(crit)
    local last = active[#active]
    m.pos = last and math.min(0, last.pos - lh) or 0

    fs:SetAlpha(1)
    fs:Show()
    active[#active + 1] = m
    PlaceMessage(m)
    area:SetScript("OnUpdate", OnUpdate)
end

local SAMPLES = {
    { "-1234",              1,   0.1,  0.1  },
    { "+856",               0.1, 1,    0.1  },
    { "+Blessing of Kings", 1,   1,    0    },
    { "Dodge",              1,   1,    1    },
    { "+45 Mana",           0,   0.44, 0.87 },
}
local sampleIndex = 0

local function SendSample()
    sampleIndex = sampleIndex % #SAMPLES + 1
    local m = SAMPLES[sampleIndex]
    Spawn(m[1], m[2], m[3], m[4], sampleIndex == 1 and "crit" or nil)
end

local function Test()
    if renderFailed then Print("custom display is off (it failed earlier); /reload to retry.") return end
    for i = 1, #SAMPLES do C_Timer.After((i - 1) * 0.3, SendSample) end
end

local PlaceMover -- forward

local function ApplyAll()
    if not db then return end
    PositionArea()
    for _, m in ipairs(active) do StyleMessage(m) end
    if mover and mover:IsShown() then PlaceMover() end
end

local function TryHook()
    if hooked or not (CombatText and CombatText.AddMessage) then return end
    -- Post-hook: runs after Blizzard's secure AddMessage returns, so nothing
    -- here taints Blizzard's code. We only read the arguments.
    hooksecurefunc(CombatText, "AddMessage", function(_, msg, _, r, g, b, displayType, isStaggered)
        Spawn(msg, r, g, b, displayType, isStaggered)
    end)
    CombatText:SetAlpha(0)
    hooked = true
end

local function Debug()
    local IsLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    Print("--- debug ---")
    Print("Blizzard_CombatText loaded: " .. tostring(IsLoaded("Blizzard_CombatText")) .. ", hooked: " .. tostring(hooked))
    Print("enable CVar: " .. tostring(Resolve("enableFloatingCombatText")) .. " = " .. tostring(GetCV("enableFloatingCombatText")))
    Print("Blizzard frame alpha: " .. tostring(CombatText and CombatText:GetAlpha()))
    Print(format("custom display failed: %s, active: %d, pooled: %d", tostring(renderFailed), #active, #pool))
    local face, size, flags = FontSpec()
    Print(format("font %s %s '%s' | area %d,%d | speed %d, distance %d, fade %.1f, mode %d",
        tostring(face), tostring(size), tostring(flags), db.areaX, db.areaY, db.speed, db.distance, db.fadeTime, FloatMode()))
end

---------------------------------------------------------------------------
-- Mover: a box covering the text path; drag it to move the area
---------------------------------------------------------------------------
local RefreshUI -- forward
local moverTicker

PlaceMover = function()
    if not mover then return end
    local lh = LineHeight()
    local mode = FloatMode()
    mover:ClearAllPoints()
    mover:SetSize(mode == 3 and (db.distance + 260) or 260, db.distance + lh)
    if mode == 2 then
        mover:SetPoint("TOP", area, "CENTER", 0, lh / 2)
    else
        mover:SetPoint("BOTTOM", area, "CENTER", 0, -lh / 2)
    end
    mover.label:SetText(format("Incoming text\n%d, %d\n|cffaaaaaadrag to move - /sctc move to lock|r",
        db.areaX, db.areaY))
end

local function BuildMover()
    local m = CreateFrame("Frame", "SCTControlMover", UIParent)
    m:SetFrameStrata("HIGH")
    m:SetMovable(true)
    m:EnableMouse(true)
    m:RegisterForDrag("LeftButton")
    m:Hide()

    local bg = m:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.8, 0.3, 0.25)
    m.label = m:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    m.label:SetPoint("CENTER")

    m:SetScript("OnDragStart", function(self)
        self.x0, self.y0 = self:GetCenter()
        self:StartMoving()
    end)
    m:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not self.x0 then return end
        local x1, y1 = self:GetCenter()
        db.areaX = math.floor(db.areaX + (x1 - self.x0) + 0.5)
        db.areaY = math.floor(db.areaY + (y1 - self.y0) + 0.5)
        self.x0 = nil
        ApplyAll()
        if RefreshUI and SCTControlFrame and SCTControlFrame:IsShown() then RefreshUI() end
    end)
    m:SetScript("OnHide", function()
        if moverTicker then moverTicker:Cancel(); moverTicker = nil end
    end)
    return m
end

local function ToggleMover()
    if mover and mover:IsShown() then
        mover:Hide()
        Print("text area locked.")
        return
    end
    mover = mover or BuildMover()
    PlaceMover()
    mover:Show()
    SendSample()
    moverTicker = C_Timer.NewTicker(0.8, SendSample)
    Print("drag the green box; sample text keeps firing until you lock it.")
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local UI
local widgets = {}
local updating = false

local function Round(v, step) return tonumber(format("%.3f", math.floor(v / step + 0.5) * step)) end

local function MakeCheck(parent, x, y, label, isOn, onClick, tip, disabledCheck)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    if tip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    cb.Refresh = function()
        if disabledCheck and disabledCheck() then
            cb:SetChecked(false); cb:Disable()
            fs:SetText(label .. " |cff808080(n/a)|r"); fs:SetTextColor(0.5, 0.5, 0.5)
            return
        end
        cb:Enable(); cb:SetChecked(isOn())
        fs:SetText(label); fs:SetTextColor(1, 1, 1)
    end
    table.insert(widgets, cb)
    return cb
end

local function MakeCVarCheck(parent, x, y, opt)
    return MakeCheck(parent, x, y, opt.label,
        function() return GetCV(opt.cvar) == "1" end,
        function(on)
            SetCVarSaved(opt.cvar, on and "1" or "0")
            if opt.cvar == "enableFloatingCombatText" and on and not hooked then
                Print("/reload if incoming text doesn't appear.")
            end
        end,
        opt.tip,
        function() return not CVarExists(opt.cvar) end)
end

local function MakeSlider(parent, x, y, opt)
    local s = CreateFrame("Slider", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    s:SetPoint("TOPLEFT", x, y)
    s:SetSize(250, 16)
    s:SetOrientation("HORIZONTAL")
    if s.SetBackdrop then
        s:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 3, right = 3, top = 6, bottom = 6 },
        })
    end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(opt.min, opt.max)
    s:SetValueStep(opt.step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)

    local title = s:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    title:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 3)
    title:SetText(opt.label)
    local valText = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    valText:SetPoint("BOTTOMRIGHT", s, "TOPRIGHT", 0, 3)

    local function show(v)
        if opt.zeroDefault and v == 0 then valText:SetText("Default")
        else valText:SetText(format(opt.fmt, v)) end
    end

    s:SetScript("OnValueChanged", function(self, v)
        v = Round(v, opt.step)
        show(v)
        if updating then return end
        if opt.cvar then
            SetCVarSaved(opt.cvar, v)
        else
            db[opt.key] = v
            ApplyAll()
        end
    end)
    s:SetScript("OnMouseWheel", function(self, d) self:SetValue(self:GetValue() + d * opt.step) end)

    s.Refresh = function()
        if opt.cvar and not CVarExists(opt.cvar) then
            s:Disable(); title:SetText(opt.label .. " |cff808080(n/a)|r")
            return
        end
        s:Enable(); title:SetText(opt.label)
        local v = opt.cvar and tonumber(GetCV(opt.cvar)) or db[opt.key] or opt.min
        updating = true
        s:SetValue(v)
        updating = false
        show(Round(v, opt.step))
    end
    table.insert(widgets, s)
    return s
end

local function MakeCycle(parent, x, y, prefix, getList, getValue, setValue, tip)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(250, 22)
    b:SetPoint("TOPLEFT", x, y)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local function index(list)
        local cur = getValue()
        for i, e in ipairs(list) do if e[2] == cur then return i end end
    end
    b.Refresh = function()
        local list = getList()
        local i = index(list)
        b:SetText(prefix .. (i and list[i][1] or "Custom"))
    end
    b:SetScript("OnClick", function(_, btn)
        local list = getList()
        local i = index(list) or 1
        if btn == "RightButton" then i = (i - 2) % #list + 1 else i = i % #list + 1 end
        setValue(list[i][2])
        ApplyAll()
        b.Refresh()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tip or "Left-click: next\nRight-click: previous", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    table.insert(widgets, b)
    return b
end

RefreshUI = function()
    for _, w in ipairs(widgets) do w.Refresh() end
end

local Reset -- forward

local function BuildUI()
    local f = CreateFrame("Frame", "SCTControlFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(600, 690)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "SCTControlFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", f, "TOP", 0, -5)
    title:SetText("SCT Control")

    local function Header(x, y, text)
        local h = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        h:SetPoint("TOPLEFT", x, y)
        h:SetText(text)
    end

    -- Left column
    local x1, y = 20, -35
    Header(x1, y, "Over your target (outgoing)"); y = y - 20
    for _, o in ipairs(TARGET_TOGGLES) do MakeCVarCheck(f, x1, y, o); y = y - 24 end
    y = y - 22
    MakeSlider(f, x1 + 5, y, { cvar = "WorldTextScale", label = "Target number size",
        min = 0.5, max = 2.5, step = 0.05, fmt = "%.2f" })
    y = y - 38
    MakeCheck(f, x1, y, "Use custom font for target numbers",
        function() return db.damageFont end,
        function(on)
            db.damageFont = on
            Print("target number font applies after logging out to character select and back in.")
        end,
        "Uses the font chosen on the right for numbers over your target. The game only reads this at login; outline can't be changed there.")

    y = y - 40
    Header(x1, y, "Incoming text display"); y = y - 36
    for _, o in ipairs(SELF_SLIDERS) do MakeSlider(f, x1 + 5, y, o); y = y - 42 end

    -- Right column
    local x2 = 310
    y = -35
    Header(x2, y, "Over your character (incoming)"); y = y - 20
    for _, o in ipairs(SELF_TOGGLES) do MakeCVarCheck(f, x2, y, o); y = y - 24 end

    y = y - 10
    local mode = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mode:SetSize(250, 22)
    mode:SetPoint("TOPLEFT", x2 + 4, y)
    mode.Refresh = function()
        if not CVarExists("floatingCombatTextFloatMode") then mode:Disable(); mode:SetText("Direction: n/a") return end
        mode:Enable()
        mode:SetText("Direction: " .. (FLOAT_MODES[FloatMode()] or FloatMode()))
    end
    mode:SetScript("OnClick", function()
        SetCVarSaved("floatingCombatTextFloatMode", FloatMode() % #FLOAT_MODES + 1)
        mode.Refresh()
        ApplyAll()
    end)
    table.insert(widgets, mode)

    y = y - 30
    MakeCycle(f, x2 + 4, y, "Font: ", GetFontList,
        function() return db.font end,
        function(v) db.font = v end,
        "Left-click: next font\nRight-click: previous\nIncludes LibSharedMedia fonts if another addon provides them.")
    y = y - 28
    MakeCycle(f, x2 + 4, y, "Outline: ", function() return OUTLINES end,
        function() return db.outline end,
        function(v) db.outline = v end)
    y = y - 30
    MakeCheck(f, x2, y, "Re-apply these settings at login",
        function() return db.enforce end,
        function(on) db.enforce = on end,
        "Pushes the settings you changed here back to the game on every login, overriding the Blizzard options panel.")

    local function Btn(text, xOff, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(110, 24)
        b:SetPoint("BOTTOM", f, "BOTTOM", xOff, 12)
        b:SetText(text)
        b:SetScript("OnClick", fn)
    end
    Btn("Test", -180, Test)
    Btn("Move", -60, ToggleMover)
    Btn("Reset", 60, function() Reset() end)
    Btn("Close", 180, function() f:Hide() end)

    f:SetScript("OnShow", function() TryHook(); RefreshUI() end)
    return f
end

---------------------------------------------------------------------------
-- Reset / events / slash
---------------------------------------------------------------------------
Reset = function()
    for cv in pairs(db.cvars) do
        local n = Resolve(cv)
        local def = GetCVDefault and n and GetCVDefault(n)
        if def then RawSetCV(n, def) end
    end
    wipe(db.cvars)
    for k, v in pairs(DEFAULTS) do if k ~= "cvars" then db[k] = v end end
    ApplyAll()
    if UI and UI:IsShown() then RefreshUI() end
    Print("reset to defaults.")
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then
            SCTControlDB = SCTControlDB or {}
            db = SCTControlDB
            for k, v in pairs(DEFAULTS) do
                if db[k] == nil then db[k] = (type(v) == "table") and {} or v end
            end
            -- Settings from older versions
            db.offsetX, db.offsetY, db.scrollTime = nil, nil, nil
            if type(db.distance) ~= "number" or db.distance < 30 then db.distance = DEFAULTS.distance end
            if type(db.fadeTime) ~= "number" then db.fadeTime = DEFAULTS.fadeTime end
            -- Read by the engine at login only
            if db.damageFont and db.font ~= "" then DAMAGE_TEXT_FONT = db.font end
            PositionArea()
            TryHook()
        elseif name == "Blizzard_CombatText" and db then
            TryHook()
        end
    elseif event == "PLAYER_LOGIN" then
        if db.enforce then
            for cv, val in pairs(db.cvars) do
                if CVarExists(cv) then SetCV(cv, val) end
            end
        end
        TryHook()
    end
end)

SLASH_SCTCONTROL1 = "/sctc"
SLASH_SCTCONTROL2 = "/sctcontrol"
SlashCmdList.SCTCONTROL = function(msg)
    msg = strlower(strtrim(msg or ""))
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if cmd == "cvars" then DumpCVars(arg)
    elseif cmd == "debug" then Debug()
    elseif cmd == "test" then Test()
    elseif cmd == "move" then ToggleMover()
    elseif cmd == "reset" then Reset()
    else
        UI = UI or BuildUI()
        UI:SetShown(not UI:IsShown())
    end
end
