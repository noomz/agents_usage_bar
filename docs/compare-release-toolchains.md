# Compare release popover backgrounds

Use this procedure for [issue #60](https://github.com/noomz/agents_usage_bar/issues/60). Keep the production release workflow unchanged until the comparison establishes whether the SDK changes the popover background.

## Build the comparison apps

1. Open the **Release toolchain comparison** Actions run on the comparison PR. The workflow runs when its YAML changes in a PR. After the workflow reaches the default branch, you can also use **Run workflow** on a selected branch.
2. Wait for both Xcode jobs to pass. The workflow builds one source commit with the existing release toolchain and the exact local Xcode 27.0 build. The Xcode 27 job uses GitHub's public-preview `xcode-27` runner, not a production-release runner.
3. Download both `toolchain-xcode-*` artifacts from that run.
4. Check that both `toolchain.txt` files report the same source SHA. Confirm each `verification.txt` reports `arm64` and `x86_64`, the expected SDK, and a `14.0` minimum runtime for both slices.
5. In each extracted artifact directory, run `shasum -a 256 -c SHA256SUMS.txt`.
6. Extract each inner `AgentsUsageBar-Xcode-*.zip` into a separate directory. Keep each app named `AgentsUsageBar.app` and preserve its bundle contents. Do not replace your installed app.

The ZIP preserves the app's ad-hoc signatures. These builds are not Developer ID signed or notarized. If macOS quarantines a downloaded comparison app, use the standard **Privacy & Security > Open Anyway** action only after checking the artifact's source and checksum.

## Compare on the same Mac

1. Quit the installed app and any other comparison copy. Run only one copy at a time because the copies share preferences and application data. Do not install a Sparkle update during the comparison.
2. Record the macOS version, display resolution, scaling, desktop background, and the **Reduce transparency** setting. Keep these settings fixed for both apps.
3. Open the Xcode 16.4 app by its full path, then open its menu-bar popover.
4. Capture the popover in Auto, Light, and Dark app themes on each display. Keep the system appearance fixed. Record which system appearance Auto resolves to.
5. Quit that copy and repeat with the Xcode 27.0 app on the same Mac and desktop background.
6. Compare matching screenshots. Record whether the desktop is visible through the background, not just whether the background looks lighter or darker.

Record results in the issue using this table:

| App theme | Display | Xcode 16.4 background | Xcode 27.0 background | Screenshot links |
| --- | --- | --- | --- | --- |
| Auto | 1 | | | |
| Light | 1 | | | |
| Dark | 1 | | | |
| Auto | 2 | | | |
| Light | 2 | | | |
| Dark | 2 | | | |

## Gate the release change

1. If the same-source apps have different backgrounds, attach their metadata and screenshots to #60. If they match, investigate other causes before changing release toolchains.
2. Before changing the production runner, explicitly accept or reject the `xcode-27` runner's preview status. GitHub documents that status in [runner-images #14404](https://github.com/actions/runner-images/issues/14404).
3. Build that same source revision locally with the selected Xcode version and repeat the appearance comparison against its CI artifact.
4. Before publishing, validate the actual release DMG, Sparkle update signature, and the applicable signing lane. For the Developer ID lane, also validate archive export, notarization, stapling, and Gatekeeper acceptance. The comparison workflow tests neither lane's complete release packaging and does not publish an appcast or release.

Do not close #60 based only on passing build jobs. The appearance comparison and the applicable release checks remain required.
