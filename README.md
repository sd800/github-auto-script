<!-- Keep this file synchronized with README_zh.md. -->

# Auto Script for GitHub Setup and Push

[Simplified Chinese](README_zh.md)

Auto Script for GitHub Setup and Push is a centralized Bash utility for anyone who wants a shorter path from local changes to a GitHub push while keeping each repository on one explicit account and SSH key. A small `git-auto.sh` dispatcher loads the central implementation from `src/`, while each project uses the same small `g.sh` interface.

Fast, convenient, and simple is the product rule. A routine push stays routine; guided setup appears only when information is missing or has changed.

The everyday interface stays deliberately small:

- `./g.sh`: Use the current project's saved owner account and key, stage changes, create a version-based commit when needed, and push.
- `./g.sh new`: Add a GitHub account and its local SSH key, then optionally use it for the current project.
- `./g.sh update`: Update local settings after a GitHub username or repository name has already changed.
- `./g.sh menu`: Open local project tools, preferences, and advanced diagnostics.

SSH identities, account verification, repository-specific authorship, release commit messages, upstream branches, and strict push identity are handled behind this interface.

## Engineering rule

Fast, convenient, and simple is also the implementation rule. Ordinary commands use the smallest correct Git and SSH operations: complete local state is reused, dependencies are checked only when a feature needs them, and safety comes from native atomic Git controls instead of duplicated preflight work. Optional `ssh -T`, `git ls-remote`, and account-discovery checks are available only under Advanced features. A routine push therefore makes no extra network request before the required `git push`. Potentially long stages name the work in progress, and uploads stream Git's real transfer progress instead of hiding output or inventing a synthetic percentage. Git output never opens an interactive pager, and SSH keepalives return control when an established connection becomes unresponsive.

## Architecture

The project uses one modular central program, one private profile, and one launcher per working project:

```text
git-auto/
|-- git-auto.sh       small central dispatcher
|-- g.sh              public copy-ready lightweight launcher
|-- src/              central Bash implementation
|   |-- 00-core.sh
|   |-- 10-ssh.sh
|   |-- 20-repository.sh
|   |-- 25-safety.sh
|   |-- 30-workflow.sh
|   |-- 40-history.sh
|   |-- 50-update.sh
|   |-- 60-menu.sh
|   `-- option.txt      technical switch configuration; currently empty
|-- README.md
|-- README_zh.md
|-- CHANGELOG.md
|-- CHANGELOG_zh.md
|-- tests/
`-- private/          local only; created automatically and ignored by Git
    |-- config.txt     personal preferences and account metadata
    `-- g.sh           copy-ready launcher with the central path built in

your-project/
|-- g.sh              generated lightweight launcher; locally ignored
`-- project files...
```

`git-auto.sh` only locates and loads the required modules beside it. The modules divide configuration and interface behavior, SSH identity handling, repository parsing, normal push workflow, historical import, rename synchronization, and menus. Missing modules stop the program before the workflow starts and identify the exact missing file.

The dispatcher and `src/` folder form one central installation and must be moved or copied together. They remain self-contained Bash code with no package dependency, no public/personal script pair, and no duplicated account block inside executable code. Updating this central installation updates the behavior used by every launcher.

## First-time setup

Place the public project wherever you want to keep the central engine, then run:

```bash
chmod +x git-auto.sh
./git-auto.sh
```

The first interactive run asks for the interface language once and records it in `private/config.txt`. The central menu can copy `g.sh` into a selected project. It also creates `private/g.sh` with the central path already built in, so the quickest manual copy is:

```bash
cp private/g.sh /path/to/your-project/g.sh
```

The tracked root `g.sh` remains the generic public copy for other users and installations.

After that, move to the project and use only the short commands:

```bash
./g.sh
./g.sh new
./g.sh update
./g.sh menu
```

No shell alias, PATH change, package installation, or application-specific home configuration directory is required. Run the tracked root `./g.sh` when this central repository itself needs to be committed and pushed.

## Central management menu

Running `./git-auto.sh` from the central folder opens the management menu. It can:

- Create or repair `g.sh` for a selected project.
- Add a GitHub account to the shared private profile.
- Change the shared interface language or display mode.
- Open explicit online diagnostics for existing SSH accounts, saved keys, and the current project.
- Open advanced tools, including historical release import.

