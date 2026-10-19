-- localfixes/pst/fu_talents.lua — механики деревьев PST шести персонажей Furtherance (18.10, слова пользователя:
-- «Таланты персонажам модов тебе тоже надо будет сделать если не сделал»): Лия (Обновитель сердец, сломанные и
-- испуганные сердца), Порченая Лия (24 контейнера, наступающие сломанные сердца, Разбитое сердце и острые сердца),
-- Пётр (Ключи от Царства: пощада врагов и боссов, души), Порченый Пётр (вода, погружение врагов, Мутный крест),
-- Мириам (Полидипсия, водовороты, Бубен), Порченая Мириам (костяные сердца, аура страха, Духовная рана, Цепная
-- молния). Всё — через данные и функции самого Furtherance (scripts/furtherance/characters/*): Furtherance:GetData,
-- RunSave/FloorSave, Item.KEYS_TO_THE_KINGDOM (перехват GrantRaptureStats / SkillIssue), Character.PETER_B.FLIP,
-- Character.MIRIAM.WHIRLPOOL, Item.POLYDIPSIA, Item.POLARITY_SHIFT. Деревья — tools/pst_talents_spec.py; источники —
-- docs/sources/pst_furtherance.md. Подключение — pst_talents.lua (крючки, как у pst/vanilla_talents.lua).
local V = {}

function V.init(C, H)
	local mod, game, M, S, roll, play = C.mod, C.game, C.M, C.S, C.roll, C.play
	local enemy, player0, safe, rng, T, fireExtra = C.enemy, C.player0, C.safe, C.rng, C.T, C.fireExtra

	S.fu = S.fu or {}
	local F = S.fu                       -- состояние модуля (комната/этаж/забег — сбрасывается в крючках)
	local later = {}
	local ALL = CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_FIREDELAY | CacheFlag.CACHE_SPEED | CacheFlag.CACHE_LUCK
	local function now() return game:GetFrameCount() end
	local function after(n, fn) later[#later + 1] = { now() + n, fn } end
	local function refresh(p) if p then p:AddCacheFlags(ALL, true) end end
	local function same(a, b) return a and b and GetPtrHash(a) == GetPtrHash(b) end
	local function FU() return Furtherance end
	local function fdata(e) local fu = FU() return fu and e and fu:GetData(e) or {} end
	local function ftry(e) local fu = FU() return fu and e and fu:TryGetData(e) end
	local function ptype(p, name)
		local fu = FU()
		return fu and fu.PlayerType and p and fu.PlayerType[name] and p:GetPlayerType() == fu.PlayerType[name]
	end
	local function isLeah(p) return ptype(p, "LEAH") end
	local function isLeahB(p) return ptype(p, "LEAH_B") end
	local function isPeter(p) return ptype(p, "PETER") end
	local function isPeterB(p) return ptype(p, "PETER_B") end
	local function isMiriam(p) return ptype(p, "MIRIAM") end
	local function isMiriamB(p) return ptype(p, "MIRIAM_B") end
	local function item(name) local fu = FU() return fu and fu.Item and fu.Item[name] end
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
	local function runSave(p) local fu = FU() return fu and fu.RunSave and fu:RunSave(p) or {} end
	local function redHearts(p) return (p:GetHearts() or 0) + (p:GetRottenHearts() or 0) * 2 end

	-- -------------------------------------------------------------------- Порченый Пётр: изнанка комнаты
	local function FLIP() local fu = FU() return fu and fu.Character and fu.Character.PETER_B and fu.Character.PETER_B.FLIP end
	local function flipActive() local fl = FLIP() return fl and fl:IsEnemyFlipActive() or false end
	local function submerged(e) local d = ftry(e) return d and d.PeterFlipped end
	-- удар «без источника» (сквозь воду): Сила погружённого врага срезает 25% — вернуть, чтобы число было честным
	local function waterHit(en, dmg)
		local fl = FLIP()
		local sf = fl and fl.STATUS_EFFECTS and fl.STATUS_EFFECTS.STRENGTH_FLAG
		if sf and StatusEffectLibrary and StatusEffectLibrary:GetStatusEffectData(en, sf) then dmg = dmg / 0.75 end
		en:TakeDamage(dmg, 0, EntityRef(nil), 0)
	end
	-- погрузить врага (как SEPARATE_SIDES:BringEnemyToFlipside в separate_sides.lua: тот файл ничего не возвращает,
	-- поэтому то же самое — здесь: метка изнанки, всплеск, заморозка на 30 кадров, Сила)
	local function submerge(ent)
		local fl = FLIP()
		if not fl then return end
		local data = fdata(ent)
		fl:FlipEnemy(ent)
		local fx = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.BIG_SPLASH, 0, ent.Position, Vector.Zero, nil)
		fx.Color = Color(1, 0.3, 0.3, 0.75)
		fx.SpriteScale = Vector(ent.Size / 25, ent.Size / 25)
		play("SOUND_WAR_LAVA_SPLASH", 0.5, 0.8)
		ent:AddFreeze(EntityRef(ent), 30)
		local old = ent.EntityCollisionClass
		ent.EntityCollisionClass = EntityCollisionClass.ENTCOLL_NONE
		if ent.GridCollisionClass > GridCollisionClass.COLLISION_SOLID then
			data.PeterFlipOGGridColl = ent.GridCollisionClass
			ent.GridCollisionClass = GridCollisionClass.COLLISION_SOLID
		end
		local se = fl.STATUS_EFFECTS
		local SEL = StatusEffectLibrary
		if se and SEL then
			SEL:AddStatusEffect(ent, se.STRENGTH_FLAG, -1, EntityRef(nil))
			local cfg = SEL.StatusConfig and SEL.StatusConfig[se.STRENGTH_NAME]
			if cfg then ent:SetColor(cfg.Color, 32, 1, false, false) end
		end
		data.PeterJustFlipped = true
		after(30, function()
			data.PeterJustFlipped = false
			if ent:Exists() then ent.EntityCollisionClass = old end
		end)
	end
	V.submerge = submerge
	local function crossEffect()
		local mc = item("MUDDLED_CROSS")
		return mc and game:GetRoom():GetEffects():GetCollectibleEffect(mc.ID)
	end

	-- -------------------------------------------------------------------- Мириам: водовороты и святая вода
	local function WH() local fu = FU() return fu and fu.Character and fu.Character.MIRIAM and fu.Character.MIRIAM.WHIRLPOOL end
	local HOLY = EffectVariant.PLAYER_CREEP_HOLYWATER_TRAIL
	local function inHoly(p, pos, extra)
		for _, c in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, HOLY)) do
			if same(c.SpawnerEntity, p) and c.Position:Distance(pos) <= math.max(20, c.Size) + (extra or 0) then return true end
		end
		return false
	end

	-- -------------------------------------------------------------------- Порченая Мириам: аура страха, молния
	local function chain(p) local ps = item("POLARITY_SHIFT") return ps and ps:IsChainLightningActive(p) end
	local function auraRadius(p)
		local fu = FU()
		local mb = fu and fu.Character and fu.Character.MIRIAM_B
		if not mb then return 47 end
		return mb.FEAR_BASE_RADIUS * (mb.FEAR_BASE_SCALE + (p:GetHearts() or 0) * mb.FEAR_SCALE_PER_HEART)
	end

	-- -------------------------------------------------------------------- Пётр: перехват Ключей от Царства
	-- KEYS_TO_THE_KINGDOM:GrantRaptureStats(player, rng, n, isTemp) — прибавки пощады (временные — за обычного врага,
	-- постоянные — за босса), :SkillIssue(player) — удар во время пощады босса отодвигает её на треть
	local function hookFU()
		local kt = item("KEYS_TO_THE_KINGDOM")
		if not kt or kt.lfHooked then return end
		kt.lfHooked = true
		local origGrant, origSkill = kt.GrantRaptureStats, kt.SkillIssue
		kt.GrantRaptureStats = function(self, player, r, n, isTemp, ...)
			local res = origGrant(self, player, r, n, isTemp, ...)
			if F.ptInGrant or not isPeter(player) then return res end
			F.ptInGrant = true
			pcall(function()
				if isTemp then
					if roll(M("lfPtGrace")) then origGrant(self, player, r, 1, true) end                     -- «Благодать»
					if M("lfPtGate") > 0 then                                                                 -- «Врата»
						F.ptSpared = (F.ptSpared or 0) + (n or 1)
						while F.ptSpared >= 10 do
							F.ptSpared = F.ptSpared - 10
							origGrant(self, player, r, 1, false)
							play("SOUND_HOLY", 0.6)
						end
					end
				elseif roll(M("lfPtHeaven")) then                                                            -- «Щедрость небес»
					origGrant(self, player, r, 1, false)
				end
			end)
			F.ptInGrant = false
			return res
		end
		kt.SkillIssue = function(self, player, ...)
			if isPeter(player) and roll(M("lfPtForgive")) then                                               -- «Прощение»
				play("SOUND_HOLY", 0.4, 1.3)
				return
			end
			return origSkill(self, player, ...)
		end
	end
	local function rapture(e)
		local kt = item("KEYS_TO_THE_KINGDOM")
		return kt and StatusEffectLibrary and StatusEffectLibrary:GetStatusEffectData(e, kt.STATUS_RAPTURE)
	end

	-- -------------------------------------------------------------------- острое испуганное сердце (Разбитое сердце)
	local function sharpHeart(p, pos)
		local pk = Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, HeartSubType.HEART_SCARED, pos,
			EntityPickup.GetRandomPickupVelocity(pos, rng), p):ToPickup()
		if not pk then return end
		fdata(pk).ShatteredHeartPickup = true                  -- так помечает их сам Furtherance (shattered_heart.lua)
		pk:GetSprite().Color = Color(0.5, 0.5, 0.5)
		pk.Timeout = 300
		return pk
	end

	-- ==================================================================== крючки
	-- урон сердец Разбитого сердца идёт от самих сердец (у взорванных нет хозяина) — засчитать Порченой Лие
	function H.altSource(se)
		if se and se.Type == EntityType.ENTITY_PICKUP and se.Variant == PickupVariant.PICKUP_HEART then
			local p = player0()
			if isLeahB(p) then return p end
		end
	end

	function H.dmgMult(ent, p, se, amount, flags)
		local mult = 1
		if isLeahB(p) then
			local d = fdata(p)
			if M("lfLbMend") > 0 then                                                                         -- «Заживление»
				d.LeahBBrokenDamage = (d.LeahBBrokenDamage or 0) + math.min(ent.HitPoints, amount) * M("lfLbMend") / 100
			end
			local sd = se and se.Type == EntityType.ENTITY_PICKUP and se.Variant == PickupVariant.PICKUP_HEART and ftry(se)
			if sd and sd.ShatteredHeartPickup then
				if M("lfLbSharp") > 0 then mult = mult * (1 + M("lfLbSharp") / 100) end                     -- «Острые сердца»
				if M("lfLbBond") > 0 and not sd.lfBond then                                                   -- «Кровная связь»
					sd.lfBond = true
					p:AddHearts(1)
					play("SOUND_VAMP_GULP", 0.4, 1.3)
				end
			end
			if M("lfLbBlast") > 0 and se and se.Type == EntityType.ENTITY_PICKUP and flags & DamageFlag.DAMAGE_EXPLOSION ~= 0 then
				mult = mult * (1 + M("lfLbBlast") / 100)                                                      -- «Сердечный взрыв»
			end
			if roll(M("lfLbScared")) and (F.lbSharpAt or 0) <= now() and ent:ToNPC() then                  -- «Колкие сердца»
				F.lbSharpAt = now() + 15
				local pos = ent.Position
				after(1, function() sharpHeart(p, pos) end)
			end
		end
		if isPeterB(p) then
			if M("lfPbDrown") > 0 and submerged(ent) then mult = mult * (1 + M("lfPbDrown") / 100) end      -- «Утопленник»
		end
		if isMiriam(p) and se and se.Type == EntityType.ENTITY_EFFECT then
			local wh = WH()
			if wh and se.Variant == wh.ID and M("lfMmPool") > 0 then mult = mult * (1 + M("lfMmPool") / 100) end   -- «Омут»
			if se.Variant == HOLY and M("lfMmCreep") > 0 then mult = mult * (1 + M("lfMmCreep") / 100) end         -- «Святая вода»
		end
		if isMiriam(p) and M("lfMmDrench") > 0 and inHoly(p, ent.Position, ent.Size) then
			mult = mult * (1 + M("lfMmDrench") / 100)                                                         -- «Промокший»
		end
		if isMiriamB(p) then
			if M("lfMbFeared") > 0 and ent:HasEntityFlags(EntityFlag.FLAG_FEAR) then mult = mult * (1 + M("lfMbFeared") / 100) end
			if M("lfMbReach") > 0 and ent.Position:Distance(p.Position) > 120 then mult = mult * (1 + M("lfMbReach") / 100) end
			if M("lfMbSteal") > 0 and flags & DamageFlag.DAMAGE_LASER ~= 0 and not chain(p) then              -- «Кровопийца»
				local d = fdata(p)
				d.MiriamBLifeSteal = (d.MiriamBLifeSteal or 0) + math.min(ent.HitPoints, amount) * M("lfMbSteal") / 100
			end
		end
		return mult
	end

	function H.tear(tear, p)
		if isLeah(p) and roll(M("lfLhCharm")) then                                                            -- «Жажда любви»
			tear:AddTearFlags(TearFlags.TEAR_CHARM)
			tear.Color = Color(1, 0.55, 0.75, 1, 0.3, 0, 0.15)
		end
		if isMiriam(p) and roll(M("lfMmEddy")) then                                                           -- «Лишний водоворот»
			fdata(tear).MiriamWhirlpoolShot = now()
		end
	end

	function H.onKill(npc, p, pos)
		local nd = ftry(npc)
		if isLeah(p) and roll(M("lfLhScared")) then                                                           -- «Испуг»
			Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_HEART, HeartSubType.HEART_SCARED, pos, RandomVector() * 2, p)
		end
		if isPeter(p) and not (nd and nd.Raptured) and roll(M("lfPtSoul")) then                              -- «Ловец душ»
			local kt = item("KEYS_TO_THE_KINGDOM")
			if kt then
				local s = Isaac.Spawn(EntityType.ENTITY_EFFECT, kt.EFFECT, kt.SOUL, pos, RandomVector() * 5, npc)
				s.Target = p
			end
		end
		if isPeterB(p) then
			if M("lfPbDepths") > 0 and nd and nd.PeterFlipped then                                         -- «Из глубины»
				for i = 0, 5 do fireExtra(p, pos, Vector(9, 0):Rotated(i * 60), 1) end
				play("SOUND_BOSS2_BUBBLES", 0.6)
			end
			if M("lfPbSwap") > 0 and flipActive() then                                                     -- «Перевёртыш»
				local ce = crossEffect()
				if ce then ce.Cooldown = ce.Cooldown + 30 end
			end
		end
		if isMiriamB(p) and M("lfMbBolt") > 0 and chain(p) then                                             -- «Разряд»
			local best, bd = nil, 260
			for _, en in ipairs(nearby(pos, 260, npc)) do
				local d = en.Position:Distance(pos)
				if d < bd then best, bd = en, d end
			end
			if best then
				best:TakeDamage(p.Damage * 2, 0, EntityRef(p), 0)
				-- картинка разряда — лазер без хозяина, дружественный и без урона (лазер игрока ранит сам: его урон
				-- считается от игрока, даже с нулевым CollisionDamage)
				local l = Isaac.Spawn(EntityType.ENTITY_LASER, LaserVariant.ELECTRIC, LaserSubType.LASER_SUBTYPE_LINEAR, pos, Vector.Zero, nil):ToLaser()
				if l then
					l.Angle = (best.Position - pos):GetAngleDegrees()
					l.Timeout = 4
					l.CollisionDamage = 0
					l.EntityCollisionClass = EntityCollisionClass.ENTCOLL_NONE
					l.MaxDistance = bd
					l:AddEntityFlags(EntityFlag.FLAG_FRIENDLY)
				end
				play("SOUND_LASERRING_WEAK", 0.6, 1.3)
			end
		end
	end

	function H.onHurt(p, amount, flags, src)
		local se = src and src.Entity
		if isPeter(p) then
			local npc = se and se:ToNPC()
			if M("lfPtHalo") > 0 and npc and rapture(npc) then                                                -- «Нимб»
				play("SOUND_HOLY_MANTLE", 0.4, 1.2)
				return false
			end
			if M("lfPtRooster") > 0 then                                                                      -- «Петух пропел»
				F.ptHits = (F.ptHits or 0) + 1
				if F.ptHits == 3 then
					for _, en in ipairs(roomEnemies()) do en:AddFear(EntityRef(p), 120) end
					p:AddSoulHearts(2)
					play("SOUND_DOGMA_ANGEL_TRANSFORM_END", 0.6, 1.4)
					game:ShakeScreen(8)
				end
			end
		end
		if isMiriamB(p) then F.mbHurtAt = now() end
	end

	function H.cache(p, flag)
		local dmg, tears, luck, speed = 0, 0, 0, 0
		if isLeah(p) then
			dmg = dmg + M("lfLhShard") * math.min(11, (p:GetBrokenHearts() or 0))                                 -- «Осколки»
			if M("lfLhHealth") > 0 and (p:GetEffectiveMaxHearts() or 0) > 0 and redHearts(p) >= (p:GetEffectiveMaxHearts() or 0) then
				dmg = dmg + M("lfLhHealth")                                                                    -- «Полная чаша»
			end
			if M("lfLhReserve") > 0 then                                                                      -- «Сердечный запас»
				dmg = dmg + math.min(19, math.floor((runSave(p).HeartRenovatorCounter or 0) / 5))
				tears = tears - 5
			end
			if M("lfLhBreakNova") > 0 then tears = tears - 5 end
			if M("lfLhRebuild") > 0 then dmg = dmg - 5 end
			if M("lfLhComfort") > 0 then speed = speed - 0.1 end
			if M("lfLhPanic") > 0 then dmg = dmg - 5 end
		end
		if isLeahB(p) then
			local red = redHearts(p)
			if M("lfLbVital") > 0 and red >= 12 then dmg = dmg + M("lfLbVital") end                          -- «Полнокровие»
			if M("lfLbOverheart") > 0 then                                                                    -- «Сверхсердце»
				local n = math.max(0, math.floor(red / 2) - 6)
				dmg, tears, speed = dmg + 2 * n, tears + 2 * n, speed - 0.1
			end
			if M("lfLbPause") > 0 then dmg = dmg - 5 end
			if M("lfLbHeartbeat") > 0 then tears = tears - 5 end
			if M("lfLbSpare") > 0 then speed = speed - 0.1 end
			if M("lfLbBond") > 0 then dmg = dmg - 5 end
		end
		if isPeter(p) then
			dmg = dmg + M("lfPtKey") * math.min(10, p:GetNumKeys())                                         -- «Ключник»
			if M("lfPtBeam") > 0 then dmg = dmg - 5 end
			if M("lfPtSaint") > 0 then tears = tears - 5 end
			if M("lfPtRooster") > 0 then speed = speed - 0.1 end
			if M("lfPtHalo") > 0 then dmg = dmg - 5 end
			if M("lfPtGate") > 0 then dmg = dmg - 5 end
		end
		if isPeterB(p) then
			if flipActive() then dmg = dmg + M("lfPbTide") end                                              -- «Прилив»
			if M("lfPbDepths") > 0 then tears = tears - 5 end
			if M("lfPbCrash") > 0 then dmg = dmg - 5 end
			if M("lfPbCall") > 0 then speed = speed - 0.1 end
			if M("lfPbSunk") > 0 then tears = tears - 5 end
			if M("lfPbSwap") > 0 then dmg = dmg - 5 end
		end
		if isMiriam(p) then
			if M("lfMmSong") > 0 then
				tears = tears - 5
				if F.mmSongRoom then dmg = dmg + 25 end                                                       -- «Песнь Мириам»
			end
			if M("lfMmBurst") > 0 then dmg = dmg - 5 end
			if M("lfMmSea") > 0 then tears = tears - 5 end
			if M("lfMmWell") > 0 then speed = speed - 0.1 end
			if M("lfMmFlood") > 0 then dmg = dmg - 5 end
		end
		if isMiriamB(p) then
			if M("lfMbMarrow") > 0 then                                                                       -- «Костный мозг»
				dmg = dmg + 4 * (p:GetBoneHearts() or 0)
				speed = speed - 0.1
			end
			if M("lfMbDread") > 0 then tears = tears - 5 end
			if M("lfMbWail") > 0 then dmg = dmg - 5 end
			if M("lfMbSpirit") > 0 then dmg = dmg - 5 end
			if M("lfMbBolt") > 0 then tears = tears - 5 end
		end
		return dmg, tears, luck, speed
	end

	function H.onRoom()
		hookFU()
		F.mmSongRoom, F.mmWellT, F.mmWellN = nil, 0, 0
		F.pbFlip = nil
		local p = player0()
		if not p then return end
		refresh(p)
		if isPeterB(p) and M("lfPbCall") > 0 then                                                            -- «Глубинный зов»
			after(10, function()
				local fl = FLIP()
				if not fl or game:GetRoom():IsClear() or flipActive() then return end
				local list = {}
				for _, en in ipairs(roomEnemies()) do
					if fl:ValidEnemyToFlip(en) and not fl:IsFlippedEnemy(en) then list[#list + 1] = en end
				end
				if #list > 0 then submerge(list[rng:RandomInt(#list) + 1]) end
			end)
		end
		if isMiriam(p) and M("lfMmFlood") > 0 then                                                         -- «Потоп»
			after(5, function()
				local pd = item("POLYDIPSIA")
				if game:GetRoom():IsClear() or not (pd and pd.SpawnPolydipsiaCreep) then return end
				local c = pd:SpawnPolydipsiaCreep(p, p)
				if c then
					pd:UpdateCreepSize(c, 90)
					c.Timeout = 150
					play("SOUND_BOSS2_BUBBLES", 0.5)
				end
			end)
		end
	end

	function H.onClear(p)
		if isLeah(p) and roll(M("lfLhStock")) then                                                            -- «Запасливость»
			local rs = runSave(p)
			rs.HeartRenovatorCounter = math.min(99, (rs.HeartRenovatorCounter or 0) + 2)
			play("SOUND_HEARTIN", 0.5, 0.9)
			refresh(p)
		end
		if isMiriamB(p) and roll(M("lfMbBone")) then                                                          -- «Костяной венец»
			p:AddBoneHearts(1)
			play("SOUND_BONE_HEART", 0.6)
		end
	end

	function H.onLevel(p)
		F.ptHits = 0
		if isLeah(p) and M("lfLhRebuild") > 0 and (p:GetBrokenHearts() or 0) > 0 then                           -- «Перестройка»
			p:AddBrokenHearts(-1)
			local rs = runSave(p)
			rs.HeartRenovatorDamage = (rs.HeartRenovatorDamage or 0) + 1
			play("SOUND_HEARTBEAT", 0.8)
		end
		if isPeter(p) and M("lfPtSaint") > 0 then                                                           -- «Святой Пётр»
			local kt = item("KEYS_TO_THE_KINGDOM")
			if kt and p:GetActiveItem(ActiveSlot.SLOT_POCKET) == kt.ID then
				p:SetActiveCharge(kt.MAX_CHARGES, ActiveSlot.SLOT_POCKET)
			end
		end
		refresh(p)
	end

	function H.onStart(cont)
		later = {}
		hookFU()
		if not cont then F.ptSpared = 0 end
		F.ptHits, F.lhBroken, F.lhSig, F.lbBroken, F.lbCd, F.lbSig, F.pbFlip = 0, nil, nil, nil, nil, nil, nil
		F.mmCarry, F.mbHearts, F.mbBones, F.mbSteal, F.mbSig, F.ptSig = 0, nil, nil, nil, nil, nil
		F.mmSongRoom, F.mmWellT, F.mmWellN, F.lbSharpAt, F.ptBeamAt = nil, 0, 0, nil, nil
	end

	-- ==================================================================== свои обработчики
	mod:AddCallback(ModCallbacks.MC_POST_UPDATE, safe("fuLater", function()
		if #later == 0 then return end
		local f, keep = now(), {}
		for _, it in ipairs(later) do
			if it[1] <= f then pcall(it[2]) else keep[#keep + 1] = it end
		end
		later = keep
	end))

	-- Обновитель сердец (Лия): сколько сломанных сердец было до применения
	mod:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, safe("fuPreUse", function(_, it, _, p)
		local hr = item("HEART_RENOVATOR")
		if hr and it == hr.ID and p and isLeah(p) then F.lhPreUse = (p:GetBrokenHearts() or 0) end
	end))

	mod:AddCallback(ModCallbacks.MC_USE_ITEM, safe("fuUse", function(_, it, _, p)
		if not p then return end
		F.lastUse = it   -- для автотеста
		local hr, mc, tb = item("HEART_RENOVATOR"), item("MUDDLED_CROSS"), item("TAMBOURINE")
		if hr and it == hr.ID and isLeah(p) then
			local before = F.lhPreUse
			after(1, function()
				if not before or (p:GetBrokenHearts() or 0) >= before then return end                     -- сердце не снято
				if roll(M("lfLhMason")) then                                                                  -- «Каменщик»
					local rs = runSave(p)
					rs.HeartRenovatorDamage = (rs.HeartRenovatorDamage or 0) + 1
					play("SOUND_HEARTBEAT", 0.6, 1.3)
				end
				if M("lfLhComfort") > 0 then p:AddHearts(2) play("SOUND_VAMP_GULP", 0.5) end                -- «Утешение»
				refresh(p)
			end)
		end
		if mc and it == mc.ID and isPeterB(p) and M("lfPbFlipLong") > 0 then                                -- «Долгий переворот»
			-- первые ~8 кадров переворота (анимация) отсчёт держит сам мод — прибавить, когда он пошёл
			local mult = M("lfPbFlipLong") / 100
			local function add(tries)
				local ce = crossEffect()
				if not ce or ce.Cooldown <= 0 then return end
				if F.pbCdSeen and ce.Cooldown < F.pbCdSeen then
					ce.Cooldown = ce.Cooldown + math.floor((ce.Cooldown + 1) * mult)
					F.pbCdSeen = nil
				elseif tries > 0 then
					F.pbCdSeen = ce.Cooldown
					after(1, function() add(tries - 1) end)
				end
			end
			F.pbCdSeen = nil
			after(2, function() add(30) end)
		end
		if tb and it == tb.ID and isMiriam(p) then
			if M("lfMmSea") > 0 then                                                                        -- «Расступившееся море»
				local wh, n = WH(), 0
				for _, en in ipairs(nearby(p.Position, 125)) do
					if n >= 4 or not wh then break end
					n = n + 1
					wh:SpawnWhirlpool(p, en.Position)
				end
			end
			if M("lfMmSong") > 0 then F.mmSongRoom = true refresh(p) end                                   -- «Песнь Мириам»
		end
	end))

	-- подобрано испуганное сердце («Паника», Лия): столкновения с сердцами перехватывает CustomHealthAPI раньше нас,
	-- поэтому — по началу анимации подбора рядом с Лией
	mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, safe("fuScared", function(_, pk)
		if pk.SubType ~= HeartSubType.HEART_SCARED or M("lfLhPanic") <= 0 then return end
		local p = player0()
		if not (p and isLeah(p)) then return end
		local d = pk:GetData()
		if d.lfPanic or not pk:GetSprite():IsPlaying("Collect") or pk.Position:Distance(p.Position) > 80 then return end
		d.lfPanic = true
		for _, en in ipairs(roomEnemies()) do en:AddFear(EntityRef(p), 90) end
		play("SOUND_SCAMPER", 0.6, 0.8)
	end), PickupVariant.PICKUP_HEART)

	-- Мириам: водовороты дольше («Долгий водоворот»), схлопывание на исходе («Схлопывание»)
	mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, safe("fuWhirl", function(_, e)
		if not F.isMiriam then return end
		local wh = WH()
		if not wh or e.Variant ~= wh.ID then return end
		local ed = e:GetData()
		if not ed.lfMmSeen and e.Timeout > 0 then
			ed.lfMmSeen = true
			if M("lfMmLast") > 0 then e.Timeout = e.Timeout + math.floor(e.Timeout * M("lfMmLast") / 100) end
		end
		-- водоворот кончается: отсчёт дошёл до нуля (дальше мод зовёт Die — эффект исчезает сразу, «Death» не видно)
		if M("lfMmBurst") > 0 and ed.lfMmSeen and not ed.lfMmBurst and (e.Timeout <= 0 or e:GetSprite():IsPlaying("Death")) then
			ed.lfMmBurst = true
			local p = player0()
			for _, en in ipairs(nearby(e.Position, 70)) do en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
			local sp = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.BIG_SPLASH, 0, e.Position, Vector.Zero, nil)
			sp.Color = Color(0.6, 0.8, 1, 1, 0, 0.1, 0.3)
			play("SOUND_BOSS2_DIVE", 0.5, 1.2)
		end
	end))

	-- «Ужас»: круг ауры страха Порченой Мириам на экране — того же размера, что и её действие (мод ставит размер
	-- в обновлении эффекта; здесь — тот же расчёт × талант, без накопления между кадрами отрисовки)
	if ModCallbacks.MC_PRE_EFFECT_RENDER then
		mod:AddCallback(ModCallbacks.MC_PRE_EFFECT_RENDER, safe("fuAura", function(_, e)
			if e.SubType ~= 3 or M("lfMbAura") <= 0 then return end
			local d = ftry(e)
			local p = e.Parent and e.Parent:ToPlayer()
			if not (d and d.MiriamBFearAura and p and isMiriamB(p)) then return end
			local mb = FU().Character.MIRIAM_B
			local sc = (mb.FEAR_BASE_SCALE + (p:GetHearts() or 0) * mb.FEAR_SCALE_PER_HEART) * (1 + M("lfMbAura") / 100)
			e.SpriteScale = Vector(sc, sc)
		end), EffectVariant.HALO)
	end

	-- кадр игрока
	mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, safe("fuFrame", function(_, p)
		if not same(p, player0()) then return end
		F.isMiriam = isMiriam(p)
		if not FU() then return end
		local room = game:GetRoom()
		-- Лия: сломанные сердца
		if isLeah(p) then
			local b = (p:GetBrokenHearts() or 0)
			if F.lhBroken and b > F.lhBroken and M("lfLhBreakNova") > 0 then                               -- «Разлом»
				for i = 0, 7 do fireExtra(p, p.Position, Vector(10, 0):Rotated(i * 45), 1.5) end
				for _, en in ipairs(nearby(p.Position, 120)) do en:AddFear(EntityRef(p), 60) end
				play("SOUND_HEARTBEAT_FASTEST", 0.7)
			end
			F.lhBroken = b
			local sig = b .. "/" .. tostring(redHearts(p) >= (p:GetEffectiveMaxHearts() or 0)) .. "/"
				.. math.floor((runSave(p).HeartRenovatorCounter or 0) / 5)
			if sig ~= F.lhSig then F.lhSig = sig refresh(p) end
		end
		-- Порченая Лия: отсчёт сломанных сердец
		if isLeahB(p) then
			local d = fdata(p)
			local b, cd = (p:GetBrokenHearts() or 0), d.LeahBHeartDecayCountdown
			local reset = cd and F.lbCd and cd > F.lbCd
			if reset and F.lbBroken and b > F.lbBroken and M("lfLbSpare") > 0 and roll(25) then          -- «Запасное сердце»
				p:AddBrokenHearts(-1)
				b = (p:GetBrokenHearts() or 0)
				F.lbOwn = true
				game:SpawnParticles(p.Position, EffectVariant.ROCK_PARTICLE, 6, 3, Color(0.4, 0.4, 0.4, 1))
				play("SOUND_ROCK_CRUMBLE", 0.4, 1.4)
			end
			if reset and M("lfLbDelay") > 0 then                                                            -- «Отсрочка»
				cd = cd + math.floor(600 * M("lfLbDelay") / 100)
				d.LeahBHeartDecayCountdown = cd
			end
			if cd and M("lfLbPause") > 0 and room:IsClear() then                                           -- «Каменное сердце»
				cd = cd + 1
				d.LeahBHeartDecayCountdown = cd
			end
			if F.lbBroken and b < F.lbBroken and not F.lbOwn and M("lfLbHeartbeat") > 0 then              -- «Сердцебиение»
				game:MakeShockwave(p.Position, 0.03, 0.02, 10)
				for _, en in ipairs(nearby(p.Position, 130)) do en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0) end
				play("SOUND_HEARTBEAT", 1, 0.8)
			end
			F.lbOwn = nil
			F.lbBroken, F.lbCd = b, cd
			local sig = tostring(math.floor(redHearts(p) / 2))
			if sig ~= F.lbSig then F.lbSig = sig refresh(p) end
		end
		-- Пётр: ключи; пощада босса — «Терпение» (отсчёт короче), «Свет с небес» (луч в другого врага раз в 2 с)
		if isPeter(p) and M("lfPtKey") > 0 then
			local sig = tostring(math.min(10, p:GetNumKeys()))
			if sig ~= F.ptSig then F.ptSig = sig refresh(p) end
		end
		if isPeter(p) and (M("lfPtPatience") > 0 or M("lfPtBeam") > 0) and not room:IsClear() then
			local sparing, others = nil, {}
			for _, en in ipairs(roomEnemies()) do
				local st = rapture(en)
				if st then
					sparing = en
					local ed = en:GetData()
					if M("lfPtPatience") > 0 and not ed.lfPtPat and st.Countdown and st.Countdown > 0 then
						ed.lfPtPat = true
						st.Countdown = math.max(1, math.floor(st.Countdown * (1 - M("lfPtPatience") / 100)))
					end
				else
					others[#others + 1] = en
				end
			end
			if sparing and #others > 0 and M("lfPtBeam") > 0 and now() >= (F.ptBeamAt or 0) then
				F.ptBeamAt = now() + 60
				local en = others[rng:RandomInt(#others) + 1]
				Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.CRACK_THE_SKY, 1, en.Position, Vector.Zero, nil)
				en:TakeDamage(p.Damage * 3, 0, EntityRef(p), 0)
				play("SOUND_ANGEL_BEAM", 0.5)
			end
		end
		-- Порченый Пётр: погружения, конец переворота, утопление
		if isPeterB(p) then
			local fa = flipActive()
			if F.pbFlip ~= nil and fa ~= F.pbFlip then
				refresh(p)
				if F.pbFlip and not fa and M("lfPbCrash") > 0 and not room:IsClear() then                 -- «Обрушение вод»
					game:ShakeScreen(10)
					for _, en in ipairs(roomEnemies()) do waterHit(en, p.Damage * 2) end
					play("SOUND_BOSS2_DIVE", 0.7)
				end
			end
			F.pbFlip = fa
			local any = M("lfPbPull") > 0 or M("lfPbBleed") > 0 or M("lfPbCharge") > 0 or M("lfPbSunk") > 0
			if any and not fa then
				local mc = item("MUDDLED_CROSS")
				-- все враги комнаты, не только «уязвимые»: погружённый первые 30 кадров без столкновений
				for _, en in ipairs(Isaac.GetRoomEntities()) do
					local nd = en:ToNPC() and en:IsActiveEnemy(false) and not en:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) and ftry(en)
					if nd and nd.PeterFlipped then
						local ed = en:GetData()
						if not ed.lfPbSub then
							ed.lfPbSub = true
							if M("lfPbPull") > 0 then waterHit(en, p.Damage * M("lfPbPull") / 100) end   -- «Утянуть на дно»
							if roll(M("lfPbBleed")) then en:AddEntityFlags(EntityFlag.FLAG_BLEED_OUT) end                       -- «Кровь в воде»
							if mc and roll(M("lfPbCharge")) and p:GetActiveItem(ActiveSlot.SLOT_POCKET) == mc.ID then          -- «Мутная вода»
								p:AddActiveCharge(math.floor(mc.MAX_CHARGES / 10), ActiveSlot.SLOT_POCKET, false, false, true)
							end
						end
						if M("lfPbSunk") > 0 and now() % 30 == 0 then                                   -- «Камнем на дно»
							waterHit(en, math.max(1, en.MaxHitPoints * 0.03))
							if now() % 60 == 0 then
								game:SpawnParticles(en.Position, EffectVariant.TEAR_POOF_VERYSMALL, 2, 1, Color(0.6, 0.8, 1, 0.8))
							end
						end
					end
				end
			end
		end
		-- Мириам: звонкий бубен, колодец
		if isMiriam(p) then
			local tb = item("TAMBOURINE")
			if tb and M("lfMmTimbrel") > 0 and p:GetActiveItem(ActiveSlot.SLOT_POCKET) == tb.ID then        -- «Звонкий бубен»
				local ch = p:GetActiveCharge(ActiveSlot.SLOT_POCKET)
				if ch < 300 then
					F.mmCarry = (F.mmCarry or 0) + M("lfMmTimbrel") / 100
					local n = math.floor(F.mmCarry)
					if n > 0 then
						F.mmCarry = F.mmCarry - n
						p:SetActiveCharge(math.min(300, ch + n), ActiveSlot.SLOT_POCKET)
					end
				end
			end
			if M("lfMmWell") > 0 and (F.mmWellN or 0) < 2 and inHoly(p, p.Position) then                     -- «Колодец Мириам»
				F.mmWellT = (F.mmWellT or 0) + 1
				if F.mmWellT >= 300 then
					F.mmWellT, F.mmWellN = 0, (F.mmWellN or 0) + 1
					if redHearts(p) < (p:GetEffectiveMaxHearts() or 0) then
						p:AddHearts(1)
						play("SOUND_VAMP_GULP", 0.5, 1.2)
					end
				end
			end
		end
		-- Порченая Мириам: аура, кости, молния, исцеление раны
		if isMiriamB(p) then
			local r = auraRadius(p)
			if M("lfMbAura") > 0 or M("lfMbDread") > 0 then
				local far = r * (1 + M("lfMbAura") / 100)
				for _, en in ipairs(nearby(p.Position, far)) do
					if M("lfMbAura") > 0 then en:AddFear(EntityRef(p), 2) end                                  -- «Ужас»
					if M("lfMbDread") > 0 then en:AddSlowing(EntityRef(p), 2, 0.6, Color(0.7, 0.6, 0.8, 1, 0, 0, 0)) end   -- «Оцепенение»
				end
			end
			local bones, hearts = (p:GetBoneHearts() or 0), (p:GetHearts() or 0)
			if F.mbBones and bones < F.mbBones and M("lfMbWail") > 0 then                                  -- «Плач»
				for _, en in ipairs(roomEnemies()) do
					en:AddFear(EntityRef(p), 90)
					en:TakeDamage(p.Damage, 0, EntityRef(p), 0)
				end
				play("SOUND_MOTHER_SUMMON_ISAACS", 0.5, 1.2)
			end
			if F.mbHearts and hearts < F.mbHearts and chain(p) and (F.mbHurtAt or -99) < now() - 2 and roll(M("lfMbDrain")) then   -- «Стойкость»
				p:AddHearts(F.mbHearts - hearts)
				hearts = (p:GetHearts() or 0)
			end
			local d = fdata(p)
			local st = d.MiriamBLifeSteal or 0
			if F.mbSteal and st < F.mbSteal - 0.01 and M("lfMbSpirit") > 0 then                               -- «Духовное исцеление»
				for _, en in ipairs(nearby(p.Position, r)) do en:TakeDamage(p.Damage * 2, 0, EntityRef(p), 0) end
				play("SOUND_HOLY", 0.5, 0.8)
			end
			F.mbBones, F.mbHearts, F.mbSteal = bones, hearts, st
			local sig = tostring(bones)
			if M("lfMbMarrow") > 0 and sig ~= F.mbSig then F.mbSig = sig refresh(p) end
		end
	end))

	T.FU = V
	V.S = F
	return V
end

return V
