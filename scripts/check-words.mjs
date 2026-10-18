// Rules 2 and 3 of CLAUDE.md, for the words and punctuation a machine can check.
import { readdirSync, readFileSync } from "node:fs";
import { extname, join } from "node:path";
import ts from "typescript";

const bannedWords = new Set([
  "absent",
  "adds",
  "bail",
  "bailed",
  "bailing",
  "bails",
  "clearing",
  "critically",
  "freeze",
  "freezes",
  "frozen",
  "gap",
  "gaps",
  "gate",
  "gated",
  "gates",
  "gating",
  "guard",
  "guarded",
  "guarding",
  "guards",
  "honest",
  "invariant",
  "invariants",
  "landed",
  "landing",
  "lands",
  "leaves",
  "leaving",
  "minted",
  "noop",
  "outrank",
  "outranks",
  "seam",
  "seams",
  "shape",
  "shaped",
  "shapes",
  "shaping",
  "significantly",
  "sits",
  "sitting",
  "spike",
  "spikes",
  "surface",
  "surfaces",
  "survive",
  "survived",
  "survives",
  "surviving",
]);

const bannedPhrases = [
  "call site",
  "call sites",
  "carries the weight",
  "earns its place",
  "fall through",
  "falls through",
  "heart of the change",
  "holds the contract",
  "key insight",
  "load bearing",
  "make no mistake",
  "no op",
  "read better",
  "reads better",
  "this is important",
  "no longer",
  "used to",
  "older build",
  "earlier build",
  "older version",
  "a later build",
  "this change",
  "these changes",
  "the old fixed",
  "line above",
  "code above",
];

// Only the words that read as generated text in a name. A noun such as "gap" is fine in code.
const bannedNames = new Set([
  "absent",
  "bail",
  "bailed",
  "bailing",
  "bails",
  "gate",
  "gated",
  "gates",
  "gating",
  "guard",
  "guarded",
  "guarding",
  "guards",
  "invariant",
  "invariants",
  "minted",
  "outrank",
  "outranks",
  "seam",
  "seams",
  "shape",
  "shaped",
  "shapes",
  "shaping",
  "spike",
  "spikes",
  "surface",
  "surfaces",
]);

const causalWords = new Set(["because", "hence", "therefore"]);

const skippedFolders = new Set([".build", ".git", "dist", "node_modules"]);

// This file holds the lists themselves.
const skippedFiles = new Set(["scripts/check-words.mjs"]);

const sourceExtensions = new Set([".ts", ".tsx", ".mjs", ".js"]);

// A Swift keyword is the language's own word, so the name list skips it.
const swiftKeywords = new Set([
  "actor",
  "any",
  "as",
  "associatedtype",
  "async",
  "await",
  "break",
  "case",
  "catch",
  "class",
  "continue",
  "convenience",
  "default",
  "defer",
  "deinit",
  "didSet",
  "do",
  "dynamic",
  "else",
  "enum",
  "extension",
  "fallthrough",
  "false",
  "fileprivate",
  "final",
  "for",
  "func",
  "get",
  "guard",
  "if",
  "import",
  "in",
  "indirect",
  "init",
  "inout",
  "internal",
  "is",
  "lazy",
  "let",
  "mutating",
  "nil",
  "nonisolated",
  "open",
  "operator",
  "optional",
  "override",
  "private",
  "protocol",
  "public",
  "repeat",
  "required",
  "rethrows",
  "return",
  "self",
  "set",
  "some",
  "static",
  "struct",
  "subscript",
  "super",
  "switch",
  "throw",
  "throws",
  "true",
  "try",
  "typealias",
  "unowned",
  "var",
  "weak",
  "where",
  "while",
  "willSet",
]);

const problems = [];

const addProblem = (path, line, text) => problems.push(`${path}:${line} ${text}`);

