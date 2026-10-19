-- localfixes/pst/ipecac_talents.lua — механики деревьев PST двух персонажей IPECAC Community Mod (18.10, слова
-- пользователя: «Таланты персонажам модов тебе тоже надо будет сделать если не сделал»; «Так делай таланты новым
-- персонажам с уже новым стилем»): Моисей (слёзы кружат вокруг, по взмаху посоха вылетают разом; полная орбита — ×1.2)
-- и Порченый Моисей (Книга казней в кармане: десять казней по очереди). Лёв и Йозеф в players.xml скрыты и автором
-- не доделаны («Not yet implemented») — деревьев нет. Всё — через данные самого мода (Characters/moses.lua,
-- Items/book_of_plagues.lua, Misc/Effects/blindness.lua): player:GetData().MosesTears, посох — нож варианта
-- «Moses Cane», IpecacCM.SaveData.BookOfPlaguesCurrentPlague, IpecacCM.BookOfPlaguesEffectsList и таймеры казней,
-- GetData().HasBlindnessEffect. Деревья — tools/pst_talents_spec.py.
local V = {}

function V.init(C, H)
	local mod, game, M, S, roll, play = C.mod, C.game, C.M, C.S, C.roll, C.play
	local enemy, player0, safe, rng, T, fireExtra = C.enemy, C.player0, C.safe, C.rng, C.T, C.fireExtra

	S.ip = S.ip or {}
	local F = S.ip
	local later = {}
	local ALL = CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY | CacheFlag.CACHE_SPEED | CacheFlag.CACHE_LUCK
	local function now() return game:GetFrameCount() end
	local function after(n, fn) later[#later + 1] = { now() + n, fn } end
	local function refresh(p) if p then p:AddCacheFlags(ALL, true) end end

	local ids = {}
	local function id(kind)
		if ids[kind] == nil then
			if kind == "moses" then ids[kind] = Isaac.GetPlayerTypeByName("Moses", false)
			elseif kind == "mosesB" then ids[kind] = Isaac.GetPlayerTypeByName("Moses", true)
			elseif kind == "book" then ids[kind] = Isaac.GetItemIdByName("Book of Plagues")
			elseif kind == "cane" then ids[kind] = Isaac.GetEntityVariantByName("Moses Cane") end
		end
		return ids[kind]
	end
	local function ok() return IpecacCM ~= nil end
	local function isMoses(p) return ok() and p and id("moses") >= 0 and p:GetPlayerType() == id("moses") end
	local function isMosesB(p) return ok() and p and id("mosesB") >= 0 and p:GetPlayerType() == id("mosesB") end
	local function hash(e) return e and GetPtrHash(e) end

	-- -------------------------------------------------------------------- Моисей: орбита
	-- предел орбиты — как getTearLimit в Characters/moses.lua (там он локальный)
	local TEARMULT = {
		[CollectibleType.COLLECTIBLE_20_20] = 2, [CollectibleType.COLLECTIBLE_MUTANT_SPIDER] = 8,
		[CollectibleType.COLLECTIBLE_INNER_EYE] = 4, [CollectibleType.COLLECTIBLE_MOMS_EYE] = 2,
		[CollectibleType.COLLECTIBLE_LOKIS_HORNS] = 4, [CollectibleType.COLLECTIBLE_EYE_SORE] = 3 }
	local function tearLimit(p)
		local base = math.min(math.max(math.ceil(60 / p.MaxFireDelay), 2), 20)
		local extra = 0
		for item, v in pairs(TEARMULT) do
			local has = IpecacCM.HasItemOrEffect and IpecacCM.HasItemOrEffect(p, item)
			if has then extra = extra + (v - 1) * p:GetCollectibleNum(item) + p:GetEffects():GetCollectibleEffectNum(item) end
		end
		if p:HasPlayerForm(PlayerForm.PLAYERFORM_BABY) then base = base * 3 end
		return base * (1 + extra)
	end
	local function orbit(p) return p:GetData().MosesTears end
	-- слеза таланта мимо орбиты: выстрел (FireTear → MC_POST_FIRE_TEAR) IPECAC забирает на орбиту Моисея, а сверх
	-- предела — удаляет (moses.lua OnFireTear); слеза, созданная напрямую, летит как обычная
	local function looseTear(p, pos, vel, mult)
		local t = Isaac.Spawn(EntityType.ENTITY_TEAR, TearVariant.BLUE, 0, pos, vel, p):ToTear()
		if not t then return nil end
		t.CollisionDamage = p.Damage * (mult or 1)
		t:AddTearFlags(p.TearFlags)
		t.Height = -23
		t.FallingSpeed = 0
		t.FallingAcceleration = 0.1
		t.Parent = p
		return t
	end

	-- -------------------------------------------------------------------- Порченый Моисей: казни
	local TIMERS = { "BookOfPlaguesPlagueOfBloodTimer", "BookOfPlaguesPlagueOfBoilsTimer", "BookOfPlaguesPlagueOfThunderstormTimer",
		"BookOfPlaguesPlagueOfFliesTimer" }
	local FLAGS = { "BookOfPlaguesPlagueOfLiceIsActive", "BookOfPlaguesPlagueOfFliesIsActive", "BookOfPlaguesPlagueOfPestilenceIsActive" }
	local function plagueActive()
		if not ok() then return false end
		for _, k in ipairs(TIMERS) do if (IpecacCM[k] or 0) > 0 then return true end end
		for _, k in ipairs(FLAGS) do if IpecacCM[k] then return true end end
		return false
	end
	local function addCharge(p, item, n)
		if not item or item < 0 then return false end
		for _, s in ipairs({ ActiveSlot.SLOT_PRIMARY, ActiveSlot.SLOT_POCKET }) do
			if p:GetActiveItem(s) == item then
				local cfg = Isaac.GetItemConfig():GetCollectible(item)
				local maxc = cfg and cfg.MaxCharges or 6
				local cur = p:GetActiveCharge(s)
				if cur < maxc then
					p:SetActiveCharge(math.min(maxc, cur + (n or 1)), s)
					game:GetHUD():FlashChargeBar(p, s)
					play("SOUND_BEEP", 0.5, 1.2)
					return true
				end
			end
		end
		return false
	end

	-- ==================================================================== крючки
	function H.dmgMult(ent, p, se, amount, flags)
		local mult = 1
		if isMoses(p) and se and se.Type == EntityType.ENTITY_TEAR then
			local h = hash(se)
			if F.msOrbit and F.msOrbit[h] then mult = mult * (1 + M("lfMsOrbit") / 100)                     -- «Облачный столп»
			elseif F.msRel and F.msRel[h] then mult = mult * (1 + M("lfMsRelease") / 100) end               -- «Исход»
		end
		if isMosesB(p) then
			local d = ent:GetData()
			if M("lfMtBlind") > 0 and ((d and d.HasBlindnessEffect) or ent:HasEntityFlags(EntityFlag.FLAG_SLOW)) then   -- «Слепая ярость»
				mult = mult * (1 + M("lfMtBlind") / 100)
			end
			if M("lfMtPharaoh") > 0 and ent:IsBoss() and plagueActive() then mult = mult * 1.25 end         -- «Ожесточённое сердце»
		end
		return mult
	end

	function H.cache(p, flag)
		local dmg, tears, luck, speed = 0, 0, 0, 0
		if isMoses(p) then
			if M("lfMsSinai") > 0 then                                                                        -- «Синай»
				if F.msFull then dmg = dmg + 20 end
				speed = speed - 0.1
			end
			if M("lfMsTablets") > 0 then dmg = dmg - 5 end
			if M("lfMsSerpent") > 0 then tears = tears - 5 end
			if M("lfMsBush") > 0 then dmg = dmg - 5 end
			if M("lfMsSea") > 0 then tears = tears - 5 end
		end
		if isMosesB(p) then
			if plagueActive() then dmg = dmg + M("lfMtWrath") end                                          -- «Гнев»
			if M("lfMtRelent") > 0 then                                                                       -- «Неумолимый»
				dmg = dmg + 3 * (F.mtCasts or 0)
				tears = tears - 5
			end
			if M("lfMtTenth") > 0 then dmg = dmg - 5 end
			if M("lfMtDouble") > 0 then speed = speed - 0.1 end
			if M("lfMtStaff") > 0 then dmg = dmg - 5 end
			if M("lfMtPharaoh") > 0 then tears = tears - 5 end
		end
		return dmg, tears, luck, speed
	end

	function H.onKill(npc, p, pos)
		if isMosesB(p) and plagueActive() and roll(M("lfMtCroak")) then p:AddBlueFlies(1, pos, nil) end      -- «Квакша»
	end

	function H.onClear(p)
		if isMoses(p) and roll(M("lfMsManna")) then                                                         -- «Манна»
			Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, HeartSubType.HEART_HALF_SOUL,
				game:GetRoom():FindFreePickupSpawnPosition(game:GetRoom():GetCenterPos(), 40, true), Vector.Zero, p)   -- не под ногами
		end
		if isMosesB(p) and roll(M("lfMtScroll")) then addCharge(p, id("book"), 1) end                      -- «Писание»
	end

	function H.onLevel(p)
		if (F.mtCasts or 0) > 0 then F.mtCasts = 0 refresh(p) end
	end

	function H.onStart(cont)
		later = {}
		F.msOrbit, F.msRel, F.msPrevTbl, F.msPrevList, F.msPrevFull, F.msFull = {}, {}, nil, nil, nil, nil
		F.mtCasts, F.mtSig, F.mtTimers = 0, nil, nil
	end

	-- ==================================================================== свои обработчики
	mod:AddCallback(ModCallbacks.MC_POST_UPDATE, safe("ipLater", function()
		if #later == 0 then return end
		local t, keep = now(), {}
		for _, j in ipairs(later) do
			if t >= j[1] then pcall(j[2]) else keep[#keep + 1] = j end
		end
		later = keep
	end))

	-- посох Моисея (нож 8.«Moses Cane» из moses.lua OnReleaseTears): «Жезл Божий» (урон), «Крепкая рука» (отброс),
	-- «Медный змей» (яд). Столкновений ножа-посоха игра не сообщает (MC_PRE_KNIFE_COLLISION для него не зовётся —
	-- зонд tools/lua/probe_moses_cane.lua, 18.10), поэтому задетые — враги, которых касается круг посоха в кадрах
	-- взмаха; каждому — по разу за взмах
	local function caneHits(knife, p)
		if not (M("lfMsRod") > 0 or M("lfMsPush") > 0 or M("lfMsSerpent") > 0) then return end
		local d = knife:GetData()
		d.lfHit = d.lfHit or {}
		-- запас 20: посох описывает дугу, а после первого кадра игра подтягивает нож к Моисею (враг у края круга то
		-- задевался, то нет)
		for _, coll in ipairs(Isaac.FindInRadius(knife.Position, knife.Size + 60, EntityPartition.ENEMY)) do
			local h = hash(coll)
			if enemy(coll) and not d.lfHit[h] and coll.Position:Distance(knife.Position) <= knife.Size + coll.Size + 20 then
				d.lfHit[h] = true
				if M("lfMsRod") > 0 then coll:TakeDamage(p.Damage * M("lfMsRod") / 100, 0, EntityRef(p), 0) end
				if M("lfMsPush") > 0 then   -- отбрасывание игры (враг скользит, его ход на это время стоит); без него — толчок
					local dir = (coll.Position - p.Position):Normalized()
					local okK = coll.AddKnockback and pcall(coll.AddKnockback, coll, EntityRef(p), dir * 10 * M("lfMsPush") / 100, 6, false)
					if not okK then coll:AddVelocity(dir * 12 * M("lfMsPush") / 100) end
				end
				if M("lfMsSerpent") > 0 then coll:AddPoison(EntityRef(p), 90, p.Damage) end
			end
		end
	end
	-- посох живёт пару кадров: проверка и в его обновлении, и в кадре выпуска орбиты (по только что созданному посоху)
	local function canesOf(p)
		local t = {}
		for _, k in ipairs(Isaac.FindByType(EntityType.ENTITY_KNIFE, id("cane"), -1, false, false)) do
			if k.Parent and GetPtrHash(k.Parent) == GetPtrHash(p) then t[#t + 1] = k end
		end
		return t
	end
	mod:AddCallback(ModCallbacks.MC_POST_KNIFE_UPDATE, safe("ipCane", function(_, knife)
		if knife.Variant ~= id("cane") then return end
		local p = knife.Parent and knife.Parent:ToPlayer()
		if isMoses(p) then caneHits(knife, p) end
	end))

	-- Книга казней: до применения — таймеры; после — продление, саранча, первенцы, неумолимость, двойная казнь, жезл
	local function timers()
		local t = {}
		for _, k in ipairs(TIMERS) do t[k] = IpecacCM[k] or 0 end
		return t
	end
	mod:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, safe("ipPreUse", function(_, it, _, p)
		if it == id("book") and isMosesB(p) then F.mtTimers = timers() end
	end))
	mod:AddCallback(ModCallbacks.MC_USE_ITEM, safe("ipUse", function(_, it, _, p)
		if not (it == id("book") and isMosesB(p) and ok()) then return end
		local before = F.mtTimers or {}
		F.mtTimers = nil
		after(1, function()
			local sd = IpecacCM.SaveData or {}
			local list = IpecacCM.BookOfPlaguesEffectsList or {}
			local cur = sd.BookOfPlaguesCurrentPlague
			local casts = 1
			if M("lfMtDouble") > 0 and #list > 0 and roll(20) then                                           -- «Двойная казнь»
				local nxt = ((cur or 0) % #list) + 1
				sd.BookOfPlaguesCurrentPlague = nxt
				pcall(list[nxt])
				casts = 2
				cur = nxt
			end
			if M("lfMtLong") > 0 then                                                                         -- «Долгие казни»
				for _, k in ipairs(TIMERS) do
					local inc = (IpecacCM[k] or 0) - (before[k] or 0)
					if inc > 0 then IpecacCM[k] = IpecacCM[k] + math.floor(inc * M("lfMtLong") / 100) end
				end
			end
			if cur == 8 and M("lfMtSwarm") > 0 then                                                          -- «Тучи»
				local extra = 3.5 * M("lfMtSwarm") / 100
				local n = math.floor(extra) + (rng:RandomFloat() < extra % 1 and 1 or 0)
				for _ = 1, n do Isaac.Spawn(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY, rng:RandomInt(5) + 1, p.Position, Vector.Zero, p) end
			end
			if cur == 10 and M("lfMtTenth") > 0 then p:AddSoulHearts(2) play("SOUND_HOLY", 0.6) end         -- «Десятая казнь»
			if M("lfMtRelent") > 0 then                                                                       -- «Неумолимый»
				F.mtCasts = math.min(10, (F.mtCasts or 0) + casts)
			end
			if M("lfMtStaff") > 0 then                                                                        -- «Жезл Аарона»
				for i = 0, 7 do fireExtra(p, p.Position, Vector(10, 0):Rotated(i * 45), 1) end
			end
			refresh(p)
		end)
	end))

	-- кадр игрока: орбита Моисея (купина, выпуск: пробой, заповеди, море) и казни
	mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("ipFrame", function(_, p)
		if not ok() or p.Index ~= player0().Index then return end
		if isMoses(p) then
			local mt = orbit(p) or {}
			local set, list = {}, {}
			for _, t in ipairs(mt) do
				if t and t:Exists() then
					set[hash(t)] = true
					list[#list + 1] = t
					if M("lfMsBush") > 0 and t.Type == EntityType.ENTITY_TEAR then                             -- «Неопалимая купина»
						local tt = t:ToTear()
						if tt and not tt:HasTearFlags(TearFlags.TEAR_BURN) then tt:AddTearFlags(TearFlags.TEAR_BURN) end
					end
				end
			end
			local full = #mt > 0 and #mt >= tearLimit(p)
			-- выпуск: мод заменил таблицу орбиты пустой
			if F.msPrevTbl and F.msPrevTbl ~= mt and F.msPrevList and #F.msPrevList > 0 then
				local rel = F.msRel or {}
				local n = 0
				for _, t in ipairs(F.msPrevList) do
					if t:Exists() and not set[hash(t)] then
						rel[hash(t)] = true
						n = n + 1
						local tt = t:ToTear()
						if tt and roll(M("lfMsPierce")) then tt:AddTearFlags(TearFlags.TEAR_PIERCING) end          -- «Расступившиеся воды»
					end
				end
				F.msRel = rel
				if n > 0 then for _, k in ipairs(canesOf(p)) do caneHits(k, p) end end                     -- взмах посоха
				if n > 0 and F.msPrevFull and M("lfMsTablets") > 0 then                                          -- «Десять заповедей»
					for i = 0, 9 do looseTear(p, p.Position, Vector(10, 0):Rotated(i * 36), 0.5) end
					play("SOUND_STONE_IMPACT", 0.5, 1.2)
				end
				if n > 0 and M("lfMsSea") > 0 then                                                               -- «Чермное море»
					for _, pr in ipairs(Isaac.FindInRadius(p.Position, 140, EntityPartition.BULLET)) do
						Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.TEAR_POOF_A, 0, pr.Position, Vector.Zero, nil)
						pr:Remove()
					end
					play("SOUND_BOSS2_BUBBLES", 0.5, 0.8)
				end
			end
			F.msOrbit, F.msPrevTbl, F.msPrevList, F.msPrevFull = set, mt, list, full
			if full ~= F.msFull then F.msFull = full if M("lfMsSinai") > 0 then refresh(p) end end
			-- выпущенные слёзы, которых уже нет, — забыть
			if F.msRel and p.FrameCount % 30 == 0 then
				local keep = {}
				for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR, -1, -1, false, false)) do
					if F.msRel[hash(t)] then keep[hash(t)] = true end
				end
				F.msRel = keep
			end
		end
		if isMosesB(p) then
			local sig = plagueActive()
			if sig ~= F.mtSig then F.mtSig = sig refresh(p) end
		end
	end))

	T.IP = V
	V.S = F
	V.H = H
	V.tearLimit = tearLimit
	V.plagueActive = plagueActive
	return V
end

return V
