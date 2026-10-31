# Strongbox

Creator: Kronic | Version 1.0.0

An inventory organizer for Shroud of the Avatar. Strongbox finds everything you own and shows it by item or by chest: your bags, your bank, every house lot and your other characters, with a total for each place and the containers inside it.

## How it finds your things

The game lets add-ons ask how many of an item you own and where, but only by the item's exact name, one item at a time. Strongbox keeps a list of every item name it knows: everything your recipes make or use, everything in your bag, anything you pick up or loot, your Crafters Ledger shopping list, and names you look up yourself. It checks each one in the background, about four a second, and saves what it finds, so the next time you open it your things show straight away.

The first scan after installing takes a few minutes (about 8 minutes for 2,000 names). After that, Strongbox only rechecks what has changed or is more than a few hours old, and counts your bag again whenever it changes. Click **Scan everything** to check every name again, or **Pause** to stop for a while.

Something no recipe uses and that you haven't carried since installing, like an old quest item, isn't on the list yet. Type its full name in the search box and click **Look up exact name**; from then on Strongbox keeps track of it.

## Pages

- **Items**: everything you own, sorted by name, amount or how many places it's in. Type any words from a name, in any order, to search. Click + to see each place with its own total and the containers in it.
- **Chests**: every bag, bank container and house chest that holds something, grouped by place. Click + to see what's inside.
- **Scattered**: items kept in more than one chest or bank container, the most spread out first, so you know what to gather up.

## Finding a chest

Stand next to a chest and click **Mark** on its line once. After that, **Compass** points the game's compass at it whenever you're in that scene; **Clear compass** stops it. Click **Name** to give any container your own name, like *Reagent Chest*. Chests you marked or named in Crafters Ledger come across on their own.

## Opening it

Click the strongbox icon, type `/strongbox`, or set a key for it under **Keys** on its row in the **Add-Ons** window.

## Installation

Import or extract the complete strongbox folder, including manifest.json and icon.png. Strongbox needs a game client with Lua API 55 or later. Your counts, marks and names are saved in Strongbox-data.tsv in the main Lua folder, so updating keeps them.
