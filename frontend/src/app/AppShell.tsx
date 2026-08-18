import {
  Activity,
  Boxes,
  ChartPie,
  CircleQuestionMark,
  KeyRound,
  LayoutDashboard,
  PanelRightClose,
  PanelRightOpen,
  ScrollText,
  type LucideIcon,
} from "lucide-react";
import { useState, type ReactNode } from "react";

interface NavItem {
  label: string;
  icon: LucideIcon;
}

const NAV_ITEMS: NavItem[] = [
  { label: "Overview", icon: LayoutDashboard },
  { label: "Activity log", icon: ScrollText },
  { label: "Access control", icon: KeyRound },
  { label: "Resources", icon: Boxes },
  { label: "Cost analysis", icon: ChartPie },
  { label: "Monitoring", icon: Activity },
  { label: "Help", icon: CircleQuestionMark },
];

const SELECTED = "Cost analysis";

export interface AppShellProps {
  children: ReactNode;
  chat?: ReactNode;
}

/**
 * Three columns: navigation, workspace, assistant. Only the middle column scrolls, and the
 * assistant collapses in width alone, so the charts never change height when it opens or closes.
 */
export function AppShell({ children, chat }: AppShellProps) {
  const [chatOpen, setChatOpen] = useState(true);

  return (
    <div className={`shell${chatOpen ? "" : " shell--chat-closed"}`}>
      <nav className="rail" aria-label="Subscription sections">
        <ul>
          {NAV_ITEMS.map(({ label, icon: Icon }) =>
            label === SELECTED ? (
              <li key={label}>
                <span className="rail__item rail__item--current" aria-current="page">
                  <Icon size={16} aria-hidden />
                  <span className="rail__label">{label}</span>
                </span>
              </li>
            ) : (
              <li key={label}>
                {/* Not a dead link and not a silent `disabled`: focusable, so a keyboard or
                    screen reader user is told why the section does nothing. */}
                <button
                  type="button"
                  className="rail__item"
                  aria-disabled="true"
                  onClick={(event) => event.preventDefault()}
                  title={`${label} is not part of this build`}
                >
                  <Icon size={16} aria-hidden />
                  <span className="rail__label">{label}</span>
                  <span className="visually-hidden">(not available in this build)</span>
                </button>
              </li>
            ),
          )}
        </ul>
      </nav>

      <div className="workspace">{children}</div>

      <aside className="chat" aria-label="Cost assistant">
        <div className="chat__head">
          <h2 className="eyebrow">Copilot</h2>
          <button
            type="button"
            className="chat__toggle"
            aria-expanded={chatOpen}
            onClick={() => setChatOpen((open) => !open)}
          >
            {chatOpen ? (
              <PanelRightClose size={16} aria-hidden />
            ) : (
              <PanelRightOpen size={16} aria-hidden />
            )}
            <span className="visually-hidden">
              {chatOpen ? "Collapse the cost assistant" : "Expand the cost assistant"}
            </span>
          </button>
        </div>
        {chatOpen ? (
          <div className="chat__body">
            {chat ?? (
              <p className="chat__empty">
                The cost assistant is not connected in this build. Grounded answers about the
                figures on this page arrive with the chat endpoint.
              </p>
            )}
          </div>
        ) : null}
      </aside>
    </div>
  );
}
