/**
 * Jackal Markdown Parser — terminal-ready ANSI markdown rendering.
 *
 * Ported from nanocoder's `source/markdown-parser/index.ts`.
 * Converts markdown to ANSI-colored strings using chalk + cli-highlight.
 *
 * Returns structured parts (text / code) so the Ink UI can render code blocks
 * without a left border for clean terminal copy/paste.
 *
 * Usage from .cl.jac (after jac-ink compilation):
 *   import from "./markdown.mjs" { parseMarkdownParts, parseMarkdown };
 */

// Force color output BEFORE chalk/cli-highlight import — Ink renders ANSI
// escape codes regardless of stdout.isTTY, so we always want color output.
process.env.FORCE_COLOR = "1";

import chalk from "chalk";

// Ensure chalk level is forced (belt + suspenders)
if (chalk.level === 0) {
  chalk.level = 3;
}

// Dynamic import for cli-highlight so FORCE_COLOR is set first.
const { highlight } = await import("cli-highlight");

// ---------------------------------------------------------------------------
// HTML entity decoding (subset from nanocoder)
// ---------------------------------------------------------------------------

const HTML_ENTITIES = {
  "&nbsp;": " ",
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&apos;": "'",
  "&copy;": "\u00a9",
  "&reg;": "\u00ae",
  "&trade;": "\u2122",
  "&ndash;": "\u2013",
  "&mdash;": "\u2014",
  "&hellip;": "\u2026",
  "&bull;": "\u2022",
};

function decodeHtmlEntities(text) {
  let result = text;
  for (const [entity, char] of Object.entries(HTML_ENTITIES)) {
    result = result.replaceAll(entity, char);
  }
  result = result.replace(/&#(\d+);/g, (_, code) =>
    String.fromCharCode(parseInt(code, 10)),
  );
  result = result.replace(/&#x([0-9A-Fa-f]+);/g, (_, code) =>
    String.fromCharCode(parseInt(code, 16)),
  );
  return result;
}

// ---------------------------------------------------------------------------
// Theme color helpers
// ---------------------------------------------------------------------------

const DEFAULT_COLORS = {
  primary: "green",
  secondary: "gray",
  info: "cyan",
  text: "white",
  tool: "blue",
  accent: "magenta",
  warning: "yellow",
  error: "red",
  success: "green",
};

function resolveColors(themeColors) {
  if (!themeColors) return DEFAULT_COLORS;
  return { ...DEFAULT_COLORS, ...themeColors };
}

// Map common color names to hex for chalk.
function colorToHex(name) {
  const map = {
    green: "#00ff00",
    gray: "#888888",
    grey: "#888888",
    cyan: "#00ffff",
    white: "#ffffff",
    blue: "#4444ff",
    magenta: "#ff00ff",
    yellow: "#ffff00",
    red: "#ff0000",
    black: "#000000",
  };
  return map[name] || "#ffffff";
}

// ---------------------------------------------------------------------------
// Core parser (returns placeholder markers for code blocks)
// ---------------------------------------------------------------------------

