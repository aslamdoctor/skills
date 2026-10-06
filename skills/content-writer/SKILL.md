---
name: content-writer
description: "Orchestrates content creation for a topic. Creates a folder, generates social media posts, blog content, and cover image prompts in multiple styles. Use when user wants to create complete content package for a topic, or mentions 'content-writer', 'create content for topic', or 'full content package'."
---

# Content Writer

Generate a complete content package for any topic including social media posts, blog content, and cover image prompts.

## Usage

```bash
# Basic usage - provide a topic
/content-writer "The Future of AI in Healthcare"

# With output directory
/content-writer "Remote Work Best Practices" --output ./content

# Specify number of cover styles (default: 5)
/content-writer "Sustainable Living Tips" --styles 3
```

## Options

| Option | Description |
|--------|-------------|
| `--output <path>` | Output directory (default: `./content-packages`) |
| `--styles <number>` | Number of cover image styles to generate (default: 5) |

## Output Structure

```
content-packages/{topic-slug}/
├── social-posts.md          # Social media content for all platforms
├── blog-post.md             # Long-form blog/article content
└── cover-prompts/
    ├── cover-style-1.md     # Cover prompt in style 1
    ├── cover-style-2.md     # Cover prompt in style 2
    ├── cover-style-3.md     # Cover prompt in style 3
    ├── cover-style-4.md     # Cover prompt in style 4
    └── cover-style-5.md     # Cover prompt in style 5
```

## Workflow

### Step 1: Setup

1. **Parse input**:
   - Extract topic from user input
   - Generate slug from topic (lowercase, kebab-case, 2-5 words)
   - Example: "The Future of AI in Healthcare" → `future-ai-healthcare`

2. **Create folder structure**:
   ```
   {output-dir}/{topic-slug}/
   └── cover-prompts/
   ```

3. **Handle conflicts**:
   - If folder exists, append timestamp: `{slug}-YYYYMMDD-HHMMSS`

### Step 2: Generate Social Media Content

Use the `/social-content` skill to create platform-specific posts.

**Request from skill**:
- LinkedIn post (story format or educational)
- Twitter/X thread (5-7 tweets)
- Instagram caption (with carousel slide ideas)
- Short-form hooks for TikTok/Reels

**Save to**: `{topic-slug}/social-posts.md`

**File format**:
```markdown
# Social Media Content: {Topic}

Generated: {date}
Topic: {original topic}

---

## LinkedIn Post

{linkedin content}

---

## Twitter/X Thread

{twitter thread}

---

## Instagram

### Caption
{caption}

### Carousel Slides
{slide ideas}

---

## Short-form Video Hooks (TikTok/Reels)

{hooks and script ideas}
```

### Step 3: Generate Blog Content

Use the `/content-creator` skill to create long-form content.

**Request from skill**:
- SEO-optimized blog post (1500-2500 words)
- Include: introduction, main sections, conclusion
- Target keywords based on topic
- Meta description

**Save to**: `{topic-slug}/blog-post.md`

**File format**:
```markdown
# {Blog Title}

**Meta Description**: {meta description}
**Target Keywords**: {keywords}
**Word Count**: {count}

Generated: {date}

---

{full blog content with proper headings}
```

### Step 4: Generate Cover Image Prompts

Use the `/cover-image` skill concepts to create prompts for 5 different styles.

**Default styles to use** (select 5 varied styles):
1. `elegant` - Professional, sophisticated
2. `blueprint` - Technical, engineering feel
3. `warm` - Friendly, approachable
4. `dark-atmospheric` - Dramatic, cinematic
5. `playful` - Fun, creative

**Alternative style sets based on topic**:
- **Technical topics**: blueprint, notion, editorial-infographic, minimal, dark-atmospheric
- **Creative topics**: playful, watercolor, fantasy-animation, sketch-notes, warm
- **Business topics**: elegant, bold-editorial, minimal, notion, vintage
- **Lifestyle topics**: warm, watercolor, nature, playful, flat-doodle

**For each style, save to**: `{topic-slug}/cover-prompts/cover-{style-name}.md`

**Prompt file format**:
```markdown
# Cover Image Prompt: {Topic}

Style: {style name}
Aspect Ratio: 2.35:1 (cinematic)

---

## Prompt

Cover theme: {topic in 2-3 words}
Style: {style name}

Title text: {8 characters or less}
Subtitle: {optional}

Visual composition:
- Main visual: {description matching style}
- Layout: {positioning}
- Decorative elements: {style-appropriate elements}

Color scheme:
- Primary: {style primary color}
- Background: {style background color}
- Accent: {style accent color}

Style notes: {specific style characteristics}

---

## Style Reference

{Brief description of the style aesthetic}
```

### Step 5: Summary

After all content is generated, provide a summary:

```
Content Package Created!

Topic: {original topic}
Location: {full path to folder}

Generated Files:
├── social-posts.md      ✓
├── blog-post.md         ✓
└── cover-prompts/
    ├── cover-elegant.md           ✓
    ├── cover-blueprint.md         ✓
    ├── cover-warm.md              ✓
    ├── cover-dark-atmospheric.md  ✓
    └── cover-playful.md           ✓

Next steps:
1. Review and customize the social posts for your brand voice
2. Edit the blog post and run SEO optimization
3. Use cover prompts with your preferred image generator
```

## Style Reference

### Available Styles for Cover Prompts

| Style | Best For |
|-------|----------|
| `elegant` | Business, professional, strategy |
| `blueprint` | Technical, architecture, engineering |
| `warm` | Personal stories, growth, life lessons |
| `dark-atmospheric` | Premium, entertainment, cinematic |
| `playful` | Fun topics, beginners, casual |
| `minimal` | Zen, focus, simplicity |
| `notion` | SaaS, productivity, tools |
| `watercolor` | Lifestyle, travel, food |
| `vintage` | History, heritage, classic |
| `sketch-notes` | Educational, tutorials |
| `bold-editorial` | Marketing, launches, announcements |
| `pixel-art` | Gaming, retro tech, developer |
| `nature` | Wellness, eco, organic |
| `flat-doodle` | Apps, workflow, productivity |
| `fantasy-animation` | Storytelling, creative |

## Notes

- All content is generated as drafts - review and customize before publishing
- Social posts follow platform best practices from the social-content skill
- Blog content follows SEO guidelines from the content-creator skill
- Cover prompts can be used with any image generation tool (DALL-E, Midjourney, etc.)
- Adjust the styles based on your brand and topic nature
