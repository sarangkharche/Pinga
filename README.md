# Pinga

Pinga is a small native macOS menu bar app for GitHub pull request comments and reviews. Choose the repositories or organisations you want to watch and open a PR or comment directly from its alert.

## Install

Requires an Apple Silicon Mac running macOS 13 or later and [GitHub CLI](https://cli.github.com/).

Download [Pinga.zip](https://github.com/sarangkharche/Pinga/releases/download/v0.1.2/Pinga.zip), unzip it and move Pinga.app to Applications.

Or install with Homebrew:

```sh
brew tap sarangkharche/pinga https://github.com/sarangkharche/Pinga
brew trust --cask sarangkharche/pinga/pinga
brew install --cask sarangkharche/pinga/pinga
```

This initial build is locally signed and not notarised by Apple. macOS may block its first launch; review the app in System Settings → Privacy & Security if prompted.

The [logo PNG](https://github.com/sarangkharche/Pinga/releases/download/v0.1.2/PRPing.png) is available separately.

## Set up

1. Run `gh auth login --hostname github.com` if you aren't already signed in.
2. Open Pinga and allow notifications.
3. Choose **Manage sources** in the menu, add your repositories or organisations and save.

Monitoring stays paused until you choose sources. The first scan is quiet. Pinga watches comments and reviews on your PRs. On other people’s PRs, it watches for replies in review threads you joined and explicit mentions in general PR comments. It ignores your own activity. Closed PRs are included when updated in the last seven days. GitHub search indexing can delay discovery. Click a PR in the menu or click a notification to open the conversation.

To show the PR currently open in your browser, choose **Enable open PR detection** in the Pinga menu and grant Accessibility access in macOS settings. Pinga checks the active browser window for a GitHub PR URL in your selected sources. Accessibility access lets apps observe and control your Mac. Pinga uses it to read the browser URL and doesn't save other page URLs. You can turn detection off in the menu. Supported browsers are Zigzag, Safari, Chrome, Firefox, Edge and Brave. Browser accessibility support can vary.

Pinga normally checks once a minute and slows down when GitHub requests it. The Mac needs to be awake and the app running. Source selection limits monitoring but doesn't change the GitHub CLI token's permissions. Private organisation access may require SSO authorisation.

## Build

Requires Xcode and GitHub CLI. Run `swift test` and `./scripts/build-app.sh`. The built app is in `dist/Pinga.app`.

The app stores monitoring state locally in `~/Library/Application Support/PR Ping/`. GitHub credentials come from the GitHub CLI and aren't saved in that state.
