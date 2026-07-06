"""
MCP Advisor brain.

Watches Balatro's exported game state and, whenever the in-game mod requests
analysis (you click a mouse side button), asks Claude for short strategic advice
via Claude Code headless mode (`claude -p`). That uses your Claude Code / Max
subscription login -- no API key, no per-request billing.

Run this in a terminal while you play:  python mcp_brain.py
Stop it with Ctrl+C.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ------------------------------- config -------------------------------
MODEL = "sonnet"        # "haiku" (fast) | "sonnet" (balanced) | "opus" (smartest)
POLL_SECONDS = 0.3        # how often to check for a new request
CLAUDE_TIMEOUT = 150      # seconds to wait for Claude per request (opus tail latency)
MAX_WORDS_HINT = 55       # keep advice short enough for the overlay

# Locate the claude executable (explicit path first, then PATH).
CLAUDE = r"C:\Users\resba\.local\bin\claude.exe"
if not Path(CLAUDE).exists():
    CLAUDE = shutil.which("claude") or "claude"

APPDATA = os.getenv("APPDATA")
BASE = Path(APPDATA) / "Balatro" / "mcp-bridge"
STATE_PATH = BASE / "mcp_gamestate.json"
SUGGEST_PATH = BASE / "mcp_suggestion.json"
LOG_PATH = BASE / "advice_log.jsonl"   # append-only history, for reviewing advice quality

SYSTEM = (
    "You are a Balatro strategy assistant giving fast in-game advice. "
    "You receive the current game state as JSON. Reply with SHORT, concrete, "
    f"actionable advice (at most ~{MAX_WORDS_HINT} words). Plain text only (no "
    "markdown, no emoji, no bullet characters, no headings). Focus on the single "
    "most important decision right now and give one brief reason. "
    "Do not use any tools; answer directly from the JSON. "
    "Card edition reference (an item's 'edition' field holds the English key on "
    "the left; use the correct name for the advice language and never mix them "
    "up): foil = +50 chips (中文: 闪箔); holo = +10 mult (中文: 全息); "
    "polychrome = x1.5 mult (中文: 多彩); negative = +1 joker slot (中文: 负片). "
    "Jokers and consumables include a 'desc' field = the card's exact in-game "
    "effect; base your reasoning on that, not on assumptions about the card."
)


def task_instruction(state: dict) -> str:
    """Pick advice guidance based on the decision on screen (state['context'])."""
    ctx = state.get("context")

    if ctx == "opening_booster":
        return (
            "The player opened a BOOSTER PACK and must choose cards. See 'booster' "
            "(kind, pick_count = how many they may take, choices). Recommend which specific "
            "card(s) to take (up to pick_count) and why, given their jokers, hand, and deck. "
            "IMPORTANT: if this is a Joker/Buffoon pack and joker_slots.used >= joker_slots.max "
            "(slots FULL), taking a joker forces SELLING one they already own -- name which "
            "existing joker to sell and why (weakest / least synergy), or say skip if none is "
            "worth displacing. Apply the same 'one must go' rule to consumable_slots for "
            "Tarot/Planet/Spectral packs. If nothing helps, say to skip the pack."
        )
    if ctx == "blind_select":
        return (
            "The player is choosing a BLIND. Use 'blind_select' (each slot's name, "
            "chip_mult, reward_dollars, state, skip_tag) and run_info.ante. Advise whether to "
            "PLAY or SKIP the on_deck blind, weighing the skip_tag reward and any boss effect "
            "against their current strength."
        )
    if ctx == "using_consumable":
        return (
            "The player is using a consumable. From 'consumables' and the hand, say which "
            "consumable to use and on which card(s), or to hold it."
        )
    if ctx == "shop":
        return (
            "The player is in the SHOP. From 'shop' (jokers_and_cards, vouchers, "
            "booster_packs with 'cost'), their cash and reroll_cost, recommend what to buy or "
            "skip (name items), and whether to reroll or save. Mind the economy: keep $5+ per "
            "$5 for interest; don't spend to zero without a strong reason. If joker_slots are "
            "full and you recommend buying a joker, say which owned joker to sell first."
        )
    if ctx == "playing_blind":
        return (
            "The player is playing a blind. Advise which cards to play or discard (respect "
            "run_info.blind_effect if present) and whether to use a consumable now. One brief "
            "reason. Exploit each joker's 'desc': jokers that scale off cards still HELD in hand "
            "(e.g. Raised Fist uses your lowest held card) reward playing or discarding your "
            "lowest held cards so a higher card sets the bonus. A card marked hidden:true is "
            "FACE-DOWN (a boss blind): you do NOT know its "
            "rank or suit, so never name or guess it -- reason like a player who cannot see it "
            "(if the whole hand is hidden, usually just play a hand to see, don't discard blindly)."
        )
    # round_eval / other / unknown -> still give useful advice from the snapshot.
    return (
        "Give the single most useful, concrete piece of advice for the current situation "
        "based on this JSON."
    )

# Map Balatro locale codes (G.SETTINGS.language) to language names for the prompt.
LANG_NAMES = {
    "en-us": "English",
    "es_419": "Spanish",
    "fr": "French",
    "de": "German",
    "it": "Italian",
    "nl": "Dutch",
    "pl": "Polish",
    "pt_br": "Brazilian Portuguese",
    "ru": "Russian",
    "ja": "Japanese",
    "ko": "Korean",
    "zh_CN": "Simplified Chinese",
    "zh_TW": "Traditional Chinese",
}


def language_instruction(state: dict) -> str:
    code = (state.get("language") or "en-us").strip()
    name = LANG_NAMES.get(code)
    if name:
        return f"Write the advice ONLY in {name}."
    # Unknown code: hand Claude the raw locale so it can still localize.
    return (f"Write the advice ONLY in the language used for the game "
            f"locale code '{code}'.")


def sanitize(text: str) -> str:
    """Keep Unicode intact (advice may be zh/ja/ko/ru/...). Strip only control
    characters that the overlay can't render (keep newline and tab)."""
    text = "".join(ch for ch in text if ch in "\n\t" or ord(ch) >= 32)
    return text.strip()


