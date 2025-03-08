# Eliza Slack Integration Setup Guide

This document provides a detailed summary of all the changes made to integrate Slack functionality into the Eliza project. Follow these steps to set up Slack integration from scratch.

## 1. System Prerequisites and Dependencies

We installed the following system packages using yum on Amazon Linux:

```bash
# Basic development tools for compiling native modules
sudo yum groupinstall -y "Development Tools"

# PostgreSQL and related packages
sudo yum install -y postgresql15 postgresql15-server postgresql15-contrib
```

These packages provide the necessary build tools and libraries for compiling native modules and running the database. The PostgreSQL packages were installed but we ended up using the built-in PGlite functionality instead.

## 2. Required NPM Packages

We installed the following NPM packages:

- `@slack/bolt`: The official Slack Bolt SDK for building Slack apps

```bash
# Within the plugin-slack directory
bun install
```

## 3. Database Migrations and Fixes

We needed to modify the database migration files to work with PGlite since it doesn't support vector extensions. Here's what we changed:

1. We modified the SQL migration file to comment out vector extensions:

```bash
# Edit the migration file:
cd packages/plugin-sql/drizzle/migrations/
```

```sql
-- In file 20250302132443_init.sql
-- Comment out extensions to avoid errors:
-- CREATE EXTENSION IF NOT EXISTS vector;
--> statement-breakpoint				
-- CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
--> statement-breakpoint

-- Change vector column types to jsonb:
CREATE TABLE "embeddings" (
	-- Instead of vector(384), etc.
	"dim_384" jsonb, 
	"dim_512" jsonb,
	"dim_768" jsonb,
	"dim_1024" jsonb,
	"dim_1536" jsonb,
	"dim_3072" jsonb,
	-- Rest of the schema remains the same
)
```

2. Then we ran the migrations to create the database schema:

```bash
cd /home/eliza/eliza-error/packages/plugin-sql && bun run migrate
```

## 4. Directory Structure

We created a custom Slack plugin with the following structure:

```
packages/plugin-slack/
  ├── src/
  │   ├── index.ts       # Main plugin export file
  │   └── service.ts     # Slack service implementation
  ├── package.json       # Plugin package configuration
  ├── tsconfig.json      # TypeScript configuration
  └── tsup.config.ts     # Build configuration
```

## 5. Plugin Implementation

### 5.1. Package Configuration (package.json)

```json
{
  "name": "@elizaos/plugin-slack",
  "version": "1.0.0-alpha.1",
  "type": "module",
  "main": "dist/index.js",
  "module": "dist/index.js",
  "types": "dist/index.d.ts",
  "publishConfig": {
    "access": "public"
  },
  "exports": {
    "package.json": "./package.json",
    ".": {
      "import": {
        "types": "./dist/index.d.ts",
        "default": "./dist/index.js"
      }
    }
  },
  "files": [
    "dist"
  ],
  "dependencies": {
    "@elizaos/core": "workspace:*",
    "@slack/bolt": "^3.17.1"
  },
  "devDependencies": {
    "tsup": "8.4.0"
  },
  "scripts": {
    "build": "tsup --format esm --dts",
    "dev": "tsup --format esm --dts --watch"
  },
  "peerDependencies": {
    "typescript": "5.8.2"
  }
}
```

### 5.2. TypeScript Configuration (tsconfig.json)

```json
{
  "extends": "../../tsconfig.json",
  "compilerOptions": {
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"],
  "references": [
    { "path": "../core" }
  ]
}
```

### 5.3. Build Configuration (tsup.config.ts)

```typescript
import { defineConfig } from "tsup";

export default defineConfig({
  clean: true,
  dts: true,
  entry: ["src/index.ts"],
  format: ["esm"],
  sourcemap: true,
  target: "esnext"
});
```

### 5.4. Plugin Entry Point (index.ts)

```typescript
import { Plugin } from "@elizaos/core";
import { SlackService, SLACK_SERVICE_NAME } from "./service";

/**
 * Slack plugin for ElizaOS
 * This plugin provides Slack integration capabilities to your agents
 */
const slackPlugin: Plugin = {
  name: "slack",
  description: "Slack client plugin",
  services: [SlackService],
  actions: [],
  providers: []
};

export default slackPlugin;
```

