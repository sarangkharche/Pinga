# Pinga

Pinga is a small native macOS menu bar app for GitHub pull request comments and reviews. Choose the repositories or organisations you want to watch and open a PR or comment directly from its alert.

## Install

Requires an Apple Silicon Mac running macOS 13 or later and [GitHub CLI](https://cli.github.com/).

Download [Pinga.zip](https://github.com/sarangkharche/Pinga/releases/download/v0.1.0/Pinga.zip), unzip it and move Pinga.app to Applications.

Or install with Homebrew:

```sh
brew tap sarangkharche/pinga https://github.com/sarangkharche/Pinga
brew trust --cask sarangkharche/pinga/pinga
brew install --cask sarangkharche/pinga/pinga
```

This initial build is locally signed and not notarised by Apple. macOS may block its first launch; review the app in System Settings → Privacy & Security if prompted.

The [logo PNG](https://github.com/sarangkharche/Pinga/releases/download/v0.1.0/PRPing.png) is available separately.

## Set up

1. Run `gh auth login --hostname github.com` if you aren't already signed in.
2. Open Pinga and allow notifications.
3. Choose **Manage sources** in the menu, add your repositories or organisations and save.

Monitoring stays paused until you choose sources. The first scan is quiet. Pinga watches PRs you author and ignores your own comments. Click the menu bar PR label to open the selected PR or click a notification to open its conversation.

Pinga normally checks once a minute and slows down when GitHub requests it. The Mac needs to be awake and the app running. Source selection limits monitoring but doesn't change the GitHub CLI token's permissions. Private organisation access may require SSO authorisation.

## Build

Requires Xcode and GitHub CLI. Run `swift test` and `./scripts/build-app.sh`. The built app is in `dist/Pinga.app`.

The app stores monitoring state locally in `~/Library/Application Support/PR Ping/`. GitHub credentials come from the GitHub CLI and aren't saved in that state.
