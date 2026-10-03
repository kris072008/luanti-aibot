-- aibot v21: an AI bot for Luanti / VoxeLibre that works its way up the tech tree by itself.
-- The AI model (Ollama or Gemini) chooses actions; a built-in planner suggests the next
-- step and takes over whenever the model picks something that makes no progress.
local http = minetest.request_http_api()
local S = minetest.settings
local KEY = S:get("aibot.gemini_key") or ""
local MODEL = S:get("aibot.model") or "gemini-2.5-flash"
local PROVIDER = S:get("aibot.provider") or "gemini"
local OLLAMA_MODEL = S:get("aibot.ollama_model") or "llama3.2"
local OLLAMA_URL = S:get("aibot.ollama_url") or "http://127.0.0.1:11434"
local INTERVAL = tonumber(S:get("aibot.think_interval")) or 8

local function chat(msg) minetest.chat_send_all("<AIBot> " .. msg) end
local function round(x) return math.floor(x + 0.5) end
local function feet(pos) return {x = round(pos.x), y = math.floor(pos.y + 0.6), z = round(pos.z)} end
local function ndef(p) return minetest.registered_nodes[minetest.get_node(p).name] end
local function solid(p) local d = ndef(p); return d and d.walkable end

---------------------------------------------------------------- saved state (one bot per world)
-- The bot's items, pickaxe level, goal and position live in the world's save, not in the
-- entity, so they survive restarts, re-spawns and the bot's area being unloaded.
local storage = minetest.get_mod_storage()
local BOT -- the one live bot entity
local function load_state()
	local d = minetest.deserialize(storage:get_string("state")) or {}
	d.inv = d.inv or {}; d.tier = d.tier or 0; d.goal = d.goal or "beat the game"
	return d
end
local function write_state(st) storage:set_string("state", minetest.serialize(st)) end
local function save_state(self)
	local p = self.object:get_pos()
	write_state({id = self.id, inv = self.inv, tier = self.tier, goal = self.goal, smelts = self.smelts, portal = self.portal,
		nportal = self.nportal, reached = self.reached, hp = self.hp, deaths = self.deaths, heading = self.heading,
		killer = self.killer, away = self.away, wastes = self.wastes, warped = self.warped, shrine = self.shrine,
		bed = self.bed, spike = self.spike, won = self.won, todo = self.todo, todo_fail = self.todo_fail,
		pos = p and vector.round(p) or load_state().pos})
end
local function live_bot() if BOT and BOT.object:get_pos() then return BOT end end

-- Keep the bot's part of the world running wherever the player is. One block is held at a
-- time; the hold is module-wide so it survives the bot's entity being reloaded.
local HELD, HELD_KEY
local function hold(pos)
	local key = math.floor(pos.x / 16) .. "," .. math.floor(pos.y / 16) .. "," .. math.floor(pos.z / 16)
	if key == HELD_KEY then return end
	local bp = vector.round(pos)
	if minetest.forceload_block(bp, true, -1) then
		if HELD then minetest.forceload_free_block(HELD, true) end
		HELD, HELD_KEY = bp, key
	end
end
-- if the bot has dropped out of the running world, load its last position so it wakes up again
local wake_t = 0
minetest.register_globalstep(function(dtime)
	wake_t = wake_t + dtime
	if wake_t < 5 then return end
	wake_t = 0
	if live_bot() or #minetest.get_connected_players() == 0 then return end
	local st = load_state()
	if st.pos and st.id and not st.away then
		HELD_KEY = nil
		hold(st.pos)
		minetest.emerge_area(vector.subtract(st.pos, 16), vector.add(st.pos, 16))
	end
end)

---------------------------------------------------------------- block categories
local CATS = {wood = {}, stone = {}, coal = {}, iron = {}, diamond = {}, gravel = {}, obsidian = {}, water = {}, lava = {}}
local NAME2CAT, ALL = {}, {}
local TIER_NEED = {stone = 1, coal = 1, iron = 2, diamond = 3, obsidian = 4}
local TIER_NAME = {[0] = "none", "wooden", "stone", "iron", "diamond"}

minetest.register_on_mods_loaded(function()
	for name, def in pairs(minetest.registered_nodes) do
		local g = def.groups or {}
		local cat
		if (g.tree or name:match("tree$") or name:match("_log$") or name:match("trunk$"))
				and not name:find("leave") and not name:find("sapling") and not name:find("stripped") then
			cat = "wood"
		elseif name == "mcl_core:stone" or name == "default:stone" or name == "mcl_deepslate:deepslate"
				or name == "mcl_nether:netherrack" or name == "mcl_end:end_stone" then cat = "stone"
		elseif name:find("with_coal") then cat = "coal"
		elseif name:find("with_iron") then cat = "iron"
		elseif name:find("with_diamond") then cat = "diamond"
		elseif name:match(":gravel$") then cat = "gravel"
		elseif name:match(":obsidian$") then cat = "obsidian"
		elseif g.water then cat = "water"
		elseif g.lava then cat = "lava"
		end
		if cat then table.insert(CATS[cat], name); NAME2CAT[name] = cat; table.insert(ALL, name) end
	end
end)

local function nearest_of(cat, p, radius, skip, miny)
	local list = CATS[cat]
	if not list or #list == 0 then return nil end
	local r = {x = radius, y = math.min(radius, 24), z = radius}
	local found = minetest.find_nodes_in_area(vector.subtract(p, r), vector.add(p, r), list)
	local best, bd
	for _, n in ipairs(found) do
		if not (skip and skip[minetest.hash_node_position(n)]) and not (miny and n.y < miny) then
			local d = vector.distance(n, p)
			if not bd or d < bd then best, bd = n, d end
		end
	end
	return best
end

local function is_source(name) return name:find("_source") ~= nil end
local function nearest_source(cat, p, radius, skip, ry)
	local r = {x = radius, y = ry or radius, z = radius}
	local found = minetest.find_nodes_in_area(vector.subtract(p, r), vector.add(p, r), CATS[cat])
	local best, bd
	for _, n in ipairs(found) do
		if is_source(minetest.get_node(n).name) and not (skip and skip[minetest.hash_node_position(n)]) then
			local d = vector.distance(n, p)
			if not bd or d < bd then best, bd = n, d end
		end
	end
	return best
end
local function in_nether(pos)
	if rawget(_G, "mcl_worlds") and mcl_worlds.pos_to_dimension then
		return mcl_worlds.pos_to_dimension(pos) == "nether"
	end
	return pos.y < -28000
end
local function in_end(pos)
	if rawget(_G, "mcl_worlds") and mcl_worlds.pos_to_dimension then
		return mcl_worlds.pos_to_dimension(pos) == "end"
	end
	return pos.y < -20000 and pos.y >= -28000
end
-- the middle of the main End island (where the exit portal stands)
local function end_center()
	local V = rawget(_G, "mcl_vars") or {}
	local c = V.mg_end_exit_portal_pos
	if c then return {x = c.x, y = c.y, z = c.z} end
	return {x = 0, y = (V.mg_end_min or -27073) + 71, z = 0}
end
local FRAME, FRAME_EYE, END_PORTAL = "mcl_portals:end_portal_frame", "mcl_portals:end_portal_frame_eye", "mcl_portals:portal_end"
-- the stronghold nearest to p (the game keeps the list that eyes of ender fly toward)
local function nearest_stronghold(p)
	local reg = rawget(_G, "mcl_structures") and mcl_structures.registered_structures
	local list = reg and reg["end_shrine"] and reg["end_shrine"].static_pos
	local best, bd
	for _, q in pairs(list or {}) do
		local d = math.sqrt((q.x - p.x) ^ 2 + (q.z - p.z) ^ 2)
		if not bd or d < bd then best, bd = q, d end
	end
	return best and {x = best.x, y = best.y, z = best.z}, bd
end

local function biome_at(p)
	local d = minetest.get_biome_data(p)
	return d and minetest.get_biome_name(d.biome) or ""
end
-- nearest place with the given biome, found by sampling rings around p (works on unexplored land)
local function find_biome(p, name, maxr)
	for r = 32, maxr, 32 do
		local n = math.max(8, math.floor(2 * math.pi * r / 32))
		for i = 0, n - 1 do
			local a = 2 * math.pi * i / n
			local q = {x = round(p.x + r * math.cos(a)), y = p.y, z = round(p.z + r * math.sin(a))}
			if biome_at(q) == name then
				local deeper = {x = round(p.x + (r + 24) * math.cos(a)), y = p.y, z = round(p.z + (r + 24) * math.sin(a))}
				return (biome_at(deeper) == name) and deeper or q, r
			end
		end
	end
end
local ANIMALS = {"cow", "pig", "sheep", "chicken", "mooshroom", "rabbit"}
local function mob_kind(le)
	if not le or not le.is_mob or (le.health or 1) <= 0 then return nil end
	local n = le.name or ""
	if n:find("dragon") then return "dragon" end
	if n:find("blaze") or n:find("elemental_fire") then return "blaze" end
	if n:find("enderman") or n:find("rover") then return "ender" end
	if le.type == "animal" then
		for _, a in ipairs(ANIMALS) do if n:find(a) then return "food" end end
		return "animal"
	end
	if le.type == "monster" then return "monster" end
	return "other"
end
-- an open spot right next to a portal block (not inside it, not inside a wall)
local function beside(p)
	for _, o in ipairs({{0, 1}, {0, -1}, {1, 0}, {-1, 0}, {0, 2}, {0, -2}, {2, 0}, {-2, 0}}) do
		local c = {x = p.x + o[1], y = p.y, z = p.z + o[2]}
		local n1, n2 = minetest.get_node(c).name, minetest.get_node({x = c.x, y = c.y + 1, z = c.z}).name
		if not solid(c) and not solid({x = c.x, y = c.y + 1, z = c.z}) and not n1:find("portal") and not n2:find("portal") then
			return {x = c.x, y = c.y - 0.45, z = c.z}
		end
	end
	return {x = p.x, y = p.y - 0.45, z = p.z + 2}
end
local ARMOR = {helmet = 2, chestplate = 6, leggings = 5, boots = 2} -- armor points, 4% less damage each

---------------------------------------------------------------- inventory roles
local function role_of(name)
	if NAME2CAT[name] == "wood" then return "log" end
	local g = minetest.get_item_group
	if name:find("sword") then return name:find("iron") and "sword" or nil end
	if name:find("helmet_iron") then return "helmet" end
	if name:find("chestplate_iron") then return "chestplate" end
	if name:find("leggings_iron") then return "leggings" end
	if name:find("boots_iron") then return "boots" end
	if name:find("blaze_rod") or name:find("flaming_rod") then return "rod" end
	if name:find("blaze_powder") or name:find("flaming_powder") then return "powder" end
	if name:find("ender_pearl") then return "pearl" end
	if name:find("ender_eye") then return "eye" end
	if name:find("mcl_mobitems:cooked_") then return "food" end
	if name:match("^mcl_mobitems:(.+)$") and ({beef = 1, porkchop = 1, mutton = 1, chicken = 1, rabbit = 1})[name:match("^mcl_mobitems:(.+)$")] then return "rawfood" end
	if name:find("bucket_water") then return "wbucket" end
	if name:find("bucket_empty") then return "bucket" end
	if name:find("flint_and_steel") then return "fns" end
	if name:match(":flint$") then return "flint" end
	if name:match(":obsidian$") then return "obsidian" end
	if name:find("crafting_table") then return "table" end
	if name:find("furnace") then return "furnace" end
	if name:find("pick") then return nil end
	if g(name, "stick") > 0 or name:match(":stick$") then return "stick" end
	if g(name, "wood") > 0 then return "plank" end
	if g(name, "cobble") > 0 or name:find("cobble") then return "cobble" end
	if name:find("raw_iron") or name:find("iron_lump") then return "raw_iron" end
	if name:find("iron_ingot") or name:find("steel_ingot") then return "ingot" end
	if name:find("coal") and not name:find("block") and not name:find("with_") then return "coal" end
	if name:match(":diamond$") then return "diamond" end
	local d = minetest.registered_nodes[name]
	if d and d.walkable then return "block" end
