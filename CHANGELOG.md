# Changelog

## 0.2.0

- Added one documented `HardEconomy-Settings.txt` file for user-defined economy
  values, sale caps and hourly sale chances.
- Added safe reapplication of changed settings without accumulating multipliers.
- Added direct update support from 0.1.0-beta.
- Changed the tested defaults after playtesting: rental 8x, machine purchase
  1.3x, fuel 5x, bulk materials 1.6x and retained the other documented values.
- Added rotating building-material sales with visible dynamic discounts.
- Added rotating vehicle sales with visible dynamic discounts.
- Sale caps accept 0 through 50 active items, and both hourly sale chances
  accept values from 0% through 50%.
- Added slower company milestones and reduced `Rent a Machine` and `Hey, Taxi!`
  discounts.
- Added validated per-application rollback copies in addition to the retained
  original-file backup.
- Kept headquarters bulk-material storage out of the release.

## 0.1.0-beta

- Initial public beta release.
- Added the first tested economy overhaul, upfront rental charging, distance-
  based vehicle travel costs, file validation, backups and restoration.
