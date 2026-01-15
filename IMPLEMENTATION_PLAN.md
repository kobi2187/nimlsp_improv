# NimLSP Evolution Plan: Reaching TypeScript LSP Feature Parity

## Current State Analysis

### Currently Implemented (11 features)
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

### Missing Features (Target: TypeScript LSP parity)

---

## Phase 1: Core Navigation Features (Foundation)

These features extend the existing navigation capabilities and are relatively straightforward since nimsuggest already provides the underlying data.

### 1.1 textDocument/typeDefinition
**Description:** Navigate to the type definition of a symbol (e.g., from variable to its type)
**Subtasks:**
- [ ] Add `TypeDefinitionParams` to messages.nim
- [ ] Add `typeDefinitionProvider` to ServerCapabilities
- [ ] Implement handler using nimsuggest `def` with type resolution
- [ ] Handle generic types and type aliases
- [ ] Add tests for basic types, custom types, generic types
**Complexity:** Medium

### 1.2 textDocument/declaration
**Description:** Navigate to the declaration (forward declaration) vs definition
**Subtasks:**
- [ ] Add `DeclarationParams` to messages.nim
- [ ] Add `declarationProvider` to ServerCapabilities
- [ ] Implement handler - in Nim, declaration often equals definition
- [ ] Handle `proc` forward declarations
- [ ] Add tests
**Complexity:** Low (Nim rarely separates declaration/definition)

### 1.3 textDocument/implementation
**Description:** Navigate to implementations of a method/interface
**Subtasks:**
- [ ] Add `ImplementationParams` to messages.nim
- [ ] Add `implementationProvider` to ServerCapabilities
- [ ] Implement handler for method implementations
- [ ] Handle concept implementations
- [ ] Handle generic instantiations
- [ ] Add tests for procs, methods, concepts
**Complexity:** Medium-High

### 1.4 textDocument/documentHighlight
**Description:** Highlight all occurrences of a symbol in the current document
**Subtasks:**
- [ ] Add `DocumentHighlightParams` and `DocumentHighlight` to messages.nim
- [ ] Add `DocumentHighlightKind` enum (Text, Read, Write)
- [ ] Add `documentHighlightProvider` to ServerCapabilities
- [ ] Implement handler using nimsuggest `highlight` command
- [ ] Distinguish read vs write occurrences
- [ ] Add tests
**Complexity:** Low (nimsuggest already has `highlight` command)

### 1.5 textDocument/prepareRename
**Description:** Validate if rename is possible at position before showing dialog
**Subtasks:**
- [ ] Add `PrepareRenameParams` to messages.nim
- [ ] Add `prepareRenameProvider` to ServerCapabilities
- [ ] Implement handler to check if symbol is renameable
- [ ] Return range of symbol to rename
- [ ] Return placeholder text
- [ ] Add tests for valid/invalid rename positions
**Complexity:** Low

---

## Phase 2: Code Intelligence & Refactoring

These features provide intelligent code assistance beyond basic navigation.

### 2.1 textDocument/codeAction (Core)
**Description:** Provide quick fixes and refactoring suggestions
**Subtasks:**
- [ ] Add `CodeActionParams`, `CodeAction`, `CodeActionKind` to messages.nim
- [ ] Add `codeActionProvider` to ServerCapabilities
- [ ] Implement base handler structure
- [ ] **Quick Fix: Add missing imports**
  - Detect undefined symbol errors
  - Suggest imports from known modules
- [ ] **Quick Fix: Remove unused imports**
  - Detect unused import warnings
  - Generate removal edit
- [ ] **Quick Fix: Remove unused variables**
  - Detect unused variable warnings
  - Generate removal or underscore prefix edit
- [ ] **Refactor: Extract variable**
  - Select expression
  - Create new variable with inferred type
- [ ] **Refactor: Extract procedure**
  - Select code block
  - Create new proc with parameters
- [ ] **Refactor: Inline variable**
  - Replace variable with its value
- [ ] Add comprehensive tests for each code action
**Complexity:** High (major feature)

### 2.2 workspace/executeCommand
**Description:** Execute custom commands triggered by code actions
**Subtasks:**
- [ ] Add `ExecuteCommandParams` to messages.nim
- [ ] Add `executeCommandProvider` to ServerCapabilities
- [ ] Implement command registry
- [ ] Implement `nimlsp.organizeImports` command
- [ ] Implement `nimlsp.applyRefactoring` command
- [ ] Add tests
**Complexity:** Medium

