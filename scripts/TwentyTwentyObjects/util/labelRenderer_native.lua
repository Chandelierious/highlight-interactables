-- labelRenderer_native.lua: Native Morrowind-style label rendering
-- Matches the exact appearance of vanilla tooltips and hover text

local ui = require('openmw.ui')
local util = require('openmw.util')
local core = require('openmw.core')

local M = {}

-- Helper for creating colors
local col = util.color.rgb

-- Morrowind's native tooltip style constants
local NATIVE_STYLE = {
    -- Background color: dark blue-gray (matches MW tooltips)
    backgroundColor = col(0.075, 0.09, 0.11, 0.95),  -- Nearly opaque
    
    -- Border color: lighter blue-gray 
    borderColor = col(0.15, 0.18, 0.22, 1.0),
    borderSize = 1,
    
    -- Text color: yellowish white (MW's signature text)
    textColor = col(0.87, 0.87, 0.76, 1.0),
    
    -- Padding matches vanilla tooltips
    padding = {
        horizontal = 8,
        vertical = 4
    },
    
    -- Font: Magic Cards (default MW font)
    -- Text size follows UI scaling
    baseTextSize = 16  -- Will be scaled by UI settings
}

-- Get user's UI scaling factor (matches the "UI Scale Correction" setting,
-- which the user sets to their OpenMW GUI scaling factor)
function M.getUIScale()
    local storage_module = require('scripts.TwentyTwentyObjects.util.storage')
    local appearance = storage_module.get('appearance', { guiScale = 100 })
    return (appearance.guiScale or 100) / 100
end

-- Text label style from the Appearance settings.
-- NOTE: the original mod's "Label opacity" slider stored appearance.opacity
-- but nothing ever read it — it was a dead control. It is consumed here now.
function M.getTextStyle()
    local storage_module = require('scripts.TwentyTwentyObjects.util.storage')
    local appearance = storage_module.get('appearance', {})
    -- tonumber-guarded: the ORIGINAL mod defined appearance.textSize as a
    -- STRING preset ("medium"), which is why the numeric size setting lives
    -- under labelTextSize. Never assume stored values are numbers.
    return {
        opacity = tonumber(appearance.opacity) or 0.8,
        sizeFactor = (tonumber(appearance.labelTextSize) or 100) / 100,
    }
end

-- Create a native Morrowind-style label
function M.createNativeLabel(text, options)
    options = options or {}
    
    local scale = M.getUIScale()
    local textStyle = M.getTextStyle()
    local textSize = NATIVE_STYLE.baseTextSize * scale * textStyle.sizeFactor
    
    -- Apply distance-based sizing if requested
    if options.distanceScale then
        textSize = textSize * options.distanceScale
    end
    
    -- Debug logging
    local logger = require('scripts.TwentyTwentyObjects.util.logger')
    logger.debug(string.format('Creating label: text="%s", pos=%s, alpha=%s', 
        text, tostring(options.position), tostring(options.alpha)))
    
    -- Create the tooltip-style container
    local labelLayout = {
        layer = 'HUD',
        type = ui.TYPE.Container,
        props = {
            -- Positioning
            anchor = util.vector2(0.5, 0.5),  -- Center-center anchor
            position = options.position or util.vector2(0, 0),
            
            -- Native tooltip appearance
            backgroundColor = NATIVE_STYLE.backgroundColor,
            borderColor = NATIVE_STYLE.borderColor, 
            borderSize = NATIVE_STYLE.borderSize,
            
            -- Padding
            padding = {
                horizontal = NATIVE_STYLE.padding.horizontal,
                vertical = NATIVE_STYLE.padding.vertical
            },
            
            -- Visibility - start visible for debugging
            visible = true,  -- Always visible for now
            alpha = (options.alpha or 1.0) * textStyle.opacity
        },
        content = ui.content({
            {
                type = ui.TYPE.Text,
                props = {
                    text = text,
                    textSize = textSize,
                    textColor = NATIVE_STYLE.textColor,
                    -- Use the same font as Morrowind tooltips
                    font = "Magic_Cards_Regular"  -- If available
                }
            }
        })
    }
    
    local element = ui.create(labelLayout)
    logger.debug(string.format('Label created: %s', tostring(element)))
    return element
end

