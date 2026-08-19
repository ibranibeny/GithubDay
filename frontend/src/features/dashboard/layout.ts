/**
 * Fixed geometry the dashboard reserves before data arrives. Skeletons and charts share these
 * numbers so a slow query never reflows the page, and collapsing the chat rail changes width
 * only -- never height.
 */
export const TREND_CHART_HEIGHT = 320;
export const DONUT_CHART_HEIGHT = 168;
export const KPI_BLOCK_HEIGHT = 96;
export const CHAT_RAIL_WIDTH = 360;
