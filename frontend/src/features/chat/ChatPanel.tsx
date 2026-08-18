import { useId, useState, type FormEvent } from "react";

import { ApiForbiddenError, ApiHttpError, ApiNetworkError } from "../../api/client";
import {
  isChartAction,
  isEvidence,
  type ChartAction,
  type CostFilter,
  type Evidence,
} from "../../api/contracts";
import { usePrefersReducedMotion } from "../../app/usePrefersReducedMotion";
import { DIMENSION_LABELS, METRIC_LABELS } from "../dashboard/useCostData";
import { EvidenceLink } from "./EvidenceLink";
import { useCostChat } from "./useCostChat";

export interface ChatPanelProps {
  filter: CostFilter | null;
  currency: string;
  onApplyEvidence: (evidence: Evidence) => void;
  onApplyAction: (action: ChartAction) => void;
}

export function ChatPanel({ filter, currency, onApplyEvidence, onApplyAction }: ChatPanelProps) {
  const ids = useId();
  const reducedMotion = usePrefersReducedMotion();
  const { messages, latest, isPending, error, canSend, send } = useCostChat(filter);
  const [prompt, setPrompt] = useState("");

  const sendable = canSend(prompt) && !isPending;

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!sendable) {
      return;
    }
    send(prompt);
    setPrompt("");
  };

  // Both gates run again here: the schema can only vouch for what came down this session's wire.
  const evidence = (latest?.evidence ?? []).filter(isEvidence);
  const actions = (latest?.chartActions ?? []).filter(isChartAction);
  const blockedNoteId = `${ids}-blocked`;

  return (
    <div className={`assistant${reducedMotion ? " assistant--still" : ""}`}>
      <ol className="assistant__log" role="log" aria-live="polite" aria-label="Conversation">
        {messages.length === 0 ? (
          <li className="assistant__hint">
            Ask about the figures on this page. Answers are grounded in the same cost data the
            charts draw from.
          </li>
        ) : null}
        {messages.map((message) => (
          <li key={message.id} className={`assistant__turn assistant__turn--${message.role}`}>
            <span className="assistant__role">{message.role === "user" ? "You" : "Copilot"}</span>
            {/* Plain text only: the answer is model output and is never treated as markup. */}
            <span className="assistant__text">{message.text}</span>
          </li>
        ))}
        {/* The wait is visible as a spinner-free busy button; this is the same fact, spoken. */}
        {isPending ? <li className="visually-hidden">Thinking…</li> : null}
      </ol>

      {error ? (
        <p className="assistant__error" role="alert">
          {describeError(error)}
        </p>
      ) : null}

      {latest && !latest.explanationAvailable ? (
        <p className="assistant__note">
          The written explanation is unavailable. The figures below still come from the cost data.
        </p>
      ) : null}

      {evidence.length > 0 ? (
        <section className="assistant__evidence" aria-label="Evidence">
          <h3 className="eyebrow">Evidence</h3>
          <ul>
            {evidence.map((item) => (
              <li key={`${item.dimension}-${item.periodStart}-${item.periodEnd}-${item.metric}`}>
                <EvidenceLink evidence={item} currency={currency} onApply={onApplyEvidence} />
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {actions.length > 0 ? (
        <div className="assistant__actions" role="group" aria-label="Chart actions">
          {actions.map((action, index) => (
            <button
              key={`${action.kind}-${index}`}
              type="button"
              className="assistant__action"
              onClick={() => onApplyAction(action)}
            >
              {describeAction(action)}
            </button>
          ))}
        </div>
      ) : null}

      <form className="assistant__compose" onSubmit={submit}>
        <label className="assistant__label" htmlFor={`${ids}-prompt`}>
          Ask about these costs
        </label>
        <textarea
          id={`${ids}-prompt`}
          className="assistant__input"
          rows={2}
          value={prompt}
          onChange={(event) => setPrompt(event.target.value)}
          aria-describedby={filter ? undefined : blockedNoteId}
        />
        <button
          type="submit"
          className="assistant__send"
          disabled={!sendable}
          aria-busy={isPending}
        >
          Send
        </button>
        {filter ? null : (
          <p id={blockedNoteId} className="assistant__note">
            Choose a period and a metric before asking a question.
          </p>
        )}
      </form>
    </div>
  );
}

function describeAction(action: ChartAction): string {
  if (action.kind === "highlight-series") {
    const where = action.grouping ? ` in ${DIMENSION_LABELS[action.grouping].toLowerCase()}` : "";
    return `Highlight ${action.value ?? "the series"}${where}`;
  }

  const parts: string[] = [];
  if (action.metric) {
    parts.push(METRIC_LABELS[action.metric].toLowerCase());
  }
  if (action.grouping) {
    parts.push(`grouped by ${DIMENSION_LABELS[action.grouping].toLowerCase()}`);
  }
  if (action.start && action.end) {
    parts.push(`${action.start} to ${action.end}`);
  }
  return parts.length > 0 ? `Show ${parts.join(", ")}` : "Apply the suggested filter";
}

/** Errors are described, never quoted: the underlying text can carry request or reply content. */
function describeError(error: Error): string {
  if (error instanceof ApiForbiddenError) {
    return "You do not have access to the cost assistant for this subscription.";
  }
  if (error instanceof ApiNetworkError) {
    return "The assistant could not be reached. Check your connection and ask again.";
  }
  if (error instanceof ApiHttpError && error.status === 422) {
    return "The assistant needs a period, a metric, and a grouping. Adjust the filters and ask again.";
  }
  return "The assistant could not answer that. Ask again, or narrow the period.";
}
