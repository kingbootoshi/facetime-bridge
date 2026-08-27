const SAMPLE_RATE = 48_000;
const LOCK_NAME = "facetime-control-audio-bridge";

export class FaceTimeAudioError extends Error {
  constructor(code, message, details = null) {
    super(message);
    this.name = "FaceTimeAudioError";
    this.code = code;
    this.details = details;
  }
}

function exactDevice(devices, kind, configuredLabel) {
  const accepted = new Set([configuredLabel, `${configuredLabel} (Virtual)`]);
  const matches = devices.filter((device) => device.kind === kind && accepted.has(device.label));
  if (matches.length !== 1) {
    throw new FaceTimeAudioError(
      "DEVICE_NOT_UNIQUE",
      `Expected one ${kind} named ${configuredLabel}; found ${matches.length}.`,
    );
  }
  return matches[0];
}

async function revealDeviceLabels() {
  let devices = await navigator.mediaDevices.enumerateDevices();
  if (devices.some((device) => device.kind === "audioinput" && device.label)) return devices;
  const permissionStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
  permissionStream.getTracks().forEach((track) => track.stop());
  devices = await navigator.mediaDevices.enumerateDevices();
  if (!devices.some((device) => device.kind === "audioinput" && device.label)) {
    throw new FaceTimeAudioError("DEVICE_LABELS_HIDDEN", "Microphone permission did not reveal audio device labels.");
  }
  return devices;
}

function assertCapabilities() {
  if (!navigator.mediaDevices?.getUserMedia || !navigator.mediaDevices?.enumerateDevices) {
    throw new FaceTimeAudioError("MEDIA_UNSUPPORTED", "This browser cannot enumerate audio devices.");
  }
  if (
    typeof window.MediaStreamTrackProcessor !== "function"
    || typeof window.MediaStreamTrackGenerator !== "function"
    || typeof window.AudioData !== "function"
  ) {
    throw new FaceTimeAudioError("AUDIO_DATA_UNSUPPORTED", "This browser cannot create the required mono AudioData track.");
  }
  if (!navigator.locks?.request) {
    throw new FaceTimeAudioError("SINGLETON_UNSUPPORTED", "This browser cannot enforce one active audio bridge.");
  }
  const supported = navigator.mediaDevices.getSupportedConstraints();
  for (const constraint of ["deviceId", "sampleRate", "channelCount", "echoCancellation", "noiseSuppression", "autoGainControl"]) {
    if (!supported[constraint]) {
      throw new FaceTimeAudioError("CONSTRAINT_UNSUPPORTED", `The browser cannot enforce ${constraint}.`);
    }
  }
}

async function acquireSingleton() {
  let acquiredResolve;
  let acquiredReject;
  let release;
  const acquired = new Promise((resolve, reject) => {
    acquiredResolve = resolve;
    acquiredReject = reject;
  });
  const hold = new Promise((resolve) => { release = resolve; });
  const task = navigator.locks.request(LOCK_NAME, { ifAvailable: true }, async (lock) => {
    if (!lock) {
      acquiredReject(new FaceTimeAudioError("BRIDGE_ALREADY_ACTIVE", "Another audio bridge is already active."));
      return;
    }
    acquiredResolve();
    await hold;
  });
  await acquired;
  return { release, task };
}

async function pumpStereoToMono(pipeline) {
  let left = new Float32Array(0);
  let right = new Float32Array(0);
  let mono = new Float32Array(0);
  try {
    while (!pipeline.stopping) {
      const next = await pipeline.reader.read();
      if (next.done) {
        if (pipeline.stopping) return;
        throw new FaceTimeAudioError("SOURCE_ENDED", "The BlackHole input track ended unexpectedly.");
      }
      const frame = next.value;
      let monoFrame;
      try {
        if (frame.sampleRate !== SAMPLE_RATE || frame.numberOfChannels !== 2 || frame.numberOfFrames <= 0) {
          throw new FaceTimeAudioError("FRAME_SHAPE_INVALID", "Expected a 48000 Hz stereo input frame.");
        }
        if (left.length !== frame.numberOfFrames) {
          left = new Float32Array(frame.numberOfFrames);
          right = new Float32Array(frame.numberOfFrames);
          mono = new Float32Array(frame.numberOfFrames);
        }
        frame.copyTo(left, { planeIndex: 0, format: "f32-planar" });
        frame.copyTo(right, { planeIndex: 1, format: "f32-planar" });
        for (let index = 0; index < frame.numberOfFrames; index += 1) mono[index] = (left[index] + right[index]) * 0.5;
        monoFrame = new AudioData({
          format: "f32-planar",
          sampleRate: SAMPLE_RATE,
          numberOfFrames: frame.numberOfFrames,
          numberOfChannels: 1,
          timestamp: frame.timestamp,
          duration: frame.duration,
          data: mono,
        });
        await pipeline.writer.write(monoFrame);
      } finally {
        monoFrame?.close();
        frame.close();
      }
    }
  } catch (error) {
    if (!pipeline.stopping) pipeline.failure = error;
  }
}

