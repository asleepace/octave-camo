/**
 * A small seeded generator (the Numerical Recipes LCG) for reproducible signals: the landing
 * demos and test clips. Uniform in [0, 1). Not for anything that must be unpredictable: the cloak's
 * noise and seeds come from crypto.getRandomValues.
 */
export function seededRandom(seed: number): () => number {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}
