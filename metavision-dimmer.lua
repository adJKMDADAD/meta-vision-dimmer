--[[ METAVISION DIMMER - Azure Latch (Nel Isagi)

    Nel's T special, Metavision, clones a grid model into workspace.Effects
    under the name "SUPER METAVISION" and then lerps Lighting toward a blue
    wash. That model is mostly glare: 21 ParticleEmitters, 20 neon Piece3
    parts and 2 Beams. This script keeps the ball path readable and removes
    the blinding part.

    WHAT IT DOES
      - ParticleEmitters inside the Metavision model are switched off
      - every light inside it (PointLight / SpotLight / SurfaceLight) is off
      - neon piece parts are pushed toward high transparency
      - beams are kept but faded, so the ball path is still visible (BEAM)
      - Lighting.Ambient / OutdoorAmbient are pulled back toward the values
        the game had before the cast instead of the full blue wash (WASH)
      - the exposure dip the effect opens with is cancelled, never deepened
        (LIFT), so the screen does not go dark
      - Bloom / ColorCorrection / SunRays / DepthOfField are clamped while
        the effect is up
      - Highlights are never touched, so anything the special reveals stays
        visible

    HOW IT HOOKS
      nelisagiVFX.peterTingle is the function that builds the effect. It is
      also reachable as replication.peterTingle, because the client merges its
      VFX modules into that table. The hook only marks the effect active; all
      dimming happens in one RenderStepped pass afterwards, so it does not
      fight the game's own tween frame by frame until it has to.

    CONTROLS
      DIMMER      master on/off, off restores lighting immediately
      VFX CUT     puzzles / particles / lights / glow removed, 0 keeps the effect
      PUZZLES     how transparent Design.Puzzles becomes (100 = invisible)
      BEAM        how visible the ball path beam stays (0 = gone)
      WASH        how much of the blue lighting wash is removed
      LIFT        how much of the exposure dip is cancelled (100 = fully flat)
      BOTH ISAGI  also tame Rin's isagimetavision container if it shows up
      UNLOAD      restore hooks, restore lighting, remove the panel

    Console: _G.MetaDim.Report()  _G.MetaDim.Set(vfx, beam, wash, dark, puzzles)
             _G.MetaDim.Unload()
]]--

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local Lighting          = game:GetService("Lighting")
local LocalPlayer       = Players.LocalPlayer

local CONFIG = {
    Enabled   = true,
    VfxCut    = 85,    -- percent of particles / lights / glow removed
    Puzzles   = 95,    -- puzzle transparency: 0 untouched, 100 invisible
    Beam      = 25,    -- percent of beam visibility kept (ball path)
    Wash      = 85,    -- percent of the blue lighting wash removed
    Lift      = 70,    -- percent of the effect's exposure dip cancelled
    BothIsagi = true,  -- also tame Rin's metavision container
    NoFlash   = true,  -- use the game's own epilepsysafe setting: no ultFlash
    Debug     = true,
    EffectMs  = 6000,  -- how long the pass keeps enforcing after a cast
}

local MD = {
    Unloaded = false,
    Active = false,
    ActiveUntil = 0,
    Tracked = {},
    Hooks = {},
    RenderConn = nil,
    Gui = nil, Panel = nil,
    Sliders = {}, Toggles = {},
    Collapsed = false,
    Hits = 0,
    Base = nil,
}

local function log(t) print("[MVD] " .. tostring(t)) end
local function dbg(t) if CONFIG.Debug then print("[MVD][dbg] " .. tostring(t)) end end

function MD.CaptureBase()
    if MD.Base then return end
    MD.Base = {
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        Exposure = Lighting.ExposureCompensation,
        ClockTime = Lighting.ClockTime,
    }
    dbg(string.format("baseline exposure %.2f", MD.Base.Exposure))
end

function MD.RestoreLighting()
    if not MD.Base then return end
    pcall(function()
        Lighting.Ambient = MD.Base.Ambient
        Lighting.OutdoorAmbient = MD.Base.OutdoorAmbient
        Lighting.ExposureCompensation = MD.Base.Exposure
    end)
end

