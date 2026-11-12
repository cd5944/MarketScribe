-- Character snapshot: realm, faction, money, professions, bag and bank contents.
-- Read-only.

local _, ns = ...
local MS = ns.MS

local function professions()
  local out = {}
  if GetProfessions then
    local ok, p1, p2, arch, fish, cook, aid = pcall(GetProfessions)
    if ok then
      for _, idx in ipairs({ p1, p2, arch, fish, cook, aid }) do
        if idx then
          local okI, name, _, rank, maxRank, _, _, skillLine = pcall(GetProfessionInfo, idx)
          if okI and name then out[name] = { skill = rank, max = maxRank, skillLine = skillLine } end
        end
      end
    end
  end
  if not next(out) and GetNumSkillLines then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
      if name and not isHeader then out[name] = { skill = rank, max = maxRank } end
    end
  end
  return out
end

local function containerCounts(bags)
  local counts = {}
  if not (C_Container and C_Container.GetContainerNumSlots) then return counts end
  for _, bag in ipairs(bags) do
    local okN, slots = pcall(C_Container.GetContainerNumSlots, bag)
    for slot = 1, (okN and slots or 0) do
      local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
      if ok and info and info.itemID then
        counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
      end
    end
  end
  return counts
end

local function bagIDs()
  local ids = {}
  for b = 0, (NUM_BAG_SLOTS or 4) + ((NUM_REAGENTBAG_SLOTS or 0)) do ids[#ids + 1] = b end
  return ids
end

local function bankIDs()
  local ids = { BANK_CONTAINER or -1 }
  local first = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0) + 1
  for b = first, first + (NUM_BANKBAGSLOTS or 6) - 1 do ids[#ids + 1] = b end
  if REAGENTBANK_CONTAINER then ids[#ids + 1] = REAGENTBANK_CONTAINER end
  return ids
end

local function rec()
  local db = MarketScribeDB.characters
  local key = MS.CharKey()
  db[key] = db[key] or {}
  return db[key]
end

local function snapshot()
  local c = rec()
  c.meta = MS.Meta()
  c.level = UnitLevel("player")
  c.class = select(2, UnitClass("player"))
  c.race = select(2, UnitRace("player"))
  c.money = GetMoney()
  c.professions = professions()
  c.bags = containerCounts(bagIDs())
  c.bagsAt = time()
end

local f = CreateFrame("Frame")
MS.RegisterEvents(f, { "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "BANKFRAME_OPENED", "PLAYERBANKSLOTS_CHANGED" })
local bankOpen = false
f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LOGOUT" then
    pcall(snapshot)
  elseif event == "BANKFRAME_OPENED" or (event == "PLAYERBANKSLOTS_CHANGED" and bankOpen) then
    bankOpen = true
    C_Timer.After(0.5, function()
      local c = rec()
      local ok, counts = pcall(containerCounts, bankIDs())
      if ok then c.bank, c.bankAt = counts, time() end
    end)
  end
end)
local closer = CreateFrame("Frame")
MS.RegisterEvents(closer, { "BANKFRAME_CLOSED" })
closer:SetScript("OnEvent", function() bankOpen = false end)
