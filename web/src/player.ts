/** A/B playback of the original and cloaked audio, switchable without a gap. */

export type Side = "in" | "out";

export class Player {
  private ctx: AudioContext | null = null;
  private buffers: Partial<Record<Side, AudioBuffer>> = {};
  private nodes: { source: AudioBufferSourceNode; gain: GainNode; side: Side }[] = [];
  private startedAt = 0;
  private offset = 0;
  side: Side = "in";
  onEnd: () => void = () => {};

  get playing() { return this.nodes.length > 0; }
  get duration() { return this.buffers.in?.duration ?? 0; }
  has(side: Side) { return !!this.buffers[side]; }

  /** Current position, s. */
  get time(): number {
    if (!this.ctx || !this.playing) return this.offset;
    return Math.min(this.duration, this.offset + this.ctx.currentTime - this.startedAt);
  }

  private context(): AudioContext {
    this.ctx ??= new AudioContext();
    return this.ctx;
  }

  set(side: Side, channels: Float32Array[], sampleRate: number) {
    const ctx = this.context();
    const buffer = ctx.createBuffer(channels.length, channels[0]!.length, sampleRate);
    channels.forEach((ch, i) => buffer.copyToChannel(ch as Float32Array<ArrayBuffer>, i));
    const wasPlaying = this.playing, at = this.time;
    if (wasPlaying) this.stopNodes();
    this.buffers[side] = buffer;
    if (wasPlaying) this.play(at);
  }

  /** Forgets one side (e.g. a cloaked result that no longer matches); playback carries on with the other. */
  drop(side: Side) {
    if (!this.buffers[side]) return;
    const wasPlaying = this.playing, at = this.time;
    if (wasPlaying) this.stopNodes();
    delete this.buffers[side];
    if (this.side === side) this.side = "in";
    if (wasPlaying && this.buffers.in) void this.play(at);
  }

  clear() {
    this.stop();
    this.buffers = {};
    this.offset = 0;
    this.side = "in";
  }

  async play(from = this.offset) {
    const ctx = this.context();
    if (ctx.state === "suspended") await ctx.resume();
    this.stopNodes();
    this.offset = from >= this.duration - 0.05 ? 0 : from;
    this.startedAt = ctx.currentTime;
    for (const side of ["in", "out"] as const) {
      const buffer = this.buffers[side];
      if (!buffer) continue;
      const source = ctx.createBufferSource(), gain = ctx.createGain();
      source.buffer = buffer;
      gain.gain.value = side === this.side ? 1 : 0;
      source.connect(gain).connect(ctx.destination);
      source.start(0, this.offset);
      if (side === "in") source.onended = () => { if (this.nodes.some((n) => n.source === source)) this.finish(); };
      this.nodes.push({ source, gain, side });
    }
  }

  pause() {
    this.offset = this.time;
    this.stopNodes();
  }

  stop() {
    this.stopNodes();
    this.offset = 0;
  }

  seek(t: number) {
    if (this.playing) this.play(t);
    else this.offset = Math.max(0, Math.min(this.duration, t));
  }

  /** Switch sides with a 30 ms crossfade. */
  switchTo(side: Side) {
    if (!this.buffers[side]) return;
    this.side = side;
    const ctx = this.ctx;
    if (!ctx) return;
    for (const n of this.nodes) n.gain.gain.setTargetAtTime(n.side === side ? 1 : 0, ctx.currentTime, 0.01);
  }

  private finish() {
    this.stopNodes();
    this.offset = 0;
    this.onEnd();
  }

  private stopNodes() {
    for (const n of this.nodes) {
      n.source.onended = null;
      try { n.source.stop(); } catch { /* already stopped */ }
      n.source.disconnect();
    }
    this.nodes = [];
  }
}