Running `./git-auto.sh new` from the central folder goes directly to account setup. Direct `./git-auto.sh` is reserved for central management; project operations, including operations on the central repository itself, use `./g.sh`.

## Lightweight project launcher

The public `g.sh` contains no GitHub account, SSH, version, commit, or history-building logic. It treats its own folder as the project root and uses the central engine path saved in that repository's local Git configuration. The central repository's own `g.sh` can use the `git-auto.sh` beside it. If neither exact path exists, the launcher asks for either the `git-auto.sh` file or its containing folder instead of searching unrelated directories.

`g.sh` is a permanent seed launcher. Once this version has been copied into a project, routine releases do not replace it: features, interface text, and safety behavior all come from the central `git-auto.sh` and `src/` files. Updating the central project therefore updates every linked project at once. Its protocol marker also lets future central engines preserve compatibility with this seed.

The root `g.sh` is tracked and is never placed in this repository's ignore rules. When the central menu copies it into another project, only that project copy is added to `.git/info/exclude`; the project's shared `.gitignore` is not changed. After a project is configured successfully, the resolved central path is remembered in that project's local `.git/config`. The launcher itself remains generic and contains no personal path.

If the central folder moves, the existing launcher asks for the new folder path or complete `git-auto.sh` path and saves it locally; the launcher file itself still does not need to change. The central menu can also repair the saved path. Central management and the central repository's own `g.sh` refresh the ignored `private/g.sh`; launchers in other projects do no extra maintenance work during a routine push.

## Private configuration

All personalized application state lives in the ignored `private/config.txt` file next to `git-auto.sh`:

```text
language: en
display-theme: auto

username: johnjoe
email: 123456+johnjoe@users.noreply.github.com

username: alice
email: alice@example.com
```

Every field has its own line, and a blank line separates accounts. Each account has only a GitHub username and commit email. Commit display names are always derived from GitHub usernames.

`display-theme` remains in this private file because it is a multi-value preference rather than an on/off switch.

Persistent binary switches belong only in `src/option.txt`, using one stable technical label per line and an `enabled` or `disabled` value. This release has no persistent binary switches, so `src/option.txt` is intentionally empty. The file contains no user data or explanatory prose.

The central engine creates `private/` with owner-only directory permissions and `config.txt` with owner-only file permissions. It writes changes atomically and never places private keys, passphrases, access tokens, or passwords in this file.

Every user of the public project gets an independent ignored `private/` folder. Its generated `g.sh` is a convenience copy that contains only that installation's central path; account and preference fields remain exclusively in `config.txt`.

## Simple input rules

- Menus with eight or fewer items use `1` through `8`.
- Longer lists keep `1` through `8`, then use `a b c d e f g h j k m n p r`. GitHub accounts are sorted alphabetically without regard to letter case before these labels are assigned.
- When a list needs more than one page, use `x` for the previous page and `y` for the next page. The letters `s` and `w` are reserved for future features; `i`, `l`, `o`, `q`, `t`, `u`, and `v` are never used as choices.
- In an account list, "Add another account" uses `9` while there are eight or fewer saved accounts and `z` after that.
- Enter `0`, always shown last, to return or cancel without selecting an item.
- When the script asks whether to perform one clearly described action, answer the displayed yes-or-no question instead of memorizing another menu number.

## What happens when you run g.sh

The default workflow follows the state of the project:

1. Treat the folder containing `g.sh` as the exact project root.
2. Detect an existing Git repository before doing anything else. Existing commits, branches, staged changes, and remotes are preserved, and `git init` is not run again. If no repository exists, the script explains that `git init` creates local metadata only, then initializes it.
3. Lock this Git repository for the complete workflow. A second `g.sh` process cannot prepare, commit, change bindings, or push the same repository until the first process finishes.
4. Stop before changing files when HEAD is detached, merge conflicts remain, or a merge, rebase, cherry-pick, or revert is unfinished.
5. Read `origin` to determine the exact GitHub `owner/repository`. Ask for a repository address only when `origin` does not identify one.
6. Reuse the fast path only when the saved owner, commit name, email, SSH Host, exact private key, and both `origin` URLs agree. Otherwise repair only the incomplete local settings without an online precheck.
7. Use only the account whose username matches the repository owner, and pin its one local SSH key. A mismatched account or default `github.com` key is never used as a fallback.
8. Rebuild an isolated Git index from the current tracked entries, without reusing cached file timestamps, then scan the working tree as `git add -A` would. This preserves deliberately staged ignored files, staged removals, and sparse-checkout boundaries while exposing changes hidden by index hints. Show this exact prospective commit tree for confirmation without changing the real staging area.
9. After commit-message confirmation, recheck the repository, branch, HEAD, origin, account binding, Git index, file contents, and untracked-file set, then run `git add -A`. Require the staged tree and the created commit to match the confirmed files, message, and account identity before pushing that exact commit object to the explicitly named current branch on `origin`. If no commit is created during this run, show the latest local commit message and require a separate confirmation before connecting to GitHub.
10. Keep optional SSH authentication, account discovery, and read-only repository checks under Advanced features.
11. If push fails, keep the local commit and explain whether GitHub reported divergent history, an identity or repository rejection, a connection problem, or another exact Git error. When GitHub has commits missing locally, offer a default-No choice to keep both histories and append the current local version as the newest exact snapshot. Ordinary pushes never use force.

