# Releasing

A `v*` tag builds the app on GitHub Actions, attaches the zip to a GitHub release, and renders the Homebrew cask into [PostHog/homebrew-tap](https://github.com/PostHog/homebrew-tap). Installed apps then update themselves from that release (see [Updates](#updates)). The setup mirrors [PostHog/postpile](https://github.com/PostHog/postpile/blob/main/RELEASING.md).

## Repo setup

Done once. Kept here so a rotated key can be set up the same way.

- **Repo.** `PostHog/sizeberg`, public, default branch `main`. Description: "Internal DevEx tool: shows what deleting worktrees, build output and caches really frees on a Mac".
- **Homebrew tap token.** The PostHog GitHub App behind `GH_APP_HOMEBREW_TAP_RELEASER_*` already writes to the tap for PostPile, phrocs and other tools. Its secrets are environment secrets per repo, so this repo needs its own copy:
  - Repo settings › Environments: `homebrew-tap`, with a deployment tag rule `v*` (no branches).
  - In that environment, `GH_APP_HOMEBREW_TAP_RELEASER_APP_ID` (the app's numeric App ID) and `GH_APP_HOMEBREW_TAP_RELEASER_PRIVATE_KEY` (in 1Password as `releaser-homebrew-tap.<date>.private-key`):

    ```
    op document get <item id> | gh secret set GH_APP_HOMEBREW_TAP_RELEASER_PRIVATE_KEY -R PostHog/sizeberg --env homebrew-tap
    gh secret set GH_APP_HOMEBREW_TAP_RELEASER_APP_ID -R PostHog/sizeberg --env homebrew-tap --body <app id>
    ```

- **Signing environment.** Repo settings › Environments: `desktop-signing`, with a deployment tag rule `v*` (no branches). It holds the Sparkle key, see [Updates](#updates). Both environments exist since 2026-11-05.
- **Apple secrets.** GitHub org secrets, declared in [posthog-cloud-infra](https://github.com/PostHog/posthog-cloud-infra) `terraform/environments/github/org/secrets/terragrunt.hcl` and shared with selected repos. Until `sizeberg` is in their `selected_repositories`, releases go out ad-hoc signed and cannot update themselves.

## Every release

1. **Pick the version.** Count the minor up for a release (`0.2.0`), the patch for a quick fix on top (`0.2.1`). A version with a `-` becomes a pre-release.
2. **Bump it** in `VERSION`.
3. **Changelog.** Changes collect under `## <version> (unreleased)` at the top of `CHANGELOG.md` as they land. Rename it to `## <version>` for the release; the release workflow takes that section as the release notes.
4. **Check locally:** `swift test` and `./build.sh`. Commit through a PR and merge to `main`.
5. **Tag and push** from the merged `main`:

   ```
   git tag -a v0.2.0 -m "SizeBerg 0.2.0"
   git push origin v0.2.0
   ```

   If the Release workflow does not start, run it by hand: Actions › Release › Run workflow, with the tag, and pick the tag under "Use workflow from" too. The environments only admit `v*` refs.

6. **What the workflow does** (`.github/workflows/release.yml`):
   - `build` on `macos-26`, in the `desktop-signing` environment: checks the tag equals `v` + `VERSION`, runs the tests, builds with `build.sh` (Developer ID signed with the hardened runtime when the Apple secrets are there, else ad-hoc), notarizes and staples, verifies the signature, the bundle ID and the version, zips the app, and for a signed build writes `appcast.xml` with the zip's EdDSA signature. It creates the GitHub release with `SizeBerg-<version>-mac-arm64.zip`, its `.sha256`, and `appcast.xml` for a signed build. The release is a draft until every file is up.
   - `publish-homebrew` on ubuntu, in the `homebrew-tap` environment: renders `homebrew/sizeberg.rb.tmpl` with the version, the sha256 and the right caveats, and commits `Casks/sizeberg.rb` to PostHog/homebrew-tap `main`.
7. **Verify:**
   - The release has the zip, the `.sha256` and, for a signed build, `appcast.xml`, with the changelog notes.
   - PostHog/homebrew-tap has a commit "chore: update sizeberg cask to <version>".
   - The build log has a green "Verify signing and notarization" step, or the "building an ad-hoc signed, not notarized release" warning.
   - On a Mac: `brew update && brew install --cask posthog/tap/sizeberg` (or `brew upgrade --cask sizeberg`). About SizeBerg shows the version. With an older signed version installed, SizeBerg › Check for Updates… offers the new one.

## Signing and notarization

Why: an ad-hoc signed app has no stable identity. Gatekeeper blocks its first open, macOS forgets privacy grants after each update, and Sparkle cannot tell that an update comes from the same developer. A Developer ID signature fixes all three; notarization lets Gatekeeper open the app without asking.

What the workflow does:

- "Check signing secrets": no certificate means a `::warning::` and an ad-hoc build. A certificate with anything else missing, or without `Resources/sparkle-public-key.txt`, fails the job: a signed app that Gatekeeper blocks, or that cannot update, should not ship.
- The certificate goes into a keychain that exists only for the job. `build.sh` signs inside out with `SIGN_IDENTITY`: Sparkle's `Autoupdate` and `Updater.app`, `Sparkle.framework`, the CLI, then the app, all with the hardened runtime and a secure timestamp. No entitlements are needed.
- `notarytool submit --wait`, then `stapler staple`.
- "Verify signing and notarization": a Developer ID authority, the hardened runtime flag, `spctl --assess`, `stapler validate`, and the public Sparkle key in `Info.plist`.

The `desktop-signing` environment needs:

| Name | Kind | What |
| --- | --- | --- |
| `APPLE_CODESIGN_CERT_BASE64` | secret | Developer ID Application certificate with its key, `.p12`, base64 |
| `APPLE_CODESIGN_CERT_PASSWORD` | secret | Password of the `.p12` |
| `APPLE_APP_SPECIFIC_PASSWORD` | secret | App-specific password of the Apple ID used for notarization |
| `APPLE_ID` | variable or secret | That Apple ID |
| `APPLE_TEAM_ID` | variable or secret | PostHog's Apple team ID |
| `SPARKLE_ED_PRIVATE_KEY` | environment secret | Private EdDSA key that signs updates, see [Updates](#updates) |

The Apple ones exist as `APPLE_*` org secrets for PostHog's desktop app (the `Array` repo). A PR to posthog-cloud-infra that adds `sizeberg` to their `selected_repositories` shares them with this repo; the workflow reads `secrets.X`, which finds an org secret too. It needs approval from the infra team, the desktop app owners and security. Shared org secrets are readable by every workflow in this repo, not only by `v*` tag runs; copying the values into the `desktop-signing` environment instead keeps them behind the tag rule, but the copies then need updating by hand when the certificate rotates.

## Updates

Installed apps update through [Sparkle](https://sparkle-project.org) 2, pinned in `Package.swift`.

- The app reads `SUFeedURL`, `https://github.com/PostHog/sizeberg/releases/latest/download/appcast.xml`, once a day and on SizeBerg › Check for Updates…. The feed names the zip of the newest release and its EdDSA signature.
- Sparkle installs an update only when the zip's EdDSA signature matches `SUPublicEDKey` in `Info.plist` and the new app has the same Developer ID as the running one. So the key and the certificate together decide who can ship an update.
- `sparkle:version` in the feed is `CFBundleVersion`, which Sparkle compares. The release workflow sets it to the workflow run number, so it grows with every release. Local builds use the commit count and never update.
- The updater runs only in a Developer ID signed build that carries the public key. Other builds show the `brew upgrade --cask sizeberg` hint instead.
- The cask has `auto_updates true`, so `brew upgrade` leaves an app that already updated itself alone.
- To pull a bad release back from updates, delete its `appcast.xml` or mark it a draft: apps then read the feed of the release before it, and never go back to an older version on their own.

The key, set up once. The original lives in [PostHog/secrets](https://github.com/PostHog/secrets) (AWS Secrets Manager, owned by team-security), environment `internal`, app `sizeberg-release`, key `SPARKLE_ED_PRIVATE_KEY`. The GitHub environment holds a working copy for the workflow, which cannot read AWS Secrets Manager. Releases need neither the person who made the key nor their Mac.

1. Generate it with Sparkle's tool, which SwiftPM downloads with the package. It puts the private key in the login keychain and prints the public key:

   ```
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account sizeberg
   ```

2. Commit the printed public key as `Resources/sparkle-public-key.txt`.
3. Export the private key once, store the original, set the working copy, then remove both local copies:

   ```
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account sizeberg -x sizeberg-sparkle.key
   secrets set internal sizeberg-release SPARKLE_ED_PRIVATE_KEY   # paste the file's content in the editor
   gh secret set SPARKLE_ED_PRIVATE_KEY -R PostHog/sizeberg --env desktop-signing < sizeberg-sparkle.key
   rm sizeberg-sparkle.key
   security delete-generic-password -s "https://sparkle-project.org" -a sizeberg
   ```

   `secrets set` needs the `secrets-editor` role in the `internal` account (request it with `/awsaccess` in #aws-access), or use the [web app](https://secrets-ui.hedgehog-kitefin.ts.net/) on the tailnet.

To restore the working copy, for example in a new environment: `secrets get internal sizeberg-release SPARKLE_ED_PRIVATE_KEY --plaintext | gh secret set SPARKLE_ED_PRIVATE_KEY -R PostHog/sizeberg --env desktop-signing`.

Losing the key everywhere means no installed app accepts a new update: everyone would have to reinstall once with Homebrew.

## Notes

- Releases are arm64 only, like the scan runner.
- The bundle ID is `com.posthog.sizeberg`. Local builds from before the first release used `local.sizeberg`; the cask's `zap` list removes both.
- Local builds never publish anything; only the workflow creates releases.
