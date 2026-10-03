# luanti-aibot

A bot that plays [VoxeLibre](https://content.luanti.org/packages/Wuzzy/mineclone2/) (the Minecraft-like game for [Luanti](https://www.luanti.org/)) by itself, from an empty inventory to killing the Ender Dragon.

You type `/bot auto` and watch. In my run it finished the whole game, confirmed by the in-game "Free the End" advancement, with four deaths along the way.

It is a scripted agent with an LLM in the loop, not an AI that learned to play. The [Limitations](#limitations) section says exactly where the shortcuts are.

## What it does

Starting with nothing, the bot works through six stages:

1. **Tech tree.** Wood, stone, iron and diamond pickaxes, with a crafting table and smelting along the way.
2. **Nether.** Bucket, flint and steel, obsidian made by pouring water on lava, then a Nether portal.
3. **Combat.** Iron sword and armor, hunted and cooked food, then blaze rods from blazes in the Nether wastes.
4. **Eyes of ender.** Ender pearls from endermen in the warped forest, crafted with blaze powder into 12 eyes.
5. **The End.** Tunnels to the nearest stronghold, fills the portal frame and goes through.
6. **Dragon.** Climbs the ten towers, destroys the end crystals, then fights the dragon.

## How it works

The whole mod is one Lua file (`init.lua`, about 1,900 lines) running inside the game server.

- **Planner.** A built-in planner looks at the bot's inventory, pickaxe tier and location and works out the next sensible step.
- **LLM.** Every few seconds the bot sends an observation (position, inventory, what it can see, the planner's suggestion, recent actions) to a language model and gets back one action as JSON. It supports a local model through [Ollama](https://ollama.com/) (`llama3.2` by default) or Gemini.
- **Arbitration.** In auto mode the model's pick only counts when it matches the planner's next step. Otherwise the planner's step runs instead. If the model can't be reached, the planner carries on alone.
- **Persistence.** Items, progress, deaths and position are kept in the world's mod storage, so the bot survives restarts and respawns.

## Install

1. Copy this folder into your Luanti `mods` directory (on macOS: `~/Library/Application Support/minetest/mods/`).
2. Add these lines to `minetest.conf`:

   ```
   secure.http_mods = aibot
   aibot.provider = ollama
   aibot.ollama_model = llama3.2
   ```

3. Start Ollama and pull the model: `ollama pull llama3.2`.
4. Create a VoxeLibre world, enable the `aibot` mod, and join.

To use Gemini instead, set `aibot.provider = gemini` and put your own key in `aibot.gemini_key`. Keep that key in `minetest.conf` only; never commit it.

## Commands

| Command | What it does |
| --- | --- |
| `/bot spawn` | Spawn the bot next to you (or bring it back with its saved items) |
| `/bot auto` | Play the whole game by itself |
| `/bot goal <text>` | Give it a smaller goal instead |
| `/bot status` | Health, deaths, pickaxe, goal and inventory |
| `/bot watch` | Teleport yourself to the bot |
| `/bot come` | Bring the bot to you |
| `/bot stop` / `/bot go` | Pause and resume |
| `/bot remove` | Put the bot away, keeping its items |
| `/bot reset` | Wipe the bot and its saved items |

Stay near the bot while it plays: animals and monsters only spawn around a player.

## Limitations

- **The planner makes most decisions.** The model is consulted every step, but the planner overrules it whenever the two disagree.
- **Movement and building are shortcuts.** The bot digs instantly, places blocks without a real inventory, and tunnels in straight lines with no real pathfinding.
- **It knows the map.** It reads the nearest Nether wastes, warped forest and stronghold from the game's data instead of exploring for them.
- **Combat is real but softened.** Monsters can hurt and kill it, but it keeps its items on death, takes no fall or lava damage, and heals without a hunger bar.
- **The dragon fight was easy.** In my run the bot ended up beside the dragon and finished it at full health, so that fight was not a hard-won one.
- **Tested on one setup.** One world, one VoxeLibre version, on a MacBook Air.

## Next steps

- Real pathfinding instead of straight tunnels
- A real inventory and timed digging
- Letting the model make more of the decisions

## Credits

Built with help from Claude (Anthropic), which wrote most of the Lua while I tested each stage in the game and reported what happened.
