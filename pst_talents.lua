-- localfixes: таланты Passive Skill Trees сборки (18.10, слова пользователя: «Там качество талантов у разных
-- персонажей разнится»; «Добавь таланты для модированных персонажей»; «И добавь больше интересных талантов а не
-- только + - какой то стат»; «Интересные таланты для всех персонажей а не только модовых»).
-- Данные (деревья, тексты en/ru) — pst/talents_data.lua, собирает tools/pst_talents_gen.py из
-- tools/pst_talents_spec.py; каталог — docs/PST_TREES.md, чеклист — docs/PST_CHECKLIST.md.
-- Здесь: 1) тексты ключей lf_… (обёртка PST:getLocalized); 2) регистрация деревьев (AddCharacterTree; персонажи
-- модов получают своё дерево вместо общего — PST возвращает вложенные в общее очки); 3) механики: каждая читает
-- PST:getTreeSnapshotMod("lf_…") — снимок дерева текущего забега, так что работает только у того персонажа, в чьём
-- дереве узел выделен. Без PST модуль ничего не делает.
local mod = LOCALFIXES.Mod
local game = Game()
local sfx = SFXManager()
local T = {}

local okData, DATA = pcall(include, "pst.talents_data")
if not okData or type(DATA) ~= "table" then
	Isaac.DebugString("[localfixes] таланты PST: нет данных " .. tostring(DATA))
	return T
end

-- ошибки механик — в лог один раз на место (игра не падает)
local reported = {}
-- новый забег — отчёты заново (19.10: автотест «все персонажи × режимы» ловит ошибку только у первого, кто её вызвал)
T.resetReports = function() for k in pairs(reported) do reported[k] = nil end end
local function safe(tag, fn)
	return function(...)
		local ok, a, b = pcall(fn, ...)
		if not ok then
			if not reported[tag] then
				reported[tag] = true
				Isaac.DebugString("[localfixes] таланты PST, ошибка в " .. tag .. ": " .. tostring(a))
			end
			return nil
		end
		return a, b
	end
end

local function M(key)
	if not (PST and PST.getTreeSnapshotMod and PST.modData and PST.modData.treeModSnapshot) then return 0 end
	local v = PST:getTreeSnapshotMod(key, 0)
	if v == true then return 1 end
	return type(v) == "number" and v or 0
end
T.M = M

-- звук по имени (нет такого в этой версии игры — тишина, без ошибки)
local function play(name, vol, pitch)
	local id = SoundEffect[name]
	if id then sfx:Play(id, vol or 1, 0, false, pitch or 1) end
end

local rng = RNG()
-- шанс в процентах; T.forceRoll — только для автотеста (вероятностные таланты без случайности)
local function roll(pct)
	if T.forceRoll then return pct > 0 end
	return pct > 0 and rng:RandomFloat() * 100 < pct
end

-- состояние забега (не сохраняется: этаж/комната)
local S = { flawless = 0, hitThisRoom = false, cursedLuck = 0, pickupsThisRoom = 0, pactUsed = false,
	roomKills = 0, rage = false, vampKills = 0, lastChanceUsed = false, goRocksFloor = 0, rubble = 0,
	inPow = nil, inGauge = nil, inMig = nil, frCharge = {}, frCarry = 0, slCarry = 0, slTimer = nil, slStill = nil,
	slBounceCd = 0, chBroken = nil, chBubbleUsed = false, crCharge = nil, crCarry = 0, crPeak = 0, feTidy = 0 }
T.S = S   -- для автотеста (tools/lua/pst_talents_test.lua)

-- крючки модулей механик (pst/vanilla_talents.lua — персонажи игры, pst/ff_talents2.lua — остальные FF, pst/fu_talents.lua —
-- Furtherance, pst/lnf_talents.lua — Lost and Forgotten, pst/ipecac_talents.lua — IPECAC, pst/ep_talents.lua — Epiphany):
-- каждый модуль получает свою таблицу крючков, обработчики этого файла зовут их все (подключение — в конце файла)
local HOOKS = {}
T.HOOKS = HOOKS   -- для проб: какой модуль падает (tools/lua/pst_hook_probe.lua)
local function each(name, ...)
	for _, h in ipairs(HOOKS) do
		if h[name] then h[name](...) end
	end
end
local VAN = {
	dmgMult = function(...)
		local m = 1
		for _, h in ipairs(HOOKS) do if h.dmgMult then m = m * (h.dmgMult(...) or 1) end end
		return m
	end,
	altSource = function(...)
		for _, h in ipairs(HOOKS) do
			if h.altSource then
				local p = h.altSource(...)
				if p then return p end
			end
		end
	end,
	onHurt = function(...)
		for _, h in ipairs(HOOKS) do
			if h.onHurt and h.onHurt(...) == false then return false end
		end
	end,
	cache = function(...)
		local d, t, l, s = 0, 0, 0, 0
		for _, h in ipairs(HOOKS) do
			if h.cache then
				local a, b, c, e = h.cache(...)
				d, t, l, s = d + (a or 0), t + (b or 0), l + (c or 0), s + (e or 0)
			end
		end
		return d, t, l, s
	end,
	onKill = function(...) each("onKill", ...) end, tear = function(...) each("tear", ...) end,
	onRoom = function(...) each("onRoom", ...) end, onClear = function(...) each("onClear", ...) end,
	onLevel = function(...) each("onLevel", ...) end, onStart = function(...) each("onStart", ...) end,
}

local function player0() return Isaac.GetPlayer(0) end

local function enemy(e)
	return e and e:IsActiveEnemy(false) and e:IsVulnerableEnemy() and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
end

-- урон от игрока (слёзы, лазеры, ножи, бомбы, сам игрок) → игрок
local function sourcePlayer(src)
	local e = src and src.Entity
	if not e then return nil end
	if e:ToPlayer() then return e:ToPlayer() end
	local sp = e.SpawnerEntity
	if sp and sp:ToPlayer() then return sp:ToPlayer() end
	if e:ToFamiliar() and e:ToFamiliar().Player then return e:ToFamiliar().Player end
	if sp and sp:ToFamiliar() and sp:ToFamiliar().Player then return sp:ToFamiliar().Player end   -- слеза спутника
	return nil
end

---------------------------------------------------------------------------------------------------------------- тексты
local function installLocale()
	if T.localeInstalled or not (PST and PST.getLocalized) then return end
	T.localeInstalled = true
	local colors = PST.kcolors or {}
	-- цвета строк в данных — имена PST.kcolors; короткие RED/GREEN/BLUE — как у штрафов и бонусов самого PST
	local alias = { RED = "RED1", GREEN = "GREEN1", BLUE = "BLUE1" }
	for _, lang in ipairs({ "en", "ru" }) do
		for _, v in pairs(DATA[lang] or {}) do
			if type(v) == "table" then
				for _, line in ipairs(v) do
					if type(line) == "table" and type(line[2]) == "string" then
						line[2] = colors[alias[line[2]] or line[2]] or colors.WHITE
					end
				end
			end
		end
	end
	local origGet, origExists = PST.getLocalized, PST.localeIDExists
	function PST:getLocalized(text, lang)
		if type(text) == "string" then
			local key = text:sub(1, 1) == "#" and text:sub(2) or text
			if key:match("^lf%u") then   -- свои ключи: lf + заглавная (PST подставляет {{%w+}} — без «_»)
				local l = lang or Options.Language
				if PST.config and PST.config.forceEnglishLocale then l = "en" end
				local s = (l == "ru" and DATA.ru[key]) or DATA.en[key]
				if s ~= nil then return s end
			end
		end
		return origGet(self, text, lang)
	end
	if origExists then
		function PST:localeIDExists(id, lang)
			if type(id) == "string" and id:match("^lf%u") then return DATA.en[id] end
			return origExists(self, id, lang)
		end
	end
	-- цветные строки (цена крупных талантов — красным): PST:getLocalizedFormat оставляет от строки только текст;
	-- на время отрисовки окна описания узла наши ключи отдаются парами {текст, цвет} — их понимает DrawNodeBox.
	-- Остальные вызовы (окно итогов, Crimson) получают строки, как раньше.
	local db = PST.treeScreen and PST.treeScreen.modules and PST.treeScreen.modules.descriptionBoxes
	if db and db.Render and PST.getLocalizedFormat then
		local origRender, origFmt = db.Render, PST.getLocalizedFormat
		local inBox = false
		db.Render = function(self, ...)
			inBox = true
			local ok, err = pcall(origRender, self, ...)
			inBox = false
			if not ok then error(err, 0) end
		end
		function PST:getLocalizedFormat(text, vals, lang)
			local r = origFmt(self, text, vals, lang)
			if inBox and type(text) == "string" and type(r) == "table" then
				local key = text:sub(1, 1) == "#" and text:sub(2) or text
				if key:match("^lf%u") then
					local src = self:getLocalized(key, lang)
					if type(src) == "table" then
						for i, line in ipairs(src) do
							if type(line) == "table" and line[2] and type(r[i]) == "string" then r[i] = { r[i], line[2] } end
						end
					end
				end
			end
			return r
		end
	end
	-- окно итогов (Shift+Q): наши модификаторы — в разделе дерева персонажа
	if PST.treeModCategories and PST.treeModCategories.charTree then
		local have = {}
		for _, k in ipairs(PST.treeModCategories.charTree) do have[k] = true end
		for k in pairs(DATA.en) do
			if not k:find("_name$") and not have[k] then table.insert(PST.treeModCategories.charTree, k) end
		end
	end
end

------------------------------------------------------------------------------------------------------------ деревья
local function copy(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = copy(x) end
	return t
end

-- глобальные таланты и новые ветки деревьев PST (обычные персонажи): узлы вливаются в дерево PST. PST хранит его уже разобранным (pos — Vector, имя — по-английски,
-- sprite, id) — узлы возвращаются в исходный вид и дерево собирается заново через AddCharacterTree (как у PST: id
-- и вложенные очки сохраняются, наши узлы — с 9501)
function T.mergeTree(pstName, ours)
	local g = PST.trees and PST.trees[pstName]
	if not g then return end
	for id in pairs(ours) do
		if g[id] then return end   -- уже влиты
		break
	end
	local raw = {}
	for id, n in pairs(g) do
		local r = {}
		for k, v in pairs(n) do
			if k ~= "id" and k ~= "sprite" and k ~= "nameLocale" and k ~= "available" then r[k] = copy(v) end
		end
		r.pos = { n.pos.X, n.pos.Y }
		r.name = n.nameLocale or n.name
		raw[tostring(id)] = r
	end
	for id, n in pairs(ours) do
		raw[tostring(id)] = n
		for _, j in ipairs(n.adjacent or {}) do   -- связь с узлом общего дерева — и в обратную сторону
			local a = raw[tostring(j)]
			if a and not ours[j] then
				a.adjacent = a.adjacent or {}
				local has = false
				for _, x in ipairs(a.adjacent) do if x == id then has = true end end
				if not has then table.insert(a.adjacent, id) end
			end
		end
	end
	local ok, err = pcall(PST.SkillTreesAPI.AddCharacterTree, pstName, true, raw)
	local c = 0
	for _ in pairs(ours) do c = c + 1 end
	Isaac.DebugString("[localfixes] таланты PST: дерево «" .. pstName .. "» +" .. c .. " узлов" .. (ok and "" or (", ошибка: " .. tostring(err))))
end

local function registerTrees()
	if T.treesRegistered or not (PST and PST.SkillTreesAPI) then return end
	T.treesRegistered = true
	local n = 0
	for name, t in pairs(DATA.trees or {}) do
		local nodes = {}
		for id, node in pairs(t.nodes) do nodes[id] = copy(node) end
		if t.mode == "global" or t.mode == "extend" then T.mergeTree(t.pst or "global", nodes) end
		if t.mode == "new" then
			local ok, err = pcall(PST.SkillTreesAPI.AddCharacterTree, name, true, nodes)
			if ok then n = n + 1 else Isaac.DebugString("[localfixes] таланты PST: дерево " .. name .. ": " .. tostring(err)) end
		end
	end
	Isaac.DebugString("[localfixes] таланты PST: деревьев " .. n)
end

-- свой лист иконок узлов (tools/pst_custom_icons.py): узлы с customID "lfIcons" и номером 5000 + кадр
local function registerIcons()
	if T.iconsRegistered or not (PST and PST.SkillTreesAPI and PST.SkillTreesAPI.InitCustomNodeImage) then return end
	T.iconsRegistered = true
	local spr = Sprite()
	spr:Load("gfx/ui/localfixes/pst_icons.anm2", true)
	PST.SkillTreesAPI.InitCustomNodeImage("lfIcons", spr)
end

function T.install()
	if not PST then return end
	installLocale()
	registerIcons()
	registerTrees()
end

----------------------------------------------------------------------------------------------------------- механики
-- Fiend Folio
local function FF() return FiendFolio end
local function isFiend(p) return FF() and FF().PLAYER and p:GetPlayerType() == FF().PLAYER.FIEND end
local function ffData(e) return FF() and FF().GetEntityData and FF():GetEntityData(e) end

-- доп. слеза таланта: FireTear вызывает MC_POST_FIRE_TEAR — у Слиппи FF сделал бы из неё тройную, а наш «Лягушачий
-- залп» — ещё две; на время выстрела — защита FF (cannotFireMoreSlippyTears) и своя (T.extraFiring)
local function fireExtra(p, pos, vel, mult)
	local d = ffData(p)
	local was = d and d.cannotFireMoreSlippyTears
	if d then d.cannotFireMoreSlippyTears = true end
	T.extraFiring = true
	local ok, t = pcall(p.FireTear, p, pos, vel, false, true, false, p, mult)
	T.extraFiring = false
	if d then d.cannotFireMoreSlippyTears = was end
	return ok and t or nil
end
T.fireExtra = fireExtra

-- временный миньон Изверга (как его делает FF: ffscripts/players/fiend.lua, взрыв огненного шара)
function T.ffMinion(player, pos)
	local ff = FF()
	if not (ff and ff.PICKUP and ff.PICKUP.VARIANT and ff.PICKUP.VARIANT.FIEND_MINION_EFFECT) then return end
	local spood = Isaac.Spawn(1000, ff.PICKUP.VARIANT.FIEND_MINION_EFFECT, 0, pos or player.Position, Vector.Zero, player)
	local d = ff:GetEntityData(spood)
	d.canreroll = false
	d.hollow = true
	spood.EntityCollisionClass = 4
	spood.Parent = player
	return spood
end

-- огненный шар сверх обычного предела (3 + Пиромантия): до предела + «Костёр»
local function ffFireballCap(player)
	local ff = FF()
	local cap = 3 + player:GetCollectibleNum(ff.ITEM.COLLECTIBLE.PYROMANCY) * 3 + player:GetTrinketMultiplier(ff.ITEM.TRINKET.IMP_FINGER)
	cap = cap + M("lfFfFireballCap")
	if M("lfFfFireStorm") > 0 then cap = cap - 1 end
	return math.max(1, cap)
end
function T.ffAddFireball(player)
	local d = ffData(player)
	local sd = d and d.ffsavedata
	if not (sd and sd.orbitingfireballs) then return false end
	if sd.orbitingfireballs >= ffFireballCap(player) then return false end
	sd.orbitingfireballs = sd.orbitingfireballs + 1
	player:AddCacheFlags(CacheFlag.CACHE_FAMILIARS, true)
	play("SOUND_FLAME_BURST", 0.3, 1.5)
	return true
end

-- полные чёрные + аморальные сердца
local function darkHearts(player)
	local n = 0
	local bh = (player:GetBlackHearts() or 0)
	while bh > 0 do
		n = n + (bh & 1)
		bh = bh >> 1
	end
	if CustomHealthAPI and CustomHealthAPI.Library and CustomHealthAPI.Library.GetHPOfKey then
		local ok, imm = pcall(CustomHealthAPI.Library.GetHPOfKey, player, "IMMORAL_HEART")
		if ok and type(imm) == "number" then n = n + math.floor(imm / 2) end
	end
	return n
end

-- Голем (FF: ffscripts/players/golem.lua)
local function isGolem(p) return FF() and FF().PLAYER and p:GetPlayerType() == FF().PLAYER.GOLEM end
-- случайный брелок-камень Голема — как его право первородства из помеченного камня
function T.goSpawnRock(pos)
	local ff = FF()
	if not (ff and ff.GetGolemTrinket) then return end
	local ok, trinket = pcall(ff.GetGolemTrinket)
	if not ok or not trinket then return end
	-- на заметку: игра дважды падала во время теста Голема рядом с выдачей брелока (18.10) — номер в лог
	Isaac.DebugString("[localfixes] таланты PST: брелок-камень " .. tostring(trinket))
	local room = game:GetRoom()
	pos = room:FindFreePickupSpawnPosition(pos or room:GetCenterPos(), 0, true)
	local vel = EntityPickup.GetRandomPickupVelocity and EntityPickup.GetRandomPickupVelocity(pos) or RandomVector() * 2
	return Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_TRINKET, trinket, pos, vel, nil)
