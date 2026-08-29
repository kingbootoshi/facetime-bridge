import { describe, expect, test } from "bun:test";
import {
  AUTHORIZED_CALLER_E164_ENV,
  AuthorizedCallerError,
  loadAuthorizedCallerE164,
} from "../src/config.ts";

describe("caller authority environment", () => {
  test("loads one exact E.164 phone number from the canonical variable", () => {
    expect(loadAuthorizedCallerE164({ [AUTHORIZED_CALLER_E164_ENV]: "+15550101001" })).toBe("+15550101001");
  });

  test("fails closed when caller authority is missing", () => {
    expect(() => loadAuthorizedCallerE164({})).toThrow(AuthorizedCallerError);
    try {
      loadAuthorizedCallerE164({});
    } catch (error) {
      expect(error).toMatchObject({ code: "AUTHORIZED_CALLER_MISSING" });
    }
  });

  test("rejects every non-E.164 authority value", () => {
    for (const value of [
      "",
      " +15550101001",
      "+15550101001 ",
      "+15550101001\n",
      "+١٥٥٥٠١٠١٠٠١",
      "+05550101001",
      "+1234567",
      "+1234567890123456",
      "caller@example.invalid",
      "Untrusted Display Label",
    ]) {
      expect(() => loadAuthorizedCallerE164({ [AUTHORIZED_CALLER_E164_ENV]: value })).toThrow(
        AuthorizedCallerError,
      );
    }
  });

  test("does not infer authority from any other variable", () => {
    expect(() => loadAuthorizedCallerE164({ AUTHORIZED_CALLER_E164: "+15550101001" })).toThrow(
      "must be set",
    );
  });
});
