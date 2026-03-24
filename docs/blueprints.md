# Blueprints

Blueprints are ready-to-use templates for Autobot — complete configurations with personalities, skills, and integrations that you can clone and customize.

Browse all blueprints: [github.com/crystal-autobot/blueprints](https://github.com/crystal-autobot/blueprints)

## Available blueprints

| Blueprint | Description | Highlights |
|-----------|-------------|------------|
| **Optimus** | General-purpose autobot with all features enabled | Telegram, Slack, web search, image generation, sandbox, custom skills |
| **Bumblebee** | Training assistant with fitness integrations | Strava, Garmin MCP, workout tracking, progress charts |
| **Blaster** | Language learning companion | Conversation practice, vocabulary tracking, quizzes, flashcards |
| **Red Alert** | Smart home monitor connected to Home Assistant | Device control, sensor charts, automations |

## Quick start

```bash
# Clone the blueprints repo
git clone https://github.com/crystal-autobot/blueprints.git
cd blueprints

# Copy a blueprint to your working directory
cp -r autobots/optimus ~/my-autobot
cd ~/my-autobot

# Configure
cp .env.example .env
# Edit .env with your API keys

# Run
autobot gateway
```

## Blueprint structure

Each blueprint is a self-contained directory:

```
blueprint/
├── config.yml              # Main configuration (model, channels, tools, MCP)
├── .env.example            # Environment variables template
├── .gitignore              # Sensible defaults for secrets and logs
├── Dockerfile.sandbox      # Custom sandbox image for code execution
└── workspace/
    ├── SOUL.md             # Bot personality and character
    ├── AGENTS.md           # Agent instructions and behavior rules
    ├── USER.md             # User preferences (timezone, language, style)
    └── skills/             # Custom skills (bash scripts, Python tools)
```

## Blueprints vs `autobot new`

| | `autobot new` | Blueprints |
|---|---|---|
| **Purpose** | Minimal starter config | Full, themed configurations |
| **Personality** | Generic defaults | Unique character and tone |
| **Skills** | None | Pre-built custom skills |
| **MCP servers** | None | Pre-configured integrations |
| **Best for** | Starting from scratch | Getting started quickly with a use case |

Both produce the same directory structure — blueprints just come with more out of the box.

## Customization

Key files to customize after copying a blueprint:

| File | What to change |
|------|---------------|
| `config.yml` | Model, channels, MCP servers, tool settings |
| `.env` | API keys and credentials |
| `workspace/SOUL.md` | Bot personality, tone, values |
| `workspace/AGENTS.md` | Behavior rules, response guidelines |
| `workspace/USER.md` | Your preferences and context |
| `workspace/skills/` | Add custom skills your bot can use |

## Contributing

Have a cool autobot setup? Submit it as a blueprint:

1. Fork [crystal-autobot/blueprints](https://github.com/crystal-autobot/blueprints)
2. Create a new directory under `autobots/`
3. Include `README.md`, `config.yml`, `.env.example`, and workspace files
4. Submit a pull request
