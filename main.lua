-- MCP Advisor: in-game overlay that shows AI suggestions for the current spot.
--
-- Trigger:  click a MOUSE SIDE BUTTON (back/forward = button 4 or 5).
--           -> exports the current game state and shows "Analyzing..."
-- A background process (mcp_brain.py) reads the state, asks Claude (via your
-- Claude Code / Max subscription in headless mode), and writes the advice back.
-- This mod polls for that answer and draws it on top of the game (fullscreen ok).
--
-- Files (under LOVE save dir = %APPDATA%/Balatro/):
--   write: mcp-bridge/mcp_gamestate.json   (state + request id, JSON)
--   read:  mcp-bridge/mcp_suggestion.json  (plain text: "<request_id>\n<advice>")

local mcpb = {
    -- CONFIG ------------------------------------------------------------
    analyze_buttons = { [4] = true, [5] = true }, -- mouse side buttons
    poll_interval   = 0.25,   -- seconds between checks for an answer
    timeout         = 60,     -- seconds before giving up on the brain
    panel_x         = 20,     -- top-left corner by default
    panel_y         = 20,
    panel_w         = 460,
    font_size       = 20,     -- overlay text size in pixels
    -- STATE -------------------------------------------------------------
    status      = 'idle',     -- idle | thinking | ready | timeout
    text        = '',
    pending_id  = nil,
    request_at  = 0,
    poll_accum  = 0,
    counter     = 0,
    font        = nil,
    title_font  = nil,
}

