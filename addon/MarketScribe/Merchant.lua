-- Vendor capture. Read-only: records what a merchant offers when you open it.
-- These are Forever-observed inventories with real prices (including any
-- reputation discount active for this character at the time).

local _, ns = ...
local MS = ns.MS

local function npcInfo()
  local guid = UnitGUID("npc")
  if not guid then return end
  local unitType, _, _, _, _, npcID = strsplit("-", guid)
  return tonumber(npcID), UnitName("npc"), unitType
end

local function position()
  local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or not mapID then return end
  local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
  if ok2 and pos then
    local x, y = pos:GetXY()
    return mapID, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
  end
  return mapID
end

local function itemInfo(i)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C_MerchantFrame.GetItemInfo(i)
    if info then
      return info.name, info.price, info.stackCount, info.numAvailable, info.isPurchasable,
             info.isUsable, info.hasExtendedCost, info.currencyID
    end
    return
  end
  local name, _, price, stack, numAvailable, isPurchasable, isUsable, extendedCost, currencyID = GetMerchantItemInfo(i)
  return name, price, stack, numAvailable, isPurchasable, isUsable, extendedCost, currencyID
end

local function capture()
  local npcID, npcName, unitType = npcInfo()
  if not npcID then return end
  local n = GetMerchantNumItems() or 0
  local items, missing = {}, 0
  for i = 1, n do
    local ok, name, price, stack, numAvailable, _, isUsable, hasExt, currencyID = pcall(itemInfo, i)
    if ok and name then
      local link = GetMerchantItemLink(i)
      local itemID = (GetMerchantItemID and GetMerchantItemID(i)) or MS.ItemIDFromLink(link)
      if not link then missing = missing + 1 end
      local entry = {
        itemID = itemID, name = name, price = price, stack = stack,
        numAvailable = numAvailable, -- -1 means unlimited
        maxStack = GetMerchantItemMaxStack and GetMerchantItemMaxStack(i) or nil,
        usable = isUsable and 1 or 0, currencyID = currencyID,
      }
      if hasExt then
        entry.costs = {}
        for c = 1, (GetMerchantItemCostInfo(i) or 0) do
          local _, value, costLink, currencyName = GetMerchantItemCostItem(i, c)
          entry.costs[#entry.costs + 1] = {
            itemID = MS.ItemIDFromLink(costLink),
            currencyID = costLink and tonumber(costLink:match("currency:(%d+)")) or nil,
            name = currencyName, qty = value,
          }
        end
      end
      items[#items + 1] = entry
      MS.RecordItem(itemID)
    else
      missing = missing + 1
    end
  end
  local mapID, x, y = position()
  local db = MarketScribeDB.merchants
  local rec = db[npcID] or { firstSeen = time() }
  rec.name, rec.unitType, rec.mapID, rec.x, rec.y = npcName, unitType, mapID, x, y
  rec.meta = MS.Meta()
  rec.numItems = n
  rec.complete = missing == 0
  rec.items = items
  db[npcID] = rec
end

local f = CreateFrame("Frame")
MS.RegisterEvents(f, { "MERCHANT_SHOW", "MERCHANT_UPDATE", "MERCHANT_CLOSED" })
local open, pending = false, false
local function schedule(delay)
  if pending then return end
  pending = true
  C_Timer.After(delay, function()
    pending = false
    if open then pcall(capture) end
  end)
end
f:SetScript("OnEvent", function(_, event)
  if event == "MERCHANT_SHOW" then
    open = true
    pcall(capture)
    schedule(1.5) -- recapture once item data has loaded
  elseif event == "MERCHANT_UPDATE" then
    if open then schedule(0.5) end
  elseif event == "MERCHANT_CLOSED" then
    open = false
  end
end)