### 2.3 textDocument/codeLens
**Description:** Show reference counts, implementation counts above symbols
**Subtasks:**
- [ ] Add `CodeLensParams`, `CodeLens` to messages.nim
- [ ] Add `codeLensProvider` to ServerCapabilities
- [ ] Implement handler to find all procedures/types
- [ ] Add reference count lens
- [ ] Add implementation count lens (for concepts/methods)
- [ ] Make lenses clickable (via commands)
- [ ] Add tests
**Complexity:** Medium

### 2.4 callHierarchy (Incoming/Outgoing)
**Description:** Show call hierarchy for functions
**Subtasks:**
- [ ] Add `CallHierarchyPrepareParams`, `CallHierarchyItem` to messages.nim
- [ ] Add `CallHierarchyIncomingCall`, `CallHierarchyOutgoingCall` types
- [ ] Add `callHierarchyProvider` to ServerCapabilities
- [ ] Implement `textDocument/prepareCallHierarchy`
- [ ] Implement `callHierarchy/incomingCalls` (who calls this?)
- [ ] Implement `callHierarchy/outgoingCalls` (what does this call?)
- [ ] Add tests
**Complexity:** High

### 2.5 typeHierarchy (Supertypes/Subtypes)
**Description:** Show type inheritance hierarchy
**Subtasks:**
- [ ] Add `TypeHierarchyPrepareParams`, `TypeHierarchyItem` to messages.nim
- [ ] Add `TypeHierarchySupertypesParams`, `TypeHierarchySubtypesParams`
- [ ] Add `typeHierarchyProvider` to ServerCapabilities
- [ ] Implement `textDocument/prepareTypeHierarchy`
- [ ] Implement `typeHierarchy/supertypes` (parent types)
- [ ] Implement `typeHierarchy/subtypes` (child types)
- [ ] Handle object inheritance
- [ ] Handle concept relationships
- [ ] Add tests
**Complexity:** High

---

## Phase 3: Advanced Editor Features

These features enhance the editing experience with visual aids.

### 3.1 textDocument/inlayHint
**Description:** Show inline type hints, parameter names
**Subtasks:**
- [ ] Add `InlayHintParams`, `InlayHint`, `InlayHintKind` to messages.nim
- [ ] Add `inlayHintProvider` to ServerCapabilities
- [ ] Implement handler structure
- [ ] **Type hints for variables**
  - Show inferred types for `let`/`var` without explicit types
- [ ] **Parameter name hints**
  - Show parameter names at call sites
- [ ] **Return type hints**
  - Show inferred return types for procedures
- [ ] Make hints configurable (enable/disable each type)
- [ ] Add tests
**Complexity:** High

### 3.2 textDocument/semanticTokens
**Description:** Rich semantic highlighting beyond syntax
**Subtasks:**
- [ ] Add `SemanticTokensParams`, `SemanticTokens` to messages.nim
- [ ] Define token types (namespace, type, class, enum, interface, struct, etc.)
- [ ] Define token modifiers (declaration, definition, readonly, etc.)
- [ ] Add `semanticTokensProvider` to ServerCapabilities
- [ ] Implement `textDocument/semanticTokens/full`
- [ ] Implement `textDocument/semanticTokens/range` (optional)
- [ ] Implement `textDocument/semanticTokens/delta` (optional)
- [ ] Map Nim symbols to semantic token types
- [ ] Add tests
**Complexity:** High

### 3.3 textDocument/foldingRange
**Description:** Define foldable code regions
**Subtasks:**
- [ ] Add `FoldingRangeParams`, `FoldingRange`, `FoldingRangeKind` to messages.nim
- [ ] Add `foldingRangeProvider` to ServerCapabilities
- [ ] Implement handler to find foldable regions
- [ ] Fold: procedures/functions
- [ ] Fold: type definitions
- [ ] Fold: import blocks
- [ ] Fold: comment blocks
- [ ] Fold: when/if blocks
- [ ] Fold: case statements
- [ ] Add tests
**Complexity:** Medium

### 3.4 textDocument/selectionRange
**Description:** Smart selection expansion (expand selection to larger constructs)
**Subtasks:**
- [ ] Add `SelectionRangeParams`, `SelectionRange` to messages.nim
- [ ] Add `selectionRangeProvider` to ServerCapabilities
- [ ] Implement handler with nested selection ranges
- [ ] Handle: expression → statement → block → procedure → file
- [ ] Add tests
**Complexity:** Medium

