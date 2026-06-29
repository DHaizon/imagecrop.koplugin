--[[--
ImageCrop plugin for KOReader.

Two-tap crop mode:
  1st tap  → sets top-left corner  (crosshair shown)
  2nd tap  → sets bottom-right corner (crop rectangle shown)
  "Crop & Save" → saves
  "Reset" / "Cancel" → start over or exit

Install:
  koreader/plugins/imagecrop.koplugin/main.lua
--]]

local BD             = require("ui/bidi")
local Blitbuffer     = require("ffi/blitbuffer")
local ButtonDialog   = require("ui/widget/buttondialog")
local DataStorage    = require("datastorage")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification   = require("ui/widget/notification")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")
local Screen         = Device.screen
local logger         = require("logger")
local _              = require("gettext")

-- ─────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Full-screen repaint used by launchCrop (no widget ref needed there).
local function scheduleRepaint(mode)
    UIManager:nextTick(function()
        UIManager:setDirty(nil, mode or "full")
        UIManager:forceRePaint()
    end)
end

-- ─────────────────────────────────────────────────────────────
-- PNG writer
-- Uses bb:writePNG(path) which is a method on the Blitbuffer
-- object itself (via libblitbuffer.so).  This is how KOReader's
-- own pinnedpopup plugin saves images and is the only reliable
-- path on KindlePW4 / KOReader v2026.03.
--
-- BlitBuffer8 (greyscale) may not support writePNG directly, so
-- we always convert to TYPE_BBRGB32 first, same as pinnedpopup.
-- ─────────────────────────────────────────────────────────────
local function writePNG(bb, path)
    local w = bb:getWidth()
    local h = bb:getHeight()

    -- Convert to RGB32 if needed (BlitBuffer8 writePNG can fail)
    local save_bb
    if bb:getType() ~= Blitbuffer.TYPE_BBRGB32 then
        save_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        save_bb:blitFrom(bb, 0, 0, 0, 0, w, h)
    else
        save_bb = bb
    end

    local ok, err = pcall(function() save_bb:writePNG(path) end)

    if save_bb ~= bb then save_bb:free() end

    if not ok then
        return false, tostring(err)
    end

    -- writePNG doesn't return a useful value; check the file exists
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path)
    if not attr or attr.size < 8 then
        return false, "writePNG produced an empty file"
    end

    return true
end

-- ─────────────────────────────────────────────────────────────
-- CropOverlay – two-tap selection
-- States: "idle" → "one" → "two"
-- ─────────────────────────────────────────────────────────────
local CropOverlay = InputContainer:extend{
    image_viewer = nil,
    on_crop      = nil,
    on_pin       = nil,
    on_cancel    = nil,
    modal        = true,

    _state = "idle",
    _p1    = nil,
    _p2    = nil,

    _bar_y = 0,
    _bar_h = 0,
    _nav_y = 0,   -- top of the directional-arrow bar (shown in state "two")
    _nav_h = 0,

    BAR_H    = Screen:scaleBySize(52),
    NAV_H    = Screen:scaleBySize(52),
    BTN_FONT = Font:getFace("cfont", 20),
    LINE_W   = Screen:scaleBySize(2),
    CROSS_R  = Screen:scaleBySize(14),
    STEP     = Screen:scaleBySize(1),   -- pixels to move per tap
}

function CropOverlay:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    self._bar_h = self.BAR_H
    self._bar_y = sh - self._bar_h
    self._nav_h = self.NAV_H
    self._nav_y = self._bar_y - self._nav_h

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    local range = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        CropTap   = { GestureRange:new{ ges = "tap",   range = range } },
        CropSwipe = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

-- Marks THIS widget dirty so UIManager calls our paintTo again.
-- We also dirty the ImageViewer beneath us so it repaints first,
-- clearing any old crosshair/corner drawings from the framebuffer
-- before we draw the new state on top.
function CropOverlay:_repaint(mode)
    local w  = self
    local iv = self.image_viewer
    UIManager:nextTick(function()
        -- 1. IV repaints first (z-order below) → wipes old overlay marks
        if iv then
            UIManager:setDirty(iv, mode or "ui")
        end
        -- 2. Overlay repaints on top → draws current state
        UIManager:setDirty(w, function()
            return mode or "ui", w.dimen
        end)
        UIManager:forceRePaint()
    end)
