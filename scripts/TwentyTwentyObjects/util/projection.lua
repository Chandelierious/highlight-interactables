-- projection.lua: World-to-screen projection utilities for Interactable Highlight mod
-- Handles converting 3D world positions to 2D screen coordinates

local ui = require('openmw.ui')
local util = require('openmw.util')
local camera = require('openmw.camera')

local M = {}

-- Cache screen size to avoid repeated lookups
local screenSize = ui.screenSize()

-- Compensation factor for OpenMW's engine-level "GUI scaling factor" setting.
-- worldToViewportVector() and ui.screenSize() both return raw window pixels,
-- but widget rendering is scaled by the engine's own GUI scale, which Lua has
-- no documented way to read directly. Set this to match the user's actual
-- engine GUI scale (see settings_improved.lua -> Appearance -> UI Scale Correction).
M.guiScale = 1.0

function M.setGuiScale(scale)
    if type(scale) == 'number' and scale > 0 then
        M.guiScale = scale
    else
        M.guiScale = 1.0
    end
end

-- Debug flag, pushed in from the player script (onLoad / debug toggle).
-- worldToScreen runs per marker per rendered frame; it must not touch
-- engine storage on every call.
local debugEnabled = false

function M.setDebug(enabled)
    debugEnabled = enabled and true or false
end

-- Logger for debugging
local logger = require('scripts.TwentyTwentyObjects.util.logger')

-- Update cached screen size (call on resolution change)
function M.updateScreenSize()
    -- Force update from UI
    screenSize = ui.screenSize()
    if debugEnabled then
        logger.debug(string.format('Screen size updated: %dx%d', screenSize.x, screenSize.y))
    end
end

-- Convert world position to screen coordinates
-- Returns vector2 or nil if position is behind camera
function M.worldToScreen(worldPos)
    -- Behind-camera detection relies solely on worldToViewportVector's z
    -- (distance from camera; <= 0/tiny means behind or at the camera).
    -- A previous hand-rolled yaw/pitch "forward hemisphere" pre-check had an
    -- inverted pitch convention and silently culled objects the player was
    -- looking DOWN at (floor loot) — do not reintroduce it.
    local viewportPos = camera.worldToViewportVector(worldPos)

    -- The z component is the distance from camera to object
    -- If it's negative or very small, the object is behind or at the camera
    if viewportPos.z <= 1 then
        -- logger.debug('Object behind camera (z <= 1)')
        return nil
    end
    
    -- Update screen size if needed
    if not screenSize or screenSize.x == 0 then
        M.updateScreenSize()
    end
    
    -- The viewport coordinates are already in screen pixels
    local screenX = viewportPos.x
    local screenY = viewportPos.y
    
    -- WORKAROUND: At ultrawide resolutions, OpenMW sometimes returns incorrect viewport coordinates
    -- If the coordinates are way outside reasonable bounds, try to correct them
    if math.abs(screenX) > screenSize.x * 3 then
        if debugEnabled then
            logger.debug(string.format('Correcting extreme X coordinate: %.1f -> clamped', screenX))
        end
        -- This object is likely at the edge of the screen, clamp it
        screenX = screenX > 0 and (screenSize.x + 100) or -100
    end
    
    if math.abs(screenY) > screenSize.y * 3 then
        if debugEnabled then
            logger.debug(string.format('Correcting extreme Y coordinate: %.1f -> clamped', screenY))
        end
        screenY = screenY > 0 and (screenSize.y + 100) or -100
    end
    
    -- Create screen position vector
    local screenPos = util.vector2(screenX, screenY)
    
    -- Log suspicious coordinates
    if debugEnabled and (math.abs(screenX) > screenSize.x * 2 or math.abs(screenY) > screenSize.y * 2) then
        logger.debug(string.format('Suspicious viewport coordinates: viewport=(%.1f, %.1f, %.1f), screen size=%dx%d', 
            viewportPos.x, viewportPos.y, viewportPos.z, screenSize.x, screenSize.y))
        logger.debug(string.format('Object pos: %s, camera distance: %.1f',
            tostring(worldPos), viewportPos.z))
    end
    
    -- Compensate for the engine's GUI scaling factor before bounds checking,
    -- so both the position and the isOnScreen check line up with rendered widgets.
    if M.guiScale and M.guiScale ~= 1.0 then
        screenPos = util.vector2(screenPos.x / M.guiScale, screenPos.y / M.guiScale)
    end

    -- Be more lenient with bounds checking - objects slightly off-screen might still have visible labels
    local margin = 200  -- Increased margin
    if not M.isOnScreen(screenPos, margin) then
        -- Only log for extreme cases to reduce spam
        if math.abs(screenX) > 5000 or math.abs(screenY) > 5000 then
            logger.debug(string.format('worldToScreen: pos=%s, viewport=%s (z=%.2f)', 
                tostring(worldPos), tostring(viewportPos), viewportPos.z))
            logger.debug(string.format('Object far outside screen bounds: (%.1f, %.1f)', screenX, screenY))
        end
        return nil
    end
    
    return screenPos
