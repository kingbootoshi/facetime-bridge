export const AUTHORIZED_CALLER_E164_ENV = "FACETIME_BRIDGE_AUTHORIZED_CALLER_E164";

export class AuthorizedCallerError extends Error {
  constructor(
    public readonly code: "AUTHORIZED_CALLER_MISSING" | "AUTHORIZED_CALLER_INVALID",
    message: string,
  ) {
    super(message);
    this.name = "AuthorizedCallerError";
  }
}

export function loadAuthorizedCallerE164(
  environment: Readonly<Record<string, string | undefined>> = process.env,
): string {
  const value = environment[AUTHORIZED_CALLER_E164_ENV];
  if (value === undefined) {
    throw new AuthorizedCallerError(
      "AUTHORIZED_CALLER_MISSING",
      `${AUTHORIZED_CALLER_E164_ENV} must be set to one E.164 phone number`,
    );
  }
  if (value.trim() !== value || !/^\+[1-9][0-9]{7,14}$/.test(value)) {
    throw new AuthorizedCallerError(
      "AUTHORIZED_CALLER_INVALID",
      `${AUTHORIZED_CALLER_E164_ENV} must be one exact E.164 phone number`,
    );
  }
  return value;
}
