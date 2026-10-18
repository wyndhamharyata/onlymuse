// The checks a saved value goes through as it comes back from the store.

export type Fields = Record<string, unknown>;

export function isText(value: unknown): value is string {
  return typeof value === "string";
}

export function isFields(value: unknown): value is Fields {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function hasText(fields: Fields, ...keys: string[]): boolean {
  return keys.every((key) => typeof fields[key] === "string");
}

export function hasNumber(fields: Fields, ...keys: string[]): boolean {
  return keys.every((key) => typeof fields[key] === "number" && Number.isFinite(fields[key]));
}

export function isWholeNumberIn(value: unknown, min: number, max: number): boolean {
  return Number.isInteger(value) && (value as number) >= min && (value as number) <= max;
}