end

function CropOverlay:_normRect()
    if not self._p1 or not self._p2 then return nil end
    local x1 = math.min(self._p1.x, self._p2.x)
    local y1 = math.min(self._p1.y, self._p2.y)
    local x2 = math.max(self._p1.x, self._p2.x)
    local y2 = math.max(self._p1.y, self._p2.y)
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end


-- Moves the entire selection by (dx, dy) screen pixels, clamped to screen.
function CropOverlay:_moveSelection(dx, dy)
    if not self._p1 or not self._p2 then return end
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local function mv(p)
        return { x = clamp(p.x + dx, 0, sw - 1),
                 y = clamp(p.y + dy, 0, sh - 1) }
    end
    self._p1 = mv(self._p1)
    self._p2 = mv(self._p2)
    self:_repaint("ui")
end

-- ── drawing ───────────────────────────────────────────────────

-- Draws a small black pill with white text (instruction label).
function CropOverlay:_drawInstruction(bb, ox, oy, sw, text)
    local face  = self.BTN_FONT
    local lw    = self.LINE_W
    local WHITE = Blitbuffer.COLOR_WHITE
    local BLACK = Blitbuffer.COLOR_BLACK

    local ok, text_w = pcall(function()
        return RenderText:sizeUtf8Text(0, sw, face, text, false, false).x
    end)
    if not ok then text_w = math.floor(sw * 0.65) end

    local pad_h = Screen:scaleBySize(10)
    local pad_v = Screen:scaleBySize(5)
    local bw    = text_w + pad_h * 2
    local bh    = face.size + pad_v * 2
    local bx    = ox + math.floor((sw - bw) / 2)
    local by    = oy + Screen:scaleBySize(28)

    bb:paintRect(bx,  by,  bw, bh, BLACK)
    bb:paintBorder(bx, by, bw, bh, lw, WHITE)
    RenderText:renderUtf8Text(bb,
        ox + math.floor(sw / 2), by + pad_v,
        face, text, true, false, WHITE)
end

-- Draws a 3-cell bar at the bottom.  Text is manually centered per cell
-- by measuring the actual rendered width with sizeUtf8Text.
function CropOverlay:_drawButtonBar(bb, ox, oy, sw)
    local bar_y = oy + self._bar_y
    local bar_h = self._bar_h
    local lw    = self.LINE_W
    local face  = self.BTN_FONT

    local WHITE = Blitbuffer.COLOR_WHITE
    local BLACK = Blitbuffer.COLOR_BLACK
    local LGRAY = Blitbuffer.gray(0.65)

    -- White background + top separator
    bb:paintRect(ox, bar_y, sw, bar_h, WHITE)
    bb:paintRect(ox, bar_y, sw, lw,    BLACK)

    -- Three equal cells with vertical dividers
    local cell_w = math.floor(sw / 3)
    bb:paintRect(ox + cell_w,     bar_y + lw, lw, bar_h - lw, BLACK)
    bb:paintRect(ox + cell_w * 2, bar_y + lw, lw, bar_h - lw, BLACK)

    -- Labels
    local l1 = (self._state == "idle") and _("Cancel") or _("Reset")
    local l2 = _("Pin")
    local l3 = _("Crop")   -- "Crop & Save" is too wide for 1/3 of screen

    -- Active colors
    local c1 = BLACK
    local c2 = (self._state == "two") and BLACK or LGRAY
    local c3 = (self._state == "two") and BLACK or LGRAY

    -- Vertical center of glyphs inside bar.
    -- face.size is the full em-height (ascenders+descenders).
    -- Visible glyphs sit in the upper ~70-75% of that box, so using
    -- face.size directly places text above the optical center.
    -- sizeUtf8Text may return a plain number (width) or {x=w, y=lines}
    -- depending on the KOReader version — handle both.
    local function measureText(text)
        local ok, result = pcall(function()
            return RenderText:sizeUtf8Text(0, sw, face, text, false, false)
        end)
        if not ok or result == nil then return nil end
        if type(result) == "number" then return result end          -- plain width
        if type(result) == "table"  then return result.x end       -- {x=w, y=lines}
        return nil
    end

    -- renderUtf8Text draws from the baseline, which sits ~80% down the em-box.
    -- To center glyphs optically we:
    --   1. estimate cap-height ≈ 72% of em (visible glyph height above baseline)
    --   2. find the top of the centered glyph block
    --   3. add the ascender (baseline offset from top of em) = face.size * 0.80
    local cap_h    = math.floor(face.size * 0.72)
    local glyph_top = bar_y + math.floor((bar_h - cap_h) / 2)
    local ty = glyph_top + math.floor(face.size * 0.80)

    -- Render a label centered inside its cell
    local function renderCell(label, cell_x, color)
        local tw = measureText(label) or math.floor(cell_w * 0.5)  -- tighter fallback
        tw = math.min(tw, cell_w)  -- clamp so we never go negative
        local tx = cell_x + math.floor((cell_w - tw) / 2)
        RenderText:renderUtf8Text(bb, tx, ty, face, label, false, color)
    end

    renderCell(l1, ox,                  c1)
    renderCell(l2, ox + cell_w,         c2)
    renderCell(l3, ox + cell_w * 2,     c3)
