-- Profession capture. Read-only: when you open a profession window, records every
-- recipe the client lists (learned and, where the client exposes them, unlearned),
-- with reagents, output item and quantity range, difficulty and source text.

local _, ns = ...
local MS = ns.MS
local TS = C_TradeSkillUI

local function reagentList(schematic)
  local out = {}
  for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
    local first = slot.reagents and slot.reagents[1]
    local r = {
      itemID = first and first.itemID, currencyID = first and first.currencyID,
      qty = slot.quantityRequired, reagentType = slot.reagentType,
      slotType = slot.dataSlotType, required = slot.required and 1 or 0,
    }
    if slot.reagents and #slot.reagents > 1 then
      r.alternatives = {}
      for _, alt in ipairs(slot.reagents) do
        r.alternatives[#r.alternatives + 1] = alt.itemID or alt.currencyID
        MS.RecordItem(alt.itemID)
      end
    end
    MS.RecordItem(r.itemID)
    out[#out + 1] = r
  end
  return out
end

local function captureRecipe(id, categories)
  local info = TS.GetRecipeInfo(id)
  if not info then return end
  local rec = {
    name = info.name, learned = info.learned and 1 or 0, categoryID = info.categoryID,
    difficulty = info.relativeDifficulty, skillUps = info.numSkillUps,
    disabled = info.disabled and 1 or nil, disabledReason = info.disabledReason,
    type = info.type, maxTrivialLevel = info.maxTrivialLevel,
  }
  local ok, sch = pcall(TS.GetRecipeSchematic, id, false)
  if ok and sch then
    rec.outputItemID = sch.outputItemID
    rec.qtyMin, rec.qtyMax = sch.quantityMin, sch.quantityMax
    rec.recipeType = sch.recipeType
    rec.reagents = reagentList(sch)
    MS.RecordItem(sch.outputItemID)
  end
  local okLink, link = pcall(TS.GetRecipeItemLink, id)
  if okLink and link then
    rec.link = link:match("|H([^|]+)|h")
    if not rec.outputItemID then rec.outputItemID = MS.ItemIDFromLink(link) end
  end
  if not info.learned and TS.GetRecipeSourceText then
    local okSrc, src = pcall(TS.GetRecipeSourceText, id)
    if okSrc then rec.source = src end
  end
  if info.categoryID and not categories[info.categoryID] then
    local okCat, cat = pcall(TS.GetCategoryInfo, info.categoryID)
    if okCat and cat then categories[info.categoryID] = cat.name end
  end
  return rec
end

local function capture()
  if not TS then return end
  for _, check in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
    if TS[check] then
      local ok, yes = pcall(TS[check])
      if ok and yes then return end -- only record this character's own professions
    end
  end
  local okBase, base = pcall(TS.GetBaseProfessionInfo)
  if not okBase or not base then return end
  local prof = base.parentProfessionName or base.professionName
  if not prof or prof == "" then return end
  local okChild, child = pcall(TS.GetChildProfessionInfo)
  local skill = (okChild and child and child.skillLevel) or base.skillLevel
  local maxSkill = (okChild and child and child.maxSkillLevel) or base.maxSkillLevel

  -- Forever reports 0 here; fall back to the character skill list (GetProfessions)
  if not skill or skill == 0 then
    local c = MarketScribeDB.characters[MS.CharKey()]
    local p = c and c.professions and c.professions[prof]
    if p then skill, maxSkill = p.skill, p.max end
  end

  local ids, allRecipes
  if TS.GetAllRecipeIDs then
    ids, allRecipes = TS.GetAllRecipeIDs(), true
  else
    ids, allRecipes = TS.GetFilteredRecipeIDs(), false
  end
  if not ids or #ids == 0 then return end

  local recipes, categories = {}, {}
  local learned, errors = 0, 0
  for _, id in ipairs(ids) do
    local ok, rec = pcall(captureRecipe, id, categories)
    if ok and rec then
      recipes[id] = rec
      if rec.learned == 1 then learned = learned + 1 end
    else
      errors = errors + 1
    end
  end

  local char = MS.CharKey()
  local db = MarketScribeDB.professions
  db[char] = db[char] or {}
  local prev = db[char][prof]
  db[char][prof] = {
    meta = MS.Meta(), professionID = base.profession, skill = skill, maxSkill = maxSkill,
    allRecipes = allRecipes, count = #ids, learned = learned, errors = errors,
    categories = categories, recipes = recipes,
  }
  if not prev or prev.learned ~= learned or prev.count ~= #ids then
    MS.Print(("%s recorded: %d recipes, %d learned%s"):format(prof, #ids, learned,
      allRecipes and "" or " (filtered list; clear profession filters for full coverage)"))
  end
end

local f = CreateFrame("Frame")
MS.RegisterEvents(f, { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_CLOSE" })
local open, pending = false, false
f:SetScript("OnEvent", function(_, event)
  if event == "TRADE_SKILL_CLOSE" then open = false return end
  if event == "TRADE_SKILL_SHOW" then open = true end
  if open and not pending then
    pending = true
    C_Timer.After(1, function()
      pending = false
      if open then
        local ok, err = pcall(capture)
        if not ok then MS.Log("tradeskill capture error: " .. tostring(err)) end
      end
    end)
  end
end)