def ask_claude(state: dict) -> str:
    prompt = (SYSTEM + " " + task_instruction(state) + " " + language_instruction(state)
              + "\n\nGame state JSON:\n" + json.dumps(state, ensure_ascii=False)
              + "\n\nAdvice:")
    try:
        r = subprocess.run(
            # --strict-mcp-config with no --mcp-config => load no MCP servers,
            # so we don't pay to health-check every configured server per call.
            [CLAUDE, "-p", prompt, "--model", MODEL, "--strict-mcp-config"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=CLAUDE_TIMEOUT,
        )
    except FileNotFoundError:
        return "Cannot find the 'claude' CLI. Check the CLAUDE path in mcp_brain.py."
    except subprocess.TimeoutExpired:
        return "Claude took too long to respond. Try clicking again."

    out = (r.stdout or "").strip()
    if not out:
        err = (r.stderr or "").strip()
        return "Claude returned nothing." + (f" ({err[:120]})" if err else "")
    return sanitize(out)


def current_request_id():
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return data.get("request_id"), data
    except Exception:
        return None, None


def main():
    print("=" * 60)
    print(" MCP Advisor brain")
    print("=" * 60)
    print(f" claude : {CLAUDE}")
    print(f" model  : {MODEL}")
    print(f" watch  : {STATE_PATH}")
    print(f" answer : {SUGGEST_PATH}")
    BASE.mkdir(parents=True, exist_ok=True)

    # Mark any state already on disk as seen, so we only answer NEW requests.
    last_id, _ = current_request_id()
    if last_id:
        print(f" (ignoring existing request {last_id} from before startup)")
    print("\nReady. Play Balatro and click a mouse side button for advice.")
    print("Ctrl+C to stop.\n")

    while True:
        try:
            if STATE_PATH.exists():
                rid, data = current_request_id()
                if rid and rid != last_id:
                    last_id = rid
                    ncards = len(data.get("current_hand") or [])
                    njok = len(data.get("jokers") or [])
                    print(f"[{time.strftime('%H:%M:%S')}] request {rid} "
                          f"({ncards} cards, {njok} jokers) -> asking {MODEL}...")
                    t0 = time.time()
                    advice = ask_claude(data)
                    dt = time.time() - t0
                    SUGGEST_PATH.write_text(f"{rid}\n{advice}", encoding="utf-8")
                    try:
                        with LOG_PATH.open("a", encoding="utf-8") as lf:
                            lf.write(json.dumps({
                                "time": time.strftime("%Y-%m-%d %H:%M:%S"),
                                "request_id": rid, "model": MODEL,
                                "seconds": round(dt, 1),
                                "context": data.get("context"),
                                "language": data.get("language"),
                                "advice": advice, "state": data,
                            }, ensure_ascii=False) + "\n")
                    except Exception as e:
                        print(f"    ! log write failed: {e}")
                    print(f"    answered in {dt:.1f}s: {advice[:80]}"
                          + ("..." if len(advice) > 80 else ""))
            time.sleep(POLL_SECONDS)
        except KeyboardInterrupt:
            print("\nStopped.")
            break
        except Exception as e:
            print(f"  ! error: {e}")
            time.sleep(1)


if __name__ == "__main__":
    main()
