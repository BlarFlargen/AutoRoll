# AutoRoll

Automatic group loot rolling for World of Warcraft 3.3.5a, created using AI.

## Install

Drop the `AutoRoll` folder into `World of Warcraft/Interface/AddOns/`

## Getting started

Open the options with `/ar`.

1. `/ar class` — confirm it picked the right class and gear set.
2. `/ar trace <shift-click an item>` — shows every rule's verdict in order, so
   you can see exactly why something would be Needed or Greeded before it
   matters.

`/ar off` stops rolling entirely.

## Commands

| Command | Effect |
|---|---|
| `/ar` | open the options panel |
| `/ar on` / `off` / `toggle` | master switch |
| `/ar status` | list every rule, its priority, and whether it is on |
| `/ar test <item>` | dry run — same code path as a real roll |
| `/ar trace <item>` | every rule's verdict, and why each declined |
| `/ar class` | classes you roll gear for |
| `/ar class add\|remove\|only <class>` | change the selection |
| `/ar class auto` | back to just your own class |
| `/ar misc` | extra armor types, all weapons, offhands, level override |
| `/ar log` | roll history window |
| `/ar delay <seconds>` | how long to wait before rolling |
| `/ar need\|greed\|pass\|black add\|remove\|list <item>` | explicit item lists |
| `/ar profile use\|copy\|delete\|reset <name>` | profile management |
| `/ar probe` | dump server roll data (run during a roll) |
| `/ar debug` | verbose rule evaluation |

## Rule order

Rules run by priority; the first match wins.

```
  5 serverFilter     defers to a server loot filter, if one is configured
 10 manualQuality    leave high-quality drops to a human
 20 blacklist        never touch
 30 needList         explicit need
 40 greedList        explicit greed
 50 passList         explicit pass
 60 alreadyKnown     recipes, mounts and pets you have
 70 recipe           unknown recipes
 80 classToken       tier tokens for your class
 84 soulbind         server soulbind mechanic (inert unless configured)
 86 tooHighLevel     requires a level above yours
 89 gearType         gear any selected class can use (exhaustive)
110 lockbox
120 tradeGoods       mats, consumables, gems, glyphs
130 boe              anything sellable
999 fallback         nothing matched
```

Any rule can be switched off individually in the options panel.
