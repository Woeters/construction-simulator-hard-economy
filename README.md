# Construction Simulator - Hard Economy

Hard Economy is an unofficial economy overhaul for the Steam PC version of
Construction Simulator. It is intended for players who want vehicle ownership,
operating costs and company progression to remain meaningful for much longer.
Its purpose is not simply to raise every number: the changes make planning,
warehouses, manual material transport and vehicle trailers useful parts of
running a company.

Current version: **0.2.1**

Author: **Thamonky**

## Download

Normal users should download the ready-to-use ZIP from the
[Releases](https://github.com/Woeters/construction-simulator-hard-economy/releases)
page. Source-code downloads do not include the third-party runtime files needed
by the ready-to-use patcher.

Updating from an earlier version? Close the game and extract the new ZIP into a
new folder. If you customized `HardEconomy-Settings.txt`, copy it from your old
patcher folder into the new one before clicking **Apply Hard Economy**. Otherwise,
the included settings will be used. Check the selected game folder before
applying. You do not need to uninstall first.

## Default economy

- Machine purchase prices: 1.3x vanilla.
- Machine rental prices: 8x vanilla.
- The first 24 hours of a rental are charged upfront.
- Fuel: 5x vanilla; maintenance: 4x vanilla.
- Regular machine transport and fast travel: 10x vanilla.
- Crane transport: 5x vanilla.
- Bulk-material prices: 1.6x vanilla.
- Building-material prices: 2x vanilla.
- Warehouse and construction-site delivery: 5x vanilla.
- Machine resale: 50% of the current purchase price.
- Instant filling: 3x vanilla; instant emptying pays nothing.
- Physical bulk resale: 18%; building-material resale: 37.5%.
- Vehicle fast travel uses the same distance-based cost calculation as travel
  to a building.
- Crane setup costs scale with the crane's value.

All settings above can be edited in `HardEconomy-Settings.txt`. Every line
shows its accepted range. Decimals use a dot, for example `1.5` or `1.55`.

The included values are a fully tested, challenging starting configuration.
Players can tune the difficulty without downloading separate Medium, Hard or
Extreme versions. Reapplying edited settings always rebuilds from a validated
original backup, so multipliers do not stack.

## Rotating sales

- Building materials can receive temporary discounts of 5%, 10%, 15%, 20% or
  25%. Better discounts generally expire sooner.
- Vehicles can receive temporary discounts of 2%, 4%, 6%, 8% or 10%. Better
  discounts generally expire sooner.
- Discounted prices and percentages are shown in the dealer interfaces.
- Sale caps and hourly sale chances are user-configurable. Both hourly chances
  accept values from 0% through 50%.

Building-material sales give warehouses a practical purpose. Players can buy
useful stock when it is discounted, store the surplus and use it for a later
contract instead of always ordering the exact requirement directly to the job.
Higher delivery costs make collecting and transporting those goods yourself a
meaningful way to save money.

Vehicle sales create occasional opportunities to choose a different machine or
make an earlier long-term purchase.

## Progression and transport

Large specialist machines remain available through rentals, but renting an
entire fleet for a small contract may cost more than the contract pays. This
encourages players to combine compatible work and gradually build a useful
owned fleet.

Regular machine transport and fast travel are deliberately expensive so low
loaders and vehicle trailers become economical tools instead of optional
role-playing equipment. The existing 250-meter free radius remains available
around active work areas.

## Slower company milestones

- `Rent a Machine` requires twice the vanilla progress; discounts are reduced
  to 5%, 9%, 12%, 14% and 15%.
- `Hey, Taxi!` requires five times the vanilla progress; discounts are reduced
  to 5%, 9%, 12%, 14% and 15%.
- Soil, gravel, concrete, sand and asphalt progress requirements are doubled.
- `Special Components` progress requirements are multiplied by 1.5.
- Pallet milestones remain unchanged.

## Why a patcher is used

Construction Simulator does not provide an official modding system for these
changes. Distributing modified game files would redistribute copyrighted game
content, so Hard Economy instead verifies and patches files from the user's own
Steam installation.

The patcher:

- contains no original or modified Construction Simulator game files;
- verifies supported files with SHA-256 before changing anything;
- creates and validates backups and a separate per-application rollback copy;
- rejects unknown, updated or mixed files;
- can update managed 0.1.0-beta or 0.2.0 directly and can reapply changed settings;
- supports restoring the original files;
- performs no network communication.

Economy-bundle changes are readable in
[`src/Apply-HardModeEconomyBundle.ps1`](src/Apply-HardModeEconomyBundle.ps1),
milestones in [`src/Update-CompanyMilestones.ps1`](src/Update-CompanyMilestones.ps1),
and dynamic sale settings in
[`src/Apply-HardEconomySaleSettings.ps1`](src/Apply-HardEconomySaleSettings.ps1).
Native changes are represented as explicit byte ranges in
[`patches/GameAssembly.patch.json`](patches/GameAssembly.patch.json).

See [BUILDING.md](BUILDING.md) to recreate the distributable patcher.

## Compatibility

- Supported platform: Steam PC.
- Supported game build: the exact original file hashes recorded in the patch source.
- Do not combine this version with the Unofficial Patch.
- A Construction Simulator update may require a new Hard Economy release.
- No DLC or Season Pass is required.
- Multiplayer compatibility is not guaranteed.

Bulk-material storage at headquarters is **not** included in this release.

## Disclaimer

Hard Economy is an unofficial fan-made project. It is not affiliated with or
endorsed by the developers or publishers of Construction Simulator, Valve, or
Steam.

No license is currently granted for the original Hard Economy source code.
Third-party components retain their own licenses; see
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