async function proveMonoTrack(track, pipeline) {
  const proofTrack = track.clone();
  const reader = new MediaStreamTrackProcessor({ track: proofTrack }).readable.getReader();
  let frame;
  let timer;
  try {
    const next = await Promise.race([
      reader.read(),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new FaceTimeAudioError("FRAME_PROOF_TIMEOUT", "Timed out proving the mono track.")), 3_000);
      }),
    ]);
    if (pipeline.failure) throw pipeline.failure;
    if (next.done || !next.value) throw new FaceTimeAudioError("FRAME_PROOF_MISSING", "The mono track ended before proof.");
    frame = next.value;
    const proof = {
      format: frame.format,
      sampleRate: frame.sampleRate,
      channels: frame.numberOfChannels,
      frames: frame.numberOfFrames,
    };
    if (proof.sampleRate !== SAMPLE_RATE || proof.channels !== 1) {
      throw new FaceTimeAudioError("FRAME_PROOF_INVALID", "Generated audio was not 48000 Hz mono.", proof);
    }
    return proof;
  } finally {
    clearTimeout(timer);
    frame?.close();
    await reader.cancel("proof complete").catch(() => undefined);
    proofTrack.stop();
  }
}

export class FaceTimeAudioBridge {
  static async open({ inputLabel = "BlackHole 16ch", outputLabel = "BlackHole 2ch" } = {}) {
    assertCapabilities();
    const singleton = await acquireSingleton();
    let sourceStream;
    let generator;
    let reader;
    let writer;
    try {
      const devices = await revealDeviceLabels();
      const input = exactDevice(devices, "audioinput", inputLabel);
      const output = exactDevice(devices, "audiooutput", outputLabel);
      const outputAudio = new Audio();
      outputAudio.autoplay = true;
      outputAudio.playsInline = true;
      if (typeof outputAudio.setSinkId !== "function") {
        throw new FaceTimeAudioError("OUTPUT_SELECTION_UNSUPPORTED", "This browser cannot select an audio output device.");
      }
      await outputAudio.setSinkId(output.deviceId);
      if (outputAudio.sinkId !== output.deviceId) throw new FaceTimeAudioError("OUTPUT_SELECTION_FAILED", "BlackHole 2ch was not applied.");
      sourceStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          deviceId: { exact: input.deviceId },
          sampleRate: { exact: SAMPLE_RATE },
          channelCount: { exact: 2 },
          echoCancellation: { exact: false },
          noiseSuppression: { exact: false },
          autoGainControl: { exact: false },
        },
        video: false,
      });
      const sourceTrack = sourceStream.getAudioTracks()[0];
      if (!sourceTrack) throw new FaceTimeAudioError("INPUT_MISSING", "BlackHole 16ch did not provide an audio track.");
      const settings = sourceTrack.getSettings();
      const expected = { deviceId: input.deviceId, sampleRate: SAMPLE_RATE, channelCount: 2, echoCancellation: false, noiseSuppression: false, autoGainControl: false };
      for (const [key, value] of Object.entries(expected)) {
        if (settings[key] !== value) throw new FaceTimeAudioError("INPUT_CONSTRAINT_FAILED", `Input did not apply ${key}.`);
      }
      reader = new MediaStreamTrackProcessor({ track: sourceTrack }).readable.getReader();
      generator = new MediaStreamTrackGenerator({ kind: "audio" });
      writer = generator.writable.getWriter();
      const pipeline = { reader, writer, generator, sourceStream, stopping: false, failure: null, pump: null };
      pipeline.pump = pumpStereoToMono(pipeline);
      const proof = await proveMonoTrack(generator, pipeline);
      const bridge = new FaceTimeAudioBridge(singleton, pipeline, outputAudio, proof, input, output);
      return bridge;
    } catch (error) {
      sourceStream?.getTracks().forEach((track) => track.stop());
      try { await reader?.cancel("open failed"); } catch {}
      try { await writer?.abort("open failed"); } catch {}
      try { generator?.stop(); } catch {}
      singleton.release();
      await singleton.task;
      throw error;
    }
  }

  constructor(singleton, pipeline, outputAudio, proof, input, output) {
    this.singleton = singleton;
    this.pipeline = pipeline;
    this.outputAudio = outputAudio;
    this.proof = proof;
    this.inputDevice = { label: input.label, deviceId: input.deviceId };
    this.outputDevice = { label: output.label, deviceId: output.deviceId };
    this.incomingStream = new MediaStream([pipeline.generator]);
    this.incomingTrack = pipeline.generator;
    this.closed = false;
  }

  async routeOutgoing(stream) {
    if (this.closed) throw new FaceTimeAudioError("BRIDGE_CLOSED", "The audio bridge is closed.");
    if (!(stream instanceof MediaStream) || stream.getAudioTracks().length === 0) {
      throw new FaceTimeAudioError("OUTGOING_STREAM_INVALID", "Outgoing audio must be a MediaStream with an audio track.");
    }
    this.outputAudio.srcObject = stream;
    await this.outputAudio.play();
  }

  clearOutgoing() {
    this.outputAudio.pause();
    this.outputAudio.srcObject = null;
  }

  async stop() {
    if (this.closed) return;
    this.closed = true;
    this.clearOutgoing();
    this.pipeline.stopping = true;
    const pending = [];
    try { pending.push(this.pipeline.reader.cancel("bridge stopped")); } catch {}
    try { pending.push(this.pipeline.writer.abort("bridge stopped")); } catch {}
    try { this.pipeline.generator.stop(); } catch {}
    this.pipeline.sourceStream.getTracks().forEach((track) => track.stop());
    if (this.pipeline.pump) pending.push(this.pipeline.pump);
    await Promise.allSettled(pending);
    this.singleton.release();
    await this.singleton.task;
  }
}
