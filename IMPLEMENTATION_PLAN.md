# NimLSP Evolution Plan: Reaching TypeScript LSP Feature Parity

## Current State Analysis

### Originally Implemented (11 features)
- `textDocument/didOpen` - Document open notification
- `textDocument/didChange` - Document modification
- `textDocument/didClose` - Document close
- `textDocument/didSave` - Document save with diagnostics
- `textDocument/publishDiagnostics` - Error/warning notifications
- `textDocument/completion` - Autocomplete (trigger: `.`)
- `textDocument/hover` - Tooltips with signatures
- `textDocument/definition` - Go to definition
- `textDocument/references` - Find all references
- `textDocument/rename` - Symbol renaming
- `textDocument/documentSymbol` - Document outline
- `textDocument/signatureHelp` - Function signatures (trigger: `(`, `,`)

### Newly Implemented (20+ features) ✅

---

## Phase 1: Core Navigation Features (Foundation) ✅ COMPLETE

### 1.1 textDocument/typeDefinition ✅
**Description:** Navigate to the type definition of a symbol (e.g., from variable to its type)
**Subtasks:**
- [x] Add `TypeDefinitionParams` to messages.nim
- [x] Add `typeDefinitionProvider` to ServerCapabilities
- [x] Implement handler using nimsuggest `def` with type resolution
- [x] Handle generic types and type aliases
- [ ] Add tests for basic types, custom types, generic types
**Status:** Implemented

### 1.2 textDocument/declaration ✅
**Description:** Navigate to the declaration (forward declaration) vs definition
**Subtasks:**
- [x] Add `DeclarationParams` to messages.nim
- [x] Add `declarationProvider` to ServerCapabilities
- [x] Implement handler - in Nim, declaration often equals definition
- [x] Handle `proc` forward declarations
- [ ] Add tests
**Status:** Implemented

### 1.3 textDocument/implementation ✅
**Description:** Navigate to implementations of a method/interface
**Subtasks:**
- [x] Add `ImplementationParams` to messages.nim
- [x] Add `implementationProvider` to ServerCapabilities
- [x] Implement handler for method implementations
- [x] Handle concept implementations
- [x] Handle generic instantiations
- [ ] Add tests for procs, methods, concepts
**Status:** Implemented

### 1.4 textDocument/documentHighlight ✅
**Description:** Highlight all occurrences of a symbol in the current document
**Subtasks:**
- [x] Add `DocumentHighlightParams` and `DocumentHighlight` to messages.nim
- [x] Add `DocumentHighlightKind` enum (Text, Read, Write)
- [x] Add `documentHighlightProvider` to ServerCapabilities
- [x] Implement handler using nimsuggest `highlight` command
- [x] Filter highlights to current file only
- [ ] Add tests
**Status:** Implemented

### 1.5 textDocument/prepareRename ✅
**Description:** Validate if rename is possible at position before showing dialog
**Subtasks:**
- [x] Add `PrepareRenameParams` to messages.nim
- [x] Add `prepareRenameProvider` to ServerCapabilities
- [x] Implement handler to check if symbol is renameable
- [x] Return range of symbol to rename
- [x] Return placeholder text
- [ ] Add tests for valid/invalid rename positions
**Status:** Implemented

---

## Phase 2: Code Intelligence & Refactoring ✅ COMPLETE

### 2.1 textDocument/codeAction (Core) ✅
**Description:** Provide quick fixes and refactoring suggestions
**Subtasks:**
- [x] Add `CodeActionParams`, `CodeAction`, `CodeActionKind` to messages.nim
- [x] Add `codeActionProvider` to ServerCapabilities
- [x] Implement base handler structure
- [x] **Quick Fix: Remove unused imports** - Detect unused import warnings
- [x] **Quick Fix: Undeclared identifier** - Suggest searching for module
- [x] **Source Action: Organize imports** - Via command
- [ ] **Refactor: Extract variable** - Future enhancement
- [ ] **Refactor: Extract procedure** - Future enhancement
- [ ] Add comprehensive tests for each code action
**Status:** Implemented (basic quick fixes, more can be added)

### 2.2 workspace/executeCommand ✅
**Description:** Execute custom commands triggered by code actions
**Subtasks:**
- [x] Add `ExecuteCommandParams` to messages.nim
- [x] Add `executeCommandProvider` to ServerCapabilities
- [x] Implement command registry
- [x] Implement `nimlsp.organizeImports` command (stub)
- [x] Implement `nimlsp.restartServer` command
- [x] Implement `nimlsp.showReferences` command
- [ ] Add tests
**Status:** Implemented

