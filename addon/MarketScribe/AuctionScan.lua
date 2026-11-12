-- Auction house capture. Read-only.
-- 1. Full replicate scans: every individual auction from C_AuctionHouse.ReplicateItems,
--    captured whenever ANY addon (normally Auctionator) or /ms fullscan triggers one.
-- 2. Commodity / item searches: the exact price ladder the AH shows when you (or
--    Auctionator) search for an item.
-- 3. Browse results: min price + total quantity per item from normal browsing.

local _, ns = ...
local MS = ns.MS
local AH = C_AuctionHouse

local BATCH = 400
local RETRY_PASSES = 6
local RETRY_DELAY = 2

local scan -- the replicate scan being captured

---------------------------------------------------------------------------
-- Full replicate scan capture
-- Row string format (comma separated):
--   itemID, keyIndex, count, buyoutTotal, minBid, minIncrement, bidAmount,
--   isHighBidder(0/1), timeLeft, quality, level, saleStatus, owner
-- buyoutTotal is for the whole stack (copper). keyIndex points into scan.keys
-- (full item strings, which carry random suffixes etc).
---------------------------------------------------------------------------
local function captureRow(s, i)
  local _, _, count, quality, _, level, _, minBid, minInc, buyout, bidAmount, highBidder,
        _, owner, ownerFull, saleStatus, itemID, hasAll = AH.GetReplicateItemInfo(i)
  if not itemID or itemID == 0 then
    s.skipped = s.skipped + 1
    return true
  end
  if not hasAll then return false, itemID end
  local link = AH.GetReplicateItemLink(i)
  local timeLeft = AH.GetReplicateItemTimeLeft(i)
  local key = (link and link:match("|H(item:[^|]+)|h")) or ("item:" .. itemID)
  local k = s.keyIndex[key]
  if not k then
    k = #s.keys + 1
    s.keys[k] = key
    s.keyIndex[key] = k
  end
  local who = (ownerFull or owner or ""):gsub(",", "")
  s.rows[i + 1] = table.concat({
    itemID, k, count or 0, buyout or 0, minBid or 0, minInc or 0, bidAmount or 0,
    highBidder and 1 or 0, timeLeft or "", quality or "", level or "", saleStatus or "", who,
  }, ",")
  s.captured = s.captured + 1
  s.itemSet[itemID] = true
  return true
end

