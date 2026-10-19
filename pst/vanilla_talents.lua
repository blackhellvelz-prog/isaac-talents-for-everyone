-- localfixes/pst/vanilla_talents.lua — механики веток талантов PST для 30 персонажей игры (18.10, слова пользователя:
-- «Ты сделай таланты все персонажам Айзека. Все которое выходили в игре»; «ВСЕМ ПЕРСОНАЖАМ ИГРЫ КОТОРЫЕ ВЫХОДИЛИ»).
-- Ветки и тексты — tools/pst_talents_spec.py (деревья «<персонаж>+»); источники — docs/sources/pst_vanilla2.md.
-- Модуль подключает pst_talents.lua: V.init(C, H) получает общие помощники C (M, S, roll, play, enemy, player0,
-- fireExtra, nearestEnemy, safe, game, mod, rng) и заполняет таблицу крючков H, которые зовут обработчики
-- pst_talents.lua (урон по врагу, убийство, удар по игроку, характеристики, выстрел, комната, зачистка, этаж,
-- начало забега). Свои обработчики (использование предмета и пилюли, подборы, кадр игрока) — здесь же.
-- Каждая механика читает M("lf…") — снимок дерева текущего забега, так что работает только у того персонажа, в
-- чьём дереве узел выделен.
local V = {}