end


-- Draws the directional-arrow bar (◄ ▲ ▼ ►) shown above the main bar
-- when state == "two".  Four equal cells.
function CropOverlay:_drawNavBar(bb, ox, oy, sw)
    local nav_y = oy + self._nav_y
    local nav_h = self._nav_h
    local lw    = self.LINE_W
    local face  = self.BTN_FONT

    local WHITE = Blitbuffer.COLOR_WHITE
    local BLACK = Blitbuffer.COLOR_BLACK

    -- Background + top separator
    bb:paintRect(ox, nav_y, sw, nav_h, WHITE)
    bb:paintRect(ox, nav_y, sw, lw,    BLACK)

    -- Four equal cells with vertical dividers
    local cell_w = math.floor(sw / 4)
    for i = 1, 3 do
        bb:paintRect(ox + cell_w * i, nav_y + lw, lw, nav_h - lw, BLACK)
    end

    -- Vertical centering (same logic as main bar)
    local cap_h     = math.floor(face.size * 0.72)
    local glyph_top = nav_y + math.floor((nav_h - cap_h) / 2)
    local ty        = glyph_top + math.floor(face.size * 0.80)

    local function measureText(text)
        local ok, result = pcall(function()
            return RenderText:sizeUtf8Text(0, sw, face, text, false, false)
        end)
        if not ok or result == nil then return nil end
        if type(result) == "number" then return result end
        if type(result) == "table"  then return result.x end
        return nil
    end

    local labels = { "◄", "▲", "▼", "►" }
    -- UTF-8: ◄ U+25C4, ▲ U+25B2, ▼ U+25BC, ► U+25BA
    for i, lbl in ipairs(labels) do
        local cx  = ox + cell_w * (i - 1)
        local tw  = measureText(lbl) or math.floor(cell_w * 0.5)
        tw = math.min(tw, cell_w)
        local tx  = cx + math.floor((cell_w - tw) / 2)
        RenderText:renderUtf8Text(bb, tx, ty, face, lbl, false, BLACK)
    end
end

