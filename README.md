# MarketScribe

Personal economy analysis tools for WoW Forever: a small, read-only in-game addon that records market, vendor and recipe data, plus local scripts that analyze it.

Recipe, vendor and item reference data from [ForeverDB.net](https://foreverdb.net).

## What the addon records

MarketScribe is passive. It never buys, bids, posts, cancels or sells, and it doesn't modify other addons. It reads what the game client already shows and saves it to `SavedVariables/MarketScribe.lua` when you `/reload` or log out.

- Full auction house scans: every individual auction (stack size, buyout, bid, time left), captured when a full scan is triggered by Auctionator or `/ms fullscan`.
- Auction searches: exact price tiers and quantities for items you search.
- Browse results: minimum price and total quantity per item.
- Item reference: live sell price, stack size, binding, level and class.
- Vendors: inventory, prices, limited stock and extra costs when you open a merchant.
- Professions: every recipe the client lists, learned or not, with reagents, output and quantity range.
- Character: realm, faction, gold, profession skills, bag and bank counts.

Commands: `/ms status`, `/ms api`, `/ms fullscan`, `/ms keep <n>`.

## Install

Copy `addon/MarketScribe` into `World of Warcraft/_forever_/Interface/AddOns/`, then restart the game. Built for client 1.60.1 (interface 16001).

## Tools

- `tools/savedvars.py`: parses a SavedVariables file as data (it is never executed) and writes JSON.

      python -I tools/savedvars.py MarketScribe.lua out.json

## Data and credit

Reference data from ForeverDB.net is used under its API terms and is credited wherever it is shown. Game data belongs to Blizzard Entertainment. This project is not affiliated with Blizzard or ForeverDB. Personal scan data is not included in this repository.
