# Social Content

An agent skill for writing and planning social media posts for LinkedIn, X, Instagram, TikTok and Facebook.

```
/social-content
```

Or just ask: "Write a LinkedIn post about our launch", "Turn this blog post into an X thread".

## What you get

- Before writing, it asks about your goal, audience, brand voice and how much time you have, unless you've already said.
- A strategy guide per platform: what it's good for, how often to post and when.
- Post templates for LinkedIn, X threads and Instagram captions, plus hook formulas (curiosity, story, value, contrarian, social proof).
- A content pillars framework and a weekly and monthly calendar layout.
- A repurposing system for turning a blog post, podcast or video into a set of posts.
- Tips on engagement and on how each platform's algorithm ranks posts.
- A 6-step method for breaking down posts that went viral and reusing their patterns in your own voice.

## Install

With the [skills CLI](https://skills.sh):

```bash
npx skills add aslamdoctor/skills --skill social-content
```

Or clone the [skills repo](https://github.com/aslamdoctor/skills) and symlink this folder:

```bash
git clone https://github.com/aslamdoctor/skills ~/skills
ln -s ~/skills/skills/social-content ~/.claude/skills/social-content
```

## Usage

- "Write a LinkedIn post about remote work for engineering managers"
- "Give me a 6-tweet thread from this article" (paste or point to the file)
- "Plan a month of posts for a SaaS founder"
- "Why did this post do so well, and how can I write one like it?"

The [content-writer](../content-writer) skill uses this one to write `social-posts.md` in its content package.

## License

MIT
