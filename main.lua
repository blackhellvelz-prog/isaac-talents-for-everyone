-- Talents for Everyone — таланты Passive Skill Trees для всех персонажей игры и модов (автор blackhellvelz): свои ветки
-- и механики у каждого обычного и порченого персонажа игры, у персонажей Fiend Folio, Furtherance, Lost and
-- Forgotten, IPECAC и потускневших Epiphany; общие таланты. Мод Мастерской собирается tools/build_workshop.py.
LOCALFIXES = LOCALFIXES or {}
if LOCALFIXES.AllInOne then
	Isaac.DebugString("[Talents for Everyone] пропуск: стоит общая сборка localfixes")
	return
end
local mod = RegisterMod("Talents for Everyone", 1)
LOCALFIXES.Mod = mod
local ok, r = pcall(include, "pst_talents")
if not ok then Isaac.DebugString("[Talents for Everyone] pst_talents: " .. tostring(r)) end
-- деревья — после загрузки всех модов (Passive Skill Trees грузится позже)
if ModCallbacks.MC_POST_MODS_LOADED then
	mod:AddCallback(ModCallbacks.MC_POST_MODS_LOADED, function()
		if LOCALFIXES.InstallPSTTalents then pcall(LOCALFIXES.InstallPSTTalents) end
	end)
end
