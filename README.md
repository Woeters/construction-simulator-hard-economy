# Construction Simulator - Hard Economy

Hard Economy is an unofficial economy overhaul for the Steam PC version of
Construction Simulator. It is intended for players who want vehicle ownership
and operating costs to remain meaningful for much longer.

Current version: **0.1.0-beta**

Author: **Thamonky**

## Download

Normal users should download the ready-to-use ZIP from the
[Releases](https://github.com/Woeters/construction-simulator-hard-economy/releases)
page. Source-code downloads do not include the
third-party runtime files required by the ready-to-use patcher.

## Main changes

- Machine rental prices are increased to 10x their vanilla values.
- The first 24 hours of every rental are charged upfront.
- Fuel and maintenance costs are increased by 4x.
- Regular machine transport costs are increased by 10x.
- Crane transport costs are increased by 5x.
- Construction-material and bulk-material purchase prices are doubled.
- Warehouse and direct construction-site delivery multipliers are increased by 5x.
- Regular fast-travel costs are increased by 10x.
- Traveling directly to a vehicle uses the same distance-based cost calculation.
- Machine resale value is reduced from 75% to 50% of its purchase price.
- Instant bulk filling is substantially more expensive.
- Instant emptying no longer rewards money.
- Physical bulk-material resale income is heavily reduced.
- Crane setup costs scale with the value of the crane.

## Why a patcher is used

Construction Simulator does not provide an official modding system for these
changes. Distributing modified game files would redistribute copyrighted game
content, so Hard Economy instead verifies and patches files from the user's own
Steam installation.

The patcher:

- contains no original Construction Simulator game files;
- verifies supported files with SHA-256 before changing anything;
- creates and validates a complete local backup;
- rejects unknown, updated or mixed files;
- supports restoring the original files;
- performs no network communication.

The economy-bundle changes are readable in
[`src/Apply-HardModeEconomyBundle.ps1`](src/Apply-HardModeEconomyBundle.ps1).
The native-code changes are represented as explicit byte ranges in
[`patches/GameAssembly.patch.json`](patches/GameAssembly.patch.json).

See [BUILDING.md](BUILDING.md) for instructions to recreate the distributable
patcher from this repository.

## Compatibility

- Supported platform: Steam PC.
- Supported game build: the file hashes recorded in the 0.1.0-beta source.
- Do not combine this version with the Unofficial Patch.
- A Construction Simulator update may require a new Hard Economy release.
- No DLC or Season Pass is required.

## Disclaimer

Hard Economy is an unofficial fan-made project. It is not affiliated with or
endorsed by the developers or publishers of Construction Simulator, Valve, or
Steam.

No license is currently granted for the original Hard Economy source code.
Third-party components retain their own licenses; see
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