-- The blinding part of the cast is not the model, it is ultFlash:
--   ultFlash(0.5, 1, nil, Color3.new(0, 0, 1))
-- which clones a ColorCorrection with Brightness 0.5 and a full screen
-- BlurEffect, then fades them over a second. The game skips all of that when
-- LocalPlayer.setting.epilepsysafe is true, so switch that on instead of trying
-- to fight the flash after it starts.
function MD.ApplyNoFlash(on)
    local player = LocalPlayer
    if not player then return end
    local folder = player:FindFirstChild("setting")
    if not folder then return end

    local flag = folder:FindFirstChild("epilepsysafe")
    if on then
        if not flag then
            flag = Instance.new("BoolValue")
            flag.Name = "epilepsysafe"
            flag.Parent = folder
        end
        if MD.NoFlashOrig == nil then MD.NoFlashOrig = flag.Value end
        flag.Value = true
    else
        if flag and MD.NoFlashOrig ~= nil then flag.Value = MD.NoFlashOrig end
        MD.NoFlashOrig = nil
    end
end

-- ============================================================= containers ==

local function isMetaName(name)
    local n = string.lower(tostring(name))
    if string.find(n, "metavision", 1, true) then return true end
    if string.find(n, "super senses", 1, true) then return true end
    return false
end

function MD.Scan()
    local fx = workspace:FindFirstChild("Effects")
    local char = LocalPlayer.Character
    local buckets = { workspace }
    if fx then table.insert(buckets, fx) end
    if char then table.insert(buckets, char) end

    for _, bucket in ipairs(buckets) do
        for _, child in ipairs(bucket:GetChildren()) do
            local wanted = isMetaName(child.Name)
            if wanted and not CONFIG.BothIsagi then
                if not string.find(string.lower(child.Name), "metavision", 1, true) then
                    wanted = false
                end
            end
            if wanted then
                local fresh = MD.Tracked[child] == nil
                MD.Tracked[child] = MD.Tracked[child] or { instances = {}, builtAt = 0 }
                if fresh then MD.CastAt = tick() end
                MD.Active = true
                MD.ActiveUntil = math.max(MD.ActiveUntil, tick() + CONFIG.EffectMs / 1000)
            end
        end
    end
end

function MD.Refresh(container)
    local rec = MD.Tracked[container]
    if not rec then return nil end
    local now = tick()
    if rec.builtAt and (now - rec.builtAt) < 1 and #rec.instances > 0 then
        return rec.instances
    end
    rec.builtAt = now
    rec.instances = container:GetDescendants()
    return rec.instances
end

-- true when the object lives inside Design.Puzzles or is one of the puzzle
-- pieces. Nel's own render loop fades these to 0.5 .. 1 every frame, so they
-- are the part of the effect that stays bright the longest.
local function isPuzzle(obj)
    local n = string.lower(obj.Name)
    if string.find(n, "piece", 1, true) then return true end
    local node = obj
    for _ = 1, 4 do
        node = node.Parent
        if not node then return false end
        local p = string.lower(node.Name)
        if string.find(p, "puzzle", 1, true) or string.find(p, "piece", 1, true) then
            return true
        end
    end
    return false
end

