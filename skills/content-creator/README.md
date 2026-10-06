# Content Creator

An agent skill for SEO blog posts and marketing content written in a consistent brand voice. It comes with two Python scripts, one that profiles the voice of existing content and one that scores a draft for SEO.

```
/content-creator
```

## What you get

- Blog post frameworks and templates in `references/content_frameworks.md`
- Brand voice attributes and guidelines in `references/brand_guidelines.md`
- Platform notes for social posts in `references/social_media_optimization.md`
- A monthly content calendar template in `assets/content_calendar_template.md`
- `scripts/brand_voice_analyzer.py`: formality, tone, perspective, readability and sentence structure of a piece of text
- `scripts/seo_optimizer.py`: an SEO score (0-100), keyword density, structure checks, meta tag suggestions and fixes

## Requirements

- Python 3. The scripts use only the standard library.

## Install

With the [skills CLI](https://skills.sh):

```bash
npx skills add aslamdoctor/skills --skill content-creator
```

Or clone the [skills repo](https://github.com/aslamdoctor/skills) and symlink this folder:

```bash
git clone https://github.com/aslamdoctor/skills ~/skills
ln -s ~/skills/skills/content-creator ~/.claude/skills/content-creator
```

## Usage

Ask your agent for a blog post, a brand voice check or a content calendar, or run the scripts yourself:

```bash
python3 scripts/brand_voice_analyzer.py post.md          # text report
python3 scripts/brand_voice_analyzer.py post.md json     # JSON report
python3 scripts/seo_optimizer.py post.md "remote work" "async teams,home office"
```

The [content-writer](../content-writer) skill uses this one to write the blog post in its content package.

## Credits

Written by Alireza Rezvani.

## License

MIT