end

local P, T, C, I, D = "plank", "stick", "cobble", "ingot", "diamond"
local RECIPES = {
	planks = {w = 1, grid = {"log"}},
	sticks = {w = 1, grid = {P, P}},
	crafting_table = {w = 2, grid = {P, P, P, P}},
	wooden_pickaxe = {w = 3, grid = {P, P, P, "", T, "", "", T, ""}, table = true, tier = 1},
	stone_pickaxe = {w = 3, grid = {C, C, C, "", T, "", "", T, ""}, table = true, tier = 2},
	iron_pickaxe = {w = 3, grid = {I, I, I, "", T, "", "", T, ""}, table = true, tier = 3},
	diamond_pickaxe = {w = 3, grid = {D, D, D, "", T, "", "", T, ""}, table = true, tier = 4},
	furnace = {w = 3, grid = {C, C, C, C, "", C, C, C, C}, table = true},
	bucket = {w = 3, grid = {I, "", I, "", I, "", "", "", ""}, table = true},
	flint_and_steel = {w = 2, grid = {I, "flint"}},
	blaze_powder = {w = 1, grid = {"rod"}},
	ender_eye = {w = 2, grid = {"powder", "pearl"}},
	iron_sword = {w = 1, grid = {I, I, T}, table = true, only = "sword"},
	iron_helmet = {w = 3, grid = {I, I, I, I, "", I, "", "", ""}, table = true, only = "helmet"},
	iron_chestplate = {w = 3, grid = {I, "", I, I, I, I, I, I, I}, table = true, only = "chestplate"},
	iron_leggings = {w = 3, grid = {I, I, I, I, "", I, I, "", I}, table = true, only = "leggings"},
	iron_boots = {w = 3, grid = {I, "", I, I, "", I, "", "", ""}, table = true, only = "boots"},
}

local SYSTEM = [[You control a bot in a Minecraft-like game (VoxeLibre). Pick ONE next action
that moves toward the goal. Reply with JSON only, one of:
{"action":"collect","what":"wood|stone|coal|iron|diamond|gravel|obsidian","count":4,"why":"..."}
{"action":"craft","what":"planks|sticks|crafting_table|wooden_pickaxe|stone_pickaxe|furnace|iron_ingot|iron_pickaxe|diamond_pickaxe|bucket|flint_and_steel|iron_sword|iron_helmet|iron_chestplate|iron_leggings|iron_boots|blaze_powder|ender_eye","count":1,"why":"..."}
{"action":"fill_bucket","why":"..."}           (fill the bucket at nearby water)
{"action":"make_obsidian","why":"..."}         (pour water on nearby lava; needs a water bucket)
{"action":"build_portal","why":"..."}          (needs 10 obsidian + flint_and_steel, on the surface)
{"action":"enter_portal","why":"..."}          (walk into the portal that is already built)
{"action":"hunt_food","why":"..."}             (kill animals for meat)
{"action":"cook_food","why":"..."}             (cook raw meat in the furnace)
{"action":"hunt_blaze","why":"..."}            (fight blazes in the Nether for blaze rods)
{"action":"hunt_ender","why":"..."}            (fight endermen for ender pearls)
{"action":"open_end","why":"..."}              (in the stronghold: put eyes in the portal frame and enter)
{"action":"crystal","why":"..."}               (in the End: climb to the next end crystal and destroy it)
{"action":"fight_dragon","why":"..."}          (in the End: fight the Ender Dragon)
{"action":"go_overworld","why":"..."}          (leave the Nether through the portal)
{"action":"bore","why":"..."}                  (tunnel and bridge safely through the Nether)
{"action":"descend","depth":12,"why":"..."}   (dig a staircase down to find ores)
{"action":"surface","why":"..."}               (climb back up to daylight)
{"action":"explore","dir":"north","why":"..."} (dir is ONE of north, south, east, west)
{"action":"follow","player":"name","why":"..."}
{"action":"say","text":"...","why":"..."}
Rules: stone and coal need a wooden pickaxe, iron needs a stone pickaxe, diamond needs an iron
pickaxe. Pickaxes and the furnace need a crafting_table. The planner's suggestion is usually
the right move; follow it unless you have a clear reason not to.]]

