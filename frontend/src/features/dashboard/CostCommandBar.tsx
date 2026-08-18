import { Download, RefreshCw } from "lucide-react";

import { formatDayLabel } from "./format";

export interface CostCommandBarProps {
  onRefresh: () => void;
  onDownload: () => void;
  isFetching: boolean;
  canDownload: boolean;
  dataFreshness: string | null;
  reratingNotice: string | null;
}

export function CostCommandBar({
  onRefresh,
  onDownload,
  isFetching,
  canDownload,
  dataFreshness,
  reratingNotice,
}: CostCommandBarProps) {
  return (
    <div className="commandbar">
      <button type="button" className="command" onClick={onRefresh}>
        <RefreshCw size={14} aria-hidden className={isFetching ? "spin" : undefined} />
        Refresh
      </button>
      <button type="button" className="command" onClick={onDownload} disabled={!canDownload}>
        <Download size={14} aria-hidden />
        Download CSV
      </button>
      <p className="commandbar__note" role="status">
        {dataFreshness ? (
          <>
            <span className="num">{formatDayLabel(dataFreshness)}</span> is the last complete day of
            usage.
          </>
        ) : (
          "Waiting for the first complete day of usage."
        )}
        {reratingNotice ? ` ${reratingNotice}` : ""}
      </p>
    </div>
  );
}
