/**
 * Flux language syntax highlighter for Hugo/Chroma CSS classes.
 * Finds code blocks with title "flux" (rendered by DoIt theme) and applies
 * token-level highlighting using Chroma's CSS class conventions.
 */
(function () {
  'use strict';

  // Flux language token definitions
  const KEYWORDS = new Set([
    'import', 'package', 'option', 'builtin', 'testcase',
    'if', 'then', 'else', 'return', 'for', 'in',
    'and', 'or', 'not', 'exists',
  ]);

  const BUILTINS = new Set([
    'true', 'false',
  ]);

  const LITERALS = new Set([
    'null',
  ]);

  // Token types mapped to Chroma CSS classes
  // .k = keyword, .kd = keyword declaration, .kn = keyword namespace
  // .s = string, .s2 = string double-quoted
  // .nf = name function, .nx = name other
  // .mi = number integer, .mf = number float
  // .o = operator
  // .c1 = comment single, .cm = comment multiline
  // .sr = string regex
  // .kt = keyword type
  // .nb = name builtin
  // .p = punctuation
  // .dl = string delimiter

  // Tokenizer: returns array of {type, text}
  function tokenize(code) {
    const tokens = [];
    let i = 0;

    while (i < code.length) {
      let match;

      // Line comments
      if (code[i] === '/' && code[i + 1] === '/') {
        let end = code.indexOf('\n', i);
        if (end === -1) end = code.length;
        tokens.push({ type: 'c1', text: code.slice(i, end) });
        i = end;
        continue;
      }

      // Block comments
      if (code[i] === '/' && code[i + 1] === '*') {
        let end = code.indexOf('*/', i + 2);
        if (end === -1) end = code.length;
        else end += 2;
        tokens.push({ type: 'cm', text: code.slice(i, end) });
        i = end;
        continue;
      }

      // Strings (double-quoted, with escape and interpolation awareness)
      if (code[i] === '"') {
        let j = i + 1;
        while (j < code.length && code[j] !== '"') {
          if (code[j] === '\\') j++; // skip escaped char
          j++;
        }
        j++; // include closing quote
        tokens.push({ type: 's2', text: code.slice(i, j) });
        i = j;
        continue;
      }

      // Regex literals /pattern/
      if (code[i] === '/' && i > 0) {
        // Heuristic: regex follows operator, punctuation, keyword, or start of line
        const prevNonWs = code.slice(0, i).trimEnd();
        const lastChar = prevNonWs[prevNonWs.length - 1];
        if (!lastChar || /[=(:,|&!<>~+\-*%^{;\[]/.test(lastChar)) {
          let j = i + 1;
          while (j < code.length && code[j] !== '/' && code[j] !== '\n') {
            if (code[j] === '\\') j++;
            j++;
          }
          if (j < code.length && code[j] === '/') {
            j++;
            tokens.push({ type: 'sr', text: code.slice(i, j) });
            i = j;
            continue;
          }
        }
      }

      // Duration literals (e.g., 1h, 30m, 2d, 500ms, 1w, 1mo, 1y, 1us, 1µs, 1ns)
      match = code.slice(i).match(/^(\d+)(y|mo|w|d|h|m(?:s|inute)?|s|us|µs|ns)\b/);
      if (match) {
        tokens.push({ type: 'mi', text: match[0] });
        i += match[0].length;
        continue;
      }

      // Date/time literals (e.g., 2024-01-01T00:00:00Z)
      match = code.slice(i).match(/^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?)?/);
      if (match && match[0].length >= 10) {
        tokens.push({ type: 'mi', text: match[0] });
        i += match[0].length;
        continue;
      }

      // Numbers (float and int, including hex)
      match = code.slice(i).match(/^0[xX][0-9a-fA-F]+|^\d+\.\d*([eE][+-]?\d+)?|^\d+([eE][+-]?\d+)?/);
      if (match) {
        tokens.push({ type: match[0].includes('.') || match[0].includes('e') || match[0].includes('E') ? 'mf' : 'mi', text: match[0] });
        i += match[0].length;
        continue;
      }

      // Identifiers and keywords
      match = code.slice(i).match(/^[a-zA-Z_][a-zA-Z0-9_]*/);
      if (match) {
        const word = match[0];
        let type = 'nx'; // default: name other

        if (KEYWORDS.has(word)) {
          type = word === 'import' || word === 'package' ? 'kn' : 'k';
        } else if (BUILTINS.has(word)) {
          type = 'nb';
        } else if (LITERALS.has(word)) {
          type = 'kc';
        } else {
          // Check if followed by '(' -> function call
          const rest = code.slice(i + word.length);
          if (/^\s*\(/.test(rest)) {
            type = 'nf';
          }
        }

        tokens.push({ type: type, text: word });
        i += word.length;
        continue;
      }

      // Multi-char operators
      match = code.slice(i).match(/^\|>|^=>|^=~|^!~|^<=|^>=|^!=|^==|^<-/);
      if (match) {
        tokens.push({ type: 'o', text: match[0] });
        i += match[0].length;
        continue;
      }

      // Single-char operators
      if ('+-*/%<>=!&|^'.includes(code[i])) {
        tokens.push({ type: 'o', text: code[i] });
        i++;
        continue;
      }

      // Punctuation
      if ('()[]{}:.,;@'.includes(code[i])) {
        tokens.push({ type: 'p', text: code[i] });
        i++;
        continue;
      }

      // Whitespace and newlines - preserve as-is
      match = code.slice(i).match(/^[\s]+/);
      if (match) {
        tokens.push({ type: null, text: match[0] });
        i += match[0].length;
        continue;
      }

      // Fallback: single character
      tokens.push({ type: null, text: code[i] });
      i++;
    }

    return tokens;
  }

  // Escape HTML entities
  function escapeHtml(text) {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // Render tokens to highlighted HTML (using Chroma's line/cl span structure)
  function renderTokens(tokens) {
    let html = '';
    let lineTokens = [];

    function flushLine() {
      let lineHtml = '';
      for (const tok of lineTokens) {
        if (tok.type) {
          lineHtml += '<span class="' + tok.type + '">' + escapeHtml(tok.text) + '</span>';
        } else {
          lineHtml += escapeHtml(tok.text);
        }
      }
      html += '<span class="line"><span class="cl">' + lineHtml + '\n</span></span>';
      lineTokens = [];
    }

    for (const token of tokens) {
      // Split by newlines to maintain line structure
      const parts = token.text.split('\n');
      for (let p = 0; p < parts.length; p++) {
        if (p > 0) {
          flushLine();
        }
        if (parts[p].length > 0) {
          lineTokens.push({ type: token.type, text: parts[p] });
        }
      }
    }

    // Flush remaining tokens
    if (lineTokens.length > 0) {
      flushLine();
    }

    return html;
  }

  // Find and highlight all flux code blocks
  function highlightFlux() {
    // DoIt theme renders code block title in a span with specific classes
    const codeBlocks = document.querySelectorAll('.code-block.highlight');

    codeBlocks.forEach(function (block) {
      // Find the title span
      const titleSpan = block.querySelector('button.code-block-button span:nth-child(2)');
      if (!titleSpan || titleSpan.textContent.trim().toLowerCase() !== 'flux') {
        return;
      }

      // Find the code element
      const codeEl = block.querySelector('pre code.chroma');
      if (!codeEl) return;

      // Get plain text content
      const plainText = codeEl.textContent;

      // Tokenize and render
      const tokens = tokenize(plainText);
      const highlighted = renderTokens(tokens);

      // Replace content
      codeEl.innerHTML = highlighted;
    });
  }

  // Run on DOM ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', highlightFlux);
  } else {
    highlightFlux();
  }
})();
