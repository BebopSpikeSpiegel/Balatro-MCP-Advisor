# Balatro MCP Advisor

An **in-game AI advisor** for [Balatro](https://www.playbalatro.com/). Click a mouse
side button while you play and a panel is drawn **on top of the game** with Claude's
suggestion for whatever decision is on screen — which cards to play or discard, what to
buy in the shop, which booster-pack card to take, whether to play or skip a blind — in
**your game's language**.

It runs on **Claude Code** (your Claude Max/Pro login) in headless mode, so there is **no
API key and no per-request billing**.

> Forked from [AbdelrahmanElmughrabi/Balatro-MCP-Server](https://github.com/AbdelrahmanElmughrabi/Balatro-MCP-Server).
> The upstream project exported game state to JSON for Claude Desktop to read on demand.
> This fork pivots it into a real-time, on-screen advisor. The original `balatro_mcp_server.py`
> / `main.py` are kept for reference; the advisor does not use them.

## How it works

```
Balatro (fullscreen)
  └─ Overlay mod (Lua, in-process, via Steamodded):
        • detects the current decision (Balatro's G.STATE machine)
        • exports game state -> mcp-bridge/mcp_gamestate.json
        • draws the suggestion panel on top of the game
        • polls mcp-bridge/mcp_suggestion.json for the answer
              ▲ writes            │ reads
              │                   ▼
  Brain (mcp_brain.py, background):
        • watches the state file
        • calls `claude -p` (headless Claude Code = your Max/Pro login)
        • writes a short, localized suggestion back
```

The game and the brain talk only through two small JSON files, so the game never blocks
on the network.

## What it advises on

Driven by Balatro's state machine, so it covers every decision screen (with a generic
fallback for anything unmapped):

| Situation | Advice |
| --- | --- |
| Playing a blind | which cards to play / discard, use a consumable, aware of the boss debuff |
| Shop | what to buy / skip, reroll or save, economy/interest |
| Booster pack | which card(s) to take (up to the pack's pick count), or skip |
| Blind select | play vs. skip, weighing the skip tag and boss effect |
| Using a consumable | which tarot/planet/spectral to use and on what |

## Requirements

- **Balatro** (Steam version) with **[Lovely injector](https://github.com/ethangreen-dev/lovely-injector)**
  + **[Steamodded](https://github.com/Steamodded/smods)** installed
- **[Claude Code](https://claude.com/claude-code)** CLI, logged in (Max or Pro)
- **Python 3.11+**
- Windows (paths below are Windows; adaptable elsewhere)

## Install

1. **Install Lovely + Steamodded** (see their repos). Confirm Steamodded loads in-game.
2. **Install the overlay mod** — copy the `mod/mcp-bridge/` folder to:
   ```
   %APPDATA%\Balatro\Mods\mcp-bridge\
   ```
   (contains `main.lua` + `mcp_bridge.json`). Restart Balatro; you should see
   `[MCP Advisor] Loaded` in the console and "MCP Advisor" in the mods list.
3. **Set up Python** (only needed for the optional legacy MCP server; the advisor brain
   itself uses just the standard library):
   ```
   python -m venv .venv
   .venv\Scripts\pip install mcp
   ```

## Use

1. Launch Balatro (fullscreen is fine).
2. Start the brain: double-click **`start_advisor.bat`** (leave it open while you play).
3. In-game, **click a mouse side button** (button 4/5) for advice on the current spot.
   The panel shows "Analyzing…", then the suggestion (~10s).

## Configuration

`mcp_brain.py` (top of file):
- `MODEL` — `haiku` (fast) / `sonnet` (default) / `opus` (smartest)

`main.lua` (`mcpb` config block):
- `analyze_buttons` — which mouse buttons trigger analysis (default 4 and 5)
- `font_size`, `panel_w`, `panel_x`, `panel_y` — overlay size/position

The advice language follows Balatro's language setting automatically.

## Credits

- Upstream: [AbdelrahmanElmughrabi/Balatro-MCP-Server](https://github.com/AbdelrahmanElmughrabi/Balatro-MCP-Server)
- [Steamodded](https://github.com/Steamodded/smods) and
  [Lovely injector](https://github.com/ethangreen-dev/lovely-injector)

## License

[MIT](LICENSE) © 2026 BebopSpikeSpiegel. Covers the advisor additions in this fork
(`main.lua`, `mcp_brain.py`, the mod, launcher). Upstream files remain the original
author's work.
