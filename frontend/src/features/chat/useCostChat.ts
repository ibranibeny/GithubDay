import { useMutation } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useRef, useState } from "react";

import { apiFetch, newCorrelationId } from "../../api/client";
import {
  parseChatResponse,
  type ChatRequest,
  type ChatResponse,
  type CostFilter,
} from "../../api/contracts";
import { getAccessToken } from "../../auth/msal";

export interface ChatSendOptions {
  correlationId: string;
  signal?: AbortSignal;
}

/**
 * The seam between the chat panel and the network, mirroring the cost gateway: production
 * injects the authenticated client, tests and the preview inject fixtures.
 */
export interface ChatGateway {
  send(request: ChatRequest, options: ChatSendOptions): Promise<ChatResponse>;
}

export const liveChatGateway: ChatGateway = {
  async send(request, { correlationId, signal }) {
    const raw = await apiFetch<unknown>("/api/chat", getAccessToken, {
      method: "POST",
      body: request,
      correlationId,
      signal,
    });
    // The reply is model-shaped output: it is validated before anything renders or is applied.
    return parseChatResponse(raw);
  },
};

export const ChatGatewayContext = createContext<ChatGateway>(liveChatGateway);

export type ChatRole = "user" | "assistant";

export interface ChatMessage {
  id: string;
  role: ChatRole;
  text: string;
}

export interface CostChat {
  messages: ChatMessage[];
  latest: ChatResponse | null;
  isPending: boolean;
  error: Error | null;
  canSend: (prompt: string) => boolean;
  send: (prompt: string) => void;
}

/** An unscoped question has no figures to ground it, so the filter is a hard precondition. */
export function canSendPrompt(prompt: string, filter: CostFilter | null | undefined): boolean {
  return prompt.trim().length > 0 && filter != null;
}

export function useCostChat(filter: CostFilter | null | undefined): CostChat {
  const gateway = useContext(ChatGatewayContext);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [latest, setLatest] = useState<ChatResponse | null>(null);
  const turnCount = useRef(0);

  const nextId = useCallback((role: ChatRole) => {
    turnCount.current += 1;
    return `${role}-${turnCount.current}`;
  }, []);

  const { mutate, isPending, error } = useMutation<
    ChatResponse,
    Error,
    { prompt: string; filters: CostFilter }
  >({
    mutationFn: (request) => gateway.send(request, { correlationId: newCorrelationId() }),
    retry: false,
    onSuccess: (response) => {
      setLatest(response);
      // An empty answer is still a turn: the evidence below it is what the reader came for.
      setMessages((current) => [
        ...current,
        { id: nextId("assistant"), role: "assistant", text: response.answer },
      ]);
    },
  });

  const canSend = useCallback((prompt: string) => canSendPrompt(prompt, filter), [filter]);

  const send = useCallback(
    (prompt: string) => {
      const trimmed = prompt.trim();
      if (!trimmed || !filter) {
        return;
      }
      setMessages((current) => [...current, { id: nextId("user"), role: "user", text: trimmed }]);
      mutate({ prompt: trimmed, filters: filter });
    },
    [filter, mutate, nextId],
  );

  return { messages, latest, isPending, error: error ?? null, canSend, send };
}
