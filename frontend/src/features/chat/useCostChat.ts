import { useMutation } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";

import { ApiHttpError, apiFetch, newCorrelationId } from "../../api/client";
import {
  parseChatResponse,
  type ChatRequest,
  type ChatResponse,
  type CostFilter,
} from "../../api/contracts";
import { getAccessToken } from "../../auth/msal";
import { trackApiFailure } from "../../telemetry/app-insights";

export interface ChatSendOptions {
  correlationId: string;
  signal?: AbortSignal;
}

/** What the panel asks, in the shape the dashboard already holds. */
export interface ChatAsk {
  prompt: string;
  filters: CostFilter;
}

/**
 * The seam between the chat panel and the network, mirroring the cost gateway: production
 * injects the authenticated client, tests and the preview inject fixtures.
 */
export interface ChatGateway {
  send(ask: ChatAsk, options: ChatSendOptions): Promise<ChatResponse>;
}

export const liveChatGateway: ChatGateway = {
  async send({ prompt, filters: filter }, { correlationId, signal }) {
    // The API names the window start/end and forbids unknown fields, so the UI's from/to is
    // translated here rather than posted and rejected.
    const request: ChatRequest = {
      prompt,
      filters: {
        start: filter.from,
        end: filter.to,
        metric: filter.metric,
        grouping: filter.grouping,
        ...(filter.grouping === "Tag" && filter.tagKey ? { tagKey: filter.tagKey } : {}),
      },
    };
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
  const inFlight = useRef<AbortController | null>(null);

  // A reply nobody is waiting for still costs the model and the reader's battery.
  useEffect(() => () => inFlight.current?.abort(), []);

  const nextId = useCallback((role: ChatRole) => {
    turnCount.current += 1;
    return `${role}-${turnCount.current}`;
  }, []);

  const { mutate, isPending, error } = useMutation<ChatResponse, Error, ChatAsk>({
    mutationFn: async (ask) => {
      inFlight.current?.abort();
      const controller = new AbortController();
      inFlight.current = controller;
      const correlationId = newCorrelationId();
      try {
        return await gateway.send(ask, { correlationId, signal: controller.signal });
      } catch (failure) {
        // A superseded turn is not a failure worth reporting, and its id would be misleading.
        if (!controller.signal.aborted) {
          trackApiFailure({
            correlationId,
            status: failure instanceof ApiHttpError ? failure.status : undefined,
          });
        }
        throw failure;
      }
    },
    retry: false,
    // The previous answer's evidence must not sit beside this turn's error.
    onMutate: () => setLatest(null),
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