function MD.Tame(instances, cut, beamKeep, puzzleAlpha)
    if not instances then return end
    local kill = cut >= 0.5
    local partAlpha = 0.60 + (0.85 - 0.60) * cut      -- 0.60 untouched -> 0.85 at full cut
    local beamAlpha = math.clamp(1 - beamKeep, 0, 1)  -- beamKeep 1 -> invisible
    puzzleAlpha = math.clamp(puzzleAlpha or 0, 0, 1)   -- 1 -> fully invisible

    -- Nel's effect forces ParticleEmitter.Enabled back to true every frame, so
    -- Enabled is useless as a switch. Rate, Lifetime, Transparency and beam
    -- width are not touched by the game and do hold.
    --
    -- Puzzle pieces are the exception: the effect rewrites their Transparency
    -- every frame (0.6 -> 1 -> back), so writing Transparency from here every
    -- frame fights it and the pieces visibly flicker. LocalTransparencyModifier
    -- is client-only, is never written by the game, and multiplies on top of
    -- Transparency, so the value holds and nothing alternates.
    MD.Orig = MD.Orig or setmetatable({}, { __mode = "k" })

    local key = string.format("%.3f|%.3f|%.3f", cut, beamKeep, puzzleAlpha)
    if MD.DoneKey ~= key then
        MD.DoneKey = key
        MD.Done = setmetatable({}, { __mode = "k" })
    end
    local done = MD.Done or setmetatable({}, { __mode = "k" })
    MD.Done = done

    for _, obj in ipairs(instances) do
        if obj.Parent ~= nil and not done[obj] then
            local puzzle = false
            pcall(function() puzzle = isPuzzle(obj) end)
            local ok = pcall(function()
                if obj:IsA("ParticleEmitter") then
                    obj.Enabled = false
                    if kill then
                        obj.Rate = 0
                        obj.Lifetime = NumberRange.new(0)
                        obj.Transparency = NumberSequence.new(1)
                    else
                        local hidden = puzzle and puzzleAlpha or cut
                        obj.Transparency = NumberSequence.new(math.clamp(hidden, 0, 1))
                    end
                elseif obj:IsA("Beam") or obj:IsA("Trail") then
                    local orig = MD.Orig[obj]
                    if not orig then
                        orig = { w0 = obj.Width0, w1 = obj.Width1 }
                        MD.Orig[obj] = orig
                    end
                    local keepBeam = puzzle and (1 - puzzleAlpha) or (1 - beamAlpha)
                    obj.Width0 = orig.w0 * keepBeam
                    obj.Width1 = orig.w1 * keepBeam
                    if kill then obj.Enabled = false end
                elseif obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight") then
                    if kill then
                        obj.Enabled = false
                        obj.Brightness = 0
                    end
                elseif obj:IsA("ForceField") then
                    if kill then obj.Visible = false end
                elseif obj:IsA("BasePart") then
                    local target = partAlpha
                    if puzzle and puzzleAlpha > target then target = puzzleAlpha end
                    obj.LocalTransparencyModifier = target
                end
                -- Highlights and everything else are left alone on purpose:
                -- they are what the special actually reveals
            end)
            if ok then done[obj] = true end
        end
    end
end

-- =============================================================== lighting ==

function MD.ClampLighting(wash, lift)
    if not MD.Base then return end
    local keep = 1 - math.clamp(wash, 0, 1)
    lift = math.clamp(lift or 0, 0, 1)

    -- The effect's own loop writes Ambient / ExposureCompensation after every
    -- render step callback, so a sampled exposure inside this pass still reads
    -- the pre-tween value (it looks like there is no dip at all), while the
    -- frame the player sees is already darkened. Drive the lift from the cast
    -- clock instead: the effect opens at -1 and ramps back over 1 second.
    local observed = Lighting.ExposureCompensation
    local drop = math.max(0, MD.Base.Exposure - observed)
    local phase = math.clamp((tick() - (MD.CastAt or 0)) / 1.1, 0, 1)
    local clockDrop = 1.15 * (1 - phase)
    local liftAmount = math.clamp(math.max(drop, clockDrop) * lift * 0.42, 0, 0.55)

    pcall(function()
        Lighting.Ambient = Lighting.Ambient:Lerp(MD.Base.Ambient, 1 - keep)
        Lighting.OutdoorAmbient = Lighting.OutdoorAmbient:Lerp(MD.Base.OutdoorAmbient, 1 - keep)
    end)

    if not MD.LiftCC then
        local cc = Instance.new("ColorCorrectionEffect")
        cc.Name = "MVD_Lift"
        cc.Parent = Lighting
        MD.LiftCC = cc
    end

    -- Metavision starts at ExposureCompensation -1 and ramps back over a second,
    -- which reads as the screen dipping dark. Exposure writes are overwritten by
    -- the effect, so cancel that dip with a ColorCorrection instead: read how far
    -- the exposure currently sits below the pre-cast value and lift the image by
    -- the same amount. Nothing here ever makes the frame darker.
    pcall(function()
        local c = MD.LiftCC
        c.Enabled = true
        c.Brightness = liftAmount
        c.Contrast = 0
        c.Saturation = -0.04
        c.TintColor = Color3.fromRGB(255, 255, 255)
    end)

    for _, child in ipairs(Lighting:GetChildren()) do
        pcall(function()
            if child:IsA("BloomEffect") then
                child.Intensity = math.min(child.Intensity, 0.18 + (1 - wash) * 0.3)
            elseif child:IsA("ColorCorrectionEffect") and child ~= MD.LiftCC then
                -- flashes add their own correction at Brightness 0.5 or higher;
                -- only ever cap the bright ones, never darken anything
                if child.Brightness > 0.2 then child.Brightness = 0.2 end
                if child.Contrast > 0.12 then child.Contrast = 0.12 end
            elseif child:IsA("BlurEffect") then
                if child.Size > 8 then child.Size = 8 end
            elseif child:IsA("SunRaysEffect") then
                child.Intensity = math.min(child.Intensity, 0.06)
            elseif child:IsA("DepthOfFieldEffect") then
                child.FarIntensity = math.min(child.FarIntensity, 0.15)
            end
        end)
    end
