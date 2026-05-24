/**
 * ANSI-safe terminal wrapping (ported from nanocoder text-wrapping.ts).
 */

import wrapAnsi from "wrap-ansi";

/**
 * Wrap text to width, trimming word-wrap artifact spaces on continuation lines.
 * @param {string} text
 * @param {number} width
 * @returns {string}
 */
export function wrapWithTrimmedContinuations(text, width) {
  if (!text || width <= 0) return text ?? "";
  const originalLines = text.split("\n");
  const result = [];

  for (const line of originalLines) {
    if (line === "") {
      result.push("");
      continue;
    }
    const wrapped = wrapAnsi(line, width, { trim: false, hard: true });
    const subLines = wrapped.split("\n");

    result.push(subLines[0] ?? "");

    for (let i = 1; i < subLines.length; i++) {
      result.push((subLines[i] ?? "").replace(/^((?:\x1b\[[0-9;]*m)*)\s/, "$1"));
    }
  }

  return result.join("\n");
}

/** @returns {number} Usable terminal width for wrapping. */
export function getTerminalWidth() {
  const cols = process.stdout?.columns;
  if (cols && cols > 24) return cols - 2;
  return 80;
}

/**
 * Wrap plain text for streaming preview (no markdown).
 * @param {string} text
 * @param {number} [width]
 * @returns {string}
 */
export function wrapPlainText(text, width) {
  const w = width && width > 20 ? width : getTerminalWidth();
  return wrapWithTrimmedContinuations(text, w);
}