end

-- Инаба (FF: ffscripts/players/inaba.lua): сила 100–400 (сотня = уровень = глаз-спутник), шкала мигрени 0–100
local function isInaba(p)
	local ff = FF()
	return ff and ff.PLAYER and (p:GetPlayerType() == ff.PLAYER.INABA or p:GetPlayerType() == ff.PLAYER.BINABA)
end
local function inSave(p)
	local d = ffData(p)
	return d and d.ffsavedata and d.ffsavedata.Inaba
end
T.inSave = inSave
local function migCap()
	local ff = FF()
	return ff and ff.InabaBal and ff.InabaBal.MigraineCap or 100
end

-- слеза глаза-спутника (обёртка FF:FireSatelliteTear): «Острый взгляд», «Безумный взгляд»
function T.inSatTear(player, tear)
	local pct = M("lfInSatDmg")
	if pct > 0 then tear.CollisionDamage = tear.CollisionDamage * (1 + pct / 100) end
	if roll(M("lfInSatMadness")) then
		tear:AddTearFlags(rng:RandomInt(2) == 0 and TearFlags.TEAR_CONFUSION or TearFlags.TEAR_FEAR)
		tear.Color = Color(1, 0.25, 0.35, 1, 0.45, 0, 0.1)
	end
end

-- «Безумные красные глаза»: начало мигрени — все враги комнаты запутаны на 4 с и получают тройной урон
function T.inRedEyes(p)
	for _, en in ipairs(Isaac.GetRoomEntities()) do
		if enemy(en) then
			en:AddConfusion(EntityRef(p), 120, false)
			en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0)
			en:SetColor(Color(1, 0.3, 0.3, 1, 0.5, 0, 0), 20, 1, true, false)
		end
	end
	p:SetColor(Color(1, 0.3, 0.3, 1, 0.5, 0, 0), 20, 1, true, false)
	game:ShakeScreen(10)
	play("SOUND_DEATH_BURST_SMALL", 0.7, 0.6)
end

-- «Затмение»: потерян уровень силы — кольцо из 12 слёз и страх у всех врагов комнаты
function T.inEclipse(p)
	for i = 0, 11 do
		local t = fireExtra(p, p.Position, Vector(10, 0):Rotated(i * 30), 1)
		if t then
			t:AddTearFlags(TearFlags.TEAR_SPECTRAL)
			t.Color = Color(0.35, 0.15, 0.5, 1, 0.2, 0, 0.3)
		end
	end
	for _, en in ipairs(Isaac.GetRoomEntities()) do
		if enemy(en) then en:AddFear(EntityRef(p), 90) end
	end
	game:ShakeScreen(8)
	play("SOUND_DEATH_BURST_LARGE", 0.6, 1.2)
end

-- каждый кадр: прирост и убыль силы и шкалы мигрени (функции FF AddPower/AddMigraineGauge локальные —
-- правится разница за кадр), уровень, начало мигрени
T.inUpdate = safe("inaba", function(_, p)
	if p.Index ~= player0().Index or not isInaba(p) then return end
	local sv = inSave(p)
	if not (sv and sv.Power) then return end
	-- сила
	local pow = sv.Power
	local old = S.inPow or pow
	if pow > old then
		local k = M("lfInPowerGain") / 100 - (M("lfInElixir") > 0 and 0.2 or 0)
		if k ~= 0 then pow = pow + (pow - old) * k end
	elseif pow < old then
		local k = (M("lfInThirdEye") > 0 and 1 or 0) - math.min(0.9, M("lfInPowerGuard") / 100)
		if k ~= 0 then pow = pow - (old - pow) * k end
		if M("lfInElixir") > 0 then pow = math.max(pow, math.floor(old / 100) * 100) end
	end
	pow = math.max(100, math.min(400, pow))
	sv.Power = pow
	S.inPow = pow
	local lvOld, lvNew = math.floor(old / 100), math.floor(pow / 100)
	if lvNew > lvOld and roll(M("lfInLevelUp")) then
		p:AddSoulHearts(1)
		play("SOUND_HOLY", 0.5)
	end
	if lvNew < lvOld and M("lfInEclipse") > 0 then T.inEclipse(p) end
	-- мигрень
	local g = sv.MigraineGauge or 0
	local og = S.inGauge or g
	if g > og then
		local k = M("lfInMigraineGain") / 100 - (M("lfInRedEyes") > 0 and 0.15 or 0)
		if k ~= 0 then g = g + (g - og) * k end
	elseif g < og and sv.MigraineMode then
		local k = math.min(0.9, M("lfInMigraineLong") / 100)
		if k > 0 then g = g + (og - g) * k end
	end
	g = math.max(0, math.min(migCap(), g))
	sv.MigraineGauge = g
	S.inGauge = g
	local mig = sv.MigraineMode and true or false
	if mig ~= S.inMig then
		if mig and S.inMig == false and M("lfInRedEyes") > 0 then T.inRedEyes(p) end
		if S.inMig ~= nil and (M("lfInMigraineDmg") > 0 or M("lfInMigraineTears") > 0) then
			p:AddCacheFlags(CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY, true)
		end
		S.inMig = mig
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.inUpdate)

-- «Третий глаз»: FF считает спутники Инабы в своём CACHE_FAMILIARS (приоритет −1) и даёт +1 за Birthcake —
-- на время этого подсчёта playerHasBirthcake для Инабы с «Третьим глазом» отвечает «да»
mod:AddPriorityCallback(ModCallbacks.MC_EVALUATE_CACHE, -100, function(_, p)
	T.inFamP = (M("lfInThirdEye") > 0 and FF() and FF().PLAYER and p:GetPlayerType() == FF().PLAYER.INABA) and p or nil
end, CacheFlag.CACHE_FAMILIARS)
mod:AddPriorityCallback(ModCallbacks.MC_EVALUATE_CACHE, 100, function() T.inFamP = nil end, CacheFlag.CACHE_FAMILIARS)

