/** Test helper: flight archives written the way adsb.lol writes them. */
/** An archive the way adsb.lol writes it (see FlightArchive.swift): a block table, then 10 s
 *  blocks, each a time marker and one record per aircraft. Shared with the wasm test. */
export function writeArchive(blocks: { time: number; aircraft: { id: number; lat: number; lon: number; feet: number; knots: number }[] }[]): Uint8Array<ArrayBuffer> {
  const words: number[] = [blocks.length, 0, 0, 0];
  for (let i = 1; i < blocks.length; i++) words.push(0, 0, 0, 0);       // offsets (unused by readers)
  for (const b of blocks) {
    const ms = Math.round(b.time * 1000);
    words.push(0x0e7f7c9d, Math.floor(ms / 2 ** 32) | 0, ms % 2 ** 32 | 0, 0);
    for (const a of b.aircraft) {
      const alt = Math.round(a.feet / 25) & 0xffff, gs = Math.round(a.knots * 10) & 0xffff;
      words.push(a.id, Math.round(a.lat * 1e6), Math.round(a.lon * 1e6), alt | (gs << 16));
    }
  }
  const out = new Uint8Array(words.length * 4), view = new DataView(out.buffer);
  words.forEach((w, i) => view.setInt32(i * 4, w | 0, true));
  return out;
}