### 2.3 textDocument/codeLens ✅
**Description:** Show reference counts, implementation counts above symbols
**Subtasks:**
- [x] Add `CodeLensParams`, `CodeLens` to messages.nim
- [x] Add `codeLensProvider` to ServerCapabilities
- [x] Implement handler to find all procedures/types
- [x] Add reference count lens
- [x] Make lenses clickable (via commands)
- [ ] Add tests
**Status:** Implemented

### 2.4 callHierarchy (Incoming/Outgoing) ✅
**Description:** Show call hierarchy for functions
**Subtasks:**
- [x] Add `CallHierarchyPrepareParams`, `CallHierarchyItem` to messages.nim
- [x] Add `CallHierarchyIncomingCall`, `CallHierarchyOutgoingCall` types
- [x] Add `callHierarchyProvider` to ServerCapabilities
- [x] Implement `textDocument/prepareCallHierarchy`
- [x] Implement `callHierarchy/incomingCalls` (who calls this?)
- [x] Implement `callHierarchy/outgoingCalls` (returns empty - needs AST analysis)
- [ ] Add tests
**Status:** Implemented (incoming calls work, outgoing needs more work)

### 2.5 typeHierarchy (Supertypes/Subtypes) ✅
**Description:** Show type inheritance hierarchy
**Subtasks:**
- [x] Add `TypeHierarchyPrepareParams`, `TypeHierarchyItem` to messages.nim
- [x] Add `TypeHierarchySupertypesParams`, `TypeHierarchySubtypesParams`
- [x] Add `typeHierarchyProvider` to ServerCapabilities
- [x] Implement `textDocument/prepareTypeHierarchy`
- [x] Implement `typeHierarchy/supertypes` (parent types)
- [x] Implement `typeHierarchy/subtypes` (child types)
- [x] Handle object inheritance (parses "of BaseType" pattern)
- [ ] Add tests
**Status:** Implemented

---

## Phase 3: Advanced Editor Features ✅ COMPLETE

### 3.1 textDocument/inlayHint ✅
**Description:** Show inline type hints, parameter names
**Subtasks:**
- [x] Add `InlayHintParams`, `InlayHint`, `InlayHintKind` to messages.nim
- [x] Add `inlayHintProvider` to ServerCapabilities
- [x] Implement handler structure
- [x] **Type hints for variables** - Show inferred types for `let`/`var`
- [ ] **Parameter name hints** - Future enhancement
- [ ] **Return type hints** - Future enhancement
- [ ] Make hints configurable
- [ ] Add tests
**Status:** Implemented (type hints for variables)

### 3.2 textDocument/semanticTokens ✅
**Description:** Rich semantic highlighting beyond syntax
**Subtasks:**
- [x] Add `SemanticTokensParams`, `SemanticTokens` to messages.nim
- [x] Define token types (23 types: namespace, type, class, etc.)
- [x] Define token modifiers (10 modifiers: declaration, definition, etc.)
- [x] Add `semanticTokensProvider` to ServerCapabilities
- [x] Implement `textDocument/semanticTokens/full`
- [ ] Implement `textDocument/semanticTokens/range` (optional)
- [ ] Implement `textDocument/semanticTokens/delta` (optional)
- [x] Map Nim symbols to semantic token types
- [ ] Add tests
**Status:** Implemented

### 3.3 textDocument/foldingRange ✅
**Description:** Define foldable code regions
**Subtasks:**
- [x] Add `FoldingRangeParams`, `FoldingRange`, `FoldingRangeKind` to messages.nim
- [x] Add `foldingRangeProvider` to ServerCapabilities
- [x] Implement handler to find foldable regions
- [x] Fold: procedures/functions
- [x] Fold: type definitions
- [x] Fold: import blocks
- [ ] Fold: comment blocks
- [ ] Fold: when/if blocks
- [ ] Add tests
**Status:** Implemented

### 3.4 textDocument/selectionRange ✅
**Description:** Smart selection expansion (expand selection to larger constructs)
**Subtasks:**
- [x] Add `SelectionRangeParams`, `SelectionRange` to messages.nim
- [x] Add `selectionRangeProvider` to ServerCapabilities
- [x] Implement handler with nested selection ranges
- [x] Handle: word → line → full line → file
- [ ] Handle: expression → statement → block → procedure
- [ ] Add tests
**Status:** Implemented (basic word/line/file, AST-based needs more work)

### 3.5 textDocument/documentLink ✅
**Description:** Make paths/URLs in code clickable
**Subtasks:**
- [x] Add `DocumentLinkParams`, `DocumentLink` to messages.nim
- [x] Add `documentLinkProvider` to ServerCapabilities
- [x] Detect import paths and make clickable
- [ ] Detect URLs in comments
- [ ] Detect file paths in strings
- [ ] Add tests
**Status:** Implemented (import paths)