end

-- ================================================================== hooks ==

function MD.Hook()
    local hooked = 0
    local function wrap(tableRef, key)
        if type(tableRef) ~= "table" or type(tableRef[key]) ~= "function" then return end
        local original = tableRef[key]
        MD.Hooks[#MD.Hooks + 1] = { table = tableRef, key = key, original = original }
        local wrapped = function(...)
            MD.Hits = MD.Hits + 1
            MD.Active = true
            MD.CastAt = tick()
            MD.ActiveUntil = tick() + CONFIG.EffectMs / 1000
            local res = table.pack(original(...))
            -- tame in the same frame the effect is built, before it is ever
            -- rendered, so the opening flash cannot show at full strength
            pcall(MD.Pass)
            -- peterTingle builds its own RenderStepped connection inside the
            -- call, so reconnecting ours afterwards guarantees the dimming
            -- pass runs after the game's tween instead of before it
            pcall(MD.StartLoop)
            return table.unpack(res, 1, res.n)
        end
        if newcclosure then
            local okc, cc = pcall(newcclosure, wrapped)
            tableRef[key] = (okc and type(cc) == "function") and cc or wrapped
        else
            tableRef[key] = wrapped
        end
        hooked = hooked + 1
    end

    local ok, nel = pcall(function()
        return require(ReplicatedStorage.client.replication.otherReplication.nelisagiVFX)
    end)
    if ok then wrap(nel, "peterTingle") end

    local ok2, rep = pcall(function() return require(ReplicatedStorage.client.replication) end)
    if ok2 and rep ~= nel then wrap(rep, "peterTingle") end

    if hooked > 0 then
        log(string.format("hooked peterTingle (%d reference%s)", hooked, hooked == 1 and "" or "s"))
    else
        log("peterTingle not found - running as a live scan only")
    end
    return hooked > 0
end

function MD.Unhook()
    for _, h in ipairs(MD.Hooks) do
        pcall(function() h.table[h.key] = h.original end)
    end
    MD.Hooks = {}
end

-- =================================================================== loop ==

function MD.Pass()
    if MD.Unloaded or not CONFIG.Enabled then return end

    MD.Scan()

    local now = tick()
    local anyContainer = false
    for container in pairs(MD.Tracked) do
        if container.Parent == nil then
            MD.Tracked[container] = nil
        else
            anyContainer = true
            MD.Tame(MD.Refresh(container), CONFIG.VfxCut / 100, CONFIG.Beam / 100,
                CONFIG.Puzzles / 100)
        end
    end

    if anyContainer or now < MD.ActiveUntil then
        MD.ClampLighting(CONFIG.Wash / 100, CONFIG.Lift / 100)
        MD.Active = true
    elseif MD.Active then
        MD.Active = false
        MD.RestoreLighting()
        pcall(function()
            if MD.LiftCC then
                MD.LiftCC.Brightness = 0
                MD.LiftCC.Contrast = 0
                MD.LiftCC.Saturation = 0
                MD.LiftCC.Enabled = false
            end
        end)
        dbg("effect over - lighting restored, dim filter off")
    end
end

function MD.StartLoop()
    -- A named BindToRenderStep binding is scoped to this executor script and
    -- survives a reload of the same file, so a stale unloaded instance can keep
    -- the name and the fresh one never runs. A plain connection is owned by the
    -- instance that made it and always fires. Ordering is no longer needed: the
    -- levers used here (emitter rate/lifetime, beam width, part transparency,
    -- and the ColorCorrection) are not written by the effect, so nothing has to
    -- win a race.
    if MD.RenderConn then
        pcall(function() MD.RenderConn:Disconnect() end)
        MD.RenderConn = nil
    end
    MD.RenderConn = RunService.RenderStepped:Connect(function()
        if MD.Unloaded then return end
        local ok, err = pcall(MD.Pass)
        if not ok then log("pass error: " .. tostring(err)) end
    end)
    MD.Priority = "renderstepped"
end

-- ==================================================================== gui ==

local C_BG    = Color3.fromRGB(10, 11, 16)
local C_ROW   = Color3.fromRGB(22, 24, 32)
local C_TRACK = Color3.fromRGB(34, 37, 48)
local C_TEXT  = Color3.fromRGB(232, 234, 242)
local C_FILL  = Color3.fromRGB(120, 170, 255)
local C_BTN   = Color3.fromRGB(38, 40, 52)
local C_ON    = Color3.fromRGB(40, 110, 70)
local C_GREEN = Color3.fromRGB(120, 255, 150)
local C_OFF   = Color3.fromRGB(120, 45, 50)

local function corner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 4)
    c.Parent = p