end

-- Get the top-center position of an object's bounding box
function M.getObjectLabelPosition(object)
    local pos = object.position
    
    -- Try to get bounding box if the method exists
    local bbox = nil
    local success, result = pcall(function() return object:getBoundingBox() end)
    if success then
        bbox = result
    end
    
    if bbox and bbox.max and bbox.max.z then
        -- Use top of bounding box with minimal clearance
        return util.vector3(
            pos.x,
            pos.y,
            pos.z + bbox.max.z  -- No extra clearance, let jitter solver handle offset
        )
    else
        -- Fallback: use object position plus minimal offset
        -- The jitter solver will handle the actual label placement
        local offset = 0  -- Start at object center
        
        -- Try to determine object type for better offset
        if object.type then
            local types = require('openmw.types')
            if object.type == types.NPC or object.type == types.Creature then
                offset = 100  -- Head height for actors (was 50)
            elseif object.type == types.Container then
                offset = 0   -- Use center for containers
            elseif object.type == types.Door then
                offset = 50  -- Center-ish height for doors (was 40)
            end
        end
        
        return pos + util.vector3(0, 0, offset)
    end
end

-- Check if screen position is within visible bounds.
-- Positions handed in are in guiScale-compensated space (worldToScreen
-- divides by guiScale), so the bounds must be scaled the same way.
function M.isOnScreen(screenPos, margin)
    margin = margin or 0
    local w = screenSize.x / M.guiScale
    local h = screenSize.y / M.guiScale
    return screenPos.x >= -margin and
           screenPos.x <= w + margin and
           screenPos.y >= -margin and
           screenPos.y <= h + margin
end

-- Clamp screen position to stay within bounds
function M.clampToScreen(screenPos, margin)
    margin = margin or 10
    return util.vector2(
        math.max(margin, math.min(screenSize.x - margin, screenPos.x)),
        math.max(margin, math.min(screenSize.y - margin, screenPos.y))
    )
end

-- Get distance-based scale factor for labels
function M.getDistanceScale(distance, minDist, maxDist)
    minDist = minDist or 100
    maxDist = maxDist or 2000
    
    -- Clamp distance to range
    distance = math.max(minDist, math.min(maxDist, distance))
    
    -- Linear interpolation (could use other curves)
    local t = (distance - minDist) / (maxDist - minDist)
    return 1.0 - (t * 0.5)  -- Scale from 100% to 50%
end

