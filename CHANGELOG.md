<!-- Keep this file synchronized with CHANGELOG_zh.md. -->

# Changelog

[Simplified Chinese](CHANGELOG_zh.md)

All notable changes to Auto Script for GitHub Setup and Push are documented in this file.

## 3.17.2 - 2026-09-23

### Changed

- Always inspect the root `package.json` before any recursive lookup. An ordinary valid package version remains eligible for `Release X.Y.Z` even when unchanged; only an unchanged common scaffold placeholder (`0.0.0`, `0.0.1`, `0.1.0`, or `1.0.0`) is skipped. A placeholder is still eligible when first added or deliberately changed.
- Limit the recursive CHANGELOG and VERSION lookup to five seconds. When the limit is reached, stop the scan, ask for an optional release version, and use `Initial commit` or `Update` when the user presses Enter.

### Tests

- Added coverage for package-first lookup before the time limit, timed-out recursive lookup and manual input, unchanged placeholder fallback, and unchanged ordinary package versions.

## 3.17.1 - 2026-09-06

### Changed

- Suggest `Release X.Y.Z` only when the selected version value is newly introduced or changed in the exact snapshot being committed. An unchanged scaffold version such as `1.0.0` now falls back to `Update` on later commits—even if another field in its file changes—while a version included in a first commit remains eligible.
- When no eligible release version is present, use `Initial commit` for a repository without commits and `Update` for an established repository.
- Show the previous commit message recorded for the current GitHub branch directly below the proposed message. This reads the local remote-tracking record updated by successful pushes and adds no pre-commit network request.

### Tests

- Added coverage for an unchanged template version in a modified package file, a changed changelog alongside an unchanged package version, the first-commit fallback, and bilingual display of the previous GitHub commit message rather than a newer unpushed local message.

## 3.16.2 - 2026-09-06

### Fixed

- Recover an interrupted repository workflow when iCloud Drive or another file provider has renamed the script's internal `pid` and `token` lock metadata to numbered conflict copies such as `pid 2` and `token 2`.
- Reclaim such a lock only when every entry is recognized internal metadata and every recorded process has ended. A live process, malformed metadata, symlink, directory, or unknown file still blocks the later run.

### Tests

- Added focused coverage for both stale and still-active workflow locks whose internal metadata has a file-provider number suffix.

## 3.16.1 - 2026-09-06

### Added

- After a normal push is rejected because the remote branch contains commits missing locally, offer a default-No option to retain both histories and append the current local version.
- When explicitly selected, fetch only the named remote branch, ask for confirmation of the connecting commit message, keep the remote history as the main parent and the existing local history as a second parent, then retry with a normal fast-forward push. The newest commit uses the exact current local file tree; no force push or automatic conflict resolution is used.

### Safety and UX

- Uppercase the shortcut letter for the default choice in every Chinese yes-or-no prompt: `[是(Y)/否(n)，默认是]` and `[是(y)/否(N)，默认否]`. Input remains case-insensitive.
- Declining the option performs no additional network request and changes neither side. Canceling the commit-message confirmation leaves the local branch unchanged and removes the temporary fetched reference.
- Recheck the repository binding, exact local commit, complete working snapshot, remote commit, authorship, message, parents, and resulting tree before advancing the local branch or retrying upload. Interrupted reconciliation is identified on the next run.
- Kept the frozen `g.sh` seed unchanged; existing project launchers receive the feature from the central engine automatically.

### Tests

- Added isolated local-transport coverage for the default-No and commit-message cancellation paths, successful retention of two unrelated histories with the local snapshot published as the newest commit, and rejection messages that must not offer this recovery.

## 3.15.1 - 2026-09-05

### Fixed

- Rebuilt commit previews from actual index entries instead of `HEAD`, without copying cached filesystem timestamps. Forced ignored additions, intent-to-add files, staged removals, and staged changes outside a sparse checkout now match native `git add -A`; cancellation still preserves the real staging area.
- Made the embedded-project review use the same prospective index as the file review. Fixed missed repositories nested several directories deep and false rejection of newly registered submodules. Failed submodule inspections now stop the operation instead of appearing clean.
- Validate every effective `origin` address, not just the first one, and refuse extra or mismatched push destinations before connecting. Normalize locally saved URL lists during binding, and disable inherited mirror, automatic-tag, and recursive-submodule push settings for script operations without changing saved preferences.
- Quote the SSH wrapper path correctly when temporary directories contain spaces or apostrophes.
- Preserve confirmed commit messages regardless of `commit.cleanup`, including messages beginning with `#`. Commit hooks remain enabled and their results are still checked before upload.
- Stop before `git init` when an existing working directory has unreadable Git metadata or is a bare repository, including during historical handoff. Detect unfinished multi-commit cherry-pick and revert sequences even when no individual conflict marker remains.