function CropOverlay:paintTo(bb, ox, oy)
    local sw  = Screen:getWidth()
    local sh  = Screen:getHeight()
    local lw  = self.LINE_W
    local WHITE = Blitbuffer.COLOR_WHITE
    local BLACK = Blitbuffer.COLOR_BLACK

    -- ── Idle: nothing extra (no instruction label) ───────────────
    if self._state == "idle" then
        -- intentionally blank; button bar is drawn below

    -- ── State "one": full-screen crosshair at p1 ─────────────────
    elseif self._state == "one" then
        local px = ox + self._p1.x
        local py = oy + self._p1.y
        local cr = self.CROSS_R
        -- White halo first (contrast on any background), then black line
        bb:paintRect(ox,     py - 1, sw,      lw + 2, WHITE)
        bb:paintRect(ox,     py,     sw,      lw,     BLACK)
        bb:paintRect(px - 1, oy,     lw + 2,  sh,     WHITE)
        bb:paintRect(px,     oy,     lw,      sh,     BLACK)
        -- Solid black square marker at intersection
        bb:paintRect(px - cr - 1, py - cr - 1, cr * 2 + 2, cr * 2 + 2, WHITE)
        bb:paintRect(px - cr,     py - cr,     cr * 2,      cr * 2,     BLACK)

    -- ── State "two": selection border + corners, NO dimming ────────
    else
        local r = self:_normRect()
        if r and r.w >= 2 and r.h >= 2 then
            -- White halo then black border (visible on any background)
            bb:paintBorder(ox + r.x - 1, oy + r.y - 1, r.w + 2, r.h + 2, lw + 1, WHITE)
            bb:paintBorder(ox + r.x,     oy + r.y,     r.w,     r.h,     lw,     BLACK)
            -- L-shaped corner markers (black with white halo)
            local arm = Screen:scaleBySize(22)
            for _, c in ipairs({
                { ox + r.x,           oy + r.y           },
                { ox + r.x + r.w,     oy + r.y           },
                { ox + r.x,           oy + r.y + r.h     },
                { ox + r.x + r.w,     oy + r.y + r.h     },
            }) do
                bb:paintRect(c[1] - arm - 1, c[2] - lw  - 1, arm * 2 + 2, lw  * 2 + 2, WHITE)
                bb:paintRect(c[1] - lw  - 1, c[2] - arm - 1, lw  * 2 + 2, arm * 2 + 2, WHITE)
                bb:paintRect(c[1] - arm, c[2] - lw,  arm * 2, lw * 2, BLACK)
                bb:paintRect(c[1] - lw,  c[2] - arm, lw * 2, arm * 2, BLACK)
            end
        end
    end

    -- ── Nav bar (arrows) above main bar — only in state "two" ─────
    if self._state == "two" then
        self:_drawNavBar(bb, ox, oy, sw)
    end

    -- ── Button bar always on top ───────────────────────────────────
    self:_drawButtonBar(bb, ox, oy, sw)
end

-- ── gesture handlers ──────────────────────────────────────────
function CropOverlay:onCropTap(_, ges)
    local tx = ges.pos.x
    local ty = ges.pos.y
    local sw = Screen:getWidth()

    -- ── Nav bar (arrow cells) — only in state "two" ────────────────
    if self._state == "two" and ty >= self._nav_y and ty < self._bar_y then
        local cell_w = math.floor(sw / 4)
        local cell   = math.floor(tx / cell_w)  -- 0=◄ 1=▲ 2=▼ 3=►
        local step   = self.STEP
        if     cell == 0 then self:_moveSelection(-step,    0)
        elseif cell == 1 then self:_moveSelection(   0, -step)
        elseif cell == 2 then self:_moveSelection(   0,  step)
        elseif cell == 3 then self:_moveSelection( step,    0)
        end
        return true
    end

    -- ── Button bar (3 equal cells) ────────────────────────────────
    if ty >= self._bar_y then
        local cell = math.floor(tx / (sw / 3))   -- 0 = left, 1 = mid, 2 = right

        if cell == 0 then
            -- Cell 1: Cancel (idle) / Reset (one, two)
            if self._state == "idle" then
                if self.on_cancel then self.on_cancel() end
            else
                self._state = "idle"
                self._p1    = nil
                self._p2    = nil
                self:_repaint("ui")
            end

        elseif cell == 1 then
            -- Cell 2: Pin — only active when state == "two"
            if self._state == "two" then
                local r = self:_normRect()
                if r and self.on_pin then self.on_pin(r) end
            end

        else
            -- Cell 3: Crop — only active when state == "two"
            if self._state == "two" then
                local r = self:_normRect()
                if r and self.on_crop then self.on_crop(r) end
            end
        end
        return true
    end

    -- ── Image area ────────────────────────────────────────────────
    if self._state == "idle" then
        self._p1    = { x = tx, y = ty }
        self._state = "one"
        self:_repaint("ui")
    elseif self._state == "one" then
        self._p2    = { x = tx, y = ty }
        self._state = "two"
        self:_repaint("ui")
    else  -- "two" → start new selection
        self._p1    = { x = tx, y = ty }
        self._p2    = nil
        self._state = "one"
        self:_repaint("ui")
    end
    return true