A clean repository creates no unnecessary commit. An empty `git status` is not accepted by itself: the independent full scan must also produce the same tree as `HEAD`. If quick status omits one or several tracked changes, the exact review still includes them together with ordinary changes. A clean sparse checkout is not mistaken for file deletion. If staged and working-tree changes cancel each other, the script stops without altering the existing index. If the repository truly is clean and already contains a local commit, `./g.sh` shows its commit message and asks before any push. An empty repository with no project files stops without attempting a push. Canceling at the commit prompt happens before staging and preserves any changes that were already staged.

If a folder already contains Git metadata that cannot be opened, the script stops instead of initializing over it. Unfinished multi-commit cherry-pick and revert sequences also block ordinary operations, even after an individual conflict has been resolved and committed. New unregistered nested repositories are blocked at any directory depth; correctly registered submodules remain supported, and a failed submodule inspection is not treated as a clean result.

Your confirmed commit message is preserved as entered, including a leading `#`, regardless of Git's message-cleanup preference. Hooks still run for normal file commits; if a hook changes the confirmed message or contents, automatic upload stops.

If GitHub rejects a push because its branch contains commits missing locally, the script first leaves both sides untouched. It then offers one optional recovery choice, defaulting to No. Choosing Yes reads the latest remote branch, shows the proposed connecting commit message for confirmation, preserves the remote history as the main line and the existing local history as a second parent, and creates a newest commit whose complete file tree exactly matches the current local version. The retry is a normal fast-forward push: no remote commit is deleted, no force option is used, and no automatic conflict resolution changes files. Canceling either confirmation changes neither history.

## GitHub account setup

Inside a project with a recognizable GitHub `origin`, `./g.sh new` derives the required username from the repository owner and never offers another account. Outside such a project, the central account menu can add any personal account. Ordinary setup follows these rules:

1. In a project, request only the owner account's commit email when that account is not already saved.
2. Reuse identities in this order: the project's complete exact mapping, the central repository's complete mapping for the same owner, then a Host following the `github-USERNAME` naming convention. If a project's saved Host was removed or now points elsewhere but its exact saved key still exists, add a collision-safe username Host for that same key instead of creating another key.
3. If other GitHub keys exist but their local names do not establish which account owns them, do not guess or default to creating another key. Offer an explicit Advanced online identity check, an explicit new-key choice, or cancellation.
4. If no local GitHub identity exists, show the exact key path and SSH Host before creating a dedicated ED25519 key.
5. Guide the user through adding the public key to the correct GitHub account, then save the local account-to-key mapping.
6. Do not run `ssh -T` or a repository read unless the user explicitly selects the Advanced identity check. The next normal `git push` returns GitHub's actual result.

New SSH Host names use `github-USERNAME`. Collisions are handled automatically with `-1`, `-2`, and later numbers. Each newly created account receives a different private key. When adding an exact Host, the script preserves a symlinked `~/.ssh/config`, quotes the key path, and verifies that the effective Host selects that exact file before saving. Advanced features inspect explicit Hosts, included and wildcard settings, the effective default `github.com` connection, every existing identity file listed for those connections, and conventional `~/.ssh/id_*` private keys not yet assigned to a Host. They can ask GitHub which account accepts each distinct key and import a confirmed identity under a username-based alias. These checks are noninteractive: a locked or unusable key fails cleanly instead of opening an unexpected passphrase prompt.

