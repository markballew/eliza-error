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