### 3.5 textDocument/documentLink
**Description:** Make paths/URLs in code clickable
**Subtasks:**
- [ ] Add `DocumentLinkParams`, `DocumentLink` to messages.nim
- [ ] Add `documentLinkProvider` to ServerCapabilities
- [ ] Detect import paths and make clickable
- [ ] Detect URLs in comments
- [ ] Detect file paths in strings
- [ ] Add tests
**Complexity:** Low

### 3.6 textDocument/linkedEditingRange
**Description:** Edit related symbols simultaneously (e.g., opening/closing tags)
**Subtasks:**
- [ ] Add `LinkedEditingRangeParams`, `LinkedEditingRanges` to messages.nim
- [ ] Add `linkedEditingRangeProvider` to ServerCapabilities
- [ ] Implement for string interpolation boundaries
- [ ] Implement for matching identifiers
- [ ] Add tests
**Complexity:** Low

---

## Phase 4: Workspace & Project Features

These features work across the entire workspace.

### 4.1 workspace/symbol
**Description:** Search for symbols across the entire workspace
**Subtasks:**
- [ ] Add `WorkspaceSymbolParams` to messages.nim
- [ ] Add `workspaceSymbolProvider` to ServerCapabilities
- [ ] Implement handler to search all project files
- [ ] Support fuzzy matching
- [ ] Support symbol kind filtering
- [ ] Cache symbols for performance
- [ ] Add tests
**Complexity:** Medium

### 4.2 workspace/applyEdit
**Description:** Apply edits to the workspace (server-initiated)
**Subtasks:**
- [ ] Add `ApplyWorkspaceEditParams`, `ApplyWorkspaceEditResult` to messages.nim
- [ ] Implement client → server flow
- [ ] Use for multi-file refactorings
- [ ] Add tests
**Complexity:** Low

### 4.3 workspace/didChangeConfiguration
**Description:** Handle configuration changes at runtime
**Subtasks:**
- [ ] Add `DidChangeConfigurationParams` to messages.nim
- [ ] Define NimLSP configuration schema
- [ ] Implement configuration handling
- [ ] Update behavior based on config changes
- [ ] Add tests
**Complexity:** Low

### 4.4 workspace/configuration
**Description:** Request configuration from client
**Subtasks:**
- [ ] Add `ConfigurationParams`, `ConfigurationItem` to messages.nim
- [ ] Implement configuration request
- [ ] Use for per-file formatting settings
- [ ] Add tests
**Complexity:** Low

### 4.5 workspace/didChangeWatchedFiles
**Description:** React to file system changes
**Subtasks:**
- [ ] Add `DidChangeWatchedFilesParams`, `FileEvent` to messages.nim
- [ ] Add `DidChangeWatchedFilesRegistrationOptions`
- [ ] Implement file watching registration
- [ ] Handle file create/change/delete events
- [ ] Re-scan project on relevant changes
- [ ] Add tests
**Complexity:** Medium

### 4.6 workspace/willRenameFiles / didRenameFiles
**Description:** Handle file renames and update imports
**Subtasks:**
- [ ] Add rename file params to messages.nim
- [ ] Implement pre-rename hook to compute edits
- [ ] Update import statements across project
- [ ] Add tests
**Complexity:** Medium-High

---

## Phase 5: Polish & Quality of Life

### 5.1 textDocument/formatting
**Description:** Format entire document
**Subtasks:**
- [ ] Add `DocumentFormattingParams` to messages.nim
- [ ] Add `documentFormattingProvider` to ServerCapabilities
- [ ] Integrate with nimpretty or custom formatter
- [ ] Handle formatting options (tabSize, insertSpaces)
- [ ] Add tests
**Complexity:** Medium (depends on formatter quality)

### 5.2 textDocument/rangeFormatting
**Description:** Format a specific range
**Subtasks:**
- [ ] Add `DocumentRangeFormattingParams` to messages.nim
- [ ] Add `documentRangeFormattingProvider` to ServerCapabilities
- [ ] Implement range-specific formatting
- [ ] Add tests
**Complexity:** Medium

