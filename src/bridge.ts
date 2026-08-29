// Base adapter for plugging any voice stack into facetime-bridge.
// See docs/INTEGRATION.md for the full contract and examples.
import { join } from "node:path";
import { homedir } from "node:os";
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";

const PROTO_PATH = join(
  import.meta.dir,
  "../native/Sources/FaceTimeBridge/Protos/facetime_media.proto",
);

/** Daemon socket: FACETIME_BRIDGE_SOCKET env override, else the daemon default. */
export function defaultSocketPath(): string {
  return process.env.FACETIME_BRIDGE_SOCKET ?? join(homedir(), ".facetime-bridge", "bridge.sock");
}

export type ControlCommand = "probe" | "call" | "answer" | "hangup";

export type ControlReply = {
  ok: boolean;
  state: string;
  authorized: boolean;
  action: string;
  errorCode: string;
  message: string;
};

export type CallEvent = {
  state: string;
  authorized: boolean;
  errorCode: string;
  observedAtMs: string | number;
};

export type AudioPacket = {
  callId: string;
  kind: number;
  pcm16: Buffer;
  sampleRate: number;
  channels: number;
  sequence: string | number;
  event: string;
};

export type HealthReply = {
  ready: boolean;
  inputDevice: string;
  outputDevice: string;
};

/** Audio transport contract: 24 kHz, mono, signed 16-bit little-endian PCM. */
export const audioFormat = {
  sampleRate: 24_000,
  channels: 1,
  encoding: "s16le",
  /** Typical daemon packet cadence: ~100 ms => 2400 samples => 4800 bytes. */
  bytesPerPacket: 4_800,
} as const;

export const audioPacketKind = {
  start: 1,
  capture: 2,
  playback: 3,
  clear: 4,
  stop: 5,
  event: 6,
} as const;

type UnaryCallback<T> = (error: grpc.ServiceError | null, value: T) => void;

interface FaceTimeMediaClient extends grpc.Client {
  health(request: Record<string, never>, callback: UnaryCallback<HealthReply>): void;
  control(request: { command: number }, callback: UnaryCallback<ControlReply>): void;
  waitIncoming(request: Record<string, never>): grpc.ClientReadableStream<CallEvent>;
  audio(): grpc.ClientDuplexStream<AudioPacket, AudioPacket>;
}

type FaceTimeMediaClientConstructor = new (
  address: string,
  credentials: grpc.ChannelCredentials,
) => FaceTimeMediaClient;

type LoadedContract = {
  facetimebridge: {
    v1: {
      FaceTimeMedia: FaceTimeMediaClientConstructor;
    };
  };
};

const definition = protoLoader.loadSync(PROTO_PATH, {
  defaults: true,
  enums: Number,
  longs: String,
  oneofs: true,
});
// proto-loader returns a runtime-generated object whose shape is fixed by the checked-in proto.
const contract = grpc.loadPackageDefinition(definition) as unknown as LoadedContract;
const Client = contract.facetimebridge.v1.FaceTimeMedia;

const commandValues: Record<ControlCommand, number> = {
  probe: 1,
  call: 2,
  answer: 3,
  hangup: 4,
};

/**
 * Thin, dependency-light client over the daemon's Unix-socket gRPC surface.
 * One instance per consumer; call close() when done.
 */
export class FaceTimeBridge {
  private readonly client: FaceTimeMediaClient;

  constructor(socketPath: string = defaultSocketPath()) {
    this.client = new Client(`unix:${socketPath}`, grpc.credentials.createInsecure());
  }

  /** Daemon readiness plus the exact BlackHole devices it bound. */
  health(): Promise<HealthReply> {
    const gate = Promise.withResolvers<HealthReply>();
    this.client.health({}, (error, value) => (error ? gate.reject(error) : gate.resolve(value)));
    return gate.promise;
  }

  /**
   * Semantic call control. Every mutating command is authority-gated by the
   * daemon: unconfigured or unauthorized targets fail closed with an errorCode.
   */
  control(command: ControlCommand): Promise<ControlReply> {
    const gate = Promise.withResolvers<ControlReply>();
    this.client.control({ command: commandValues[command] }, (error, value) =>
      error ? gate.reject(error) : gate.resolve(value),
    );
    return gate.promise;
  }

  /** Server stream of call-state transitions (ring, connected, ended, ...). */
  waitIncoming(): grpc.ClientReadableStream<CallEvent> {
    return this.client.waitIncoming({});
  }

  /**
   * Bidirectional audio. Read `capture` packets (caller voice), write
   * `playback` packets (your agent's voice) in the `audioFormat` contract.
   */
  audio(): grpc.ClientDuplexStream<AudioPacket, AudioPacket> {
    return this.client.audio();
  }

  close(): void {
    this.client.close();
  }
}