function V.init(C, H)
	local mod, game, M, S, roll, play = C.mod, C.game, C.M, C.S, C.roll, C.play
	local enemy, player0, fireExtra, nearestEnemy, safe, rng = C.enemy, C.player0, C.fireExtra, C.nearestEnemy, C.safe, C.rng
	local T = C.T

	S.vb, S.vr, S.vf, S.vrun = S.vb or {}, S.vr or {}, S.vf or {}, S.vrun or {}   -- на время / комнату / этаж / забег
	local later = {}                                                              -- отложенные действия

	local ALL = CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY | CacheFlag.CACHE_SPEED | CacheFlag.CACHE_LUCK
	local function now() return game:GetFrameCount() end
	local function after(frames, fn) later[#later + 1] = { now() + frames, fn } end
	local function buffOn(key) return (S.vb[key] or -1) > now() end
	local function stack(tbl, key, cap)
		tbl[key] = math.min(cap, (tbl[key] or 0) + 1)
		return tbl[key]
	end
	local function same(a, b) return a and b and GetPtrHash(a) == GetPtrHash(b) end
	local function refresh(p) if p then p:AddCacheFlags(ALL, true) end end
	local function roomEnemies()
		local t = {}
		for _, e in ipairs(Isaac.GetRoomEntities()) do if enemy(e) then t[#t + 1] = e end end
		return t
	end
	local function nearby(pos, r, skip)
		local t = {}
		for _, e in ipairs(Isaac.FindInRadius(pos, r, EntityPartition.ENEMY)) do
			if enemy(e) and not same(e, skip) then t[#t + 1] = e end
		end
		return t
	end
	local function freePos(off)
		local room = game:GetRoom()
		return room:FindFreePickupSpawnPosition(room:GetCenterPos() + (off or Vector.Zero), 0, true)
	end
	local function spawn(v, st, pos, vel)
		return Isaac.Spawn(EntityType.ENTITY_PICKUP, v, st or 0, pos, vel or Vector.Zero, nil)
	end
	local function aside(p)   -- свободное место в 2–3 клетках от игрока
		return game:GetRoom():FindFreePickupSpawnPosition(p.Position + RandomVector() * 90, 0, true)
	end
	local function cardOrPill(pos)
		if rng:RandomInt(2) == 0 then return spawn(PickupVariant.PICKUP_TAROTCARD, 0, pos) end
		return spawn(PickupVariant.PICKUP_PILL, 0, pos)
	end
	-- спутник, от которого урон: сам спутник или его слеза
	local function famOf(se)
		if not se then return nil end
		local f = se:ToFamiliar()
		if f then return f end
		local sp = se.SpawnerEntity
		return sp and sp:ToFamiliar() or nil
	end
	-- второй брат (Иаков и Исав) или вторая половина (Порченый Забытый: тело и душа)
	local PAIR = { [PlayerType.PLAYER_THEFORGOTTEN_B] = PlayerType.PLAYER_THESOUL_B,
		[PlayerType.PLAYER_THESOUL_B] = PlayerType.PLAYER_THEFORGOTTEN_B }
	local function partner(p)
		local t = p.GetOtherTwin and p:GetOtherTwin()
		if t then return t end
		local want = PAIR[p:GetPlayerType()]
		if not want then return nil end
		for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_PLAYER)) do
			local q = e:ToPlayer()
			if q and q:GetPlayerType() == want then return q end
		end
		return nil
	end
	V.partner = partner
	local function partnerNear(p)
		local q = partner(p)
		return q ~= nil and q.Position:Distance(p.Position) <= 100
	end
	local function hasMantle(p)
		return p:GetEffects():GetCollectibleEffectNum(CollectibleType.COLLECTIBLE_HOLY_MANTLE) > 0
	end
	local function isBerserk(p) return p:GetEffects():HasCollectibleEffect(CollectibleType.COLLECTIBLE_BERSERK) end
	local BLUE = {}
	for _, k in ipairs({ "BLUE_FLY", "BLUE_SPIDER", "WISP", "ITEM_WISP", "ABYSS_LOCUST", "BLOOD_BABY", "DIP" }) do
		if FamiliarVariant[k] then BLUE[FamiliarVariant[k]] = true end
	end
	local function famCount(p, variant)
		local n = 0
		for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, variant or -1)) do
			local f = e:ToFamiliar()
			if f and same(f.Player, p) and (variant or not BLUE[f.Variant]) then n = n + 1 end
		end
		return n
	end
	local function fullCharge(p)
		local id = p:GetActiveItem(ActiveSlot.SLOT_PRIMARY)
		if not id or id == 0 then return false end
		local cfg = Isaac.GetItemConfig():GetCollectible(id)
		return cfg ~= nil and cfg.MaxCharges > 0 and p:GetActiveCharge(ActiveSlot.SLOT_PRIMARY) >= cfg.MaxCharges
	end
	local function soulOf(p)   -- у Забытого синие сердца — у Души
		local sub = p.GetSubPlayer and p:GetSubPlayer()
		if sub then return (sub:GetSoulHearts() or 0) end
		return (p:GetSoulHearts() or 0)
	end
	local function lowRed(p) return (p:GetHearts() or 0) <= 2 end
	local function poopAlive(g)
		return g and g:GetType() == GridEntityType.GRID_POOP and g.State < 1000
			and g.CollisionClass ~= GridCollisionClass.COLLISION_NONE
	end
	local function nearPoop(p)
		local room = game:GetRoom()
		for dy = -2, 2 do
			for dx = -2, 2 do
				local pos = p.Position + Vector(dx * 40, dy * 40)
				local g = room:GetGridEntityFromPos(pos)
				if poopAlive(g) and g.Position:Distance(p.Position) <= 90 then return true end
			end
		end
		return false
	end
	local function freshOn() return S.vRoomFoes and S.vRoomAt and now() - S.vRoomAt < 300 end
	local function sacActive()
		local n = 0
		for _, t in ipairs(S.vSac or {}) do if t > now() then n = n + 1 end end
		return math.min(3, n)
	end
	local STATUS = { EntityFlag.FLAG_SLOW, EntityFlag.FLAG_FEAR, EntityFlag.FLAG_CHARM, EntityFlag.FLAG_CONFUSION,
		EntityFlag.FLAG_FREEZE, EntityFlag.FLAG_POISON, EntityFlag.FLAG_BURN }
	local function hasStatus(e)
		for _, f in ipairs(STATUS) do if f and e:HasEntityFlags(f) then return true end end
		return false
	end
	local function inAnemia(e)
		for _, c in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.PLAYER_CREEP_RED)) do
			if c:GetData().lfAnemia and c.Position:Distance(e.Position) <= 30 + e.Size then return true end
		end
		return false
	end
	local function shard(p, pos, vel, mult, variant)   -- слеза таланта без выстрела игрока
		local t = Isaac.Spawn(EntityType.ENTITY_TEAR, variant or TearVariant.BLUE, 0, pos, vel, p):ToTear()
		if t then
			t.CollisionDamage = p.Damage * mult
			t:GetData().lfTearFx = true
		end
		return t
	end
	local function selfUse(p, item)   -- предмет по таланту (не считается «использованием» для других талантов)
		V.selfUse = true
		pcall(p.UseActiveItem, p, item, UseFlag.USE_NOANIM)
		V.selfUse = false
	end

	-- ---------------------------------------------------------------------------------------- действия
	local function shockwave(p, pos, skip)   -- «Ослиная челюсть»
		game:ShakeScreen(5)
		game:SpawnParticles(pos, EffectVariant.ROCK_PARTICLE, 6, 4)
		play("SOUND_ROCK_CRUMBLE", 0.6, 1.2)
		for _, en in ipairs(nearby(pos, 80, skip)) do
			en:TakeDamage(p.Damage * 1.5, 0, EntityRef(p), 0)
			en:AddVelocity((en.Position - pos):Resized(8))
		end
	end
	local function holyBurst(p)   -- «Святой взрыв»
		play("SOUND_HOLY", 0.8)
		local list = roomEnemies()
		for i, en in ipairs(list) do
			if i <= 4 then
				local b = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.CRACK_THE_SKY, 0, en.Position, Vector.Zero, p):ToEffect()
				if b then b.CollisionDamage = 0 end
			end
			en:TakeDamage(p.Damage * 10, 0, EntityRef(p), 0)
		end
	end
	local function stench(p)   -- «Смрад смерти»
		game:Fart(p.Position, 85, p, 1, 0, Color.Default)
		for _, en in ipairs(nearby(p.Position, 100)) do en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
	end
	local function pillars(p)   -- «Столпы храма»
		game:ShakeScreen(20)
		play("SOUND_ROCK_CRUMBLE", 1, 0.7)
		local room = game:GetRoom()
		for i = 1, 6 do
			game:SpawnParticles(room:GetRandomPosition(20), EffectVariant.ROCK_PARTICLE, 6, 5)
		end
		for _, en in ipairs(roomEnemies()) do en:TakeDamage(p.Damage * 10, 0, EntityRef(p), 0) end
	end
	local function shadowBurst(p, pos)   -- «Проклятие предателя»
		game:SpawnParticles(pos, EffectVariant.DARK_BALL_SMOKE_PARTICLE, 10, 4)
		play("SOUND_UNHOLY", 0.5, 1.3)
		for _, en in ipairs(nearby(pos, 100)) do en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
	end
	local function chaos(p)   -- «Хаос во плоти»
		local ref = EntityRef(p)
		for _, en in ipairs(roomEnemies()) do
			local r = rng:RandomInt(5)
			if r == 0 then en:AddFear(ref, 90)
			elseif r == 1 then en:AddSlowing(ref, 90, 0.5, Color(0.6, 0.6, 0.6, 1, 0, 0, 0))
			elseif r == 2 then en:AddConfusion(ref, 90, false)
			elseif r == 3 then en:AddCharmed(ref, 90)
			else en:AddPoison(ref, 90, p.Damage) end
		end
		play("SOUND_EDEN_GLITCH", 0.5)
	end
	local TEARFX = { "TEAR_SLOW", "TEAR_POISON", "TEAR_CHARM", "TEAR_FEAR", "TEAR_FREEZE", "TEAR_BURN", "TEAR_CONFUSION",
		"TEAR_HOMING" }

	-- ---------------------------------------------------------------------------------------- крючки
	-- урон по врагу: множитель
	function H.dmgMult(ent, p, se, amount, flags)
		local mult, f, ed = 1, now(), ent:GetData()
		local fam = famOf(se)
		if fam then
			local fv = fam.Variant
			if M("lfLiFamDmg") > 0 then mult = mult * (1 + M("lfLiFamDmg") / 100) end                 -- «Инкуб»
			if fv == FamiliarVariant.BLUE_FLY and M("lfKpFlies") > 0 then mult = mult * (1 + M("lfKpFlies") / 100) end
			if (fv == FamiliarVariant.WISP or fv == FamiliarVariant.ITEM_WISP) and M("lfBeWisp") > 0 then
				mult = mult * (1 + M("lfBeWisp") / 100)                                                -- «Огоньки»
			end
			if fv == FamiliarVariant.BLOOD_BABY and M("lfTeClot") > 0 then mult = mult * (1 + M("lfTeClot") / 100) end
			if fv == FamiliarVariant.ABYSS_LOCUST then
				if M("lfTapLocust") > 0 then mult = mult * (1 + M("lfTapLocust") / 100) end           -- «Саранча»
				if M("lfTapPlague") > 0 and (ed.lfPlagueCd or 0) <= f then                            -- «Чума»
					ed.lfPlagueCd = f + 30
					ent:AddPoison(EntityRef(p), 60, p.Damage * 0.5)
				end
			end
			if fv == FamiliarVariant.UMBILICAL_BABY then
				if M("lfTliCord") > 0 then mult = mult * (1 + M("lfTliCord") / 100) end              -- «Пуповина»
				if (ed.lfFetusCd or 0) <= f and roll(M("lfTliFetus")) then                         -- «Пугающее дитя»
					ed.lfFetusCd = f + 30
					ent:AddFear(EntityRef(p), 90)
				end
				ed.lfFetusHit = f
			end
		end
		if se and se.Type == EntityType.ENTITY_DARK_ESAU and M("lfTjaEsau") > 0 then
			mult = mult * (1 + M("lfTjaEsau") / 100)                                                  -- «Тёмный брат»
		end
		if se and se.Type == EntityType.ENTITY_EFFECT and se.Variant == EffectVariant.PLAYER_CREEP_RED and M("lfTmCreep") > 0 then
			mult = mult * (1 + M("lfTmCreep") / 100)                                                  -- «Кровоток»
		end
		if se and se:ToKnife() then
			if M("lfTfClub") > 0 then mult = mult * (1 + M("lfTfClub") / 100) end                    -- «Костяная дубина»
			if M("lfTfStorm") > 0 and (S.vStormCd or 0) <= f and roll(25) then                      -- «Костяной шторм»
				S.vStormCd = f + 8
				for i = 0, 2 do   -- от края врага наружу: осколки летят в соседей, а не лопаются в нём
					local dir = Vector(1, 0):Rotated(rng:RandomInt(360))
					shard(p, ent.Position + dir * (ent.Size + 14), dir * 8, 0.5, TearVariant.BONE)
				end
			end
		end
		if M("lfTmHug") > 0 and ent.Position:Distance(p.Position) <= 80 + ent.Size then
			mult = mult * (1 + M("lfTmHug") / 100)                                                    -- «Объятия»
		end
		if M("lfTaMarkDmg") > 0 and ent:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED) then
			mult = mult * (1 + M("lfTaMarkDmg") / 100)                                                -- «Метка серы»
		end
		if M("lfTjNoose") > 0 and hasStatus(ent) then mult = mult * (1 + M("lfTjNoose") / 100) end   -- «Удавка»
		if M("lfLzAnemia") > 0 and inAnemia(ent) then mult = mult * 1.5 end                        -- «Вечная анемия»
		-- состояния от удара (с откатом на врага)
		if (ed.lfStatusCd or 0) <= f then
			local ref, any = EntityRef(p), false
			if roll(M("lfAzBurn")) then ent:AddBurn(ref, 90, p.Damage) any = true end              -- «Адское пламя»
			if roll(M("lfFoCrush")) then ent:AddSlowing(ref, 60, 0.5, Color(0.6, 0.6, 0.6, 1, 0, 0, 0)) any = true end
			if roll(M("lfJeTrick")) then ent:AddConfusion(ref, 60, false) any = true end           -- «Хитрость Иакова»
			if ent.AddBleeding and roll(M("lfTeBleed")) then ent:AddBleeding(ref, 150) any = true end   -- «Кровопускание»
			if roll(M("lfTaMark")) then ent:AddBrimstoneMark(ref, 150) any = true end              -- «Проклятая сера»
			if any then ed.lfStatusCd = f + 15 end
		end
		return mult
	end

	-- кто нанёс урон, если не игрок и не его слеза: Тёмный Исав
	function H.altSource(se)
		if se and se.Type == EntityType.ENTITY_DARK_ESAU then return player0() end
	end

	-- убийство
	function H.onKill(npc, p, pos)
		if roll(M("lfBbFlies")) then p:AddBlueFlies(1, pos, nil) end                               -- «Мушиный рой»
		if roll(M("lfSaJaw")) then shockwave(p, pos, npc) end                                       -- «Ослиная челюсть»
		if roll(M("lfBeSoulCh")) and p.AddSoulCharge then p:AddSoulCharge(1) end                    -- «Душевный запас»
		if roll(M("lfTbeBlood")) and p.AddBloodCharge then p:AddBloodCharge(1) end                  -- «Кровавый заряд»
		if PickupVariant.PICKUP_POOP and roll(M("lfTbPoopDrop")) then
			spawn(PickupVariant.PICKUP_POOP, 0, pos, RandomVector() * 2)                             -- «Удобрение»
		end
		if roll(M("lfTkTip")) then                                                                  -- «Чаевые»
			local c = spawn(PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY, pos, RandomVector() * 2):ToPickup()
			if c then c.Timeout = -1 end
		end
		if isBerserk(p) and roll(M("lfTsExtend")) then                                              -- «Неистовство»
			local ef = p:GetEffects():GetCollectibleEffect(CollectibleType.COLLECTIBLE_BERSERK)
			if ef then ef.Cooldown = ef.Cooldown + 30 end
		end
		if M("lfTjCurse") > 0 then                                                                  -- «Проклятие предателя»
			S.vr.tjKills = (S.vr.tjKills or 0) + 1
			if S.vr.tjKills % 3 == 0 then shadowBurst(p, pos) end
		end
		if M("lfTaCough") > 0 and npc:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED) then        -- «Адский кашель»
			for _, en in ipairs(nearby(pos, 120, npc)) do en:AddBrimstoneMark(EntityRef(p), 150) end
		end
		if M("lfTliAbyss") > 0 and (npc:GetData().lfFetusHit or -99) >= now() - 10 then           -- «Дитя бездны»
			for i = 0, 3 do shard(p, pos, Vector(9, 0):Rotated(45 + i * 90), 1) end
		end
	end

	-- удар по игроку (до того, как игра его применит); false — удара нет
	function H.onHurt(p, amount, flags, src)
		local se = src and src.Entity
		local selfHit = se and same(se, p)
		local cost = flags & (DamageFlag.DAMAGE_RED_HEARTS | DamageFlag.DAMAGE_IV_BAG) ~= 0
		local room = game:GetRoom()
		if not selfHit and not cost then
			if roll(M("lfAzWings")) then                                                            -- «Взмах крыльев»
				p:SetMinDamageCooldown(30)
				p:SetColor(Color(1, 1, 1, 0.4, 0.2, 0.2, 0.2), 10, 1, true, false)
				play("SOUND_BIRD_FLAP", 0.8)
				return false
			end
			if M("lfAzScapegoat") > 0 and not S.vr.azGoat and not room:IsClear() then              -- «Козёл отпущения»
				S.vr.azGoat = 1
				local en = nearestEnemy(p.Position, 2000)
				if en then en:TakeDamage(p.Damage * 5, 0, EntityRef(p), 0) end
				p:SetMinDamageCooldown(30)
				play("SOUND_DEVIL_CARD", 0.7)
				return false
			end
		end
		if hasMantle(p) then return nil end   -- удар примет щит мантии (его разбитие — V.mantleBroke)
		if roll(M("lfEvRaven")) then                                                                -- «Вороньё»
			for _, en in ipairs(roomEnemies()) do en:AddFear(EntityRef(p), 90) end
			play("SOUND_BIRD_FLAP", 0.8, 0.8)
		end
		if M("lfEvRazor") > 0 then stack(S.vr, "evRazor", 3) end                                   -- «Порез»
		if M("lfSaRage") > 0 then stack(S.vf, "saRage", 5) end                                     -- «Неукротимый»
		S.vr.saHit = 1                                                                              -- «Волосы Самсона»
		if M("lfSaPillars") > 0 and not S.vr.saPillars and not room:IsClear() then                -- «Столпы храма»
			local hp = (p:GetHearts() or 0) + (p:GetSoulHearts() or 0) + (p:GetBoneHearts() or 0) * 2 - amount
			if hp <= 2 then
				S.vr.saPillars = 1
				pillars(p)
			end
		end
		if roll(M("lfLzRags")) then after(1, function() p:AddSoulHearts(1) end) end              -- «Саван»
		if roll(M("lfLiConception")) then                                                          -- «Зачатие»
			after(1, function() for _ = 1, 2 do p:AddBlueSpider(p.Position) end end)
		end
		if roll(M("lfKpPiggy")) then                                                               -- «Копилка»
			after(1, function() spawn(PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY, aside(p), RandomVector() * 2) end)
		end
		if M("lfBbStench") > 0 and not room:IsClear() then stench(p) end                         -- «Смрад смерти»
		if M("lfTedRebirth") > 0 then S.vb.tedRebirth = now() + 300 end                            -- «Перерождение»
		if roll(M("lfTedHitDrop")) then after(1, function() cardOrPill(aside(p)) end) end
		if M("lfTedChaos") > 0 and not room:IsClear() then chaos(p) end                          -- «Хаос во плоти»
		if M("lfJeTwo") > 0 then                                                                    -- «Двое против всех»
			local q = partner(p)
			if q then
				S.vr["jeTwo" .. GetPtrHash(q)] = 1
				refresh(q)
			end
		end
		after(1, function() refresh(p) end)
	end

	-- щит Святой мантии разбит (число щитов уменьшилось — кадр игрока)
	function V.mantleBroke(p)
		if roll(M("lfLoMantle")) then                                                               -- «Отголосок мантии»
			after(90, function()
				if not hasMantle(p) then
					p:GetEffects():AddCollectibleEffect(CollectibleType.COLLECTIBLE_HOLY_MANTLE, true)
					play("SOUND_HOLY_MANTLE", 0.6)
				end
			end)
		end
		if M("lfLoBurst") > 0 then holyBurst(p) end                                                 -- «Святой взрыв»
		if M("lfTloLast") > 0 then S.vr.tloLast = 1 end                                              -- «Сквозь смерть»
		refresh(p)
	end

	-- характеристики: прибавки урона и скорострельности в %, удача, скорость
	function H.cache(p, flag)
		local dmg, tears, luck, speed = 0, 0, 0, 0
		local pt = p:GetPlayerType()
		-- ???
		if M("lfBbSoulDmg") > 0 then dmg = dmg + M("lfBbSoulDmg") * math.min(6, math.floor((p:GetSoulHearts() or 0) / 2)) end
		if M("lfBbStench") > 0 then tears = tears - 5 end
		-- Ева
		if M("lfEvEmpty") > 0 then
			dmg = dmg + M("lfEvEmpty") * math.min(6, math.floor(math.max(0, (p:GetMaxHearts() or 0) - (p:GetHearts() or 0)) / 2))
		end
		dmg = dmg + M("lfEvRazor") * (S.vr.evRazor or 0)
		if M("lfEvBabylon") > 0 then
			tears = tears - 5
			if lowRed(p) then speed = speed + 0.3 end
		end
		-- Самсон
		dmg = dmg + M("lfSaRage") * (S.vf.saRage or 0)
		if M("lfSaHair") > 0 and not S.vr.saHit then dmg = dmg + M("lfSaHair") end
		if M("lfSaPillars") > 0 then speed = speed - 0.1 end
		-- Азазель
		if M("lfAzScapegoat") > 0 then dmg = dmg - 10 end
		-- Лазарь
		dmg = dmg + M("lfLzPill") * (S.vr.lzPill or 0)
		if M("lfLzAnemia") > 0 then speed = speed - 0.1 end
		-- Иден
		if M("lfEdReshape") > 0 and S.vf.edUp then
			local up, dn = S.vf.edUp, S.vf.edDown
			if up == 1 then dmg = dmg + 25 elseif up == 2 then tears = tears + 25 elseif up == 3 then speed = speed + 0.25 else luck = luck + 2 end
			if dn == 1 then dmg = dmg - 10 elseif dn == 2 then tears = tears - 10 elseif dn == 3 then speed = speed - 0.1 else luck = luck - 1 end
		end
		-- Потерянный
		dmg = dmg + M("lfLoDeal") * math.min(10, S.vrun.loDeals or 0)
		if M("lfLoBurst") > 0 then dmg = dmg - 5 end
		-- Лилит
		if M("lfLiRetinue") > 0 then
			dmg = dmg + 3 * math.min(10, famCount(p))
			tears = tears - 5
		end
		-- Хранитель
		if M("lfKpGreedDmg") > 0 then dmg = dmg + M("lfKpGreedDmg") * math.min(5, math.floor(p:GetNumCoins() / 10)) end
		if M("lfKpMiser") > 0 then dmg = dmg - 5 end
		-- Аполлион
		dmg = dmg + M("lfApVoid") * (S.vr.apVoid or 0)
		if M("lfApHunger") > 0 then dmg = dmg + (S.vf.apHunger or 0) end
		if M("lfApCharged") > 0 and fullCharge(p) then tears = tears + M("lfApCharged") end
		if M("lfApApoc") > 0 then tears = tears - 10 end
		-- Забытый
		if M("lfFoBone") > 0 then dmg = dmg + M("lfFoBone") * math.min(6, (p:GetBoneHearts() or 0)) end
		if M("lfFoChain") > 0 then
			speed = speed - 0.1
			if (p:GetBoneHearts() or 0) > 0 and soulOf(p) > 0 then
				dmg = dmg + 15
				tears = tears + 15
			end
		end
		-- Вифания
		if M("lfBeCandle") > 0 then dmg = dmg - 5 end
		-- Иаков и Исав
		if M("lfJeBond") > 0 and partnerNear(p) then dmg = dmg + M("lfJeBond") end
		if M("lfJeTwo") > 0 then
			tears = tears - 5
			if S.vr["jeTwo" .. GetPtrHash(p)] then dmg = dmg + 25 end
		end
		-- Порченый Исаак
		local items = p:GetCollectibleCount()
		if M("lfTiSort") > 0 then tears = tears + M("lfTiSort") * math.min(8, items) end
		if M("lfTiSwap") > 0 then dmg = dmg + 5 * (S.vf.tiSwap or 0) end
		if M("lfTiEight") > 0 then
			speed = speed - 0.1
			if items >= 8 then
				dmg = dmg + 20
				tears = tears + 20
			end
		end
		-- Порченая Магдалина
		if M("lfTmOpen") > 0 then
			tears = tears - 10
			dmg = dmg + 2 * math.min(10, S.vr.tmOpen or 0)
		end
		-- Порченый Каин
		if M("lfTcCraft") > 0 then dmg = dmg + M("lfTcCraft") * math.min(5, math.floor((S.vf.tcPicked or 0) / 5)) end
		if M("lfTcAlch") > 0 then dmg = dmg - 5 end
		-- Порченый Иуда
		if buffOn("tjArts") then dmg = dmg + M("lfTjArts") end
		if M("lfTjCurse") > 0 then tears = tears - 5 end
		-- Порченый ???
		if M("lfTbPoopDmg") > 0 and nearPoop(p) then dmg = dmg + M("lfTbPoopDmg") end
		if M("lfTbKing") > 0 then
			tears = tears - 10
			dmg = dmg + 3 * math.min(10, S.vr.tbKing or 0)
		end
		-- Порченая Ева
		if M("lfTeSac") > 0 then
			tears = tears - 5
			dmg = dmg + 10 * sacActive()
		end
		-- Порченый Самсон
		if isBerserk(p) then dmg = dmg + M("lfTsBerserk")
		elseif M("lfTsUnstop") > 0 then tears = tears - 10 end
		-- Порченый Азазель
		if M("lfTaCough") > 0 then dmg = dmg - 5 end
		-- Порченый Лазарь
		if pt == PlayerType.PLAYER_LAZARUS2_B then dmg = dmg + M("lfTlDead") end
		if pt == PlayerType.PLAYER_LAZARUS_B then tears = tears + M("lfTlAlive") end
		if freshOn() then dmg = dmg + M("lfTlFresh") end
		if M("lfTlFlip") > 0 then
			speed = speed - 0.1
			if S.vr.tlFlip then dmg = dmg + 15 end
		end
		-- Порченый Иден
		if buffOn("tedRebirth") then dmg = dmg + M("lfTedRebirth") end
		if M("lfTedChaos") > 0 then tears = tears - 5 end
		-- Порченый Потерянный
		if M("lfTloShield") > 0 and hasMantle(p) then dmg = dmg + M("lfTloShield") end
		if M("lfTloLast") > 0 then
			tears = tears - 10
			if S.vr.tloLast then dmg = dmg + 50 end
		end
		-- Порченая Лилит
		if M("lfTliAbyss") > 0 then speed = speed - 0.1 end
		-- Порченый Хранитель
		if buffOn("tkRush") then tears = tears + M("lfTkRush") end
		if M("lfTkInvest") > 0 then
			tears = tears - 5
			dmg = dmg + 3 * math.min(10, math.floor((S.vf.tkSpent or 0) / 15))
		end
		-- Порченый Аполлион
		if M("lfTapPlague") > 0 then dmg = dmg - 5 end
		-- Порченый Забытый
		if M("lfTfBond") > 0 and partnerNear(p) then dmg = dmg + M("lfTfBond") end
		if M("lfTfStorm") > 0 then speed = speed - 0.1 end
		-- Порченая Вифания
		if M("lfTbeLem") > 0 then dmg = dmg - 5 end
		-- Порченый Иаков
		if pt == PlayerType.PLAYER_JACOB2_B then dmg = dmg + M("lfTjaLost") end
		if M("lfTjaRun") > 0 and #Isaac.FindByType(EntityType.ENTITY_DARK_ESAU) > 0 then tears = tears + M("lfTjaRun") end
		if M("lfTjaChain") > 0 then speed = speed - 0.1 end
		return dmg, tears, luck, speed
	end

	-- выстрел
	function H.tear(tear, p)
		if roll(M("lfEdMut")) then                                                                  -- «Мутация»
			local fl = TearFlags[TEARFX[rng:RandomInt(#TEARFX) + 1]]
			if fl then
				tear:AddTearFlags(fl)
				tear.Color = Color(1, 1, 1, 1, rng:RandomFloat() * 0.4, rng:RandomFloat() * 0.4, rng:RandomFloat() * 0.4)
			end
		end
		if M("lfEvBabylon") > 0 and lowRed(p) then tear:AddTearFlags(TearFlags.TEAR_PIERCING) end   -- «Грех Вавилона»
	end

	-- вход в комнату
	function H.onRoom()
		S.vr = {}
		S.vPoops = nil
		local p = player0()
		if not p then return end
		local room = game:GetRoom()
		S.vRoomAt, S.vRoomFoes = now(), not room:IsClear()
		if not room:IsClear() then
			if roll(M("lfAzSulfur")) then selfUse(p, CollectibleType.COLLECTIBLE_SULFUR) end          -- «Серная вспышка»
			if roll(M("lfLiBox")) then selfUse(p, CollectibleType.COLLECTIBLE_BOX_OF_FRIENDS) end   -- «Коробка друзей»
			if roll(M("lfLoUnseen")) then                                                           -- «Незримый»
				for _, en in ipairs(roomEnemies()) do en:AddConfusion(EntityRef(p), 60, false) end
			end
		end
		refresh(p)
		refresh(partner(p))
	end

	-- зачистка комнаты
	function H.onClear(p)
		local room = game:GetRoom()
		local boss = room:GetType() == RoomType.ROOM_BOSS
		if roll(M("lfBbSoulRegen")) then p:AddSoulHearts(1) end                                   -- «Призрачная плоть»
		if roll(M("lfLzRegen")) and (p:GetHearts() or 0) < (p:GetEffectiveMaxHearts() or 0) then p:AddHearts(1) end
		if boss and roll(M("lfEdToken")) then spawn(PickupVariant.PICKUP_TRINKET, 0, freePos(Vector(-40, 40))) end
		if boss and roll(M("lfFoWall")) then spawn(PickupVariant.PICKUP_HEART, HeartSubType.HEART_BONE, freePos(Vector(40, 40))) end
		if boss and roll(M("lfTloCard")) then spawn(PickupVariant.PICKUP_TAROTCARD, Card.CARD_HOLY, freePos(Vector(0, 60))) end
		if roll(M("lfBeCharge")) then pcall(p.AddActiveCharge, p, 1, ActiveSlot.SLOT_PRIMARY, true, false, false) end
		if roll(M("lfJeStew")) then                                                                -- «Чечевичная похлёбка»
			p:AddHearts(1)
			local q = partner(p)
			if q then q:AddHearts(1) end
		end
		if roll(M("lfTcBag")) then                                                                 -- «Сумка»
			for i = 1, 2 do spawn(0, 0, freePos(Vector(i * 30 - 45, 30))) end
		end
	end

	-- новый этаж
	function H.onLevel(p)
		S.vf = {}
		if M("lfEdReshape") > 0 then                                                               -- «Перекройка»
			local up = rng:RandomInt(4) + 1
			local dn = rng:RandomInt(3) + 1
			if dn >= up then dn = dn + 1 end
			S.vf.edUp, S.vf.edDown = up, dn
		end
		if roll(M("lfEdStart")) then                                                               -- «Запас Идена»
			local r = rng:RandomInt(3)
			local v = r == 0 and PickupVariant.PICKUP_TAROTCARD or r == 1 and PickupVariant.PICKUP_PILL or PickupVariant.PICKUP_TRINKET
			spawn(v, 0, freePos(Vector(0, 40)))
		end
		refresh(p)
	end

	function H.onStart(cont)
		if not cont then S.vrun = {} end
		S.vb, S.vr, S.vf = {}, {}, {}
		S.vColl, S.vHearts, S.vClots, S.vCoins, S.vBerserk, S.vSig, S.vSac = nil, nil, nil, nil, nil, nil, {}
		-- метки с номером кадра: номер кадра нового забега начинается с нуля
		S.vStormCd, S.vMantle, S.vMantleRoom, S.vRoomAt, S.vRoomFoes, S.vPoops = nil, nil, nil, nil, nil, nil
		later = {}
	end

	-- ---------------------------------------------------------------------------------------- свои обработчики
	mod:AddCallback(ModCallbacks.MC_POST_UPDATE, safe("vLater", function()
		if #later == 0 then return end
		local f, keep = now(), {}
		for _, it in ipairs(later) do
			if it[1] <= f then pcall(it[2]) else keep[#keep + 1] = it end
		end
		later = keep
	end))

	-- признаки, от которых зависят прибавки: изменились — пересчитать
	local function sig(p)
		local t = {}
		local function add(v) t[#t + 1] = tostring(v) end
		if M("lfBbSoulDmg") > 0 then add((p:GetSoulHearts() or 0)) end
		if M("lfEvEmpty") > 0 or M("lfEvBabylon") > 0 then add((p:GetHearts() or 0)) add((p:GetMaxHearts() or 0)) end
		if M("lfKpGreedDmg") > 0 then add(math.floor(p:GetNumCoins() / 10)) end
		if M("lfApCharged") > 0 then add(fullCharge(p)) end
		if M("lfFoBone") > 0 or M("lfFoChain") > 0 then add((p:GetBoneHearts() or 0)) add(soulOf(p) > 0) end
		if M("lfLiRetinue") > 0 then add(famCount(p)) end
		if M("lfTiSort") > 0 or M("lfTiEight") > 0 then add(p:GetCollectibleCount()) end
		if M("lfTbPoopDmg") > 0 then add(nearPoop(p)) end
		if M("lfTsBerserk") > 0 or M("lfTsUnstop") > 0 then add(isBerserk(p)) end
		if M("lfTlDead") > 0 or M("lfTlAlive") > 0 or M("lfTjaLost") > 0 then add(p:GetPlayerType()) end
		if M("lfTloShield") > 0 then add(hasMantle(p)) end
		if M("lfTjaRun") > 0 then add(#Isaac.FindByType(EntityType.ENTITY_DARK_ESAU)) end
		if M("lfJeBond") > 0 or M("lfTfBond") > 0 then add(partnerNear(p)) end
		if M("lfTlFresh") > 0 then add(freshOn()) end
		if M("lfTeSac") > 0 then add(sacActive()) end
		for _, k in ipairs({ "tjArts", "tedRebirth", "tkRush" }) do add(buffOn(k)) end
		return table.concat(t, ",")
	end

	mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("vanilla2", function(_, p)
		if not same(p, player0()) then return end
		local f = now()
		if M("lfLzAnemia") > 0 and p.FrameCount % 4 == 0 and p.Velocity:Length() > 1 then             -- «Вечная анемия»
			local c = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.PLAYER_CREEP_RED, 0, p.Position, Vector.Zero, p):ToEffect()
			if c then
				c.CollisionDamage = p.Damage * 0.3
				c:SetTimeout(60)
				c:GetData().lfAnemia = true
			end
		end
		local n = p:GetCollectibleCount()                                                          -- Порченый Исаак
		if S.vColl and n ~= S.vColl then
			if n > S.vColl and roll(M("lfTiGift")) then spawn(0, 0, freePos(Vector(0, 40))) end   -- «Подарок выбора»
			if n < S.vColl and roll(M("lfTiSwap")) then                                           -- «Обмен»
				p:AddHearts(2)
				S.vf.tiSwap = math.min(4, (S.vf.tiSwap or 0) + 1)
				refresh(p)
			end
		end
		S.vColl = n
		local h = (p:GetHearts() or 0)                                                                    -- «Сердце нараспашку»
		if S.vHearts and h > S.vHearts and M("lfTmOpen") > 0 then
			S.vr.tmOpen = math.min(10, (S.vr.tmOpen or 0) + (h - S.vHearts))
			refresh(p)
		end
		S.vHearts = h
		if M("lfTeSac") > 0 then                                                                  -- «Кровавая жертва»
			local c = famCount(p, FamiliarVariant.BLOOD_BABY)
			if S.vClots and c > S.vClots then
				for _ = 1, c - S.vClots do table.insert(S.vSac, f + 150) end
				refresh(p)
			end
			S.vClots = c
		end
		local b = isBerserk(p)                                                                     -- «Неудержимый»
		if b and not S.vBerserk and M("lfTsUnstop") > 0 then
			after(3, function()   -- свежий Берсерк игра заводит своим таймером в первых кадрах
				local ef = p:GetEffects():GetCollectibleEffect(CollectibleType.COLLECTIBLE_BERSERK)
				if ef then ef.Cooldown = ef.Cooldown + 60 end
			end)
		end
		S.vBerserk = b
		local mc = p:GetEffects():GetCollectibleEffectNum(CollectibleType.COLLECTIBLE_HOLY_MANTLE)   -- щит мантии
		if S.vMantle and mc < S.vMantle and S.vMantleRoom == game:GetLevel():GetCurrentRoomIndex() then
			V.mantleBroke(p)
		end
		S.vMantle, S.vMantleRoom = mc, game:GetLevel():GetCurrentRoomIndex()
		local coins = p:GetNumCoins()                                                              -- «Инвестор»
		if S.vCoins and coins < S.vCoins and M("lfTkInvest") > 0 then
			S.vf.tkSpent = (S.vf.tkSpent or 0) + (S.vCoins - coins)
		end
		S.vCoins = coins
		if M("lfTbKing") > 0 and f % 6 == 0 then                                                  -- «Король кала»
			local room = game:GetRoom()
			S.vPoops = S.vPoops or {}
			for i = 0, room:GetGridSize() - 1 do
				local g = room:GetGridEntity(i)
				if g and g:GetType() == GridEntityType.GRID_POOP then
					local alive = poopAlive(g)
					if S.vPoops[i] == true and not alive then
						stack(S.vr, "tbKing", 10)
						refresh(p)
					end
					S.vPoops[i] = alive
				end
			end
		end
		if f % 6 == 0 then
			local sg = sig(p)
			if sg ~= S.vSig then
				S.vSig = sg
				refresh(p)
				refresh(partner(p))
			end
		end
	end))

	-- использован активный предмет
	mod:AddCallback(ModCallbacks.MC_USE_ITEM, safe("vUse", function(_, item, _, p, flags)
		if V.selfUse or not p then return end
		if flags and flags & UseFlag.USE_CARBATTERY ~= 0 then return end
		if M("lfApVoid") > 0 then stack(S.vr, "apVoid", 3) end                                   -- «Поглощение»
		if M("lfApApoc") > 0 then                                                                 -- «Апокалипсис»
			for _, en in ipairs(roomEnemies()) do en:TakeDamage(p.Damage * 2, 0, EntityRef(p), 0) end
			game:ShakeScreen(8)
		end
		if M("lfTjArts") > 0 then S.vb.tjArts = now() + 150 end                                  -- «Тёмные искусства»
		if item == CollectibleType.COLLECTIBLE_FLIP and M("lfTlFlip") > 0 then                   -- «Обратная сторона»
			S.vr.tlFlip = 1
			after(15, function()
				local q = player0()
				if (q:GetHearts() or 0) < (q:GetEffectiveMaxHearts() or 0) then q:AddHearts(1) end
				refresh(q)
			end)
		end
		if item == CollectibleType.COLLECTIBLE_ANIMA_SOLA and M("lfTjaChain") > 0 then           -- «Цепи души»
			for _, en in ipairs(roomEnemies()) do
				if en.Type ~= EntityType.ENTITY_DARK_ESAU then en:AddFreeze(EntityRef(p), 60) end
			end
		end
		if M("lfTbeLem") > 0 and roll(25) and p.AddWisp then                                    -- «Лемегетон»
			p:AddWisp(item, p.Position, true)
		end
		refresh(p)
	end))

	-- пилюля
	mod:AddCallback(ModCallbacks.MC_USE_PILL, safe("vPill", function(_, _, p)
		if not p or M("lfLzPill") <= 0 then return end                                          -- «Знахарь»
		if (p:GetHearts() or 0) < (p:GetEffectiveMaxHearts() or 0) then p:AddHearts(1) end
		stack(S.vr, "lzPill", 3)
		refresh(p)
	end))

	-- подборы
	local SMALL = { [PickupVariant.PICKUP_COIN] = true, [PickupVariant.PICKUP_BOMB] = true, [PickupVariant.PICKUP_KEY] = true }
	mod:AddCallback(ModCallbacks.MC_PRE_PICKUP_COLLISION, safe("vPick", function(_, pk, coll)
		local p = coll and coll:ToPlayer()
		if not p then return end
		local d = pk:GetData()
		if d.lfVCounted or pk:IsShopItem() and pk.Price > 0 and p:GetNumCoins() < pk.Price then return end
		local room = game:GetRoom()
		if pk.Variant == PickupVariant.PICKUP_COLLECTIBLE then
			local rt = room:GetType()
			if pk.SubType ~= 0 and pk.Price ~= 0 and (rt == RoomType.ROOM_DEVIL or rt == RoomType.ROOM_BLACK_MARKET) then
				d.lfVCounted = true
				S.vrun.loDeals = (S.vrun.loDeals or 0) + 1                                         -- «Дьявольская удача»
				after(2, function() refresh(p) end)
			end
			return
		end
		if pk.Wait > 0 then return end
		d.lfVCounted = true
		local small = SMALL[pk.Variant]
		if (small or pk.Variant == PickupVariant.PICKUP_HEART) and roll(M("lfApHunger")) then   -- «Ненасытная пустота»
			S.vf.apHunger = math.min(20, (S.vf.apHunger or 0) + 1)
			after(1, function() refresh(p) end)
		end
		if small and roll(M("lfTcGather")) then                                                   -- «Двойной улов»
			after(1, function()
				if pk.Variant == PickupVariant.PICKUP_COIN then p:AddCoins(1)
				elseif pk.Variant == PickupVariant.PICKUP_BOMB then p:AddBombs(1)
				else p:AddKeys(1) end
			end)
		end
		if M("lfTcCraft") > 0 or M("lfTcAlch") > 0 then                                          -- «Мастеровой», «Алхимик»
			S.vf.tcPicked = (S.vf.tcPicked or 0) + 1
			S.vrun.tcTotal = (S.vrun.tcTotal or 0) + 1
			if M("lfTcAlch") > 0 and S.vrun.tcTotal % 30 == 0 then
				after(1, function() spawn(PickupVariant.PICKUP_TRINKET, 0, freePos(Vector(0, 40))) end)
			end
			after(1, function() refresh(p) end)
		end
		if pk.Variant == PickupVariant.PICKUP_COIN and M("lfTkRush") > 0 then                     -- «Золотая лихорадка»
			S.vb.tkRush = now() + 90
			after(1, function() refresh(p) end)
		end
	end))

	-- скидка («Скряга»), исчезающие полусердца («Утечка»)
	mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, safe("vPickUpd", function(_, pk)
		if M("lfKpMiser") > 0 and pk.Price > 0 then
			local d = pk:GetData()
			if d.lfMiser ~= pk.Price then
				local np = math.max(1, math.floor(pk.Price * 0.75 + 0.5))
				if np ~= pk.Price then
					pk.AutoUpdatePrice = false
					pk.Price = np
				end
				d.lfMiser = pk.Price
			end
		end
		if pk.Variant == PickupVariant.PICKUP_HEART and pk.Timeout > 0 and M("lfTmLeak") > 0 then
			local d = pk:GetData()
			if not d.lfLeak then
				d.lfLeak = true
				if roll(M("lfTmLeak")) then
					pk.Timeout = -1
					pk:SetColor(Color(1, 1, 1, 1, 0.3, 0, 0), 15, 1, true, false)
				end
			end
		end
	end))

	-- погиб огонёк («Свеча веры»)
	mod:AddCallback(ModCallbacks.MC_POST_ENTITY_KILL, safe("vWisp", function(_, e)
		local fm = e:ToFamiliar()
		if not fm or M("lfBeCandle") <= 0 then return end
		if fm.Variant ~= FamiliarVariant.WISP and fm.Variant ~= FamiliarVariant.ITEM_WISP then return end
		local p = fm.Player or player0()
		game:SpawnParticles(fm.Position, EffectVariant.EMBER_PARTICLE, 8, 4, Color(1, 1, 0.8, 1, 0.5, 0.5, 0.3))
		play("SOUND_HOLY", 0.4, 1.5)
		for _, en in ipairs(nearby(fm.Position, 90)) do en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
	end), EntityType.ENTITY_FAMILIAR)

	-- второй брат / вторая половина: те же прибавки
	mod:AddPriorityCallback(ModCallbacks.MC_EVALUATE_CACHE, CallbackPriority.LATE, safe("vTwin", function(_, p, flag)
		local p0 = player0()
		if not p0 or same(p, p0) then return end
		if not same(partner(p0), p) then return end
		local dmg, tears, luck, speed = H.cache(p, flag)
		if flag == CacheFlag.CACHE_DAMAGE and dmg ~= 0 then p.Damage = p.Damage * (1 + dmg / 100) end
		if flag == CacheFlag.CACHE_FIREDELAY and tears ~= 0 then
			p.MaxFireDelay = math.max(1, (p.MaxFireDelay + 1) / (1 + tears / 100) - 1)
		end
		if flag == CacheFlag.CACHE_LUCK and luck ~= 0 then p.Luck = p.Luck + luck end
		if flag == CacheFlag.CACHE_SPEED and speed ~= 0 then p.MoveSpeed = p.MoveSpeed + speed end
	end))

	T.V = V   -- для автотеста
	V.S = S
	return V
end

return V