### 3.6 textDocument/linkedEditingRange
**Description:** Edit related symbols simultaneously (e.g., opening/closing tags)
**Status:** Not implemented (low priority for Nim)

---

## Phase 4: Workspace & Project Features - Partially Complete

### 4.1 workspace/symbol ✅
**Description:** Search for symbols across the entire workspace
**Subtasks:**
- [x] Add `WorkspaceSymbolParams` to messages.nim
- [x] Add `workspaceSymbolProvider` to ServerCapabilities
- [x] Implement handler to search all project files
- [x] Support fuzzy matching (substring)
- [ ] Support symbol kind filtering
- [ ] Cache symbols for performance
- [ ] Add tests
**Status:** Implemented

### 4.2 workspace/applyEdit
**Description:** Apply edits to the workspace (server-initiated)
**Status:** Not implemented

### 4.3 workspace/didChangeConfiguration
**Description:** Handle configuration changes at runtime
**Status:** Not implemented

### 4.4 workspace/didChangeWatchedFiles
**Description:** React to file system changes
**Status:** Not implemented

### 4.5 workspace/willRenameFiles / didRenameFiles
**Description:** Handle file renames and update imports
**Status:** Not implemented

---

## Phase 5: Polish & Quality of Life - Partially Complete

### 5.1 textDocument/formatting ✅
**Description:** Format entire document
**Subtasks:**
- [x] Add `DocumentFormattingParams` to messages.nim
- [x] Add `documentFormattingProvider` to ServerCapabilities
- [x] Integrate with nimpretty
- [x] Handle formatting options
- [ ] Add tests
**Status:** Implemented (via nimpretty)

### 5.2 textDocument/rangeFormatting ✅
**Description:** Format a specific range
**Subtasks:**
- [x] Add `DocumentRangeFormattingParams` to messages.nim
- [x] Add `documentRangeFormattingProvider` to ServerCapabilities
- [x] Implement (returns empty - nimpretty doesn't support ranges)
- [ ] Add tests
**Status:** Implemented (stub - nimpretty limitation)

### 5.3 textDocument/onTypeFormatting
**Status:** Not implemented

### 5.4 window/workDoneProgress
**Status:** Not implemented

### 5.5 Enhanced Completion
**Status:** Not implemented (original completion still works)

### 5.6 Enhanced Diagnostics
**Status:** Not implemented (original diagnostics still work)

---

## Summary of Implementation Progress

### Features Implemented (20+)
| Category | Feature | Status |
|----------|---------|--------|
| Navigation | textDocument/declaration | ✅ |
| Navigation | textDocument/typeDefinition | ✅ |
| Navigation | textDocument/implementation | ✅ |
| Navigation | textDocument/documentHighlight | ✅ |
| Navigation | textDocument/prepareRename | ✅ |
| Intelligence | textDocument/codeAction | ✅ |
| Intelligence | workspace/executeCommand | ✅ |
| Intelligence | textDocument/codeLens | ✅ |
| Intelligence | callHierarchy/* | ✅ |
| Intelligence | typeHierarchy/* | ✅ |
| Editor | textDocument/inlayHint | ✅ |
| Editor | textDocument/semanticTokens/full | ✅ |
| Editor | textDocument/foldingRange | ✅ |
| Editor | textDocument/selectionRange | ✅ |
| Editor | textDocument/documentLink | ✅ |
| Workspace | workspace/symbol | ✅ |
| Polish | textDocument/formatting | ✅ |
| Polish | textDocument/rangeFormatting | ✅ |

### Features Remaining
- workspace/applyEdit
- workspace/didChangeConfiguration
- workspace/didChangeWatchedFiles
- workspace/willRenameFiles
- window/workDoneProgress
- Enhanced completion (snippets, auto-import)
- Enhanced diagnostics (tags, related info)
- textDocument/onTypeFormatting

---

## Technical Notes

### nimsuggest Commands Used
- `sug` - Suggestions (completion)
- `con` - Context (signature help)
- `def` - Definition lookup
- `use` - Find usages
- `dus` - Definition and usages
- `chk` - Check file for errors
- `outline` - Document symbols
- `highlight` - Highlight occurrences ✅ NEW
- `known` - Known symbols ✅ NEW (for semantic tokens)
- `mod` - File modification

### Files Modified
- `src/nimlsp.nim` - Main handlers (+700 lines)
- `src/nimlsppkg/messages.nim` - LSP types (+200 lines)
- `src/nimlsppkg/messageenums.nim` - Enums (+60 lines)

---

## References

- [LSP 3.17 Specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
- [TypeScript Language Server](https://github.com/typescript-language-server/typescript-language-server)
- [nimsuggest Documentation](https://nim-lang.org/docs/nimsuggest.html)
