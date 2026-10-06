# Content Writer

An agent skill that turns one topic into a full content package: social posts, a blog post and cover image prompts in several styles.

```
/content-writer "The Future of AI in Healthcare"
```

## What you get

```
content-packages/{topic-slug}/
├── social-posts.md      LinkedIn post, X thread, Instagram caption and carousel ideas, TikTok/Reels hooks
├── blog-post.md         SEO blog post (1500-2500 words) with meta description and target keywords
└── cover-prompts/
    ├── cover-elegant.md
    ├── cover-blueprint.md
    └── ...              one prompt file per style
```

- Cover styles are picked to suit the topic (technical, creative, business or lifestyle). You can override the count with `--styles`.
- If the topic folder already exists, a timestamp is added to the new folder name so nothing is overwritten.
- Everything is a draft. Review it before you publish.

## Requirements

content-writer hands each part to another skill, so install these too:

| Skill | Used for |
|---|---|
| [social-content](../social-content) | `social-posts.md` |
| [content-creator](../content-creator) | `blog-post.md` |
| [cover-image](../cover-image) | the style rules behind `cover-prompts/` |

## Install

With the [skills CLI](https://skills.sh):

```bash
npx skills add aslamdoctor/skills --skill content-writer --skill content-creator --skill social-content --skill cover-image
```

Or clone the [skills repo](https://github.com/aslamdoctor/skills) and symlink the four folders into your agent's skills directory:

```bash
git clone https://github.com/aslamdoctor/skills ~/skills
for s in content-writer content-creator social-content cover-image; do
  ln -s ~/skills/skills/$s ~/.claude/skills/$s
done
```

## Usage

```
/content-writer "Remote Work Best Practices"
/content-writer "Remote Work Best Practices" --output ./content
/content-writer "Sustainable Living Tips" --styles 3
```

| Option | Description |
|---|---|
| `--output <path>` | Output directory (default `./content-packages`) |
| `--styles <number>` | Number of cover prompt styles (default 5) |

The cover prompts are plain text. Paste them into any image generator (DALL-E, Midjourney and so on), or run `/cover-image` on the blog post to generate the image itself.

## License

MIT
