# Cover Image

An agent skill that reads an article and makes a hand-drawn style cover image for it. It picks a style that suits the content, or uses the one you name, from 20 styles.

```
/cover-image path/to/article.md
```

## What you get

```
cover-image/{topic-slug}/
├── source-article.md    copy of the input
├── prompts/
│   └── cover.md         the full image prompt
└── cover.png
```

- It confirms style, aspect ratio, title and language with you before it generates anything.
- The image itself comes from whichever image generation skill your agent has. If there are several, it asks which one to use. With none, you still get the prompt in `prompts/cover.md`.
- If the topic folder already exists, a timestamp is added to the new folder name.

## Styles

elegant, blueprint, warm, dark-atmospheric, playful, minimal, notion, watercolor, vintage, sketch-notes, bold-editorial, pixel-art, nature, flat-doodle, fantasy-animation, chalkboard, retro, vector-illustration, editorial-infographic, intuition-machine

Each style is described in `references/styles/<name>.md`.

## Install

With the [skills CLI](https://skills.sh):

```bash
npx skills add aslamdoctor/skills --skill cover-image
```

Or clone the [skills repo](https://github.com/aslamdoctor/skills) and symlink this folder:

```bash
git clone https://github.com/aslamdoctor/skills ~/skills
ln -s ~/skills/skills/cover-image ~/.claude/skills/cover-image
```

## Usage

```
/cover-image path/to/article.md
/cover-image path/to/article.md --style blueprint
/cover-image path/to/article.md --style minimal --no-title
/cover-image --style playful        then paste the content
```

| Option | Description |
|---|---|
| `--style <name>` | One of the styles above. Picked from the content if left out |
| `--aspect <ratio>` | `2.35:1` (default), `16:9` or `1:1` |
| `--lang <code>` | Language for the title text (`en`, `zh`, `ja` and so on) |
| `--no-title` | Image only, no title text |

## Custom styles

Put an `EXTEND.md` in `.skills/cover-image/` (per project) or `~/.skills/cover-image/` (for you) to add styles or change defaults. The project file wins.

## Credits

Adapted from [baoyu-cover-image](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-cover-image) by Jim Liu ([JimLiu/baoyu-skills](https://github.com/JimLiu/baoyu-skills)).

## License

MIT
