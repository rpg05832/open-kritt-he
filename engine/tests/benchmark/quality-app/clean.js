// Benchmark project: the CORRECT counterpart. Any finding here is a false positive.
export function isFreeShipping(total) {
  const threshold = 200;
  return total >= threshold;
}