local function finish()
  local s = scan
  if not s then return end
  scan = nil
  -- compact rows in auction order
  local rows = {}
  for i = 1, s.total do
    if s.rows[i] then rows[#rows + 1] = s.rows[i] end
  end
  local record = {
    meta = s.meta,
    total = s.total,
    captured = #rows,
    missingInfo = #s.retry,
    skipped = s.skipped,
    errors = s.errors,
    aborted = s.aborted or nil,
    triggeredBy = s.triggeredBy,
    finishedAt = time(),
    keys = s.keys,
    rows = rows,
  }
  record.complete = (not s.aborted) and record.missingInfo == 0 and s.errors == 0
    and (record.captured + record.skipped) == record.total
  local db = MarketScribeDB
  table.insert(db.scans, 1, record)
  local keep = db.settings.keepScans or 3
  while #db.scans > keep do
    local old = table.remove(db.scans)
    MS.Print(("pruned old full scan from %s (keeping %d)"):format(date("%m-%d %H:%M", old.meta.t), keep))
  end
  for itemID in pairs(s.itemSet) do MS.RecordItem(itemID) end
  local msg = ("full scan saved: %d of %d auctions, %d distinct items, complete=%s%s")
    :format(record.captured, record.total, #s.keys, tostring(record.complete),
            s.aborted and " (AH closed before capture finished)" or "")
  MS.Print(msg)
  MS.Print("type /reload (or log out) to write it to disk")
  MS.Log(msg)
end

local function retryPass()
  local s = scan
  if not s or s.aborted then return end
  local list = s.retry
  s.retry = {}
  local idx = 1
  local function step()
    if not scan or s.aborted then return end
    local stop = math.min(idx + BATCH - 1, #list)
    for j = idx, stop do
      local i = list[j]
      local ok, done, itemID = pcall(captureRow, s, i)
      if not ok then
        s.errors = s.errors + 1
      elseif not done then
        s.retry[#s.retry + 1] = i
        if itemID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
      end
    end
    idx = stop + 1
    if idx <= #list then
      C_Timer.After(0, step)
    else
      s.passes = s.passes + 1
      if #s.retry > 0 and s.passes < RETRY_PASSES then
        C_Timer.After(RETRY_DELAY, retryPass)
      else
        finish()
      end
    end
  end
  step()
end

local function processBatch()
  local s = scan
  if not s or s.aborted then return end
  local stop = math.min(s.i + BATCH, s.total)
  for i = s.i, stop - 1 do
    local ok, done, itemID = pcall(captureRow, s, i)
    if not ok then
      s.errors = s.errors + 1
    elseif not done then
      s.retry[#s.retry + 1] = i
      if itemID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    end
  end
  s.i = stop
  if s.i < s.total then
    C_Timer.After(0, processBatch)
  elseif #s.retry > 0 then
    C_Timer.After(RETRY_DELAY, retryPass)
  else
    finish()
  end
end

local lastRequest -- set when /ms fullscan triggered the scan

local function startReplicateCapture()
  if scan then return end
  local ok, n = pcall(AH.GetNumReplicateItems)
  if not ok or not n or n == 0 then
    MS.Print("replicate scan returned no auctions")
    return
  end
  scan = {
    meta = MS.Meta(), total = n, i = 0, rows = {}, keys = {}, keyIndex = {},
    retry = {}, itemSet = {}, captured = 0, skipped = 0, errors = 0, passes = 0,
    triggeredBy = (lastRequest and time() - lastRequest < 300) and "MarketScribe" or "other addon",
  }
  lastRequest = nil
  MS.Print(("capturing full scan: %d auctions (keep the AH open until it finishes)"):format(n))
  processBatch()
end

function MS.RequestFullScan()
  if not (AH and AH.ReplicateItems) then
    MS.Print("this client has no C_AuctionHouse.ReplicateItems")
    return
  end
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
    MS.Print("open the auction house first")
    return
  end
  local last = MarketScribeDB.lastReplicateRequest
  if last and time() - last < 15 * 60 then
    MS.Print(("the server allows one full scan per 15 minutes; about %d min left (other addons' scans count too)")
      :format(math.ceil((15 * 60 - (time() - last)) / 60)))
    return
  end
  MarketScribeDB.lastReplicateRequest = time()
  lastRequest = time()
  MS.Print("requesting full scan; the game may freeze for a few seconds while the server sends it")
  AH.ReplicateItems()
end

---------------------------------------------------------------------------
-- Search results (exact ladders for what you look at)
---------------------------------------------------------------------------
local function pushSearch(key, snap)
  local db = MarketScribeDB
  local list = db.searches[key]
  if not list then list = {}; db.searches[key] = list end
  -- results arrive in pages; replace a snapshot from the same minute instead of stacking
  if list[1] and snap.t - list[1].t < 60 then
    list[1] = snap
  else
    table.insert(list, 1, snap)
  end
  local keep = db.settings.keepSearches or 5
  while #list > keep do table.remove(list) end
end

-- commodity row: unitPrice, quantity, numOwnerItems, totalNumberOfOwners, timeLeftSeconds
local function captureCommodity(itemID)
  local n = AH.GetNumCommoditySearchResults(itemID) or 0
  local rows = {}
  for i = 1, n do
    local r = AH.GetCommoditySearchResultInfo(itemID, i)
    if r then
      rows[#rows + 1] = table.concat({ r.unitPrice or 0, r.quantity or 0, r.numOwnerItems or 0,
        r.totalNumberOfOwners or 0, r.timeLeftSeconds or "" }, ",")
    end
  end
  pushSearch("c:" .. itemID, {
    t = time(), kind = "commodity", itemID = itemID, n = n,
    full = AH.HasFullCommoditySearchResults(itemID) and 1 or 0,
    build = MS.Build(), rows = rows,
  })
  MS.RecordItem(itemID)
end

local function itemKeyString(k)
  return ("%d:%d:%d:%d"):format(k.itemID or 0, k.itemLevel or 0, k.itemSuffix or 0, k.battlePetSpeciesID or 0)
end

-- item row: buyoutTotal, bidAmount, minBid, quantity, timeLeft, totalNumberOfOwners, itemString
local function captureItemSearch(itemKey)
  local n = AH.GetNumItemSearchResults(itemKey) or 0
  local rows = {}
  for i = 1, n do
    local r = AH.GetItemSearchResultInfo(itemKey, i)
    if r then
      local str = r.itemLink and r.itemLink:match("|H(item:[^|]+)|h") or ""
      rows[#rows + 1] = table.concat({ r.buyoutAmount or 0, r.bidAmount or 0, r.minBid or 0,
        r.quantity or 0, r.timeLeft or "", r.totalNumberOfOwners or 0, str }, ",")
    end
  end
  pushSearch("i:" .. itemKeyString(itemKey), {
    t = time(), kind = "item", itemID = itemKey.itemID, n = n,
    full = AH.HasFullItemSearchResults(itemKey) and 1 or 0,
    build = MS.Build(), rows = rows,
  })
  MS.RecordItem(itemKey.itemID)
end

-- browse: "t,minPrice,totalQuantity" per item key, latest only
local function captureBrowse()
  local results = AH.GetBrowseResults()
  if not results then return end
  local t = time()
  local browse = MarketScribeDB.browse
  for _, r in ipairs(results) do
    if r.itemKey then
      browse[itemKeyString(r.itemKey)] = t .. "," .. (r.minPrice or 0) .. "," .. (r.totalQuantity or 0)
    end
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
MS.OnInit(function()
  if not AH then
    MS.Print("C_AuctionHouse is not available on this client; auction capture disabled")
    return
  end
  local missing = MS.RegisterEvents(f, {
    "REPLICATE_ITEM_LIST_UPDATE", "AUCTION_HOUSE_CLOSED",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  })
  if #missing > 0 then MS.Log("AH events unavailable: " .. table.concat(missing, " ")) end
end)

local browsePending = false
f:SetScript("OnEvent", function(_, event, a1)
  if event == "REPLICATE_ITEM_LIST_UPDATE" then
    startReplicateCapture()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if scan then
      scan.aborted = true
      MS.Print("AH closed during capture; saving what was captured, marked incomplete")
      finish()
    end
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    pcall(captureCommodity, a1)
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    pcall(captureItemSearch, a1)
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    if not browsePending then
      browsePending = true
      C_Timer.After(0.5, function() browsePending = false; pcall(captureBrowse) end)
    end
  end
end)
