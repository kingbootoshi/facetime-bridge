import { describe, expect, test } from "bun:test";
import {
  FaceTimeBridge,
  audioFormat,
  audioPacketKind,
  defaultSocketPath,
} from "../src/bridge.ts";

describe("bridge adapter contract", () => {
  test("loads the checked-in proto and exposes every RPC", () => {
    const bridge = new FaceTimeBridge("/tmp/facetime-bridge-adapter-test.sock");
    try {
      expect(typeof bridge.health).toBe("function");
      expect(typeof bridge.control).toBe("function");
      expect(typeof bridge.waitIncoming).toBe("function");
      expect(typeof bridge.audio).toBe("function");
    } finally {
      bridge.close();
    }
  });

  test("audio format matches the native daemon transport", () => {
    // AudioBridge.transportSampleRate in native/Sources/FaceTimeBridge/AudioBridge.swift
    expect(audioFormat).toEqual({
      sampleRate: 24_000,
      channels: 1,
      encoding: "s16le",
      bytesPerPacket: 4_800,
    });
  });

  test("packet kinds mirror AudioPacketKind proto values", () => {
    expect(audioPacketKind).toEqual({
      start: 1,
      capture: 2,
      playback: 3,
      clear: 4,
      stop: 5,
      event: 6,
    });
  });

  test("socket path honors FACETIME_BRIDGE_SOCKET override", () => {
    const prior = process.env.FACETIME_BRIDGE_SOCKET;
    process.env.FACETIME_BRIDGE_SOCKET = "/tmp/custom.sock";
    try {
      expect(defaultSocketPath()).toBe("/tmp/custom.sock");
    } finally {
      if (prior === undefined) delete process.env.FACETIME_BRIDGE_SOCKET;
      else process.env.FACETIME_BRIDGE_SOCKET = prior;
    }
  });
});