### Performance

- Removed per-file Git subprocesses for ordinary index-hint preparation. A 150-file change now requires one hint-list scan rather than hundreds of Git calls; affected hidden flags are cleared in batches while unrelated flags remain unchanged.
- Kept the frozen `g.sh` seed unchanged. All fixes are delivered through the central modules with no new dependency or ordinary-path network precheck.

### Tests

- Added an isolated, offline regression script covering staged/index edge cases, sparse checkouts, nested repositories and submodules, SSH path quoting, single-destination pushes, inherited push settings, message cleanup, damaged metadata, sequencer state, literal filenames, and bulk hint preparation.

## 3.13.1 - 2026-09-04

### Changed

- Simplified ordinary commits to one authoritative flow: build the exact prospective file tree, show that same tree for confirmation, run `git add -A`, and verify the resulting commit before push. Visible changes and changes hidden by Git index hints can no longer follow different staging paths.
- The review now describes the exact commit snapshot rather than presenting a potentially incomplete quick-status result. Only index hints on files that actually need to be committed are cleared; unrelated hints remain unchanged.
- Froze `g.sh` as the stable seed launcher. Existing project copies continue to delegate to the central engine and do not need replacement when features, text, or safety logic change; future implementation updates belong in `git-auto.sh` and `src/`.

### Fixed

- Prevented simultaneous visible and `assume-unchanged` changes from producing a partial review or a failed partial staging operation.
- Added correct handling for sparse checkouts, staged and working-tree changes that cancel each other, dirty submodules, and unregistered nested Git repositories. Each case now stops or continues with an accurate explanation and without silently committing different contents.
- The central engine now discards inherited Git environment overrides that could redirect Git operations to another repository, index, object store, or commit identity.
- Rechecked every newly created ordinary and reconstructed-history commit against its confirmed tree, message, author, and committer before allowing upload.

### Tests

- Added focused coverage for mixed visible and hidden changes, preservation of unrelated index hints, net-zero staging states, clean sparse checkouts, dirty submodules, nested repositories, inherited Git overrides, and commit hooks that alter a confirmed message.

## 3.12.1 - 2026-09-04

### Fixed

- Removed the early clean-working-tree decision based only on an empty `git status`. Every ordinary run now builds an independent Git index from `HEAD`, scans the complete non-ignored working tree, and compares the exact prospective commit tree with the current commit before deciding that no changes exist.
- When the initial status output omits a tracked change, the script reconstructs the accurate review list from the independent index and continues through the normal commit-message confirmation instead of incorrectly switching to the existing-commit push path.
- Stages a recovered snapshot through Git's exact tree operation after confirmation, so index hints such as `assume-unchanged` cannot make the real commit silently omit files that the independent scan recovered. The real staging area remains unchanged until confirmation.

### Tests

- Added focused regression coverage in which ordinary `git status` reports a clean tree for a modified tracked file marked `assume-unchanged`. It verifies both that cancellation preserves the original index and local change, and that confirmation recovers, reviews, stages, and commits the actual contents.

## 3.11.5 - 2026-09-04

### Changed

- Removed the extra blank line before the existing-commit upload question so the confirmation follows the commit message directly.

## 3.11.3 - 2026-09-04

### Changed

- Simplified the confirmation shown when a clean working tree already has a local commit. The interface now labels the commit message explicitly, hides the commit hash and redundant branch name, explains why no new commit will be created, and places a short upload question on its own line.
- Rewrote the corresponding English and Simplified Chinese text independently for clear, natural phrasing.

### Tests

- Updated focused push-confirmation coverage for the concise English and Simplified Chinese output and for the absence of technical commit and branch details.

## 3.11.2 - 2026-09-01

### Fixed

- Restored an explicit confirmation boundary for the clean-working-tree path. When `./g.sh` did not create a commit during the current run, it now shows the current branch and latest local commit and requires confirmation before making any connection to GitHub; declining leaves all local commits unchanged.
- Kept the ordinary changed-file path concise: the existing commit-message confirmation continues to cover the commit created during that run, without adding a second prompt immediately before its push.

### Tests

- Added focused coverage proving that a pre-existing local commit cannot reach the push command after the user declines, while an explicitly confirmed push still targets the exact local commit.

## 3.11.1 - 2026-09-01

### Changed