-- Френд (FF: ffscripts/players/friend.lua): сердца — патроны револьвера (FriendHeldGuns[gun.InitSeed].Ammo),
-- урон пули — GetFriendShotDamageBonus (flat, mult, crit), перезарядка — FriendBalancing.ReloadMultiplier
local function isFriend(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.FRIEND end
T.isFriend = isFriend
-- прибавка к множителю урона пули
function T.frBonus(gun, player, shot, reload)
	local add = 0
	if reload then add = add + M("lfFrReloadBonus") / 100 end
	if shot then
		if shot.HeartType == "Red" then add = add + M("lfFrRedRound") / 100 end
		if shot.HeartKey == "SOUL_HEART" then add = add + M("lfFrSoulRound") / 100 end
		if shot.HeartKey == "BLACK_HEART" then add = add + M("lfFrBlackRound") / 100 end
	end
	if M("lfFrRicochet") > 0 then add = add - 0.1 end
	if M("lfFrLastRound") > 0 and gun then   -- «Последний патрон»: барабан опустел этим выстрелом
		local pd = ffData(player)
		local gt = pd and pd.FriendHeldGuns and pd.FriendHeldGuns[gun.InitSeed]
		if gt and gt.Ammo and #gt.Ammo == 0 then add = add + 2 end
	end
	return add
end
-- основной револьвер: зарядить один патрон, если барабан не полон
function T.frLoadOne(p)
	local ff = FF()
	local pd = ffData(p)
	local gun = pd and pd.FriendsRevolver
	local gt = gun and pd.FriendHeldGuns and pd.FriendHeldGuns[gun.InitSeed]
	if not (gt and gt.Ammo and ff.GetFriendAmmo and ff.ReloadFriendBullet) then return false end
	local target = ff:GetFriendAmmo(gun)
	if not target or #gt.Ammo >= #target then return false end
	ff:ReloadFriendBullet(gun, p)
	return true
end
-- слоты с «Горячим выстрелом»
local function hotSlots(p)
	local ff = FF()
	local id = ff and ff.ITEM and ff.ITEM.COLLECTIBLE and ff.ITEM.COLLECTIBLE.HOT_SHOT
	local out = {}
	if not id then return out end
	for slot = 0, 2 do
		if p:GetActiveItem(slot) == id then out[#out + 1] = slot end
	end
	return out
end
local function hotCharge(p, slot) return p:GetActiveCharge(slot) + p:GetBatteryCharge(slot) end
-- каждый кадр: скорость перезарядки; прибавка к заряду «Горячего выстрела» от урона
T.frUpdate = safe("friend", function(_, p)
	if p.Index ~= player0().Index or not isFriend(p) then return end
	local ff = FF()
	local fb = ff.FriendBalancing
	if fb then
		T.frReloadBase = T.frReloadBase or fb.ReloadMultiplier
		local k = 1 - math.min(0.5, M("lfFrReloadSpeed") / 100)
		if M("lfFrExtMag") > 0 then k = k * 1.2 end
		fb.ReloadMultiplier = T.frReloadBase * k
	end
	local k = M("lfFrHotCharge") / 100 - (M("lfFrOverheat") > 0 and 0.2 or 0)
	for _, slot in ipairs(hotSlots(p)) do
		local cur = hotCharge(p, slot)
		local old = S.frCharge[slot]
		if old and cur > old and k ~= 0 then
			S.frCarry = S.frCarry + (cur - old) * k
			local n = S.frCarry >= 0 and math.floor(S.frCarry) or math.ceil(S.frCarry)
			if n ~= 0 then
				S.frCarry = S.frCarry - n
				p:AddActiveCharge(n, slot, false, true, true)
				cur = hotCharge(p, slot)
			end
		end
		S.frCharge[slot] = cur
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.frUpdate)

-- «Бережливость»: выстрел без расхода патрона (колбэк FF: true — патрон не тратится)
mod:AddCallback("PRE_GUN_FIRE_CONSUME_AMMO", safe("frAmmo", function(_, gun, player)
	if isFriend(player) and roll(M("lfFrAmmoSave")) then return true end
end))
-- «Рикошет»: пули отскакивают от стен; общие эффекты слёз — и пулям
mod:AddCallback("POST_GUN_FIRE_TEAR", safe("frTear", function(_, gun, player, tear)
	if not (tear and isFriend(player)) then return end
	T.frLastTear = tear   -- для автотеста
	if M("lfFrRicochet") > 0 then tear:AddTearFlags(TearFlags.TEAR_BOUNCE) end
	if T.tearFx then T.tearFx(tear) end
end))
-- «Удлинённый барабан»: предел контейнеров 6 → 7. Колбэк сквозной (каждый получает значение предыдущего): FF ставит
-- 6 на IMPORTANT, наш после него +1 контейнер. Игра запоминает предел до следующего кадра (проверено 18.10).
mod:AddPriorityCallback(ModCallbacks.MC_PLAYER_GET_HEART_LIMIT, CallbackPriority.LATE, safe("frLimit", function(_, p, limit)
	if M("lfFrExtMag") > 0 and isFriend(p) then return limit + 2 end
end))

-- Слиппи (FF: ffscripts/players/slippy.lua): данные игрока FF frogTimer (заряд пука в кадрах, ступени 30/80/150)
-- и frogStop (держит «Золотую голову лягушки»); пук FF — на отпускании
local function isSlippy(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.SLIPPY end
T.isSlippy = isSlippy
-- наш пук поверх пука FF: ступень 1 — белая вспышка, 2 — красная, 3 — красное свечение
function T.slFart(p, tier)
	local pos = p.Position
	local r = tier >= 3 and 140 or 90
	local pct = M("lfSlFartDmg")
	local fear = roll(M("lfSlFartFear"))
	for _, en in ipairs(Isaac.FindInRadius(pos, r, EntityPartition.ENEMY)) do
		if enemy(en) then
			if pct > 0 then en:TakeDamage(p.Damage * pct / 100, 0, EntityRef(p), 0) end
			if fear then en:AddFear(EntityRef(p), 90) end
		end
	end
	if roll(M("lfSlFartCloud")) then
		local gas = Isaac.Spawn(EntityType.ENTITY_EFFECT, 141, 0, pos, Vector.Zero, p):ToEffect()
		if gas then gas.Timeout = 150 end
	end
	if tier >= 3 and M("lfSlGasGiant") > 0 then   -- «Газовый гигант»
		for _, en in ipairs(Isaac.FindInRadius(pos, 160, EntityPartition.ENEMY)) do
			if enemy(en) then en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
		end
		for i = 0, 6 do
			local off = i == 0 and Vector.Zero or Vector(45, 0):Rotated(i * 60)
			local gas = Isaac.Spawn(EntityType.ENTITY_EFFECT, 141, 0, pos + off, off:Resized(3), p):ToEffect()
			if gas then gas.Timeout = 300 end
		end
		game:ShakeScreen(15)
	end
end
-- каждый кадр: скорость заряда, отпускание (пук), «Тихий пруд», слизь, отскок
T.slUpdate = safe("slippy", function(_, p)
	if p.Index ~= player0().Index or not isSlippy(p) then return end
	local d = ffData(p)
	if not d then return end
	local timer = d.frogTimer or 0
	local last = S.slTimer or 0
	-- заряд: FF прибавляет frogTimer в обновлении игрока (60 раз в секунду) — правим прирост за кадр
	if d.frogStop and timer > last and last > 0 then
		local k = M("lfSlChargeSpeed") / 100 - (M("lfSlGasGiant") > 0 and 0.2 or 0)
		if k ~= 0 then
			S.slCarry = S.slCarry + (timer - last) * k
			local n = S.slCarry >= 0 and math.floor(S.slCarry) or math.ceil(S.slCarry)
			if n ~= 0 then
				S.slCarry = S.slCarry - n
				d.frogTimer = math.max(1, d.frogTimer + n)
				timer = d.frogTimer
			end
		end
	end
	if timer == 0 and last > 30 then T.slFart(p, last > 150 and 3 or last > 80 and 2 or 1) end
	S.slTimer = timer
	local still = d.frogStop and true or false
	if still ~= S.slStill then
		S.slStill = still
		if M("lfSlStillPond") > 0 then p:AddCacheFlags(CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY, true) end
	end
	if M("lfSlSlime") > 0 and not d.frogStop and p.Velocity:LengthSquared() > 1 and p.FrameCount % 6 == 0 then
		local c = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.PLAYER_CREEP_GREEN, 0, p.Position, Vector.Zero, p):ToEffect()
		if c then
			c.CollisionDamage = p.Damage * M("lfSlSlime") / 100
			c:SetTimeout(45)
			c.SpriteScale = Vector(0.7, 0.7)
			c:Update()
		end
	end
	if M("lfSlSlam") > 0 and not d.frogStop then   -- «Таран»: враг на пути скольжения
		for _, en in ipairs(Isaac.FindInRadius(p.Position, p.Size + 28, EntityPartition.ENEMY)) do
			local ed = en:GetData()
			if enemy(en) and (ed.lfSlamCd or 0) <= game:GetFrameCount()
				and en.Position:Distance(p.Position) <= p.Size + en.Size + 6 then
				ed.lfSlamCd = game:GetFrameCount() + 30
				en:TakeDamage(p.Damage * 2, 0, EntityRef(p), 0)
				en:AddVelocity((en.Position - p.Position):Resized(6))
				play("SOUND_MEAT_IMPACTS", 0.6)
			end
		end
	end
	if M("lfSlRebound") > 0 and p:CollidesWithGrid() and S.slBounceCd <= p.FrameCount then
		S.slBounceCd = p.FrameCount + 30
		if roll(M("lfSlRebound")) then
			for i = 0, 3 do fireExtra(p, p.Position, Vector(9, 0):Rotated(45 + i * 90), 0.7) end
			play("SOUND_MEAT_JUMPS", 0.5, 1.3)
		end
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.slUpdate)

-- Чайна (FF: ffscripts/players/china.lua): здоровья нет, удар — сломанное сердце (12 — смерть); FF ранит её при
-- касании препятствий (TakeDamage с источником — она сама) и ямах; сделки с дьяволом — одна на комнату (общий
-- OptionsPickupIndex), «Конский пломбир» (карта FF) лечит сломанное сердце
local function isChina(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.CHINA end
T.isChina = isChina
-- каждый кадр: число сломанных сердец — пересчёт урона/слёз, «Осколки» на новом сломанном сердце
T.chUpdate = safe("china", function(_, p)
	if p.Index ~= player0().Index or not isChina(p) then return end
	local b = (p:GetBrokenHearts() or 0)
	local old = S.chBroken
	S.chBroken = b
	if old == nil or b == old then return end
	if M("lfChCracks") > 0 or M("lfChJitters") > 0 or M("lfLowHpFury") > 0 then
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY, true)
	end
	if b > old and M("lfChShards") > 0 then   -- «Осколки»
		for i = 0, 7 do
			local t = fireExtra(p, p.Position, Vector(9, 0):Rotated(i * 45), 1)
			if t then
				t:AddTearFlags(TearFlags.TEAR_PIERCING)
				t.Color = Color(1, 1, 1, 1, 0.5, 0.5, 0.6)
			end
		end
		for _, en in ipairs(Isaac.FindInRadius(p.Position, 140, EntityPartition.ENEMY)) do
			if enemy(en) then en:AddFear(EntityRef(p), 90) end
		end
		play("SOUND_MIRROR_BREAK", 0.4, 1.4)
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.chUpdate)
-- комната дьявола: FF связал сделки общим индексом (одна на комнату) — «Доля беса» отвязывает одну, «Договор беса» —
-- все (каждая взятая — сломанное сердце); после FF (LATE)
T.chDevilRoom = safe("chDevil", function()
	local room = game:GetRoom()
	if room:GetType() ~= RoomType.ROOM_DEVIL or not room:IsFirstVisit() then return end
	local p = player0()
	if not isChina(p) then return end
	local deals = {}
	for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE)) do
		local pk = e:ToPickup()
		if pk and pk.Price < 0 and pk.OptionsPickupIndex ~= 0 then deals[#deals + 1] = pk end
	end
	if #deals == 0 then return end
	if M("lfChImpPact") > 0 then
		for _, pk in ipairs(deals) do
			pk.OptionsPickupIndex = 0
			pk:GetData().lfChPact = true
		end
	elseif #deals > 1 and roll(M("lfChImpShare")) then
		deals[rng:RandomInt(#deals) + 1].OptionsPickupIndex = 0
	end
end)
mod:AddPriorityCallback(ModCallbacks.MC_POST_NEW_ROOM, CallbackPriority.LATE, T.chDevilRoom)
-- «Договор беса»: сделка куплена — плата сломанным сердцем. Пьедестал сделки после покупки удаляется (SubType 0, наши
-- данные ещё на месте), а колбэк покупки REPENTOGON приходит уже без данных (проверено 18.10) — плата на удалении
mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, safe("chPact", function(_, e)
	if e.Variant ~= PickupVariant.PICKUP_COLLECTIBLE or e.SubType ~= 0 then return end
	local d = e:GetData()
	if d.lfChPact and not d.lfChPaid then
		d.lfChPaid = true
		local p = player0()
		if isChina(p) then
			p:AddBrokenHearts(1)
			play("SOUND_DEVIL_CARD", 0.5)
		end
	end
end), EntityType.ENTITY_PICKUP)

-- Крейг (FF: ffscripts/players/craig.lua): «Батарейка Крейга» (карман) копит заряд (растения-лампочки, камни-лампочки,
-- урон), вне боя разряжается по 1 за кадр, на 200% — взрыв перегрузки; растения-лампочки — эффект FF.BulbPlant
local function isCraig(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.CRAIG end
T.isCraig = isCraig
local function crMax()
	local ff = FF()
	local cfg = ff and ff.ITEM and Isaac.GetItemConfig():GetCollectible(ff.ITEM.COLLECTIBLE.CRAIGS_BATTERY)
	return cfg and cfg.MaxCharges or 300
end
local function crSlot(p)
	local id = FF().ITEM.COLLECTIBLE.CRAIGS_BATTERY
	for slot = ActiveSlot.SLOT_PRIMARY, ActiveSlot.SLOT_POCKET2 do
		if p:GetActiveItem(slot) == id then return slot end
	end
end
T.crSlot = crSlot
local function roomActive()
	local room = game:GetRoom()
	return room:IsAmbushActive() or not room:IsClear()
end
-- «Вспышка»: сорванное взрослое растение-лампочка
local function crFlash(p, pos)
	for _, en in ipairs(Isaac.FindInRadius(pos, 100, EntityPartition.ENEMY)) do
		if enemy(en) then
			en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0)
			en:AddConfusion(EntityRef(p), 60, false)
		end
	end
	game:SpawnParticles(pos, EffectVariant.EMBER_PARTICLE, 10, 5, Color(1, 1, 0.5, 1, 0.5, 0.5, 0))
	play("SOUND_BULB_FLASH", 1, 1.2)
end
T.crFlash = crFlash
-- каждый кадр: заряд (прибавка, изоляция, перегрузка), статическое поле, садовник, удобрение, вспышка
T.crUpdate = safe("craig", function(_, p)
	if p.Index ~= player0().Index or not isCraig(p) then return end
	local ff = FF()
	local slot = crSlot(p)
	local max = crMax()
	if slot then
		local cur = p:GetTotalActiveCharge(slot)
		local old = S.crCharge
		if old and cur > old then   -- «Подзарядка»
			local k = M("lfCrCharge") / 100
			if k > 0 then S.crCarry = S.crCarry + (cur - old) * k end
		elseif old and cur < old and old - cur <= 2 and not roomActive() then   -- «Изоляция»: разряд вне боя
			local k = math.min(1, M("lfCrInsul") / 100)
			if k > 0 then S.crCarry = S.crCarry + (old - cur) * k end
		elseif old and cur == 0 and S.crPeak >= max * 1.9 and M("lfCrGround") > 0 then   -- «Заземление»
			p:SetActiveCharge(math.floor(max / 3) + 1, slot)
		end
		-- «Статическое поле»: раз в секунду
		if M("lfCrStatic") > 0 and p.FrameCount % 30 == 0 and roomActive() then
			local n = 0
			for _, en in ipairs(Isaac.FindInRadius(p.Position, 80, EntityPartition.ENEMY)) do
				if enemy(en) then n = n + 1 end
			end
			S.crCarry = S.crCarry + math.min(5, n) * M("lfCrStatic")
		end
		if S.crCarry >= 1 then
			local n = math.floor(S.crCarry)
			S.crCarry = S.crCarry - n
			p:AddActiveCharge(n, slot, false, true, true)
		end
		cur = p:GetTotalActiveCharge(slot)
		S.crCharge = cur
		S.crPeak = cur
	end
	local bp = ff.FF and ff.FF.BulbPlant
	if not bp then return end
	-- «Садовник»: раз в секунду боя — шанс ещё одного растения (предел FF — 5)
	if p.FrameCount % 30 == 0 and roomActive() and roll(M("lfCrGardener"))
		and #Isaac.FindByType(bp.ID, bp.Var, bp.Sub) < (ff.BulbPlantSpawnLimit or 5) then
		local pos = ff.FindSafeSpawnSpot and ff:FindSafeSpawnSpot(p.Position, nil, nil, true, 120, true)
			or game:GetRoom():FindFreePickupSpawnPosition(p.Position + RandomVector() * 120, 0, true)
		Isaac.Spawn(bp.ID, bp.Var, bp.Sub, pos, Vector.Zero, p)
	end
	local grow = M("lfCrFertilizer") / 100
	for _, e in ipairs(Isaac.FindByType(bp.ID, bp.Var, bp.Sub)) do
		local d = ffData(e)
		if d then
			if grow > 0 and d.Coll and not d.MaxSize and d.GrowTimer then   -- «Удобрение»
				d.lfGrow = (d.lfGrow or 0) + grow
				if d.lfGrow >= 1 then
					d.lfGrow = d.lfGrow - 1
					d.GrowTimer = d.GrowTimer - 1
				end
			end
			if M("lfCrFlash") > 0 and d.Suffix == "full" and not e:GetData().lfFlash
				and e:GetSprite():GetAnimation() == "Poppedfull" then   -- «Вспышка»
				e:GetData().lfFlash = true
				crFlash(p, e.Position)
			end
		end
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.crUpdate)
-- лазеры технологии Крейга — «Длинный провод» (первый вызов обновления лазера — на 2-м кадре; урон луча батарейки —
-- в обработчике урона по врагам)
mod:AddCallback(ModCallbacks.MC_POST_LASER_UPDATE, safe("crLaser", function(_, laser)
	if laser.FrameCount > 3 then return end
	local p = laser.SpawnerEntity and laser.SpawnerEntity:ToPlayer()
	if not (p and isCraig(p)) then return end
	local d = laser:GetData()
	if d.lfCr then return end
	d.lfCr = true
	if laser.Variant == LaserVariant.THIN_RED then
		local pct = M("lfCrWire")
		if pct > 0 and laser.MaxDistance > 0 then laser:SetMaxDistance(laser.MaxDistance * (1 + pct / 100)) end
	end
end))

-- Фенд (FF: ffscripts/players/dumb/fend.lua): Spirit Sword (нож-швабра) с отражением снарядов, урон ×0.2
local function isFend(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.FEND end
T.isFend = isFend
-- снаряд сбит шваброй: «Обратка», «Зеркальная швабра», «Чистюля»
function T.feDeflect(p, proj)
	local pd = proj:GetData()
	if pd.lfFeDone then return end
	pd.lfFeDone = true
	if M("lfFeTidy") > 0 and S.feTidy < 10 then
		S.feTidy = S.feTidy + 1
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
	end
	if M("lfFeMirror") > 0 or roll(M("lfFeReturn")) then
		local best, bd
		for _, en in ipairs(Isaac.FindInRadius(proj.Position, 400, EntityPartition.ENEMY)) do
			local d = en.Position:Distance(proj.Position)
			if enemy(en) and (not bd or d < bd) then best, bd = en, d end
		end
		local dir = best and (best.Position - proj.Position) or (proj.Position - p.Position)
		local t = fireExtra(p, proj.Position, dir:Resized(11), 1)
		if t then t.Color = Color(0.6, 0.9, 1, 1, 0.1, 0.3, 0.4) end
	end
end
local function feKnifeOwner(knife)
	local p = knife.Parent and knife.Parent:ToPlayer() or (knife.SpawnerEntity and knife.SpawnerEntity:ToPlayer())
	return p and isFend(p) and p
end
mod:AddCallback(ModCallbacks.MC_PRE_KNIFE_COLLISION, safe("feKnife", function(_, knife, other)
	local proj = other and other:ToProjectile()
	local p = proj and feKnifeOwner(knife)
	if p then T.feDeflect(p, proj) end
end))
mod:AddCallback(ModCallbacks.MC_PRE_PROJECTILE_COLLISION, safe("feProj", function(_, proj, other)
	if other and other:ToPlayer() then proj:GetData().lfHitPlayer = true return end
	local k = other and other:ToKnife()
	local p = k and feKnifeOwner(k)
	if p then T.feDeflect(p, proj) end
end))
-- взмах Spirit Sword с отражением (Lost Contact) гасит снаряды самим движком, без колбэков столкновения (проверено
-- 18.10 настоящим взмахом) — снаряд, исчезнувший в воздухе рядом с Фендом во время взмаха, считается сбитым
mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, safe("feGone", function(_, e)
	local proj = e:ToProjectile()
	if not proj or proj:GetData().lfHitPlayer or proj:GetData().lfFeDone or proj.Height > -4 then return end
	local p = player0()
	if not (p and isFend(p)) or proj.Position:Distance(p.Position) > 120 then return end
	for _, k in ipairs(Isaac.FindByType(EntityType.ENTITY_KNIFE)) do
		if feKnifeOwner(k:ToKnife()) then
			T.feDeflect(p, proj)
			return
		end
	end
end), EntityType.ENTITY_PROJECTILE)

-- Фронд (FF: ffscripts/players/dumb/frond.lua): в комнате с врагами раз в ползадержки выстрела (данные FrondDelay)
-- выпускает слезу пота с таинственной жидкостью (зелёная лужа); слёзы ядовитые и растущие
local function isFrond(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.FROND end
T.isFrond = isFrond
-- ближайший враг: перебор сущностей комнаты (FindInRadius по разделу ENEMY не видит врага, пока у него нет
-- столкновений — например, в анимации появления; проверено 18.10)
local function nearestEnemy(pos, r)
	local best, bd
	r = r or 600
	for _, en in ipairs(Isaac.GetRoomEntities()) do
		if enemy(en) then
			local d = en.Position:Distance(pos)
			if d <= r and (not bd or d < bd) then best, bd = en, d end
		end
	end
	return best
end
T.nearestEnemy = nearestEnemy
-- слёзы пота и брызги: 8 слёз с таинственной жидкостью вокруг
function T.foBurst(p)
	for i = 0, 7 do
		local t = fireExtra(p, p.Position, Vector(7, 0):Rotated(i * 45), 1)
		if t then
			t:AddTearFlags(TearFlags.TEAR_MYSTERIOUS_LIQUID_CREEP)
			t.FallingSpeed = t.FallingSpeed - 6
			t.FallingAcceleration = t.FallingAcceleration + 0.5
		end
	end
	play("SOUND_BOIL_HATCH", 0.6, 1.4)
end
T.foUpdate = safe("frond", function(_, p)
	if p.Index ~= player0().Index or not isFrond(p) then return end
	local d = ffData(p)
	if d and d.FrondDelay and not game:GetRoom():IsClear() then   -- «Испарина»
		local k = M("lfFoSweatRate") / 100
		if k > 0 then d.FrondDelay = d.FrondDelay - k end
	end
	if M("lfFoMiasma") > 0 and p.FrameCount % 60 == 0 then   -- «Миазмы»
		local hit = false
		for _, en in ipairs(Isaac.FindInRadius(p.Position, 85, EntityPartition.ENEMY)) do
			if enemy(en) then
				en:AddPoison(EntityRef(p), 63, p.Damage)
				hit = true
			end
		end
		if hit then
			game:SpawnParticles(p.Position, EffectVariant.DUST_CLOUD, 3, 1, Color(0.8, 0.8, 0.3, 0.5, 0.2, 0.2, 0))
		end
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.foUpdate)
-- слеза пота (FF добавляет TEAR_MYSTERIOUS_LIQUID_CREEP после FireTear — видно в первом обновлении слезы)
mod:AddCallback(ModCallbacks.MC_POST_TEAR_UPDATE, safe("foTear", function(_, tear)
	if tear.FrameCount > 1 or not tear:HasTearFlags(TearFlags.TEAR_MYSTERIOUS_LIQUID_CREEP) then return end
	local p = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
	if not (p and isFrond(p)) then return end
	local d = tear:GetData()
	if d.lfFoSweat or T.extraFiring then return end
	d.lfFoSweat = true
	local pct = M("lfFoSweatDmg")
	if pct > 0 then tear.CollisionDamage = tear.CollisionDamage * (1 + pct / 100) end
	if M("lfFoFlood") > 0 then   -- «Потоп»
		local en = nearestEnemy(tear.Position)
		if en then
			tear.Velocity = (en.Position - tear.Position):Resized(math.max(6, tear.Velocity:Length()))
			d.lfFoTarget = en
		end
	end
end))
-- зелёные лужи Фронда
mod:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, safe("foCreep", function(_, eff)
	local pct = M("lfFoCreep")
	if pct <= 0 then return end
	local sp = eff.SpawnerEntity
	local p = sp and (sp:ToPlayer() or (sp.SpawnerEntity and sp.SpawnerEntity:ToPlayer()))
	if p and isFrond(p) then eff:GetData().lfFoCreep = 1 + pct / 100 end
end), EffectVariant.PLAYER_CREEP_GREEN)

-- Фиент (FF: ffscripts/players/dumb/fient.lua): медленные тяжёлые оглушающие слёзы, дым при выстреле, гнилые сердца
local function isFient(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.FIENT end
T.isFient = isFient
local function standing(p) return p:GetMovementInput():Length() < 0.1 and p.Velocity:Length() < 0.6 end
T.standing = standing
function T.fiSmoke(p, r, frames)
	for _, en in ipairs(Isaac.GetRoomEntities()) do
		if enemy(en) and en.Position:Distance(p.Position) <= r then en:AddConfusion(EntityRef(p), frames, false) end
	end
	game:SpawnParticles(p.Position, EffectVariant.DUST_CLOUD, 6, 2, Color(0.8, 0.8, 0.85, 0.6, 0.2, 0.2, 0.2))
end
T.fiUpdate = safe("fient", function(_, p)
	if p.Index ~= player0().Index or not isFient(p) then return end
	if M("lfFiChill") > 0 or M("lfFiZen") > 0 then   -- стоит/идёт — пересчёт слёз
		local st = standing(p)
		if st ~= S.fiStill then
			S.fiStill = st
			p:AddCacheFlags(CacheFlag.CACHE_FIREDELAY, true)
		end
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.fiUpdate)

-- Ми (FF: ffscripts/players/dumb/mi.lua): плоская слеза (данные FF isMiFlatTear) на 20-м кадре умирает и оставляет
-- аметистового миньона (эффект 1000.1736.10); с правом первородства — миньона Изверга
local function isMi(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.MI end
T.isMi = isMi
local MINION_V = 1736
function T.miMinion(p, pos, lost)
	local ff = FF()
	if lost and ff.PICKUP and ff.PICKUP.VARIANT and ff.PICKUP.VARIANT.FIEND_MINION_EFFECT then
		local m = Isaac.Spawn(1000, ff.PICKUP.VARIANT.FIEND_MINION_EFFECT, 10, pos, Vector.Zero, p)
		m.EntityCollisionClass = 4
		m.Parent = p
		local d = ff:GetEntityData(m)
		d.hollow, d.canreroll, d.fiendsLostFriend = true, false, true
		m:Update()
		return m
	end
	local m = Isaac.Spawn(1000, MINION_V, 10, pos, Vector.Zero, p)
	m:Update()
	return m
end
-- слеза Ми на 19-м кадре (FF превратит её на 20-м): «Двойня», «Рой», «Потерянные друзья»
mod:AddCallback(ModCallbacks.MC_POST_TEAR_UPDATE, safe("miTear", function(_, tear)
	if tear.FrameCount ~= 19 then return end
	local d = ffData(tear)
	if not (d and d.isMiFlatTear) then return end
	local p = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
	if not (p and isMi(p)) then return end
	local lost = M("lfMiLost") > 0
	if lost and not d.MiBirthrightTear then d.MiBirthrightTear = true end   -- FF сам оставит миньона Изверга
	if M("lfMiSwarm") > 0 or roll(M("lfMiTwins")) then T.miMinion(p, tear.Position + RandomVector() * 8, lost) end
end))

-- Фризер-младшая (FF: ffscripts/players/dumb/freezerjr.lua): data.FreezerJrCharge (+1/125 за кадр при прицеле),
-- FreezerJrFullyCharged; отпускание полного заряда — «сбой» (стирает сущности и сетку комнаты)
local function isFreezer(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.FREEZERJR end
T.isFreezer = isFreezer
function T.fzCrash(p)   -- «сбой» случился
	if M("lfFzDefrag") > 0 and (S.fzDefrag or 0) < 5 then
		S.fzDefrag = (S.fzDefrag or 0) + 1
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
	end
	if M("lfFzBsod") > 0 then p:AddHearts(2) end
	if roll(M("lfFzBackup")) then
		local room = game:GetRoom()
		local vs = { PickupVariant.PICKUP_COIN, PickupVariant.PICKUP_BOMB, PickupVariant.PICKUP_KEY, PickupVariant.PICKUP_HEART }
		-- после «сбоя» FF ещё 3 кадра чистит комнату — подбор появится позже
		S.fzBackupAt = game:GetFrameCount() + 6
		S.fzBackupV = vs[rng:RandomInt(#vs) + 1]
	end
end
T.fzUpdate = safe("freezer", function(_, p)
	if p.Index ~= player0().Index or not isFreezer(p) then return end
	local d = ffData(p)
	if not d then return end
	if d.FreezerJrCharging and d.FreezerJrCharge and not d.FreezerJrFullyCharged then
		local k = M("lfFzOverclock") / 100 - (M("lfFzBsod") > 0 and 0.25 or 0)
		if k ~= 0 then d.FreezerJrCharge = math.max(0, d.FreezerJrCharge + k / 125) end
	end
	if S.fzFull and not d.FreezerJrFullyCharged and not d.FreezerJrCharging then T.fzCrash(p) end
	S.fzFull = d.FreezerJrFullyCharged and true or false
	local charging = d.FreezerJrCharging and true or false
	if charging ~= S.fzCharging then
		S.fzCharging = charging
		if M("lfFzFlicker") > 0 then p:AddCacheFlags(CacheFlag.CACHE_FIREDELAY, true) end
	end
	if charging and M("lfFzStatic") > 0 and p.FrameCount % 10 == 0 then
		for _, en in ipairs(Isaac.GetRoomEntities()) do
			if enemy(en) and en.Position:Distance(p.Position) <= 120 then en:AddSlowing(EntityRef(p), 15, 0.6, Color(0.7, 0.7, 1, 1, 0, 0, 0.2)) end
		end
	end
	if S.fzBackupAt and game:GetFrameCount() >= S.fzBackupAt then
		local room = game:GetRoom()
		Isaac.Spawn(EntityType.ENTITY_PICKUP, S.fzBackupV, 0, room:FindFreePickupSpawnPosition(p.Position + Vector(0, 40), 0, true), Vector.Zero, nil)
		S.fzBackupAt = nil
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.fzUpdate)

-- Пит (FF: ffscripts/dead/fiend_b_skin_legitimate.lua): подбирает только сердца; Birthcake — дружественный Бетер
local function isPeat(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.PEAT end
T.isPeat = isPeat
function T.peBrawl(p)   -- «Драка с курицей»: тройной урон врагам в 2 клетках, отбрасывание
	for _, en in ipairs(Isaac.GetRoomEntities()) do
		if enemy(en) and en.Position:Distance(p.Position) <= 85 then
			en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0)
			en:AddVelocity((en.Position - p.Position):Resized(8))
		end
	end
	game:ShakeScreen(6)
	play("SOUND_PUNCH", 1, 0.9)
end
-- урон врагам внутри обработки урона по игроку игра не проводит (проверено 18.10) — сдача в следующем кадре
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("peat", function(_, p)
	if S.peBrawlPending and p.Index == player0().Index and isPeat(p) then
		S.peBrawlPending = nil
		T.peBrawl(p)
	end
end))
function T.peBeeter(p)
	local ff = FF()
	local b = ff.FF and ff.FF.Beeter
	if not b then return end
	local room = game:GetRoom()
	local bee = Isaac.Spawn(b.ID, b.Var, 0, room:FindFreePickupSpawnPosition(p.Position + RandomVector() * 40, 0, true), Vector.Zero, p):ToNPC()
	if bee then
		bee:AddCharmed(EntityRef(p), -1)
		bee:ClearEntityFlags(EntityFlag.FLAG_APPEAR)
	end
	return bee
end

-- Классический Изверг (FF: fiend_classic.lua, customhealth.lua 735–800): удар превращает полные чёрные сердца в
-- миньонов-сердца (пикап FIEND_MINION_CLASSIC; бьют уроном Изверга с флагом DAMAGE_COUNTDOWN)
local function isClassic(p) return FF() and FF().PLAYER and p and p:GetPlayerType() == FF().PLAYER.CLASSIC_FIEND end
T.isClassic = isClassic
local function cfVar() return FF().PICKUP.VARIANT.FIEND_MINION_CLASSIC end
function T.cfMinion(p, pos)
	local ff = FF()
	local m = Isaac.Spawn(EntityType.ENTITY_PICKUP, cfVar(), 0, Isaac.GetFreeNearPosition(pos or p.Position, 40), Vector.Zero, p)
	ff:GetEntityData(m).canreroll = false
	m.EntityCollisionClass = 4
	m.Parent = p
	return m
end
local function cfMinions()
	local out = {}
	for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP, cfVar())) do
		if not e:IsDead() then out[#out + 1] = e end
	end
	return out
end
T.cfMinions = cfMinions
-- «Запасное сердце»: миньон после удара (в следующем кадре — после миньонов FF)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("classic", function(_, p)
	if S.cfExtraPending and p.Index == player0().Index and isClassic(p) then
		S.cfExtraPending = nil
		T.cfMinion(p, p.Position)
	end
end))
-- (localfixes грузится раньше FF — вариант пикапа проверяется внутри)
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, safe("cfMinion", function(_, pk)
	local p = player0()
	if not isClassic(p) or pk.Variant ~= cfVar() then return end
	local d = pk:GetData()
	if pk.FrameCount <= 1 and not d.lfCfSeen then   -- новый миньон: «Орда»
		d.lfCfSeen = true
		if M("lfCfHorde") > 0 and not d.lfCfTwin and not T.cfTwinning then
			T.cfTwinning = true
			local t = T.cfMinion(p, pk.Position)
			t:GetData().lfCfTwin, t:GetData().lfCfSeen = true, true
			T.cfTwinning = false
		end
	end
	local k = M("lfCfMinionSpeed") / 100   -- «Гончие»: доп. тяга по ходу движения — тем же AddVelocity, что у FF
	if k > 0 and pk.Velocity:LengthSquared() > 0.01 and not game:GetRoom():IsClear() then
		pk:AddVelocity(pk.Velocity:Resized(k))
	end
	if M("lfCfKamikaze") > 0 and not game:GetRoom():IsClear() then   -- «Камикадзе»
		for _, en in ipairs(Isaac.GetRoomEntities()) do
			if enemy(en) and en.Position:Distance(pk.Position) <= en.Size + 16 then
				for _, x in ipairs(Isaac.GetRoomEntities()) do
					if enemy(x) and x.Position:Distance(pk.Position) <= 80 then x:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
				end
				game:SpawnParticles(pk.Position, EffectVariant.BLOOD_PARTICLE, 10, 4, Color(0.2, 0.1, 0.2, 1, 0, 0, 0))
				play("SOUND_DEATH_BURST_SMALL", 0.8)
				pk:Remove()
				break
			end
		end
	end
end))

-- Глобальные таланты (любой персонаж)
-- «Серия», «Адреналин», «Первопроходец», «Счастливая монета», «Разбег»: состояние и пересчёт характеристик
T.glUpdate = safe("global", function(_, p)
	if p.Index ~= player0().Index then return end
	local now = game:GetFrameCount()
	if S.glStreak and S.glStreak > 0 and now - (S.glStreakAt or 0) > 90 then   -- серия прервалась (3 с)
		S.glStreak = 0
		p:AddCacheFlags(CacheFlag.CACHE_FIREDELAY, true)
	end
	if S.glAdrenUntil and now >= S.glAdrenUntil then
		S.glAdrenUntil = nil
		p:AddCacheFlags(CacheFlag.CACHE_FIREDELAY, true)
	end
	if M("lfGlLuckyCoin") > 0 and p.FrameCount % 15 == 0 then
		local c = math.min(5, math.floor(p:GetNumCoins() / 15))
		if c ~= S.glCoinLuck then
			S.glCoinLuck = c
			p:AddCacheFlags(CacheFlag.CACHE_LUCK, true)
		end
	end
	if M("lfGlMomentum") > 0 then
		local mv = p.Velocity:Length() > 1
		if mv ~= S.glMoving then
			S.glMoving = mv
			p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
		end
	end
	if S.glOverkill then   -- «Перебор»: остаток урона — ближайшему врагу (в следующем кадре)
		local o = S.glOverkill
		S.glOverkill = nil
		local best, bd
		for _, en in ipairs(Isaac.GetRoomEntities()) do
			if enemy(en) and not en:IsDead() and GetPtrHash(en) ~= o.hash then
				local d = en.Position:Distance(o.pos)
				if not bd or d < bd then best, bd = en, d end
			end
		end
		if best then
			T.glSplash = true
			best:TakeDamage(o.dmg, 0, EntityRef(p), 0)
			T.glSplash = false
		end
	end
	if S.glThorns then   -- «Шипы»: удар по атакующему (в следующем кадре — внутри обработки урона по игроку не проходит)
		local e = S.glThorns
		S.glThorns = nil
		if e and e:Exists() and enemy(e) then e:TakeDamage(p.Damage * 5 * M("lfGlThorns") / 100, 0, EntityRef(p), 0) end
	end
	if S.glPhoenixFire then
		S.glPhoenixFire = nil
		for _, en in ipairs(Isaac.GetRoomEntities()) do
			if enemy(en) then en:AddBurn(EntityRef(p), 90, p.Damage) end
		end
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.glUpdate)
-- «Джекпот»: подобранная монета; «Сундучник»: открытый сундук
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_COLLISION or ModCallbacks.MC_PRE_PICKUP_COLLISION, safe("glPick", function(_, pk, coll)
	local p = coll and coll:ToPlayer()
	if not p then return end
	local d = pk:GetData()
	if pk.Variant == PickupVariant.PICKUP_COIN and not d.lfJack and pk.Price == 0 then
		d.lfJack = true
		if roll(M("lfGlJackpot")) then
			Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY, pk.Position, RandomVector() * 3, nil)
		end
	end
end))
local CHESTS = { [PickupVariant.PICKUP_CHEST] = true, [PickupVariant.PICKUP_LOCKEDCHEST] = true,
	[PickupVariant.PICKUP_BOMBCHEST] = true, [PickupVariant.PICKUP_ETERNALCHEST] = true,
	[PickupVariant.PICKUP_SPIKEDCHEST] = true, [PickupVariant.PICKUP_MIMICCHEST] = true,
	[PickupVariant.PICKUP_OLDCHEST] = true, [PickupVariant.PICKUP_WOODENCHEST] = true,
	[PickupVariant.PICKUP_HAUNTEDCHEST] = true, [PickupVariant.PICKUP_REDCHEST] = true,
	[PickupVariant.PICKUP_MEGACHEST] = true }
T.glChestOpened = safe("glChest", function(pk)
	local d = pk:GetData()
	if d.lfChestDone then return end
	d.lfChestDone = true
	if roll(M("lfGlChest")) then
		local r = rng:RandomInt(3)
		local v = r == 0 and PickupVariant.PICKUP_COIN or r == 1 and PickupVariant.PICKUP_BOMB or PickupVariant.PICKUP_KEY
		Isaac.Spawn(EntityType.ENTITY_PICKUP, v, 1, pk.Position, RandomVector() * 3, nil)
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, safe("glChestUpd", function(_, pk)
	if not CHESTS[pk.Variant] then return end
	local d = pk:GetData()
	if pk.SubType ~= 0 then d.lfWasClosed = true   -- закрытый (ChestSubType.CHEST_CLOSED)
	elseif d.lfWasClosed and not d.lfChestDone then T.glChestOpened(pk) end   -- открыт при нас (уже открытые — нет)
end))
-- «Сдача»: покупка в магазине
if ModCallbacks.MC_POST_PICKUP_SHOP_PURCHASE then
	mod:AddCallback(ModCallbacks.MC_POST_PICKUP_SHOP_PURCHASE, safe("glShop", function(_, pk, player, spent)
		if (spent or 0) > 0 and roll(M("lfGlChange")) then
			local p = player and player:ToPlayer()
			if p then
				p:AddCoins(2)
				play("SOUND_CASH_REGISTER", 0.6)
			end
		end
	end))
end

-- Обычные персонажи Isaac: новые ветки их деревьев PST. Механики не привязаны к персонажу (узлы есть только в его
-- дереве — значит, работают только у него)
T.vanUpdate = safe("vanilla", function(_, p)
	if p.Index ~= player0().Index then return end
	-- «Коллекционер»: пересчёт урона, когда меняется число предметов
	if M("lfIsCollector") > 0 then
		local n = math.min(6, math.floor(p:GetCollectibleCount() / 5))
		if n ~= S.isItems then
			S.isItems = n
			p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
		end
	end
	-- «Целительный выплеск», «Переполнение», «Милосердие»: изменение красного здоровья
	local h = (p:GetHearts() or 0)
	if S.mgHearts and h > S.mgHearts and p.FrameCount > 2 and roll(M("lfMgHealBurst")) and not S.mgBurstRoom then
		S.mgBurstRoom = true
		for i = 0, 5 do fireExtra(p, p.Position, Vector(9, 0):Rotated(i * 60), 1) end
		play("SOUND_VAMP_GULP", 0.5, 1.2)
	end
	S.mgHearts = h
	-- «Счастливая семёрка», «Игрок»: удача меняется — пересчёт
	if (M("lfCaLuckDmg") > 0) and p.FrameCount % 10 == 0 then
		local l = math.floor(p.Luck)
		if l ~= S.caLuck then
			S.caLuck = l
			p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
		end
	end
	-- «Отмычка»: потраченный ключ (без золотого) — шанс вернуть
	local k = p:GetNumKeys()
	if S.caKeys and k == S.caKeys - 1 and not p:HasGoldenKey() and roll(M("lfCaPicklock")) then
		p:AddKeys(1)
		k = k + 1
		play("SOUND_KEYPICKUP_GAUNTLET", 0.6, 1.3)
	end
	S.caKeys = k
	-- «Тьма внутри»: число чёрных сердец меняется
	if M("lfJdDark") > 0 then
		local b = darkHearts(p)
		if b ~= S.jdDark then
			S.jdDark = b
			p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
		end
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, T.vanUpdate)
-- «Переполнение» и «Милосердие»: красное сердце, подобранное при полном красном здоровье
mod:AddCallback(ModCallbacks.MC_PRE_PICKUP_COLLISION, safe("mgFull", function(_, pk, coll)
	local p = coll and coll:ToPlayer()
	if not p or pk.Variant ~= PickupVariant.PICKUP_HEART then return end
	local red = { [HeartSubType.HEART_FULL] = 2, [HeartSubType.HEART_HALF] = 1, [HeartSubType.HEART_DOUBLEPACK] = 4,
		[HeartSubType.HEART_SCARED] = 2 }
	local amt = red[pk.SubType]
	if not amt or pk:GetData().lfMgDone or (p:GetMaxHearts() or 0) == 0 or (p:GetHearts() or 0) < (p:GetEffectiveMaxHearts() or 0) then return end
	pk:GetData().lfMgDone = true
	if roll(M("lfMgOverflow")) then p:AddSoulHearts(1) end
	if M("lfMgCharity") > 0 and (S.mgMercy or 0) < 20 then
		S.mgMercy = math.min(20, (S.mgMercy or 0) + amt)
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
		pk:Remove()   -- «съедено» милосердием (иначе при полном здоровье сердце осталось бы лежать)
		play("SOUND_BOSS2_BUBBLES", 0.5, 1.4)
		return true
	end
end), PickupVariant.PICKUP_HEART)
-- «Брызги»: слеза попала во врага — 3 маленькие
mod:AddCallback(ModCallbacks.MC_PRE_TEAR_COLLISION, safe("isSplash", function(_, tear, other)
	if not (other and enemy(other)) or tear:GetData().lfSplashed or T.extraFiring then return end
	local p = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
	if not p or not roll(M("lfIsSplash")) then return end
	tear:GetData().lfSplashed = true
	for i = -1, 1 do
		local t = fireExtra(p, tear.Position, tear.Velocity:Rotated(180 + i * 40):Resized(7), 0.4)
		if t then
			t.Scale = t.Scale * 0.6
			t:GetData().lfSplashed = true
		end
	end
end))

-- обёртки FF: залп «Огненного шквала» и урон огненных шаров
local function hookFF()
	local ff = FF()
	if T.ffHooked or not (ff and ff.LaunchFireball) then return end
	T.ffHooked = true
	local orig = ff.LaunchFireball
	local inStorm = false
	-- «Огранка»: сила брелоков-камней; функция FF рекурсивна (Henge Rock, Molten Fossil) — бонус только снаружи
	if ff.GetGolemTrinketPower then
		local origPow, depth = ff.GetGolemTrinketPower, 0
		ff.GetGolemTrinketPower = function(player, id, ...)
			depth = depth + 1
			local ok, a, b = pcall(origPow, player, id, ...)
			depth = depth - 1
			if not ok then error(a, 0) end
			if depth == 0 and type(a) == "number" and a > 0 and player and isGolem(player) then
				local pct = M("lfGoTrinketPower")
				if pct > 0 then a = a * (1 + pct / 100) end
			end
			return a, b
		end
	end
	-- «Друза»: одна жеода — как две
	if ff.HasTwoGeodes and ff.IsGeode then
		local origTwo = ff.HasTwoGeodes
		ff.HasTwoGeodes = function(player, ...)
			if player and M("lfGoDruse") > 0 and isGolem(player) then
				for i = 0, 1 do
					local t = player:GetTrinket(i)
					if t > 0 and ff.IsGeode(t) then return true end
				end
			end
			return origTwo(player, ...)
		end
	end
	-- «Эхо окаменелости» и «Висмутовое благословение»: разбитый брелок-камень
	if ff.CrushRockTrinket then
		local origCrush = ff.CrushRockTrinket
		ff.CrushRockTrinket = function(player, trinketId, crusher, ...)
			local r = origCrush(player, trinketId, crusher, ...)
			if player and isGolem(player) then
				local real = ff.GetRealTrinketId and ff:GetRealTrinketId(trinketId) or trinketId
				local eff = ff.FossilBreakEffects and ff.FossilBreakEffects[real]
				if eff and M("lfGoFossilEcho") > 0 then pcall(eff, player, crusher) end
				if roll(M("lfGoCrushSoul")) then
					player:AddSoulHearts(2)
					play("SOUND_HOLY", 0.6)
				end
			end
			return r
		end
	end
	-- Слиппи: боковые слёзы тройного выстрела (FF создаёт их в slippyPostFireTear) — «Тройное кваканье»
	if ff.slippyPostFireTear then
		local origSl = ff.slippyPostFireTear
		ff.slippyPostFireTear = function(self, player, tear, ...)
			local pct = (player and isSlippy(player)) and M("lfSlTriple") or 0
			if pct <= 0 then return origSl(self, player, tear, ...) end
			local before = {}
			for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do before[GetPtrHash(t)] = true end
			local r = origSl(self, player, tear, ...)
			local main = tear and GetPtrHash(tear)
			for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
				local h = GetPtrHash(t)
				if not before[h] and h ~= main then
					t.CollisionDamage = t.CollisionDamage * (1 + pct / 100)
					t:GetData().lfSide = true
				end
			end
			return r
		end
	end
	-- Френд: урон пули, шанс крита
	if ff.GetFriendShotDamageBonus then
		local origBonus = ff.GetFriendShotDamageBonus
		ff.GetFriendShotDamageBonus = function(self, gun, player, shot, ...)
			local gd = gun and ff:GetEntityData(gun)
			local reload = gd and gd.reloadBonusActivated
			local flat, mult, crit = origBonus(self, gun, player, shot, ...)
			if player and isFriend(player) and type(mult) == "number" then
				local ok, add = pcall(T.frBonus, gun, player, shot, reload)
				if ok then mult = mult + add end
			end
			return flat, mult, crit
		end
	end
	if ff.GetFriendCritChance then
		local origCrit = ff.GetFriendCritChance
		ff.GetFriendCritChance = function(self, player, ...)
			local c = origCrit(self, player, ...)
			if player and isFriend(player) and type(c) == "number" then c = c + M("lfFrCrit") end
			return c
		end
	end
	-- Инаба: слёзы глаз-спутников; «Третий глаз»
	if ff.FireSatelliteTear then
		local origSat = ff.FireSatelliteTear
		ff.FireSatelliteTear = function(self, player, ...)
			local tear = origSat(self, player, ...)
			if tear and player and isInaba(player) then pcall(T.inSatTear, player, tear) end
			return tear
		end
	end
	if ff.playerHasBirthcake then
		local origCake = ff.playerHasBirthcake
		ff.playerHasBirthcake = function(self, player, ...)
			local has, n = origCake(self, player, ...)
			if not has and T.inFamP and player and GetPtrHash(player) == GetPtrHash(T.inFamP) then return true, 1 end
			return has, n
		end
	end
	ff.LaunchFireball = function(player, dir, mode, ...)
		local r = orig(player, dir, mode, ...)
		if not inStorm and player and M("lfFfFireStorm") > 0 and dir then
			inStorm = true
			pcall(orig, player, dir:Rotated(25), mode)
			pcall(orig, player, dir:Rotated(-25), mode)
			inStorm = false
		end
		return r
	end
end

-- урон огненных шаров FF: слеза FIRE_MIND с данными specialfiend — в первом кадре
mod:AddCallback(ModCallbacks.MC_POST_TEAR_UPDATE, safe("ffFireballDmg", function(_, tear)
	if tear.FrameCount > 1 or not FF() then return end
	local pct = M("lfFfFireballDmg")
	if pct <= 0 then return end
	local d = ffData(tear)
	if d and d.specialfiend and not d.lfDmg then
		d.lfDmg = true
		tear.CollisionDamage = tear.CollisionDamage * (1 + pct / 100)
	end
end))

-- убийство врага
mod:AddCallback(ModCallbacks.MC_POST_ENTITY_KILL, safe("kill", function(_, e)
	local npc = e:ToNPC()
	if not npc or npc:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) or not npc:IsEnemy() then return end
	local p = player0()
	if not p then return end
	local pos = npc.Position
	-- «Жажда крови»: 8 убийств в комнате — ярость до зачистки
	S.roomKills = S.roomKills + 1
	if M("lfKBerserk") > 0 and not S.rage and S.roomKills >= 8 and not game:GetRoom():IsClear() then
		S.rage = true
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
		p:SetColor(Color(1, 0.4, 0.4, 1, 0.3, 0, 0), 30, 1, true, false)
		play("SOUND_BERSERK_START", 0.6)
	end
	-- «Вампиризм»: каждые 30 убийств — полсердца
	if M("lfKVampire") > 0 then
		S.vampKills = S.vampKills + 1
		if S.vampKills >= 30 then
			S.vampKills = 0
			if isChina(p) then p:AddBrokenHearts(-1)   -- у Чайны — склеить сломанное сердце
			elseif (p:GetMaxHearts() or 0) > 0 and (p:GetHearts() or 0) < (p:GetEffectiveMaxHearts() or 0) then p:AddHearts(1)
			else p:AddBlackHearts(1) end
			play("SOUND_VAMP_GULP", 0.7)
		end
	end
	if roll(M("lfGoQuake")) then   -- «Толчок»: враги рядом получают урон игрока
		game:ShakeScreen(6)
		game:SpawnParticles(pos, EffectVariant.ROCK_PARTICLE, 8, 4)
		play("SOUND_ROCK_CRUMBLE", 0.6)
		for _, en in ipairs(Isaac.FindInRadius(pos, 90, EntityPartition.ENEMY)) do
			if enemy(en) and en.Index ~= npc.Index then en:TakeDamage(p.Damage, 0, EntityRef(p), 0) end
		end
	end
	if roll(M("lfKillBurst")) then
		for i = 0, 5 do
			local t = fireExtra(p, pos, Vector(9, 0):Rotated(i * 60), 0.6)
			if t then t:AddTearFlags(TearFlags.TEAR_SPECTRAL) end
		end
	end
	if S.pickupsThisRoom < 2 and roll(M("lfKillPickup")) then
		S.pickupsThisRoom = S.pickupsThisRoom + 1
		local r = rng:RandomInt(10)
		local v, st = PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY
		if r >= 5 and r < 7 then v, st = PickupVariant.PICKUP_BOMB, BombSubType.BOMB_NORMAL
		elseif r >= 7 and r < 9 then v, st = PickupVariant.PICKUP_KEY, KeySubType.KEY_NORMAL
		elseif r == 9 then v, st = PickupVariant.PICKUP_HEART, HeartSubType.HEART_HALF end
		Isaac.Spawn(EntityType.ENTITY_PICKUP, v, st, pos, RandomVector() * 2, nil)
	end
	if roll(M("lfMgBloodHeal")) and (p:GetHearts() or 0) < (p:GetEffectiveMaxHearts() or 0) then p:AddHearts(1) end   -- «Кровопийца»
	if p:GetNumCoins() < 30 and roll(M("lfJdSilver")) then   -- «Тридцать сребреников»
		Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY, pos, RandomVector() * 2, nil)
	end
	if M("lfGlStreak") > 0 then   -- «Серия»
		local now = game:GetFrameCount()
		if now - (S.glStreakAt or -999) <= 90 then S.glStreak = math.min(5, (S.glStreak or 0) + 1) end
		S.glStreakAt = now
		p:AddCacheFlags(CacheFlag.CACHE_FIREDELAY, true)
	end
	if isPeat(p) and roll(M("lfPeLaugh")) then   -- «Хе-хе-хе»
		for _, en in ipairs(Isaac.GetRoomEntities()) do
			if enemy(en) and en.Position:Distance(pos) <= 120 then en:AddFear(EntityRef(p), 60) end
		end
	end
	if isMi(p) and roll(M("lfMiPiggy")) and FF().AddFractionalCoins then   -- «Копилка»
		FF():AddFractionalCoins(0.1)
		play("SOUND_PENNYPICKUP", 0.4, 1.4)
	end
	if isFient(p) and not S.fiStashRoom and roll(M("lfFiStash")) then   -- «Заначка»
		local ff = FF()
		if ff.PICKUP and ff.PICKUP.VARIANT and ff.PICKUP.VARIANT.FFSACK and ff.PICKUP.SACK and ff.PICKUP.SACK.DRUG_BAGGIE then
			S.fiStashRoom = true
			Isaac.Spawn(EntityType.ENTITY_PICKUP, ff.PICKUP.VARIANT.FFSACK, ff.PICKUP.SACK.DRUG_BAGGIE, pos, Vector.Zero, nil)
		end
	end
	if (isFrond(p) or isFient(p)) and roll(M("lfFoChunk")) then   -- «Ошмётки»: кружащий гнилой ошмёток FF (до 3)
		local sd = ffData(p) and ffData(p).ffsavedata
		if sd and (sd.MorbidChunks or 0) < 3 then
			sd.MorbidChunks = (sd.MorbidChunks or 0) + 1
			p:AddCacheFlags(CacheFlag.CACHE_FAMILIARS, true)
			play("SOUND_BOIL_HATCH", 0.5, 1.2)
		end
	end
	if isFriend(p) and roll(M("lfFrKillReload")) and T.frLoadOne(p) then   -- «Трофейный патрон»
		play("SOUND_BUTTON_PRESS", 0.5, 1.3)
	end
	if isInaba(p) then
		if roll(M("lfInOrbOnKill")) and FF().SpawnInabaPowerItem then FF().SpawnInabaPowerItem(0, pos) end
		local sv = inSave(p)
		if sv and sv.MigraineMode and M("lfInMigraineKill") > 0 then   -- «Горячка»
			sv.MigraineGauge = math.min(migCap(), (sv.MigraineGauge or 0) + M("lfInMigraineKill"))
			S.inGauge = sv.MigraineGauge
		end
	end
	if isFiend(p) then
		if roll(M("lfFfFireballOnKill")) then T.ffAddFireball(p) end
		if roll(M("lfFfMinionOnKill")) then T.ffMinion(p, pos) end
		if roll(M("lfFfImmoralDrop")) then
			local ff = FF()
			local h = Isaac.Spawn(5, ff.PICKUP.VARIANT.HALF_IMMORAL_HEART, 0, pos, RandomVector() * 1.5, p):ToPickup()
			if h then h.Timeout = 60 end
		end
	end
	VAN.onKill(npc, p, pos)   -- ветки персонажей игры
end))

