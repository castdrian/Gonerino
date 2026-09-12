# Changelog

## 1.8.1 - 2026-09-12

### Fixes

- stabilize feed filtering and Shorts blocking (9b93823)
- restore Shorts blocking actions (6e96b7a)
- stop mutating live action sheets (dc10e98)
- deduplicate context menu block actions, resolves #34 (254fd37)

### Maintenance

- bump version to 1.8.1 (174caa0)

## 1.7.0 - 2026-09-09

### Features

- harden feed filtering and settings navigation, resolves #32 and resolves #33 (32c989e)

### Fixes

- enlarge GitHub badge icon (72d2994)
- shorten package manager badge label (d5ea01b)
- normalize download badge icons (f5f1000)
- harden repository tooling portability (15eafb8)
- repair Crowdin translation lifecycle (ee77394)
- harden Go device harness IO (f3e464f)
- keep changelog out of release assets (d807f88)
- preserve existing translation baselines (d4ef94b)
- correct patch version generation (61becd8)
- make automated pull request merging reliable (b36eacd)
- correct Crowdin localization paths (9ad3cd4)

### Documentation

- restore Crowdin badge (fe88758)
- simplify Crowdin badge (6d9d041)
- refine README presentation (30b8f70)

### CI

- guard Crowdin translation imports (ebc6c2b)
- align automation with native Crowdin integration (86d83b5)
- fetch history for changelog generation (05947bb)

### Maintenance

- consolidate repository tooling in Go (ec11ae7)
- update readme (e46df0e)
- update readme (8941751)
- modernize repository tooling and metadata (7df650a)
- bump patch version to 1.6.1 (f265215)
- refresh repository presentation and automation (c4176bb)

### Other changes

- New Crowdin updates (#29) (122b5e6)
- Update Crowdin configuration file (216544e)

## 1.6.0 - 2026-09-08

### Features

- add release notifications and changelog UI (467ed90)

### Fixes

- satisfy notification SDK callbacks (6a61482)

### Documentation

- refresh changelog for 1.6.0 (87c389e)
- generate changelog for 1.6.0 (465e5f0)

### Maintenance

- add LICENSE (77561e5)
- update readme (2da2183)

## 1.5.0 - 2026-09-08

### Features

- release reworked filtering and settings (6fb48d0)

### Fixes

- rebuild feed filtering and settings navigation (324df06)
- remove feed filtering stalls and settings redirects (9236b54)
- stabilize settings navigation and feed blocking (bef91c4)
- correct package version (29e5258)
- harden blocking and settings (ff49510)
- stabilize Gonerino blocking and settings (3e18f4a)

### CI

- use current macos runner and gnu make (4a65fe1)