end

function MD.MakeSlider(parent, y, text, lo, hi, getv, setv)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -12, 0, 26)
    row.Position = UDim2.new(0, 6, 0, y)
    row.BackgroundColor3 = C_ROW
    row.BorderSizePixel = 0
    row.Parent = parent
    corner(row, 4)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0, 96, 1, 0)
    label.Position = UDim2.new(0, 8, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.TextSize = 11
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = C_TEXT
    label.Text = text
    label.Parent = row

    local track = Instance.new("Frame")
    track.Size = UDim2.new(0, 104, 0, 6)
    track.Position = UDim2.new(0, 108, 0.5, -3)
    track.BackgroundColor3 = C_TRACK
    track.BorderSizePixel = 0
    track.Parent = row
    corner(track, 3)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = C_FILL
    fill.BorderSizePixel = 0
    fill.Parent = track
    corner(fill, 3)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 8, 1, 8)
    knob.Position = UDim2.new(0, 0, 0, -4)
    knob.BackgroundColor3 = Color3.fromRGB(240, 240, 250)
    knob.BorderSizePixel = 0
    knob.ZIndex = 3
    knob.Parent = track
    corner(knob, 4)

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0, 46, 0, 18)
    box.Position = UDim2.new(1, -54, 0.5, -9)
    box.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
    box.BorderSizePixel = 0
    box.Font = Enum.Font.Code
    box.TextSize = 11
    box.TextColor3 = C_TEXT
    box.ClearTextOnFocus = false
    box.TextXAlignment = Enum.TextXAlignment.Center
    box.Text = tostring(math.floor(getv()))
    box.Parent = row
    corner(box, 3)

    local def = { get = getv, set = setv, fill = fill, knob = knob, box = box,
                  min = lo, max = hi }

    function def.paint()
        local v = def.get()
        local frac = 0
        if def.max > def.min then frac = (v - def.min) / (def.max - def.min) end
        frac = math.clamp(frac, 0, 1)
        fill.Size = UDim2.new(frac, 0, 1, 0)
        knob.Position = UDim2.new(frac, -4, 0, -4)
        box.Text = tostring(math.floor(v))
    end

    local dragging = false
    local function apply(x)
        local w = track.AbsoluteSize.X
        if w <= 0 then return end
        local frac = math.clamp((x - track.AbsolutePosition.X) / w, 0, 1)
        def.set(math.floor(def.min + frac * (def.max - def.min) + 0.5))
        def.paint()
    end

    local function down(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            apply(input.Position.X)
        end
    end

    track.InputBegan:Connect(down)
    knob.InputBegan:Connect(down)
    row.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then apply(i.Position.X) end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            apply(i.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if not n then def.paint() return end
        def.set(math.clamp(math.floor(n), def.min, def.max))
        def.paint()
    end)

    def.paint()
    table.insert(MD.Sliders, def)
end

function MD.MakeToggle(parent, y, text, getv, setv)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -12, 0, 26)
    row.Position = UDim2.new(0, 6, 0, y)
    row.BackgroundColor3 = C_ROW
    row.BorderSizePixel = 0
    row.Parent = parent
    corner(row, 4)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0, 170, 1, 0)
    label.Position = UDim2.new(0, 8, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.TextSize = 11
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = C_TEXT
    label.Text = text
    label.Parent = row

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 54, 0, 18)
    btn.Position = UDim2.new(1, -62, 0.5, -9)
    btn.BackgroundColor3 = C_BTN
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.Code
    btn.TextSize = 11
    btn.TextColor3 = C_TEXT
    btn.Text = "OFF"
    btn.Parent = row
    corner(btn, 4)

    local def = { get = getv, set = setv }
    function def.paint()
        local on = def.get() and true or false
        btn.Text = on and "ON" or "OFF"
        btn.BackgroundColor3 = on and C_ON or C_BTN
        btn.TextColor3 = on and C_GREEN or C_TEXT
    end
    btn.MouseButton1Click:Connect(function()
        def.set(not def.get())
        def.paint()
    end)
    def.paint()
    table.insert(MD.Toggles, def)
