# Skills

Agent skills I use day to day. Each one is a folder with a `SKILL.md`, in the [Agent Skills](https://agentskills.io) format, so they work with Claude Code, Codex, OpenCode, Pi and other agents that read skill folders.

## Skills

| Skill | What it does |
|---|---|
| [agent-smith](skills/agent-smith) | Runs several coding tasks in parallel from one Herdr pane, each in its own worktree with its own worker agent |

## Install

With the [skills CLI](https://skills.sh):

```bash
npx skills add aslamdoctor/skills --skill agent-smith
```

Or clone the repo and symlink the skills you want into your agent's skills directory:

```bash
git clone https://github.com/aslamdoctor/skills ~/skills
ln -s ~/skills/skills/agent-smith ~/.claude/skills/agent-smith
```

## License

MIT