- Added a repository-wide workflow lock in Git's own control directory. Two `g.sh` processes can no longer prepare, commit, change bindings, reconnect rebuilt history, or push the same repository at the same time. Locks owned by a live process stop the later run; recognizable locks left by a process that no longer exists are reclaimed safely.
- Added an interruption record for the staging, commit, and push phases. The next run explains where the earlier run ended, clears no staged work, and performs the complete review again instead of silently reusing an earlier preparation.
- Turned each ordinary commit into a verified transaction. Before showing the review, the script builds an isolated Git-index snapshot without changing the real staging area. After confirmation it verifies the repository root, Git control directory, branch, HEAD, both `origin` URLs, saved account, email, SSH Host, key binding, Git index, file contents, and untracked-file set. After `git add -A`, the real staged tree must exactly match the reviewed tree before `git commit` can run.
- Verified the new commit's direct parent and repository binding before upload. Ordinary push now sends the exact reviewed commit object to the explicitly named current branch on `origin`, then records that branch's upstream; a last-moment local ref movement cannot silently substitute another commit.
- Expanded misplaced-project detection to new nested directories with independent-project markers and to entirely new top-level directories containing 20 or more files. The existing default-No confirmation remains, and already staged additions receive the same check.
- Applied the same repository lock to username/repository update, owner binding, local binding repair, and the working-directory handoff after historical reconstruction.

### Tests

- Added focused coverage for active and stale locks, interrupted staging records, worktree and branch changes after confirmation, exact staged-tree mismatch, origin changes before upload, and exact-object push targeting.

## 3.10.7 - 2026-09-01

### Changed

- Made the complete `git status --short` review mandatory before every formal commit, including the established-project fast path.
- Added a focused safeguard for new top-level folders absent from the current committed history that contain an independent-project marker. It covers both unstaged and already staged additions, shows each candidate with its marker, and requires a separate confirmation that defaults to No before version discovery or `git add -A` can run. Declining preserves the existing index.
- Kept ordinary commits concise: normal new folders add no prompt, and explicitly approved project-like folders remain supported. Candidate lists use the shared numbering and pagination conventions.

### Tests

- Added focused coverage for unstaged and pre-staged candidates, unchanged index state after refusal, explicit approval, ordinary folders that need no extra prompt, and shared pagination for long review lists.

## 3.10.6 - 2026-09-01

### Changed

- Expanded release-version discovery to search every project-owned folder for `CHANGELOG*` files, including multilingual variants, and select the highest valid version across the complete candidate set.
- Included project-owned distribution and build folders in changelog discovery while continuing to exclude Git metadata, dependencies, caches, virtual environments, and coverage output.

### Tests

- Updated version-resolution coverage for competing root, nested, multilingual, distribution, and dependency changelogs.

## 3.10.5 - 2026-09-01

### Changed

- Refined the title presentation in both menu interfaces.

## 3.10.3 - 2026-09-01

### Changed

- Renamed the English README and changelog language link from `Chinese` to `Simplified Chinese` for greater specificity.

## 3.10.2 - 2026-09-01

### Changed

- Changed the MIT License copyright holder from `sd800` to `Songming.org`.

## 3.10.1 - 2026-09-01

### Changed

- Added explicit progress communication around every potentially long ordinary stage: working-tree inspection, release-version discovery, staging, commit creation, SSH connection, and upload. Commit output also explains when repository hooks or signing may be responsible for additional visible prompts.
- Changed ordinary push output from end-of-command buffering to live streaming with Git's real `--progress` data. Object enumeration, compression, transfer, and remote responses now appear while the command runs, while the same captured output remains available for precise failure explanations.
- Added `[current/total]` progress to historical snapshot safety scans and history construction, live Git progress to both normal and lease-protected historical uploads, and an explicit status before connecting an active working directory to rebuilt local history.
- Kept progress factual: the interface reports real stages and Git-provided transfer data rather than displaying a synthetic percentage or spinner that cannot measure the underlying operation.
- Licensed the project under the MIT License and added the complete license text at the repository root.

### Tests

- Expanded focused push coverage to verify live progress output, explicit `origin` targeting, preserved pipeline failure status, and the existing detailed failure classification.

## 3.9.3 - 2026-09-01

### Changed

- Added a process-wide `GIT_PAGER=cat` guard in both the lightweight launcher and central engine, while retaining command-level `--no-pager` protection for displayed lists. Future Git commands inherit noninteractive output automatically without modifying the user's Git configuration.
- Added SSH keepalive checks to pinned push transport and Advanced identity verification. A connection that becomes unresponsive after it is established now returns a normal failure instead of waiting indefinitely; visible key-passphrase prompts remain supported.

### Tests

- Expanded focused checks to cover the launcher and engine pager guards plus keepalive settings in both ordinary and Advanced SSH paths.

## 3.9.2 - 2026-09-01