const splitWords = (text) =>
  text
    .replaceAll(/([a-z])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .split(/[^a-z]+/);

function checkText(path, line, text, kind) {
  const words = splitWords(text);
  const spaced = ` ${words.join(" ")} `;

  for (const word of words) {
    const isBanned = kind === "name" ? bannedNames.has(word) : bannedWords.has(word);

    if (isBanned) addProblem(path, line, `"${word}"`);
    if (kind === "doc" && causalWords.has(word))
      addProblem(path, line, `"${word}" joins two facts`);
  }

  for (const phrase of bannedPhrases) {
    if (spaced.includes(` ${phrase} `)) addProblem(path, line, `"${phrase}"`);
  }

  if (/ worth [a-z]+ing /.test(spaced)) addProblem(path, line, `"Worth ...ing"`);

  if (kind !== "name" && /[\u2013\u2014]/.test(text)) addProblem(path, line, "em or en dash");
  if ((kind === "doc" || kind === "comment") && text.includes(";")) {
    addProblem(path, line, "semicolon in prose");
  }
}

// A string is prose when it holds a sentence, not a class list, a selector or a path.
function isProse(text) {
  if (!/[A-Za-z]/.test(text)) return false;

  const trimmed = text.trim();
  if (!/\s/.test(trimmed)) return false;
  if (/=>|\bfunction \b|\bconst \b|\blet \b/.test(trimmed)) return false;

  return !/^[a-z0-9:./[\]%!_-]+(?:\s+[a-z0-9:./[\]%!_-]+)*$/.test(trimmed);
}

function isClassNameAttribute(node) {
  const isAttribute = ts.isJsxAttribute(node);
  const name = isAttribute ? node.name.getText() : "";

  return name === "className" || name === "class";
}

function checkSource(path, source, kind) {
  const file = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, kind);

  const visit = (node, insideClassName) => {
    const inClassName = insideClassName || isClassNameAttribute(node);

    // A name the platform or a library owns keeps its spelling.
    const parent = node.parent;
    const isPropertyName =
      parent !== undefined &&
      ((ts.isPropertyAccessExpression(parent) && parent.name === node) ||
        (ts.isQualifiedName(parent) && parent.right === node));

    if (ts.isIdentifier(node) && !isPropertyName) {
      checkText(path, lineOf(node.getStart(file)), node.text, "name");
    }

    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      if (!inClassName && isProse(node.text)) {
        checkText(path, lineOf(node.getStart(file)), node.text, "text");
      }
    }

    if (ts.isJsxText(node) && isProse(node.text)) {
      checkText(path, lineOf(node.getStart(file)), node.text, "text");
    }

    if (ts.isTemplateHead(node) || ts.isTemplateMiddle(node) || ts.isTemplateTail(node)) {
      if (!inClassName && isProse(node.text)) {
        checkText(path, lineOf(node.getStart(file)), node.text, "text");
      }
    }

    ts.forEachChild(node, (child) => visit(child, inClassName));
  };

  const lineOf = (position) => file.getLineAndCharacterOfPosition(position).line + 1;

  visit(file, false);

  // The AST knows where every comment is, even past a template literal, where a plain scanner loses its place.
  const commentRanges = new Map();
  const remember = (ranges) => {
    for (const range of ranges ?? []) commentRanges.set(range.pos, range);
  };
  const visitComments = (node) => {
    remember(ts.getLeadingCommentRanges(source, node.getFullStart()));
    remember(ts.getTrailingCommentRanges(source, node.getEnd()));
    ts.forEachChild(node, visitComments);
  };
  visitComments(file);

  const comments = [...commentRanges.values()].sort((a, b) => a.pos - b.pos);
  let previousCommentLine = -2;

  for (const comment of comments) {
    const line = lineOf(comment.pos);
    const isLine = comment.kind === ts.SyntaxKind.SingleLineCommentTrivia;

    if (isLine && line === previousCommentLine + 1) {
      addProblem(path, line, "comment runs over one line");
    }

    checkText(path, line, source.slice(comment.pos, comment.end), "comment");
    previousCommentLine = line;
  }
}

