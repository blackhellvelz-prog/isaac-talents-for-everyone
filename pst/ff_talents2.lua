-- localfixes/pst/ff_talents2.lua — механики деревьев PST оставшихся персонажей Fiend Folio (18.10, слова пользователя:
-- «Таланты персонажам модов тебе тоже надо будет сделать если не сделал»): Порченый Изверг (BIEND), Порченый Голем
-- (BOLEM), Порченый Френд (BRIEND), Имидж (IMAGE), Скелетный Изверг (SKELETAL_FIEND), ключевые таланты Порченой Инабы
-- (BINABA; остальное — механики Инабы из pst_talents.lua). Всё — через данные и функции самого FF
-- (ffscripts/players/biend.lua, bolem.lua, briend.lua + briend_bounty, skeletalfiend.lua,
-- taiga/challenges/babySensory.lua, inaba.lua). Деревья — tools/pst_talents_spec.py; источники —
-- docs/sources/pst_ff2.md. Подключение — pst_talents.lua (крючки, как у pst/vanilla_talents.lua).
local V = {}

function V.init(C, H)
	local mod, game, M, S, roll, play = C.mod, C.game, C.M, C.S, C.roll, C.play
	local enemy, player0, safe, rng, T = C.enemy, C.player0, C.safe, C.rng, C.T
	local FF, ffData, darkHearts = C.FF, C.ffData, C.darkHearts

	S.f2 = S.f2 or {}
	local F = S.f2                       -- состояние модуля (комната/этаж — сбрасывается в крючках)
	local later = {}
	local ALL = CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY | CacheFlag.CACHE_SPEED | CacheFlag.CACHE_LUCK
	local function now() return game:GetFrameCount() end
	local function after(n, fn) later[#later + 1] = { now() + n, fn } end
	local function refresh(p) if p then p:AddCacheFlags(ALL, true) end end
	local function same(a, b) return a and b and GetPtrHash(a) == GetPtrHash(b) end
	local function ptype(p, name) return FF() and FF().PLAYER and FF().PLAYER[name] and p:GetPlayerType() == FF().PLAYER[name] end
	local function isBiend(p) return ptype(p, "BIEND") end
	local function isBolem(p) return ptype(p, "BOLEM") end
	local function isBriend(p) return ptype(p, "BRIEND") end
	local function isImage(p) return ptype(p, "IMAGE") end
	local function isSkel(p) return ptype(p, "SKELETAL_FIEND") end
	local function isBinaba(p) return ptype(p, "BINABA") end
	local function nearby(pos, r, skip)
		local t = {}
		for _, e in ipairs(Isaac.FindInRadius(pos, r, EntityPartition.ENEMY)) do
			if enemy(e) and not same(e, skip) then t[#t + 1] = e end
		end
		return t
	end
	local function roomEnemies()
		local t = {}
		for _, e in ipairs(Isaac.GetRoomEntities()) do if enemy(e) then t[#t + 1] = e end end
		return t
	end
	local function freePos(off)
		local room = game:GetRoom()
		return room:FindFreePickupSpawnPosition(room:GetCenterPos() + (off or Vector.Zero), 0, true)
	end

	-- -------------------------------------------------------------------- Порченый Изверг: «Злоба»
	local function bData(p) return ffData(p) end
	local function dashing(p) local d = bData(p) return d and d.MaliceDashing end
	local function split(p) local d = bData(p) return d and d.MaliceSplit end

	-- -------------------------------------------------------------------- Порченый Голем: камни
	local ROCKSET
	local function rockSet()
		if ROCKSET then return ROCKSET end
		ROCKSET = {}
		local ff = FF()
		for _, id in pairs(ff and ff.ITEM and ff.ITEM.ROCK or {}) do
			if type(id) == "number" then ROCKSET[id] = true end
		end
		return ROCKSET
	end
	local function rocksHeld(p)
		local n, set = 0, rockSet()
		for slot = 0, 1 do
			local t = p:GetTrinket(slot)
			if t and t > 0 and set[t & ~TrinketType.TRINKET_GOLDEN_FLAG] then n = n + 1 end
		end
		local ok, sm = pcall(p.GetSmeltedTrinkets, p)
		if ok and type(sm) == "table" then
			for id in pairs(set) do
				local e = sm[id]
				if e then n = n + (e.trinketAmount or 0) + (e.goldenTrinketAmount or 0) end
			end
		end
		return math.min(6, n)
	end

	-- -------------------------------------------------------------------- Имидж: вплавленные брелоки
	local function smeltedCount(p)
		local ok, sm = pcall(p.GetSmeltedTrinkets, p)
		if not ok or type(sm) ~= "table" then return 0 end
		local n = 0
		for _, e in pairs(sm) do
			if type(e) == "table" then n = n + (e.trinketAmount or 0) + (e.goldenTrinketAmount or 0) end
		end
		return n
	end

	-- ==================================================================== крючки
	function H.dmgMult(ent, p, se, amount, flags)
		local mult, ed, f = 1, ent:GetData(), now()
		if isBiend(p) then
			if M("lfBfDash") > 0 and dashing(p) then mult = mult * (1 + M("lfBfDash") / 100) end          -- «Злоба»
			if M("lfBfTar") > 0 then                                                                         -- «Липкая смола»
				for _, c in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.PLAYER_CREEP_BLACK)) do
					if same(c.SpawnerEntity, p) and c.Position:Distance(ent.Position) <= 30 + ent.Size then
						mult = mult * (1 + M("lfBfTar") / 100)
						break
					end
				end
			end
		end
		if isBriend(p) then
			local ed2 = ffData(ent)
			if M("lfBrBounty") > 0 and ed2 and ed2.GunslingerData then mult = mult * (1 + M("lfBrBounty") / 100) end
			if M("lfBrDuel") > 0 and not F.brDuelUsed and ent:ToNPC() then                                  -- «Дуэль»
				F.brDuelUsed = true
				mult = mult * 3
				play("SOUND_BULLET_SHOT", 0.5, 0.8)
			end
		end
		if isImage(p) and M("lfImPets") > 0 and se and (se:ToFamiliar() or (se.SpawnerEntity and se.SpawnerEntity:ToFamiliar())) then
			mult = mult * (1 + M("lfImPets") / 100)                                                            -- «Друзья-питомцы»
		end
		if isSkel(p) and se and se.Type == EntityType.ENTITY_FAMILIAR and se.Variant == FamiliarVariant.BONE_ORBITAL
			and M("lfSfMarrow") > 0 then
			mult = mult * 2                                                                                   -- «Мозг костей»
		end
		return mult
	end

	function H.onKill(npc, p, pos)
		local ff = FF()
		if isBiend(p) and dashing(p) and roll(M("lfBfDashHeart")) and ff and ff.PICKUP and ff.PICKUP.VARIANT.HALF_BLACK_HEART then
			Isaac.Spawn(EntityType.ENTITY_PICKUP, ff.PICKUP.VARIANT.HALF_BLACK_HEART, 0, pos, Vector.Zero, p)   -- «Смоляное сердце»
		end
		if isBriend(p) and roll(M("lfBrCharge")) then                                                          -- «Пороховой запас»
			pcall(p.AddActiveCharge, p, 10, ActiveSlot.SLOT_POCKET, true, false, true)
		end
		if isSkel(p) and roll(M("lfSfBones")) then                                                             -- «Костяная свита»
			local b = Isaac.Spawn(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BONE_ORBITAL, 0, p.Position, Vector.Zero, p):ToFamiliar()
			if b then b.Parent = p b.Player = p end
		end
	end

	function H.onHurt(p, amount, flags, src)
		local room = game:GetRoom()
		if isBolem(p) and M("lfBgAvalanche") > 0 and not room:IsClear() then                                -- «Обвал»
			game:ShakeScreen(10)
			play("SOUND_ROCK_CRUMBLE", 0.9)
			for i = 1, 5 do game:SpawnParticles(p.Position + RandomVector() * 60, EffectVariant.ROCK_PARTICLE, 4, 4) end
			for _, en in ipairs(nearby(p.Position, 120)) do en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
		end
		if isImage(p) and M("lfImScream") > 0 and not room:IsClear() then                                   -- «Крик»
			for _, en in ipairs(roomEnemies()) do en:AddSlowing(EntityRef(p), 90, 0.5, Color(0.7, 0.7, 1, 1, 0, 0, 0.1)) end
			play("SOUND_SCAMPER", 0.6, 1.4)
		end
	end

	function H.cache(p, flag)
		local dmg, tears, luck, speed = 0, 0, 0, 0
		local d = ffData(p)
		if isBiend(p) then
			if split(p) then dmg = dmg + M("lfBfSplit") end                                                 -- «Раскол»
			if M("lfBfBounce") > 0 then dmg = dmg - 5 end
			if M("lfBfHollow") > 0 then tears = tears - 10 end
			if M("lfBfReform") > 0 then
				speed = speed - 0.1
				if F.bfReformRoom then dmg = dmg + 20 end
			end
		end
		if isBolem(p) then
			dmg = dmg + M("lfBgPebbleDmg") * rocksHeld(p)                                                     -- «Груда камней»
			if M("lfBgOverdrive") > 0 then
				speed = speed - 0.1
				if d and (d.OverclockTime or 0) > 0 then tears = tears + 25 end                             -- «Перегрев»
			end
			if M("lfBgAvalanche") > 0 then dmg = dmg - 5 end
		end
		if isBriend(p) then
			local ff = FF()
			local rev = ff and ff.IsPrimaryGunRevolver and ff:IsPrimaryGunRevolver(p)
			if rev then tears = tears + M("lfBrRevolver") else dmg = dmg + M("lfBrDeagle") end              -- стволы
			if M("lfBrCool") > 0 then dmg = dmg - 5 end
			if M("lfBrDuel") > 0 then tears = tears - 5 end
		end
		if isImage(p) then
			dmg = dmg + M("lfImOverload") * math.min(10, smeltedCount(p))                                 -- «Перегрузка»
			tears = tears + M("lfImHunger") * math.min(5, F.imFloorItems or 0)                             -- «Сенсорный голод»
			if M("lfImMelt") > 0 then dmg = dmg - 5 end
			if M("lfImScream") > 0 then tears = tears - 5 end
		end
		if isSkel(p) then
			if M("lfSfRiff") > 0 then tears = tears - 5 end
			if M("lfSfMarrow") > 0 then dmg = dmg - 5 end
		end
		if isBinaba(p) then
			if M("lfBiEyeStay") > 0 and F.biEyeStill then dmg = dmg + 20 end            -- «Неподвижный глаз»
			if M("lfBiEyeStay") > 0 then tears = tears - 5 end
		end
		return dmg, tears, luck, speed
	end

	function H.onRoom()
		F.brDuelUsed = false
		F.sfRiffAt = now() + 300
		if F.bfReformRoom then
			F.bfReformRoom = nil
			refresh(player0())
		end
	end

	function H.onClear(p)
		local ff = FF()
		if isBolem(p) and roll(M("lfBgPebble")) and ff and ff.BolemsPebbles then                           -- «Галька»
			local list = ff.BolemsPebbles
			Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_TRINKET, list[rng:RandomInt(#list) + 1], freePos(Vector(0, 40)), Vector.Zero, nil)
		end
		if isBriend(p) and M("lfBrCool") > 0 and roll(25) and ff and ff.SetBountyHeat and ff.savedata and ff.savedata.run then   -- «Залечь на дно»
			local h = ff.savedata.run.briendHeat or 0
			if h > 0 then ff:SetBountyHeat(h - 1) end
		end
	end

	function H.onLevel(p)
		F.imFloorItems = 0
		if isBolem(p) and M("lfBgSteady") > 0 then                                                           -- «Крепкая хватка»
			after(2, function()
				local sd = ffData(p) and ffData(p).ffsavedata
				if sd and sd.RockDropChance then sd.RockDropChance = sd.RockDropChance * math.max(0, 1 - M("lfBgSteady") / 100) end
			end)
		end
		if isImage(p) and M("lfImMelt") > 0 then                                                            -- «Расплавить всё»
			local t = p:GetTrinket(0)
			if t and t > 0 then
				p:TryRemoveTrinket(t)
				pcall(p.AddSmeltedTrinket, p, t)
				play("SOUND_VAMP_GULP", 0.6)
			end
		end
		refresh(p)
	end

	function H.onStart(cont)
		later = {}
		F.bfSeenDash, F.bfMinions, F.bfReforming, F.bfReformRoom = nil, nil, nil, nil
		F.imItems, F.imFloorItems, F.biEyeStill = nil, 0, nil
	end

	-- ==================================================================== свои обработчики
	mod:AddCallback(ModCallbacks.MC_POST_UPDATE, safe("f2Later", function()
		if #later == 0 then return end
		local f, keep = now(), {}
		for _, it in ipairs(later) do
			if it[1] <= f then pcall(it[2]) else keep[#keep + 1] = it end
		end
		later = keep
	end))

	-- использован предмет: «Разгон» (Порченый Голем), «Выдержка стрелка» (Порченый Френд), «Сок» (Скелетный Изверг)
	mod:AddCallback(ModCallbacks.MC_USE_ITEM, safe("f2Use", function(_, item, _, p)
		local ff = FF()
		if not (p and ff and ff.ITEM and ff.ITEM.COLLECTIBLE) then return end
		local C2 = ff.ITEM.COLLECTIBLE
		if item == C2.OVERCLOCK and isBolem(p) and M("lfBgOverclock") > 0 then                             -- «Долгий разгон»
			after(1, function()
				local d = ffData(p)
				if d and d.OverclockTime and d.OverclockTime > 0 then
					d.OverclockTime = d.OverclockTime + math.floor(600 * M("lfBgOverclock") / 100)
				end
				refresh(p)
			end)
		end
		if item == C2.GUNSLINGERS_GRIT and isBriend(p) and M("lfBrGrit") > 0 then                          -- «Выдержка»
			after(1, function()
				local add = math.floor(((ff.BriendBalancing and ff.BriendBalancing.BoostDuration) or 105) * M("lfBrGrit") / 100)
				for _, q in ipairs({ p, p.GetOtherTwin and p:GetOtherTwin() or nil }) do
					local d = q and ffData(q)
					if d and d.BriendGritBoost then d.BriendGritBoost = d.BriendGritBoost + add end
				end
			end)
		end
		if item == C2.BONE_HURTING_JUICE and isSkel(p) and M("lfSfJuice") > 0 then                       -- «Крепкий сок»
			after(1, function()
				local sd = ffData(p) and ffData(p).ffsavedata
				if sd and sd.skeltalFiendBuff then sd.skeltalFiendBuff = sd.skeltalFiendBuff * (1 + M("lfSfJuice") / 100) end
				refresh(p)
			end)
		end
	end))

	-- выроненный камень не разбивается («Подхватить», Порченый Голем)
	mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, safe("f2Catch", function(_, pk)
		if M("lfBgCatch") <= 0 or pk.Timeout <= 0 or pk.Wait <= 0 then return end
		local d = pk:GetData()
		if d.lfCatch then return end
		d.lfCatch = true
		local ff = FF()
		if ff and ff.ITEM and ff.ITEM.ROCK and pk.SubType == ff.ITEM.ROCK.FOOLS_UNOBTAINIUM then return end   -- выроненный предмет
		if rockSet()[pk.SubType & ~TrinketType.TRINKET_GOLDEN_FLAG] and roll(M("lfBgCatch")) then
			pk.Timeout = -1
			pk:SetColor(Color(1, 1, 1, 1, 0.3, 0.3, 0.3), 15, 1, true, false)
		end
	end), PickupVariant.PICKUP_TRINKET)

	-- кадр игрока: «Злоба» (рывок, раскол, сборка), огоньки Скелетного Изверга, «Гитарный рифф», предметы Имиджа
	mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("f2Frame", function(_, p)
		if not same(p, player0()) then return end
		local ff = FF()
		if not ff then return end
		local d = ffData(p)
		if isBiend(p) and d then
			-- рывок начался: «Рикошет» — отскок от стены (тем же способом, что карта «Три огненных шара» наоборот)
			if d.MaliceDashing and not F.bfSeenDash then
				F.bfSeenDash = true
				if M("lfBfBounce") > 0 and not d.Reverse3FireballsDash then
					d.Reverse3FireballsDash = true
					d.Reverse3FireballsDashCount = 1
				end
			elseif not d.MaliceDashing then
				F.bfSeenDash = nil
			end
			-- раскол: «Пустая оболочка» — ещё полый миньон; «Чёрная кровь» — гибель миньона
			local n = d.MaliceSplit and d.MaliceMinions and #d.MaliceMinions or nil
			if n and not F.bfMinions then
				if M("lfBfHollow") > 0 and ff.SpawnMaliceMinion and d.HollowMaliceMinions then
					d.HollowMaliceMinions[#d.HollowMaliceMinions + 1] = ff.SpawnMaliceMinion(p, p.Position, RandomVector() * 4, 1, true)
				end
				refresh(p)
			elseif n and F.bfMinions and n < F.bfMinions then
				for _ = 1, F.bfMinions - n do
					if roll(M("lfBfBlood")) then p:AddBlackHearts(1) play("SOUND_UNHOLY", 0.4, 1.4) end
				end
			end
			if (n == nil) ~= (F.bfMinions == nil) then refresh(p) end
			F.bfMinions = n
			-- сборка закончилась: «Сборка»
			if F.bfReforming and not d.MaliceReforming and not d.MaliceSplit and M("lfBfReform") > 0 then
				for i = 0, 7 do
					local t = Isaac.Spawn(EntityType.ENTITY_TEAR, TearVariant.BLOOD, 0, p.Position, Vector(9, 0):Rotated(i * 45), p):ToTear()
					if t then
						t.CollisionDamage = p.Damage
						t.Color = Color(0.1, 0.1, 0.1, 1, 0, 0, 0)
						t:GetData().lfTearFx = true
					end
				end
				F.bfReformRoom = true
				refresh(p)
			end
			F.bfReforming = d.MaliceReforming
		end
		-- Скелетный Изверг: огоньки следа жгут врагов («Огненный след»)
		if isSkel(p) and M("lfSfFire") > 0 and p.FrameCount % 3 == 0 then
			for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, 51)) do
				local ed = e:GetData()
				if not ed.lfSkFire and same(e.SpawnerEntity, p) then
					ed.lfSkFire = true
					e.CollisionDamage = p.Damage * M("lfSfFire") / 100
				end
			end
		end
		-- «Гитарный рифф»: раз в 10 секунд в комнате с врагами — волна
		if isSkel(p) and M("lfSfRiff") > 0 and not game:GetRoom():IsClear() and now() >= (F.sfRiffAt or 0) then
			F.sfRiffAt = now() + 300
			game:MakeShockwave(p.Position, 0.035, 0.025, 10)
			play("SOUND_FORESTBOSS_STOMPS", 0.5, 1.4)
			for _, en in ipairs(nearby(p.Position, 130)) do
				en:TakeDamage(p.Damage, 0, EntityRef(p), 0)
				en:AddVelocity((en.Position - p.Position):Resized(10))
			end
		end
		-- Имидж: предметы этого этажа («Сенсорный голод»)
		if isImage(p) then
			local c = p:GetCollectibleCount()
			if F.imItems and c > F.imItems then
				F.imFloorItems = (F.imFloorItems or 0) + (c - F.imItems)
				refresh(p)
			end
			F.imItems = c
			if M("lfImOverload") > 0 and p.FrameCount % 30 == 0 then
				local sc = smeltedCount(p)
				if sc ~= F.imSmelted then F.imSmelted = sc refresh(p) end
			end
		end
		-- Порченый Голем: «Груда камней» — число камней изменилось
		if isBolem(p) and p.FrameCount % 15 == 0 and (M("lfBgPebbleDmg") > 0 or M("lfBgOverdrive") > 0) then
			local sg = rocksHeld(p) .. "/" .. tostring(d and (d.OverclockTime or 0) > 0)
			if sg ~= F.bgSig then F.bgSig = sg refresh(p) end
		end
		-- Порченый Френд: сменился основной ствол
		if isBriend(p) and p.FrameCount % 10 == 0 and (M("lfBrRevolver") > 0 or M("lfBrDeagle") > 0) and ff.IsPrimaryGunRevolver then
			local rv = ff:IsPrimaryGunRevolver(p)
			if rv ~= F.brRev then F.brRev = rv refresh(p) refresh(p.GetOtherTwin and p:GetOtherTwin() or nil) end
		end
		-- Порченая Инаба: глаз на месте (зажата кнопка «бросить»)
		if isBinaba(p) and M("lfBiEyeStay") > 0 then
			local still = Input.IsActionPressed(ButtonAction.ACTION_DROP, p.ControllerIndex)
			if still ~= F.biEyeStill then F.biEyeStill = still refresh(p) end
		end
	end))

	T.F2 = V
	V.S = F
	return V
end

return V