### Fixed

- Disabled Git's interactive pager for commit change summaries, status output, and reconstructed-history logs. Large first-commit file lists now print normally and continue without waiting for an unexplained `q` keystroke at a `:` prompt.

### Tests

- Added a focused regression check with a deliberately configured pager and verified that the commit workflow never launches it.

## 3.9.1 - 2026-09-01

### Changed

- Tightened the established-project fast path so it is used only when the saved owner, commit name, email, SSH Host, exact key, and both `origin` URLs agree. A moved central engine path is refreshed locally without repeating account setup.
- Made every routine upload explicitly push the current branch to `origin`, so an unrelated saved upstream or push default cannot redirect the operation.
- Reused a project's exact saved key when its old SSH Host is missing or no longer selects that key. The local repair creates a collision-safe username Host without a new key or online precheck.
- Removed the extra SSH-account verification that historical import repeated immediately after its account-selection check, and stopped preloading newly created keys into `ssh-agent` as a separate step.

### Fixed

- Prevented multi-key and stale username Hosts from being accepted unless their effective first identity is the exact verified or saved key.
- Preserved symlinked SSH configuration files when adding a Host, resolved chained file links safely, quoted key paths, and validated the exact effective key before replacing the configuration target.
- Kept a repository's exact saved custom SSH Host parseable while a missing SSH entry is repaired, without accepting arbitrary unconfigured aliases.
- Made `update` keep the project's exact saved key while rejecting an inconsistent saved Host, so alias repair cannot silently switch to the different key selected by that Host.
- Normalized an identity found by an Advanced retry to a stable username Host instead of leaving a legacy multi-key Host in the saved binding.

### Tests

- Added focused coverage for fast-binding authorship and fetch/push consistency, moved-engine refresh, exact push targeting, multi-key Hosts, symlinked SSH configuration, missing-alias repair, `update` fallback, custom-origin recovery, and the single historical identity check.

## 3.8.1 - 2026-09-01

### Changed

- Added an ignored, copy-ready `private/g.sh` whose built-in path points to the current central `git-auto.sh`. Central management and the central repository's own launcher refresh this personalized copy automatically; ordinary project pushes do no extra maintenance work. The tracked root `g.sh` remains generic.
- Let the lightweight launcher accept either the complete `git-auto.sh` path or the path of its containing folder. Quoted paths, `~`, and folder paths are normalized before use.
- Expanded SSH discovery to include the effective default `github.com` connection, every existing identity file listed for an SSH Host, and conventional `~/.ssh/id_*` private keys not yet assigned to a Host. This includes settings inherited through `Include` and wildcard rules.

### Fixed

- Fixed first-time project setup offering to create a duplicate key when the same account already had a valid nonstandard SSH Host saved by the central repository. A new project now reuses that exact local account, Host, and key mapping without an online precheck.
- Defined local identity priority as a complete current-project mapping, then the central repository's complete owner/key mapping, then a `github-USERNAME` naming convention. A stale username-shaped Host can no longer override a more exact central mapping.
- In incomplete project bindings, a saved nonstandard SSH Host is trusted only when it still resolves to the exact saved private key; otherwise the repair flow continues through safer identity discovery.
- When existing GitHub keys are present but cannot be assigned to the requested username from trusted local state, ordinary setup now stops before guessing. It offers an explicit Advanced online identity check, an explicit new-key choice, or cancellation.
- Changed new-key prompts reached after failed Advanced verification to default to No, preventing a temporary network failure from leading to an accidental duplicate key.
- Made Advanced SSH identification noninteractive so an encrypted or unusable candidate key fails cleanly instead of leaving the workflow waiting for an unexpected passphrase prompt.
- Fixed username-change synchronization falling back to the new username when it must locate the account's existing key under the former username.

### Tests

- Added focused coverage for central nonstandard-alias reuse, multi-key SSH Host discovery, folder-path launcher input, and the personalized private launcher.

## 3.7.5 - 2026-09-01

### Changed

- Split the commit-message instructions across two short lines and placed the editable default message on its own line for clearer terminal output in both English and Chinese.

## 3.7.3 - 2026-09-01

### Changed

- Made prior user confirmation mandatory for every formal commit created by the script. Ordinary and first-time workflows confirm the individual commit message before staging.
- Historical reconstruction now displays each exact `Release X.Y.Z` message and requests one explicit confirmation for the complete listed batch before creating any commit.

### Fixed

- Added an internal confirmation-state guard so the historical repository builder cannot be called directly to create commits before the user approves the displayed release plan.

### Tests

- Added a focused commit-confirmation test mode covering ordinary approval, cancellation before staging, rejection of unconfirmed historical commits, and creation after batch approval without running unrelated tests.

