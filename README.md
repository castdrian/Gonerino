# Gonerino

[![Release](https://github.com/castdrian/Gonerino/actions/workflows/release.yml/badge.svg)](https://github.com/castdrian/Gonerino/actions/workflows/release.yml)
[![Crowdin](https://img.shields.io/badge/Crowdin-Translations-2ab27b?logo=crowdin&logoColor=white)](https://crowdin.com/project/gonerino)

YouTube tweak that allows you to block and automatically remove items from your feeds.

<p align="center"><img src="assets/screenshots.svg" alt="Gonerino custom settings, long-form controls, and Shorts controls in official iPhone 16 frames" width="100%"></p>

## Download

<p>
  <a href="https://repo.adriancastro.dev"><img src="assets/apt-repo-badge.svg" alt="Add Gonerino to your package manager" height="60"></a>
  &nbsp;
  <a href="https://github.com/castdrian/Gonerino/releases/latest"><img src="assets/github-release-badge.svg" alt="Download the latest Gonerino release" height="60"></a>
</p>

## Features

- Block channels or individual videos from YouTube menus
- Block items by channel, video, or keyword
- Remove blocked items from all feeds
- Hide “People also watched” and “You might also like” sections

## Compatibility

![Gonerino compatibility](.github/compatibility.svg)

## Simulator debugging

The repository tooling can inject a simulator build with simforge, verify the slim simslim profile, capture YouTube logs, and run repeated custom-settings navigation checks.

```sh
GONERINO_CYDIASUBSTRATE=/path/to/CydiaSubstrate \
GONERINO_SIMFORGE_BIN=/path/to/simforge \
go run ./scripts/gonerino-tools.go simulator-debug <simulator-udid> ./test-artifacts/simulator

GONERINO_CYDIASUBSTRATE=/path/to/CydiaSubstrate \
GONERINO_SIMFORGE_BIN=/path/to/simforge \
go run ./scripts/gonerino-tools.go simulator-settings-regression <simulator-udid> ./test-artifacts/simulator-settings 20
```

## Contributors

[![Contributors](https://contrib.rocks/image?repo=castdrian/Gonerino)](https://github.com/castdrian/Gonerino/graphs/contributors)