// Fenced blocks and inline code are examples, not prose.
function stripCode(markdown) {
  let inFence = false;

  return markdown
    .split("\n")
    .map((line) => {
      if (/^\s*```/.test(line)) {
        inFence = !inFence;
        return "";
      }

      if (inFence) return "";

      return line.replace(/`[^`]*`/g, "");
    })
    .join("\n");
}

function checkDoc(path, source) {
  stripCode(source)
    .split("\n")
    .forEach((line, index) => checkText(path, index + 1, line, "doc"));
}

function listFiles(folder) {
  return readdirSync(folder, { withFileTypes: true }).flatMap((entry) => {
    const path = join(folder, entry.name);

    if (entry.isDirectory()) {
      return skippedFolders.has(entry.name) ? [] : listFiles(path);
    }

    return skippedFiles.has(path) ? [] : [path];
  });
}

// Swift has no parser here. A comment goes to the comment list, a string to the text list and every
// other word to the name list.
function checkSwift(path, source) {
  let index = 0;
  let line = 1;
  let previousCommentLine = -2;

  while (index < source.length) {
    const character = source[index];
    const next = source[index + 1];

    if (character === "\n") {
      line += 1;
      index += 1;
      continue;
    }

    if (character === "/" && (next === "/" || next === "*")) {
      const isLine = next === "/";
      const end = isLine ? source.indexOf("\n", index) : source.indexOf("*/", index + 2);
      const stop = end === -1 ? source.length : end;
      const text = source.slice(index + 2, stop);

      if (isLine && line === previousCommentLine + 1) {
        addProblem(path, line, "comment runs over one line");
      }

      checkText(path, line, text, "comment");
      if (isLine) previousCommentLine = line;
      line += text.split("\n").length - 1;
      index = isLine ? stop : stop + 2;
      continue;
    }

    if (character === '"') {
      const quote = source.startsWith('"""', index) ? '"""' : '"';
      const stop = readSwiftStringEnd(source, index + quote.length, quote);
      const text = source.slice(index + quote.length, stop);

      checkText(path, line, text, "text");
      line += text.split("\n").length - 1;
      index = stop + quote.length;
      continue;
    }

    if (/[A-Za-z_]/.test(character)) {
      let end = index + 1;

      while (end < source.length && /[A-Za-z0-9_]/.test(source[end])) end += 1;

      const word = source.slice(index, end);

      if (!swiftKeywords.has(word)) checkText(path, line, word, "name");
      index = end;
      continue;
    }

    index += 1;
  }
}

function readSwiftStringEnd(source, start, quote) {
  let index = start;

  while (index < source.length && !source.startsWith(quote, index)) {
    index += source[index] === "\\" ? 2 : 1;
  }

  return index;
}

const roots = ["src", "tests", "scripts", "helper"];
const rootFiles = ["CLAUDE.md", "NOTES.md"];

const files = [
  ...roots.flatMap((root) => {
    try {
      return listFiles(root);
    } catch {
      return [];
    }
  }),
  ...rootFiles,
];

function checkStyles(path, source) {
  for (const match of source.matchAll(/\/\*[\s\S]*?\*\//g)) {
    const line = source.slice(0, match.index).split("\n").length;

    if (match[0].includes("\n")) addProblem(path, line, "comment runs over one line");

    checkText(path, line, match[0], "comment");
  }
}

for (const path of files) {
  const extension = extname(path);

  const isChecked =
    sourceExtensions.has(extension) || [".md", ".css", ".swift"].includes(extension);

  if (!isChecked) continue;

  const source = readFileSync(path, "utf8");

  if (extension === ".swift") {
    checkSwift(path, source);
    continue;
  }

  if (extension === ".md") {
    checkDoc(path, source);
    continue;
  }

  if (extension === ".css") {
    checkStyles(path, source);
    continue;
  }

  checkSource(path, source, extension === ".tsx" ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
}

for (const problem of problems) console.log(problem);

if (problems.length > 0) {
  console.log(`${problems.length} problems. CLAUDE.md rules 2 and 3 explain each one.`);
  process.exit(1);
}