-- урон по врагам: крит, боссы
mod:AddPriorityCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, CallbackPriority.LATE, safe("dmg", function(_, ent, amount, flags, src, cd)
	if ent:ToPlayer() then return end
	if not enemy(ent) then return end
	local se = src.Entity
	local ff = FF()
	local fbInfo = ff and ff.FF and ff.FF.FriendFireball
	local fireball = se and fbInfo and se.Type == fbInfo.ID and se.Variant == fbInfo.Var
	local p = sourcePlayer(src) or (fireball and player0()) or VAN.altSource(se)
	if not p then return end
	local mult = 1
	if fireball and M("lfFrFireballDmg") > 0 and isFriend(p) then mult = mult * (1 + M("lfFrFireballDmg") / 100) end
	if se and se:ToTear() and se:GetData().lfCrit then mult = mult * 2 end
	if ent:IsBoss() and M("lfBossSlayer") > 0 then mult = mult * (1 + M("lfBossSlayer") / 100) end
	if se and se:ToLaser() and (se.Variant == LaserVariant.BRIM_TECH or se.Variant == LaserVariant.THICKER_BRIM_TECH)
		and M("lfCrRayDmg") > 0 and isCraig(p) then   -- «Высокое напряжение»: луч батарейки
		mult = mult * (1 + M("lfCrRayDmg") / 100)
	end
	if M("lfJdBackstab") > 0 and ent.Velocity:LengthSquared() > 0.25 and ent.Velocity:Dot(p.Position - ent.Position) < 0 then
		mult = mult * (1 + M("lfJdBackstab") / 100)   -- «Удар в спину»: враг движется от вас
	end
	if M("lfJdKiss") > 0 and not S.jdKissUsed and ent:ToNPC() and not ent:IsBoss() then   -- «Поцелуй Иуды»
		S.jdKissUsed = true
		ent:AddCharmed(EntityRef(p), 150)
	end
	if not T.glSplash then
		local ed = ent:GetData()
		if M("lfGlFirstStrike") > 0 and not ed.lfHitOnce then mult = mult * (1 + M("lfGlFirstStrike") / 100) end
		ed.lfHitOnce = true
		if M("lfGlExecute") > 0 and ent.HitPoints < ent.MaxHitPoints * 0.25 then mult = mult * (1 + M("lfGlExecute") / 100) end
		if se and se:GetData().lfRhythm then mult = mult * 3 end
		local total = amount * mult
		if M("lfGlOverkill") > 0 and total > ent.HitPoints and ent.HitPoints > 0 then   -- «Перебор»
			S.glOverkill = { dmg = (total - ent.HitPoints) * M("lfGlOverkill") / 100, pos = ent.Position, hash = GetPtrHash(ent) }
		end
	end
	if isClassic(p) and M("lfCfMinionDmg") > 0 and flags & DamageFlag.DAMAGE_COUNTDOWN ~= 0 and se and se:ToPlayer() then
		for _, m in ipairs(cfMinions()) do   -- удар миньона-сердца: FF бьёт от имени Изверга, миньон вплотную к врагу
			if m.Position:Distance(ent.Position) <= ent.Size + 30 then
				mult = mult * (1 + M("lfCfMinionDmg") / 100)
				break
			end
		end
	end
	if isMi(p) and se and se:ToTear() and M("lfMiEdge") > 0 then
		local td = ffData(se)
		if td and td.isMiFlatTear then mult = mult * (1 + M("lfMiEdge") / 100) end   -- «Острая грань»
	end
	if isFient(p) and M("lfFiDaze") > 0 and ent:HasEntityFlags(EntityFlag.FLAG_CONFUSION) then
		mult = mult * (1 + M("lfFiDaze") / 100)   -- «Одурь»
	end
	if isFrond(p) then
		if M("lfFoToxic") > 0 and ent:HasEntityFlags(EntityFlag.FLAG_POISON) then mult = mult * (1 + M("lfFoToxic") / 100) end
		if se and se:GetData().lfFoCreep then mult = mult * se:GetData().lfFoCreep end   -- «Зловонная лужа»
	end
	if se and se:ToKnife() and isFend(p) then
		if M("lfFeMopDmg") > 0 then mult = mult * (1 + M("lfFeMopDmg") / 100) end   -- «Тяжёлая швабра»
		if roll(M("lfFeWetFloor")) then   -- «Мокрый пол»
			local c = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.PLAYER_CREEP_HOLYWATER_TRAIL, 0, ent.Position, Vector.Zero, p):ToEffect()
			if c then
				c.CollisionDamage = p.Damage
				c:SetTimeout(90)
				c.SpriteScale = Vector(1.4, 1.4)
				c:Update()
			end
		end
	end
	if M("lfCrChain") > 0 and not T.chaining and se and se:ToLaser() and isCraig(p) and roll(25) then   -- «Цепная молния»
		local ed = ent:GetData()
		if (ed.lfChainCd or 0) <= game:GetFrameCount() then
			ed.lfChainCd = game:GetFrameCount() + 15
			local best, bd
			for _, en in ipairs(Isaac.FindInRadius(ent.Position, 120, EntityPartition.ENEMY)) do
				local dd = en.Position:Distance(ent.Position)
				if enemy(en) and GetPtrHash(en) ~= GetPtrHash(ent) and (not bd or dd < bd) then best, bd = en, dd end
			end
			if best then
				T.chaining = true
				best:TakeDamage(amount * 0.5, 0, EntityRef(p), 0)
				T.chaining = false
				-- видно: искры по линии разряда (без урона)
				for k = 0, 5 do
					game:SpawnParticles(ent.Position + (best.Position - ent.Position) * (k / 5), EffectVariant.EMBER_PARTICLE, 2, 2,
						Color(1, 1, 0.3, 1, 0.6, 0.6, 0))
				end
				play("SOUND_REDLIGHTNING_ZAP", 0.4, 1.4)
			end
		end
	end
	-- «Легион»: огненные шары копятся на 25% медленнее — вычет из накопленного урона Изверга
	if M("lfFfHellLegion") > 0 and isFiend(p) then
		local d = ffData(p)
		local sd = d and d.ffsavedata
		if sd and sd.fiendDamageDealt then sd.fiendDamageDealt = math.max(0, sd.fiendDamageDealt - amount * 0.2) end
	end
	mult = mult * VAN.dmgMult(ent, p, se, amount, flags)   -- ветки персонажей игры
	if mult ~= 1 then
		return { Damage = amount * mult }
	end