## 3.7.2 - 2026-09-01

### Changed

- Restored one commit-message confirmation before every new commit, including the established-project `./g.sh` fast path. The script displays the proposed version-derived message before `git add -A`; Enter accepts it, another value replaces it, and `:cancel` stops before staging, committing, or pushing.
- Kept established projects concise by showing only the commit-message confirmation, while first-time or incomplete bindings continue to include the full working-tree review.

## 3.7.1 - 2026-09-01

### Changed

- Added the tracked `src/option.txt` as the only location for future persistent binary switches. Its format is limited to stable technical labels with `enabled` or `disabled` values; it is intentionally empty because the current release has no persistent binary switches.
- Kept interface language, the multi-value `display-theme` preference, and GitHub username/email records in the ignored `private/config.txt`.
- Added automatic cleanup for the retired `add-tags-to-historical-release` field in existing private configurations without changing language, display mode, or account records.

### Removed

- Removed historical-release Git tags end to end, including the Advanced setting, local tag creation, remote tag inspection, conflict handling, and tag pushes. Historical reconstruction now creates only the ordered `Release X.Y.Z` commits; tags already present in an existing repository are not deleted or changed.
- Removed the technical-details reveal feature and its `GIT_AUTO_DEBUG_DETAILS` environment switch. Destination summaries now always contain only the GitHub account followed by the repository.

### Tests

- Updated configuration, historical reconstruction, menu, and summary regression coverage for the empty option file and the complete removal of both retired features.

## 3.6.1 - 2026-09-01

### Changed

- Made “fast, convenient, and simple; never complicate a simple problem” an explicit engineering rule as well as a product rule. Ordinary commands now reuse complete local state and perform no optional online precheck before the required `git push`.
- Removed `curl`, `ssh -T`, and `git ls-remote` from ordinary account setup, project binding, local project checks, and `./g.sh update`. Account and repository results now come from the actual `git push` when a push is needed.
- Added explicit Advanced features for discovering and importing existing SSH accounts, verifying saved account keys with GitHub, and running SSH plus read-only repository diagnostics for the current project.
- Changed ordinary account setup to reuse only an explicit saved project key or a username-based `github-USERNAME` SSH Host. Missing identities receive a separate key after confirmation; advanced import can verify older aliases and add a stable username-based alias without replacing the old one.
- Made commit-email suggestions fully local and removed the GitHub API lookup. `ssh-keygen` is now required only when the selected flow actually creates a key.
- Simplified `g.sh` engine resolution to the explicit environment override, the repository-local saved path, the same-folder central engine, or one pasted path. It no longer searches ancestor folders, common home locations, or `PATH`.
- Combined central module validation and loading into one dispatcher pass. Changed project account menu actions to bind only the repository owner, and made local project checks validate the complete owner/key/origin binding instead of only a saved username.
- Made `./g.sh update` a local-only synchronization flow for changes already completed on GitHub. It continues to reuse the existing key, normalize the new username alias, and review every local setting before writing.
- Historical reconstruction now offers to connect rebuilt `main` to the existing, normally non-empty working directory after publication. It preserves every current file, runs `git init` only when Git metadata is absent, asks before replacing unrelated local history, leaves current differences uncommitted with a mixed reset, installs `g.sh`, and saves the owner/key/origin binding for the next normal push.
- Batched historical version tags into one push and removed the redundant fetch before replacing remote `main`; exact `--force-with-lease` values still reject any concurrent remote change atomically.

### Fixed

- Prevented the project-check menu from reporting a repository as ready when only its username matched but its exact key, SSH Host, fetch URL, or push URL was missing or inconsistent.
- Corrected launcher documentation that still described directory-wide engine searches removed from the lightweight implementation.
- Kept force-with-lease options before the remote name in the new batched tag push so Git parses them as options rather than refspecs.

### Tests

- Added regression coverage for local-only account selection, incomplete binding repair without online calls, username and repository updates without prechecks, batched tag pushes, and strict Advanced-menu network boundaries.
- Added integration coverage for linking rebuilt history into both a non-empty directory without Git metadata and a non-empty repository with unrelated local history, including file preservation, mixed-reset behavior, launcher installation, and future `./g.sh` readiness.

## 3.5.1 - 2026-08-31

### Changed