The local default is `USERNAME@users.noreply.github.com`. You can replace it with the exact private address shown by GitHub, including the `ID+USERNAME@users.noreply.github.com` form, or any email already verified for that account.

## Multiple-account protection

The shared private profile makes configured accounts available to every project, but each repository uses only the account whose username matches the repository owner.

Repository-specific values remain only in that repository's `.git/config`: username, email, SSH alias, identity file, and normalized fetch and push URLs for `origin`. A complete binding requires all of them to agree. Before each network operation, a temporary SSH wrapper enables `IdentitiesOnly=yes` and pins the selected private key. Other agent-loaded keys cannot silently become fallback identities.

This strict owner-account workflow intentionally stops when `owner/repository` belongs to a different username. It never treats the ability to read a public repository as permission to bind or push it from another configured account.

Ordinary commands trust the explicit local account-to-key mapping and let `git push` return the remote result. When an older or manually named SSH Host needs to be identified, use the Advanced online diagnostic; it verifies the actual GitHub username and creates a stable username-based alias without replacing the old Host.

Every upload requires exactly one effective `origin` push address matching the selected account and repository. Extra destinations, including those introduced by included Git configuration or URL rewrites, stop the upload. The script also disables mirror pushes, automatic tag following, and recursive submodule pushes for its own Git commands without changing your saved preferences. Only the explicitly selected branch is uploaded.

## Repository address input

Repository prompts accept and normalize common GitHub forms:

```text
owner/repository
owner/repository.git
github.com/owner/repository
https://github.com/owner/repository
https://github.com/owner/repository/tree/main
https://github.com/owner/repository/blob/main/README.md
git@github.com:owner/repository.git
ssh://git@github.com/owner/repository.git
git://github.com/owner/repository.git
git clone https://github.com/owner/repository.git
gh repo clone owner/repository
```

Query strings, fragments, trailing slashes, `.git`, and repository page paths are removed. Non-GitHub URLs are rejected rather than rewritten silently.

## Username or repository changes

After completing a username change or repository rename on GitHub, run `./g.sh update` in the affected project.

The flow assumes the change is already complete on GitHub. It asks what changed and requests only the relevant new information. The repository owner is always kept equal to the account username; a pasted URL under another owner is rejected. A final review lists every local file and Git setting that will change.

Username changes reuse the existing key, create a collision-safe username-based SSH Host when needed, preserve the previous Host for other projects, update the shared private account entry, and synchronize this repository's author and both `origin` URLs. Project files, branches, commits, and the GitHub repository are not modified or pushed. Canceling the final review leaves `private/config.txt`, `~/.ssh/config`, and the repository's `.git/config` unchanged.

`update` makes no network request. The next ordinary `git push` confirms the changed account and repository; the Advanced menu remains available when a separate SSH or read-only repository diagnostic is wanted.

## Commit messages and release versions

Every formal commit created by the script requires user confirmation first. For an established project, `./g.sh` keeps the workflow short: it displays the exact snapshot `git add -A` will prepare, checks for a possible accidentally embedded project, confirms the detected commit message, then runs `git add -A`, `git commit -m "Release X.Y.Z"`, and `git push`. Press Enter to accept the proposed message, type a replacement, or enter `:cancel` to stop before staging. With no working-tree changes, the script skips commit, clearly labels the latest local commit message, and asks a short confirmation question before push.

Every changed working tree receives the same complete pre-commit file review, including the normal fast path. Long change lists are printed directly and never open Git's interactive pager. If a new directory absent from current history contains a standard project marker such as `package.json`, `pyproject.toml`, `Cargo.toml`, or `go.mod`, the script lists it and requires a separate confirmation that defaults to No. A completely new top-level directory containing 20 or more files receives the same check. A folder that contains its own unregistered `.git` directory is blocked because Git would record a repository link rather than its ordinary file contents. Changes inside a configured submodule must be committed in that submodule first. Smaller ordinary folders do not add another prompt. A detected release version always takes priority, including for a first commit.

For every commit, including the first one, release versions are discovered in this order:

1. A valid root `package.json` version.
2. Every project-owned `CHANGELOG*` file in the root and all nested folders, including multilingual variants, using the highest valid version found anywhere in the project.
3. Root `VERSION*` files.
4. Recursive `VERSION*` files.
5. The fallback message `Update`.