end))

-- выстрел: поджог, крит
function T.tearFx(tear)
	local d = tear:GetData()
	if d.lfTearFx then return end
	d.lfTearFx = true
	if M("lfIsHeaven") > 0 and not T.extraFiring then   -- «Свет небес»: каждая 10-я слеза
		S.isBeat = (S.isBeat or 0) + 1
		if S.isBeat % 10 == 0 then
			local p = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
			local en = p and T.nearestEnemy and T.nearestEnemy(p.Position, 900)
			if en then
				local beam = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.CRACK_THE_SKY, 0, en.Position, Vector.Zero, p):ToEffect()
				if beam then beam.CollisionDamage = 0 end
				en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0)
			end
		end
	end
	if M("lfGlRhythm") > 0 and not T.extraFiring then   -- «Ритм»: каждая 4-я слеза
		S.glBeat = (S.glBeat or 0) + 1
		if S.glBeat % 4 == 0 then
			d.lfRhythm = true
			tear.Scale = tear.Scale * 1.3
			tear.Color = Color(0.6, 0.8, 1, 1, 0.1, 0.2, 0.5)
		end
	end
	if roll(M("lfTearBurn")) then
		tear:AddTearFlags(TearFlags.TEAR_BURN)
		tear.Color = Color(1, 0.6, 0.3, 1, 0.25, 0.05, 0)
	end
	if roll(M("lfTearPoison")) then
		tear:AddTearFlags(TearFlags.TEAR_POISON)
		tear.Color = Color(0.4, 1, 0.4, 1, 0, 0.2, 0)
	end
	if roll(M("lfTearPetrify")) then
		tear:AddTearFlags(TearFlags.TEAR_FREEZE)
		tear.Color = Color(0.6, 0.6, 0.6, 1, 0.1, 0.1, 0.1)
	end
	if roll(M("lfCrit")) then
		tear:GetData().lfCrit = true
		tear.Color = Color(1, 0.3, 0.3, 1, 0.35, 0, 0)
		tear.Scale = tear.Scale * 1.15
	end
	local tp = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
	if tp then VAN.tear(tear, tp) end   -- ветки персонажей игры