- Established the core product rule: fast, convenient, and simple. Routine pushes must not be turned into guided setup unless required information is missing or changed.
- Reduced established-project `./g.sh` runs to the practical equivalent of `git add -A`, an automatic version-derived `git commit -m "Release X.Y.Z"` when changes exist, and `git push`.
- Added a local fast-path check for the saved owner, SSH alias, exact key, fetch destination, and push destination. A valid binding skips repeated `ssh -T`, `git ls-remote`, commit-message prompts, configuration rewrites, status explanations, and staged summaries; push is the only GitHub connection.
- Kept the complete guided verification flow for first-time setup and changed, incomplete, or inconsistent bindings.
- Added an eight-second SSH connection timeout with one connection attempt so an unreachable network fails promptly.
- Push failures now preserve and mention the local commit, show Git's exact output, and provide localized explanations for non-fast-forward history, rejected identity or repository access, and connection failures.

### Fixed

- Restored the tracked, copy-ready root `g.sh` launcher that was omitted from the migrated repository snapshot.
- Corrected fast-path state and push-exit-status tests so they verify the parent shell state and the exact failed push result.
- Confirmed that rerunning `./g.sh` with a clean working tree still proceeds to `git push`, allowing an earlier connection failure to be retried without recreating the commit.

### Tests

- Added regression coverage for the no-preflight fast path, SSH timeout, automatic established-project behavior, clean-tree push continuation, and English and Chinese push-failure explanations.

## 3.3.1 - 2026-08-31

### Changed

- Made repository ownership the sole account-selection rule across `./g.sh`, `./g.sh new`, project verification, guided updates, and historical reconstruction. A repository under `owner/repository` can use only the configured account named `owner`.
- Added owner-match guards to the retained origin-identity interface and the internal historical build and publish entry points; project-scoped `./g.sh new` now stops instead of falling back to arbitrary account setup when owner setup does not finish.
- Rewrote remote-check messages to describe the exact read-only result without claiming that public read access proves ownership or push permission.
- Limited `./g.sh update` to username and repository-name changes under the same account identity; repository addresses under a different owner are rejected.
- Updated both README versions to document the strict owner-account flow and the exact remote-check boundary.

### Fixed

- Fixed a mismatched saved account or ordinary `github.com` default key taking priority over the repository owner, which could bind `davidsdd` to an `sd800/...` repository. Existing mismatched local bindings are now ignored and corrected on the next normal run.
- Fixed versioned first snapshots suggesting `Initial commit`. Any detected version now has absolute commit-message priority and produces `Release X.Y.Z`.

### Tests

- Added regression coverage for mismatched saved and supplied accounts, save-time owner enforcement, versioned first commits, same-owner updates, and the project release-number policy.

## 3.1.11 - 2026-08-31

### Changed

- Raised the complete dark-mode palette by another brightness level using softer, less saturated 256-color tones. Every selected color maintains at least 9.8:1 contrast against both black and a common dark-gray background.

## 3.1.10 - 2026-08-31

### Changed

- Renamed the Advanced features setting to “Add version tags when rebuilding history” so the option describes the action directly.

## 3.1.9 - 2026-08-31

### Changed

- Raised the brightness of the complete dark-mode palette with softened 256-color tones. Every selected color maintains at least 7.8:1 contrast against both black and a common dark-gray background without returning to neon-like high-intensity colors.

## 3.1.8 - 2026-08-31

### Changed

- Replaced the dark-mode ANSI palette with moderate 256-color tones for headings, informational text, success, warnings, errors, and secondary text. Every selected color maintains greater than 5:1 contrast against both black and a common dark-gray background.

## 3.1.7 - 2026-08-31

### Changed

- Removed the remaining high-intensity dark-mode colors and changed headings, success, warnings, and errors to standard ANSI tones after bright green and related status colors proved too strong.

## 3.1.6 - 2026-08-31

### Changed

- Reduced the brightness of informational text in dark mode by replacing bright cyan with standard cyan.

## 3.1.5 - 2026-08-31

### Added

- Added an Advanced features setting for historical-release `vX.Y.Z` tags. Tags default to off; only the enabled state writes `add-tags-to-historical-release: enabled` to `private/config.txt`, and disabling the setting removes that line.
- Added an optional reconstructed-commit timestamp step that defaults to using reliable detected release dates. When declined, no historical dates are assigned and each commit keeps the local system time recorded automatically by Git when creating it.

### Changed

- Expanded the English and Chinese tag-setting prompt to explain that tags appear on GitHub's Tags page and do not change file contents.

## 3.1.4 - 2026-08-31

### Changed

- Every file requiring a publication check now displays the exact reason: either a filename commonly used for credentials, private configuration, or key material, or a recognized private-key header.
- Reworded the risk heading and guidance so users can understand and review each item instead of receiving an unexplained “sensitive-looking” warning.

## 3.1.3 - 2026-08-31

### Fixed