end

function CropOverlay:onCropSwipe() return true end

-- ─────────────────────────────────────────────────────────────
-- Coordinate mapping: screen → source-image pixels
-- ─────────────────────────────────────────────────────────────
-- ── Shared: parse the ImageWidget geometry ───────────────────
-- Returns img_x, img_y, img_w, img_h, pan_x, pan_y, scale
-- or nil, err on failure.
local function getImageGeom(iv)
    local iwg = iv._image_wg
    if not iwg then return nil, "no _image_wg" end
    local dimen = iwg.dimen
    if not dimen then return nil, "image not yet painted" end

    local img_x, img_y = dimen.x, dimen.y
    local img_w, img_h = dimen.w, dimen.h

    local scale = 1.0
    if type(iwg.getScaleFactor) == "function" then
        local sf = iwg:getScaleFactor()
        if sf and sf ~= 0 then scale = sf end
    end

    local pan_x = rawget(iwg, "_offset_x") or 0
    local pan_y = rawget(iwg, "_offset_y") or 0

    logger.warn(string.format(
        "ImageCrop geom: dimen=(%d,%d %dx%d) scale=%.4f pan=(%d,%d)",
        img_x, img_y, img_w, img_h, scale, pan_x, pan_y))

    return img_x, img_y, img_w, img_h, pan_x, pan_y, scale
end

-- ── Clip sel to the widget rect and return sx,sy,sx2,sy2 ─────
local function clipSel(sel, img_x, img_y, img_w, img_h)
    local sx  = math.max(sel.x,         img_x)
    local sy  = math.max(sel.y,         img_y)
    local sx2 = math.min(sel.x + sel.w, img_x + img_w)
    local sy2 = math.min(sel.y + sel.h, img_y + img_h)
    if sx2 <= sx or sy2 <= sy then
        return nil, "Selection is entirely outside the image."
    end
    return sx, sy, sx2, sy2
end

-- ── Rect in BLITBUFFER coordinates (already-scaled widget bb) ─
-- The ImageWidget blitbuffer is img_w × img_h pixels.
-- Coordinate mapping: bb_pixel = screen_pixel - widget_origin - pan
-- No scale division needed because the bb IS the scaled image.
local function screenToBB(iv, sel)
    local img_x, img_y, img_w, img_h, pan_x, pan_y, scale, err =
        getImageGeom(iv)
    if not img_x then return nil, img_y end

    local sx, sy, sx2, sy2, cerr = clipSel(sel, img_x, img_y, img_w, img_h)
    if not sx then return nil, cerr end

    local bx  = math.max(0, math.floor(sx  - img_x - pan_x + 0.5))
    local by  = math.max(0, math.floor(sy  - img_y - pan_y + 0.5))
    local bx2 = math.min(img_w, math.floor(sx2 - img_x - pan_x + 0.5))
    local by2 = math.min(img_h, math.floor(sy2 - img_y - pan_y + 0.5))
    if bx2 <= bx or by2 <= by then return nil, "BB rect is empty." end

    local r = { x = bx, y = by, w = bx2 - bx, h = by2 - by }
    logger.warn(string.format("ImageCrop screenToBB: sel=(%d,%d %dx%d) → bb=(%d,%d %dx%d)",
        sel.x, sel.y, sel.w, sel.h, r.x, r.y, r.w, r.h))
    return r
