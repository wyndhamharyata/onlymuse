// Rule 6 of CLAUDE.md, for the layout and function size a syntax tree can check.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import ts from "typescript";

const branchKinds = new Set([
  ts.SyntaxKind.IfStatement,
  ts.SyntaxKind.ForStatement,
  ts.SyntaxKind.ForOfStatement,
  ts.SyntaxKind.ForInStatement,
  ts.SyntaxKind.WhileStatement,
  ts.SyntaxKind.DoStatement,
  ts.SyntaxKind.CaseClause,
  ts.SyntaxKind.CatchClause,
  ts.SyntaxKind.ConditionalExpression,
  ts.SyntaxKind.AmpersandAmpersandToken,
  ts.SyntaxKind.BarBarToken,
  ts.SyntaxKind.QuestionQuestionToken,
]);

const exitKinds = new Set([
  ts.SyntaxKind.ReturnStatement,
  ts.SyntaxKind.ContinueStatement,
  ts.SyntaxKind.BreakStatement,
  ts.SyntaxKind.ThrowStatement,
]);

const controlKinds = new Set([
  ts.SyntaxKind.IfStatement,
  ts.SyntaxKind.ForStatement,
  ts.SyntaxKind.ForOfStatement,
  ts.SyntaxKind.ForInStatement,
  ts.SyntaxKind.WhileStatement,
  ts.SyntaxKind.DoStatement,
  ts.SyntaxKind.SwitchStatement,
  ts.SyntaxKind.TryStatement,
]);

const skippedFolders = new Set([".git", "dist", "node_modules"]);

const skippedFiles = new Set([]);

const problems = [];

const addProblem = (path, line, text) => problems.push(`${path}:${line} ${text}`);

const ends = (statement) => {
  if (exitKinds.has(statement.kind)) return true;

  return ts.isBlock(statement) && statement.statements.length > 0
    ? ends(statement.statements.at(-1))
    : false;
};

const isEarlyExit = (statement) =>
  ts.isIfStatement(statement) &&
  statement.elseStatement === undefined &&
  ends(statement.thenStatement);

const isOneLineIf = (statement, lineOf) =>
  ts.isIfStatement(statement) &&
  statement.elseStatement === undefined &&
  lineOf(statement.getStart()) === lineOf(statement.getEnd());

const isControl = (statement, lineOf) =>
  controlKinds.has(statement.kind) && lineOf(statement.getStart()) !== lineOf(statement.getEnd());

const countBranches = (node) => {
  let count = 0;

  const visit = (child) => {
    if (ts.isFunctionLike(child)) return;
    if (branchKinds.has(child.kind)) count += 1;

    ts.forEachChild(child, visit);
  };

  visit(node);

  return count;
};

const listFiles = (folder) =>
  readdirSync(folder, { withFileTypes: true }).flatMap((entry) => {
    const path = join(folder, entry.name);

    if (entry.isDirectory()) return skippedFolders.has(entry.name) ? [] : listFiles(path);

    return skippedFiles.has(path) || !/\.tsx?$/.test(path) ? [] : [path];
  });

const checkFile = (path) => {
  const source = readFileSync(path, "utf8");
  const file = ts.createSourceFile(
    path,
    source,
    ts.ScriptTarget.Latest,
    true,
    path.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS
  );
  const lines = source.split("\n");
  const lineOf = (position) => file.getLineAndCharacterOfPosition(position).line + 1;
  const leadingStart = (node) => {
    let position = node.getFullStart();

    while (position < node.getStart(file) && /\s/.test(source[position])) position += 1;

    return position;
  };
  const isApart = (above, below) =>
    lineOf(below.getStart(file)) - lineOf(above.getEnd()) > 1 &&
    lines[lineOf(above.getEnd())].trim() === "";

  for (const match of source.matchAll(/\n\n\n/g)) {
    addProblem(path, source.slice(0, match.index).split("\n").length, "two blank lines");
  }

  for (const match of source.matchAll(/\/\*\*/g)) {
    addProblem(path, source.slice(0, match.index).split("\n").length, "JSDoc block");
  }

  const checkStatements = (statements) => {
    statements.forEach((statement, index) => {
      const next = statements[index + 1];

      if (next === undefined || isApart(statement, next)) return;

      const isRun =
        (isEarlyExit(statement) && isEarlyExit(next)) ||
        (isOneLineIf(statement, lineOf) && isOneLineIf(next, lineOf));

      if (isRun) return;

      const isCrowded =
        isEarlyExit(statement) ||
        isControl(statement, lineOf) ||
        isControl(next, lineOf) ||
        (ts.isVariableStatement(statement) !== ts.isVariableStatement(next) &&
          !ts.isReturnStatement(next));

      if (isCrowded)
        addProblem(path, lineOf(statement.getEnd()), "no blank line between statements");
    });
  };

  const visit = (node) => {
    if (ts.isBlock(node)) checkStatements(node.statements);
    if (ts.isCaseClause(node) || ts.isDefaultClause(node)) checkStatements(node.statements);

    if (ts.isFunctionLike(node) && node.body && ts.isBlock(node.body)) {
      const statements = node.body.statements;
      const last = statements.at(-1);
      const long =
        statements.length > 1 &&
        (statements.length > 3 || lineOf(last.getStart(file)) - lineOf(node.getStart(file)) > 3);

      if (
        long &&
        last !== undefined &&
        ts.isReturnStatement(last) &&
        lines[lineOf(leadingStart(last)) - 2]?.trim() !== ""
      ) {
        addProblem(path, lineOf(last.getStart(file)), "no blank line before the last return");
      }

      const branches = countBranches(node.body);

      if (branches > 15) addProblem(path, lineOf(node.getStart(file)), `${branches} branch points`);
    }

    ts.forEachChild(node, visit);
  };

  visit(file);
};

for (const path of listFiles("src")) checkFile(path);

for (const problem of problems) console.log(problem);

if (problems.length > 0) {
  console.log(`${problems.length} problems. CLAUDE.md rule 6 explains each one.`);
  process.exit(1);
}