### 5.3 textDocument/onTypeFormatting
**Description:** Format as you type (on specific characters)
**Subtasks:**
- [ ] Add `DocumentOnTypeFormattingParams` to messages.nim
- [ ] Add `documentOnTypeFormattingProvider` to ServerCapabilities
- [ ] Implement formatting on newline
- [ ] Implement formatting on closing brace
- [ ] Add tests
**Complexity:** Medium

### 5.4 window/workDoneProgress
**Description:** Show progress for long operations
**Subtasks:**
- [ ] Add `WorkDoneProgressCreateParams` to messages.nim
- [ ] Add `WorkDoneProgressBegin`, `WorkDoneProgressReport`, `WorkDoneProgressEnd`
- [ ] Implement progress reporting for nimsuggest initialization
- [ ] Implement progress for workspace symbol indexing
- [ ] Add tests
**Complexity:** Low

### 5.5 window/showMessage & window/showMessageRequest
**Description:** Show messages to users with optional actions
**Subtasks:**
- [ ] Add `ShowMessageParams`, `ShowMessageRequestParams` to messages.nim
- [ ] Add `MessageActionItem`
- [ ] Implement message display
- [ ] Implement action handling
- [ ] Add tests
**Complexity:** Low

### 5.6 Enhanced Completion
**Description:** Improve completion experience
**Subtasks:**
- [ ] Add completion item resolve support
- [ ] Add snippet support for templates/procedures
- [ ] Add auto-import on completion
- [ ] Add completion for file paths in imports
- [ ] Add completion sorting by relevance
- [ ] Add completion filtering by context
- [ ] Add tests
**Complexity:** Medium

### 5.7 Enhanced Diagnostics
**Description:** Improve diagnostic experience
**Subtasks:**
- [ ] Add diagnostic tags (unnecessary, deprecated)
- [ ] Add related information for diagnostics
- [ ] Add diagnostic codes
- [ ] Add code description URLs
- [ ] Implement textDocument/diagnostic (pull model)
- [ ] Add tests
**Complexity:** Medium

---

## Implementation Priority Order

### High Priority (Core functionality)
1. **textDocument/documentHighlight** - Easy win, nimsuggest has it
2. **textDocument/prepareRename** - Improves existing rename
3. **textDocument/codeAction** - Major feature, enables quick fixes
4. **workspace/symbol** - Essential for large projects
5. **textDocument/formatting** - Quality of life

### Medium Priority (Enhanced experience)
6. **textDocument/typeDefinition** - Navigation improvement
7. **textDocument/implementation** - Navigation improvement
8. **textDocument/inlayHint** - Modern editor feature
9. **textDocument/foldingRange** - Editor comfort
10. **textDocument/codeLens** - Information display

### Lower Priority (Advanced features)
11. **textDocument/semanticTokens** - Rich highlighting
12. **callHierarchy** - Code analysis
13. **typeHierarchy** - Code analysis
14. **textDocument/selectionRange** - Editor comfort
15. **workspace/didChangeWatchedFiles** - File monitoring

---

## Technical Notes

### nimsuggest Commands Available
- `sug` - Suggestions (completion)
- `con` - Context (signature help)
- `def` - Definition lookup
- `use` - Find usages
- `dus` - Definition and usages
- `chk` - Check file for errors
- `outline` - Document symbols
- `highlight` - Highlight occurrences
- `known` - Known symbols
- `mod` - File modification

### Key Files to Modify
- `src/nimlsp.nim` - Main handlers
- `src/nimlsppkg/messages.nim` - LSP types
- `src/nimlsppkg/messageenums.nim` - Enums
- `src/nimlsppkg/suggestlib.nim` - nimsuggest bridge

### Testing Strategy
- Unit tests for each new feature
- Integration tests with mock LSP client
- Test fixtures for complex scenarios
- Regression tests for existing functionality

---

## Success Metrics

- [ ] All Phase 1 features implemented and tested
- [ ] All Phase 2 features implemented and tested
- [ ] All Phase 3 features implemented and tested
- [ ] All Phase 4 features implemented and tested
- [ ] All Phase 5 features implemented and tested
- [ ] Documentation updated
- [ ] Performance benchmarks show no regression
- [ ] Feature parity checklist with TypeScript LSP completed

---

## References

- [LSP 3.17 Specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
- [TypeScript Language Server](https://github.com/typescript-language-server/typescript-language-server)
- [nimsuggest Documentation](https://nim-lang.org/docs/nimsuggest.html)