end
mod:AddCallback(ModCallbacks.MC_POST_FIRE_TEAR, safe("tear", function(_, tear)
	T.tearFx(tear)
	if T.extraFiring then return end
	local p = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
	if p and isFient(p) then
		if roll(M("lfFiSmoke")) then T.fiSmoke(p, 85, 60) end   -- «Дымовая завеса»
		if M("lfFiZen") > 0 and standing(p) then   -- «Дзен»
			tear:AddTearFlags(TearFlags.TEAR_PIERCING | TearFlags.TEAR_HOMING)
			tear.Color = Color(0.7, 1, 0.7, 1, 0, 0.15, 0)
		end
	end
	local fd = p and ffData(p)
	-- «Лягушачий залп»: ещё две слезы по бокам — только к основной (боковые FF стреляет под своей защитой)
	if p and M("lfSlFivefold") > 0 and isSlippy(p) and not (fd and fd.cannotFireMoreSlippyTears) then
		for _, a in ipairs({ -30, 30 }) do
			local t = fireExtra(p, tear.Position, tear.Velocity:Rotated(a), 0.6)
			if t then
				t.Scale = tear.Scale * 0.85
				t:GetData().lfVolley = true
			end
		end
	end
end))

-- урон по игроку: «Нетронутый» сбрасывается, «Кровавый договор»
mod:AddPriorityCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, CallbackPriority.IMPORTANT, safe("hurt", function(_, ent, amount, flags, src, cd)
	local p = ent:ToPlayer()
	if not p then return end
	if flags & (DamageFlag.DAMAGE_FAKE | DamageFlag.DAMAGE_NO_PENALTIES) ~= 0 then return end
	if M("lfFfBloodPact") > 0 and isFiend(p) and not S.pactUsed and not game:GetRoom():IsClear() then
		S.pactUsed = true
		T.ffMinion(p, p.Position)
		p:SetMinDamageCooldown(30)
		play("SOUND_DEVIL_CARD", 0.6)
		return false
	end
	if M("lfGoStoneSkin") > 0 and isGolem(p) and FF().GetHeldRockCount and FF().GetHeldRockCount(p, {}) >= 2 and roll(25) then
		game:SpawnParticles(p.Position, EffectVariant.ROCK_PARTICLE, 6, 3)
		play("SOUND_ROCK_CRUMBLE", 0.8)
		p:SetMinDamageCooldown(30)
		return false
	end
	if isChina(p) then
		local selfHit = src and src.Entity and GetPtrHash(src.Entity) == GetPtrHash(p)
		if (selfHit or flags & DamageFlag.DAMAGE_PITFALL ~= 0) and roll(M("lfChPadded")) then   -- «Мягкие стены»
			p:SetMinDamageCooldown(30)
			return false
		end
		if M("lfChBubble") > 0 and not S.chBubbleUsed and not game:GetRoom():IsClear() then   -- «Пузырчатая плёнка»
			S.chBubbleUsed = true
			p:SetMinDamageCooldown(40)
			p:SetColor(Color(0.8, 0.9, 1, 1, 0.3, 0.3, 0.4), 15, 1, true, false)
			play("SOUND_PLOP", 0.8, 1.6)
			return false
		end
	end
	if VAN.onHurt(p, amount, flags, src) == false then return false end   -- ветки персонажей игры (уворот, козёл отпущения)
	local hpNow = (p:GetHearts() or 0) + (p:GetSoulHearts() or 0) + (p:GetBoneHearts() or 0) * 2 + (p:GetEternalHearts() or 0)
	if M("lfGlPhoenix") > 0 and not S.glPhoenixUsed and hpNow <= amount and not isChina(p) then   -- «Феникс»
		S.glPhoenixUsed = true
		if (p:GetMaxHearts() or 0) > 0 then p:AddHearts(2) else p:AddSoulHearts(2) end
		p:SetMinDamageCooldown(60)
		S.glPhoenixFire = true
		game:ShakeScreen(12)
		play("SOUND_HOLY", 0.8, 0.8)
		return false
	end
	if M("lfGlThorns") > 0 and src and src.Entity and enemy(src.Entity) then S.glThorns = src.Entity end
	if M("lfGlAdrenaline") > 0 then
		S.glAdrenUntil = game:GetFrameCount() + 150
		p:AddCacheFlags(CacheFlag.CACHE_FIREDELAY, true)
	end
	if isClassic(p) and not game:GetRoom():IsClear() then
		local ms = cfMinions()
		local hp = (p:GetHearts() or 0) + (p:GetSoulHearts() or 0) + (p:GetBoneHearts() or 0) * 2
		if M("lfCfLastBreath") > 0 and not S.cfBreathUsed and #ms > 0 and hp <= amount then   -- «Последний вздох»
			S.cfBreathUsed = true
			ms[1]:Remove()
			p:AddBlackHearts(2)
			p:SetMinDamageCooldown(40)
			play("SOUND_UNHOLY", 0.6)
			return false
		end
		if roll(M("lfCfExtraMinion")) then S.cfExtraPending = true end   -- «Запасное сердце»: после удара
	end
	if isPeat(p) and not game:GetRoom():IsClear() then
		if M("lfPeChicken") > 0 and not S.peChickenUsed then   -- «Бесконечная драка»
			S.peChickenUsed = true
			S.peBrawlPending = true
			p:SetMinDamageCooldown(30)
			return false
		end
		if roll(M("lfPeBrawl")) then S.peBrawlPending = true end   -- «Драка с курицей»
	end
	if M("lfFoBloat") > 0 and isFrond(p) and not game:GetRoom():IsClear() then T.foBurst(p) end   -- «Вздутие»
	if M("lfCrGround") > 0 and isCraig(p) and flags & DamageFlag.DAMAGE_EXPLOSION ~= 0 and S.crPeak >= crMax() * 1.9 then
		return false   -- «Заземление»: взрыв перегрузки батарейки
	end
	if M("lfSlToadSkin") > 0 and isSlippy(p) then
		local d = ffData(p)
		if d and d.frogStop and roll(M("lfSlToadSkin")) then
			p:SetColor(Color(0.5, 1, 0.5, 1, 0, 0.3, 0), 15, 1, true, false)
			play("SOUND_MEAT_JUMPS", 0.6, 0.8)
			p:SetMinDamageCooldown(30)
			return false
		end
	end
	S.hitThisRoom = true
	if S.flawless > 0 then
		S.flawless = 0
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
	end
end))

