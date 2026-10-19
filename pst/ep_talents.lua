-- localfixes/pst/ep_talents.lua — механики деревьев PST девяти потускневших персонажей Epiphany (18.10, слова
-- пользователя: «Таланты персонажам модов тебе тоже надо будет сделать если не сделал»; «Так делай таланты новым
-- персонажам с уже новым стилем»; «Сначала таланты на всех - потом тесты»). Всё — через данные самого мода
-- (scripts/epiphany/characters/*): Epiphany:RunSave(p) / FloorSave(p) — гниение Исаака (BD_ROT_BUILDUP), шкала
-- кровотечения и запас лечения Магдалины (BleedingHeartsCount, TRMagdaleneBonusHearts), шкала бойни Самсона
-- (FloorSave.SamsonBar, RunSave.SamsonImmortalCountdown); инвентарь Исаака (Epiphany.Character.ISAAC:GetInventory),
-- кучки ??? (Epiphany.Character.BLUEBABY:GetSaveData, лужи «Creep (TrBB)»), формы Иуды (Epiphany.PlayerType.JUDAS1…5),
-- синие сломанные сердца (Epiphany:AddBlueBrokenHearts); свои события мода — удар мешком Каина (CAIN_POST_BAG_HIT,
-- CAIN_POST_SWING_HIT), удар кулаком и бросок валуна Самсона (SAMSON_PRE_DAMAGE_ENTITY, SAMSON_POST_THROW_BOULDER).
-- Две функции мода обёрнуты (рост гниения ISAAC.AddRot и наполнение шкалы SAMSON.AddTokens) — только множитель
-- и событие, остальное делает сам мод. Глитчнутый гапер — 10.404 (content/entities2.xml), «золотые» враги Хранителя —
-- враги с Midas freeze (KEEPER:LoseCoins). Деревья — tools/pst_talents_spec.py; автотест — tools/lua/pst_test_ep.lua.
local V = {}

function V.init(C, H)
	local mod, game, M, S, roll, play = C.mod, C.game, C.M, C.S, C.roll, C.play
	local enemy, player0, safe, rng, T, fireExtra = C.enemy, C.player0, C.safe, C.rng, C.T, C.fireExtra
	local darkHearts = C.darkHearts

	S.ep = S.ep or {}
	local F = S.ep
	local later = {}
	local ALL = CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY | CacheFlag.CACHE_SPEED | CacheFlag.CACHE_LUCK
	local function now() return game:GetFrameCount() end
	local function after(n, fn) later[#later + 1] = { now() + n, fn } end
	local function refresh(p) if p then p:AddCacheFlags(ALL, true) end end

	local function ok() return Epiphany and Epiphany.PlayerType and Epiphany.RunSave end
	local function is(p, name) return ok() and p and Epiphany.PlayerType[name] ~= nil and p:GetPlayerType() == Epiphany.PlayerType[name] end
	local function isIsaac(p) return is(p, "ISAAC") end
	local function isMag(p) return is(p, "MAGDALENE") end
	local function isCain(p) return is(p, "CAIN") end
	local function isBB(p) return is(p, "BLUEBABY") end
	local function isSamson(p) return is(p, "SAMSON") end
	local function isEden(p) return is(p, "EDEN") end
	local function isLost(p) return is(p, "LOST") end
	local function isKeeper(p) return is(p, "KEEPER") end
	-- Иуда: пять форм — пять типов игрока (judas.lua: 8+ синих сломанных → JUDAS1, 4+ → JUDAS2, средняя JUDAS,
	-- 4+ сломанных → JUDAS4, 8+ → JUDAS5)
	local JFORM = { JUDAS1 = "angel", JUDAS2 = "angel", JUDAS = "neutral", JUDAS4 = "demon", JUDAS5 = "demon" }
	local function judasForm(p)
		if not (ok() and p) then return nil end
		local t = p:GetPlayerType()
		for name, form in pairs(JFORM) do
			if Epiphany.PlayerType[name] ~= nil and t == Epiphany.PlayerType[name] then return form end
		end
		return nil
	end
	local function isJudas(p) return judasForm(p) ~= nil end

	local function rs(p)
		if not (ok() and p) then return {} end
		local okk, s = pcall(Epiphany.RunSave, Epiphany, p)
		return okk and s or {}
	end
	local function fs(p)
		if not (ok() and p and Epiphany.FloorSave) then return {} end
		local okk, s = pcall(Epiphany.FloorSave, Epiphany, p)
		return okk and s or {}
	end
	local function char(name) return ok() and Epiphany.Character and Epiphany.Character[name] end
	local function roomEnemies(pos, r)
		local t = {}
		local list = pos and Isaac.FindInRadius(pos, r, EntityPartition.ENEMY) or Isaac.GetRoomEntities()
		for _, e in ipairs(list) do if enemy(e) then t[#t + 1] = e end end
		return t
	end
	local function freePos(pos) return game:GetRoom():FindFreePickupSpawnPosition(pos, 40, true) end
	local function spawnPickup(var, sub, pos)
		return Isaac.Spawn(EntityType.ENTITY_PICKUP, var, sub, freePos(pos), Vector.Zero, nil)
	end
	local function penny(pos)
		Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY, pos, RandomVector() * 2, nil)
	end
	-- деление обычному активному предмету (основной слот; как бонус Потерянного в lost.lua — Epiphany:AddActiveCharges)
	local function chargeActive(p, n, ids)
		local slots = ids and { ActiveSlot.SLOT_PRIMARY, ActiveSlot.SLOT_POCKET } or { ActiveSlot.SLOT_PRIMARY }
		for _, s in ipairs(slots) do
			local it = p:GetActiveItem(s)
			local cfg = it ~= 0 and Isaac.GetItemConfig():GetCollectible(it)
			local fits = cfg and (ids and ids[it] or (not ids and cfg.ChargeType == ItemConfig.CHARGE_NORMAL))
			if fits then
				local maxc = cfg.MaxCharges or 0
				if maxc > 0 and p:GetActiveCharge(s) < maxc then
					if Epiphany and Epiphany.AddActiveCharges then
						pcall(Epiphany.AddActiveCharges, Epiphany, p, s, n or 1)
					else
						p:SetActiveCharge(math.min(maxc, p:GetActiveCharge(s) + (n or 1)), s)
					end
					game:GetHUD():FlashChargeBar(p, s)
					play("SOUND_BEEP", 0.5, 1.2)
					return true
				end
			end
		end
		return false
	end
	local function primary(p)
		local it = p:GetActiveItem(ActiveSlot.SLOT_PRIMARY)
		if it == 0 then return 0, 0, 0 end
		local cfg = Isaac.GetItemConfig():GetCollectible(it)
		return it, p:GetActiveCharge(ActiveSlot.SLOT_PRIMARY) + p:GetBatteryCharge(ActiveSlot.SLOT_PRIMARY), cfg and cfg.MaxCharges or 0
	end
	local function primaryFull(p)
		local it, c, m = primary(p)
		return it ~= 0 and m > 0 and c >= m
	end
	local function hpNow(p) return (p:GetHearts() or 0) + (p:GetSoulHearts() or 0) + (p:GetBoneHearts() or 0) * 2 + (p:GetEternalHearts() or 0) end

	-- штрафы больших талантов: −5% урона (d), −5% к скорострельности (t), −0.1 к скорости (s)
	local DOWN = {
		d = { "lfZiCompost", "lfZiToss", "lfZmFill", "lfZmPulse", "lfZcHarvest", "lfZcMark", "lfZjDescent", "lfZjAtone",
			"lfZbSpill", "lfZsGrudge", "lfZsQuake", "lfZeRush", "lfZeSave", "lfZlMantle", "lfZlTrial", "lfZkVault", "lfZkBribe" },
		t = { "lfZiSpoils", "lfZiHoard", "lfZmHemo", "lfZmFull", "lfZcSplit", "lfZcPush", "lfZjHalo", "lfZjEmbrace", "lfZbLord",
			"lfZbGut", "lfZsMeat", "lfZsRage", "lfZeCorrupt", "lfZeBattery", "lfZlPrayer", "lfZkInterest", "lfZkMidas" },
		s = { "lfZiSwarm", "lfZmVamp", "lfZcAbel", "lfZjHorns", "lfZbSlip", "lfZbMend", "lfZsBerserk", "lfZeRainbow", "lfZlWisp",
			"lfZlGuide", "lfZkMagnet" },
	}
	local OWNER = { Zi = isIsaac, Zm = isMag, Zc = isCain, Zj = isJudas, Zb = isBB, Zs = isSamson, Ze = isEden, Zl = isLost, Zk = isKeeper }
	local function owns(p, key) local f = OWNER[key:sub(3, 4)] return f and f(p) end

	-- -------------------------------------------------------------------- Исаак: гниение, «Гниль», Гнилой кубик
	local function bd() return ok() and Epiphany.Item and Epiphany.Item.BLIGHTED_DICE end
	local function blightId() local b = bd() return b and b.BLIGHT end
	local function rotCap() local I = char("ISAAC") return I and I.ROT_CAP or 100 end
	local function rot(p) return rs(p).BD_ROT_BUILDUP or 0 end
	local function blights(p) local id = blightId() return id and p:GetCollectibleNum(id) or 0 end
	local function diceIds() local b = bd() return b and { [b.ID] = true, [b.ID2] = true } end

	-- -------------------------------------------------------------------- Магдалина
	local function bleed(p) return rs(p).BleedingHeartsCount or 0 end
	local function bonusHp(p) return rs(p).TRMagdaleneBonusHearts or 0 end
	local function fullRed(p) return (p:GetMaxHearts() or 0) > 0 and (p:GetHearts() or 0) >= (p:GetEffectiveMaxHearts() or 0) end

	-- -------------------------------------------------------------------- ???: кучки и лужи
	local function bbSave(p)
		local B = char("BLUEBABY")
		if not (B and B.GetSaveData) then return nil end
		local okk, s = pcall(B.GetSaveData, B, p)
		return okk and s or nil
	end
	local function creepInfo() local B = char("BLUEBABY") return B and B.CREEP end
	local function creeps()
		local cr = creepInfo()
		if not (cr and cr.Variant) then return {} end
		return Isaac.FindByType(EntityType.ENTITY_EFFECT, cr.Variant, -1, false, false)
	end
	local function inCreep(p)
		local cr = creepInfo()
		for _, c in ipairs(creeps()) do
			local e = c:ToEffect()
			if e and c.Position:Distance(p.Position) <= (e.Scale or 1) * (cr.BASE_RADIUS or 16) then return true end
		end
		return false
	end
	local function stock(p)
		local s = bbSave(p)
		if not s then return 0 end
		return #(s.Poops or {}) + (s.MixedPoop and 1 or 0)
	end
	local function refill(p, n)
		local s = bbSave(p)
		local B = char("BLUEBABY")
		local top = s and s.Poops and s.Poops[1]
		if not top then return false end
		local cap = B and B.MAX_POOP_NOTCHES or 8
		if (top.Amount or 0) >= cap then return false end
		top.Amount = math.min(cap, (top.Amount or 0) + (n or 1))
		play("SOUND_PLOP", 0.6, 1.1)
		return true
	end

	-- -------------------------------------------------------------------- Самсон: шкала бойни
	local function bar(p) return fs(p).SamsonBar end
	local function tier(p) local b = bar(p) return b and b.Tier or 1 end

	-- -------------------------------------------------------------------- Хранитель
	local function golden(e) return e and e:HasEntityFlags(EntityFlag.FLAG_MIDAS_FREEZE) end
	local function isGlitch(e) return e and e.Type == 10 and e.Variant == 404 end

	-- ==================================================================== обёртки функций мода
	local function wrap()
		local I = char("ISAAC")
		if I and I.AddRot then
			local orig = I.lfOrigAddRot or I.AddRot
			I.lfOrigAddRot = orig
			I.AddRot = function(self, player, buildUp, dis, ...)
				if player and isIsaac(player) and type(buildUp) == "number" and buildUp > 0 then
					if M("lfZiSlow") > 0 then buildUp = buildUp * (1 - math.min(90, M("lfZiSlow")) / 100) end   -- «Консервация»
					if M("lfZiSwarm") > 0 then                                                                       -- «Гнилой рой»
						player:AddBlueFlies(3, player.Position, nil)
						play("SOUND_BOIL_HATCH", 0.5, 1.1)
					end
				end
				return orig(self, player, buildUp, dis, ...)
			end
		end
		local SA = char("SAMSON")
		if SA and SA.AddTokens then
			local orig = SA.lfOrigAddTokens or SA.AddTokens
			SA.lfOrigAddTokens = orig
			SA.AddTokens = function(self, player, tokens, ...)
				if player and isSamson(player) and type(tokens) == "number" and tokens > 0 and M("lfZsFill") > 0 then
					tokens = tokens * (1 + M("lfZsFill") / 100)                                                   -- «Мясник»
				end
				return orig(self, player, tokens, ...)
			end
		end
	end

	-- ==================================================================== события мешка Каина и кулаков Самсона
	local function onBagHit(p, bag, ent)
		if not (p and isCain(p) and ent and enemy(ent)) then return end
		local d = ent:GetData()
		d.lfBagHitAt = now()
		if roll(M("lfZcStun")) then ent:AddConfusion(EntityRef(p), 60, false) end                           -- «Бум по голове»
		if M("lfZcPush") > 0 and ent.Mass < 100 and bag then                                               -- «Железный мешок»
			ent:AddVelocity((ent.Position - bag.Position):Resized(12))
		end
		if M("lfZcMark") > 0 then                                                                           -- «Каинова печать»
			d.lfMarkUntil = now() + 90
			ent:SetColor(Color(1, 0.75, 0.75, 1, 0.3, 0.05, 0.05), 90, 1, true, false)
		end
		if M("lfZcSplit") > 0 and bag then                                                                  -- «Лопнувший шов»
			F.ccSplit = F.ccSplit or {}
			local h = GetPtrHash(bag)
			if not F.ccSplit[h] or now() - F.ccSplit[h] > 20 then
				F.ccSplit[h] = now()
				for i = 0, 3 do
					local dir = Vector(1, 0):Rotated(i * 90 + 45)
					fireExtra(p, ent.Position + dir * (ent.Size + 14), dir * 9, 0.6)
				end
				play("SOUND_TEARS_FIRE", 0.5, 1.2)
			end
		end
	end
	local CB = {}
	local function addCB(name, fn)
		local cb = Epiphany.ExtraCallbacks and Epiphany.ExtraCallbacks[name]
		if not (cb and Epiphany.AddExtraCallback) then return end
		Epiphany:AddExtraCallback(cb, fn)
		CB[#CB + 1] = { cb, fn }
	end
	local function hookEP()
		if not ok() or F.hooked then return end
		F.hooked = true
		wrap()
		-- после luamod: старые обработчики — прочь
		local old = rawget(_G, "LOCALFIXES_EP_CB")
		if old and Epiphany.RemoveExtraCallback then
			for _, c in ipairs(old) do pcall(Epiphany.RemoveExtraCallback, Epiphany, c[1], c[2]) end
		end
		addCB("CAIN_POST_BAG_HIT", safe("epBagHit", function(_, bag, ent, data)
			local p = data and data.PlayerOwner
			p = p and p:ToPlayer() or player0()
			onBagHit(p, bag, ent)
		end))
		addCB("CAIN_POST_SWING_HIT", safe("epSwingHit", function(_, bag, ent, p)
			onBagHit(p and p:ToPlayer(), bag, ent)
		end))
		-- «Хук»: множитель удара кулаком и прыжка (складывается с другими множителями мода)
		addCB("SAMSON_PRE_DAMAGE_ENTITY", safe("epPunch", function(p)
			if p and isSamson(p) and M("lfZsPunch") > 0 then return { Multiply = M("lfZsPunch") / 100 } end
		end))
		-- «Камнепад»: урон брошенного валуна
		addCB("SAMSON_POST_THROW_BOULDER", safe("epBoulder", function(p, boulder)
			if p and boulder and isSamson(p) and M("lfZsRock") > 0 then
				boulder.CollisionDamage = boulder.CollisionDamage * (1 + M("lfZsRock") / 100)
			end
		end))
		rawset(_G, "LOCALFIXES_EP_CB", CB)
	end

	-- ==================================================================== крючки
	function H.dmgMult(ent, p, se, amount, flags)
		if not ok() then return 1 end
		local mult = 1
		local d = ent:GetData()
		if d.lfMarkUntil and now() < d.lfMarkUntil then mult = mult * 1.25 end                          -- «Каинова печать»
		if isCain(p) then
			local bag = se and GetPtrHash(se) == GetPtrHash(p)           -- мешок бьёт с источником-игроком (throwing_bag.lua)
			local scatter = se and se:ToTear() and se.SpawnerEntity and GetPtrHash(se.SpawnerEntity) == GetPtrHash(p)
			if bag then
				mult = mult * (1 + M("lfZcBag") / 100)                                                     -- «Тяжёлый мешок»
				if p:GetMovementInput():Length() > 0.1 or p.Velocity:Length() > 1 then
					mult = mult * (1 + M("lfZcSwing") / 100)                                               -- «Размах»
				end
			end
			if scatter then mult = mult * (1 + M("lfZcScatter") / 100) end                                -- «Россыпь»
			if ent.HitPoints < ent.MaxHitPoints / 2 then mult = mult * (1 + M("lfZcSharp") / 100) end      -- «Острый камень»
		end
		if isBB(p) and se then
			local cr = creepInfo()
			if cr and se.Type == EntityType.ENTITY_EFFECT and se.Variant == cr.Variant then
				mult = mult * (1 + M("lfZbCreep") / 100)                                                   -- «Ядовитые отходы»
			end
			if M("lfZbLord") > 0 and se.Type == EntityType.ENTITY_FAMILIAR and se.Variant == FamiliarVariant.BLUE_FLY then
				mult = mult * 2                                                                             -- «Повелитель мух»
			end
		end
		if isEden(p) and isGlitch(ent) then mult = mult * (1 + M("lfZeGlitch") / 100) end                 -- «Охотник на глитчи»
		if isLost(p) and ent:IsBoss() then mult = mult * (1 + M("lfZlBoss") / 100) end                     -- «Гнев свыше»
		if isKeeper(p) and golden(ent) then mult = mult * (1 + M("lfZkGold") / 100) end                     -- «Золотое касание»
		return mult
	end

	function H.tear(tear, p)
		if not ok() then return end
		if isBB(p) and roll(M("lfZbStink")) then                                                            -- «Вонь»
			tear:AddTearFlags(TearFlags.TEAR_POISON)
			tear.Color = Color(0.5, 0.9, 0.4, 1, 0, 0.15, 0)
		end
		if isEden(p) and roll(M("lfZeStatic")) then                                                         -- «Помехи»
			tear:AddTearFlags(TearFlags.TEAR_CONFUSION)
			tear.Color = Color(0.7, 0.7, 0.9, 1, 0.15, 0.15, 0.25)
		end
		if isLost(p) and roll(M("lfZlHoly")) then                                                           -- «Святой свет»
			tear:AddTearFlags(TearFlags.TEAR_LIGHT_FROM_HEAVEN)
			tear.Color = Color(1, 1, 0.8, 1, 0.3, 0.3, 0.15)
		end
	end

	function H.onHurt(p, amount, flags, src)
		if not ok() or flags & DamageFlag.DAMAGE_FAKE ~= 0 then return end
		if isMag(p) then
			if roll(M("lfZmClot")) then                                                                       -- «Свёртываемость»
				local before = bleed(p)
				after(1, function()
					local s = rs(p)
					if (s.BleedingHeartsCount or 0) > before then s.BleedingHeartsCount = s.BleedingHeartsCount - 1 end
				end)
			end
			if M("lfZmPulse") > 0 then                                                                        -- «Пульс»
				after(1, function()
					for i = 0, 7 do
						local t = fireExtra(p, p.Position, Vector(10, 0):Rotated(i * 45), 1)
						if t then t:ChangeVariant(TearVariant.BLOOD) end
					end
					play("SOUND_HEARTOUT", 0.6, 1.1)
				end)
			end
		end
		local jf = judasForm(p)
		if jf == "angel" and M("lfZjHalo") > 0 and not F.jdHaloRoom then                                   -- «Пепельный нимб»
			F.jdHaloRoom = true
			p:SetMinDamageCooldown(30)
			play("SOUND_HOLY_MANTLE", 0.5, 1.2)
			return false
		end
		if isBB(p) and M("lfZbSpill") > 0 then                                                              -- «Разлив»
			after(1, function()
				local c = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.PLAYER_CREEP_GREEN, 0, p.Position, Vector.Zero, p):ToEffect()
				if c then
					c.CollisionDamage = p.Damage
					c.SpriteScale = Vector(2, 2)
					c.Scale = 2
					c:Update()
				end
			end)
		end
		if isSamson(p) and tier(p) >= 3 and roll(M("lfZsSkin")) then                                        -- «Толстая шкура»
			p:SetMinDamageCooldown(30)
			play("SOUND_ROCK_CRUMBLE", 0.5, 1.4)
			return false
		end
		if isEden(p) and M("lfZeSave") > 0 and not F.edSaveFloor and hpNow(p) <= amount then              -- «Сохранение»
			F.edSaveFloor = true
			if (p:GetMaxHearts() or 0) > 0 then p:AddHearts(4) else p:AddSoulHearts(4) end
			p:SetMinDamageCooldown(60)
			play("SOUND_POWERUP_SPEWER", 0.6, 1.2)
			return false
		end
		if isLost(p) and roll(M("lfZlDodge")) then                                                          -- «Бесплотность»
			p:SetMinDamageCooldown(30)
			play("SOUND_HOLY_MANTLE", 0.4, 1.4)
			return false
		end
		if isKeeper(p) and (M("lfZkVault") > 0 or M("lfZkPiggy") > 0) then
			-- KEEPER:LoseCoins (позже в этом же уроне) снимает монеты сразу, а выпадающие раскладывает по следующим
			-- кадрам — окно «не выпадать» ставится уже сейчас
			local c0 = p:GetNumCoins()
			local vault = M("lfZkVault") > 0 and not F.kpVaultRoom                                               -- «Сейф»
			if vault then F.kpVaultRoom, F.kpNoDropUntil = true, now() + 20 end
			after(1, function()
				local lost = c0 - p:GetNumCoins()
				if lost <= 0 then
					if vault then F.kpVaultRoom, F.kpNoDropUntil = nil, nil end   -- удар не прошёл — «Сейф» цел
					return
				end
				if vault then
					if lost > 5 then p:AddCoins(lost - 5) play("SOUND_CASH_REGISTER", 0.5, 1.2) end
				elseif M("lfZkPiggy") > 0 then                                                                  -- «Копилка»
					local back = math.floor(lost * M("lfZkPiggy") / 100 + 0.5)
					if back > 0 then p:AddCoins(back) play("SOUND_PENNYPICKUP", 0.5, 1.2) end
				end
			end)
		end
	end

	function H.cache(p, flag)
		local dmg, tears, luck, speed = 0, 0, 0, 0
		if not ok() then return dmg, tears, luck, speed end
		if isIsaac(p) then
			dmg = dmg + M("lfZiBlight") * math.min(10, rs(p).lfBlightEaten or 0)                             -- «Пожиратель гнили»
			if rot(p) < rotCap() / 2 then tears = tears + M("lfZiFresh") end                                 -- «Свежесть»
			dmg = dmg + M("lfZiHeld") * blights(p)                                                          -- «Плесень в карманах»
			if M("lfZiToss") > 0 then dmg = dmg + 5 * (F.ziToss or 0) end                                   -- «Удачный бросок»
		end
		if isMag(p) then
			dmg = dmg + M("lfZmOver") * math.min(12, bonusHp(p))                                             -- «Переполнение»
			if bleed(p) > 0 then tears = tears + M("lfZmRush") end                                           -- «Адреналин»
			dmg = dmg + M("lfZmFury") * math.min(8, bleed(p))                                                -- «Кровавая ярость»
			if M("lfZmFull") > 0 and fullRed(p) then dmg = dmg + 15 end                                      -- «Материнская любовь»
		end
		if isCain(p) and M("lfZcAbel") > 0 and now() < (F.ccAbelUntil or 0) then dmg = dmg + 20 end      -- «Братоубийство»
		local jf = judasForm(p)
		if jf then
			dmg = dmg + M("lfZjDark") * math.min(6, darkHearts(p))                                           -- «Чёрная кровь»
			tears = tears + M("lfZjMourn") * math.min(8, (p:GetBrokenHearts() or 0))                                -- «Скорбь»
			if jf == "neutral" then dmg = dmg + M("lfZjBalance") end                                         -- «Равновесие»
			if jf == "demon" then
				dmg = dmg + M("lfZjFallen")                                                                   -- «Падший»
				if M("lfZjHorns") > 0 then dmg = dmg + 25 end                                                 -- «Рога»
			end
		end
		if isBB(p) then
			dmg = dmg + M("lfZbStock") * math.min(6, stock(p))                                               -- «Запасы»
			if F.bbWade then dmg = dmg + M("lfZbWade") end                                                    -- «Вброд»
		end
		if isSamson(p) then
			dmg = dmg + M("lfZsTier") * math.max(0, tier(p) - 1)                                             -- «Кровожадность»
			if M("lfZsBerserk") > 0 and tier(p) >= 5 then dmg = dmg + 25 end                                -- «Берсерк»
		end
		if isEden(p) then
			dmg = dmg + M("lfZeHoard") * math.min(6, math.floor(p:GetCollectibleCount() / 5))               -- «Собрание»
			if M("lfZeRush") > 0 and now() < (F.edRushUntil or 0) then dmg = dmg + 15 end                  -- «Первое впечатление»
			local rb = rs(p).lfRainbow                                                                         -- «Радуга»
			if M("lfZeRainbow") > 0 and type(rb) == "table" then
				dmg, tears, luck = dmg + 5 * (rb[1] or 0), tears + 5 * (rb[2] or 0), luck + 0.5 * (rb[3] or 0)
			end
		end
		if isLost(p) then
			local it, c = primary(p)
			if it ~= 0 then dmg = dmg + M("lfZlFaith") * math.min(12, c) end                                -- «Вера»
			if primaryFull(p) then
				tears = tears + M("lfZlReady")                                                                -- «Готовность»
				if M("lfZlGuide") > 0 then dmg = dmg + 20 end                                                 -- «Путеводный свет»
			end
		end
		if isKeeper(p) then
			local k = math.min(6, math.floor(p:GetNumCoins() / 20))
			dmg = dmg + M("lfZkGreed") * k                                                                    -- «Жадность»
			tears = tears + M("lfZkHustle") * k                                                               -- «Суета»
		end
		for _, key in ipairs(DOWN.d) do if M(key) > 0 and owns(p, key) then dmg = dmg - 5 end end
		for _, key in ipairs(DOWN.t) do if M(key) > 0 and owns(p, key) then tears = tears - 5 end end
		for _, key in ipairs(DOWN.s) do if M(key) > 0 and owns(p, key) then speed = speed - 0.1 end end
		return dmg, tears, luck, speed
	end

	function H.onKill(npc, p, pos)
		if not ok() then return end
		if isIsaac(p) and M("lfZiSpoils") > 0 and npc:IsBoss() and not F.ziSpoilRoom then                  -- «Новый лист»
			F.ziSpoilRoom = true
			local s = rs(p)
			s.BD_ROT_BUILDUP = math.floor((s.BD_ROT_BUILDUP or 0) / 2 * 100) / 100
			play("SOUND_HOLY", 0.4, 1.3)
			refresh(p)
		end
		if isMag(p) then
			if M("lfZmHemo") > 0 and bleed(p) > 0 then                                                        -- «Кровоизлияние»
				local c = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.PLAYER_CREEP_RED, 0, pos, Vector.Zero, p):ToEffect()
				if c then
					c.CollisionDamage = p.Damage
					c.SpriteScale = Vector(1.5, 1.5)
					c:Update()
				end
			end
			if M("lfZmVamp") > 0 then                                                                         -- «Вампир»
				F.mgKills = (F.mgKills or 0) + 1
				local s = rs(p)
				if F.mgKills % 15 == 0 and (s.BleedingHeartsCount or 0) > 0 then
					s.BleedingHeartsCount = s.BleedingHeartsCount - 1
					play("SOUND_VAMP_GULP", 0.5, 1.1)
				end
			end
		end
		if isCain(p) then
			local hit = npc:GetData().lfBagHitAt
			if hit and now() - hit <= 3 then                                                                  -- убит мешком
				if M("lfZcHarvest") > 0 and roll(10) then spawnPickup(PickupVariant.PICKUP_NULL, 0, pos) end   -- «Жатва»
				if M("lfZcAbel") > 0 then F.ccAbelUntil = now() + 150 refresh(p) end                          -- «Братоубийство»
			end
		end
		if isJudas(p) and roll(M("lfZjSilver")) then penny(pos) end                                          -- «Тридцать монет»
		if isBB(p) then
			if roll(M("lfZbFlies")) then p:AddBlueFlies(1, pos, nil) end                                      -- «Мухи»
			if M("lfZbGut") > 0 then                                                                          -- «Нутро»
				F.bbKills = (F.bbKills or 0) + 1
				if F.bbKills % 10 == 0 then refill(p, 1) end
			end
		end
		if isSamson(p) then
			if roll(M("lfZsRoar")) then                                                                       -- «Рёв»
				for _, en in ipairs(roomEnemies(pos, 120)) do en:AddFear(EntityRef(p), 90) end
				play("SOUND_MONSTER_ROAR_0", 0.4, 1.3)
			end
			if M("lfZsQuake") > 0 and tier(p) >= 4 then                                                       -- «Землетрясение»
				for _, en in ipairs(roomEnemies(pos, 100)) do
					if GetPtrHash(en) ~= GetPtrHash(npc) then en:TakeDamage(p.Damage * 2, DamageFlag.DAMAGE_CRUSH, EntityRef(p), 0) end
				end
				game:SpawnParticles(pos, EffectVariant.ROCK_PARTICLE, 6, 4)
				game:ShakeScreen(6)
			end
		end
		if isEden(p) then
			if roll(M("lfZeBug")) then p:AddBlueSpider(pos) end                                              -- «Баг-репорт»
			if M("lfZeCorrupt") > 0 and isGlitch(npc) then                                                    -- «Повреждение»
				for _, en in ipairs(roomEnemies(pos, 90)) do
					if GetPtrHash(en) ~= GetPtrHash(npc) then en:TakeDamage(p.Damage * 3, DamageFlag.DAMAGE_EXPLOSION, EntityRef(p), 0) end
				end
				local fx = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.BOMB_EXPLOSION, 0, pos, Vector.Zero, nil)
				fx.Color = Color(0.6, 1, 0.8, 1, 0.1, 0.4, 0.3)
				play("SOUND_EXPLOSION_WEAK", 0.6, 1.3)
			end
		end
		if isKeeper(p) then
			if roll(M("lfZkTithe")) then penny(pos) end                                                       -- «Десятина»
			if M("lfZkMidas") > 0 and golden(npc) then penny(pos) end                                         -- «Мидас»
		end
	end

	-- первый вход в комнату — функцией: автотест подставляет «да» (стартовая комната)
	function V.firstVisit() return game:GetRoom():IsFirstVisit() end

	function H.onRoom()
		F.ziSpoilRoom, F.jdHaloRoom, F.kpVaultRoom, F.bbMendRoom, F.bbMendT = nil, nil, nil, 0, 0
		local p = player0()
		if not (ok() and p) then return end
		local room = game:GetRoom()
		if isEden(p) and V.firstVisit() then
			if roll(M("lfZeCoin")) then spawnPickup(PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY, p.Position) end   -- «Мелочь»
			if roll(M("lfZeCharge")) then chargeActive(p, 1) end                                               -- «Скачок»
			if M("lfZeBattery") > 0 then chargeActive(p, 1) end                                                 -- «Разгон»
			if M("lfZeRush") > 0 and not room:IsClear() then F.edRushUntil = now() + 150 refresh(p) end       -- «Первое впечатление»
		end
	end

	-- тип комнаты — функцией: автотест подставляет комнату мини-босса («Испытание»)
	function V.roomType() return game:GetRoom():GetType() end

	function H.onClear(p)
		if not ok() then return end
		local pos = game:GetRoom():GetCenterPos()
		if isIsaac(p) then
			if roll(M("lfZiDice")) then chargeActive(p, 1, diceIds()) end                                      -- «Шулерский кубик»
			if roll(M("lfZiRotten")) then spawnPickup(PickupVariant.PICKUP_HEART, HeartSubType.HEART_ROTTEN, pos) end   -- «Гнилая удача»
		end
		if isMag(p) and roll(M("lfZmHeart")) then spawnPickup(PickupVariant.PICKUP_HEART, HeartSubType.HEART_FULL, pos) end   -- «Большое сердце»
		if isCain(p) and roll(M("lfZcSack")) then spawnPickup(PickupVariant.PICKUP_NULL, 0, pos) end         -- «Бережливость»
		if isJudas(p) and roll(M("lfZjDeal")) then spawnPickup(PickupVariant.PICKUP_HEART, HeartSubType.HEART_BLACK, pos) end   -- «Тёмная сделка»
		if isBB(p) and roll(M("lfZbRefill")) then refill(p, 1) end                                          -- «Пополнение»
		if isLost(p) then
			if roll(M("lfZlCharge")) then chargeActive(p, 1) end                                              -- «Батарейный блок»
			local rt = V.roomType()
			if M("lfZlTrial") > 0 and (rt == RoomType.ROOM_MINIBOSS or rt == RoomType.ROOM_CHALLENGE) then chargeActive(p, 1) end   -- «Испытание»
		end
	end

	function H.onLevel(p)
		F.ziToss, F.edSaveFloor = 0, nil
		if not ok() then return end
		local jf = judasForm(p)
		if jf then
			if M("lfZjAtone") > 0 and (p:GetBrokenHearts() or 0) > 0 then                                            -- «Искупление»
				if (Epiphany.GetBlueBrokenHearts and Epiphany:GetBlueBrokenHearts(p) or 0) > 0 and Epiphany.AddBlueBrokenHearts then
					Epiphany:AddBlueBrokenHearts(p, -1)
				else
					p:AddBrokenHearts(-1)
				end
				play("SOUND_SUPERHOLY", 0.4, 1.2)
			end
			if M("lfZjEmbrace") > 0 then p:AddBlackHearts(2) end                                               -- «Объятие тьмы»
		end
		if isSamson(p) and M("lfZsGrudge") > 0 and (F.ssTier or 1) >= 2 then                                 -- «Злопамятность»
			after(2, function()
				local b = bar(p)
				if b and (b.Tier or 1) < 2 then
					b.Tier, b.Tokens = 2, 1
					F.ssTier = 2
					refresh(p)
				end
			end)
		end
		if isEden(p) and M("lfZeRainbow") > 0 then                                                           -- «Радуга»
			local s = rs(p)
			s.lfRainbow = type(s.lfRainbow) == "table" and s.lfRainbow or { 0, 0, 0 }
			local i = rng:RandomInt(3) + 1
			s.lfRainbow[i] = (s.lfRainbow[i] or 0) + 1
			play("SOUND_POWERUP1", 0.5, 1.2)
		end
		if isLost(p) and M("lfZlMantle") > 0 then                                                            -- «Вторая мантия»
			after(3, function() p:GetEffects():AddCollectibleEffect(CollectibleType.COLLECTIBLE_HOLY_MANTLE, true) end)
		end
		if isKeeper(p) then
			local add = 0
			if M("lfZkInterest") > 0 then add = add + math.min(15, math.floor(p:GetNumCoins() * 0.1)) end   -- «Проценты»
			if M("lfZkBribe") > 0 then add = add + 7 end                                                      -- «Взятка»
			if add > 0 then p:AddCoins(add) play("SOUND_CASH_REGISTER", 0.5, 1) end
		end
		refresh(p)
	end

	function H.onStart(cont)
		later = {}
		F.hooked = nil
		hookEP()
		F.ziToss, F.ziBlights, F.ziHoard, F.mgBonus, F.mgMax, F.ccAbelUntil, F.ccSplit = 0, nil, nil, nil, nil, nil, {}
		F.jdType, F.jdHaloRoom, F.bbWade, F.bbMendT, F.bbMendRoom, F.ssTier, F.ssRage = nil, nil, false, 0, 0, nil, nil
		F.edRushUntil, F.edSaveFloor, F.kpVaultRoom, F.kpNoDropUntil, F.kpHaggle, F.sig = nil, nil, nil, nil, nil, nil
		if not cont then F.mgKills, F.bbKills = 0, 0 end
	end

	-- ==================================================================== свои обработчики
	mod:AddCallback(ModCallbacks.MC_POST_UPDATE, safe("epLater", function()
		if #later == 0 then return end
		local t, keep = now(), {}
		for _, j in ipairs(later) do
			if t >= j[1] then pcall(j[2]) else keep[#keep + 1] = j end
		end
		later = keep
	end))

	-- Исаак: «Пожиратель гнили» — «Гниль», скормленная кубику; «Удачный бросок»
	mod:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, safe("epPreUse", function(_, it, _, p, flags)
		if not (ok() and p and isIsaac(p)) then return end
		local ids = diceIds()
		if not (ids and ids[it]) or (flags or 0) & UseFlag.USE_CARBATTERY ~= 0 then return end
		local I = char("ISAAC")
		local okk, inv = pcall(I.GetInventory, I, p)
		if okk and inv and inv.items and inv.items[inv.selected] == blightId() then
			local s = rs(p)
			s.lfBlightEaten = (s.lfBlightEaten or 0) + 1
			after(1, function() refresh(p) end)
		end
	end))
	mod:AddCallback(ModCallbacks.MC_USE_ITEM, safe("epUse", function(_, it, _, p, flags)
		if not (ok() and p) then return end
		local ids = diceIds()
		if isIsaac(p) and ids and ids[it] and M("lfZiToss") > 0 and (F.ziToss or 0) < 5 then
			F.ziToss = (F.ziToss or 0) + 1
			refresh(p)
		end
		-- Потерянный: «Молитва», «Огоньки» — только сам предмет игрока (не повтор и не чужой вызов)
		if isLost(p) and (flags or 0) & UseFlag.USE_OWNED ~= 0 and (flags or 0) & UseFlag.USE_CARBATTERY == 0 then
			if M("lfZlPrayer") > 0 then
				for i = 0, 7 do
					local t = fireExtra(p, p.Position, Vector(10, 0):Rotated(i * 45), 1)
					if t then
						t:AddTearFlags(TearFlags.TEAR_SPECTRAL | TearFlags.TEAR_HOMING)
						t.Color = Color(1, 1, 0.85, 1, 0.35, 0.35, 0.2)
					end
				end
				play("SOUND_HOLY", 0.5, 1.2)
			end
			if M("lfZlWisp") > 0 then
				local okw = pcall(p.AddWisp, p, it, p.Position)
				if not okw then pcall(p.AddWisp, p, CollectibleType.COLLECTIBLE_BOOK_OF_VIRTUES, p.Position) end
			end
		end
	end))

	-- Хранитель: «Торг» — покупка возвращает 2 монеты
	function V.haggleTouch(pk, coll)   -- касание магазинного подбора (автотест зовёт напрямую)
		local p = coll and coll:ToPlayer()
		if not (p and isKeeper(p) and M("lfZkHaggle") > 0 and pk:IsShopItem() and pk.Price > 0) then return end
		if F.kpHaggle and now() - F.kpHaggle < 4 then return end
		F.kpHaggle = now()
		local c0 = p:GetNumCoins()
		after(2, function()
			if p:GetNumCoins() < c0 and roll(M("lfZkHaggle")) then
				p:AddCoins(2)
				play("SOUND_CASH_REGISTER", 0.5, 1.3)
			end
		end)
	end
	mod:AddCallback(ModCallbacks.MC_PRE_PICKUP_COLLISION, safe("epHaggle", function(_, pk, coll) V.haggleTouch(pk, coll) end))

	-- Хранитель: «Сейф» — монеты, которые выпали бы от удара, не выпадают (их стоимость уже вернули)
	mod:AddCallback(ModCallbacks.MC_POST_PICKUP_INIT, safe("epVaultDrop", function(_, pk)
		if not (F.kpNoDropUntil and now() <= F.kpNoDropUntil) then return end
		local sp = pk.SpawnerEntity and pk.SpawnerEntity:ToPlayer()
		if sp and isKeeper(sp) then pk:Remove() end
	end), PickupVariant.PICKUP_COIN)

	-- Хранитель: «Монетный магнит»
	mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, safe("epMagnet", function(_, pk)
		local p = player0()
		if not (p and isKeeper(p) and M("lfZkMagnet") > 0) then return end
		if pk:IsShopItem() or pk.FrameCount < 20 or pk:GetSprite():IsPlaying("Collect") then return end
		local dir = p.Position - pk.Position
		if dir:Length() < 8 then return end
		local v = pk.Velocity + dir:Resized(1.2)
		if v:Length() > 9 then v = v:Resized(9) end
		pk.Velocity = v
	end), PickupVariant.PICKUP_COIN)

	-- кадр игрока: счётчики, шкалы, смена формы
	mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("epFrame", function(_, p)
		if not ok() or p.Index ~= player0().Index then return end
		if not F.hooked then hookEP() end
		local sig
		if isIsaac(p) then
			local b = blights(p)
			if F.ziBlights and b > F.ziBlights and M("lfZiCompost") > 0 then                                  -- «Компост»
				p:AddHearts(2)
				play("SOUND_VAMP_GULP", 0.5, 1)
			end
			F.ziBlights = b
			if M("lfZiHoard") > 0 then                                                                        -- «Барахольщик»
				local pd = p:GetData()
				local I = char("ISAAC")
				local okk, inv = pcall(I.GetInventory, I, p)
				if okk and inv and not pd.lfHoard then
					pd.lfHoard = true
					inv.cap = inv.cap + 1
					if I.GetInventorySprites then
						local oks, spr = pcall(I.GetInventorySprites, I, inv)
						if oks and spr then pd.TARNISHED_ISAAC_INVENTORY_SPRITES = spr end
					end
				end
			end
			sig = table.concat({ b, rs(p).lfBlightEaten or 0, rot(p) < rotCap() / 2 and 1 or 0 }, ":")
		elseif isMag(p) then
			local bh, mx = bonusHp(p), (p:GetMaxHearts() or 0)
			if F.mgBonus then
				if bh > F.mgBonus and roll(M("lfZmSoft")) then                                                -- «Нежность»
					local s = rs(p)
					s.TRMagdaleneBonusHearts = bh + (bh - F.mgBonus)
					bh = s.TRMagdaleneBonusHearts
				end
				-- запас ушёл в контейнер (magdalene.lua: −порог, +1 контейнер) — запас меньше прежнего при новом контейнере
				if M("lfZmFill") > 0 and bh < F.mgBonus and F.mgMax and mx > F.mgMax then                 -- «Переливание»
					p:AddSoulHearts(2)
					play("SOUND_HOLY", 0.5, 1.2)
				end
			end
			F.mgBonus, F.mgMax = bh, mx
			sig = table.concat({ math.min(12, bh), math.min(8, bleed(p)), fullRed(p) and 1 or 0 }, ":")
		elseif isCain(p) then
			sig = now() < (F.ccAbelUntil or 0) and 1 or 0
		elseif isJudas(p) then
			local t = p:GetPlayerType()
			if F.jdType and t ~= F.jdType and M("lfZjDescent") > 0 then                                       -- «Нисхождение»
				for _, en in ipairs(roomEnemies()) do en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
				local fx = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.POOF02, 1, p.Position, Vector.Zero, nil)
				fx.Color = Color(0.3, 0.1, 0.3, 1, 0.2, 0, 0.2)
				game:ShakeScreen(8)
				play("SOUND_DEATH_CARD", 0.6, 0.9)
			end
			F.jdType = t
			sig = table.concat({ t, math.min(6, darkHearts(p)), math.min(8, (p:GetBrokenHearts() or 0)) }, ":")
		elseif isBB(p) then
			if now() % 5 == 0 then F.bbWade = inCreep(p) end
			if M("lfZbSlip") > 0 and now() % 10 == 0 then                                                      -- «Скользко»
				local cr = creepInfo()
				for _, c in ipairs(creeps()) do
					local e = c:ToEffect()
					for _, en in ipairs(roomEnemies(c.Position, (e and e.Scale or 1) * (cr.BASE_RADIUS or 16))) do
						en:AddSlowing(EntityRef(p), 15, 0.6, Color(0.7, 0.6, 0.45, 1, 0, 0, 0))
					end
				end
			end
			if M("lfZbMend") > 0 and F.bbWade and (F.bbMendRoom or 0) < 2 then                               -- «Целебная лужа»
				F.bbMendT = (F.bbMendT or 0) + 1
				if F.bbMendT >= 300 then
					F.bbMendT, F.bbMendRoom = 0, (F.bbMendRoom or 0) + 1
					if (p:GetMaxHearts() or 0) > 0 then p:AddHearts(1) else p:AddSoulHearts(1) end
					play("SOUND_VAMP_GULP", 0.5, 1.2)
				end
			end
			sig = table.concat({ math.min(6, stock(p)), F.bbWade and 1 or 0 }, ":")
		elseif isSamson(p) then
			local tr = tier(p)
			if F.ssTier and tr > F.ssTier and M("lfZsMeat") > 0 then p:AddHearts(1) end                      -- «Мясо»
			F.ssTier = tr
			local s = rs(p)
			local cd = s.SamsonImmortalCountdown or 0
			if cd > 1 and not F.ssRage then                                                                   -- «Неугасимый»
				F.ssRage = true
				if M("lfZsRage") > 0 then
					s.SamsonImmortalCountdown = cd * 1.5
					if s.SamsonImmortalCountdownFull then s.SamsonImmortalCountdownFull = s.SamsonImmortalCountdownFull * 1.5 end
				end
			elseif cd <= 1 then
				F.ssRage = nil
			end
			sig = tr
		elseif isEden(p) then
			sig = table.concat({ math.min(6, math.floor(p:GetCollectibleCount() / 5)), now() < (F.edRushUntil or 0) and 1 or 0 }, ":")
		elseif isLost(p) then
			local it, c = primary(p)
			sig = table.concat({ it, math.min(12, c), primaryFull(p) and 1 or 0 }, ":")
		elseif isKeeper(p) then
			sig = math.min(6, math.floor(p:GetNumCoins() / 20))
		end
		if sig ~= nil and sig ~= F.sig then F.sig = sig refresh(p) end
	end))

	T.EP = V
	V.S = F
	V.H = H        -- для автотеста
	V.rs, V.fs, V.tier, V.bleed, V.stock = rs, fs, tier, bleed, stock
	return V
end

return V