### 5.5. Slack Service Implementation (service.ts)

```typescript
import { App } from "@slack/bolt";
import { 
  IAgentRuntime, 
  logger, 
  Message, 
  MessageContent, 
  MessageType, 
  Role, 
  Service, 
  ServiceEvent, 
  ServiceEventType 
} from "@elizaos/core";

// Slack service constants
export const SLACK_SERVICE_NAME = "slack";

/**
 * Slack service for ElizaOS
 * This service handles integration with Slack using the Bolt SDK
 */
export class SlackService extends Service {
  private app: App | null = null;
  private isRunning = false;
  private port = 3000;
  private signingSecret = "";
  private token = "";
  private appToken = "";
  private botUserId = "";
  private messageCache: Record<string, Message[]> = {};

  constructor(runtime: IAgentRuntime) {
    super(SLACK_SERVICE_NAME, runtime);
    this.port = Number(runtime.secrets.SLACK_PORT || "3000");
    this.signingSecret = runtime.secrets.SLACK_SIGNING_SECRET as string;
    this.token = runtime.secrets.SLACK_BOT_TOKEN as string;
    this.appToken = runtime.secrets.SLACK_APP_TOKEN as string;
  }

  async start(): Promise<boolean> {
    if (!this.token || !this.signingSecret) {
      logger.error("Slack service missing required credentials");
      return false;
    }

    try {
      // Initialize the Slack app
      this.app = new App({
        token: this.token,
        signingSecret: this.signingSecret,
        socketMode: !!this.appToken,
        appToken: this.appToken || undefined,
        port: this.port
      });

      // Get bot info
      const authInfo = await this.app.client.auth.test();
      this.botUserId = authInfo.user_id as string;
      logger.info(`Slack bot authorized as: ${authInfo.user}`);

      // Handle message events
      this.app.event('message', async ({ event, say }) => {
        await this.handleMessage(event, say);
      });

      // Handle app_mention events
      this.app.event('app_mention', async ({ event, say }) => {
        await this.handleMention(event, say);
      });

      // Start the app
      await this.app.start();
      this.isRunning = true;
      logger.info(`Slack service started on port ${this.port}`);
      return true;
    } catch (error) {
      logger.error("Error starting Slack service:", error);
      return false;
    }
  }

  async stop(): Promise<void> {
    if (this.app && this.isRunning) {
      await this.app.stop();
      this.isRunning = false;
      logger.info("Slack service stopped");
    }
  }

  async isAvailable(): Promise<boolean> {
    return this.isRunning;
  }

  private async handleMessage(event: any, say: any): Promise<void> {
    // Ignore messages from the bot itself
    if (event.user === this.botUserId) return;

    // Ignore messages without text
    if (!event.text) return;

    // Create a message object
    const message: Message = {
      id: event.ts,
      parentId: event.thread_ts || null,
      timestamp: new Date(Number(event.ts) * 1000).toISOString(),
      channelId: event.channel,
      userId: event.user,
      username: await this.getUserName(event.user),
      role: Role.User,
      type: MessageType.Text,
      content: { text: event.text } as MessageContent,
      metadata: { rawEvent: event }
    };

    // Cache the message
    this.cacheMessage(event.channel, message);

    // Emit the message received event
    this.emit(ServiceEventType.MessageReceived, {
      service: this.name,
      type: ServiceEventType.MessageReceived,
      timestamp: new Date().toISOString(),
      data: {
        channelId: event.channel,
        threadId: event.thread_ts,
        message
      }
    } as ServiceEvent);
  }

  private async handleMention(event: any, say: any): Promise<void> {
    // Create a message object
    const message: Message = {
      id: event.ts,
      parentId: event.thread_ts || null,
      timestamp: new Date(Number(event.ts) * 1000).toISOString(),
      channelId: event.channel,
      userId: event.user,
      username: await this.getUserName(event.user),
      role: Role.User,
      type: MessageType.Text,
      content: { text: event.text } as MessageContent,
      metadata: { rawEvent: event, isMention: true }
    };

    // Cache the message
    this.cacheMessage(event.channel, message);

    // Emit the message received event
    this.emit(ServiceEventType.MessageReceived, {
      service: this.name,
      type: ServiceEventType.MessageReceived,
      timestamp: new Date().toISOString(),
      data: {
        channelId: event.channel,
        threadId: event.thread_ts,
        message
      }
    } as ServiceEvent);
  }

  private cacheMessage(channelId: string, message: Message): void {
    if (!this.messageCache[channelId]) {
      this.messageCache[channelId] = [];
    }
    this.messageCache[channelId].push(message);
    
    // Limit cache size to 100 messages per channel
    if (this.messageCache[channelId].length > 100) {
      this.messageCache[channelId].shift();
    }
  }

  private async getUserName(userId: string): Promise<string> {
    if (!this.app) return userId;
    
    try {
      const result = await this.app.client.users.info({ user: userId });
      return result.user?.name || userId;
    } catch (error) {
      logger.error(`Error getting user info for ${userId}:`, error);
      return userId;
    }
  }

  async sendMessage(channelId: string, text: string, threadId?: string): Promise<boolean> {
    if (!this.app || !this.isRunning) return false;

    try {
      await this.app.client.chat.postMessage({
        channel: channelId,
        text: text,
        thread_ts: threadId
      });
      return true;
    } catch (error) {
      logger.error("Error sending message to Slack:", error);
      return false;
    }
  }

  async getChannelHistory(channelId: string, limit = 10): Promise<Message[]> {
    return this.messageCache[channelId] || [];
  }
}
```