-- характеристики по условию
mod:AddPriorityCallback(ModCallbacks.MC_EVALUATE_CACHE, CallbackPriority.LATE, safe("cache", function(_, p, flag)
	if p.Index ~= player0().Index then return end
	local dmg, tears, luck = 0, 0, 0
	local hp = (p:GetHearts() or 0) + (p:GetSoulHearts() or 0) + (p:GetBoneHearts() or 0) * 2
	if isChina(p) then
		hp = (p:GetBrokenHearts() or 0) >= 8 and 0 or 99   -- у Чайны «мало здоровья» — 8+ сломанных сердец
		local b = (p:GetBrokenHearts() or 0)
		dmg = dmg + M("lfChCracks") * b
		tears = tears + M("lfChJitters") * b
		if M("lfChBubble") > 0 then dmg = dmg - 10 end
	end
	if M("lfLowHpFury") > 0 and hp <= 2 then
		dmg = dmg + M("lfLowHpFury")
		tears = tears + M("lfLowHpFury")
	end
	if S.flawless > 0 then dmg = dmg + S.flawless * M("lfFlawlessDmg") end
	if M("lfFfBlackHeartDmg") > 0 and isFiend(p) then dmg = dmg + math.min(4, darkHearts(p)) * M("lfFfBlackHeartDmg") end
	if S.rubble > 0 then dmg = dmg + S.rubble * M("lfGoRockBreakDmg") end
	if M("lfGoHeavy") > 0 and p.MoveSpeed < 1 then dmg = dmg + M("lfGoHeavy") * math.floor((1 - p.MoveSpeed) * 10 + 0.001) end
	local fast = M("lfInHarePace") + M("lfSpeedDmg")   -- «Лунный заяц» Инабы и общий «Разгон»
	if fast > 0 and p.MoveSpeed > 1 then
		dmg = dmg + fast * math.floor((p.MoveSpeed - 1) * 10 + 0.001)
	end
	if isSlippy(p) then
		local d = ffData(p)
		if M("lfSlStillPond") > 0 and d and d.frogStop then
			dmg = dmg + 25
			tears = tears + 50
		end
		if M("lfSlFivefold") > 0 then tears = tears - 10 end
		if M("lfSlSlam") > 0 then tears = tears - 10 end
	end
	if isCraig(p) and M("lfCrChain") > 0 then tears = tears - 10 end
	if isFrond(p) and M("lfFoMiasma") > 0 then tears = tears - 10 end
	if isClassic(p) and M("lfCfHorde") > 0 then dmg = dmg - 10 end
	-- обычные персонажи
	if M("lfIsCollector") > 0 then dmg = dmg + M("lfIsCollector") * math.min(6, math.floor(p:GetCollectibleCount() / 5)) end
	if M("lfIsHeaven") > 0 then tears = tears - 5 end
	dmg = dmg + (S.mgMercy or 0)
	if M("lfCaLuckDmg") > 0 and p.Luck > 0 then dmg = dmg + M("lfCaLuckDmg") * math.min(10, math.floor(p.Luck)) end
	if M("lfCaLucky7") > 0 then tears = tears - 10 end
	if M("lfJdDark") > 0 then dmg = dmg + M("lfJdDark") * math.min(6, darkHearts(p)) end
	if M("lfJdKiss") > 0 then dmg = dmg - 5 end
	-- глобальные
	if M("lfGlRhythm") > 0 then tears = tears - 10 end
	if M("lfGlLuckyCoin") > 0 then
		dmg = dmg - 5
		luck = luck + math.min(5, math.floor(p:GetNumCoins() / 15))
	end
	if M("lfGlPhoenix") > 0 then dmg = dmg - 5 end
	if M("lfGlExplorer") > 0 then
		dmg = dmg + 2 * (S.glNewRooms or 0)
		luck = luck - 1
	end
	if M("lfGlMomentum") > 0 and p.Velocity:Length() > 1 then dmg = dmg + M("lfGlMomentum") end
	if (S.glStreak or 0) > 0 then tears = tears + S.glStreak * M("lfGlStreak") end
	local vDmg, vTears, vLuck, vSpeed = VAN.cache(p, flag)   -- ветки персонажей игры
	dmg, tears, luck = dmg + vDmg, tears + vTears, luck + vLuck
	if S.glAdrenUntil then tears = tears + M("lfGlAdrenaline") end
	if isPeat(p) then
		if M("lfPeBelly") > 0 then dmg = dmg + M("lfPeBelly") * math.min(6, math.floor((p:GetHearts() or 0) / 2)) end
		if M("lfPeChicken") > 0 then tears = tears - 10 end
		if M("lfPeBuddy") > 0 then dmg = dmg - 10 end
	end
	if isFreezer(p) then
		dmg = dmg + (S.fzDefrag or 0) * M("lfFzDefrag")
		local d = ffData(p)
		if M("lfFzFlicker") > 0 and d and d.FreezerJrCharging then tears = tears + M("lfFzFlicker") end
	end
	if isMi(p) then
		if M("lfMiSwarm") > 0 then tears = tears - 20 end
		if M("lfMiLost") > 0 then dmg = dmg - 10 end
	end
	if isFient(p) then
		if M("lfFiSlowShot") > 0 and p.ShotSpeed < 1 then
			dmg = dmg + M("lfFiSlowShot") * math.floor((1 - p.ShotSpeed) * 10 + 0.001)
		end
		if M("lfFiChill") > 0 and standing(p) then tears = tears + M("lfFiChill") end
		if M("lfFiZen") > 0 then dmg = dmg - 10 end
	end
	if isFend(p) then
		dmg = dmg + S.feTidy * M("lfFeTidy")
		if M("lfFeShine") > 0 and (p:GetHearts() or 0) >= (p:GetEffectiveMaxHearts() or 0) and (p:GetMaxHearts() or 0) > 0 then
			dmg = dmg + M("lfFeShine")
		end
		if M("lfFeMirror") > 0 then dmg = dmg - 10 end
		if M("lfFePro") > 0 then tears = tears - 20 end
	end
	local sv = isInaba(p) and inSave(p)
	if sv and sv.MigraineMode then
		dmg = dmg + M("lfInMigraineDmg")
		tears = tears + M("lfInMigraineTears")
	end
	if M("lfGoDruse") > 0 then tears = tears - 5 end
	if M("lfGoMotherlode") > 0 then luck = luck - 1 end
	if S.rage and M("lfKBerserk") > 0 then dmg = dmg + 40 end
	if M("lfKBerserk") > 0 then tears = tears - 5 end
	luck = luck + S.cursedLuck
	if M("lfFfCursedFortune") > 0 then luck = luck - 1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfKVampire") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfGoStoneSkin") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfSlStillPond") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfCrGround") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfFoFlood") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfFiHotbox") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfFzStatic") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfPeFatGuy") > 0 then p.MoveSpeed = p.MoveSpeed - 0.15 end
	if flag == CacheFlag.CACHE_SPEED and M("lfCfLastBreath") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and M("lfMgCharity") > 0 then p.MoveSpeed = p.MoveSpeed - 0.1 end
	if flag == CacheFlag.CACHE_SPEED and vSpeed ~= 0 then p.MoveSpeed = p.MoveSpeed + vSpeed end
	if flag == CacheFlag.CACHE_LUCK and M("lfCaLucky7") > 0 and p.Luck < 7 then p.Luck = 7 end   -- «Счастливая семёрка»
	if flag == CacheFlag.CACHE_DAMAGE and dmg ~= 0 then p.Damage = p.Damage * (1 + dmg / 100) end
	if flag == CacheFlag.CACHE_DAMAGE and M("lfFePro") > 0 and isFend(p) then
		p.Damage = p.Damage * 2.5   -- «Профессионал»: FF режет урон Фенда ×0.2 — с талантом ×0.5
	end
	if flag == CacheFlag.CACHE_FIREDELAY and tears ~= 0 then
		p.MaxFireDelay = math.max(1, (p.MaxFireDelay + 1) / (1 + tears / 100) - 1)
	end
	if flag == CacheFlag.CACHE_LUCK and luck ~= 0 then p.Luck = p.Luck + luck end
	if flag == CacheFlag.CACHE_SIZE and M("lfChPetite") > 0 then   -- «Миниатюрная»
		p.SizeMulti = p.SizeMulti * (1 - math.min(0.4, M("lfChPetite") / 100))
	end
end))

-- здоровье меняется — пересчитать «Последний рубеж» и «Порочное сердце»
local lastHp, lastSpeed = -1, -1
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("hpwatch", function(_, p)
	if p.Index ~= player0().Index or p.FrameCount % 10 ~= 0 then return end
	if M("lfGoHeavy") > 0 or M("lfInHarePace") > 0 or M("lfSpeedDmg") > 0 then   -- урон от скорости
		local sp = math.floor(p.MoveSpeed * 100 + 0.5)
		if sp ~= lastSpeed then
			lastSpeed = sp
			p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
		end
	end
	if M("lfLowHpFury") <= 0 and M("lfFfBlackHeartDmg") <= 0 and M("lfPeBelly") <= 0 then return end
	local hp = (p:GetHearts() or 0) * 100 + (p:GetSoulHearts() or 0) + darkHearts(p) * 10000
	if hp ~= lastHp then
		lastHp = hp
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY, true)
	end
end))

-- «Жадность»: подборы рядом тянутся к игроку; «Последний шанс»: половина сердца — щит мантии раз за этаж
local MAGNET = { [PickupVariant.PICKUP_COIN] = true, [PickupVariant.PICKUP_BOMB] = true,
	[PickupVariant.PICKUP_KEY] = true, [PickupVariant.PICKUP_HEART] = true }
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("keystones", function(_, p)
	if p.Index ~= player0().Index then return end
	if M("lfKMagnet") > 0 then
		-- FindByType, а не FindInRadius(…, PICKUP): подбор в анимации появления в раздел столкновений не попадает
		for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP)) do
			local pk = e:ToPickup()
			if pk and MAGNET[pk.Variant] and pk.Position:DistanceSquared(p.Position) < 14400 and not pk:IsShopItem()
				and pk.Price == 0 and pk.Wait <= 0 then
				pk.Velocity = pk.Velocity * 0.7 + (p.Position - pk.Position):Resized(3.5)
			end
		end
	end
	if M("lfKLastChance") > 0 and not S.lastChanceUsed and p.FrameCount % 5 == 0 then
		local hp = (p:GetHearts() or 0) + (p:GetSoulHearts() or 0) + (p:GetBoneHearts() or 0) * 2
		if isChina(p) then hp = (p:GetBrokenHearts() or 0) >= 10 and 1 or 99 end   -- у Чайны — 10+ сломанных сердец
		if hp == 1 then
			S.lastChanceUsed = true
			p:GetEffects():AddCollectibleEffect(CollectibleType.COLLECTIBLE_HOLY_MANTLE, true)
			play("SOUND_HOLY_MANTLE", 0.8)
		end
	end
end))

