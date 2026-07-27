# AutoRoll

Automatic group loot rolling for WoW 3.3.5a (Interface 30300).

Needs gear your class can use, Greeds anything worth money, Passes the rest.
Every decision comes from an ordered list of rules — the first one that matches
wins.

## Install

Drop the `AutoRoll` folder into `World of Warcraft/Interface/AddOns/`, so you
end up with `Interface/AddOns/AutoRoll/AutoRoll.toc`. The folder name and the
`.toc` name must match.

## Getting started

Open the options with `/ar`. The defaults roll for your own class and are
sensible out of the box, but two things are worth doing before a raid:

1. `/ar class` — confirm it picked the right class and gear set.
2. `/ar trace <shift-click an item>` — shows every rule's verdict in order, so
   you can see exactly why something would be Needed or Greeded before it
   matters.

`/ar off` stops it rolling entirely.

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

## How gear is decided

**You pick classes, not armor types.** Everything a class can equip — its armor
type, weapons, shields and relics — is derived from the class. Pick several to
gear an alt or an offspec alongside your own. Anything no selected class uses
falls to the "unselected gear" actions: Greed if it is BoE, Pass if BoP.

**Armor type is level-gated, and this is the part that is easy to get wrong.**
A warrior does not learn Plate until level 40 and wears Mail before that.
Treating Plate as "the warrior type" with Mail as a fallback makes a low-level
warrior roll on armor it cannot wear while skipping the armor it can. So
`CLASS_GEAR` in `Rules.lua` records the level each type is learned at, and the
derivation picks the highest one you actually qualify for. **Ignore level
requirements** under Misc overrides this, and is on by default.

**Misc** adds individual types on top of the class selection — each armor type,
each of the fifteen weapon types, and each offhand category (shields,
held-in-off-hand, and the four relic types). Held-in-off-hand has no subclass
of its own, so it is matched by equip slot instead.

**Ignore level requirements is on by default.** The level-gated armor type is
only the right answer while you are actually levelling that character; turn it
off if you want a level-30 paladin to roll mail rather than plate.

**The gear rule is exhaustive.** Every armor and weapon item leaves rule 89
with a decision — including ones that are unusable, an unselected type, or not
really gear at all like fishing poles. The rules below it know nothing about
whether you can equip something, so a case that fell through would be handed to
a rule that might Need it.

## Design notes

**The roll delay is not cosmetic.** Rolling on the same frame the event fires
is an obvious bot signature, and some cores drop rolls that arrive before the
client has finished building the roll frame. Default 1.5s; do not set it to 0.

**Item data arrives late.** `GetItemInfo` returns nothing for an item not yet
in your local cache, which is normal at the instant a roll starts — but quality
and bind type come from the server and are always present. Deciding on that
partial picture silently skips every gear rule and drops through to a Greed, so
the queue retries until the real data lands.

**Red tooltip text is read from both columns.** Equipment tooltips put the
equip slot on the left of line 2 and the item's type on the right — and it is
the *right* string that turns red when you lack the proficiency. A left-only
scan catches "Requires Level 80" and misses every weapon restriction in the
game. Weapon and shield proficiency is client-enforced this way, so it needs no
table; armor type is *not* enforced, which is the only reason `CLASS_GEAR`
exists.

**Item classes and type names are read from the client** via
`GetAuctionItemClasses` and `GetAuctionItemSubClasses`, not hardcoded English,
so it works on a localised client. If the ordering differs on your client it
falls back to English and `/ar class` says so.

**One tooltip scanner, created once.** Frames in WoW can never be garbage
collected, so creating a `GameTooltip` inside a per-item function leaks a frame
on every loot roll.

**Disenchant rolls are off by default.** Action `3` is a Cataclysm value that
does not exist on a Blizzlike 3.3.5a core. It is gated behind both a setting
and a runtime capability check.

**Rolls are re-checked before firing.** Anything else that answers rolls — a
server-side filter, another addon, you clicking a button — may close a roll
during the delay, so the addon confirms it is still live at the moment it acts.

## Custom servers

`ServerRules.lua` is the only file you should need to edit. Register a rule
there and it automatically gets a checkbox in the options panel:

```lua
A:RegisterRule{
    key      = "myRule",
    label    = "Shown in the options panel",
    priority = 85,
    fn = function(self, ctx)
        if somethingTrue then return self.ACTION.NEED, "why" end
        -- return nil to fall through to the next rule
    end,
}
```

Add `A.defaults.rules.myRule = true` at the top of the file for the setting to
persist.

It ships with two scaffolds, both inert until configured: a Peloria soulbind
integration and a generic server loot filter deferral. For servers that answer
asynchronously, `A:AddPrefetch` fires a request when a roll starts and
`A:AddReadyCheck` makes the queue wait for the reply before deciding.

Context fields: `rollID`, `link`, `itemID`, `name`, `quality`, `iLevel`,
`reqLevel`, `itemClass`, `itemSubClass`, `maxStack`, `equipSlot`, `resolved`,
`bindOnPickUp`, `canNeed`, `canGreed`, `canDisenchant`, `isTest`.

Helpers on `self`: `IsUnusable`, `IsAlreadyKnown`, `IsClassToken`, `IsLockbox`,
`IsOffhandItem`, `GetNeedSets`, `GetNeedClasses`, `GetUpgradeDelta`,
`CountInBags`, `ListContains`, `ScanTooltip`, `Debug`.