end

-- ── Rect in SOURCE-FILE coordinates (native image resolution) ─
-- Used only by saveWithRenderImage which re-decodes the file at full res.
-- Coordinate mapping: src_pixel = (screen_pixel - widget_origin - pan) / scale
local function screenToSrc(iv, sel)
    local img_x, img_y, img_w, img_h, pan_x, pan_y, scale, err =
        getImageGeom(iv)
    if not img_x then return nil, img_y end

    local sx, sy, sx2, sy2, cerr = clipSel(sel, img_x, img_y, img_w, img_h)
    if not sx then return nil, cerr end

    local src_w = math.max(1, math.floor(img_w / scale + 0.5))
    local src_h = math.max(1, math.floor(img_h / scale + 0.5))

    local function toX(v) return math.floor((v - img_x - pan_x) / scale + 0.5) end
    local function toY(v) return math.floor((v - img_y - pan_y) / scale + 0.5) end

    local rx  = clamp(toX(sx),  0, src_w - 1)
    local ry  = clamp(toY(sy),  0, src_h - 1)
    local rx2 = clamp(toX(sx2), rx + 1, src_w)
    local ry2 = clamp(toY(sy2), ry + 1, src_h)

    local r = { x = rx, y = ry, w = rx2 - rx, h = ry2 - ry }
    logger.warn(string.format("ImageCrop screenToSrc: sel=(%d,%d %dx%d) → src=(%d,%d %dx%d) of %dx%d",
        sel.x, sel.y, sel.w, sel.h, r.x, r.y, r.w, r.h, src_w, src_h))
    return r
end

-- ─────────────────────────────────────────────────────────────
-- Save
-- ─────────────────────────────────────────────────────────────
local function buildOutputPath(src_file)
    local dir  = src_file:match("^(.*)/[^/]+$")
                 or DataStorage:getFullDataDir() .. "/screenshots"
    local base = src_file:match("([^/]+)%.[^%.]+$") or "image"
    return dir .. "/" .. base .. "_crop_" .. os.date("%Y%m%d_%H%M%S") .. ".png"
end

