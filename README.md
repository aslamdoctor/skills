# Skills

Agent skills I use day to day. Each one is a folder with a `SKILL.md`, in the [Agent Skills](https://agentskills.io) format, so they work with Claude Code, Codex, OpenCode, Pi and other agents that read skill folders.

## Skills

| Skill | What it does |
|---|---|
| [agent-smith](skills/agent-smith) | Runs several coding tasks in parallel from one Herdr pane, each in its own worktree with its own worker agent |
| [content-writer](skills/content-writer) | Builds a full content package for a topic: social posts, a blog post and cover image prompts. Uses the three skills below |
| [content-creator](skills/content-creator) | SEO blog content with brand voice analysis, plus Python scripts for voice and SEO scoring |
| [social-content](skills/social-content) | Platform-specific posts for LinkedIn, X, Instagram, TikTok and Facebook |
| [cover-image](skills/cover-image) | Cover image prompts in 20+ hand-drawn styles |

## Install

With the [skills CLI](https://skills.sh):

```bash
npx skills add aslamdoctor/skills --skill agent-smith
```

content-writer needs its three helper skills installed too:

```bash
npx skills add aslamdoctor/skills --skill content-writer --skill content-creator --skill social-content --skill cover-image
```

Or clone the repo and symlink the skills you want into your agent's skills directory:

```bash
git clone https://github.com/aslamdoctor/skills ~/skills
ln -s ~/skills/skills/agent-smith ~/.claude/skills/agent-smith
```

## License

MIT
