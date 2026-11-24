# Inventory scope, repairs and Lazarus package

Local candidate 1.0.2, 2026-11-20. No game launch or save-file edit.

## Asset evidence

All 923 paths in `item-identities.json` were decoded from their existing extracted
uassets with UAssetAPI and the 0.10.0.653173 mappings. Serialized overrides were
merged with each actual item class's defaults from the reflection dump.
`inventory-assets.json` records the relevant resulting properties for every path;
the regression test requires the path sets to match exactly.

175 assets have the Buildable bit. 120 also inherit/declare inventory support;
116 are build-only, while four Nixie tube variants also have Fabricator routing.
The fix rejects those 116 without excluding the four inventory outputs. Other
inventory restrictions still apply. The user's live count of 707 is not a proven
base-game count: loaded/modded asset overrides and available targets can differ.
No fixed replacement count is hardcoded into the menu.

Native VoyageItem::IsBuildable reads CraftFilter bit 8. The native CanAddItem
routine checks target restrictions, but does not reject build-only objects. The
new predicate combines both, and is used at catalog generation and again before
every AddItem. Unknown/unreadable eligibility fails closed. AddItem's two boolean
arguments are bAllowStacking and bNotifyChanged, not eligibility bypasses.

Lazarus selection uses actual Food, FoodMaterial and Memory categories plus the
human seed, then recursively includes their Components recipes. This covers the
15 food and 10 nutrient assets in the snapshot and the available memory items.
Recipe cycles and duplicates are bounded; player-inventory eligibility is always
required. Mod recipes use their live dependencies instead of a frozen ingredient
list. The selected amount is per item type, not a promise to complete that many
humans or to supply non-inventory resources such as electricity.

## Repair evidence and boundaries

The old Nerfus Lua menu exposes BP_VoyageCheatWiget; most actions live in shipped
Blueprints. Its ubergraph contains a direct OverrideHealth(GetMaxDurability())
on BP_Module_RoomOutlet's destructible component. This is evidence for the direct
repair method, not evidence of an original single-button whole-boat repair.
Native VoyageModuleComponent::Repair instead sends negative damage to the same
component. Warden now uses the direct scalar override when the component exists,
and verifies the resulting durability. Custom modules without that component
retain their own native Repair implementation.

GetAllModules membership supplements scene attachments for boat repair. Detached
native candidates must still be in the current boat list, in the same world, and
must not have an attachment chain to a different boat. Damage references must
belong to the module's owner. Reported success requires the actual health readback.

Area repair makes one damage-component snapshot on request and inspects at most
24 entries per tick, yielding after 3 ms between entries. Individual engine calls
can exceed that time; no hard frame-time guarantee is made. Authority, world,
distance, owner, duplicate, destruction and character/vehicle filters are applied
before repair. The center is fixed when requested. World/player changes discard
old references; cancellation stops subsequent work. It restores existing health,
not deleted actors, build progress, ammunition or fuel.

`inventory-repair-abi.json` records parameter storage for the relevant reflected
calls (1–16 bytes). No oversized destructible-properties struct is passed through
UE4SS's 512-byte UFunction buffer. Native physics, mesh visuals and live save
behavior remain unverified by offline tests.