- Fixed historical-import private-key detection reporting its own source code because the scanner contained the broad pattern it searched for.
- Private-key content checks now recognize complete key-file headers at the start of a file. Source code and documentation that merely mention a header are ignored, while real OpenSSH, PEM, PGP, and PuTTY keys remain covered; `.ppk` filenames are also recognized.

## 3.1.2 - 2026-08-31

### Changed

- Chinese yes-or-no prompts now show the accepted shortcut letters explicitly as `[是(y)/否(n)，默认是]` or `[是(y)/否(n)，默认否]`.

## 3.1.1 - 2026-08-31

### Added

- Added a seven-module `src/` layout for core UI and configuration, SSH, repository parsing, normal workflow, historical import, guided updates, and menus.
- Added one reusable pagination system for every menu or enumerated list that can exceed eight items. Each page uses `1-8` and the allowed account letters, with `x` for the previous page, `y` for the next page, and `0` last.
- Added a diagnostic-details interface through `GIT_AUTO_DEBUG_DETAILS=1`; normal output hides commit author, email, SSH Host, private-key path, push address, branch, and underlying push command.

### Changed

- Reduced `git-auto.sh` to a small dispatcher that validates every required module before loading any of them. The dispatcher and `src/` remain one self-contained central installation without third-party dependencies.
- GitHub account lists are now sorted alphabetically without regard to letter case before menu labels are assigned.
- Account labels after `1-8` use only `a b c d e f g h j k m n p r`. The keys `s` and `w` are reserved, while `i`, `l`, `o`, `q`, `t`, `u`, and `v` are excluded.
- "Add another account" now uses `9` when eight or fewer accounts are saved and `z` when more than eight are saved.
- Normal GitHub destination summaries now show only the account followed by the repository. Detailed identity and transport fields remain available in diagnostic mode or when they are required to explain a decision or error.
- Historical release plans, skipped folders, risk files, and conflicting tag lists now use the same pagination rules instead of truncating or flooding long output.

## 2.1.1 - 2026-08-31

### Changed

- Standardized every choose-one menu on consecutive numeric options. Account selection now uses `1`, `2`, `3`, and so on; `0` consistently returns or cancels, while direct confirmations remain explicit yes-or-no questions.
- Replaced the historical-import account menu's letter-based “add another account” option with the next available number.
- Documented the shared input rules in both README versions and added regression checks to prevent letter-based menu options from returning.

## 2.1.0 - 2026-08-31

### Added

- Added an explicit project-state phase that reports the exact repository root and current branch, preserves existing Git history, and stops safely on detached HEAD, unresolved conflicts, or unfinished Git operations.
- Added origin-aware account discovery: SSH remotes such as `git@github800:owner/repository.git` now verify that Host's configured key and GitHub username before considering other accounts.
- Added a pre-staging cancellation boundary, empty-repository handling, read-only update cancellation guarantees, and regression coverage for each of those states.
- Added `git://github.com/owner/repository.git` to the accepted repository address variants.

### Changed

- Reordered the default workflow around project state, origin, account, exact key, destination access, change review, commit, and push.
- Made existing repositories state explicitly that `git init` will not run again and that commits, branches, staged changes, and remotes are preserved.
- Made the tracked root `g.sh` operate on the central repository itself; direct `git-auto.sh` now remains the unambiguous central-management entry.
- Deduplicated SSH checks for multiple Host entries that reference the same private key.
- Reworked English and Chinese interface text to name the exact key, Host, repository, account, file, command, and write boundary involved in each decision.
- Updated both README versions to match the implemented user flow and local-state boundaries.

### Fixed

- Fixed existing repositories with a valid custom GitHub SSH Host being sent through generic account creation or prompted to create another key.
- Fixed Chinese text variables followed by full-width punctuation being parsed as different shell variable names.
- Fixed normal runs rewriting local engine-path settings during read-only detection or update cancellation.
- Fixed the central repository's tracked `g.sh` being treated like an ignored project-only launcher.

## 2.0.0 - 2026-08-31

### Added

- Added `git-auto.sh` as the single complete central engine shared by every project.
- Added a tracked, generic root `g.sh` that can be copied directly from the public repository without containing a personal path or account value.
- Added automatic generation and repair of small project-local `g.sh` launchers that preserve the four-command interface and pass the exact launcher folder as the project root.
- Added a bilingual central management menu for launcher creation, shared account setup and repair, preferences, and advanced tools.
- Added the ignored `private/config.txt` profile for language, display mode, and all shared GitHub account metadata.
- Added owner-only permissions for the private directory and configuration file.
- Added explicit missing-engine guidance when a central folder has moved.

### Changed

