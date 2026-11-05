# Sammasak Skills

Reusable agent skills for software development and homelab workflows. The repository can be installed through each harness's native plugin marketplace, or delivered reproducibly with Nix.

## Claude Code

Add the marketplace and install the plugin:

```sh
claude plugin marketplace add sammasak/skills
claude plugin install sammasak-skills@sammasak-skills
```

Inside a Claude Code session, the equivalent commands are `/plugin marketplace add sammasak/skills` and `/plugin install sammasak-skills@sammasak-skills`.

## Cursor

Cursor supports the portable Agent Plugins package in the root `plugin.json`. Add the repository marketplace, then install the plugin from Cursor's Plugins view:

```sh
agent plugin marketplace add https://github.com/sammasak/skills
```

In Cursor, open **Customize → Plugins**, select the `sammasak-skills` marketplace, and install the plugin.

## GitHub Copilot CLI

Copilot CLI reads the shared marketplace manifest in `.claude-plugin/marketplace.json` and the portable root `plugin.json`:

```sh
copilot plugin marketplace add sammasak/skills
copilot plugin install sammasak-skills@sammasak-skills
```

## Codex

Add the marketplace and install the plugin:

```sh
codex plugin marketplace add sammasak/skills
codex plugin add sammasak-skills@sammasak-skills
```

Codex installs the portable skills from the repository's root `skills/` directory. Claude-specific agents and hooks remain available through the Claude Code plugin.

## Gemini CLI

Gemini CLI installs one skill at a time. Replace `nix-flake-development` with the skill directory you want:

```sh
gemini skills install https://github.com/sammasak/skills.git --path skills/nix-flake-development
```

Use `gemini skills list` to verify the installed skill.

## Nix

The NixOS Home Manager integration remains available for atomic, reproducible deployment. See the project configuration that consumes this repository as the `skills` flake input.

## Agent skill bundles

`bundles/` packages exactly the named skills and one role contract for a sandboxed agent
(skills#63, consumed by nixos-config's agent runtime through `inputs.skills`):

```sh
bash bundles/build.sh --src . --rev "$(git rev-parse HEAD)" --role quality --harness claude-code \
  --skill rust-engineering --skill nix-flake-development --out /tmp/bundle
```

or, from Nix, `(import "${inputs.skills}/bundles" { inherit pkgs; src = inputs.skills; rev = inputs.skills.rev; }).bundle { role; harness; skills; }`.
The bundle holds `roles/<role>/ROLE.md`, `skills/<name>/`, the harness adapter
(`.claude/agents/<role>.md` with its `skills` narrowed to the bundled ones, or `codex/<role>.toml`),
`bin/bundle-check` (verifies every sha256, no network or credentials) and `bundle.json`
(`agent-skill-bundle` v1): source rev, role with its declared tasks and the declared skills it lacks,
per-skill sha256, and a digest. A skill is visibility only: `authorization` (the role's `forbidden`
list, its `act` tasks, the adapter's tool policy) does not change with the skills bundled. An
unknown, misspelled, duplicate or empty skill name, an unknown role or a role without an adapter for
the harness fails with one JSON error line (classes `skill`, `role`, `harness`, `usage`).
`bin/bundle-check` catches an edited, added or relinked file and a manifest that no longer
matches its own digest; it is not a signature (anyone who can write the bundle can rewrite both),
so the trust anchor stays the bundle's read-only store path or a pinned `digests.bundle`.

Built from Nix, a bundle also carries the role's declared read and run tasks as `tasks/<name>`:
`bundles/default.nix` evaluates `task-modules/` and `agents/<role>/*.nix`, the modules devenv
imports, so each script is that task's code with its `coordinator.*` options applied (an optional
`taskConfig` module sets them), never a copy. `act` tasks stay with the host's audited wrappers.
`tasks.scripts` in `bundle.json` records each one's sha256 and what it runs after;
`bin/bundle-run <task> [input-json]` runs it after its dependencies the way devenv passes inputs
and outputs. Both entrypoints pin their store `PATH`, so they run in an empty environment. A declared
task the modules do not define fails the build (class `task`). `bash tests/test-bundles.sh`
(`skills:test:bundles`); `skills:test:bundle-sandbox` builds the quality bundle and runs it in a
bubblewrap sandbox: new user, network, mount and pid namespaces, read-only store, private HOME, no
credentials. There it checks that the claude-code adapter's skills and the role's tasks resolve to
the bundled ones, then runs `quality:report` and `quality:gate` against a fixture checkout through
the fake consumer devenv. A Claude Code session itself is not started there: it needs a credential.

## License

This project is licensed under the MIT License; see [LICENSE](LICENSE).