end

function MD.PaintSliders()
    for i = 1, #MD.Sliders do pcall(MD.Sliders[i].paint) end
    for i = 1, #MD.Toggles do pcall(MD.Toggles[i].paint) end
end

function MD.BuildGui()
    if MD.Gui then return end
    pcall(function()
        local HEIGHT = 304
        local sg = Instance.new("ScreenGui")
        sg.Name = "MetaVisionDimmer"
        sg.ResetOnSpawn = false
        sg.DisplayOrder = 2147482400
        local placed = false
        if gethui then pcall(function() sg.Parent = gethui() placed = true end) end
        if not placed then
            sg.Parent = LocalPlayer:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
        end

        local panel = Instance.new("Frame")
        panel.Size = UDim2.new(0, 268, 0, HEIGHT)
        panel.Position = UDim2.new(0, 14, 0, 430)
        panel.BackgroundColor3 = C_BG
        panel.BackgroundTransparency = 0.1
        panel.BorderSizePixel = 0
        panel.Active = true
        panel.Parent = sg
        corner(panel, 6)

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -78, 0, 22)
        title.Position = UDim2.new(0, 8, 0, 2)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.Code
        title.TextSize = 12
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.TextColor3 = C_TEXT
        title.Text = "NEL T - METAVISION DIMMER"
        title.Parent = panel

        local hide = Instance.new("TextButton")
        hide.Size = UDim2.new(0, 46, 0, 18)
        hide.Position = UDim2.new(1, -52, 0, 4)
        hide.BackgroundColor3 = C_BTN
        hide.BorderSizePixel = 0
        hide.Font = Enum.Font.Code
        hide.TextSize = 10
        hide.TextColor3 = C_TEXT
        hide.Text = "HIDE"
        hide.Parent = panel
        corner(hide, 4)

        local body = Instance.new("Frame")
        body.Size = UDim2.new(1, 0, 1, -26)
        body.Position = UDim2.new(0, 0, 0, 26)
        body.BackgroundTransparency = 1
        body.Parent = panel

        MD.MakeToggle(body, 0, "DIMMER", function() return CONFIG.Enabled end,
            function(v)
                CONFIG.Enabled = v
                if not v then MD.RestoreLighting() end
            end)
        MD.MakeSlider(body, 30, "VFX CUT", 0, 100,
            function() return CONFIG.VfxCut end,
            function(v) CONFIG.VfxCut = v end)
        MD.MakeSlider(body, 60, "PUZZLES", 0, 100,
            function() return CONFIG.Puzzles end,
            function(v) CONFIG.Puzzles = v end)
        MD.MakeSlider(body, 90, "BEAM", 0, 100,
            function() return CONFIG.Beam end,
            function(v) CONFIG.Beam = v end)
        MD.MakeSlider(body, 120, "WASH", 0, 100,
            function() return CONFIG.Wash end,
            function(v) CONFIG.Wash = v end)
        MD.MakeSlider(body, 150, "LIFT", 0, 100,
            function() return CONFIG.Lift end,
            function(v) CONFIG.Lift = v end)
        MD.MakeToggle(body, 180, "BOTH ISAGI (RIN)",
            function() return CONFIG.BothIsagi end,
            function(v) CONFIG.BothIsagi = v end)
        MD.MakeToggle(body, 210, "NO FLASH (GAME SETTING)",
            function() return CONFIG.NoFlash end,
            function(v)
                CONFIG.NoFlash = v
                MD.ApplyNoFlash(v)
            end)

        local unload = Instance.new("TextButton")
        unload.Size = UDim2.new(1, -12, 0, 24)
        unload.Position = UDim2.new(0, 6, 0, 242)
        unload.BackgroundColor3 = C_OFF
        unload.BorderSizePixel = 0
        unload.Font = Enum.Font.Code
        unload.TextSize = 11
        unload.TextColor3 = Color3.fromRGB(255, 235, 235)
        unload.Text = "UNLOAD"
        unload.Parent = body
        corner(unload, 4)
        unload.MouseButton1Click:Connect(function() MD.Unload() end)

        hide.MouseButton1Click:Connect(function()
            MD.Collapsed = not MD.Collapsed
            body.Visible = not MD.Collapsed
            panel.Size = UDim2.new(0, 268, 0, MD.Collapsed and 26 or HEIGHT)
            hide.Text = MD.Collapsed and "SHOW" or "HIDE"
        end)

        local dragging, startPos, basePos = false, nil, nil
        title.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                dragging, startPos, basePos = true, i.Position, panel.Position
            end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if not dragging then return end
            if i.UserInputType == Enum.UserInputType.MouseMovement
                or i.UserInputType == Enum.UserInputType.Touch then
                local d = i.Position - startPos
                panel.Position = UDim2.new(basePos.X.Scale, basePos.X.Offset + d.X,
                                           basePos.Y.Scale, basePos.Y.Offset + d.Y)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)

        MD.Gui, MD.Panel = sg, panel
    end)