-- Method 1: re-decode source file with RenderImage (KOReader's own API)
-- This is what pinnedpopup uses and is reliable on this build.
local function saveWithRenderImage(src_file, rect, out_file)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then
        return false, "ui/renderimage unavailable"
    end

    local src_bb = RenderImage:renderImageFile(src_file, false)
    if not src_bb then
        return false, "RenderImage:renderImageFile returned nil"
    end

    local x = clamp(rect.x, 0, src_bb:getWidth()  - 1)
    local y = clamp(rect.y, 0, src_bb:getHeight() - 1)
    local w = clamp(rect.w, 1, src_bb:getWidth()  - x)
    local h = clamp(rect.h, 1, src_bb:getHeight() - y)

    local crop = Blitbuffer.new(w, h, src_bb:getType())
    crop:blitFrom(src_bb, 0, 0, x, y, w, h)
    src_bb:free()

    local ok, err = writePNG(crop, out_file)
    crop:free()
    return ok, ok and out_file or tostring(err)
end

-- Crops a pre-captured blitbuffer and saves it to a PNG.
-- The caller must capture Screen.bb BEFORE any layout changes (closeAll).
local function saveCapturedBB(captured_bb, rect, out_file)
    local src_w = captured_bb:getWidth()
    local src_h = captured_bb:getHeight()
    logger.warn(string.format(
        "ImageCrop saveCapturedBB: bb=%dx%d rect=(%d,%d %dx%d)",
        src_w, src_h, rect.x, rect.y, rect.w, rect.h))

    local x = clamp(rect.x, 0, src_w - 1)
    local y = clamp(rect.y, 0, src_h - 1)
    local w = clamp(rect.w, 1, src_w - x)
    local h = clamp(rect.h, 1, src_h - y)

    local crop = Blitbuffer.new(w, h, captured_bb:getType())
    crop:blitFrom(captured_bb, 0, 0, x, y, w, h)
    captured_bb:free()

    local ok, err = writePNG(crop, out_file)
    crop:free()
    return ok, ok and out_file or tostring(err)
end

-- Captures the current Screen.bb into a new blitbuffer and clips rect to it.
-- Returns captured_bb, clipped_rect  OR  nil, err.
-- Call this BEFORE any layout changes that would shift screen content.
local function captureScreen(sel, iv)
    local src = Screen.bb
    if not src then return nil, "Screen.bb unavailable" end

    local src_w = src:getWidth()
    local src_h = src:getHeight()

    -- Clip selection to the image widget area (avoid grabbing black padding)
    local sx  = sel.x
    local sy  = sel.y
    local sx2 = sel.x + sel.w
    local sy2 = sel.y + sel.h
    if iv and iv._image_wg and iv._image_wg.dimen then
        local d = iv._image_wg.dimen
        sx  = math.max(sx,  math.max(0, d.x))
        sy  = math.max(sy,  math.max(0, d.y))
        sx2 = math.min(sx2, math.max(0, d.x) + d.w)
        sy2 = math.min(sy2, math.max(0, d.y) + d.h)
    end
    if sx2 <= sx or sy2 <= sy then
        return nil, "Selection outside image area."
    end

    local x = clamp(sx,       0, src_w - 1)
    local y = clamp(sy,       0, src_h - 1)
    local w = clamp(sx2 - sx, 1, src_w - x)
    local h = clamp(sy2 - sy, 1, src_h - y)

    -- Copy the region NOW (before layout changes shift Screen.bb content)
    local captured = Blitbuffer.new(w, h, src:getType())
    captured:blitFrom(src, 0, 0, x, y, w, h)

    logger.warn(string.format(
        "ImageCrop captureScreen: Screen.bb=%dx%d sel=(%d,%d %dx%d) → captured=(%d,%d %dx%d)",
        src_w, src_h, sel.x, sel.y, sel.w, sel.h, x, y, w, h))

    return captured, { x = 0, y = 0, w = w, h = h }
end

local function performCrop(captured_bb, rect, iv)
    local out
    if iv and iv.file then
        out = buildOutputPath(iv.file)
    else
        out = DataStorage:getFullDataDir() .. "/screenshots/crop_" ..
              os.date("%Y%m%d_%H%M%S") .. ".png"
    end
    return saveCapturedBB(captured_bb, rect, out)
end

-- ─────────────────────────────────────────────────────────────
-- UI helpers
-- ─────────────────────────────────────────────────────────────
local function showResult(path)
    local d
    d = ButtonDialog:new{
        title   = _("Crop saved:") .. "\n\n" .. BD.filepath(path) .. "\n",
        modal   = true,
        buttons = {{
            { text = _("View"), callback = function()
                UIManager:close(d)
                local IV = require("ui/widget/imageviewer")
                UIManager:show(IV:new{
                    file = path, modal = true,
                    with_title_bar = false, buttons_visible = true,
                })
            end },
            { text = _("OK"), callback = function() UIManager:close(d) end },
        }},
    }
    UIManager:show(d)
end

local function showError(msg)
    local d = ButtonDialog:new{
        title   = _("Crop failed:") .. "\n\n" .. (msg or "?") .. "\n",
        modal   = true,
        buttons = {{
            { text = _("OK"), callback = function() UIManager:close(d) end },
        }},
    }
    UIManager:show(d)
end

-- ─────────────────────────────────────────────────────────────
-- Pin crop
-- Crops the selected region in memory and saves it directly into
-- PinnedElements' image directory, creating a pin entry.
-- Requires PinnedElements plugin to have set _G.PinnedElements_active.
-- ─────────────────────────────────────────────────────────────
local function performCropAndPin(captured_bb, rect, iv)
    local pe = _G.PinnedElements_active
    if not pe then
        UIManager:show(Notification:new{ text = _("PinnedElements not active") })
        captured_bb:free()
        return
    end
    if not (pe._img_dir and pe._pins) then
        UIManager:show(Notification:new{ text = _("PinnedElements not initialized") })
        captured_bb:free()
        return
    end

    local img_path = string.format("%s/crop_%d_%d.png",
        pe._img_dir, os.time(), math.random(100, 999))

    local ok, result = saveCapturedBB(captured_bb, rect, img_path)
    if not ok then
        UIManager:show(Notification:new{ text = _("Crop failed: ") .. tostring(result) })
        return
    end

    local pageno = 0
    if pe.ui and pe.ui.view and pe.ui.view.state then
        pageno = pe.ui.view.state.page or 0
    end

    table.insert(pe._pins, {
        id       = tostring(os.time()) .. tostring(math.random(100, 999)),
        type     = "image",
        page     = pageno,
        label    = _("Cropped image"),
        img_path = img_path,
        created  = os.time(),
    })
    pe:_saveStorage()
    UIManager:show(Notification:new{ text = _("Crop pinned") })
end

-- ─────────────────────────────────────────────────────────────
-- Launch
-- ─────────────────────────────────────────────────────────────
local function launchCrop(iv)
    local prev_buttons    = iv.buttons_visible
    local prev_title_bar  = iv.with_title_bar
    local prev_fullscreen = iv.fullscreen
    iv.buttons_visible = false
    iv.with_title_bar  = false
    iv.fullscreen      = true   -- remove padding + rounded frame
    iv:update()

    local overlay

    local function closeAll()
        if overlay then UIManager:close(overlay) end
        iv.buttons_visible = prev_buttons
        iv.with_title_bar  = prev_title_bar
        iv.fullscreen      = prev_fullscreen
        iv:update()
        scheduleRepaint("full")
    end

    overlay = CropOverlay:new{
        image_viewer = iv,
        on_cancel    = closeAll,
        on_crop      = function(sel)
            -- Capture the screen NOW, before closeAll() changes the layout.
            -- closeAll() restores bars which shifts content by ~104px,
            -- so Screen.bb read after closeAll would have wrong coordinates.
            local captured_bb, rect = captureScreen(sel, iv)
            closeAll()
            UIManager:nextTick(function()
                if not captured_bb then
                    showError(rect or "capture failed")
                    return
                end
                local ok, result = performCrop(captured_bb, rect, iv)
                if ok then showResult(result)
                else       showError(result)
                end
            end)
        end,
        on_pin       = function(sel)
            local captured_bb, rect = captureScreen(sel, iv)
            closeAll()
            UIManager:nextTick(function()
                if not captured_bb then return end
                performCropAndPin(captured_bb, rect, iv)
            end)
        end,
    }

    UIManager:show(overlay)
    scheduleRepaint("full")
end

-- ─────────────────────────────────────────────────────────────
-- Plugin class
-- ─────────────────────────────────────────────────────────────
local ImageCropPlugin = InputContainer:extend{
    name        = "imagecrop",
    fullname    = "Image Crop",
    is_doc_only = false,
}

function ImageCropPlugin:init()
    local IV = require("ui/widget/imageviewer")
    if IV._imagecrop_patched then return end
    IV._imagecrop_patched = true

    local orig_init = IV.init

    function IV:init()
        orig_init(self)
        if not self.button_table then return end

        local bt = self.button_table
        if bt.buttons and bt.buttons[1] then
            table.insert(bt.buttons[1], {
                text     = _("Crop"),
                id       = "imagecrop_btn",
                callback = function() launchCrop(self) end,
            })
        end

        if bt._buildButtons then
            for i = #bt, 1, -1 do bt[i] = nil end
            bt:_buildButtons()
        else
            local ButtonTable = require("ui/widget/buttontable")
            local new_bt = ButtonTable:new{
                width       = bt.width,
                buttons     = bt.buttons,
                zero_sep    = bt.zero_sep,
                show_parent = bt.show_parent,
            }
            if self.button_container and self.button_container[1] == bt then
                self.button_container[1] = new_bt
            end
            self.button_table = new_bt
        end
    end

    logger.info("ImageCrop: ImageViewer patched (two-tap mode).")
end

return ImageCropPlugin