Parsing supports newest-first and oldest-first changelogs, common English and Chinese dates, prereleases, build metadata, optional `v` prefixes, brackets, and Unicode dash variants. Project-owned release, distribution, and build folders participate in the search. Git metadata, dependency, cache, virtual-environment, and coverage directories are excluded.

## Historical release import

The advanced menu can reconstruct linear Git history from complete release folders that do not have useful Git history.

It discovers or accepts version mappings, sorts them by SemVer, and builds one complete `Release X.Y.Z` snapshot commit per version in a temporary repository. Files removed by a later release disappear from that later snapshot. Normal hidden files and ignored files are preserved, while `.git` and `.DS_Store` are excluded at every depth.

When archived releases lack a root `.gitignore`, the user can paste one shared set of rules directly into the terminal. It is added only to missing reconstructed snapshots and never written back to the source folders.

The flow checks for sensitive-looking and oversized files, displays `git log --oneline --reverse`, and verifies the selected GitHub identity before publishing. Safety scans and snapshot construction show `[current/total]` progress, and publication streams Git's real transfer progress. Reconstructed commit timestamps use reliable detected release dates by default. The user can decline; in that case, no historical dates are assigned and each commit keeps the local system time that Git records automatically when creating it.

Before creating reconstructed commits, the release plan displays every exact `Release X.Y.Z` message. One explicit batch confirmation covers the listed history; the internal builder refuses to create even the first commit unless that confirmation has been given.

Replacing an existing remote `main` requires explicit confirmation and an exact `--force-with-lease`. No backup branch is created, and other remote branches are unchanged. Historical reconstruction creates release commits only; it does not create or modify Git tags.

After publishing, the flow offers to connect the rebuilt `main` to the existing, normally non-empty working directory. It never copies over, deletes, or replaces current project files. If that directory has no Git metadata, it runs `git init`; if it has unrelated local history, it explains the change and asks before reconnecting. A mixed reset moves the branch to rebuilt history while leaving every current file difference as an ordinary uncommitted change. The flow then installs `g.sh`, saves the owner/key/origin binding, and makes the next `./g.sh` run ready to commit and push the current work.

The engine implements snapshot copying itself and does not depend on `rsync`.

## Language, display, and accessibility

English is the first-run default; Chinese is fully localized. The selected language applies consistently to project commands, central management, update flows, advanced tools, explanations, warnings, and errors. It can be changed from either menu.

Display mode supports automatic, dark, light, and colorless output. Automatic mode uses terminal background information and the macOS appearance setting when available. `NO_COLOR` and noninteractive output disable color.

The interface uses plain text status labels and no emoji symbols.

## Security and local state

The engine writes only to locations required by the requested workflow:

- `private/config.txt` for shared personal preferences and account metadata.
- `private/g.sh` as an ignored copy-ready launcher containing the current central path.
- `src/option.txt` as the technical location for persistent binary switches; it is currently empty.
- `~/.ssh` for GitHub SSH keys and configuration.
- The selected repository's `.git/config` and `.git/info/exclude` for local binding and launcher exclusion.
- Temporary directories for strict SSH wrappers and historical reconstruction.

The script does not use any other application-specific configuration directory. It creates or edits `~/.ssh` only when SSH identity work is explicitly part of the selected flow, and it shows the exact new key and Host before creation. Private keys are never copied into the central project or `private/config.txt`. Inherited Git environment values cannot redirect the launcher or engine to another repository, index, object store, or commit identity. Ordinary commands perform no optional online precheck, ordinary pushes never use force, and source release folders are never changed by historical import.

## Requirements and testing

- Bash 3.2 or later.
- Git and OpenSSH. `ssh-keygen` is required only when a new key must be created.
- Standard POSIX/macOS utilities used by the modular Bash engine.
- Network access for `git push` and any Advanced online diagnostic the user explicitly selects.

Run the isolated test suite with:

```bash
./tests/test.sh
bash tests/test.sh --commit-confirmation
bash tests/audit-regressions.sh
```

Tests use temporary home folders, private profiles, Git repositories, SSH configuration, and simulated SSH transport. They cover the direct push path, full setup, account isolation, versioned commits, push-failure explanations, and remote-history retention without using the real private profile or modifying real GitHub repositories.

## License

This project is available under the [MIT License](LICENSE).