-- Outline/glow highlight: a single ui.TYPE.Image per object using a radial
-- gradient texture (textures/tto_soft_glow.png, shipped with this mod),
-- tinted via the documented `color` prop — a soft circular glow centered on
-- the object rather than a hard box.
--
-- WHY IMAGES (and not Containers): on this engine build, Containers render at
-- their content-measured size and IGNORE explicit `size` (OpenMW issue #7848)
-- — an empty Container with size set renders at 0x0, invisible. In-game
-- diagnostics confirmed this. The Image widget has `resource`, `color`, and
-- `size` as *documented* props with no content-based auto-sizing, so explicit
-- sizes actually apply.
local GLOW_TEXTURE = ui.texture { path = 'textures/tto_soft_glow.png' }

-- Named color presets exposed in the settings menu.
M.GLOW_COLORS = {
    cyan   = col(0.4, 0.85, 1.0),
    white  = col(1.0, 1.0, 1.0),
    gold   = col(1.0, 0.85, 0.4),
    green  = col(0.5, 1.0, 0.55),
    red    = col(1.0, 0.45, 0.4),
    purple = col(0.8, 0.5, 1.0),
}

local OUTLINE_STYLE = {
    glowColor = M.GLOW_COLORS.cyan,   -- default tint
    glowScale = 1.7,                  -- glow diameter relative to the object's larger screen dimension, at size 100%
    baseAlpha = 0.8,                  -- glow alpha at full label alpha and opacity 100%... see below
    minDiameter = 48,                 -- so small/distant objects still get a visible glow
    maxDiameter = 900,
}

-- Glow diameter in pixels. Prefers the object's WORLD bbox diagonal
-- (distance- and orientation-independent, so the glow is a stable UI marker
-- like the text labels: bigger objects get bigger circles, but approaching an
-- object doesn't balloon it). Falls back to the projected screen box only
-- when no world size is available.
function M.computeGlowDiameter(worldDiag, projectedSize, sizeFactor)
    local d
    if worldDiag and worldDiag > 0 then
        -- Gentle sublinear curve: rat (~70u) ≈ 70px, NPC (~200u) ≈ 130px,
        -- crate (~90u) ≈ 80px at 100% size.
        d = 24 + math.sqrt(worldDiag) * 7.5
    elseif projectedSize then
        d = math.sqrt(projectedSize.x * projectedSize.y) * OUTLINE_STYLE.glowScale
    else
        d = 60
    end
    d = d * (sizeFactor or 1.0)
    return math.max(OUTLINE_STYLE.minDiameter, math.min(d, OUTLINE_STYLE.maxDiameter))
end

-- style = { color = util.color, sizeFactor = number (1.0 = default), opacity = number (0..1) }
local function glowGeometry(center, size, sizeFactor, worldDiag)
    local d = M.computeGlowDiameter(worldDiag, size, sizeFactor)
    return {
        pos = util.vector2(center.x - d / 2, center.y - d / 2),
        size = util.vector2(d, d),
    }
end

-- Create a glow highlight. `options.position` (screen-space vector2) is the
-- glow CENTER, `options.size` (vector2) is the object's on-screen extents.
-- Optional style overrides: options.color (util.color), options.sizeFactor
-- (1.0 = default size), options.opacity (0..1, replaces the default 0.8).
-- Returns { glow = Element }.
function M.createOutlineBox(options)
    options = options or {}
    local size = options.size or util.vector2(60, 60)
    local center = options.position or util.vector2(0, 0)
    local geo = glowGeometry(center, size, options.sizeFactor, options.worldDiag)
    local opacity = options.opacity or OUTLINE_STYLE.baseAlpha

    local glow = ui.create({
        layer = 'HUD',
        type = ui.TYPE.Image,
        props = {
            resource = GLOW_TEXTURE,
            color = options.color or OUTLINE_STYLE.glowColor,
            position = geo.pos,
            size = geo.size,
            alpha = (options.alpha or 1.0) * opacity,
            visible = true,
        },
    })

    return { glow = glow }
end

-- Update an existing glow's center position, size, and alpha in place.
-- Accepts the same style overrides as createOutlineBox (sizeFactor, opacity).
function M.updateOutlineBox(outlineBox, options)
    if not outlineBox or not outlineBox.glow then return end
    options = options or {}
    local el = outlineBox.glow

    if options.position and options.size then
        local geo = glowGeometry(options.position, options.size, options.sizeFactor, options.worldDiag)
        el.layout.props.position = geo.pos
        el.layout.props.size = geo.size
    end
    if options.alpha ~= nil then
        el.layout.props.alpha = options.alpha * (options.opacity or OUTLINE_STYLE.baseAlpha)
    end
    if options.visible ~= nil then
        el.layout.props.visible = options.visible
    end
    el:update()
end

-- Destroy a glow highlight.
function M.destroyOutlineBox(outlineBox)
    if not outlineBox or not outlineBox.glow then return end
    outlineBox.glow:destroy()
end

-- Create label with connecting line to object
function M.createLabelWithLine(text, screenPos, objectPos, options)
    options = options or {}
    
    -- Create main label
    local label = M.createNativeLabel(text, options)
    
    -- Create line connecting label to object
    -- Line starts from bottom-center of label (where anchor is)
    local line = ui.create({
        layer = 'HUD',
        type = ui.TYPE.Container,
        props = {
            -- Line is drawn as a thin stretched box
            backgroundColor = col(0.5, 0.5, 0.5, 0.3),  -- Semi-transparent gray
            
            -- Position at object point
            position = objectPos,
            
            -- Size and rotation to connect points
            size = util.vector2(1, 0),  -- Will be calculated
            
            visible = options.showLine ~= false
        }
    })
    
    -- Calculate line geometry
    local delta = screenPos - objectPos
    local length = delta:length()
    local angle = math.atan2(delta.y, delta.x)
    
    -- Update line properties
    line.layout.props.size = util.vector2(length, 1)  -- 1 pixel thick
    line.layout.props.rotation = angle
    
    -- Group label and line together
    return {
        label = label,
        line = line,
        update = function(self, newScreenPos, newObjectPos)
            -- Update positions
            self.label.layout.props.position = newScreenPos
            
            -- Recalculate line
            local newDelta = newScreenPos - newObjectPos
            local newLength = newDelta:length()
            local newAngle = math.atan2(newDelta.y, newDelta.x)
            
            self.line.layout.props.position = newObjectPos
            self.line.layout.props.size = util.vector2(newLength, 1)
            self.line.layout.props.rotation = newAngle
            
            self.label:update()
            self.line:update()
        end,
        destroy = function(self)
            self.label:destroy()
            self.line:destroy()
        end
    }
end

-- Match exact Morrowind tooltip behavior for special cases
function M.formatItemLabel(item)
    local text = item.name
    
    -- Add count for stacked items (e.g., "Gold (127)")
    if item.count and item.count > 1 then
        text = string.format("%s (%d)", text, item.count)
    end
    
    -- Add ownership indicator if stolen
    if item.isStolen then
        text = text .. " (Stolen)"
    end
    
    -- Match MW's enchanted item coloring (future feature)
    -- if item.isEnchanted then
    --     -- Would need different text color
    -- end
    
    return text
end

-- Create multi-line label for grouped items (MW style)
function M.createGroupLabel(items, position, options)
    -- Build multi-line text like MW containers
    local lines = {}
    
    -- Group by type and show counts
    local typeGroups = {}
    for _, item in ipairs(items) do
        local typeName = item.type or "Items"
        if not typeGroups[typeName] then
            typeGroups[typeName] = {count = 0, examples = {}}
        end
        typeGroups[typeName].count = typeGroups[typeName].count + 1
        if #typeGroups[typeName].examples < 3 then
            table.insert(typeGroups[typeName].examples, item.name)
        end
    end
    
    -- Format like Morrowind container tooltips
    for typeName, group in pairs(typeGroups) do
        if group.count > 3 then
            -- "Weapons (7)"
            table.insert(lines, string.format("%s (%d)", typeName, group.count))
        else
            -- List individual items
            for _, name in ipairs(group.examples) do
                table.insert(lines, name)
            end
        end
    end
    
    local text = table.concat(lines, "\n")
    return M.createNativeLabel(text, options)
end

-- Create health bar in MW style (for NPCs/Creatures)
function M.addHealthBar(labelElement, healthPercent)
    -- Morrowind uses a simple red bar
    local healthBar = ui.create({
        type = ui.TYPE.Container,
        props = {
            -- Dark background
            backgroundColor = col(0.1, 0.0, 0.0, 0.8),
            size = util.vector2(60, 4),
            position = util.vector2(0, labelElement.layout.size.y + 2),
            
            -- Border like MW
            borderColor = NATIVE_STYLE.borderColor,
            borderSize = 1
        },
        content = ui.content({
            {
                type = ui.TYPE.Container,
                props = {
                    -- Red health fill
                    backgroundColor = col(0.8, 0.1, 0.1, 1.0),
                    size = util.vector2(58 * healthPercent, 2),
                    position = util.vector2(1, 1)
                }
            }
        })
    })
    
    return healthBar
end

-- Preload native style (called once on init)
function M.init()
    -- Cache any native UI resources if needed
    -- This ensures consistent performance
end

return M