---------------------------------------------------------------- the bot
minetest.register_entity("aibot:bot", {
	initial_properties = {
		physical = true, collide_with_objects = false,
		collisionbox = {-0.3, 0, -0.3, 0.3, 1.8, 0.3},
		visual = "cube", visual_size = {x = 0.6, y = 1.8},
		textures = {"aibot_bot.png", "aibot_bot.png", "aibot_bot.png",
			"aibot_bot.png", "aibot_bot.png", "aibot_bot.png"},
		nametag = "AIBot", hp_max = 20, static_save = true, stepheight = 0.6,
	},
	_hittable_by_projectile = true, -- arrows and fireballs can hit the bot

	on_activate = function(self, staticdata)
		local d = minetest.deserialize(staticdata or "") or {}
		local live = live_bot()
		local st = load_state()
		-- bots made by older versions carried their own items: fold those into the shared save
		if not d.v and (d.inv ~= nil or d.tier ~= nil) then
			local into = live or st
			for name, n in pairs(d.inv or {}) do into.inv[name] = (into.inv[name] or 0) + n end
			into.tier = math.max(into.tier or 0, d.tier or 0)
			if live then save_state(live) else write_state(st) end
		end
		if live or (st.id and d.id ~= st.id) then
			self.gone = true -- a newer bot exists; this one is a leftover copy
			self.object:remove()
			return
		end
		self.id = st.id or 1
		self.goal, self.inv, self.tier, self.smelts = st.goal, st.inv, st.tier, st.smelts
		self.portal, self.nportal, self.reached = st.portal, st.nportal, st.reached
		self.hp, self.deaths, self.heading = st.hp or 20, st.deaths or 0, st.heading
		self.hit_t, self.strike_t, self.eat_t, self.scan_t = 0, 0, 0, 0
		self.killer, self.away, self.wastes, self.warped = st.killer, nil, st.wastes, st.warped
		self.shrine, self.bed, self.spike, self.won = st.shrine, st.bed, st.spike, st.won
		self.todo, self.todo_fail = st.todo, st.todo_fail or 0
		self.history, self.fail = {}, {}
		self.timer, self.keep, self.busy = 0, 0, false
		self.object:set_acceleration({x = 0, y = -9.81, z = 0})
		self.object:set_armor_groups({fleshy = 100})
		BOT = self
		save_state(self)
	end,

	get_staticdata = function(self)
		return minetest.serialize({v = 8, id = self.id})
	end,

	on_deactivate = function(self) if not self.gone then save_state(self) end end,

	---------------------------------------------------------- inventory helpers
	add = function(self, name, n) self.inv[name] = (self.inv[name] or 0) + n end,
	remove = function(self, name, n)
		self.inv[name] = (self.inv[name] or 0) - n
		if self.inv[name] <= 0 then self.inv[name] = nil end
	end,
	count = function(self, role)
		local c = 0
		for name, n in pairs(self.inv) do if role_of(name) == role then c = c + n end end
		return c
	end,
	-- list of n item names that fill a role (may mix types, e.g. oak + birch planks)
	take = function(self, role, n, used)
		local out = {}
		for name, have in pairs(self.inv) do
			if role_of(name) == role then
				local free = have - ((used and used[name]) or 0)
				while free > 0 and #out < n do
					out[#out + 1] = name; free = free - 1
					if used then used[name] = (used[name] or 0) + 1 end
				end
			end
		end
		return #out == n and out or nil
	end,

	craft_once = function(self, what)
		if what == "iron_ingot" then
			if self:count("furnace") < 1 then return false, "need a furnace" end
			local raw = self:take("raw_iron", 1)
			if not raw then return false, "need raw iron" end
			local fuel = self:take("coal", 1) or self:take("plank", 1) or self:take("log", 1)
			if not fuel then return false, "need fuel (coal or wood)" end
			local res = minetest.get_craft_result({method = "cooking", width = 1, items = {ItemStack(raw[1])}})
			if res.item:is_empty() then return false, "RECIPE smelting " .. raw[1] .. " not recognised" end
			self:remove(raw[1], 1)
			self.smelts = (self.smelts or 0) + 1 -- one piece of coal smelts 8 items (wood: 1)
			if role_of(fuel[1]) ~= "coal" or self.smelts % 8 == 1 then self:remove(fuel[1], 1) end
			self:add(res.item:get_name(), res.item:get_count())
			return true
		end
		local r = RECIPES[what]
		if not r then return false, "I don't know how to craft " .. tostring(what) end
		if r.tier and self.tier >= r.tier then return false, "already have that pickaxe or better" end
		if r.only and self:count(r.only) > 0 then return false, "already have one" end
		if what == "crafting_table" and self:count("table") > 0 then return false, "already have one" end
		if what == "furnace" and self:count("furnace") > 0 then return false, "already have one" end
		if r.table and self:count("table") < 1 then return false, "need a crafting_table" end
		local items, used = {}, {}
		for i, role in ipairs(r.grid) do
			if role == "" then items[i] = ItemStack("")
			else
				local got = self:take(role, 1, used)
				if not got then return false, "need more " .. role end
				items[i] = ItemStack(got[1])
			end
		end
		local res = minetest.get_craft_result({method = "normal", width = r.w, items = items})
		if res.item:is_empty() then
			local names = {}
			for _, it in ipairs(items) do names[#names + 1] = it:get_name() end
			return false, "RECIPE for " .. what .. " not recognised with: " .. table.concat(names, ",")
		end
		for name, n in pairs(used) do self:remove(name, n) end
		self:add(res.item:get_name(), res.item:get_count())
		if r.tier and r.tier > self.tier then self.tier = r.tier end
		return true
	end,

	craft = function(self, what, n)
		local made = 0
		for _ = 1, math.max(1, math.min(tonumber(n) or 1, 16)) do
			local ok, err = self:craft_once(what)
			if not ok then
				if made == 0 then return false, err end
				break
			end
			made = made + 1
		end
		chat("Crafted " .. what .. " x" .. made)
		return true
	end,

	---------------------------------------------------------- world helpers
	underground = function(self)
		local f = feet(self.object:get_pos())
		if f.y < -10 and f.y > -20000 then return true end -- deep down counts even under an open shaft
		for y = f.y + 2, f.y + 40 do
			local name = minetest.get_node({x = f.x, y = y, z = f.z}).name
			local d = minetest.registered_nodes[name]
			if d and d.walkable and NAME2CAT[name] ~= "wood" and ((d.groups or {}).leaves or 0) == 0 then return true end
		end
		return false
	end,

	-- remove one block and pocket its drops. returns true if the spot is now clear.
	dig_any = function(self, p)
		local name = minetest.get_node(p).name
		local def = minetest.registered_nodes[name]
		if not def or not def.walkable then return true end
		if def.diggable == false or def._mcl_hardness == -1 or name:find("bedrock") then return false, "unbreakable" end
		local need = TIER_NEED[NAME2CAT[name]] or ((((def.groups or {}).pickaxey or 0) > 0) and 1 or 0)
		if self.tier < need then return false, "need a better pickaxe" end
		for _, o in ipairs({{x=1,y=0,z=0},{x=-1,y=0,z=0},{x=0,y=1,z=0},{x=0,y=-1,z=0},{x=0,y=0,z=1},{x=0,y=0,z=-1}}) do
			local q = vector.add(p, o)
			local qn = minetest.get_node(q).name
			if NAME2CAT[qn] == "lava" then
				if self:count("wbucket") > 0 and not in_nether(q) then
					minetest.set_node(q, {name = is_source(qn) and "mcl_core:obsidian" or "mcl_core:cobble"})
				elseif not self:plug(q) then
					return false, "lava"
				end
			end
		end
		if minetest.is_protected(p, "") then return false, "protected" end
		for _, item in ipairs(minetest.get_node_drops(name, "")) do
			local st = ItemStack(item)
			if not st:is_empty() then self:add(st:get_name(), st:get_count()) end
		end
		minetest.remove_node(p)
		minetest.check_for_falling(p)
		return true
	end,

	-- carve one step of tunnel / staircase toward target. returns false,reason if it can't.
	dig_step_toward = function(self, target)
		local pos = self.object:get_pos()
		local f = feet(pos)
		local dx, dz, dy = target.x - f.x, target.z - f.z, target.y - f.y
		local flat = math.sqrt((target.x - pos.x) ^ 2 + (target.z - pos.z) ^ 2)
		if flat < 2.2 then
			if dy < -1 then return self:dig_any({x = f.x, y = f.y - 1, z = f.z}) end
			if dy > 5 then return false, "too high" end
			return true
		end
		local sx, sz = 0, 0
		if math.abs(dx) >= math.abs(dz) then sx = dx > 0 and 1 or -1 else sz = dz > 0 and 1 or -1 end
		local a = {x = f.x + sx, y = f.y, z = f.z + sz}
		local cells
		if dy > 1 then cells = {{0, 1}, {0, 2}, {-1, 2}}      -- stairs up
		elseif dy < -1 then cells = {{0, 0}, {0, 1}, {0, -1}}  -- stairs down
		else cells = {{0, 0}, {0, 1}} end                      -- level tunnel
		for _, c in ipairs(cells) do
			local p = c[1] == 0 and {x = a.x, y = a.y + c[2], z = a.z} or {x = f.x, y = f.y + c[2], z = f.z}
			local ok, why = self:dig_any(p)
			if not ok then return false, why end
		end
		return true
	end,

	move_toward = function(self, target, stop_dist)
		local pos = self.object:get_pos()
		local dir = {x = target.x - pos.x, y = 0, z = target.z - pos.z}
		local dist = vector.length(dir)
		local vel = self.object:get_velocity()
		if dist < stop_dist then
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			return true
		end
		dir = vector.normalize(dir)
		self.object:set_yaw(math.atan2(-dir.x, dir.z))
		local f = feet(pos)
		local y = vel.y
		local here = ndef(f)
		local wet = here and here.liquidtype and here.liquidtype ~= "none"
		local sinking = target.y < f.y - 1 -- heading for something below: don't float back up
		if wet and not sinking then
			y = 3 -- swim up
		elseif wet then
			y = math.min(vel.y, -2) -- sink to the bottom and keep digging
		elseif solid({x = round(pos.x + dir.x * 0.8), y = f.y, z = round(pos.z + dir.z * 0.8)})
				and math.abs(vel.y) < 0.5 then
			y = 6.5 -- jump over block
		end
		self.object:set_velocity({x = dir.x * 4, y = y, z = dir.z * 4})
		return false
	end,

	-- walk toward target; if allowed and not getting closer, dig. returns "arrived", "blocked" or nil
	travel = function(self, t, target, stop, dtime, may_dig)
		if self:move_toward(target, stop) then return "arrived" end
		t.chk = (t.chk or 0) + dtime
		if t.chk >= 0.6 then
			t.chk = 0
			local d = vector.distance(self.object:get_pos(), target)
			if may_dig and (not t.last_d or d > t.last_d - 0.25) then
				local ok, why = self:dig_step_toward(target)
				if not ok then t.block_reason = why; return "blocked" end
			end
			t.last_d = d
		end
	end,

	---------------------------------------------------------- planner (the tech tree)
	plan = function(self)
		local f = feet(self.object:get_pos())
		local function dirword() return ({"north", "south", "east", "west"})[math.random(4)] end
		local LIMIT = {stone = -10, coal = -40, iron = -40, diamond = -50}
		local function collect(what, n)
			if what == "wood" and self:underground() then return {action = "surface", why = "need wood from the surface"} end
			if what == "diamond" and f.y > -44 then
				return {action = "descend", depth = f.y + 50, why = "diamonds are deep down"}
			end
			if self.fail[what] then
				self.fail[what] = nil
				local blocked = self.fail.descend
				self.fail.descend = nil
				if LIMIT[what] and f.y > LIMIT[what] and not blocked then
					return {action = "descend", depth = 12, why = "no " .. what .. " here, going deeper"}
				end
				return {action = "explore", dir = dirword(), why = "no " .. what .. " here, looking elsewhere"}
			end
			return {action = "collect", what = what, count = math.max(1, n), why = "need " .. what}
		end
		local ensure
		ensure = function(role, n)
			if self:count(role) >= n then return nil end
			if role == "plank" then
				if self:count("log") > 0 then return {action = "craft", what = "planks", count = self:count("log"), why = "logs into planks"} end
				return collect("wood", 4)
			elseif role == "stick" then
				return ensure("plank", 2) or {action = "craft", what = "sticks", count = 2, why = "need sticks"}
			elseif role == "table" then
				return ensure("plank", 4) or {action = "craft", what = "crafting_table", why = "need a crafting table"}
			elseif role == "cobble" then return collect("stone", n - self:count("cobble"))
			elseif role == "furnace" then
				return ensure("table", 1) or ensure("cobble", 8) or {action = "craft", what = "furnace", why = "need a furnace"}
			elseif role == "ingot" then
				local missing = n - self:count("ingot")
				return ensure("furnace", 1) or ensure("raw_iron", missing)
					or ((self:count("coal") < 1 and self:count("plank") < missing) and collect("coal", 2))
					or {action = "craft", what = "iron_ingot", count = missing, why = "smelt the iron"}
			elseif role == "raw_iron" then return collect("iron", n - self:count("raw_iron"))
			elseif role == "diamond" then return collect("diamond", n - self:count("diamond"))
			elseif role == "flint" then return collect("gravel", 8)
			end
		end
		local step = ensure("table", 1)
		if step then return step end
		local t = self.tier
		if t == 0 then
			return ensure("plank", 3) or ensure("stick", 2) or {action = "craft", what = "wooden_pickaxe", why = "first pickaxe"}
		elseif t == 1 then
			return ensure("cobble", 3) or ensure("stick", 2) or {action = "craft", what = "stone_pickaxe", why = "upgrade pickaxe"}
		elseif t == 2 then
			return ensure("ingot", 3) or ensure("stick", 2) or {action = "craft", what = "iron_pickaxe", why = "upgrade pickaxe"}
		elseif t == 3 then
			return ensure("diamond", 3) or ensure("stick", 2) or {action = "craft", what = "diamond_pickaxe", why = "upgrade pickaxe"}
		end
		local function try(action, why)
			if self.fail[action] then
				self.fail[action] = nil
				return {action = "explore", dir = dirword(), why = "couldn't " .. action .. " here, looking elsewhere"}
			end
			return {action = action, why = why}
		end
		local inN = in_nether(f)
		if inN then
			self.reached = true
			if not self.nportal then self.nportal = f end -- where the portal brought me out
		end
		-- the portal I already built: walk back to it when I need it
		local function use_portal(why)
			local pn = self.portal
			if pn then
				local nn = minetest.get_node(pn).name
				if nn ~= "ignore" and nn ~= "mcl_portals:portal" then pn, self.portal = nil, nil end
			end
			pn = pn or minetest.find_node_near(f, 40, {"mcl_portals:portal"})
			if not pn then return nil end
			self.portal = pn
			if vector.distance(f, pn) > 6 then return {action = "goto", target = pn, why = "walking back to my portal"} end
			return {action = "enter_portal", why = why}
		end

		-- stage 3: real combat. Gear up, stock food, then hunt blazes for their rods.
		if self.reached then
			-- stage 4: 12 eyes of ender = 12 ender pearls + 12 blaze powder (6 rods)
			local EYES = 12
			local eyes, pearls, powder, rods = self:count("eye"), self:count("pearl"), self:count("powder"), self:count("rod")
			-- stage 5: take the eyes to the stronghold, open the End portal and go through
			-- stage 6: destroy the ten end crystals (they heal the dragon), then kill the dragon
			if self.won then
				return {action = "done", msg = "The Ender Dragon is dead. I beat the game!"}
			end
			if in_end(f) then
				if self:count("cobble") + self:count("block") < 150 then
					return collect("stone", 100) -- blocks for stairs and towers
				end
				if not self.todo then
					self.todo, self.todo_fail = {}, 0
					for i = (self.spike or 1), 10 do self.todo[#self.todo + 1] = i end
				end
				if #self.todo > 0 and self.todo_fail < 2 * #self.todo then
					return {action = "crystal", why = "end crystal on tower " .. self.todo[1] .. ", " .. #self.todo
						.. " left (they heal the dragon)"}
				end
				return {action = "fight_dragon", why = #self.todo == 0 and "all ten crystals are gone"
					or (#self.todo .. " crystals could not be reached")}
			end
			if eyes >= EYES or self.shrine then
				if inN then return {action = "go_overworld", why = "taking the eyes to the stronghold"} end
				if not self.shrine then
					local q, d = nearest_stronghold(f)
					if not q then
						return {action = "done", msg = "I can't find where the strongholds are in this game version. Please send Claude a screenshot."}
					end
					self.shrine = q
					chat("The nearest stronghold is about " .. math.floor(d) .. " blocks away, deep underground. Tunnelling there.")
				end
				local sh = self.shrine
				local flat = math.sqrt((sh.x - f.x) ^ 2 + (sh.z - f.z) ^ 2)
				if flat <= 6 and math.abs(sh.y - f.y) <= 6 then self.bed = self.bed or f end -- respawn here from now on
				if flat > 6 or math.abs(sh.y - f.y) > 6 then
					return {action = "goto", target = sh, why = "to the stronghold, " .. math.floor(flat) .. " blocks to go"}
				end
				return {action = "open_end", why = "fill the portal frame with eyes of ender"}
			end
			local need_rods = math.max(0, math.ceil((EYES - eyes - powder) / 2)) - rods
			if need_rods <= 0 then
				if pearls > 0 and powder > 0 then
					return {action = "craft", what = "ender_eye", count = math.min(pearls, powder), why = "pearl + blaze powder"}
				end
				if pearls > 0 and rods > 0 then
					return {action = "craft", what = "blaze_powder", count = math.ceil(pearls / 2), why = "powder for the eyes"}
				end
			end
			local geared = self:count("sword") > 0 and self:count("helmet") > 0 and self:count("chestplate") > 0
				and self:count("leggings") > 0 and self:count("boots") > 0
			local food, raw = self:count("food"), self:count("rawfood")
			if inN then
				if self:count("cobble") + self:count("block") < 24 then
					return collect("stone", 30) -- spare blocks for bridging and sealing lava
				end
				if not geared then
					return {action = "go_overworld", why = "need a sword and armor first"}
				end
				-- go to the part of the Nether where the mob I need lives
				local function seek(biome, key, label)
					if biome_at(f) == biome then return nil end
					if self[key] and vector.distance(f, self[key]) <= 5 then self[key] = nil end -- wrong spot: look again
					if not self[key] and not self["no_" .. key] then
						local q, r = find_biome(f, biome, 3000)
						if q then
							self[key] = q
							chat("The nearest " .. label .. " is about " .. r .. " blocks away; heading there.")
						else
							self["no_" .. key] = true
							chat("I can't find any " .. label .. " within 3000 blocks. Please send Claude a screenshot.")
						end
					end
					if self[key] then
						return {action = "goto", target = self[key], why = "to the " .. label .. ", "
							.. math.floor(vector.distance(f, self[key])) .. " blocks to go"}
					end
					return {action = "bore", why = "looking for the " .. label}
				end
				if need_rods > 0 then
					return seek("Nether", "wastes", "Nether wastes")
						or {action = "hunt_blaze", why = "need " .. need_rods .. " more blaze rods"}
				end
				local why = "need " .. (EYES - eyes - pearls) .. " more ender pearls"
				for _, m in ipairs(self:mobs_near(48)) do
					if m.kind == "ender" then return {action = "hunt_ender", why = why} end
				end
				return seek("WarpedForest", "warped", "warped forest (endermen live there)")
					or {action = "hunt_ender", why = why}
			end
			if self:count("sword") < 1 then
				return ensure("stick", 1) or ensure("ingot", 2) or {action = "craft", what = "iron_sword", why = "a weapon"}
			end
			for _, piece in ipairs({{"chestplate", 8}, {"leggings", 7}, {"helmet", 5}, {"boots", 4}}) do
				if self:count(piece[1]) < 1 then
					return ensure("ingot", piece[2]) or {action = "craft", what = "iron_" .. piece[1], why = "armor"}
				end
			end
			if food >= 8 then self.huntfails = 0 end
			if food < ((self.huntfails or 0) >= 3 and math.min(8, math.max(3, food + raw)) or 8) or (food < 1) then
				if raw > 0 and (food + raw >= 8 or self.fail.hunt_food) then
					if self:count("coal") < 1 and self:count("plank") < raw then return collect("coal", 2) end
					return {action = "cook_food", why = "cooked meat heals more"}
				end
				if self:underground() then return try("surface", "animals live on the surface") end
				if self.fail.hunt_food then
					self.fail.hunt_food = nil
					self.hunt_dir = self.hunt_dir or dirword()
					if (self.huntfails or 0) % 6 == 5 then self.hunt_dir = dirword() end
					return {action = "explore", dir = self.hunt_dir, why = "no animals here, searching further"}
				end
				return {action = "hunt_food", why = "need " .. math.max(1, 8 - food - raw) .. " more meat"}
			end
			local step = use_portal("ready to fight: sword, armor and food")
			if step then return step end
			-- the portal is gone: fall through and build a new one
		end

		-- stage 2: get into the Nether
		-- without a water bucket the lava at the bottom of the world blocks digging: work higher up
		if self:count("wbucket") < 1 and f.y < -40 and not self.fail.surface
				and not minetest.find_node_near(f, 40, {"mcl_portals:portal"}) then
			return {action = "surface", why = "too much lava down here without water"}
		end
		local step2 = use_portal("the portal is already built")
		if step2 then return step2 end
		if self:count("bucket") + self:count("wbucket") < 1 then
			return ensure("ingot", 3) or {action = "craft", what = "bucket", why = "a bucket to carry water"}
		end
		if self:count("fns") < 1 then
			return ensure("flint", 1) or ensure("ingot", 1)
				or {action = "craft", what = "flint_and_steel", why = "to light the portal"}
		end
		if self:count("obsidian") < 10 then
			if self:count("wbucket") < 1 then
				if self:underground() then return try("surface", "need water from the surface") end
				return try("fill_bucket", "water turns lava into obsidian")
			end
			if nearest_of("obsidian", f, 24) then
				return collect("obsidian", 10 - self:count("obsidian"))
			end
			if f.y > -46 then return {action = "descend", depth = f.y + 54, why = "lava lakes are deep down"} end
			return try("make_obsidian", "pour water on lava")
		end
		if self:underground() then return try("surface", "build the portal on the surface") end
		return try("build_portal", "10 obsidian and flint and steel ready")
	end,

	auto = function(self)
		local g = (self.goal or ""):lower()
		if g:find("follow") then return false end
		for _, w in ipairs({"beat", "game", "dragon", "auto", "win", "finish", "pickaxe", "diamond", "iron", "nether", "portal", "blaze", "fight", "ender", "pearl", "eye", "stronghold", "end", "dragon", "crystal"}) do
			if g:find(w) then return true end
		end
		return false
	end,

	---------------------------------------------------------- what the bot tells the AI
	observe = function(self)
		local p = feet(self.object:get_pos())
		local found = minetest.find_nodes_in_area(vector.add(p, {x=-20,y=-10,z=-20}), vector.add(p, {x=20,y=12,z=20}), ALL)
		local stats = {}
		for _, n in ipairs(found) do
			local cat = NAME2CAT[minetest.get_node(n).name]
			if cat then
				local st = stats[cat] or {count = 0}
				st.count = st.count + 1
				local d = vector.distance(n, p)
				if not st.d or d < st.d then st.d = d end
				stats[cat] = st
			end
		end
		self.seen = stats
		local near = {}
		for cat, st in pairs(stats) do
			near[#near + 1] = string.format("%s (%d blocks, nearest %d away)", cat, st.count, math.floor(st.d))
		end
		local have = {}
		for _, r in ipairs({"log", "plank", "stick", "table", "cobble", "coal", "raw_iron", "ingot", "furnace", "diamond"}) do
			local c = self:count(r)
			if c > 0 then have[#have + 1] = r .. " " .. c end
		end
		local players = {}
		for _, pl in ipairs(minetest.get_connected_players()) do players[#players + 1] = pl:get_player_name() end
		self.suggestion = self:plan()
		return table.concat({
			"Goal: " .. self.goal,
			string.format("Position %d,%d,%d (%s). Pickaxe: %s.", p.x, p.y, p.z,
				self:underground() and "underground" or "on the surface", TIER_NAME[self.tier]),
			"You have: " .. (#have > 0 and table.concat(have, ", ") or "nothing"),
			"Visible nearby: " .. (#near > 0 and table.concat(near, "; ") or "nothing useful"),
			"Players: " .. table.concat(players, ", "),
			"Planner suggests: " .. minetest.write_json(self.suggestion),
			"Recent actions: " .. table.concat(self.history, " | "),
		}, "\n")
	end,

	think = function(self)
		if not http then chat("No internet access: add 'secure.http_mods = aibot' to minetest.conf") self.paused = true return end
		if PROVIDER ~= "ollama" and KEY == "" then chat("No Gemini key: set aibot.gemini_key in minetest.conf") self.paused = true return end
		local obs = self:observe()
		if self.suggestion.action == "done" and self:auto() then
			self.paused = true
			chat(self.suggestion.msg or "Done.")
			return
		end
		self.busy = true
		local req
		if PROVIDER == "ollama" then
			req = {
				url = OLLAMA_URL .. "/api/chat", method = "POST", timeout = 120,
				extra_headers = {"Content-Type: application/json"},
				data = minetest.write_json({
					model = OLLAMA_MODEL, stream = false, format = "json",
					messages = {{role = "system", content = SYSTEM}, {role = "user", content = obs}},
				}),
			}
		else
			req = {
				url = "https://generativelanguage.googleapis.com/v1beta/models/" .. MODEL .. ":generateContent",
				method = "POST", timeout = 30,
				extra_headers = {"Content-Type: application/json", "x-goog-api-key: " .. KEY},
				data = minetest.write_json({
					system_instruction = {parts = {{text = SYSTEM}}},
					contents = {{role = "user", parts = {{text = obs}}}},
					generationConfig = {responseMimeType = "application/json", temperature = 0.4},
				}),
			}
		end
		http.fetch(req, function(res)
			self.busy = false
			if self.gone or not self.object:get_pos() then return end -- bot was removed meanwhile
			local act
			if res.succeeded and res.code == 200 then
				local ok, data = pcall(minetest.parse_json, res.data)
				local text
				if ok and type(data) == "table" then
					if data.message then text = data.message.content
					elseif data.candidates and data.candidates[1] then text = data.candidates[1].content.parts[1].text end
				end
				local ok2, parsed = pcall(minetest.parse_json, text or "")
				if ok2 and type(parsed) == "table" then act = parsed end
			elseif res.code == 0 and PROVIDER == "ollama" then
				chat("Can't reach Ollama (is the app running?). Using the planner on its own.")
			else
				chat("AI error " .. tostring(res.code) .. ". Using the planner on its own.")
			end
			self:start_action(act or {})
		end)
	end,

	---------------------------------------------------------- the Nether portal
	build_portal = function(self)
		if self:count("obsidian") < 10 then return false, "need 10 obsidian" end
		if self:count("fns") < 1 then return false, "need flint_and_steel" end
		if self:underground() then return false, "must be on the surface" end
		if not rawget(_G, "mcl_portals") or not mcl_portals.light_nether_portal then
			return false, "this game has no Nether portals"
		end
		local f = feet(self.object:get_pos())
		-- find room for the frame (4 wide, 5 tall) two blocks away. It needs no ground under it,
		-- only to be clear of water and lava, so over the sea it is built just above the surface.
		local site, ax
		for up = 0, 8 do
			for _, o in ipairs({{0, 2, "x"}, {0, -2, "x"}, {2, 0, "z"}, {-2, 0, "z"}}) do
				local ok = true
				local base = {x = f.x + o[1] - (o[3] == "x" and 1 or 0), y = f.y + up, z = f.z + o[2] - (o[3] == "z" and 1 or 0)}
				for i = 0, 3 do
					for dy = 0, 4 do
						local p = {x = base.x + (o[3] == "x" and i or 0), y = base.y + dy, z = base.z + (o[3] == "z" and i or 0)}
						local d = ndef(p)
						if not d or (d.liquidtype and d.liquidtype ~= "none") or d._mcl_hardness == -1 then ok = false end
					end
				end
				if ok then site, ax = base, o[3] break end
			end
			if site then break end
		end
		if not site then self.fail.build_portal = true return false, "no room for the frame here" end
		local used = 0
		for i = 0, 3 do
			for dy = 0, 4 do
				local p = {x = site.x + (ax == "x" and i or 0), y = site.y + dy, z = site.z + (ax == "z" and i or 0)}
				local edge = (i == 0 or i == 3)
				local cap = (dy == 0 or dy == 4)
				self:dig_any(p)
				if edge and cap then
					-- corners aren't needed
				elseif edge or cap then
					minetest.set_node(p, {name = "mcl_core:obsidian"}); used = used + 1
				else
					minetest.remove_node(p)
				end
			end
		end
		local ob = self:take("obsidian", used)
		for _, name in ipairs(ob or {}) do self:remove(name, 1) end
		local inner = {x = site.x + (ax == "x" and 1 or 0), y = site.y + 1, z = site.z + (ax == "z" and 1 or 0)}
		mcl_portals.light_nether_portal(inner)
		if not minetest.get_node(inner).name:find("portal") then
			chat("I built the frame but it wouldn't light. Pausing: please send Claude a screenshot.")
			self.paused = true
			return false, "portal would not light"
		end
		chat("Portal built and lit! Stepping through.")
		self.portal = inner
		self.task = {kind = "enter", t = 0, inner = inner}
		return true
	end,

	---------------------------------------------------------- real combat
	armor_points = function(self)
		local pts = 0
		for piece, v in pairs(ARMOR) do if self:count(piece) > 0 then pts = pts + v end end
		return pts
	end,

	hurt = function(self, dmg, by)
		local now = minetest.get_us_time() / 1e6
		if dmg <= 0 or now - self.hit_t < 0.5 then return end -- brief immunity after each hit
		self.hit_t = now
		dmg = dmg * (1 - 0.04 * self:armor_points())
		self.hp = self.hp - dmg
		if self.hp <= 0 then self:die(by) end
	end,

	-- explosions reach the bot through the game's damage call
	deal_damage = function(self, damage, reason)
		self:hurt(damage, (type(reason) == "table" and reason.type) or "an explosion")
	end,

	on_punch = function(self, puncher, tflp, caps, dir, damage)
		if puncher and puncher:is_player() then return true end
		local dmg = caps and caps.damage_groups and caps.damage_groups.fleshy or damage or 0
		local le = puncher and puncher:get_luaentity()
		self:hurt(dmg, le and le.name or "something")
		return true -- health is tracked by the bot itself
	end,

	die = function(self, by)
		self.deaths = self.deaths + 1
		self.hp, self.task, self.htarget = 20, nil, nil
		self.killer = (tostring(by):gsub("^.-:", ""))
		local back = self.bed or self.shrine or self.portal
		chat(string.format("I was killed by %s (death #%d). Respawning at %s.", self.killer, self.deaths,
			(self.bed or self.shrine) and "the stronghold" or "my portal"))
		if back then
			hold(back)
			minetest.emerge_area(vector.subtract(back, 8), vector.add(back, 8))
			self.object:set_pos(beside(back))
		end
		save_state(self)
	end,

	strike = function(self, obj)
		local now = minetest.get_us_time() / 1e6
		if now - self.strike_t < 0.7 then return end
		self.strike_t = now
		local p, q = self.object:get_pos(), obj:get_pos()
		local dir = vector.normalize(vector.subtract(q, p))
		obj:punch(self.object, 1.0, {full_punch_interval = 0.6,
			damage_groups = {fleshy = self:count("sword") > 0 and 6 or 1}}, dir)
	end,

	-- everything alive near the bot, sorted nearest first: {obj, le, kind, d}
	mobs_near = function(self, radius)
		local pos = self.object:get_pos()
		local out = {}
		for _, obj in ipairs(minetest.get_objects_inside_radius(pos, radius)) do
			local le = obj ~= self.object and obj:get_luaentity()
			local kind = mob_kind(le)
			if kind then out[#out + 1] = {obj = obj, le = le, kind = kind, d = vector.distance(pos, obj:get_pos())} end
		end
		table.sort(out, function(a, b) return a.d < b.d end)
		return out
	end,

	-- runs a few times a second: monsters notice the bot, the bot hits back, eats and picks things up
	senses = function(self, pos)
		local threat
		local eye = {x = pos.x, y = pos.y + 1.5, z = pos.z}
		for _, m in ipairs(self:mobs_near(16)) do
			local hostile = (m.kind == "monster" or m.kind == "blaze") and m.le.passive == false
			if hostile or m.le.attack == self.object then
				-- monsters only notice the bot when they can actually see it
				if hostile and m.le.do_attack and m.le.state ~= "attack"
						and not (m.le.day_docile and m.le:day_docile())
						and minetest.line_of_sight(eye, vector.add(m.obj:get_pos(), {x = 0, y = 1, z = 0})) then
					m.le:do_attack(self.object)
				end
				if m.le.attack == self.object and not threat and m.kind ~= "dragon" then threat = m.obj end
				if m.d <= 3.5 and (m.le.attack == self.object or m.kind == "blaze") then self:strike(m.obj) end
			end
		end
		-- something is attacking me: drop what I'm doing and fight it
		local k = self.task and self.task.kind
		if threat and self:count("sword") > 0 and k ~= "enter" and k ~= "leave" and k ~= "shrine"
				and not (k == "hunt" and self.task.what ~= "food") then
			self.task = {kind = "hunt", what = "threat", target = threat, t = 0, tick = 0}
		end
		local now = minetest.get_us_time() / 1e6
		if self.hp < 20 and now - self.hit_t > 10 and now - (self.regen_t or 0) > 4 then
			self.regen_t = now
			self.hp = math.min(20, self.hp + 1)
		end
		if self.hp <= 10 and now - self.eat_t > 2 then
			local bite = self:take("food", 1) or self:take("rawfood", 1)
			if bite then
				self.eat_t = now
				self.hp = math.min(20, self.hp + (role_of(bite[1]) == "food" and 8 or 3))
				self:remove(bite[1], 1)
			end
		end
		for _, obj in ipairs(minetest.get_objects_inside_radius(pos, 3)) do
			local le = obj:get_luaentity()
			if le and le.name == "__builtin:item" and le.itemstring and le.itemstring ~= "" then
				local st = ItemStack(le.itemstring)
				if not st:is_empty() then self:add(st:get_name(), st:get_count()) end
				le.itemstring = ""
				obj:remove()
			end
		end
	end,

	---------------------------------------------------------- safe movement (tunnel, bridge, stairs)
	-- put a spare block into a hole or into lava
	plug = function(self, p)
		local b = self:take("cobble", 1) or self:take("block", 1)
		if not b then return false end
		minetest.set_node(p, {name = b[1]})
		self:remove(b[1], 1)
		return true
	end,

	-- make one cell passable: lava gets plugged first, then the block is dug out
	open_cell = function(self, p)
		local name = minetest.get_node(p).name
		if NAME2CAT[name] == "lava" and not self:plug(p) then return false, "lava" end
		return self:dig_any(p)
	end,

	-- move one block: dx/dz sideways, dy -1/0/+1. Digs, bridges and seals lava as needed.
	safe_step = function(self, dx, dz, dy)
		local f = feet(self.object:get_pos())
		local a = {x = f.x + dx, y = f.y + dy, z = f.z + dz}
		local cells = {{x = a.x, y = a.y, z = a.z}, {x = a.x, y = a.y + 1, z = a.z}}
		if dy > 0 then cells[#cells + 1] = {x = f.x, y = f.y + 2, z = f.z} end
		if dy < 0 then cells[#cells + 1] = {x = a.x, y = a.y + 2, z = a.z} end
		for _, c in ipairs(cells) do
			local ok, why = self:open_cell(c)
			if not ok then return false, why end
		end
		local floor = {x = a.x, y = a.y - 1, z = a.z}
		if not solid(floor) and not self:plug(floor) then return false, "no blocks to bridge with" end
		self.object:set_pos({x = a.x, y = a.y - 0.45, z = a.z})
		self.object:set_velocity({x = 0, y = 0, z = 0})
		return true
	end,

	-- one safe step toward a point. returns "arrived", true, or false,why
	step_toward = function(self, target, near)
		local pos = self.object:get_pos()
		local f = feet(pos)
		local ddx, ddz, ddy = target.x - f.x, target.z - f.z, math.floor(target.y + 0.5) - f.y
		local flat = math.sqrt(ddx * ddx + ddz * ddz)
		if flat <= near and math.abs(ddy) <= 2 then return "arrived" end
		local dx, dz = 0, 0
		if flat > near then
			if math.abs(ddx) >= math.abs(ddz) then dx = ddx > 0 and 1 or -1 else dz = ddz > 0 and 1 or -1 end
		end
		local dy = ddy > 1 and 1 or (ddy < -1 and -1 or 0)
		if dx == 0 and dz == 0 then
			if dy == 0 then return "arrived" end
			if dy > 0 then -- straight up: stand on a new block
				if not self:open_cell({x = f.x, y = f.y + 2, z = f.z}) then return false, "can't climb" end
				self.object:set_pos({x = f.x, y = f.y + 0.55, z = f.z})
				if not self:plug(f) then return false, "no blocks to climb with" end
				return true
			end
			dx = 1 -- going down needs a step sideways
		end
		return self:safe_step(dx, dz, dy)
	end,

	-- The game is meant to carry anything standing in a portal across. If it doesn't, go to the
	-- spot in the Nether this portal leads to (1/8 of the distance) and put the exit portal there.
	cross_portal = function(self, t)
		local V = rawget(_G, "mcl_vars") or {}
		local nmin = V.mg_nether_min or -29067
		local lava = V.mg_lava_nether_max or (nmin + 31)
		local p = self.object:get_pos()
		local olow = (V.mg_lava_overworld_max or -52) + 1
		local target = {x = math.floor(p.x / 8), z = math.floor(p.z / 8),
			y = math.min(lava + 1 + math.max(0, math.floor(p.y) - olow), (V.mg_bedrock_nether_top_min or (nmin + 120)) - 12)}
		if self.nportal then
			local n = self.nportal
			minetest.emerge_area(vector.subtract(n, 8), vector.add(n, 8), function(_, _, remaining)
				if remaining and remaining > 0 then return end
				if self.gone or not self.object:get_pos() or self.task ~= t then return end
				hold(n)
				self.object:set_pos({x = n.x, y = n.y - 0.45, z = n.z})
			end)
			return
		end
		chat("The game didn't carry me through, so I'm crossing to the same spot in the Nether myself.")
		local p1, p2 = vector.add(target, {x = -10, y = -16, z = -10}), vector.add(target, {x = 10, y = 16, z = 10})
		minetest.emerge_area(p1, p2, function(_, _, remaining)
			if remaining and remaining > 0 then return end
			if self.gone or not self.object:get_pos() or self.task ~= t then return end
			-- nearest solid floor above the lava sea with headroom
			local best, bd
			for _, n in ipairs(minetest.find_nodes_in_area_under_air(p1, p2, {"group:building_block", "group:pickaxey", "mcl_nether:netherrack"})) do
				if n.y > lava and not solid({x = n.x, y = n.y + 2, z = n.z}) then
					local d = vector.distance(n, target)
					if not bd or d < bd then best, bd = n, d end
				end
			end
			local floor = best or target
			local exit
			if rawget(_G, "mcl_portals") and mcl_portals.spawn_nether_portal then
				exit = mcl_portals.spawn_nether_portal({x = floor.x - 1, y = floor.y, z = floor.z - 1}, nil, nil, "")
			end
			local dest
			if exit then
				dest = {x = exit.x, y = exit.y - 0.45, z = exit.z + 1} -- beside the new portal, not in it
				minetest.set_node({x = exit.x, y = exit.y - 1, z = exit.z + 1}, {name = "mcl_core:obsidian"})
			else
				if not best then minetest.set_node(floor, {name = "mcl_core:obsidian"}) end
				minetest.remove_node({x = floor.x, y = floor.y + 1, z = floor.z})
				minetest.remove_node({x = floor.x, y = floor.y + 2, z = floor.z})
				dest = {x = floor.x, y = floor.y + 0.55, z = floor.z}
			end
			hold(dest)
			self.object:set_pos(dest)
		end)
	end,

	---------------------------------------------------------- acting
	run = function(self, a)
		local pos = self.object:get_pos()
		local f = feet(pos)
		if a.action == "collect" and CATS[a.what or ""] then
			if self.tier < (TIER_NEED[a.what] or 0) then return false, "need a better pickaxe for " .. a.what end
			self.task = {kind = "collect", what = a.what, want = math.max(1, tonumber(a.count) or 4), got = 0, t = 0, tt = 0, skip = {}}
			return true
		elseif a.action == "craft" then
			local ok, err = self:craft(a.what, a.count)
			if not ok and err and err:find("^RECIPE") then
				chat(err); chat("Pausing so you can send Claude a screenshot of this. /bot go to resume.")
				self.paused = true
			end
			self.timer = INTERVAL - 2
			return ok, err
		elseif a.action == "descend" then
			local n = math.max(3, math.min(tonumber(a.depth) or 12, 70))
			self.task = {kind = "descend", t = 0, tick = 9, bad = 0, limit = 40 + n * 4, to_y = f.y - n,
				dir = ({{1, 0}, {-1, 0}, {0, 1}, {0, -1}})[math.random(4)]}
			return true
		elseif a.action == "hunt_food" or a.action == "hunt_blaze" or a.action == "hunt_ender" then
			local what = a.action:sub(6)
			local found
			for _, m in ipairs(self:mobs_near(48)) do if m.kind == what then found = true break end end
			if not found then
				self.fail[a.action] = true
				if what ~= "food" then
					self.quiet = (self.quiet or 0) + 1
					if self.quiet % 5 == 1 then
						chat("No " .. (what == "blaze" and "blazes" or "endermen")
							.. " in sight. Monsters only appear near a player, so stay close to me (/bot watch).")
					end
					self.task = {kind = "bore", t = 0, tick = 0, steps = 6, bad = 0, wander = true,
						dir = ({{1, 0}, {-1, 0}, {0, 1}, {0, -1}})[math.random(4)]}
					return true
				end
				self.huntfails = (self.huntfails or 0) + 1
				if self.huntfails % 5 == 1 then chat("No animals in sight. Animals and monsters only exist near a player, so stay close to me (/bot watch).") end
				return false, "no animals nearby"
			end
			self.task = {kind = "hunt", what = what, t = 0, tick = 0}
			return true
		elseif a.action == "cook_food" then
			if self:count("furnace") < 1 then return false, "need a furnace" end
			local n = 0
			while self:count("rawfood") > 0 do
				local raw = self:take("rawfood", 1)
				local fuel = self:take("coal", 1) or self:take("plank", 1) or self:take("log", 1)
				if not fuel then break end
				local res = minetest.get_craft_result({method = "cooking", width = 1, items = {ItemStack(raw[1])}})
				if res.item:is_empty() then return false, "RECIPE cooking " .. raw[1] .. " not recognised" end
				self:remove(raw[1], 1)
				self.smelts = (self.smelts or 0) + 1
				if role_of(fuel[1]) ~= "coal" or self.smelts % 8 == 1 then self:remove(fuel[1], 1) end
				self:add(res.item:get_name(), res.item:get_count())
				n = n + 1
			end
			if n == 0 then return false, "nothing to cook, or no fuel" end
			chat("Cooked " .. n .. " meat.")
			self.timer = INTERVAL - 2
			return true
		elseif a.action == "bore" then
			self.task = {kind = "bore", t = 0, tick = 0, steps = 24, bad = 0}
			return true
		elseif a.action == "goto" and a.target then
			self.task = {kind = "goto", t = 0, tick = 0, target = a.target, bad = 0}
			return true
		elseif a.action == "crystal" then
			self.task = {kind = "crystal", t = 0, tick = 0, bad = 0}
			return true
		elseif a.action == "fight_dragon" then
			self.task = {kind = "dragon", t = 0, tick = 0, say = 0, none = 0}
			return true
		elseif a.action == "open_end" then
			self.task = {kind = "shrine", t = 0, tick = 0, wait = 0}
			return true
		elseif a.action == "go_overworld" then
			if not in_nether(pos) then return false, "already in the overworld" end
			if not self.portal then return false, "I don't remember where my portal is" end
			if self.nportal and vector.distance(pos, self.nportal) > 6 then
				self.task = {kind = "goto", t = 0, tick = 0, target = self.nportal, bad = 0}
				return true
			end
			self.task = {kind = "leave", t = 0}
			return true
		elseif a.action == "fill_bucket" then
			if self:count("wbucket") > 0 then return false, "bucket is already full" end
			if self:count("bucket") < 1 then return false, "need a bucket" end
			self.task = {kind = "fill", t = 0, skip = {}}
			return true
		elseif a.action == "make_obsidian" then
			if self:count("wbucket") < 1 then return false, "need a water bucket" end
			self.task = {kind = "cool", t = 0, tt = 0, skip = {}}
			return true
		elseif a.action == "build_portal" then
			return self:build_portal()
		elseif a.action == "enter_portal" then
			local p = self.portal
			if not p or minetest.get_node(p).name ~= "mcl_portals:portal" then return false, "no portal found" end
			while minetest.get_node({x = p.x, y = p.y - 1, z = p.z}).name == "mcl_portals:portal" do
				p = {x = p.x, y = p.y - 1, z = p.z}
			end
			self.task = {kind = "enter", t = 0, inner = p}
			return true
		elseif a.action == "surface" then
			if not self:underground() then return false, "already on the surface" end
			self.task = {kind = "surface", t = 0, tick = 0}
			return true
		elseif a.action == "explore" and in_nether(pos) then
			self.task = {kind = "bore", t = 0, tick = 0, steps = 16, bad = 0, dir = ({north = {0, 1}, south = {0, -1}, east = {1, 0}, west = {-1, 0}})[a.dir or ""]}
			return true
		elseif a.action == "explore" then
			local d = ({north = {x=0,z=1}, south = {x=0,z=-1}, east = {x=1,z=0}, west = {x=-1,z=0}})[a.dir or ""]
				or ({{x=0,z=1}, {x=0,z=-1}, {x=1,z=0}, {x=-1,z=0}})[math.random(4)]
			self.task = {kind = "walk", dig = self:underground(), t = 0, limit = 25,
				target = {x = pos.x + d.x * 16, y = f.y, z = pos.z + d.z * 16}}
			return true
		elseif a.action == "walk_to" and tonumber(a.x) and tonumber(a.z) then
			self.task = {kind = "walk", t = 0, limit = 20, target = {x = tonumber(a.x), y = tonumber(a.y) or f.y, z = tonumber(a.z)}}
			return true
		elseif a.action == "follow" and a.player then
			self.task = {kind = "follow", player = tostring(a.player), t = 0}
			return true
		elseif a.action == "say" and a.text then
			chat(tostring(a.text)); return true
		elseif a.action == "wait" then return true
		end
		return false, "unknown action"
	end,

	start_action = function(self, a)
		local sug = self.suggestion or self:plan()
		local by = "AI"
		if a.dir then a.dir = tostring(a.dir):match("%a+") end
		local idle = ({explore = 1, wait = 1, say = 1, walk_to = 1})[a.action or ""] or not a.action
		if self:auto() then
			-- playing by itself: the AI's pick only counts when it matches the next sensible step,
			-- otherwise it wastes materials (e.g. crafting the same pickaxe again and again)
			if a.action == sug.action and (a.what == sug.what or sug.what == nil) then
				sug.why = a.why or sug.why
				a = sug
			else
				a, by = sug, "planner"
			end
		elseif (a.action == "explore" or a.action == "wait" or not a.action) and self.seen then
			local g = self.goal:lower()
			for cat in pairs(TIER_NEED) do
				if g:find(cat) and self.seen[cat] then a, by = {action = "collect", what = cat, count = 4}, "planner" end
			end
			if (g:find("wood") or g:find("log") or g:find("tree")) and self.seen.wood then
				a, by = {action = "collect", what = "wood", count = 4}, "planner"
			end
		end
		self.task = nil
		local ok, err = self:run(a)
		if not ok and not self.paused and self:auto() and sug.action ~= "done" and a ~= sug then
			-- the AI's pick wasn't possible: do what the planner wanted instead
			a, by = sug, "planner"
			ok, err = self:run(a)
		end
		local entry = tostring(a.action) .. (a.what and (" " .. tostring(a.what)) or "") .. (a.dir and (" " .. a.dir) or "")
			.. (a.depth and (" " .. tostring(a.depth)) or "") .. (ok and "" or (" FAILED: " .. tostring(err)))
		table.insert(self.history, entry)
		if #self.history > 6 then table.remove(self.history, 1) end
		chat(string.format("[%s] %s%s", by, entry, (ok and a.why) and (" (" .. tostring(a.why) .. ")") or ""))
	end,

	on_step = function(self, dtime)
		if self.gone then return end
		local pos = self.object:get_pos()
		if not pos then return end
		-- keep the bot's own part of the world running, even far from the player
		hold(pos)
		self.keep = self.keep + dtime
		if self.keep > 5 then
			self.keep = 0
			save_state(self)
			minetest.emerge_area(vector.subtract(pos, 30), vector.add(pos, 30))
		end

		if in_end(pos) and pos.y < end_center().y - 70 then
			self:die("the void")
			return
		end
		self.scan_t = self.scan_t + dtime
		if self.scan_t >= 0.3 then
			self.scan_t = 0
			self:senses(pos)
			pos = self.object:get_pos()
			if not pos then return end
		end

		local t = self.task
		if t then
			t.t = t.t + dtime
			if t.kind == "walk" then
				local r = self:travel(t, t.target, 1.3, dtime, t.dig)
				if r == "blocked" then chat("Blocked (" .. tostring(t.block_reason) .. "), trying something else.") end
				if r or t.t > (t.limit or 20) then self.task = nil end
			elseif t.kind == "descend" then
				local f = feet(pos)
				if f.y <= t.to_y then
					chat("Dug down to height " .. f.y .. "."); self.task = nil
				else
					t.tick = t.tick + dtime
					local v = self.object:get_velocity()
					self.object:set_velocity({x = 0, y = math.min(v.y, 0), z = 0})
					if t.tick >= 0.35 then
						t.tick = 0
						-- next stair: one step forward and one down, with headroom. The bot is placed
						-- straight into the space it just dug, so nothing can hold it back.
						local a = {x = f.x + t.dir[1], y = f.y - 1, z = f.z + t.dir[2]}
						local ok, why = true, nil
						for d = 1, 5 do -- don't step off into lava or a deep hole
							local below = {x = a.x, y = a.y - d, z = a.z}
							if NAME2CAT[minetest.get_node(below).name] == "lava" then ok, why = false, "lava below" break end
							if solid(below) then break end
							if d == 5 then ok, why = false, "deep drop" end
						end
						if ok then
							for _, dy in ipairs({1, 2, 0}) do
								ok, why = self:dig_any({x = a.x, y = a.y + dy, z = a.z})
								if not ok then break end
							end
						end
						if ok then
							t.bad = 0
							self.object:set_pos({x = a.x, y = a.y - 0.45, z = a.z})
						else
							t.bad = t.bad + 1
							t.dir = {-t.dir[2], t.dir[1]} -- turn and try another way down
							if t.bad >= 4 then
								chat("Can't dig further down here (" .. tostring(why) .. ").")
								self.fail.descend = true; self.task = nil
							end
						end
					end
					if self.task and t.t > t.limit then self.task = nil end
				end
			elseif t.kind == "collect" then
				if not t.target or NAME2CAT[minetest.get_node(t.target).name] ~= t.what then
					-- in the End, only take surface blocks: digging down leads to the void
					if in_end(pos) then t.miny = t.miny or (feet(pos).y - 1) end
					t.target = nearest_of(t.what, feet(pos), t.what == "wood" and 40 or 24, t.skip, t.miny)
					t.tt, t.last_d = 0, nil
					if not t.target then
						if t.got == 0 then self.fail[t.what] = true end
						chat(string.format("No more %s within reach (got %d).", t.what, t.got)); self.task = nil
					end
				end
				if self.task and t.target then
					t.tt = t.tt + dtime
					local flat = math.sqrt((pos.x - t.target.x) ^ 2 + (pos.z - t.target.z) ^ 2)
					local give_up = false
					if flat < 1.9 and vector.distance(pos, t.target) <= 6.5 then
						self:move_toward(t.target, 99)
						if self:dig_any(t.target) then
							t.got = t.got + 1; t.target = nil
							if t.got >= t.want then
								chat(string.format("Collected %d %s.", t.got, t.what)); self.task = nil
							end
						else give_up = true end
					else
						local r = self:travel(t, t.target, 1.5, dtime, self.tier >= 1)
						if r == "arrived" and self.tier >= 1 then -- right above/below it but out of reach
							t.chk = (t.chk or 0) + dtime
							if t.chk >= 0.6 then
								t.chk = 0
								if not self:dig_step_toward(t.target) then give_up = true end
							end
						end
						if r == "blocked" or t.tt > 40 then give_up = true end
					end
					if give_up and t.target then t.skip[minetest.hash_node_position(t.target)] = true; t.target = nil end
				end
				if self.task and t.t > 180 then
					if t.got == 0 then self.fail[t.what] = true end
					chat("Collecting is taking too long, rethinking."); self.task = nil
				end
			elseif t.kind == "bore" then
				t.tick = t.tick + dtime
				if t.tick >= 0.25 then
					t.tick = 0
					t.dir = t.dir or self.heading or ({{1, 0}, {-1, 0}, {0, 1}, {0, -1}})[math.random(4)]
					if not t.wander then self.heading = t.dir end
					local ok, why = self:safe_step(t.dir[1], t.dir[2], 0)
					if ok then
						t.steps, t.bad = t.steps - 1, 0
						if t.steps <= 0 then self.task = nil end
					else
						t.bad = t.bad + 1
						t.dir = {-t.dir[2], t.dir[1]}
						if t.bad >= 4 then chat("Stuck (" .. tostring(why) .. ")."); self.heading = nil; self.task = nil end
					end
				end
			elseif t.kind == "goto" then
				t.tick = t.tick + dtime
				if t.tick >= 0.25 then
					t.tick = 0
					local r, why = self:step_toward(t.target, 3)
					if r == "arrived" then self.task = nil
					elseif not r then
						t.bad = t.bad + 1
						if not self:safe_step(({1, -1, 0, 0})[t.bad % 4 + 1], ({0, 0, 1, -1})[t.bad % 4 + 1], 0) or t.bad > 12 then
							chat("Can't get there (" .. tostring(why) .. ")."); self.task = nil
						end
					end
				end
				if self.task and t.t > 600 then self.task = nil end
			elseif t.kind == "crystal" then
				t.tick = t.tick + dtime
				if t.tick >= 0.25 then
					t.tick = 0
					local c = end_center()
					local n = self.todo[1]
					local ang = (n - 1) / 10 * 2 * math.pi
					local ux, uz = math.cos(ang), math.sin(ang)
					local col = {x = round(c.x + 43 * ux), z = round(c.z + 43 * uz)}
					local function next_spike(msg, failed)
						chat(msg)
						if t.cp then minetest.forceload_free_block(t.cp, true) end
						table.remove(self.todo, 1)
						if failed then -- come back to it after the others
							self.todo[#self.todo + 1] = n
							self.todo_fail = self.todo_fail + 1
						end
						self.task = nil; save_state(self)
					end
					if not t.cp then
						-- the crystal sits on a bedrock block on top of its obsidian tower
						local p1 = {x = col.x - 3, y = c.y - 20, z = col.z - 3}
						local p2 = {x = col.x + 3, y = c.y + 75, z = col.z + 3}
						minetest.emerge_area(p1, p2)
						local top
						for _, p in ipairs(minetest.find_nodes_in_area(p1, p2, {"mcl_core:bedrock"})) do
							if not top or p.y > top.y then top = p end
						end
						if top then
							t.cp = {x = top.x, y = top.y + 1, z = top.z}
							t.stand = {x = round(top.x + 4 * ux), y = top.y, z = round(top.z + 4 * uz)}
							minetest.forceload_block(t.cp, true, -1)
						else
							t.miss = (t.miss or 0) + 1
							if t.miss > 60 then next_spike("No crystal tower at spot " .. n .. ".") end
						end
					elseif not t.there then
						local r, why = self:step_toward(t.stand, 1)
						if r == "arrived" then t.there, t.wait = true, 0
						elseif r == false then
							t.bad = t.bad + 1
							self:safe_step(({1, -1, 0, 0})[t.bad % 4 + 1], ({0, 0, 1, -1})[t.bad % 4 + 1], 0)
							if t.bad > 30 then next_spike("Can't reach crystal " .. n .. " yet (" .. tostring(why) .. "); I'll come back to it.", true) end
						end
					else
						-- some crystals are caged in iron bars: cut through the bars between me and it
						local f = feet(pos)
						local dx, dz = t.cp.x - f.x, t.cp.z - f.z
						local len = math.max(1, math.sqrt(dx * dx + dz * dz))
						for k = 1, 5 do
							for dy = -1, 3 do
								local cell = {x = round(f.x + dx / len * k), y = f.y + dy, z = round(f.z + dz / len * k)}
								local name = minetest.get_node(cell).name
								if name:find("pane") or name:find("iron_bars") then self:dig_any(cell) end
							end
						end
						local hit
						for _, obj in ipairs(minetest.get_objects_inside_radius(t.cp, 4)) do
							local le = obj:get_luaentity()
							if le and le.name == "mcl_end:crystal" then
								obj:punch(self.object, 1.0, {full_punch_interval = 1.0, damage_groups = {fleshy = 6}},
									vector.direction(pos, t.cp))
								hit = true
							end
						end
						t.wait = t.wait + 0.25
						if hit then next_spike("Destroyed the end crystal on tower " .. n .. ". " .. (#self.todo - 1) .. " left.")
						elseif t.wait > 12 then next_spike("No crystal on tower " .. n .. " (already gone).") end
					end
				end
				if self.task and t.t > 300 then
					chat("Tower " .. tostring(self.todo[1]) .. " is taking too long; I'll come back to it.")
					local n = table.remove(self.todo, 1)
					self.todo[#self.todo + 1] = n
					self.todo_fail = self.todo_fail + 1; self.task = nil
				end
			elseif t.kind == "dragon" then
				t.tick = t.tick + dtime
				local c = end_center()
				local cy = c.y + 25 -- the dragon circles 25 blocks above the exit portal, 35 blocks out
				if not t.loaded then
					t.loaded = true -- keep the dragon's whole flight path running
					for x = -48, 48, 16 do for z = -48, 48, 16 do for y = 0, 48, 16 do
						minetest.forceload_block({x = c.x + x, y = c.y + y, z = c.z + z}, true, -1)
					end end end
				end
				local dr, dle
				for _, obj in ipairs(minetest.get_objects_inside_radius({x = c.x, y = cy, z = c.z}, 90)) do
					local le = obj:get_luaentity()
					if mob_kind(le) == "dragon" then dr, dle = obj, le end
				end
				if dr then
					t.seen, t.none, t.hp = true, 0, dle.health
					local dp = dr:get_pos()
					local dd = vector.distance(pos, dp)
					if dd <= 7 then self:strike(dr) end
					-- remember where it came closest; if that is out of reach, move the perch there
					if not t.best or dd < t.best.d then t.best = {d = dd, p = dp} end
					t.lap = (t.lap or 0) + dtime
					if t.lap > 50 then
						if t.best.d > 4.5 and t.perch then
							t.perch = {x = round(t.best.p.x), y = round(t.best.p.y) - 1, z = round(t.best.p.z)}
						end
						t.lap, t.best = 0, nil
					end
					t.say = t.say + dtime
					if t.say > 30 then
						t.say = 0
						chat("Dragon health: " .. math.max(0, math.floor(dle.health or 0)) .. " / 200")
					end
				else
					t.none = t.none + dtime
					-- when it dies the game puts the exit portal and the dragon egg at the centre
					if minetest.find_node_near(c, 9, {"mcl_end:dragon_egg", END_PORTAL}) and (t.seen or t.none > 10) then
						self.won = true
						chat("The Ender Dragon is dead! I beat the game.")
						self.task = nil; save_state(self)
					elseif t.none > 45 and not t.warned then
						t.warned = true
						chat("I can't see the dragon. Come and stand near me (/bot watch) so the End stays awake.")
					end
				end
				if self.task and t.tick >= 0.25 then
					t.tick = 0
					if not t.perch then
						local a = math.atan2(pos.x - c.x, pos.z - c.z)
						t.perch = {x = round(c.x + math.sin(a) * 35), y = round(cy + 3 * math.sin(2 * a)) - 1,
							z = round(c.z + math.cos(a) * 35)}
					end
					-- climb to a perch on its flight path; if knocked off, climb back
					if self:step_toward(t.perch, 0.6) == false then
						self:safe_step(({1, -1, 0, 0})[math.random(4)], ({0, 0, 1, -1})[math.random(4)], 0)
					end
				end
				if self.task and t.t > 900 then self.task = nil end
			elseif t.kind == "shrine" then
				t.tick = t.tick + dtime
				if in_end(pos) then
					self.task = nil
				elseif t.portal then
					-- stand in the open portal; if the game doesn't take me, use its own teleport call
					self.object:set_velocity({x = 0, y = 0, z = 0})
					self.object:set_pos({x = t.portal.x, y = t.portal.y - 0.45, z = t.portal.z})
					t.wait = t.wait + dtime
					if t.wait > 6 and not t.sent then
						t.sent = true
						if rawget(_G, "mcl_portals") and mcl_portals.end_teleport then
							mcl_portals.end_teleport(self.object, t.portal)
						end
					end
					if t.wait > 30 then
						chat("The End portal didn't take me through. Pausing: please send Claude a screenshot.")
						self.paused = true; self.task = nil
					end
				elseif t.tick >= 0.5 then
					t.tick = 0
					local f = feet(pos)
					local p1, p2 = vector.add(f, {x = -24, y = -14, z = -24}), vector.add(f, {x = 24, y = 14, z = 24})
					local open = minetest.find_nodes_in_area(p1, p2, {END_PORTAL})
					local frames = minetest.find_nodes_in_area(p1, p2, {FRAME, FRAME_EYE})
					if #open > 0 then
						t.portal = open[math.ceil(#open / 2)]
					elseif #frames == 0 then
						minetest.emerge_area(p1, p2)
						if t.t > 30 then
							chat("I'm at the stronghold's position but can't find the portal frame. Pausing: please send Claude a screenshot.")
							self.paused = true; self.task = nil
						end
					else
						local c, empty = {x = 0, y = 0, z = 0}, nil
						local lo = {x = frames[1].x, y = frames[1].y, z = frames[1].z}
						local hi = {x = lo.x, y = lo.y, z = lo.z}
						for _, p in ipairs(frames) do
							c = vector.add(c, p)
							lo = {x = math.min(lo.x, p.x), y = p.y, z = math.min(lo.z, p.z)}
							hi = {x = math.max(hi.x, p.x), y = p.y, z = math.max(hi.z, p.z)}
							if not empty and minetest.get_node(p).name == FRAME then empty = p end
						end
						c = {x = round(c.x / #frames), y = round(c.y / #frames), z = round(c.z / #frames)}
						if vector.distance(pos, c) > 6 then
							-- walk into the portal room, one block above the frame
							local r = self:step_toward({x = c.x, y = c.y + 1, z = c.z}, 3)
							if r == false then self:safe_step(({1, -1, 0, 0})[math.random(4)], ({0, 0, 1, -1})[math.random(4)], 0) end
						elseif empty then
							local eye = self:take("eye", 1)
							if not eye then
								chat("I've run out of eyes of ender with the frame still unfinished. Pausing: please send Claude a screenshot.")
								self.paused = true; self.task = nil
							else
								-- the game's own "place an eye" action first; plain placement if that isn't possible
								local node = minetest.get_node(empty)
								local item = minetest.registered_items[eye[1]]
								local pl = minetest.get_connected_players()[1]
								if item and item.on_place and pl then
									pcall(item.on_place, ItemStack(eye[1]), {
										get_player_name = function() return pl:get_player_name() end,
										get_player_control = function() return {sneak = true} end,
										get_pos = function() return self.object:get_pos() end,
										is_player = function() return true end,
									}, {type = "node", under = empty, above = {x = empty.x, y = empty.y + 1, z = empty.z}})
								end
								if minetest.get_node(empty).name == FRAME then
									minetest.set_node(empty, {name = FRAME_EYE, param2 = node.param2})
								end
								self:remove(eye[1], 1)
								t.placed = (t.placed or 0) + 1
							end
						else
							-- every frame holds an eye: the portal should be open. Open it if the game didn't.
							for x = lo.x + 1, hi.x - 1 do
								for z = lo.z + 1, hi.z - 1 do
									minetest.set_node({x = x, y = lo.y, z = z}, {name = END_PORTAL})
								end
							end
							chat("Placed " .. (t.placed or 0) .. " eyes of ender. The End portal is open! Stepping in.")
						end
					end
				end
				if self.task and not t.portal and t.t > 240 then self.task = nil end
			elseif t.kind == "leave" then
				-- stand at the Nether side of the portal, then come out at my overworld portal
				self.object:set_velocity({x = 0, y = 0, z = 0})
				if t.t > 4 and not t.sent then
					t.sent = true
					local back = self.portal
					minetest.emerge_area(vector.subtract(back, 8), vector.add(back, 8), function(_, _, remaining)
						if remaining and remaining > 0 then return end
						if self.gone or not self.object:get_pos() or self.task ~= t then return end
						hold(back)
						self.object:set_pos(beside(back))
						chat("Back in the overworld."); self.task = nil
					end)
				end
				if self.task and t.t > 60 then self.task = nil end
			elseif t.kind == "hunt" then
				local tg = t.target
				if tg and (not tg:get_pos() or not mob_kind(tg:get_luaentity())) then
					tg, t.target = nil, nil
					t.kills = (t.kills or 0) + 1
				end
				if not tg then
					for _, m in ipairs(self:mobs_near(48)) do
						if m.kind == t.what then tg = m.obj break end
					end
					t.target = tg
					if not tg then
						if (t.kills or 0) == 0 then self.fail["hunt_" .. t.what] = true end
						self.task = nil
					end
				end
				local tle = tg and tg:get_luaentity()
				if self.task and tg and t.what == "ender" and self.hp < 16 and tle and tle.attack ~= self.object then
					self.object:set_velocity({x = 0, y = self.object:get_velocity().y, z = 0}) -- catch my breath first
				elseif self.task and tg then
					local q = tg:get_pos()
					if vector.distance(pos, q) <= 3.2 then
						self.object:set_velocity({x = 0, y = 0, z = 0})
						self:strike(tg)
					elseif in_nether(pos) or t.safe then
						t.tick = t.tick + dtime
						if t.tick >= 0.25 then
							t.tick = 0
							if self:step_toward(q, 1.5) == false then t.target = nil end
						end
					else
						self:travel(t, q, 1.5, dtime, false)
						t.prog = (t.prog or 0) + dtime
						if t.prog >= 4 then
							local d = vector.distance(pos, q)
							if t.pd and d > t.pd - 1.5 then t.safe = true end -- stuck: dig or bridge to it
							t.prog, t.pd = 0, d
						end
					end
				end
				if self.task and t.t > 120 then self.task = nil end
			elseif t.kind == "fill" then
				if not t.target then t.target = nearest_source("water", feet(pos), 40, t.skip, 10) end
				local target = t.target
				if not target then
					chat("No water nearby."); self.fail.fill_bucket = true; self.task = nil
				elseif vector.distance(pos, target) <= 3.5 then
					local b = self:take("bucket", 1)
					if b then self:remove(b[1], 1); self:add("mcl_buckets:bucket_water", 1) end
					chat("Filled the bucket with water."); self.task = nil
				else
					local r = self:travel(t, target, 1.5, dtime, true)
					if r == "blocked" then t.skip[minetest.hash_node_position(target)] = true; t.target = nil end
					if t.t > 90 then self.fail.fill_bucket = true; self.task = nil end
				end
			elseif t.kind == "cool" then
				if not t.target then
					t.target = nearest_source("lava", feet(pos), 24, t.skip)
					t.tt, t.last_d = 0, nil
					if not t.target then
						chat("No lava nearby."); self.fail.make_obsidian = true; self.task = nil
					end
				end
				if self.task and t.target then
					t.tt = t.tt + dtime
					if vector.distance(pos, t.target) <= 4.5 then
						self:move_toward(t.target, 99)
						local made = 0
						for _, n in ipairs(minetest.find_nodes_in_area(vector.subtract(t.target, 3), vector.add(t.target, 3), CATS.lava)) do
							local name = minetest.get_node(n).name
							if is_source(name) and made < 14 then
								minetest.set_node(n, {name = "mcl_core:obsidian"}); made = made + 1
							elseif not is_source(name) then
								minetest.set_node(n, {name = "mcl_core:cobble"})
							end
						end
						chat("Poured water on the lava: " .. made .. " obsidian blocks formed."); self.task = nil
					else
						local r = self:travel(t, t.target, 1.5, dtime, true)
						if r == "arrived" then
							t.chk = (t.chk or 0) + dtime
							if t.chk >= 0.6 then
								t.chk = 0
								if not self:dig_step_toward(t.target) then r = "blocked" end
							end
						end
						if r == "blocked" or t.tt > 40 then
							t.skip[minetest.hash_node_position(t.target)] = true; t.target = nil
						end
					end
				end
				if self.task and t.t > 150 then self.fail.make_obsidian = true; self.task = nil end
			elseif t.kind == "enter" then
				if in_nether(pos) then
					chat("Made it through the portal."); self.task = nil
				else
					self.object:set_velocity({x = 0, y = 0, z = 0})
					t.tick = (t.tick or 1) + dtime
					if t.tick >= 1 then -- keep standing inside the portal until the game teleports me
						t.tick = 0
						self.object:set_pos({x = t.inner.x, y = t.inner.y - 0.45, z = t.inner.z})
					end
					if t.t > 10 and not t.crossing then
						t.crossing = true
						self:cross_portal(t)
					end
					if t.t > 120 then
						chat("I couldn't get through the portal. Pausing: please send Claude a screenshot.")
						self.paused = true; self.task = nil
					end
				end
			elseif t.kind == "surface" then
				self.object:set_velocity({x = 0, y = 0, z = 0})
				t.tick = t.tick + dtime
				if t.tick >= 0.4 then
					t.tick = 0
					local f = feet(pos)
					if not self:underground() then chat("Back on the surface."); self.task = nil
					else
						local filler = self:take("block", 1) or self:take("cobble", 1)
						local ok1 = self:dig_any({x = f.x, y = f.y + 2, z = f.z})
						if not filler or not ok1 then
							chat(filler and "Can't dig upward here." or "No blocks left to climb with.")
							self.fail.surface = true; self.task = nil
						else
							self.object:set_pos({x = f.x, y = f.y + 0.5, z = f.z})
							minetest.set_node(f, {name = filler[1]})
							self:remove(filler[1], 1)
						end
					end
				end
				if self.task and t.t > 120 then self.task = nil end
			elseif t.kind == "follow" then
				local pl = minetest.get_player_by_name(t.player)
				if not pl or t.t > 30 then self.task = nil
				else self:move_toward(pl:get_pos(), 2.5) end
			end
		else
			local v = self.object:get_velocity()
			self.object:set_velocity({x = 0, y = v.y, z = 0})
		end

		self.timer = self.timer + dtime
		if self.timer >= INTERVAL and BOT == self and not self.busy and not self.paused and not self.task then
			self.timer = 0
			self:think()
		end
	end,

	on_death = function(self) chat("I died! Use /bot spawn to bring me back.") end,
})

---------------------------------------------------------------- chat commands
-- a spot next to the player with room for the bot (never inside a wall)
local function free_spot(p)
	for _, o in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {0, 0}}) do
		local c = {x = round(p.x) + o[1], y = math.floor(p.y + 0.6), z = round(p.z) + o[2]}
		if not solid(c) and not solid({x = c.x, y = c.y + 1, z = c.z}) then
			return {x = c.x, y = c.y - 0.45, z = c.z}
		end
	end
	return {x = p.x, y = p.y + 0.1, z = p.z}
end

local function spawn_bot(pos)
	local st = load_state()
	st.id = (st.id or 0) + 1 -- any older copy still lying around removes itself when it loads
	st.away = nil
	write_state(st)
	BOT = nil
	return minetest.add_entity(pos, "aibot:bot", minetest.serialize({v = 8, id = st.id}))
end

-- after a restart, wake the area the bot was last in so it carries on by itself
minetest.register_on_joinplayer(function()
	minetest.after(3, function()
		local st = load_state()
		if st.pos and not live_bot() then
			minetest.emerge_area(vector.subtract(st.pos, 16), vector.add(st.pos, 16))
			hold(st.pos)
		end
	end)
end)
minetest.register_on_shutdown(function() local b = live_bot(); if b then save_state(b) end end)

local function describe(st, where)
	local s = {}
	for k, v in pairs(st.inv) do s[#s + 1] = k:gsub("^.-:", "") .. " x" .. v end
	return string.format("%s Health %d/20, deaths %d%s. Pickaxe: %s. Goal: %s. Carrying: %s", where,
		math.floor((st.hp or 20) + 0.5), st.deaths or 0, st.killer and (" (last killed by " .. st.killer .. ")") or "",
		TIER_NAME[st.tier] or "?", st.goal, #s > 0 and table.concat(s, ", ") or "nothing")
end

local USAGE = "spawn | auto | goal <text> | status | stop | go | come | watch | remove | reset"
minetest.register_chatcommand("bot", {
	params = USAGE,
	description = "Control the AI bot",
	func = function(name, param)
		local cmd, rest = param:match("^(%S+)%s*(.*)$")
		local bot = live_bot()
		local st = load_state()
		local player = minetest.get_player_by_name(name)
		local beside = free_spot(player:get_pos())
		if cmd == "spawn" or cmd == "come" then
			if bot then
				bot.object:set_pos(beside); bot.task = nil
				return true, "Bot brought to you."
			end
			spawn_bot(beside)
			return true, (st.tier > 0 or next(st.inv)) and "Bot brought to you with its saved items."
				or "AIBot spawned. Its goal is to beat the game; /bot status shows progress."
		elseif cmd == "status" or cmd == "inv" or cmd == "where" then
			if bot then
				local p = feet(bot.object:get_pos())
				return true, describe(bot, string.format("At %d,%d,%d.", p.x, p.y, p.z))
			elseif st.pos then
				return true, describe(st, string.format("Asleep, last seen at %d,%d,%d (/bot come wakes it).", st.pos.x, st.pos.y, st.pos.z))
			end
			return false, "No bot yet. Use /bot spawn."
		elseif cmd == "watch" then
			local p = bot and bot.object:get_pos() or st.pos
			if not p then return false, "No bot yet. Use /bot spawn." end
			player:set_pos(vector.add(p, {x = 0, y = 1, z = 0}))
			return true, bot and "Teleported you to the bot." or "Teleported you to where the bot was last seen."
		elseif cmd == "reset" then
			if bot then bot.gone = true; bot.object:remove() end
			BOT = nil
			write_state({id = (st.id or 0) + 1})
			return true, "Bot and all its saved items wiped. /bot spawn starts fresh."
		end
		if not bot then return false, "The bot isn't awake here. Use /bot come first." end
		if cmd == "goal" and rest ~= "" then
			bot.goal = rest; bot.history = {}; bot.fail = {}; bot.paused = false; bot.task = nil
			return true, "New goal: " .. rest
		elseif cmd == "auto" then
			bot.goal = "beat the game"; bot.history = {}; bot.fail = {}; bot.paused = false
			return true, "Bot is now playing by itself."
		elseif cmd == "stop" then bot.paused = true; bot.task = nil; return true, "Bot paused."
		elseif cmd == "go" then bot.paused = false; return true, "Bot resumed."
		elseif cmd == "remove" then
			bot.away = true; save_state(bot); bot.gone = true; bot.object:remove(); BOT = nil
			return true, "Bot put away. Its items are saved; /bot spawn brings it back."
		end
		return false, "Usage: /bot " .. USAGE
	end,
})