-- вход в комнату
T.onRoom = safe("room", function()
	S.hitThisRoom, S.pickupsThisRoom, S.pactUsed, S.roomKills = false, 0, false, 0
	S.chBubbleUsed = false
	S.fiStashRoom = false
	S.peChickenUsed = false
	if M("lfGlExplorer") > 0 and game:GetRoom():IsFirstVisit() and (S.glNewRooms or 0) < 10 then
		S.glNewRooms = (S.glNewRooms or 0) + 1
		local p0 = player0()
		if p0 then p0:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true) end
	end
	S.cfBreathUsed = false
	S.mgBurstRoom, S.jdKissUsed = false, false
	VAN.onRoom()   -- ветки персонажей игры
	if not game:GetRoom():IsClear() and roll(M("lfIsMomGaze")) then   -- «Взгляд мамы»
		local p0 = player0()
		for _, en in ipairs(Isaac.GetRoomEntities()) do
			if enemy(en) and not en:IsBoss() then en:AddFreeze(EntityRef(p0), 30) end
		end
	end
	if S.feTidy > 0 then
		S.feTidy = 0
		local p0 = player0()
		if p0 then p0:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true) end
	end
	if S.rubble > 0 then
		S.rubble = 0
		local p0 = player0()
		if p0 then p0:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true) end
	end
	if S.rage then
		S.rage = false
		local p0 = player0()
		if p0 then p0:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true) end
	end
	local room = game:GetRoom()
	if room:IsClear() then return end
	local p = player0()
	if not p then return end
	if roll(M("lfRoomShield")) then
		p:GetEffects():AddCollectibleEffect(CollectibleType.COLLECTIBLE_HOLY_MANTLE, true)
	end
	if isFient(p) and M("lfFiHotbox") > 0 then T.fiSmoke(p, 2000, 90) end   -- «Задымление»
	if isPeat(p) then
		if roll(M("lfPeBeeter")) then T.peBeeter(p) end   -- «Эй, Бетер»
		if M("lfPeBuddy") > 0 then   -- «Лучший друг»: до 2 дружественных Бетеров
			local b, n = FF().FF and FF().FF.Beeter, 0
			if b then
				for _, e in ipairs(Isaac.FindByType(b.ID, b.Var)) do
					if e:HasEntityFlags(EntityFlag.FLAG_CHARM) or e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) then n = n + 1 end
				end
				if n < 2 then T.peBeeter(p) end
			end
		end
	end
	if isMi(p) and roll(M("lfMiAme")) then T.miMinion(p, p.Position + RandomVector() * 30, M("lfMiLost") > 0) end
	if isFriend(p) and M("lfFrOverheat") > 0 then   -- «Перегрев»: «Горячий выстрел» наполовину
		for _, slot in ipairs(hotSlots(p)) do
			p:AddActiveCharge(50, slot, true, false, true)
			S.frCharge[slot] = hotCharge(p, slot)
		end
	end
	if isFiend(p) then
		local n = 0
		if roll(M("lfFfMinionRoom")) then n = n + 1 end
		if M("lfFfHellLegion") > 0 then n = n + math.min(3, darkHearts(p)) end
		for i = 1, n do T.ffMinion(p, p.Position + RandomVector() * 20) end
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, T.onRoom)

-- зачистка комнаты
T.onClear = safe("clear", function()
	local p = player0()
	if not p then return end
	if S.rage then   -- ярость — до зачистки
		S.rage = false
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
	end
	if isChina(p) then
		local ff = FF()
		if roll(M("lfChPushPop")) and ff.ITEM and ff.ITEM.CARD and ff.ITEM.CARD.HORSE_PUSHPOP then   -- «Сладкоежка»
			local room = game:GetRoom()
			Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_TAROTCARD, ff.ITEM.CARD.HORSE_PUSHPOP,
				room:FindFreePickupSpawnPosition(room:GetCenterPos(), 0, true), Vector.Zero, nil)
		end
		if (p:GetBrokenHearts() or 0) > 0 and roll(M("lfChGlue")) then   -- «Клей»
			p:AddBrokenHearts(-1)
			play("SOUND_VAMP_GULP", 0.5, 1.3)
		end
	end
	if (isFrond(p) or isFient(p)) and roll(M("lfFoMorbid")) and CustomHealthAPI and CustomHealthAPI.Library then   -- «Гнилое нутро»
		pcall(CustomHealthAPI.Library.AddHealth, p, "MORBID_HEART", 1)
		play("SOUND_BOIL_HATCH", 0.5)
	end
	if roll(M("lfCaPatch")) then   -- «Повязка»: карта или пилюля
		local room = game:GetRoom()
		local pos = room:FindFreePickupSpawnPosition(room:GetCenterPos(), 0, true)
		if rng:RandomInt(2) == 0 then Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_TAROTCARD, 0, pos, Vector.Zero, nil)
		else Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_PILL, 0, pos, Vector.Zero, nil) end
	end
	if game:GetRoom():GetType() == RoomType.ROOM_BOSS and roll(M("lfGlBossLoot")) then   -- «Охотник за трофеями»
		local room = game:GetRoom()
		Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, HeartSubType.HEART_SOUL,
			room:FindFreePickupSpawnPosition(room:GetCenterPos() + Vector(0, 40), 0, true), Vector.Zero, nil)
	end
	if isClassic(p) and roll(M("lfCfBlackDrop")) then   -- «Тёмная жатва»
		local room = game:GetRoom()
		local ff = FF()
		local v = ff.PICKUP and ff.PICKUP.VARIANT and ff.PICKUP.VARIANT.HALF_BLACK_HEART
		if v then
			Isaac.Spawn(EntityType.ENTITY_PICKUP, v, 0, room:FindFreePickupSpawnPosition(room:GetCenterPos(), 0, true), Vector.Zero, nil)
		else
			Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, HeartSubType.HEART_BLACK, room:FindFreePickupSpawnPosition(room:GetCenterPos(), 0, true), Vector.Zero, nil)
		end
	end
	if isPeat(p) and roll(M("lfPeHearty")) then   -- «Сытный обед»
		local room = game:GetRoom()
		local st = rng:RandomInt(3) == 0 and HeartSubType.HEART_FULL or HeartSubType.HEART_HALF
		Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, st, room:FindFreePickupSpawnPosition(room:GetCenterPos(), 0, true), Vector.Zero, nil)
	end
	if isFend(p) and roll(M("lfFeFinds")) then   -- «Находки уборщика»
		local r = rng:RandomInt(10)
		local v, st = PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY
		if r >= 6 and r < 8 then v, st = PickupVariant.PICKUP_BOMB, BombSubType.BOMB_NORMAL
		elseif r >= 8 then v, st = PickupVariant.PICKUP_KEY, KeySubType.KEY_NORMAL end
		local room = game:GetRoom()
		Isaac.Spawn(EntityType.ENTITY_PICKUP, v, st, room:FindFreePickupSpawnPosition(room:GetCenterPos(), 0, true), Vector.Zero, nil)
	end
	if isFriend(p) and roll(M("lfFrHeartDrop")) then   -- «Патронташ»: сердце — больше патронов
		local r = rng:RandomInt(20)
		local st = r < 12 and HeartSubType.HEART_HALF or r < 17 and HeartSubType.HEART_FULL or HeartSubType.HEART_HALF_SOUL
		local room = game:GetRoom()
		local pos = room:FindFreePickupSpawnPosition(room:GetCenterPos(), 0, true)
		Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, st, pos, Vector.Zero, nil)
	end
	if S.goRocksFloor < 2 and roll(M("lfGoRockOnClear")) then
		S.goRocksFloor = S.goRocksFloor + 1
		T.goSpawnRock(game:GetRoom():GetCenterPos())
	end
	if game:GetRoom():GetType() == RoomType.ROOM_BOSS and roll(M("lfGoBossRock")) then
		T.goSpawnRock(game:GetRoom():GetCenterPos())
	end
	if M("lfFlawlessDmg") > 0 and not S.hitThisRoom and S.flawless < 5 then
		S.flawless = S.flawless + 1
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
	end
	VAN.onClear(p)   -- ветки персонажей игры
end)
mod:AddCallback(ModCallbacks.MC_PRE_SPAWN_CLEAN_AWARD, T.onClear)

-- новый этаж
T.onLevel = safe("level", function()
	S.flawless, S.cursedLuck, S.lastChanceUsed, S.goRocksFloor = 0, 0, false, 0
	S.fzDefrag = 0
	S.glPhoenixUsed, S.glNewRooms = false, 0
	S.mgMercy = 0
	if M("lfGoMotherlode") > 0 then T.goSpawnRock(game:GetRoom():GetCenterPos() + Vector(0, 60)) end
	local p = player0()
	if not p then return end
	p:AddCacheFlags(CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_LUCK, true)
	VAN.onLevel(p)   -- ветки персонажей игры
	if roll(M("lfGlCarto")) then   -- «Картограф»: карта этажа
		local level = game:GetLevel()
		if level.ApplyMapEffect then level:ApplyMapEffect() end
		level:UpdateVisibility()
	end
	if isPeat(p) and M("lfPeFatGuy") > 0 then   -- «Здоровяк»
		local sd = ffData(p) and ffData(p).ffsavedata
		if sd and (sd.lfPeFat or 0) < 3 then
			sd.lfPeFat = (sd.lfPeFat or 0) + 1
			p:AddMaxHearts(2)
			p:AddHearts(2)
		end
	end
	if isMi(p) and roll(M("lfMiStars")) and FF().ITEM and FF().ITEM.CARD and FF().ITEM.CARD.THIRTEEN_OF_STARS then
		Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_TAROTCARD, FF().ITEM.CARD.THIRTEEN_OF_STARS,
			game:GetRoom():FindFreePickupSpawnPosition(game:GetRoom():GetCenterPos() + Vector(40, 40), 0, true), Vector.Zero, nil)
	end
	if M("lfInFloorPower") > 0 and isInaba(p) then   -- «Полнолуние»
		local sv = inSave(p)
		if sv and sv.Power then
			sv.Power = math.min(400, sv.Power + M("lfInFloorPower"))
			S.inPow = sv.Power
		end
	end
	if roll(M("lfSecretMap")) then
		local level = game:GetLevel()
		for _, rt in ipairs({ RoomType.ROOM_SECRET, RoomType.ROOM_SUPERSECRET }) do
			local idx = level:QueryRoomTypeIndex(rt, false, rng)
			local desc = idx and level:GetRoomByIdx(idx)
			if desc and desc.Data and desc.Data.Type == rt then
				desc.DisplayFlags = desc.DisplayFlags | 5
				break
			end
		end
		level:UpdateVisibility()
	end
	-- «Кровавый договор»: цена — минус одно аморальное сердце за этаж
	if M("lfFfBloodPact") > 0 and isFiend(p) and CustomHealthAPI and CustomHealthAPI.Library and CustomHealthAPI.Library.AddHealth then
		pcall(CustomHealthAPI.Library.AddHealth, p, "IMMORAL_HEART", -2)
	end
end)
mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, T.onLevel)

-- проклятые монеты FF
mod:AddCallback(ModCallbacks.MC_PRE_PICKUP_COLLISION, safe("cursed", function(_, pickup, collider)
	local p = collider and collider:ToPlayer()
	local ff = FF()
	if not (p and ff and ff.PICKUP and ff.PICKUP.COIN and pickup.SubType == ff.PICKUP.COIN.CURSED) then return end
	if pickup:GetData().lfCounted then return end
	pickup:GetData().lfCounted = true
	if M("lfFfCursedLuck") > 0 then
		S.cursedLuck = S.cursedLuck + M("lfFfCursedLuck")
		p:AddCacheFlags(CacheFlag.CACHE_LUCK, true)
	end
	if M("lfFfCursedFortune") > 0 then
		-- FF разыгрывает монету (ffscripts/xalum/pickups/medley_pickup_effects/cursed_penny.lua: −1, +1, +2, −2 …) —
		-- через кадр сравнить монеты: убыль вернуть с тем же прибытком
		S.cursedCoins = { coins = p:GetNumCoins(), frame = game:GetFrameCount() }
		if isFiend(p) then T.ffMinion(p, p.Position) end
	end
end), PickupVariant.PICKUP_COIN)
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, safe("cursedcheck", function()
	local c = S.cursedCoins
	if not c or game:GetFrameCount() - c.frame < 2 then return end
	S.cursedCoins = nil
	local p = player0()
	local loss = c.coins - p:GetNumCoins()
	if loss > 0 then
		p:AddCoins(loss * 2)
		play("SOUND_PENNYPICKUP", 1, 0.8)
	end
end))

-- разбитый камень: «Старатель» (помеченные), «Щебень» (любой)
local ROCKS = { [GridEntityType.GRID_ROCK] = true, [GridEntityType.GRID_ROCKB] = true, [GridEntityType.GRID_ROCKT] = true,
	[GridEntityType.GRID_ROCK_ALT] = true, [GridEntityType.GRID_ROCK_SS] = true, [GridEntityType.GRID_ROCK_SPIKED] = true,
	[GridEntityType.GRID_ROCK_ALT2] = true, [GridEntityType.GRID_ROCK_GOLD] = true }
T.onRockBreak = safe("rock", function(_, gridEnt, gridType)
	local p = player0()
	if not p or not ROCKS[gridType] then return end
	if (gridType == GridEntityType.GRID_ROCKT or gridType == GridEntityType.GRID_ROCK_SS) and roll(M("lfGoTintedRock")) then
		T.goSpawnRock(gridEnt.Position)
	end
	if M("lfGoRockBreakDmg") > 0 and S.rubble < 5 then
		S.rubble = S.rubble + 1
		p:AddCacheFlags(CacheFlag.CACHE_DAMAGE, true)
	end
end)
if ModCallbacks.MC_POST_GRID_ROCK_DESTROY then
	mod:AddCallback(ModCallbacks.MC_POST_GRID_ROCK_DESTROY, T.onRockBreak)
end

-- начало забега: генератор случая, состояние
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, safe("start", function(_, cont)
	T.resetReports()
	rng:SetSeed(math.max(1, game:GetSeeds():GetStartSeed()), 35)
	if not cont then S.flawless, S.cursedLuck = 0, 0 end
	S.inPow, S.inGauge, S.inMig, S.frCharge, S.frCarry = nil, nil, nil, {}, 0
	S.slCarry, S.slTimer, S.slStill, S.slBounceCd = 0, nil, nil, 0
	S.chBroken, S.chBubbleUsed = nil, false
	S.crCharge, S.crCarry, S.crPeak = nil, 0, 0
	VAN.onStart(cont)   -- ветки персонажей игры
	-- множитель перезарядки FF общий для всех револьверов — в начале забега вернуть исходный
	if T.frReloadBase and FF() and FF().FriendBalancing then FF().FriendBalancing.ReloadMultiplier = T.frReloadBase end
	hookFF()
	local p = player0()
	if p and M("lfInThirdEye") > 0 and isInaba(p) then p:AddCacheFlags(CacheFlag.CACHE_FAMILIARS, true) end
end))

-- модули механик: каждый заполняет свою таблицу крючков (HOOKS)
for _, modName in ipairs({ "pst.vanilla_talents", "pst.ff_talents2", "pst.fu_talents", "pst.lnf_talents", "pst.ipecac_talents", "pst.ep_talents" }) do
	local okV, VM = pcall(include, modName)
	if okV and type(VM) == "table" and VM.init then
		local H = {}
		local okI, err = pcall(VM.init, { mod = mod, game = game, M = M, S = S, roll = roll, play = play, enemy = enemy,
			player0 = player0, fireExtra = fireExtra, nearestEnemy = nearestEnemy, safe = safe, rng = rng, T = T,
			FF = FF, ffData = ffData, darkHearts = darkHearts }, H)
		if okI then HOOKS[#HOOKS + 1] = H
		else Isaac.DebugString("[localfixes] таланты PST, модуль " .. modName .. ": " .. tostring(err)) end
	else
		Isaac.DebugString("[localfixes] таланты PST: нет модуля " .. modName .. " " .. tostring(VM))
	end
end

LOCALFIXES.InstallPSTTalents = T.install
LOCALFIXES.PSTTalents = T   -- для автотеста
return T