function parseMarkdownCore(text, themeColors, width) {
  const colors = resolveColors(themeColors);

  // Step 0: Decode HTML entities
  let result = decodeHtmlEntities(text);

  // Step 1: Convert <br> tags
  result = result.replace(/<br\s*\/?>/gi, "\n");

  // Step 2: Extract fenced code blocks with placeholders
  const codeBlocks = [];
  result = result.replace(
    /^([ \t]*)```([a-zA-Z0-9\-+#]*)\n([\s\S]*?)^\1```/gm,
    (_match, indent, lang, code) => {
      const dedented = indent
        ? code
            .split("\n")
            .map((line) =>
              line.startsWith(indent) ? line.slice(indent.length) : line,
            )
            .join("\n")
        : code;
      try {
        const codeStr = dedented.trim().replace(/\t/g, "  ");
        const highlighted = highlight(codeStr, {
          language: lang || "plaintext",
          theme: "default",
        });
        const placeholder = `__CODE_BLOCK_${codeBlocks.length}__`;
        codeBlocks.push(highlighted);
        return placeholder;
      } catch {
        const formatted = chalk.hex(colorToHex(colors.tool))(
          dedented.trim().replace(/\t/g, "  "),
        );
        const placeholder = `__CODE_BLOCK_${codeBlocks.length}__`;
        codeBlocks.push(formatted);
        return placeholder;
      }
    },
  );

  // Step 3: Extract inline code with placeholders
  const inlineCodes = [];
  result = result.replace(/`([^`\n]+)`/g, (_match, code) => {
    const formatted = chalk.hex(colorToHex(colors.tool))(String(code).trim());
    const placeholder = `__INLINE_CODE_${inlineCodes.length}__`;
    inlineCodes.push(formatted);
    return placeholder;
  });

  // Step 4: Process markdown formatting (code is now protected)

  // Lists FIRST (before italic, since * at start of line is a list marker)
  result = result.replace(
    /^([ \t]*)[-*]\s+(.+)$/gm,
    (_match, indent, txt) =>
      indent + chalk.hex(colorToHex(colors.text))(`\u2022 ${txt}`),
  );
  result = result.replace(
    /^([ \t]*)(\d+)\.\s+(.+)$/gm,
    (_match, indent, num, txt) =>
      indent + chalk.hex(colorToHex(colors.text))(`${num}. ${txt}`),
  );

  // Bold (**text** — avoid __ to prevent conflicts with snake_case)
  result = result.replace(/\*\*([^*]+)\*\*/g, (_match, txt) =>
    chalk.hex(colorToHex(colors.text)).bold(txt),
  );

  // Italic (*text* — avoid _ to prevent conflicts with snake_case)
  result = result.replace(
    /(^|\s)\*([^*\n]*[a-zA-Z][^*\n]*)\*($|\s)/gm,
    (_match, before, txt, after) =>
      before + chalk.hex(colorToHex(colors.text)).italic(txt) + after,
  );

  // Headings (# Heading)
  result = result.replace(/^#{1,6}\s+(.+)$/gm, (_match, txt) =>
    chalk.hex(colorToHex(colors.primary)).bold(txt),
  );

  // Links [text](url)
  result = result.replace(
    /\[([^\]]+)\]\(([^)]+)\)/g,
    (_match, txt, url) =>
      chalk.hex(colorToHex(colors.info)).underline(txt) +
      " " +
      chalk.hex(colorToHex(colors.secondary))(`(${url})`),
  );

  // Blockquotes (> text)
  result = result.replace(/^>\s+(.+)$/gm, (_match, txt) =>
    chalk.hex(colorToHex(colors.secondary)).italic(`> ${txt}`),
  );

  // Horizontal rules (--- or ***)
  result = result.replace(/^(---|\*\*\*|___)\s*$/gm, () =>
    chalk.hex(colorToHex(colors.secondary))(
      "\u2500".repeat(Math.min(width || 60, 60)),
    ),
  );

  return { text: result, codeBlocks, inlineCodes };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Parse markdown and return structured parts for Ink rendering.
 * Text parts go inside the bordered box; code parts render without border.
 *
 * @param {string} text - Raw markdown text
 * @param {object} themeColors - Color tokens matching theme.cl.jac
 * @param {number} [width] - Terminal width for wrapping (optional)
 * @returns {Array<{type: 'text'|'code', content: string}>}
 */
export function parseMarkdownParts(text, themeColors, width) {
  if (!text || !text.trim()) return [{ type: "text", content: "" }];

  try {
    const { text: processed, codeBlocks, inlineCodes } = parseMarkdownCore(
      text,
      themeColors,
      width,
    );

    // Restore inline code inside text segments
    let withInline = processed;
    withInline = withInline.replace(
      /__INLINE_CODE_(\d+)__/g,
      (_match, index) => inlineCodes[parseInt(index, 10)] || "",
    );

    // Split on code block markers; split() with capture group interleaves
    // text and index strings: [text, idx, text, idx, ...]
    const segments = withInline.split(/__CODE_BLOCK_(\d+)__/);
    const parts = [];

    for (let i = 0; i < segments.length; i++) {
      if (i % 2 === 0) {
        const content = segments[i];
        if (content) parts.push({ type: "text", content });
      } else {
        const idx = parseInt(segments[i] || "0", 10);
        const codeContent = codeBlocks[idx];
        if (codeContent) parts.push({ type: "code", content: codeContent });
      }
    }

    return parts;
  } catch {
    return [{ type: "text", content: text }];
  }
}

/**
 * Parse markdown into a single flat ANSI-colored string.
 * Used for non-interactive / plain mode output.
 *
 * @param {string} text - Raw markdown text
 * @param {object} themeColors - Color tokens matching theme.cl.jac
 * @param {number} [width] - Terminal width for wrapping (optional)
 * @returns {string}
 */
export function parseMarkdown(text, themeColors, width) {
  if (!text || !text.trim()) return "";

  const { text: processed, codeBlocks, inlineCodes } = parseMarkdownCore(
    text,
    themeColors,
    width,
  );

  let result = processed;
  result = result.replace(/__CODE_BLOCK_(\d+)__/g, (_match, index) => {
    return codeBlocks[parseInt(index, 10)] || "";
  });
  result = result.replace(/__INLINE_CODE_(\d+)__/g, (_match, index) => {
    return inlineCodes[parseInt(index, 10)] || "";
  });

  return result;
}