- Replaced the duplicated public/personal executable model with one public central engine and one private text configuration.
- Moved all personalized values out of executable code; account updates and preferences no longer modify `git-auto.sh` or project launchers.
- Made the root `g.sh` public and trackable, while project copies created by the central menu remain local through `.git/info/exclude`.
- Moved resolved central paths into each target repository's local `.git/config`, keeping the public launcher generic.
- Separated central engine location, target project location, and private configuration location throughout the implementation.
- Migrated the existing ignored personal accounts into `private/config.txt` without changing SSH keys or repository bindings.
- Rewrote both README versions around the centralized installation and everyday project workflow.

### Removed

- Removed the `dist/` directory and the full personalized script copy.
- Removed account and preference fields from the top of executable scripts.

## 1.2.0 - 2026-08-31

### Added

- Added one-time interface language initialization on the first interactive run, with English as the default and fully localized Chinese as the alternative.
- Added a menu option for changing the saved interface language later.
- Localized the complete standard, update, and advanced workflows so every prompt, explanation, warning, and error follows one consistent saved language.

### Changed

- Renamed the standard public and personal distribution files from `go.sh` to `g.sh`; the script can still be renamed freely after copying.
- Moved interface language and display preferences into clear, human-editable fields at the top of the self-contained script.
- Removed the application-specific preference directory; the script now keeps its own preferences without creating another local configuration folder.
- Made the update and advanced workflows reuse the saved interface language instead of asking independently.

## 1.1.0 - 2026-08-31

### Added

- Added `./g.sh update` as the fourth public command for GitHub username changes, repository renames or transfers, and combined changes.
- Added an English-default, fully localized Chinese guided update flow that asks only for information relevant to the selected change.
- Added pre-write verification of the existing key's new GitHub username and access to the exact new repository.
- Added automatic reuse of the existing account key, collision-safe creation of a new username-based SSH alias, and preservation of the old alias for other local repositories.
- Added automatic migration of the visible account entry, noreply email suggestion, repository-local commit identity, saved strict-key binding, and both fetch and push URLs for `origin`.
- Added personal-owner migration when the repository owner matched the old username, while preserving organization ownership and accepting complete GitHub addresses for moved repositories.

### Fixed

- Fixed false "script is inside another repository" errors on macOS when the script directory and Git reported the same physical folder using different path spelling, case, or an equivalent system prefix.

## 1.0.0 - 2026-08-31

### Added

- Added the three-command interface: `./g.sh`, `./g.sh new`, and `./g.sh menu`.
- Added automatic discovery of existing GitHub SSH identities from `~/.ssh/config` and `Include` files.
- Added one dedicated ED25519 key per GitHub account with automatic `github-USERNAME` alias collision handling.
- Added verification of the actual GitHub username authenticated by a key before saving an account or repository binding.
- Added current-format noreply commit email suggestions derived from the public GitHub account ID.
- Added repository-local binding to one account, email, SSH alias, and private key.
- Added a temporary SSH wrapper that pins every network Git operation to one private key.
- Added support for personal repositories, organization-owned repositories, and repository account switching.
- Added normalization for `owner/repository`, HTTP, HTTPS, SSH, repository-page URLs, and common clone command input.
- Added version discovery from `package.json`, primary changelogs, language changelogs, recursive changelogs, and `VERSION*` files.
- Added changelog support for top-first and bottom-first ordering, multiple date formats, prereleases, build metadata, and Unicode dashes.
- Added automatic dark and light appearance detection with high-contrast and colorless modes.
- Added script renaming, safe self-updates of the account block, and repository-local self-exclusion.
- Kept the script fully self-contained by using Git's tracked state instead of a companion source marker.
- Added a bilingual advanced menu, with English as its default, without adding another public command.
- Added guided reconstruction of linear Git history from complete historical release folders sorted by SemVer.
- Added full-snapshot replacement that preserves hidden and ignored files while excluding `.git` and `.DS_Store` at every depth.
- Added reliable changelog-date reuse, optional lightweight `vX.Y.Z` tags, and explicit handling for identical snapshots.
- Added a direct terminal editor for supplying `.gitignore` content only to historical snapshots that lack it.
- Added preflight detection for sensitive-looking files and files too large for a normal GitHub push.
- Added empty-remote publishing and explicitly confirmed remote `main` replacement with an exact force-with-lease and no automatic backup branch.
- Replaced emoji status symbols with plain text labels throughout the user interface.
- Added an isolated test suite with temporary home directories, Git repositories, simulated SSH transport, and a strict push test.

### Documentation

- Added an en-US `README.md` written for public repository visitors.
- Added a synchronized Chinese `README_zh.md`.
- Added reciprocal language links for both README and changelog files.
