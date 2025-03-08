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