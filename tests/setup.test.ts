import { describe, expect, test } from "bun:test";
import { brewExecutableFor, missingPackageError, validateBlackHoleCasks } from "../src/commands/setup.ts";

describe("controlled setup", () => {
  test("uses the fixed Homebrew prefix for each supported architecture", () => {
    expect(brewExecutableFor("arm64")).toBe("/opt/homebrew/bin/brew");
    expect(brewExecutableFor("x64")).toBe("/usr/local/bin/brew");
    expect(() => brewExecutableFor("unsupported")).toThrow("unsupported macOS architecture");
  });

  test("requires a separate explicit install for only missing casks", () => {
    expect(missingPackageError("/opt/homebrew/bin/brew", ["blackhole-16ch"]).message).toBe(
      "Missing official Homebrew package: blackhole-16ch. Run explicitly: /opt/homebrew/bin/brew install --cask blackhole-16ch",
    );
    expect(missingPackageError("/opt/homebrew/bin/brew", ["blackhole-2ch", "blackhole-16ch"]).message).toBe(
      "Missing official Homebrew packages: blackhole-2ch, blackhole-16ch. Run explicitly: /opt/homebrew/bin/brew install --cask blackhole-2ch blackhole-16ch",
    );
  });

  test("accepts only official Homebrew BlackHole cask metadata", () => {
    const official = {
      casks: [
        {
          token: "blackhole-2ch",
          tap: "homebrew/cask",
          homepage: "https://existential.audio/blackhole/",
          url: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg",
        },
        {
          token: "blackhole-16ch",
          tap: "homebrew/cask",
          homepage: "https://existential.audio/blackhole/",
          url: "https://existential.audio/downloads/BlackHole16ch-0.7.1.pkg",
        },
      ],
    };
    expect(() => validateBlackHoleCasks(official)).not.toThrow();
    expect(() =>
      validateBlackHoleCasks({
        casks: [{ ...official.casks[0], tap: "untrusted/tap" }, official.casks[1]],
      }),
    ).toThrow("untrusted BlackHole cask metadata");
    expect(() =>
      validateBlackHoleCasks({
        casks: [{ ...official.casks[0], url: "https://example.com/BlackHole.pkg" }, official.casks[1]],
      }),
    ).toThrow("untrusted BlackHole cask metadata");
  });
});
