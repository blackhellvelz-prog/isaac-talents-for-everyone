-- localfixes/pst/lnf_talents.lua — механики деревьев PST четырёх персонажей Lost and Forgotten (18.10, слова
-- пользователя: «Таланты персонажам модов тебе тоже надо будет сделать если не сделал»; «Так делай таланты новым
-- персонажам с уже новым стилем»): Робот (модули в гнёздах, Батарейка Робота; при ударе модули срабатывают и один
-- ломается), Порченый Робот (лом и Мастерская), Джозеф (Лунный камень, сон, сонные враги и сонные прибавки),
-- Порченый Джозеф (кошмары-зеваки 297.484, пробуждение со сломанными сердцами, накал кошмара). Всё — через данные
-- самого мода (lnfscripts/characters/*): LNF.GetPlayerData(p).Modules / ModulesDamage…, LNF.Modules[id]:func,
-- LNF.CanAddModule, LNF.Data().Scrap / Dream / RoomDream / MoonRockStats / NightmareIntensity, Lost.AddDream,
-- данные кошмара GetLNFData().Stats {урон, —, скорость, радиус}. Деревья — tools/pst_talents_spec.py.
local V = {}

function V.init(C, H)
	local mod, game, M, S, roll, play = C.mod, C.game, C.M, C.S, C.roll, C.play
	local enemy, player0, safe, rng, T, fireExtra = C.enemy, C.player0, C.safe, C.rng, C.T, C.fireExtra

	S.lnf = S.lnf or {}
	local F = S.lnf
	local later = {}
	local ALL = CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY | CacheFlag.CACHE_SPEED | CacheFlag.CACHE_LUCK
	local function now() return game:GetFrameCount() end
	local function after(n, fn) later[#later + 1] = { now() + n, fn } end
	local function refresh(p) if p then p:AddCacheFlags(ALL, true) end end

	local function ok() return LNF and LNF.PlayerType and LNF.Data end
	local function ptype(p, name) return ok() and p and LNF.PlayerType[name] and p:GetPlayerType() == LNF.PlayerType[name] end
	local function isRobot(p) return ptype(p, "Robot") end
	local function isRobotB(p) return ptype(p, "TaintedRobot") end
	local function isJoseph(p) return ptype(p, "Joseph") end
	local function isJosephB(p) return ptype(p, "TaintedJoseph") end
	local function ld() return ok() and LNF.Data() or {} end
	local function pd(p)
		if not (ok() and p and p.GetLNFData) then return {} end
		local okk, d = pcall(LNF.GetPlayerData, p)
		return okk and d or {}
	end
	local function edata(e)
		if not (e and e.GetLNFData) then return nil end
		local okk, d = pcall(e.GetLNFData, e)
		return okk and d or nil
	end
	local function item(name) return ok() and LNF.CollectibleType and LNF.CollectibleType[name] end
	local function roomEnemies()
		local t = {}
		for _, e in ipairs(Isaac.GetRoomEntities()) do if enemy(e) then t[#t + 1] = e end end
		return t
	end
	-- деление активному предмету мода (основной слот или карманный)
	local function addCharge(p, id, n)
		if not id then return false end
		for _, s in ipairs({ ActiveSlot.SLOT_PRIMARY, ActiveSlot.SLOT_POCKET }) do
			if p:GetActiveItem(s) == id then
				local cfg = Isaac.GetItemConfig():GetCollectible(id)
				local maxc = cfg and cfg.MaxCharges or 8
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

	-- -------------------------------------------------------------------- Робот: модули
	local function sockets(p)
		local d = pd(p)
		local n, open = 0, 0
		for _, sl in ipairs(d.Modules or {}) do
			if not sl.locked then
				open = open + 1
				if sl.mod ~= nil then n = n + 1 end
			end
		end
		return n, open
	end
	local function runModules(p)
		local d = pd(p)
		for _, sl in ipairs(d.Modules or {}) do
			if sl.mod ~= nil and not sl.locked and LNF.Modules[sl.mod] then
				pcall(LNF.Modules[sl.mod].func, LNF.Modules[sl.mod], p, sl.subtype)
			end
		end
		p:AddCacheFlags(CacheFlag.CACHE_ALL)
		p:EvaluateItems()
	end
	local SIMPLE = { 1, 2, 3, 6, 7, 8, 9 }   -- модули без предмета (урон, скорострельность, подвижность, щит, бомба, грусть, копия)
	local function spawnModule(pos)
		local pv = LNF.PickupVariant and LNF.PickupVariant.PICKUP_MODULE
		if not pv then return end
		Isaac.Spawn(EntityType.ENTITY_PICKUP, pv, SIMPLE[rng:RandomInt(#SIMPLE) + 1], game:GetRoom():FindFreePickupSpawnPosition(pos, 40, true),
			Vector.Zero, nil)
	end
	local function snapModules(p)
		local t = {}
		for i, sl in ipairs(pd(p).Modules or {}) do t[i] = sl.mod and { sl.mod, sl.subtype } or false end
		return t
	end

	-- -------------------------------------------------------------------- Порченый Робот: лом
	local function scrap() return ld().Scrap or 0 end
	local function addScrap(n)
		local d = ld()
		d.Scrap = math.max(0, (d.Scrap or 0) + n)
		F.rtScrap = d.Scrap   -- свои изменения — не «подобрал» и не «купил»
	end
	local function spawnScrap(pos, n)
		local pv = LNF.PickupVariant and LNF.PickupVariant.PICKUP_SCRAP
		if not pv then return end
		for _ = 1, n or 1 do
			Isaac.Spawn(EntityType.ENTITY_PICKUP, pv, 0, pos, Vector.FromAngle(rng:RandomInt(360)) * (1 + rng:RandomInt(3)), nil)
		end
	end

	-- -------------------------------------------------------------------- Джозеф: сон
	local function dreaming() return ld().Dream == true end
	local function dreamy(e) local d = edata(e) return d and (d.Dreamy or 0) > 0.05 end
	local function startDream()
		local d = ld()
		d.Dream, d.RoomDream = true, true
		d.MoonRockStats = d.MoonRockStats or { 0, 0, 0, 0 }
		for _, en in ipairs(roomEnemies()) do
			local npc = en:ToNPC()
			-- как «Лунный камень» (items/moonrock.lua): у Entity CanShutDoors — метод, у EntityNPC — поле
			local okc, shut = pcall(en.CanShutDoors, en)
			if not okc then shut = npc and npc.CanShutDoors end
			if npc and en.Parent == nil and en.HitPoints >= en.MaxHitPoints * 0.7 and not npc:IsChampion() and shut
				and not en:IsBoss() and Lost and Lost.AddDream then
				pcall(Lost.AddDream, en)
			end
		end
		for i = 0, game:GetNumPlayers() - 1 do
			local q = Isaac.GetPlayer(i)
			q:AddCacheFlags(CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY | CacheFlag.CACHE_SPEED | CacheFlag.CACHE_RANGE, true)
		end
		play("SOUND_ROCK_CRUMBLE", 0.6, 1.3)
	end

	-- -------------------------------------------------------------------- Порченый Джозеф: кошмары
	local function isNightmare(e) return e and e.Type == 297 and e.Variant == 484 end
	local function nightmares()
		local n = 0
		for _, e in ipairs(Isaac.FindByType(297, 484, -1, false, false)) do if not e:IsDead() then n = n + 1 end end
		return n
	end

	-- ==================================================================== крючки
	function H.dmgMult(ent, p, se, amount, flags)
		local mult = 1
		if isJoseph(p) and M("lfJoWalk") > 0 and dreamy(ent) then mult = mult * (1 + M("lfJoWalk") / 100) end   -- «Лунатик»
		return mult
	end

	function H.onHurt(p, amount, flags, src)
		if flags & DamageFlag.DAMAGE_FAKE ~= 0 then return end
		if isRobot(p) then F.rbHurtAt = now() end
		if isRobotB(p) then
			if M("lfRtArmor") > 0 and not F.rtArmorRoom and scrap() >= 5 then                                 -- «Броня из лома»
				F.rtArmorRoom = true
				addScrap(-5)
				p:SetMinDamageCooldown(30)
				play("SOUND_METAL_BLOCKBREAK", 0.6, 1.1)
				return false
			end
			if scrap() >= 10 and roll(M("lfRtPlate")) then                                                     -- «Обшивка»
				p:SetMinDamageCooldown(30)
				play("SOUND_METAL_BLOCKBREAK", 0.4, 1.4)
				return false
			end
		end
		if isJoseph(p) and dreaming() then
			if M("lfJoPillow") > 0 and not F.joPillowRoom then                                               -- «Подушка»
				F.joPillowRoom = true
				p:SetMinDamageCooldown(30)
				play("SOUND_HOLY_MANTLE", 0.4, 1.3)
				return false
			end
			if roll(M("lfJoLight")) then                                                                      -- «Чуткий сон»
				local d = ld()
				local keep = {}
				for _, en in ipairs(roomEnemies()) do if dreamy(en) then keep[#keep + 1] = en end end
				local st = { RoomDream = d.RoomDream, DreamActive = d.DreamActive, DreamTime = d.DreamTime }
				after(1, function()
					local d2 = ld()
					d2.RoomDream, d2.DreamActive, d2.DreamTime, d2.Dream = st.RoomDream, st.DreamActive, st.DreamTime, true
					for _, en in ipairs(keep) do
						local ed = edata(en)
						if ed and en:Exists() then ed.Dreamy = 1 end
					end
					refresh(p)
				end)
			end
		end
	end

	function H.cache(p, flag)
		local dmg, tears, luck, speed = 0, 0, 0, 0
		if isRobot(p) then
			local n, open = sockets(p)
			dmg = dmg + M("lfRbSocket") * n                                                                    -- «Шестерёнки»
			tears = tears + M("lfRbCool") * n                                                                  -- «Охлаждение»
			if M("lfRbMain") > 0 then                                                                         -- «Мейнфрейм»
				if open > 0 and n >= open then dmg = dmg + 20 end
				speed = speed - 0.1
			end
			if M("lfRbDouble") > 0 then tears = tears - 5 end
			if M("lfRbArmor") > 0 then dmg = dmg - 5 end
			if M("lfRbSpare") > 0 then speed = speed - 0.1 end
			if M("lfRbLine") > 0 then tears = tears - 5 end
		end
		if isRobotB(p) then
			local k = math.min(6, math.floor(scrap() / 5))
			dmg = dmg + M("lfRtScrap") * k                                                                     -- «Металлолом»
			tears = tears + M("lfRtOil") * k                                                                   -- «Смазка»
			if M("lfRtOvertime") > 0 then                                                                     -- «Сверхурочные»
				dmg = dmg + 10 * (F.rtOver or 0)
				speed = speed - 0.1
			end
			if M("lfRtBargain") > 0 then dmg = dmg - 5 end
			if M("lfRtArmor") > 0 then tears = tears - 5 end
			if M("lfRtDelivery") > 0 then dmg = dmg - 5 end
			if M("lfRtShrapnel") > 0 then tears = tears - 5 end
		end
		if isJoseph(p) then
			if not dreaming() then tears = tears + M("lfJoAwake") end                                      -- «Бессонница»
			if M("lfJoDay") > 0 then dmg = dmg - 5 end
			if M("lfJoTerror") > 0 then tears = tears - 5 end
			if M("lfJoSweet") > 0 then speed = speed - 0.1 end
			if M("lfJoCatch") > 0 then dmg = dmg - 5 end
			if M("lfJoPillow") > 0 then tears = tears - 5 end
		end
		if isJosephB(p) then
			dmg = dmg + M("lfJtOwl") * math.min(5, nightmares())                                             -- «Сова»
			if M("lfJtFury") > 0 then                                                                         -- «Ночная ярость»
				dmg = dmg + 3 * (F.jtFury or 0)
				tears = tears - 5
			end
			if M("lfJtFear") > 0 then dmg = dmg - 5 end
			if M("lfJtCall") > 0 then speed = speed - 0.1 end
			if M("lfJtFuel") > 0 then dmg = dmg - 5 end
			if M("lfJtLull") > 0 then tears = tears - 5 end
		end
		return dmg, tears, luck, speed
	end

	function H.onKill(npc, p, pos)
		if isRobotB(p) and roll(M("lfRtSalvage")) then spawnScrap(pos, 1) end                                -- «Старьёвщик»
		if isJoseph(p) and dreamy(npc) then
			if M("lfJoTerror") > 0 then                                                                       -- «Ночной ужас»
				for _, en in ipairs(Isaac.FindInRadius(pos, 90, EntityPartition.ENEMY)) do
					if enemy(en) and GetPtrHash(en) ~= GetPtrHash(npc) then en:TakeDamage(p.Damage * 2, DamageFlag.DAMAGE_EXPLOSION, EntityRef(p), 0) end
				end
				local fx = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF02, 1, pos, Vector.Zero, nil)
				fx.Color = Color(1, 0.6, 1, 1, 0.4, 0.2, 0.4)
				play("SOUND_DEMON_HIT", 0.5, 1.3)
			end
			if M("lfJoSweet") > 0 and roll(10) then                                                           -- «Сладкие сны»
				Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, HeartSubType.HEART_HALF_SOUL, pos, RandomVector() * 2, p)
			end
		end
	end

	function H.onRoom()
		F.rtArmorRoom, F.joPillowRoom = nil, nil
		local p = player0()
		if not p then return end
		if isJosephB(p) and F.jtFury and F.jtFury > 0 then F.jtFury = 0 refresh(p) end
		if isJoseph(p) and M("lfJoDay") > 0 and not game:GetRoom():IsClear() and roll(20) then             -- «Грёзы наяву»
			after(8, function() if not game:GetRoom():IsClear() then startDream() end end)
		end
	end

	function H.onClear(p)
		if isRobot(p) then
			if roll(M("lfRbCharge")) then addCharge(p, item("ROBOTS_BATTERY"), 1) end                         -- «Подзарядка»
			if roll(M("lfRbRecycle")) then spawnModule(p.Position) end                                       -- «Переработка»
			if M("lfRbSpare") > 0 then                                                                        -- «Запчасти»
				F.rbRooms = (F.rbRooms or 0) + 1
				if F.rbRooms % 4 == 0 then spawnModule(game:GetRoom():GetCenterPos()) end
			end
		end
		if isJoseph(p) and roll(M("lfJoMoon")) then addCharge(p, item("MOON_ROCK"), 1) end                  -- «Лунный свет»
		if isJosephB(p) then
			F.jtClearAt = now()
			if M("lfJtFuel") > 0 then addCharge(p, item("NIGHTMARE_FUEL"), 1) end                             -- «Запас топлива»
		end
	end

	function H.onLevel(p)
		F.rtOver, F.jtLullFloor = 0, nil
		if isRobotB(p) and M("lfRtDelivery") > 0 then                                                      -- «Доставка»
			after(2, function() addScrap(5) play("SOUND_SCAMPER", 0.6) end)
		end
		refresh(p)
	end

	function H.onStart(cont)
		later = {}
		F.rbPrev, F.rbHurtAt, F.rbArmorRoom, F.rtScrap, F.rtOver, F.rtArmorRoom = nil, nil, nil, nil, 0, nil
		F.joStats, F.joPillowRoom, F.jtBroken, F.jtInt, F.jtClearAt, F.jtFury, F.jtLullFloor = nil, nil, nil, nil, nil, 0, nil
		F.rbSig, F.rtSig, F.joSig, F.jtSig = nil, nil, nil, nil
		if not cont then F.rbRooms = 0 end
	end

	-- ==================================================================== свои обработчики
	mod:AddCallback(ModCallbacks.MC_POST_UPDATE, safe("lnfLater", function()
		if #later == 0 then return end
		local t, keep = now(), {}
		for _, j in ipairs(later) do
			if t >= j[1] then pcall(j[2]) else keep[#keep + 1] = j end
		end
		later = keep
	end))

	-- Робот: «Разгон» — батарейка запускает модули ещё раз; Джозеф: «Ловец снов» — кольцо слёз от Лунного камня
	mod:AddCallback(ModCallbacks.MC_USE_ITEM, safe("lnfUse", function(_, it, _, p)
		if not (ok() and p) then return end
		if it == item("ROBOTS_BATTERY") and isRobot(p) and M("lfRbDouble") > 0 then
			after(1, function() runModules(p) end)
		end
		if it == item("MOON_ROCK") and isJoseph(p) and M("lfJoCatch") > 0 then
			for i = 0, 7 do fireExtra(p, p.Position, Vector(10, 0):Rotated(i * 45), 1) end
			play("SOUND_TEARS_FIRE", 0.6, 0.8)
		end
	end))

	-- Порченый Робот: «Умелец» — разбор предмета в Мастерской даёт больше лома
	mod:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, safe("lnfPreUse", function(_, it, _, p)
		if not (ok() and p and it == item("WORKSHOP") and isRobotB(p) and M("lfRtTinker") > 0) then return end
		local q = p.QueuedItem and p.QueuedItem.Item
		if q and q:IsCollectible() then
			local base = 2.5 * math.ceil(q.Quality / 2 + 1)
			local extra = base * M("lfRtTinker") / 100
			local n = math.floor(extra) + (rng:RandomFloat() < extra % 1 and 1 or 0)
			if n > 0 then
				local pos = p.Position
				after(1, function() spawnScrap(pos, n) end)
			end
		end
	end))

	-- Робот: «Конвейер» — модуль при занятых гнёздах сразу срабатывает
	local function modulePickup(_, pk, coll)
		local p = coll and coll:ToPlayer()
		if not (p and isRobot(p) and M("lfRbLine") > 0 and pk.Price == 0) then return end
		if LNF.CanAddModule and LNF.CanAddModule(nil, p) then return end
		local id, sub = pk.SubType, nil
		if id > 10000 then id, sub = math.floor(pk.SubType / 10000), pk.SubType % 10000 end
		local m = LNF.Modules and LNF.Modules[id]
		if not m then return end
		pcall(m.func, m, p, sub)
		p:AddCacheFlags(CacheFlag.CACHE_ALL)
		p:EvaluateItems()
		pk:Remove()
		play("SOUND_BATTERYCHARGE", 0.6, 1.2)
		return true
	end
	-- раньше обработчика LNF (callbacks.lua: он возвращает значение — дальше колбэки не идут)
	mod:AddPriorityCallback(ModCallbacks.MC_PRE_PICKUP_COLLISION, CallbackPriority.IMPORTANT, safe("lnfModule", function(_, pk, coll, low)
		local pv = ok() and LNF.PickupVariant and LNF.PickupVariant.PICKUP_MODULE
		if pv and pk.Variant == pv then return modulePickup(_, pk, coll) end
	end))

	-- Джозеф: «Осознанный сон» — после формулы Джозефа (joseph.lua OnCache, приоритет LATE режет прибавки урона вдвое)
	mod:AddPriorityCallback(ModCallbacks.MC_EVALUATE_CACHE, CallbackPriority.LATE + 100, safe("lnfLucid", function(_, p)
		if isJoseph(p) and M("lfJoLucid") > 0 and dreaming() then p.Damage = p.Damage * (1 + M("lfJoLucid") / 100) end
	end), CacheFlag.CACHE_DAMAGE)

	-- Порченый Джозеф: сила, радиус и скорость кошмара — один раз после появления
	mod:AddCallback(ModCallbacks.MC_NPC_UPDATE, safe("lnfNightmare", function(_, npc)
		if npc.Variant ~= 484 then return end
		local d = edata(npc)
		if not (d and d.Stats and not d.lfStat) then return end
		d.lfStat = true
		local st = d.Stats
		if M("lfJtBoom") > 0 and st[1] then st[1] = st[1] * (1 + M("lfJtBoom") / 100) end                      -- «Топливо кошмаров»
		if M("lfJtWave") > 0 and st[4] then st[4] = st[4] * (1 + M("lfJtWave") / 100) end                      -- «Ударная волна»
		if M("lfJtSlow") > 0 and st[3] then st[3] = st[3] * (1 - M("lfJtSlow") / 100) end                      -- «Тяжёлые веки»
	end), 297)

	-- Порченый Джозеф: «Жуть» и «Ночная ярость» — смерть кошмара
	mod:AddCallback(ModCallbacks.MC_POST_ENTITY_KILL, safe("lnfNightmareKill", function(_, e)
		if not isNightmare(e) then return end
		local p = player0()
		if not (p and isJosephB(p)) then return end
		if game:GetRoom():IsClear() then return end
		local d = edata(e)
		if M("lfJtFear") > 0 then
			local r = (d and d.Stats and d.Stats[4] or 100) * 0.45
			for _, en in ipairs(Isaac.FindInRadius(e.Position, r, EntityPartition.ENEMY)) do
				if enemy(en) and not isNightmare(en) then en:AddFear(EntityRef(p), 60) end
			end
		end
		if M("lfJtFury") > 0 and (F.jtFury or 0) < 10 then
			F.jtFury = (F.jtFury or 0) + 1
			refresh(p)
		end
	end), 297)

	-- кадр игрока: модули, лом, сон, пробуждение
	mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("lnfFrame", function(_, p)
		if not ok() or p.Index ~= player0().Index then return end
		if isRobot(p) then
			local d = pd(p)
			if M("lfRbHold") > 0 and d.Modules then                                                           -- «Конденсатор»
				local k = M("lfRbHold") / 100
				if (d.ModulesDamage or 0) > 0 then d.ModulesDamage = d.ModulesDamage + 0.001 * k end
				if (d.ModulesFirerate or 0) > 0 then d.ModulesFirerate = d.ModulesFirerate + 0.0007 * k end
				if (d.ModulesMobility or 0) > 0 then d.ModulesMobility = d.ModulesMobility + 0.001 * k end
			end
			-- сломанный ударом модуль: «Прочный корпус» возвращает, «Броня из обломков» даёт щит
			local cur = snapModules(p)
			if F.rbPrev and F.rbHurtAt and now() - F.rbHurtAt <= 3 then
				local lost = {}
				for i, v in pairs(F.rbPrev) do if v and not cur[i] then lost[#lost + 1] = i end end
				if #lost > 0 then
					if roll(M("lfRbKeep")) then
						local i = lost[rng:RandomInt(#lost) + 1]
						local sl = d.Modules[i]
						if sl and sl.mod == nil then
							sl.mod, sl.subtype = F.rbPrev[i][1], F.rbPrev[i][2]
							cur[i] = F.rbPrev[i]
							d.ModulesTransparency = 1
							play("SOUND_BATTERYCHARGE", 0.5, 1.4)
						end
					end
					if M("lfRbArmor") > 0 and F.rbArmorRoom ~= game:GetLevel():GetCurrentRoomIndex() then
						F.rbArmorRoom = game:GetLevel():GetCurrentRoomIndex()
						p:GetEffects():AddCollectibleEffect(CollectibleType.COLLECTIBLE_HOLY_MANTLE, true)
						play("SOUND_HOLY_MANTLE", 0.5)
					end
				end
			end
			F.rbPrev = cur
			local n = sockets(p)
			if n ~= F.rbSig then F.rbSig = n refresh(p) end
		end
		if isRobotB(p) then
			local s = scrap()
			if F.rtScrap and s > F.rtScrap then                                                               -- подобран лом
				for _ = 1, s - F.rtScrap do
					if roll(M("lfRtSort")) then addScrap(1) end                                                -- «Сортировка»
					if M("lfRtShrapnel") > 0 then                                                             -- «Шрапнель»
						for i = 0, 3 do
							local t = fireExtra(p, p.Position, Vector(9, 0):Rotated(i * 90 + 45), 0.6)
							if t then t:ChangeVariant(TearVariant.METALLIC) end
						end
					end
				end
				s = scrap()
			elseif F.rtScrap and s < F.rtScrap and M("lfRtOvertime") > 0 and (F.rtOver or 0) < 5 then       -- покупка
				F.rtOver = (F.rtOver or 0) + 1
				play("SOUND_POWERUP1", 0.5, 1.2)
				refresh(p)
			end
			F.rtScrap = s
			if M("lfRtBargain") > 0 then                                                                      -- «Сделка»
				for _, col in pairs(pd(p).Tiles or {}) do
					if type(col) == "table" then
						for _, tile in pairs(col) do
							if type(tile) == "table" and tile.price and not tile.bought and not tile.lfBargain then
								tile.price = math.max(1, tile.price - 1)
								tile.lfBargain = true
							end
						end
					end
				end
			end
			local sig = math.floor(s / 5)
			if sig ~= F.rtSig then F.rtSig = sig refresh(p) end
		end
		if isJoseph(p) then
			local d = ld()
			local st = d.MoonRockStats
			if st and M("lfJoDeep") > 0 then                                                                  -- «Глубокий сон»
				if F.joStats then
					local grew = false
					for i = 1, 4 do
						local inc = (st[i] or 0) - (F.joStats[i] or 0)
						if inc > 0 then st[i] = st[i] + inc * M("lfJoDeep") / 100 grew = true end
					end
					if grew then refresh(p) end
				end
				F.joStats = { st[1], st[2], st[3], st[4] }
			end
			local sig = dreaming()
			if sig ~= F.joSig then F.joSig = sig refresh(p) end
		end
		if isJosephB(p) then
			local b = (p:GetBrokenHearts() or 0)
			if F.jtBroken and b >= F.jtBroken + 2 then                                                        -- пробуждение (кошмар коснулся)
				local added = b - F.jtBroken
				if M("lfJtLull") > 0 and not F.jtLullFloor then                                                -- «Колыбельная»
					F.jtLullFloor = true
					p:AddBrokenHearts(-added)
					play("SOUND_MEAT_JUMPS", 0.4, 1.5)
				elseif roll(M("lfJtRude")) then                                                                -- «Резкое пробуждение»
					p:AddBrokenHearts(-1)
				end
				if M("lfJtCall") > 0 then p:AddSoulHearts(2) play("SOUND_HOLY", 0.5, 1.2) end                -- «Будильник»
				b = (p:GetBrokenHearts() or 0)
			end
			F.jtBroken = b
			local d = ld()
			local int = d.NightmareIntensity or 0
			if F.jtInt and int > F.jtInt and F.jtClearAt and now() - F.jtClearAt <= 3 and roll(M("lfJtCalm")) then   -- «Спокойная ночь»
				d.NightmareIntensity = F.jtInt
				int = F.jtInt
			end
			F.jtInt = int
			local sig = math.min(5, nightmares())
			if M("lfJtOwl") > 0 and sig ~= F.jtSig then F.jtSig = sig refresh(p) end
		end
	end))

	T.LNF = V
	V.S = F
	V.H = H        -- для автотеста
	return V
end

return V
