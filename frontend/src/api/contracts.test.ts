import { describe, expect, it } from "vitest";

import { normalizeCurrency } from "./contracts";

describe("normalizeCurrency", () => {
  it("rejects a response with mixed currencies", () => {
    expect(() => normalizeCurrency(["USD", "IDR"])).toThrow("Mixed currencies");
  });
});