## 6. Character Configuration

We created a character configuration file `slack-character.json` in the root directory:

```json
{
  "name": "Eliza Slack Bot",
  "clients": ["slack"],
  "plugins": ["@elizaos/plugin-slack"],
  "bio": "I'm Eliza, an AI assistant powered by elizaOS that can help you with a variety of tasks.",
  "messageExamples": [
    [
      {
        "role": "user",
        "content": "Hello, who are you?"
      },
      {
        "role": "assistant",
        "content": "Hi there! I'm Eliza, an AI assistant powered by elizaOS. I'm here to help answer questions, provide information, and assist with various tasks. How can I help you today?"
      }
    ],
    [
      {
        "role": "user",
        "content": "What can you do?"
      },
      {
        "role": "assistant",
        "content": "I can help with a wide range of tasks, including:\n\n- Answering questions on various topics\n- Having casual conversations\n- Providing information about different subjects\n- Assisting with brainstorming ideas\n\nWhat would you like assistance with today?"
      }
    ]
  ],
  "postExamples": [
    "Just explored some fascinating research on AI agent frameworks. The future of human-AI collaboration looks promising with systems like elizaOS that enable richer interactions and more natural communication patterns.",
    "Have a coding problem you're stuck on? Don't hesitate to reach out - sometimes a quick conversation can help unblock your thinking and lead to solutions!"
  ],
  "topics": [
    "Artificial Intelligence",
    "Machine Learning",
    "Software Development",
    "Technology",
    "Problem Solving",
    "Data Science"
  ],
  "adjectives": [
    "helpful",
    "knowledgeable",
    "friendly",
    "considerate",
    "thoughtful"
  ],
  "settings": {
    "secrets": {
      "SLACK_BOT_TOKEN": "xoxb-your-token-here",
      "SLACK_SIGNING_SECRET": "your-signing-secret-here",
      "SLACK_APP_TOKEN": "xapp-your-app-token-here",
      "SLACK_PORT": "3000"
    }
  },
  "style": {
    "all": [
      "Be clear and concise in your responses",
      "Use a friendly and conversational tone",
      "Use proper grammar and punctuation",
      "Be encouraging and supportive"
    ],
    "chat": [
      "Use appropriate emoji sparingly to add warmth to responses",
      "Break up long responses into paragraphs for readability"
    ],
    "post": [
      "Keep posts concise and informative",
      "Include relevant hashtags when appropriate"
    ]
  }
}
```

## 7. Environment Configuration

We created a `.env` file in the root directory with Slack-specific configuration:

```
# Slack-specific environment variables
CHARACTER.ELIZA_SLACK_BOT.SLACK_BOT_TOKEN=xoxb-your-token-here
CHARACTER.ELIZA_SLACK_BOT.SLACK_SIGNING_SECRET=your-signing-secret-here
CHARACTER.ELIZA_SLACK_BOT.SLACK_APP_TOKEN=xapp-your-app-token-here
CHARACTER.ELIZA_SLACK_BOT.SLACK_PORT=3000
```

## 8. Start Script

We created a `start-slack.sh` script in the root directory to automate the build and startup process:

```bash
#!/bin/bash

# Build all necessary packages
cd packages/core && bun run build
cd ../plugin-sql && bun run build
cd ../cli && bun run build
cd ../plugin-slack && bun run build
cd ../the-org && bun run build
cd ../..

# Set the character path and run the application
export ELIZA_CHARACTER_PATH=$(pwd)/slack-character.json
export NODE_PATH=$NODE_PATH:$(pwd)/packages

echo "Starting Eliza with Slack character from: $ELIZA_CHARACTER_PATH"
echo "Make sure to update the Slack tokens in slack-character.json or .env file"

# Start elizaos
bun x elizaos start
```

## 9. Updates to package.json

We updated the root `package.json` to include convenience scripts for Slack integration:

```json
"scripts": {
  "setup": "cd packages/core && bun run build && cd ../plugin-sql && bun run build && cd ../cli && bun run build && cd ../plugin-slack && bun run build && cd ../the-org && bun run build && cd ../.. && bun install",
  "start": "cd packages/the-org && export ELIZA_CHARACTER_PATH=../../slack-character.json && bun run start",
  "start:slack": "export ELIZA_CHARACTER_PATH=slack-character.json && cd packages/the-org && bun run start"
}
```

## 10. Slack App Setup

To complete the setup, you'll need to:

1. Create a Slack app in the [Slack API Console](https://api.slack.com/apps)
2. Configure the Slack app with the following permissions:
   - `chat:write` - To send messages
   - `channels:history` - To read channel history
   - `app_mentions:read` - To listen for mentions
   - `channels:read` - To access channel information

3. Enable Event Subscriptions and subscribe to the following events:
   - `message.channels`
   - `app_mention`

4. Install the app to your workspace and obtain the following tokens:
   - Bot Token (`xoxb-...`)
   - Signing Secret
   - App Token (`xapp-...`) if using socket mode

5. Update your `slack-character.json` or `.env` file with the actual tokens.

## 11. Running the Integration

1. Make the start script executable:
   ```
   chmod +x start-slack.sh
   ```

2. Run the start script:
   ```
   ./start-slack.sh
   ```

This will build all necessary packages and start Eliza with the Slack character configuration.

## 12. Troubleshooting Common Issues

### Module Resolution Issues

If you encounter "Module not found" errors:

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/path/to/plugin-slack/dist/index.js'
```

Make sure to:
1. Check that all packages are properly built: `bun run setup`
2. Ensure the NODE_PATH environment variable includes your packages directory:
   ```bash
   export NODE_PATH=$NODE_PATH:$(pwd)/packages
   ```

### TypeScript Configuration Issues

If you see TypeScript errors related to the "composite" setting:

```
Referenced project 'packages/core' must have setting "composite": true
```

You might need to modify the main `tsconfig.json` in the root directory to include:

```json
{
  "compilerOptions": {
    "composite": true,
    // other options...
  }
}
```

### Database Migration Errors

If you get errors related to PostgreSQL extensions when running migrations:

```
error: extension "vector" is not available
```

Follow the steps in section 3 to modify the migration files to work with PGlite.

### Slack API Connectivity Issues

If the bot cannot connect to Slack:

1. Verify your tokens are correctly set in either `.env` or `slack-character.json`
2. Ensure your Slack app has the necessary scopes and event subscriptions
3. For debugging, check the logs for specific error messages:
   ```
   [TIMESTAMP] ERROR: Error starting Slack service: Error: An API error occurred: invalid_auth
   ```

### Socket Mode Issues

If you're using Socket mode (with the App Token) and encounter connection issues:

1. Ensure your App Token starts with `xapp-`
2. Verify you've enabled Socket Mode in your Slack app settings
3. Check network connectivity and firewall settings 