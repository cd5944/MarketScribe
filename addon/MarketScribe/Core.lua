-- MarketScribe: passive, read-only data recorder.
-- It never buys, bids, posts, cancels, sells, or clicks anything. It only reads
-- information the client already shows and writes it to SavedVariables.

local _, ns = ...
local MS = {}
ns.MS = MS

MS.VERSION = "0.1.0"
MS.SCHEMA = 1

local DEFAULTS = {
  keepScans = 3,        -- full replicate scans kept (each can be a few MB)
  keepSearches = 5,     -- snapshots kept per searched item
}

function MS.Print(...)
  print("|cff33ccffMarketScribe|r:", ...)
end

-- Call fn safely; returns ok, results...
function MS.Try(fn, ...)
  if type(fn) ~= "function" then return false, "missing api" end
  return pcall(fn, ...)
end

function MS.Build()
  local _, build = GetBuildInfo()
  return build
end

function MS.CharKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

function MS.Meta()
  local version, build, _, toc = GetBuildInfo()
  return {
    t = time(),
    version = version, build = build, toc = toc,
    project = WOW_PROJECT_ID,
    realm = GetRealmName(),
    faction = UnitFactionGroup("player"),
    character = UnitName("player"),
    addon = MS.VERSION, schema = MS.SCHEMA,
  }
end

-- Safe event registration: unknown events on this client are skipped, not fatal.
function MS.RegisterEvents(frame, events)
  local missing = {}
  for _, e in ipairs(events) do
    if not pcall(frame.RegisterEvent, frame, e) then missing[#missing + 1] = e end
  end
  return missing
end

---------------------------------------------------------------------------
-- Item reference cache: live client values for this build (sell price etc).
-- items[itemID] = { name, quality, itemLevel, reqLevel, classID, subclassID,
--                   maxStack, sellPrice, bindType, isCraftingReagent(0/1),
--                   equipLoc, build }
---------------------------------------------------------------------------
local GetItemInfoF = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoad = (C_Item and C_Item.RequestLoadItemDataByID) or function() end
local pendingItems, pendingCount = {}, 0

function MS.RecordItem(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 or not MarketScribeDB then return end
  local items = MarketScribeDB.items
  local existing = items[itemID]
  if existing and existing[12] == MS.Build() then return end
  local ok, name, _, quality, ilvl, reqLevel, _, _, maxStack, equipLoc, _, sellPrice,
        classID, subclassID, bindType, _, _, isReagent = pcall(GetItemInfoF, itemID)
  if not ok or not name then
    if not pendingItems[itemID] then
      pendingItems[itemID] = true
      pendingCount = pendingCount + 1
      pcall(RequestLoad, itemID)
    end
    return
  end
  items[itemID] = { name, quality, ilvl, reqLevel, classID, subclassID, maxStack,
                    sellPrice, bindType, isReagent and 1 or 0, equipLoc or "", MS.Build() }
end

function MS.ItemIDFromLink(link)
  return link and tonumber(link:match("item:(%d+)"))
end

---------------------------------------------------------------------------
-- Init and events
---------------------------------------------------------------------------
local core = CreateFrame("Frame")
MS.RegisterEvents(core, { "ADDON_LOADED", "GET_ITEM_INFO_RECEIVED" })

core:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "ADDON_LOADED" and arg1 == "MarketScribe" then
    MarketScribeDB = MarketScribeDB or {}
    local db = MarketScribeDB
    db.schema = MS.SCHEMA
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULTS) do if db.settings[k] == nil then db.settings[k] = v end end
    db.items = db.items or {}
    db.scans = db.scans or {}
    db.searches = db.searches or {}
    db.browse = db.browse or {}
    db.merchants = db.merchants or {}
    db.professions = db.professions or {}
    db.characters = db.characters or {}
    db.log = db.log or {}
    for _, fn in ipairs(MS.onInit or {}) do pcall(fn) end
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if pendingItems[arg1] then
      pendingItems[arg1] = nil
      pendingCount = pendingCount - 1
      if arg2 ~= false then MS.RecordItem(arg1) end
    end
  end
end)

function MS.OnInit(fn)
  MS.onInit = MS.onInit or {}
  table.insert(MS.onInit, fn)
end

function MS.Log(msg)
  local log = MarketScribeDB and MarketScribeDB.log
  if not log then return end
  table.insert(log, 1, date("%Y-%m-%d %H:%M:%S") .. " " .. msg)
  while #log > 100 do table.remove(log) end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

local function apiReport()
  local function has(path)
    local cur = _G
    for part in path:gmatch("[^%.]+") do
      if type(cur) ~= "table" then return false end
      cur = cur[part]
    end
    return cur ~= nil
  end
  local version, build, _, toc = GetBuildInfo()
  MS.Print(("client %s build %s toc %s project %s"):format(tostring(version), tostring(build), tostring(toc), tostring(WOW_PROJECT_ID)))
  for _, api in ipairs({
    "C_AuctionHouse.ReplicateItems", "C_AuctionHouse.GetReplicateItemInfo",
    "C_AuctionHouse.GetCommoditySearchResultInfo", "C_AuctionHouse.GetItemSearchResultInfo",
    "C_AuctionHouse.GetBrowseResults", "QueryAuctionItems",
    "C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetFilteredRecipeIDs",
    "C_TradeSkillUI.GetRecipeSchematic", "C_TradeSkillUI.GetRecipeSourceText",
    "C_MerchantFrame.GetItemInfo", "GetMerchantItemInfo", "GetMerchantItemID",
    "C_Container.GetContainerItemInfo", "GetProfessions",
  }) do
    MS.Print(("  %s %s"):format(has(api) and "yes" or "NO ", api))
  end
end

local function status()
  local db = MarketScribeDB
  MS.Print(("items %d | full scans %d | searched items %d | browse keys %d | merchants %d | pending item loads %d")
    :format(count(db.items), #db.scans, count(db.searches), count(db.browse), count(db.merchants), pendingCount))
  for i, s in ipairs(db.scans) do
    MS.Print(("  scan %d: %s  %d/%d rows  complete=%s%s"):format(i, date("%m-%d %H:%M", s.meta.t),
      s.captured or 0, s.total or 0, tostring(s.complete), s.aborted and " (AH closed early)" or ""))
  end
  for char, profs in pairs(db.professions) do
    for prof, p in pairs(profs) do
      MS.Print(("  %s %s %s/%s: %d recipes (%d learned)%s"):format(char, prof, tostring(p.skill), tostring(p.maxSkill),
        p.count or 0, p.learned or 0, p.allRecipes and "" or " [filtered list, may be incomplete]"))
    end
  end
end

SLASH_MARKETSCRIBE1 = "/ms"
SLASH_MARKETSCRIBE2 = "/marketscribe"
SlashCmdList.MARKETSCRIBE = function(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "api" then apiReport()
  elseif cmd == "fullscan" then if MS.RequestFullScan then MS.RequestFullScan() end
  elseif cmd == "keep" and tonumber(rest) then
    MarketScribeDB.settings.keepScans = math.max(1, math.min(10, tonumber(rest)))
    MS.Print("keeping", MarketScribeDB.settings.keepScans, "full scans")
  elseif cmd == "status" or cmd == "" then status()
  else
    MS.Print("/ms status | /ms api | /ms fullscan (AH must be open, 15 min cooldown) | /ms keep <n>")
  end
end
