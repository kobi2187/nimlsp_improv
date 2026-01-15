type
  ErrorCode* = enum
    RequestCancelled = -32800 # All the other error codes are from JSON-RPC
    ParseError = -32700,
    InternalError = -32603,
    InvalidParams = -32602,
    MethodNotFound = -32601,
    InvalidRequest = -32600,
    ServerErrorStart = -32099,
    ServerNotInitialized = -32002,
    ServerErrorEnd = -32000

# Anything below here comes from the LSP specification
type
  DiagnosticSeverity* {.pure.} = enum
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4

  SymbolKind* {.pure.} = enum
    File = 1,
    Module = 2,
    Namespace = 3,
    Package = 4,
    Class = 5,
    Method = 6,
    Property = 7,
    Field = 8,
    Constructor = 9,
    Enum = 10,
    Interface = 11,
    Function = 12,
    Variable = 13,
    Constant = 14,
    String = 15,
    Number = 16,
    Boolean = 17,
    Array = 18,
    Object = 19,
    Key = 20,
    Null = 21,
    EnumMember = 22,
    Struct = 23,
    Event = 24,
    Operator = 25,
    TypeParameter = 26

  CompletionItemKind* {.pure.} = enum
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25

  TextDocumentSyncKind* {.pure.} = enum
    None = 0,
    Full = 1,
    Incremental = 2

  MessageType* {.pure.} = enum
    Error = 1,
    Warning = 2,
    Info = 3,
    Log = 4

  FileChangeType* {.pure.} = enum
    Created = 1,
    Changed = 2,
    Deleted = 3

  WatchKind* {.pure.} = enum
    Create = 1,
    Change = 2,
    Delete = 4

  TextDocumentSaveReason* {.pure.} = enum
    Manual = 1,
    AfterDelay = 2,
    FocusOut = 3

  CompletionTriggerKind* {.pure.} = enum
    Invoked = 1,
    TriggerCharacter = 2,
    TriggerForIncompleteCompletions = 3

  InsertTextFormat* {.pure.} = enum
    PlainText = 1,
    Snippet = 2

  DocumentHighlightKind* {.pure.} = enum
    Text = 1,
    Read = 2,
    Write = 3

  FoldingRangeKind* {.pure.} = enum
    Comment = "comment",
    Imports = "imports",
    Region = "region"

  InlayHintKind* {.pure.} = enum
    Type = 1,
    Parameter = 2

  # Semantic token types (LSP 3.16+)
  SemanticTokenType* {.pure.} = enum
    Namespace = "namespace",
    Type = "type",
    Class = "class",
    Enum = "enum",
    Interface = "interface",
    Struct = "struct",
    TypeParameter = "typeParameter",
    Parameter = "parameter",
    Variable = "variable",
    Property = "property",
    EnumMember = "enumMember",
    Event = "event",
    Function = "function",
    Method = "method",
    Macro = "macro",
    Keyword = "keyword",
    Modifier = "modifier",
    Comment = "comment",
    String = "string",
    Number = "number",
    Regexp = "regexp",
    Operator = "operator",
    Decorator = "decorator"

  # Semantic token modifiers (LSP 3.16+)
  SemanticTokenModifier* {.pure.} = enum
    Declaration = "declaration",
    Definition = "definition",
    Readonly = "readonly",
    Static = "static",
    Deprecated = "deprecated",
    Abstract = "abstract",
    Async = "async",
    Modification = "modification",
    Documentation = "documentation",
    DefaultLibrary = "defaultLibrary"

  # Code action kinds
  CodeActionKind* {.pure.} = enum
    Empty = "",
    QuickFix = "quickfix",
    Refactor = "refactor",
    RefactorExtract = "refactor.extract",
    RefactorInline = "refactor.inline",
    RefactorRewrite = "refactor.rewrite",
    Source = "source",
    SourceOrganizeImports = "source.organizeImports",
    SourceFixAll = "source.fixAll"

  # Diagnostic tags (LSP 3.15+)
  DiagnosticTag* {.pure.} = enum
    Unnecessary = 1,  # Faded out code (unused variables, imports)
    Deprecated = 2    # Strike-through text (deprecated symbols)