-- Compute an on-screen outline box (center + size in pixels) for an object.
-- Returns nil if the object can't be projected to a usable on-screen box.
--
-- object:getBoundingBox() returns an openmw.util#Box in WORLD coordinates.
-- NOTE: util.box has `vertices` (8 corner vector3s), `center`, and `halfSize`
-- — it does NOT have `min`/`max` fields. (This mod's original label-placement
-- code checks bbox.max.z, which is always nil, so the bbox path there has
-- silently never run; everything has been using the type-based fallbacks.)
--
-- Strategy: project all 8 corners to screen space and take the min/max
-- extents — a true screen-space bounding rectangle that correctly handles
-- rotated objects and meshes extending below their origin (hanging lanterns).
function M.getOutlineBox(object)
    local corners = nil
    local ok, bbox = pcall(function() return object:getBoundingBox() end)
    if ok and bbox then
        if bbox.vertices then
            corners = bbox.vertices
        elseif bbox.center and bbox.halfSize then
            local c, h = bbox.center, bbox.halfSize
            corners = {}
            for _, sx in ipairs({ -1, 1 }) do
                for _, sy in ipairs({ -1, 1 }) do
                    for _, sz in ipairs({ -1, 1 }) do
                        table.insert(corners, util.vector3(
                            c.x + sx * h.x, c.y + sy * h.y, c.z + sz * h.z))
                    end
                end
            end
        end
    end

    -- The glow's CENTER comes from projecting bbox.center directly — the true
    -- 3D centroid gives the visual center exactly. Deriving the center from
    -- the min/max rect of projected corners skews toward whichever corners
    -- protrude in screen space (video evidence: orbs sat up-left of crate
    -- faces). Corners are only used for the on-screen SIZE.
    local centerScreen = nil
    if ok and bbox and bbox.center then
        centerScreen = M.worldToScreen(bbox.center)
    end

    if corners and centerScreen then
        local minX, minY, maxX, maxY
        local projectedCount = 0
        for _, v in ipairs(corners) do
            local sp = M.worldToScreen(v)
            if sp then
                projectedCount = projectedCount + 1
                minX = math.min(minX or sp.x, sp.x)
                maxX = math.max(maxX or sp.x, sp.x)
                minY = math.min(minY or sp.y, sp.y)
                maxY = math.max(maxY or sp.y, sp.y)
            end
        end
        -- World-space bbox diagonal: distance- and orientation-independent
        -- measure of the object's physical size, for stable glow sizing.
        local worldDiag = nil
        if bbox.halfSize then
            worldDiag = bbox.halfSize:length() * 2
        end
        if projectedCount >= 4 then
            local w = math.max(12, math.min(maxX - minX, 800))
            local h = math.max(12, math.min(maxY - minY, 800))
            if debugEnabled then
                logger.debug(string.format('[OutlineBox] bbox path: corners=%d center=(%.0f,%.0f) size=%dx%d',
                    projectedCount, centerScreen.x, centerScreen.y, w, h))
            end
            return centerScreen, util.vector2(w, h), worldDiag
        end
        -- Center is on screen but too few corners projected (object at a
        -- screen edge): still center correctly, size from world diagonal.
        if debugEnabled then
            logger.debug(string.format('[OutlineBox] center-only path: corners=%d', projectedCount))
        end
        local approx = math.max(24, math.min((worldDiag or 100) * 0.6, 500))
        return centerScreen, util.vector2(approx, approx), worldDiag
    end

    if debugEnabled then
        logger.debug(string.format('[OutlineBox] heuristic fallback: bboxOk=%s hasBbox=%s hasCorners=%s hasCenterScreen=%s',
            tostring(ok), tostring(bbox ~= nil), tostring(corners ~= nil), tostring(centerScreen ~= nil)))
    end

    -- Heuristic fallback (no usable bbox / too few corners projected):
    -- vertical extent from object origin to the label anchor point, fixed
    -- aspect for width.
    local basePos = object.position
    local topPos = M.getObjectLabelPosition(object)  -- has its own fallback, never nil
    local baseScreen = M.worldToScreen(basePos)
    local topScreen = M.worldToScreen(topPos)
    if not baseScreen or not topScreen then
        return nil
    end

    local screenHeight = math.abs(topScreen.y - baseScreen.y)
    if screenHeight <= 0 then
        screenHeight = 40
    end
    screenHeight = math.max(20, math.min(screenHeight, 500))
    local screenWidth = math.max(20, math.min(screenHeight * 0.6, 400))

    local centerY = (topScreen.y + baseScreen.y) / 2
    return util.vector2(baseScreen.x, centerY),
           util.vector2(screenWidth, screenHeight)
end

return M