----------------------------------------------------------------------
-- Minimal JSON encoder (self-contained)
----------------------------------------------------------------------
local function json_quote(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
end
local ARRAY_MT = { __json = 'array' }
local function newarray() return setmetatable({}, ARRAY_MT) end
local function json_encode(v)
    local t = type(v)
    if v == nil then return 'null'
    elseif t == 'boolean' then return v and 'true' or 'false'
    elseif t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
        return tostring(v)
    elseif t == 'string' then return json_quote(v)
    elseif t == 'table' then
        local mt = getmetatable(v)
        local is_array = mt == ARRAY_MT
        if not is_array then
            local n = 0; for _ in pairs(v) do n = n + 1 end
            is_array = (n > 0 and n == #v)
        end
        if is_array then
            local parts = {}
            for i = 1, #v do parts[i] = json_encode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local parts = {}
            for k, val in pairs(v) do parts[#parts + 1] = json_quote(k) .. ':' .. json_encode(val) end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

----------------------------------------------------------------------
-- Field extractors
----------------------------------------------------------------------
local function get_enhancement(c)
    -- Only playing-card enhancements (Steel, Gold, Glass, ...) use 'm_' centers.
    local key = c and c.config and c.config.center and c.config.center.key
    if key and key:sub(1, 2) == 'm_' then return key end
    return 'none'
end
local function get_edition(c)
    local e = c and c.edition
    if not e then return 'none' end
    if e.foil then return 'foil' end
    if e.holo then return 'holo' end
    if e.polychrome then return 'polychrome' end
    if e.negative then return 'negative' end
    if e.type then return tostring(e.type) end
    return 'none'
end

local function get_language()
    local ok, code = pcall(function()
        if G.SETTINGS and G.SETTINGS.language then return G.SETTINGS.language end
        if G.LANG and G.LANG.key then return G.LANG.key end
        return nil
    end)
    if ok and code then return code end
    return 'en-us'
end

-- Describe one shop item (joker, playing card, consumable, voucher, or pack).
local function shop_item(c)
    local item = {}
    if c.cost then item.cost = c.cost end   -- shop items have a cost; pack choices don't
    item.name = (c.ability and c.ability.name)
        or (c.config and c.config.center and c.config.center.name) or 'Unknown'
    item.key = (c.config and c.config.center and c.config.center.key) or '?'
    if c.base and c.base.value then           -- it's a playing card
        item.rank = c.base.value
        item.suit = c.base.suit
    end
    local ed = get_edition(c);      if ed ~= 'none' then item.edition = ed end
    local enh = get_enhancement(c); if enh ~= 'none' then item.enhancement = enh end
    return item
end

local function collect_area(area)
    local list = newarray()
    if area and area.cards then
        for _, c in ipairs(area.cards) do list[#list + 1] = shop_item(c) end
    end
    return list
end

-- Map G.STATE (Balatro's state machine) to a decision context + raw number.
local function resolve_context()
    local num, ctx = -1, 'other'
    pcall(function()
        num = G.STATE or -1
        -- These overlays don't reliably set G.STATE (an open pack can report
        -- G.STATE = 999), so detect them by the presence of their data/UI first.
        if G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0 then
            ctx = 'opening_booster'; return
        end
        if G.blind_select then ctx = 'blind_select'; return end
        local S = G.STATES
        if S then
            if num == S.SELECTING_HAND or num == S.HAND_PLAYED or num == S.DRAW_TO_HAND then
                ctx = 'playing_blind'
            elseif num == S.SHOP then ctx = 'shop'
            elseif num == S.PLAY_TAROT then ctx = 'using_consumable'
            elseif num == S.BLIND_SELECT then ctx = 'blind_select'
            elseif num == S.ROUND_EVAL then ctx = 'round_eval'
            elseif num == S.TAROT_PACK or num == S.PLANET_PACK or num == S.SPECTRAL_PACK
                or num == S.STANDARD_PACK or num == S.BUFFOON_PACK then
                ctx = 'opening_booster'
            end
        end
    end)
    return ctx, num
end

-- Owned consumables (Tarot/Planet/Spectral) - relevant in most contexts.
local function collect_consumables()
    local list = newarray()
    pcall(function()
        if G.consumeables and G.consumeables.cards then
            for _, c in ipairs(G.consumeables.cards) do
                list[#list + 1] = {
                    name = (c.ability and c.ability.name)
                        or (c.config and c.config.center and c.config.center.name) or 'Unknown',
                    key = (c.config and c.config.center and c.config.center.key) or '?',
                    set = (c.ability and c.ability.set) or '?',
                }
            end
        end
    end)
    return list
end

-- Booster pack currently open: the offered cards and how many may be chosen.
-- Pack kind is inferred from the choice cards' set (G.STATE is unreliable here).
local function build_booster()
    local kind = 'Booster'
    pcall(function()
        local first = G.pack_cards and G.pack_cards.cards and G.pack_cards.cards[1]
        local set = first and first.ability and first.ability.set
        if set == 'Planet' then kind = 'Celestial (Planet cards)'
        elseif set == 'Tarot' then kind = 'Arcana (Tarot cards)'
        elseif set == 'Spectral' then kind = 'Spectral cards'
        elseif set == 'Joker' then kind = 'Buffoon (Jokers)'
        elseif first and first.base then kind = 'Standard (playing cards)'
        end
    end)
    local pick_count, shown = 1, 0
    pcall(function() pick_count = G.GAME.pack_choices or 1 end)
    pcall(function() shown = G.GAME.pack_size or 0 end)
    return {
        kind = kind,
        pick_count = pick_count,
        shown = shown,
        choices = collect_area(G.pack_cards),
    }
end

-- Blind-selection screen: the Small / Big / Boss choices.
local function build_blind_select()
    local out = newarray()
    pcall(function()
        local rr = G.GAME.round_resets
        if not rr or not rr.blind_choices then return end
        for _, slot in ipairs({ 'Small', 'Big', 'Boss' }) do
            local key = rr.blind_choices[slot]
            if key then
                local bdef = G.P_BLINDS and G.P_BLINDS[key]
                local entry = {
                    slot = slot,
                    is_boss = (slot == 'Boss'),
                    on_deck = (G.GAME.blind_on_deck == slot),
                    name = (bdef and bdef.name) or key,
                    reward_dollars = (bdef and bdef.dollars) or 0,
                    chip_mult = (bdef and bdef.mult) or 0,
                    state = (rr.loc_blind_states and rr.loc_blind_states[slot])
                        or (rr.blind_states and rr.blind_states[slot]) or '?',
                }
                if rr.blind_tags and rr.blind_tags[slot] then
                    local tkey = rr.blind_tags[slot]
                    local tdef = G.P_TAGS and G.P_TAGS[tkey]
                    entry.skip_tag = (tdef and tdef.name) or tkey
                end
                out[#out + 1] = entry
            end
        end
    end)
    return out
end

local function build_state(request_id)
    local GAME = G.GAME
    local cr = GAME.current_round or {}
    local state = {}
    state.request_id = request_id
    state.player_data = {
        cash = GAME.dollars or 0,
        hands_left = cr.hands_left or 0,
        discards_left = cr.discards_left or 0,
    }
    local blind_name, chips_to_beat = 'None', 0
    if GAME.blind then
        blind_name = GAME.blind.name or 'None'
        chips_to_beat = GAME.blind.chips or 0
    end
    state.run_info = {
        ante = (GAME.round_resets and GAME.round_resets.ante) or 0,
        round = GAME.round or 0,
        chips_to_beat = chips_to_beat,
        current_blind_name = blind_name,
    }
    local hand = newarray()
    if G.hand and G.hand.cards then
        for _, c in ipairs(G.hand.cards) do
            hand[#hand + 1] = {
                rank = (c.base and c.base.value) or '?',
                suit = (c.base and c.base.suit) or '?',
                enhancement = get_enhancement(c),
                edition = get_edition(c),
                seal = c.seal or 'none',
            }
        end
    end
    state.current_hand = hand
    local jokers = newarray()
    if G.jokers and G.jokers.cards then
        for _, j in ipairs(G.jokers.cards) do
            jokers[#jokers + 1] = {
                name = (j.ability and j.ability.name)
                    or (j.config and j.config.center and j.config.center.name) or 'Unknown',
                key = (j.config and j.config.center and j.config.center.key) or '?',
                edition = get_edition(j),
            }
        end
    end
    state.jokers = jokers
    state.deck_size = (G.deck and G.deck.cards and #G.deck.cards) or 0

    -- Slot capacity: picking up a card when full forces selling/removing one,
    -- so the advisor can name which to drop instead of ignoring the tradeoff.
    pcall(function()
        state.joker_slots = {
            used = (G.jokers and G.jokers.cards and #G.jokers.cards) or 0,
            max = (G.jokers and G.jokers.config and G.jokers.config.card_limit) or 5,
        }
    end)
    pcall(function()
        state.consumable_slots = {
            used = (G.consumeables and G.consumeables.cards and #G.consumeables.cards) or 0,
            max = (G.consumeables and G.consumeables.config and G.consumeables.config.card_limit) or 2,
        }
    end)

    -- What decision is on screen right now (drives extra data + brain advice).
    local context, game_state = resolve_context()
    state.context = context
    state.game_state = game_state

    -- Consumables are relevant in almost every context.
    state.consumables = collect_consumables()

    -- Boss debuff + current score while playing a blind.
    if context == 'playing_blind' then
        pcall(function()
            local dt = G.GAME.blind and G.GAME.blind.loc_debuff_text
            if dt and dt ~= '' then state.run_info.blind_effect = dt end
        end)
        pcall(function() state.run_info.chips_scored = G.GAME.chips end)
    end

    -- Shop: contents only when actually in the shop (never stale during a blind).
    local in_shop = (context == 'shop')
    state.in_shop = in_shop
    local shop = {
        reroll_cost = (GAME.current_round and GAME.current_round.reroll_cost) or 0,
        jokers_and_cards = newarray(),
        vouchers = newarray(),
        booster_packs = newarray(),
    }
    if in_shop then
        shop.jokers_and_cards = collect_area(G.shop_jokers)
        shop.vouchers = collect_area(G.shop_vouchers)
        shop.booster_packs = collect_area(G.shop_booster)
    end
    state.shop = shop

    -- Booster pack being opened: which card(s) to pick.
    if context == 'opening_booster' then
        state.booster = build_booster()
    end

    -- Blind selection: play vs skip.
    if context == 'blind_select' then
        state.blind_select = build_blind_select()
    end

    state.language = get_language()   -- Balatro locale code, e.g. en-us, zh_CN, fr
    return state
end

----------------------------------------------------------------------
-- Request / response
----------------------------------------------------------------------
local function request_analysis()
    if not G or not G.GAME then
        mcpb.status = 'ready'
        mcpb.text = 'No active game to analyze. Start a run first.'
        return
    end
    mcpb.counter = mcpb.counter + 1
    local rid
    local ok_t, tm = pcall(function() return os.time() end)
    rid = (ok_t and tostring(tm) or '0') .. '-' .. tostring(mcpb.counter)

    local state = build_state(rid)
    love.filesystem.createDirectory('mcp-bridge')
    love.filesystem.write('mcp-bridge/mcp_gamestate.json', json_encode(state))

    mcpb.pending_id = rid
    mcpb.status = 'thinking'
    mcpb.text = ''
    mcpb.request_at = love.timer.getTime()
    print('[MCP Advisor] Requested analysis (' .. rid .. ')')
end

local function check_answer()
    local info = love.filesystem.getInfo('mcp-bridge/mcp_suggestion.json')
    if not info then return end
    local contents = love.filesystem.read('mcp-bridge/mcp_suggestion.json')
    if not contents or contents == '' then return end
    local nl = contents:find('\n')
    local rid, body
    if nl then
        rid = contents:sub(1, nl - 1)
        body = contents:sub(nl + 1)
    else
        rid, body = contents, ''
    end
    rid = (rid or ''):gsub('%s+$', '')
    if mcpb.pending_id and rid == mcpb.pending_id and mcpb.status == 'thinking' then
        mcpb.status = 'ready'
        mcpb.text = body
        print('[MCP Advisor] Answer received (' .. rid .. ')')
    end
end

----------------------------------------------------------------------
-- Hook mouse side buttons (without breaking Balatro's own handling)
----------------------------------------------------------------------
local orig_mousepressed = love.mousepressed
function love.mousepressed(x, y, button, istouch, presses)
    if orig_mousepressed then orig_mousepressed(x, y, button, istouch, presses) end
    if mcpb.analyze_buttons[button] then
        local ok, err = pcall(request_analysis)
        if not ok then print('[MCP Advisor] request error: ' .. tostring(err)) end
    end
end

----------------------------------------------------------------------
-- Poll for the answer each ~poll_interval seconds
----------------------------------------------------------------------
local orig_update = love.update
function love.update(dt)
    if orig_update then orig_update(dt) end
    mcpb.poll_accum = mcpb.poll_accum + (dt or 0)
    if mcpb.poll_accum >= mcpb.poll_interval then
        mcpb.poll_accum = 0
        if mcpb.status == 'thinking' then
            pcall(check_answer)
            if mcpb.status == 'thinking'
                and (love.timer.getTime() - mcpb.request_at) > mcpb.timeout then
                mcpb.status = 'timeout'
                mcpb.text = 'No answer in time. Is mcp_brain.py running in a terminal?'
            end
        end
    end
end

----------------------------------------------------------------------
-- Draw the overlay panel on top of everything
----------------------------------------------------------------------
-- Build the overlay font from Balatro's current-language font FILE at our own
-- small size, so non-Latin advice (zh/ja/ko/ru/...) has correct glyphs WITHOUT
-- inheriting the game's huge render size. Cached; rebuilt when language changes.
local function get_font()
    local size = mcpb.font_size or 20
    local file
    pcall(function() file = G and G.LANG and G.LANG.font and G.LANG.font.file end)

    if file and (mcpb.font_file ~= file or mcpb.font_size_cur ~= size or not mcpb.font_obj) then
        local ok, f = pcall(love.graphics.newFont, file, size)
        if ok and f then
            mcpb.font_obj = f
            mcpb.font_file = file
            mcpb.font_size_cur = size
        end
    end
    if mcpb.font_obj then return mcpb.font_obj end

    -- Fallback: LOVE default font at our size (Latin only, but correctly sized).
    if not mcpb.font or mcpb.font_fallback_size ~= size then
        mcpb.font = love.graphics.newFont(size)
        mcpb.font_fallback_size = size
    end
    return mcpb.font
end

local function header_line()
    if mcpb.status == 'thinking' then
        local dots = string.rep('.', 1 + (math.floor(love.timer.getTime() * 2) % 3))
        return 'MCP Advisor  -  Analyzing' .. dots
    elseif mcpb.status == 'ready' then
        return 'MCP Advisor  -  Advice'
    elseif mcpb.status == 'timeout' then
        return 'MCP Advisor  -  No response'
    else
        return 'MCP Advisor  -  side-click for advice'
    end
end

local orig_draw = love.draw
function love.draw()
    if orig_draw then orig_draw() end
    local ok = pcall(function()
        local font = get_font()
        local pad = 12
        local x, y, w = mcpb.panel_x, mcpb.panel_y, mcpb.panel_w
        local title = header_line()
        local body = mcpb.text or ''

        local _, tlines = font:getWrap(title, w - 2 * pad)
        local _, blines = font:getWrap(body, w - 2 * pad)
        local lh = font:getHeight()
        local th = math.max(#tlines, 1) * lh
        local bh = (#blines) * lh
        local h = pad + th + (body ~= '' and (6 + bh) or 0) + pad

        love.graphics.push('all')
        love.graphics.origin()
        love.graphics.setFont(font)
        -- background
        love.graphics.setColor(0, 0, 0, 0.78)
        love.graphics.rectangle('fill', x, y, w, h, 8, 8)
        love.graphics.setColor(1, 0.85, 0.2, 0.9)
        love.graphics.rectangle('line', x, y, w, h, 8, 8)
        -- title
        love.graphics.setColor(1, 0.85, 0.2, 1)
        love.graphics.printf(title, x + pad, y + pad, w - 2 * pad, 'left')
        -- body
        if body ~= '' then
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.printf(body, x + pad, y + pad + th + 6, w - 2 * pad, 'left')
        end
        love.graphics.pop()
    end)
    if not ok then love.graphics.setColor(1, 1, 1, 1) end
end

print('[MCP Advisor] Loaded. Click a mouse side button (4/5) for advice.')