end

-- ================================================================== public =

function MD.Report()
    local n = 0
    for _ in pairs(MD.Tracked) do n = n + 1 end
    log(string.format("enabled=%s active=%s casts=%d live_containers=%d",
        tostring(CONFIG.Enabled), tostring(MD.Active), MD.Hits, n))
    log(string.format("vfx cut=%d%% puzzles=%d%% beam=%d%% wash=%d%% lift=%d%% both=%s",
        CONFIG.VfxCut, CONFIG.Puzzles, CONFIG.Beam, CONFIG.Wash, CONFIG.Lift, tostring(CONFIG.BothIsagi)))
    if MD.Base then
        local drop = math.max(0, MD.Base.Exposure - Lighting.ExposureCompensation)
        local phase = math.clamp((tick() - (MD.CastAt or 0)) / 1.1, 0, 1)
        log(string.format("baseline exposure %.2f, sampled %.2f (dip %.2f), cast phase %.2f, lift %.2f",
            MD.Base.Exposure, Lighting.ExposureCompensation, drop, phase,
            math.clamp(math.max(drop, 1.15 * (1 - phase)) * (CONFIG.Lift / 100) * 0.42, 0, 0.55)))
    end
end

function MD.Set(vfx, beam, wash, lift, puzzles)
    if vfx then CONFIG.VfxCut = math.clamp(vfx, 0, 100) end
    if beam then CONFIG.Beam = math.clamp(beam, 0, 100) end
    if wash then CONFIG.Wash = math.clamp(wash, 0, 100) end
    if lift then CONFIG.Lift = math.clamp(lift, 0, 100) end
    if puzzles then CONFIG.Puzzles = math.clamp(puzzles, 0, 100) end
    MD.PaintSliders()
    MD.Report()
end

function MD.Unload()
    if MD.Unloaded then return end
    MD.Unloaded = true
    pcall(MD.Unhook)
    pcall(MD.RestoreLighting)
    pcall(MD.ApplyNoFlash, false)
    pcall(function()
        if MD.LiftCC then MD.LiftCC:Destroy() end
    end)
    MD.LiftCC = nil
    pcall(function() RunService:UnbindFromRenderStep("MVD_Pass") end)
    pcall(function()
        if type(MD.RenderConn) == "RBXScriptConnection" then MD.RenderConn:Disconnect() end
    end)
    MD.RenderConn = nil
    pcall(function()
        if MD.LiftCC then MD.LiftCC.Enabled = false end
    end)
    pcall(function() if MD.Gui then MD.Gui:Destroy() end end)
    MD.Gui, MD.Panel = nil, nil
    if _G.MetaDim == MD then _G.MetaDim = nil end
    print("[MVD] unloaded - hooks restored, lighting restored, panel removed")
end

-- ================================================================= startup =

_G.MetaDim = MD
MD.Config = CONFIG
MD.CONFIG = CONFIG

MD.CaptureBase()
MD.BuildGui()
MD.Hook()
MD.StartLoop()
if CONFIG.NoFlash then MD.ApplyNoFlash(true) end

log("ready - VFX CUT 85, PUZZLES 95, BEAM 25, WASH 85, LIFT 70, NO FLASH on")
log("cast Nel T, then _G.MetaDim.Report() shows state; UNLOAD in the panel")
