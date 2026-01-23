import std/[algorithm, asyncdispatch, asyncfile, hashes, os, osproc, sets,
            streams, strformat, strutils, tables, times, uri]
import asynctools/asyncproc
import nimlsppkg/[baseprotocol, logger, suggestlib, utfmapping]
include nimlsppkg/messages
include nimlsppkg/messageenums


const
  version = block:
    var version = "0.0.0"
    let nimbleFile = staticRead(currentSourcePath().parentDir /../ "nimlsp.nimble")
    for line in nimbleFile.splitLines:
      let keyval = line.split('=')
      if keyval.len == 2:
        if keyval[0].strip == "version":
          version = keyval[1].strip(chars = Whitespace + {'"'})
          break
    version
  # This is used to explicitly set the default source path
  explicitSourcePath {.strdefine.} = getCurrentCompilerExe().parentDir.parentDir

type
  UriParseError* = object of Defect
    uri: string

proc uriToPath(uri: string): string =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.
  let parsed = uri.parseUri
  if parsed.scheme != "file":
    var e = newException(UriParseError, &"Invalid scheme: {parsed.scheme}, only \"file\" is supported")
    e.uri = uri
    raise e
  if parsed.hostname != "":
    var e = newException(UriParseError, &"Invalid hostname: {parsed.hostname}, only empty hostname is supported")
    e.uri = uri
    raise e
  return normalizedPath(
    when defined(windows):
      parsed.path[1..^1]
    else:
      parsed.path).decodeUrl

var nimpath = explicitSourcePath

infoLog("Version: ", version)
infoLog("explicitSourcePath: ", explicitSourcePath)
for i in 1..paramCount():
  infoLog("Argument ", i, ": ", paramStr(i))

type
  # Cache entry for symbol information
  SymbolCache = object
    timestamp: float  # When cache was created
    symbols: seq[Suggest]  # Cached symbols

  # Configuration options
  NimLspConfig = object
    inlayHintsEnabled: bool
    codeLensEnabled: bool
    semanticTokensEnabled: bool
    maxCompletionItems: int

var
  gotShutdown = false
  initialized = false
  projectFiles = initTable[string, tuple[nimsuggest: NimSuggest, openFiles: OrderedSet[string], dirtyFiles: HashSet[string]]]()
  openFiles = initTable[string, tuple[projectFile: string, fingerTable: seq[seq[tuple[u16pos, offset: int]]]]]()
  # Symbol caches for faster lookups
  outlineCache = initTable[string, SymbolCache]()
  knownSymbolsCache = initTable[string, SymbolCache]()
  # Default configuration
  config = NimLspConfig(
    inlayHintsEnabled: true,
    codeLensEnabled: true,
    semanticTokensEnabled: true,
    maxCompletionItems: 100
  )

const
  CacheExpirationSeconds = 5.0  # Cache expires after 5 seconds

template getNimsuggest(fileuri: string): Nimsuggest =
  projectFiles[openFiles[fileuri].projectFile].nimsuggest

proc isCacheValid(cache: SymbolCache): bool =
  ## Check if cache is still valid
  let now = epochTime()
  result = (now - cache.timestamp) < CacheExpirationSeconds

proc getCachedOutline(fileuri: string, filestash: string): seq[Suggest] =
  ## Get outline from cache or fetch fresh
  if fileuri in outlineCache and outlineCache[fileuri].isCacheValid:
    return outlineCache[fileuri].symbols
  # Fetch fresh
  let symbols = getNimsuggest(fileuri).outline(uriToPath(fileuri), dirtyfile = filestash)
  outlineCache[fileuri] = SymbolCache(timestamp: epochTime(), symbols: symbols)
  return symbols

proc getCachedKnownSymbols(fileuri: string, filestash: string): seq[Suggest] =
  ## Get known symbols from cache or fetch fresh
  if fileuri in knownSymbolsCache and knownSymbolsCache[fileuri].isCacheValid:
    return knownSymbolsCache[fileuri].symbols
  # Fetch fresh
  let symbols = getNimsuggest(fileuri).known(uriToPath(fileuri), dirtyfile = filestash)
  knownSymbolsCache[fileuri] = SymbolCache(timestamp: epochTime(), symbols: symbols)
  return symbols

proc invalidateCache(fileuri: string) =
  ## Invalidate caches for a file
  outlineCache.del(fileuri)
  knownSymbolsCache.del(fileuri)

proc getDiagnosticTags(message: string): Option[seq[int]] =
  ## Get diagnostic tags based on the message content
  var tags: seq[int] = @[]

  # Check for "unused" patterns - Unnecessary tag
  if "imported and not used" in message or
     "is never used" in message or
     "declared but not used" in message or
     "is unused" in message:
    tags.add DiagnosticTag.Unnecessary.int

  # Check for "deprecated" patterns - Deprecated tag
  if "is deprecated" in message or
     "deprecated" in message.toLowerAscii:
    tags.add DiagnosticTag.Deprecated.int

  if tags.len > 0:
    result = some(tags)
  else:
    result = none(seq[int])

proc createDiagnosticFromSuggest(suggest: Suggest): Diagnostic =
  ## Create a Diagnostic from a nimsuggest Suggest result
  let
    message = suggest.doc
    endcolumn = suggest.column + message.rfind('\'') - message.find('\'') - 1
    tags = getDiagnosticTags(message)

  result = create(Diagnostic,
    create(Range,
      create(Position, suggest.line-1, suggest.column),
      create(Position, suggest.line-1, max(suggest.column, endcolumn))
    ),
    some(case suggest.forth:
      of "Error": DiagnosticSeverity.Error.int
      of "Hint": DiagnosticSeverity.Hint.int
      of "Warning": DiagnosticSeverity.Warning.int
      else: DiagnosticSeverity.Error.int),
    none(int),
    none(CodeDescription),
    some("nimsuggest chk"),
    message,
    tags,
    none(seq[DiagnosticRelatedInformation])
  )

template whenValid(data, kind, body) =
  if data.isValid(kind, allowExtra = true):
    var data = kind(data)
    body
  else:
    debugLog("Unable to parse data as ", kind)

template whenValidStrict(data, kind, body) =
  if data.isValid(kind):
    var data = kind(data)
    body
  else:
    debugLog("Unable to parse data as ", kind)

proc getFileStash(fileuri: string): string =
  return storage / (hash(fileuri).toHex & ".nim")

template textDocumentRequest(message, kind, name, body) {.dirty.} =
  if message["params"].isSome:
    let name = message["params"].unsafeGet
    whenValid(name, kind):
      let
        fileuri = name["textDocument"]["uri"].getStr
        filestash = storage / (hash(fileuri).toHex & ".nim" )
      debugLog "Got request for URI: ", fileuri, " copied to ", filestash
      when kind isnot DocumentSymbolParams:
        let
          rawLine = name["position"]["line"].getInt
          rawChar = name["position"]["character"].getInt
      body

template textDocumentNotification(message, kind, name, body) {.dirty.} =
  if message["params"].isSome:
    let name = message["params"].unsafeGet
    whenValid(name, kind):
      if "languageId" notin name["textDocument"] or name["textDocument"]["languageId"].getStr == "nim":
        let
          fileuri = name["textDocument"]["uri"].getStr
          filestash = storage / (hash(fileuri).toHex & ".nim" )
        body

proc pathToUri(path: string): string =
  # This is a modified copy of encodeUrl in the uri module. This doesn't encode
  # the / character, meaning a full file path can be passed in without breaking
  # it.
  result = newStringOfCap(path.len + path.len shr 2) # assume 12% non-alnum-chars
  when defined(windows):
    result.add '/'
  for c in path:
    case c
    # https://tools.ietf.org/html/rfc3986#section-2.3
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/': result.add c
    of '\\':
      when defined(windows):
        result.add '/'
      else:
        result.add '%'
        result.add toHex(ord(c), 2)
    else:
      result.add '%'
      result.add toHex(ord(c), 2)

proc parseId(node: JsonNode): int =
  if node.kind == JString:
    parseInt(node.getStr)
  elif node.kind == JInt:
    node.getInt
  else:
    raise newException(MalformedFrame, "Invalid id node: " & repr(node))

proc respond(outs: Stream | AsyncFile, request: RequestMessage, data: JsonNode) {.multisync.} =
  let resp = create(ResponseMessage, "2.0", parseId(request["id"]), some(data), none(ResponseError)).JsonNode
  await outs.sendJson resp

proc error(outs: Stream | AsyncFile, request: RequestMessage, errorCode: ErrorCode, message: string, data: JsonNode) {.multisync.} =
  let resp = create(ResponseMessage, "2.0", parseId(request["id"]), none(JsonNode), some(create(ResponseError, ord(errorCode), message, data))).JsonNode
  await outs.sendJson resp

proc notify(outs: Stream | AsyncFile, notification: string, data: JsonNode) {.multisync.} =
  let resp = create(NotificationMessage, "2.0", notification, some(data)).JsonNode
  await outs.sendJson resp

type Certainty = enum
  None,
  Folder,
  Cfg,
  Nimble

proc getProjectFile(fileUri: string): string =
  let file = fileUri.decodeUrl
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = None
  while not path.isRootDir:
    let
      (dir, fname, ext) = path.splitFile()
      current = fname & ext
    if fileExists(path / current.addFileExt(".nim")) and certainty <= Folder:
      result = path / current.addFileExt(".nim")
      certainty = Folder
    if fileExists(path / current.addFileExt(".nim")) and
      (fileExists(path / current.addFileExt(".nim.cfg")) or
      fileExists(path / current.addFileExt(".nims"))) and certainty <= Cfg:
      result = path / current.addFileExt(".nim")
      certainty = Cfg
    if certainty <= Nimble:
      for nimble in walkFiles(path / "*.nimble"):
        let info = osproc.execProcess("nimble dump " & nimble, options = {osproc.poEvalCommand, osproc.poUsePath})
        var sourceDir, name: string
        for line in info.splitLines:
          if line.startsWith("srcDir"):
            sourceDir = path / line[(1 + line.find '"')..^2]
          if line.startsWith("name"):
            name = line[(1 + line.find '"')..^2]
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and
            file.isRelativeTo(sourceDir) and fileExists(projectFile):
          result = projectFile
          certainty = Nimble
    path = dir
  debugLog "Found project file " & result & " for input file " & fileUri

# Parse command line arguments
var customNimPath = ""
for i in 1..paramCount():
  let arg = paramStr(i)
  case arg:
    of "--help":
      echo "Usage: nimlsp [OPTIONS] [PATH]\n"
      echo "--help, shows this message"
      echo "--version, shows only the version"
      echo "--stdio, use stdio for communication (default)"
      echo "PATH, path to the Nim source directory, defaults to \"", nimpath, "\""
      quit 0
    of "--version":
      echo "nimlsp v", version, " - built for Nim version ", NimVersion
      when defined(debugLogging): echo "Compiled with debug logging"
      when defined(debugCommunication): echo "Compiled with communication logging"
      quit 0
    of "--stdio":
      # This is the default behavior, ignore it
      discard
    else:
      # Treat as path to Nim sources
      customNimPath = arg

if customNimPath != "":
  nimpath = expandFilename(customNimPath)
if not fileExists(nimpath / "config/nim.cfg"):
  stderr.write &"""Unable to find "config/nim.cfg" in "{nimpath
  }". Supply the Nim project folder by adding it as an argument.
"""
  quit 1

proc checkVersion(outs: Stream | AsyncFile) {.multisync.} =
  let
    nimoutputTuple =
      when outs is AsyncFile: await asyncproc.execProcess("nim --version", options = {asyncproc.poEvalCommand, asyncproc.poUsePath})
      else: osproc.execCmdEx("nim --version", options = {osproc.poEvalCommand, osproc.poUsePath})
  if nimoutputTuple.exitcode == 0:
    let
      nimoutput = nimoutputTuple.output
      versionStart = "Nim Compiler Version ".len
      version = nimoutput[versionStart..<nimoutput.find(" ", versionStart)]
      #hashStart = nimoutput.find("git hash") + 10
      #hash = nimoutput[hashStart..nimoutput.find("\n", hashStart)]
    if version != NimVersion:
      await outs.notify("window/showMessage", create(ShowMessageParams, MessageType.Warning.int, message = "Current Nim version does not match the one NimLSP is built against " & version & " != " & NimVersion).JsonNode)

proc main(ins: Stream | AsyncFile, outs: Stream | AsyncFile) {.multisync.} =
  while true:
    try:
      debugLog "Trying to read frame"
      let frame = await ins.readFrame
      debugLog "Got frame"
      let message = frame.parseJson
      whenValidStrict(message, RequestMessage):
        debugLog "Got valid Request message of type ", message["method"].getStr
        if not initialized and message["method"].getStr != "initialize":
          await outs.error(message, ServerNotInitialized, "Unable to accept requests before being initialized", newJNull())
          continue
        case message["method"].getStr:
          of "shutdown":
            debugLog "Got shutdown request, answering"
            let resp = newJNull()
            await outs.respond(message, resp)
            gotShutdown = true
          of "initialize":
            debugLog "Got initialize request, answering"
            initialized = true

            # Define semantic tokens legend
            let semanticTokensLegend = create(SemanticTokensLegend,
              tokenTypes = @[
                "namespace", "type", "class", "enum", "interface",
                "struct", "typeParameter", "parameter", "variable", "property",
                "enumMember", "event", "function", "method", "macro",
                "keyword", "modifier", "comment", "string", "number",
                "regexp", "operator", "decorator"
              ],
              tokenModifiers = @[
                "declaration", "definition", "readonly", "static",
                "deprecated", "abstract", "async", "modification",
                "documentation", "defaultLibrary"
              ]
            )

            let resp = create(InitializeResult, create(ServerCapabilities,
              textDocumentSync = some(create(TextDocumentSyncOptions,
                openClose = some(true),
                change = some(TextDocumentSyncKind.Full.int),
                willSave = some(false),
                willSaveWaitUntil = some(false),
                save = some(create(SaveOptions, some(true)))
              )),
              hoverProvider = some(true),
              completionProvider = some(create(CompletionOptions,
                resolveProvider = some(false),
                triggerCharacters = some(@["."])
              )),
              signatureHelpProvider = some(create(SignatureHelpOptions,
                triggerCharacters = some(@["(", ","])
              )),
              definitionProvider = some(true),
              declarationProvider = some(true),  # NEW: Go to declaration
              typeDefinitionProvider = some(true),  # NEW: Go to type definition
              implementationProvider = some(true),  # NEW: Go to implementation
              referencesProvider = some(true),
              documentHighlightProvider = some(true),  # NEW: Highlight occurrences
              documentSymbolProvider = some(true),
              workspaceSymbolProvider = some(true),  # NEW: Workspace symbol search
              codeActionProvider = some(true),  # NEW: Code actions (quick fixes, refactoring)
              codeLensProvider = some(create(CodeLensOptions,
                resolveProvider = some(false)
              )),  # NEW: Reference counts
              documentFormattingProvider = some(true),  # NEW: Code formatting via nimpretty
              documentRangeFormattingProvider = some(true),  # NEW: Range formatting
              documentOnTypeFormattingProvider = none(DocumentOnTypeFormattingOptions),
              renameProvider = some(true),
              documentLinkProvider = some(create(DocumentLinkOptions,
                resolveProvider = some(false)
              )),  # NEW: Clickable imports
              colorProvider = none(bool),
              foldingRangeProvider = some(true),  # NEW: Code folding
              selectionRangeProvider = some(true),  # NEW: Smart selection
              callHierarchyProvider = some(true),  # NEW: Call hierarchy
              typeHierarchyProvider = some(true),  # NEW: Type hierarchy
              semanticTokensProvider = some(create(SemanticTokensOptions,
                semanticTokensLegend,
                some(false),  # range
                some(true)    # full
              )),  # NEW: Semantic tokens for syntax highlighting
              inlayHintProvider = some(true),  # NEW: Inlay hints (type hints)
              executeCommandProvider = some(create(ExecuteCommandOptions,
                commands = @["nimlsp.organizeImports", "nimlsp.restartServer", "nimlsp.showReferences"]
              )),  # NEW: Custom commands
              workspace = none(WorkspaceCapability),
              experimental = none(JsonNode)
            )).JsonNode
            await outs.respond(message,resp)
            when outs is AsyncFile:
              await checkVersion(outs)
            else:
              checkVersion(outs)
          of "textDocument/completion":
            message.textDocumentRequest(CompletionParams, compRequest):
              debugLog "Running equivalent of: sug ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).sug(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found suggestions: ",
                suggestions[0..<min(suggestions.len, 10)],
                if suggestions.len > 10: &" and {suggestions.len-10} more" else: ""
              var
                completionItems = newJarray()
                seenLabels: CountTable[string]
                addedSuggestions: HashSet[string]
              for suggestion in suggestions:
                seenLabels.inc suggestion.collapseByIdentifier
              for i in 0..min(suggestions.high, config.maxCompletionItems - 1):
                let
                  suggestion = suggestions[i]
                  collapsed = suggestion.collapseByIdentifier
                if not addedSuggestions.contains collapsed:
                  addedSuggestions.incl collapsed
                  let
                    seenTimes = seenLabels[collapsed]
                    detail =
                      if seenTimes == 1: some(nimSymDetails(suggestion))
                      else: some(&"[{seenTimes} overloads]")
                    symKind = suggestion.symKind.TSymKind
                    # Generate snippet for procedures/functions
                    (insertText, insertTextFormat) =
                      if symKind in {skProc, skFunc, skMethod, skTemplate, skMacro, skIterator}:
                        # Parse signature to create snippet with placeholders
                        let sig = suggestion.forth
                        if "(" in sig:
                          let
                            parenStart = sig.find('(')
                            parenEnd = sig.rfind(')')
                          if parenStart < parenEnd:
                            let params = sig[parenStart+1..<parenEnd]
                            if params.len > 0:
                              var snippetParts: seq[string] = @[]
                              var paramNum = 1
                              for param in params.split(','):
                                let
                                  trimmed = param.strip()
                                  colonPos = trimmed.find(':')
                                  paramName = if colonPos > 0: trimmed[0..<colonPos].strip() else: trimmed
                                if paramName.len > 0:
                                  snippetParts.add "${" & $paramNum & ":" & paramName & "}"
                                  inc paramNum
                              (some(suggestion.qualifiedPath[^1].strip(chars = {'`'}) & "(" & snippetParts.join(", ") & ")$0"), some(InsertTextFormat.Snippet.int))
                            else:
                              (some(suggestion.qualifiedPath[^1].strip(chars = {'`'}) & "()$0"), some(InsertTextFormat.Snippet.int))
                          else:
                            (none(string), none(int))
                        else:
                          (none(string), none(int))
                      else:
                        (none(string), none(int))
                  completionItems.add create(CompletionItem,
                    label = suggestion.qualifiedPath[^1].strip(chars = {'`'}),
                    kind = some(nimSymToLSPKind(suggestion).int),
                    detail = detail,
                    documentation = some(suggestion.doc),
                    deprecated = none(bool),
                    preselect = none(bool),
                    sortText = some(fmt"{i:04}"),
                    filterText = none(string),
                    insertText = insertText,
                    insertTextFormat = insertTextFormat,
                    textEdit = none(TextEdit),
                    additionalTextEdits = none(seq[TextEdit]),
                    commitCharacters = none(seq[string]),
                    command = none(Command),
                    data = none(JsonNode)
                  ).JsonNode
              await outs.respond(message, completionItems)
          of "textDocument/hover":
            message.textDocumentRequest(TextDocumentPositionParams, hoverRequest):
              debugLog "Running equivalent of: def ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found suggestions: ",
                suggestions[0..<min(suggestions.len, 10)],
                if suggestions.len > 10: &" and {suggestions.len-10} more" else: ""
              var resp: JsonNode
              if suggestions.len == 0:
                resp = newJNull()
              else:
                var label = suggestions[0].qualifiedPath.join(".")
                if suggestions[0].forth != "":
                  label &= ": "
                  label &= suggestions[0].forth
                let
                  rangeopt =
                    some(create(Range,
                      create(Position, rawLine, rawChar),
                      create(Position, rawLine, rawChar + suggestions[0].qualifiedPath[^1].len)
                    ))
                  markedString = create(MarkedStringOption, "nim", label)
                if suggestions[0].doc != "":
                  resp = create(Hover,
                    @[
                      markedString,
                      create(MarkedStringOption, "", suggestions[0].doc),
                    ],
                    rangeopt
                  ).JsonNode
                else:
                  resp = create(Hover, markedString, rangeopt).JsonNode;
                await outs.respond(message, resp)
          of "textDocument/references":
            message.textDocumentRequest(ReferenceParams, referenceRequest):
              debugLog "Running equivalent of: use ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).use(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found suggestions: ",
                suggestions[0..<min(suggestions.len, 10)],
                if suggestions.len > 10: &" and {suggestions.len-10} more" else: ""
              var response = newJarray()
              for suggestion in suggestions:
                if suggestion.section == ideUse or referenceRequest["context"]["includeDeclaration"].getBool:
                  response.add create(Location,
                    "file://" & pathToUri(suggestion.filepath),
                    create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    )
                  ).JsonNode
              if response.len == 0:
                await outs.respond(message, newJNull())
              else:
                await outs.respond(message, response)
          of "textDocument/rename":
            message.textDocumentRequest(RenameParams, renameRequest):
              debugLog "Running equivalent of: use ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).use(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found suggestions: ",
                suggestions[0..<min(suggestions.len, 10)],
                if suggestions.len > 10: &" and {suggestions.len-10} more" else: ""
              var resp: JsonNode
              if suggestions.len == 0:
                resp = newJNull()
              else:
                var textEdits = newJObject()
                for suggestion in suggestions:
                  let uri = "file://" & pathToUri(suggestion.filepath)
                  if uri notin textEdits:
                    textEdits[uri] = newJArray()
                  textEdits[uri].add create(TextEdit, create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    ),
                    renameRequest["newName"].getStr
                  ).JsonNode
                resp = create(WorkspaceEdit,
                  some(textEdits),
                  none(seq[TextDocumentEdit])
                ).JsonNode
                await outs.respond(message, resp)
          of "textDocument/definition":
            message.textDocumentRequest(TextDocumentPositionParams, definitionRequest):
              debugLog "Running equivalent of: def ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let declarations = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found suggestions: ",
                declarations[0..<min(declarations.len, 10)],
                if declarations.len > 10: &" and {declarations.len-10} more" else: ""
              var resp: JsonNode
              if declarations.len == 0:
                resp = newJNull()
              else:
                resp = newJarray()
                for declaration in declarations:
                  resp.add create(Location,
                    "file://" & pathToUri(declaration.filepath),
                    create(Range,
                      create(Position, declaration.line-1, declaration.column),
                      create(Position, declaration.line-1, declaration.column + declaration.qualifiedPath[^1].len)
                    )
                  ).JsonNode
              await outs.respond(message, resp)
          of "textDocument/documentSymbol":
            message.textDocumentRequest(DocumentSymbolParams, symbolRequest):
              debugLog "Running equivalent of: outline ", uriToPath(fileuri),
                        ";", filestash
              let syms = getNimsuggest(fileuri).outline(
                uriToPath(fileuri),
                dirtyfile = filestash
              )
              debugLog "Found outlines: ", syms[0..<min(syms.len, 10)],
                        if syms.len > 10: &" and {syms.len-10} more" else: ""
              var resp: JsonNode
              if syms.len == 0:
                resp = newJNull()
              else:
                resp = newJarray()
                for sym in syms.sortedByIt((it.line,it.column,it.quality)):
                  if sym.qualifiedPath.len != 2:
                    continue
                  resp.add create(
                    SymbolInformation,
                    sym.name[],
                    nimSymToLSPKind(sym.symKind).int,
                    some(false),
                    create(Location,
                    "file://" & pathToUri(sym.filepath),
                      create(Range,
                        create(Position, sym.line-1, sym.column),
                        create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len)
                      )
                    ),
                    none(string)
                  ).JsonNode
              await outs.respond(message, resp)
          of "textDocument/signatureHelp":
            message.textDocumentRequest(TextDocumentPositionParams, sigHelpRequest):
              debugLog "Running equivalent of: con ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).con(uriToPath(fileuri), dirtyfile = filestash, rawLine + 1, rawChar)
              var signatures = newSeq[SignatureInformation]()
              for suggestion in suggestions:
                var label = suggestion.qualifiedPath.join(".")
                if suggestion.forth != "":
                  label &= ": "
                  label &= suggestion.forth
                signatures.add create(SignatureInformation,
                  label = label,
                  documentation = some(suggestion.doc),
                  parameters = none(seq[ParameterInformation])
                )
              let resp = create(SignatureHelp,
                signatures = signatures,
                activeSignature = some(0),
                activeParameter = some(0)
              ).JsonNode
              await outs.respond(message, resp)

          # ============= NEW FEATURES =============

          of "textDocument/documentHighlight":
            # Highlight all occurrences of a symbol in the current document
            message.textDocumentRequest(TextDocumentPositionParams, highlightRequest):
              debugLog "Running equivalent of: highlight ", uriToPath(fileuri), ";", filestash
              let highlights = getNimsuggest(fileuri).highlight(uriToPath(fileuri), dirtyfile = filestash)
              debugLog "Found highlights: ",
                highlights[0..<min(highlights.len, 10)],
                if highlights.len > 10: &" and {highlights.len-10} more" else: ""
              var response = newJarray()
              for hl in highlights:
                # Filter to only include highlights in the current file
                if hl.filepath == uriToPath(fileuri):
                  response.add create(DocumentHighlight,
                    create(Range,
                      create(Position, hl.line-1, hl.column),
                      create(Position, hl.line-1, hl.column + hl.qualifiedPath[^1].len)
                    ),
                    some(DocumentHighlightKind.Text.int)  # nimsuggest doesn't distinguish read/write
                  ).JsonNode
              if response.len == 0:
                await outs.respond(message, newJNull())
              else:
                await outs.respond(message, response)

          of "textDocument/typeDefinition":
            # Go to the type definition of a symbol
            message.textDocumentRequest(TextDocumentPositionParams, typeDefRequest):
              debugLog "Running equivalent of: def ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found suggestions for typeDefinition: ",
                suggestions[0..<min(suggestions.len, 10)],
                if suggestions.len > 10: &" and {suggestions.len-10} more" else: ""
              var resp: JsonNode
              if suggestions.len == 0:
                resp = newJNull()
              else:
                # For type definition, we want to find the type of the symbol
                # The `forth` field contains the type information
                let suggestion = suggestions[0]
                let typeName = suggestion.forth.split(" ")[0]  # Get the type name
                # Try to find the type definition
                let typeDefs = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                  suggestion.line, suggestion.column)
                resp = newJarray()
                if typeDefs.len > 0:
                  for typeDef in typeDefs:
                    resp.add create(Location,
                      "file://" & pathToUri(typeDef.filepath),
                      create(Range,
                        create(Position, typeDef.line-1, typeDef.column),
                        create(Position, typeDef.line-1, typeDef.column + typeDef.qualifiedPath[^1].len)
                      )
                    ).JsonNode
                else:
                  # Fall back to the original definition
                  resp.add create(Location,
                    "file://" & pathToUri(suggestion.filepath),
                    create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    )
                  ).JsonNode
              await outs.respond(message, resp)

          of "textDocument/implementation":
            # Go to implementations (similar to references for now)
            message.textDocumentRequest(TextDocumentPositionParams, implRequest):
              debugLog "Running equivalent of: use ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).use(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found implementations: ",
                suggestions[0..<min(suggestions.len, 10)],
                if suggestions.len > 10: &" and {suggestions.len-10} more" else: ""
              var response = newJarray()
              for suggestion in suggestions:
                # For implementations, we look for definitions (ideDef) rather than usages
                if suggestion.section == ideDef:
                  response.add create(Location,
                    "file://" & pathToUri(suggestion.filepath),
                    create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    )
                  ).JsonNode
              if response.len == 0:
                await outs.respond(message, newJNull())
              else:
                await outs.respond(message, response)

          of "textDocument/declaration":
            # Go to declaration (same as definition in Nim)
            message.textDocumentRequest(TextDocumentPositionParams, declRequest):
              debugLog "Running equivalent of: def ", uriToPath(fileuri), ";", filestash, ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let declarations = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              debugLog "Found declarations: ",
                declarations[0..<min(declarations.len, 10)],
                if declarations.len > 10: &" and {declarations.len-10} more" else: ""
              var resp: JsonNode
              if declarations.len == 0:
                resp = newJNull()
              else:
                resp = newJarray()
                for declaration in declarations:
                  resp.add create(Location,
                    "file://" & pathToUri(declaration.filepath),
                    create(Range,
                      create(Position, declaration.line-1, declaration.column),
                      create(Position, declaration.line-1, declaration.column + declaration.qualifiedPath[^1].len)
                    )
                  ).JsonNode
              await outs.respond(message, resp)

          of "textDocument/prepareRename":
            # Validate if rename is possible and return the range to rename
            message.textDocumentRequest(TextDocumentPositionParams, prepareRenameRequest):
              debugLog "Running prepareRename for ", uriToPath(fileuri), ":",
                rawLine + 1, ":",
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              let suggestions = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1,
                openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)
              )
              var resp: JsonNode
              if suggestions.len == 0:
                resp = newJNull()
              else:
                let suggestion = suggestions[0]
                let symbolName = suggestion.qualifiedPath[^1]
                resp = create(PrepareRenameResult,
                  create(Range,
                    create(Position, rawLine, rawChar),
                    create(Position, rawLine, rawChar + symbolName.len)
                  ),
                  symbolName
                ).JsonNode
              await outs.respond(message, resp)

          of "textDocument/codeAction":
            # Provide code actions (quick fixes, refactoring)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, CodeActionParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                let diagnostics = params["context"]["diagnostics"]
                debugLog "Got code action request for URI: ", fileuri

                var actions = newJarray()

                # Check diagnostics for quick fixes
                for diag in diagnostics:
                  let diagMessage = diag["message"].getStr

                  # Quick fix: unused import
                  if "imported and not used" in diagMessage or "is never used" in diagMessage:
                    let unusedName = diagMessage.split("'")[1]
                    actions.add create(CodeAction,
                      title = "Remove unused import: " & unusedName,
                      kind = some($CodeActionKind.QuickFix),
                      diagnostics = some(@[Diagnostic(diag)]),
                      isPreferred = some(true),
                      edit = none(WorkspaceEdit),
                      command = none(Command),
                      data = none(JsonNode)
                    ).JsonNode

                  # Quick fix: undeclared identifier (suggest import)
                  if "undeclared identifier" in diagMessage:
                    let symbolName = diagMessage.split("'")[1]
                    actions.add create(CodeAction,
                      title = "Search for module containing: " & symbolName,
                      kind = some($CodeActionKind.QuickFix),
                      diagnostics = some(@[Diagnostic(diag)]),
                      isPreferred = some(false),
                      edit = none(WorkspaceEdit),
                      command = none(Command),
                      data = none(JsonNode)
                    ).JsonNode

                # Source action: Organize imports
                actions.add create(CodeAction,
                  title = "Organize imports",
                  kind = some($CodeActionKind.SourceOrganizeImports),
                  diagnostics = none(seq[Diagnostic]),
                  isPreferred = some(false),
                  edit = none(WorkspaceEdit),
                  command = some(create(Command, "Organize imports", "nimlsp.organizeImports", some(@[%fileuri]))),
                  data = none(JsonNode)
                ).JsonNode

                await outs.respond(message, actions)

          of "textDocument/codeLens":
            # Provide code lenses (reference counts, etc.)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, CodeLensParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                debugLog "Got code lens request for URI: ", fileuri

                # Get document symbols to add lenses to
                let syms = getNimsuggest(fileuri).outline(uriToPath(fileuri), dirtyfile = filestash)

                var lenses = newJarray()
                for sym in syms:
                  if sym.qualifiedPath.len >= 2:
                    # Only add lenses to top-level symbols
                    let symKind = sym.symKind.TSymKind
                    if symKind in {skProc, skFunc, skMethod, skType, skTemplate, skMacro}:
                      # Get reference count
                      let refs = getNimsuggest(fileuri).use(uriToPath(fileuri), dirtyfile = filestash,
                        sym.line, sym.column)
                      let refCount = refs.len - 1  # Subtract 1 for the definition itself

                      if refCount >= 0:
                        lenses.add create(CodeLens,
                          create(Range,
                            create(Position, sym.line-1, sym.column),
                            create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len)
                          ),
                          some(create(Command,
                            if refCount == 1: "1 reference" else: $refCount & " references",
                            "nimlsp.showReferences",
                            some(@[%fileuri, %sym.line, %sym.column])
                          )),
                          none(JsonNode)
                        ).JsonNode

                await outs.respond(message, lenses)

          of "workspace/symbol":
            # Search for symbols across the workspace
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, WorkspaceSymbolParams):
                let query = params["query"].getStr.toLowerAscii
                debugLog "Workspace symbol search for: ", query

                var symbols = newJarray()
                # Search through all open project files
                for projectFile, projectData in projectFiles:
                  let syms = projectData.nimsuggest.outline(projectFile, dirtyfile = "")
                  for sym in syms:
                    if sym.qualifiedPath.len >= 2:
                      let symName = sym.qualifiedPath[^1].toLowerAscii
                      if query.len == 0 or symName.contains(query):
                        symbols.add create(SymbolInformation,
                          sym.name[],
                          nimSymToLSPKind(sym.symKind).int,
                          some(false),
                          create(Location,
                            "file://" & pathToUri(sym.filepath),
                            create(Range,
                              create(Position, sym.line-1, sym.column),
                              create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len)
                            )
                          ),
                          if sym.qualifiedPath.len > 2: some(sym.qualifiedPath[^2]) else: none(string)
                        ).JsonNode

                await outs.respond(message, symbols)

          of "workspace/executeCommand":
            # Execute custom commands
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, ExecuteCommandParams):
                let command = params["command"].getStr
                debugLog "Execute command: ", command

                case command:
                of "nimlsp.organizeImports":
                  # TODO: Implement import organization
                  await outs.respond(message, newJNull())
                of "nimlsp.restartServer":
                  # Clear all project files to force re-initialization
                  for projectFile in projectFiles.keys.toSeq:
                    projectFiles.del(projectFile)
                  await outs.respond(message, newJNull())
                else:
                  await outs.respond(message, newJNull())

          of "textDocument/formatting":
            # Format the entire document using nimpretty
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, DocumentFormattingParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                debugLog "Formatting document: ", fileuri

                # Read the current file content
                let originalContent = readFile(filestash)

                # Try to format with nimpretty
                let formattedPath = filestash & ".formatted"
                let nimprettyResult =
                  when defined(windows):
                    osproc.execCmdEx("nimpretty --output:" & formattedPath & " " & filestash)
                  else:
                    waitFor asyncproc.execProcess("nimpretty --output:" & formattedPath & " " & filestash, options = {asyncproc.poEvalCommand, asyncproc.poUsePath})

                var resp: JsonNode
                if fileExists(formattedPath):
                  let formattedContent = readFile(formattedPath)
                  removeFile(formattedPath)

                  if formattedContent != originalContent:
                    # Count lines in original
                    let lines = originalContent.splitLines()
                    resp = newJarray()
                    resp.add create(TextEdit,
                      create(Range,
                        create(Position, 0, 0),
                        create(Position, lines.len, 0)
                      ),
                      formattedContent
                    ).JsonNode
                  else:
                    resp = newJarray()
                else:
                  resp = newJarray()

                await outs.respond(message, resp)

          of "textDocument/rangeFormatting":
            # Format a range of the document
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, DocumentRangeFormattingParams):
                let fileuri = params["textDocument"]["uri"].getStr
                debugLog "Range formatting document: ", fileuri
                # nimpretty doesn't support range formatting, return empty
                await outs.respond(message, newJarray())

          of "textDocument/documentLink":
            # Provide clickable links for imports
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, DocumentLinkParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                debugLog "Document links for: ", fileuri

                var links = newJarray()

                # Read file and find import statements
                if fileExists(filestash):
                  let content = readFile(filestash)
                  var lineNum = 0
                  for line in content.splitLines():
                    let trimmed = line.strip()
                    if trimmed.startsWith("import ") or trimmed.startsWith("from "):
                      # Extract module name(s)
                      var startCol = line.find("import ")
                      if startCol == -1:
                        startCol = line.find("from ")
                        if startCol != -1:
                          startCol += 5
                      else:
                        startCol += 7

                      if startCol != -1:
                        let endCol = line.len
                        links.add create(DocumentLink,
                          create(Range,
                            create(Position, lineNum, startCol),
                            create(Position, lineNum, endCol)
                          ),
                          none(string),  # target will be resolved
                          some("Go to module"),
                          none(JsonNode)
                        ).JsonNode
                    lineNum += 1

                await outs.respond(message, links)

          of "textDocument/foldingRange":
            # Provide folding ranges
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, FoldingRangeParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                debugLog "Folding ranges for: ", fileuri

                var ranges = newJarray()

                # Get outline to find foldable regions
                let syms = getNimsuggest(fileuri).outline(uriToPath(fileuri), dirtyfile = filestash)

                # Sort symbols by line
                let sortedSyms = syms.sortedByIt(it.line)

                # Create folding ranges for each symbol
                for i, sym in sortedSyms:
                  if sym.qualifiedPath.len >= 2:
                    let symKind = sym.symKind.TSymKind
                    if symKind in {skProc, skFunc, skMethod, skType, skTemplate, skMacro, skIterator}:
                      # Find the end of this symbol (next symbol at same or lower depth, or EOF)
                      var endLine = sym.line
                      for j in (i+1)..<sortedSyms.len:
                        if sortedSyms[j].qualifiedPath.len <= sym.qualifiedPath.len:
                          endLine = sortedSyms[j].line - 2
                          break
                        endLine = sortedSyms[j].line

                      if endLine > sym.line:
                        ranges.add create(FoldingRange,
                          sym.line - 1,  # startLine (0-indexed)
                          none(int),
                          endLine - 1,   # endLine (0-indexed)
                          none(int),
                          none(string)   # kind
                        ).JsonNode

                # Also add import folding
                if fileExists(filestash):
                  let content = readFile(filestash)
                  var importStart = -1
                  var importEnd = -1
                  var lineNum = 0
                  for line in content.splitLines():
                    let trimmed = line.strip()
                    if trimmed.startsWith("import ") or trimmed.startsWith("from ") or
                       trimmed.startsWith("include ") or trimmed.startsWith("export "):
                      if importStart == -1:
                        importStart = lineNum
                      importEnd = lineNum
                    elif trimmed.len > 0 and importStart != -1 and not trimmed.startsWith("#"):
                      break
                    lineNum += 1

                  if importStart != -1 and importEnd > importStart:
                    ranges.add create(FoldingRange,
                      importStart,
                      none(int),
                      importEnd,
                      none(int),
                      some("imports")
                    ).JsonNode

                await outs.respond(message, ranges)

          of "textDocument/selectionRange":
            # Provide smart selection ranges
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, SelectionRangeParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                let positions = params["positions"]
                debugLog "Selection ranges for: ", fileuri

                var response = newJarray()

                # Read file content for line-based analysis
                if fileExists(filestash):
                  let content = readFile(filestash)
                  let lines = content.splitLines()

                  for pos in positions:
                    let line = pos["line"].getInt
                    let character = pos["character"].getInt

                    # Build nested selection ranges from smallest to largest
                    # Word -> Line -> Block -> Function -> File
                    var ranges: seq[JsonNode] = @[]

                    # Innermost: current word
                    if line < lines.len:
                      let lineText = lines[line]
                      var wordStart = character
                      var wordEnd = character

                      # Find word boundaries
                      while wordStart > 0 and lineText[wordStart-1].isAlphaNumeric:
                        dec wordStart
                      while wordEnd < lineText.len and lineText[wordEnd].isAlphaNumeric:
                        inc wordEnd

                      if wordEnd > wordStart:
                        ranges.add create(SelectionRange,
                          create(Range,
                            create(Position, line, wordStart),
                            create(Position, line, wordEnd)
                          ),
                          none(SelectionRange)
                        ).JsonNode

                    # Next: current line (non-whitespace)
                    if line < lines.len:
                      let lineText = lines[line]
                      let trimmedStart = lineText.len - lineText.strip(leading=true, trailing=false).len
                      let trimmedEnd = lineText.strip(trailing=true, leading=false).len
                      ranges.add create(SelectionRange,
                        create(Range,
                          create(Position, line, trimmedStart),
                          create(Position, line, trimmedEnd)
                        ),
                        none(SelectionRange)
                      ).JsonNode

                    # Next: full line including newline
                    ranges.add create(SelectionRange,
                      create(Range,
                        create(Position, line, 0),
                        create(Position, line + 1, 0)
                      ),
                      none(SelectionRange)
                    ).JsonNode

                    # Outermost: entire file
                    ranges.add create(SelectionRange,
                      create(Range,
                        create(Position, 0, 0),
                        create(Position, lines.len, 0)
                      ),
                      none(SelectionRange)
                    ).JsonNode

                    # Link them together (innermost to outermost)
                    if ranges.len > 0:
                      var result = ranges[^1]
                      for i in countdown(ranges.len - 2, 0):
                        var r = ranges[i]
                        r["parent"] = result
                        result = r
                      response.add result

                await outs.respond(message, response)

          of "textDocument/prepareCallHierarchy":
            # Prepare call hierarchy item
            message.textDocumentRequest(TextDocumentPositionParams, callHierarchyRequest):
              debugLog "Preparing call hierarchy for ", uriToPath(fileuri), ":",
                rawLine + 1, ":", openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)

              let suggestions = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1, openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar))

              var response = newJarray()
              if suggestions.len > 0:
                let suggestion = suggestions[0]
                let symKind = suggestion.symKind.TSymKind
                if symKind in {skProc, skFunc, skMethod, skTemplate, skMacro, skIterator}:
                  response.add create(CallHierarchyItem,
                    suggestion.qualifiedPath[^1],
                    nimSymToLSPKind(suggestion.symKind).int,
                    none(seq[int]),
                    some(suggestion.forth),
                    "file://" & pathToUri(suggestion.filepath),
                    create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    ),
                    create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    ),
                    some(%*{"filepath": suggestion.filepath, "line": suggestion.line, "column": suggestion.column})
                  ).JsonNode

              if response.len == 0:
                await outs.respond(message, newJNull())
              else:
                await outs.respond(message, response)

          of "callHierarchy/incomingCalls":
            # Get incoming calls (who calls this function)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, CallHierarchyIncomingCallsParams):
                let item = params["item"]
                let uri = item["uri"].getStr
                let data = item["data"]
                debugLog "Getting incoming calls for: ", item["name"].getStr

                var response = newJarray()

                if data.kind == JObject and "filepath" in data and "line" in data and "column" in data:
                  let filepath = data["filepath"].getStr
                  let line = data["line"].getInt
                  let column = data["column"].getInt

                  # Get all usages
                  for projectFile, projectData in projectFiles:
                    if openFiles.len > 0:
                      let firstFile = openFiles.keys.toSeq[0]
                      let refs = projectData.nimsuggest.use(filepath, dirtyfile = "", line, column)

                      for r in refs:
                        if r.section == ideUse:  # Only usages, not definition
                          # Get the containing function for this usage
                          let containerDefs = projectData.nimsuggest.def(r.filepath, dirtyfile = "", r.line, 0)
                          if containerDefs.len > 0:
                            let container = containerDefs[0]
                            let containerKind = container.symKind.TSymKind
                            if containerKind in {skProc, skFunc, skMethod, skTemplate, skMacro, skIterator}:
                              response.add create(CallHierarchyIncomingCall,
                                create(CallHierarchyItem,
                                  container.qualifiedPath[^1],
                                  nimSymToLSPKind(container.symKind).int,
                                  none(seq[int]),
                                  some(container.forth),
                                  "file://" & pathToUri(container.filepath),
                                  create(Range,
                                    create(Position, container.line-1, container.column),
                                    create(Position, container.line-1, container.column + container.qualifiedPath[^1].len)
                                  ),
                                  create(Range,
                                    create(Position, container.line-1, container.column),
                                    create(Position, container.line-1, container.column + container.qualifiedPath[^1].len)
                                  ),
                                  some(%*{"filepath": container.filepath, "line": container.line, "column": container.column})
                                ),
                                @[create(Range,
                                  create(Position, r.line-1, r.column),
                                  create(Position, r.line-1, r.column + r.qualifiedPath[^1].len)
                                )]
                              ).JsonNode

                await outs.respond(message, response)

          of "callHierarchy/outgoingCalls":
            # Get outgoing calls (what does this function call)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, CallHierarchyOutgoingCallsParams):
                let item = params["item"]
                debugLog "Getting outgoing calls for: ", item["name"].getStr

                # Outgoing calls require parsing the function body, which is complex
                # Return empty for now - this would need AST analysis
                await outs.respond(message, newJarray())

          of "textDocument/prepareTypeHierarchy":
            # Prepare type hierarchy item
            message.textDocumentRequest(TextDocumentPositionParams, typeHierarchyRequest):
              debugLog "Preparing type hierarchy for ", uriToPath(fileuri), ":",
                rawLine + 1, ":", openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar)

              let suggestions = getNimsuggest(fileuri).def(uriToPath(fileuri), dirtyfile = filestash,
                rawLine + 1, openFiles[fileuri].fingerTable[rawLine].utf16to8(rawChar))

              var response = newJarray()
              if suggestions.len > 0:
                let suggestion = suggestions[0]
                let symKind = suggestion.symKind.TSymKind
                if symKind == skType:
                  response.add create(TypeHierarchyItem,
                    suggestion.qualifiedPath[^1],
                    SymbolKind.Class.int,
                    none(seq[int]),
                    some(suggestion.forth),
                    "file://" & pathToUri(suggestion.filepath),
                    create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    ),
                    create(Range,
                      create(Position, suggestion.line-1, suggestion.column),
                      create(Position, suggestion.line-1, suggestion.column + suggestion.qualifiedPath[^1].len)
                    ),
                    some(%*{"filepath": suggestion.filepath, "line": suggestion.line, "column": suggestion.column, "forth": suggestion.forth})
                  ).JsonNode

              if response.len == 0:
                await outs.respond(message, newJNull())
              else:
                await outs.respond(message, response)

          of "typeHierarchy/supertypes":
            # Get supertypes (parent types)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, TypeHierarchySupertypesParams):
                let item = params["item"]
                let data = item["data"]
                debugLog "Getting supertypes for: ", item["name"].getStr

                var response = newJarray()

                # Parse the type definition to find "of BaseType"
                if data.kind == JObject and "forth" in data:
                  let forth = data["forth"].getStr
                  # Look for "object of X" pattern
                  if "of " in forth:
                    let parts = forth.split("of ")
                    if parts.len > 1:
                      let parentTypeName = parts[1].split(" ")[0].strip()
                      # Try to find the parent type definition
                      for projectFile, projectData in projectFiles:
                        let syms = projectData.nimsuggest.outline(projectFile, dirtyfile = "")
                        for sym in syms:
                          if sym.qualifiedPath.len >= 2 and sym.qualifiedPath[^1] == parentTypeName:
                            let symKind = sym.symKind.TSymKind
                            if symKind == skType:
                              response.add create(TypeHierarchyItem,
                                sym.qualifiedPath[^1],
                                SymbolKind.Class.int,
                                none(seq[int]),
                                some(sym.forth),
                                "file://" & pathToUri(sym.filepath),
                                create(Range,
                                  create(Position, sym.line-1, sym.column),
                                  create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len)
                                ),
                                create(Range,
                                  create(Position, sym.line-1, sym.column),
                                  create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len)
                                ),
                                some(%*{"filepath": sym.filepath, "line": sym.line, "column": sym.column, "forth": sym.forth})
                              ).JsonNode
                              break

                await outs.respond(message, response)

          of "typeHierarchy/subtypes":
            # Get subtypes (child types)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, TypeHierarchySubtypesParams):
                let item = params["item"]
                let typeName = item["name"].getStr
                debugLog "Getting subtypes for: ", typeName

                var response = newJarray()

                # Search for types that inherit from this type
                for projectFile, projectData in projectFiles:
                  let syms = projectData.nimsuggest.outline(projectFile, dirtyfile = "")
                  for sym in syms:
                    if sym.qualifiedPath.len >= 2:
                      let symKind = sym.symKind.TSymKind
                      if symKind == skType:
                        # Check if this type inherits from our type
                        if ("of " & typeName) in sym.forth or ("of  " & typeName) in sym.forth:
                          response.add create(TypeHierarchyItem,
                            sym.qualifiedPath[^1],
                            SymbolKind.Class.int,
                            none(seq[int]),
                            some(sym.forth),
                            "file://" & pathToUri(sym.filepath),
                            create(Range,
                              create(Position, sym.line-1, sym.column),
                              create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len)
                            ),
                            create(Range,
                              create(Position, sym.line-1, sym.column),
                              create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len)
                            ),
                            some(%*{"filepath": sym.filepath, "line": sym.line, "column": sym.column, "forth": sym.forth})
                          ).JsonNode

                await outs.respond(message, response)

          of "textDocument/inlayHint":
            # Provide inlay hints (type hints, parameter names)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, InlayHintParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                let rangeStart = params["range"]["start"]["line"].getInt
                let rangeEnd = params["range"]["end"]["line"].getInt
                debugLog "Inlay hints for: ", fileuri, " lines ", rangeStart, "-", rangeEnd

                var hints = newJarray()

                # Get outline to find variable declarations without explicit types
                let syms = getNimsuggest(fileuri).outline(uriToPath(fileuri), dirtyfile = filestash)

                for sym in syms:
                  if sym.line >= rangeStart + 1 and sym.line <= rangeEnd + 1:
                    let symKind = sym.symKind.TSymKind
                    # Add type hints for variables
                    if symKind in {skVar, skLet, skConst, skParam, skForVar}:
                      if sym.forth.len > 0 and sym.forth != "":
                        # Type hint after variable name
                        hints.add create(InlayHint,
                          create(Position, sym.line-1, sym.column + sym.qualifiedPath[^1].len),
                          ": " & sym.forth,
                          some(InlayHintKind.Type.int),
                          none(seq[TextEdit]),
                          some(sym.forth),
                          some(false),
                          some(true),
                          none(JsonNode)
                        ).JsonNode

                await outs.respond(message, hints)

          of "textDocument/semanticTokens/full":
            # Provide semantic tokens for syntax highlighting
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, SemanticTokensParams):
                let fileuri = params["textDocument"]["uri"].getStr
                let filestash = storage / (hash(fileuri).toHex & ".nim")
                debugLog "Semantic tokens for: ", fileuri

                # Get all known symbols
                let known = getNimsuggest(fileuri).known(uriToPath(fileuri), dirtyfile = filestash)

                # Sort by line, then column
                let sortedKnown = known.sortedByIt((it.line, it.column))

                # Build semantic tokens data
                # Format: [deltaLine, deltaStartChar, length, tokenType, tokenModifiers]
                var data: seq[int] = @[]
                var prevLine = 0
                var prevChar = 0

                for sym in sortedKnown:
                  let line = sym.line - 1
                  let col = sym.column
                  let length = sym.qualifiedPath[^1].len

                  # Calculate deltas
                  let deltaLine = line - prevLine
                  let deltaChar = if deltaLine == 0: col - prevChar else: col

                  # Map symbol kind to semantic token type
                  let tokenType = case sym.symKind.TSymKind:
                    of skType: 1  # type
                    of skProc, skFunc: 12  # function
                    of skMethod: 13  # method
                    of skVar, skLet, skForVar: 8  # variable
                    of skConst: 8  # variable (readonly)
                    of skParam: 7  # parameter
                    of skEnumField: 10  # enumMember
                    of skMacro: 14  # macro
                    of skTemplate: 12  # function
                    of skIterator: 12  # function
                    else: 8  # variable

                  # Token modifiers (bitfield)
                  let tokenModifiers = case sym.symKind.TSymKind:
                    of skConst: 4  # readonly
                    of skType: 1  # declaration
                    else: 0

                  data.add deltaLine
                  data.add deltaChar
                  data.add length
                  data.add tokenType
                  data.add tokenModifiers

                  prevLine = line
                  prevChar = col

                let resp = create(SemanticTokens,
                  none(string),
                  data
                ).JsonNode
                await outs.respond(message, resp)

          # ============= END NEW FEATURES =============

          else:
            debugLog "Unknown request"
            await outs.error(message, InvalidRequest, "Unknown request: " & frame, newJObject())
        continue
      whenValidStrict(message, NotificationMessage):
        debugLog "Got valid Notification message of type ", message["method"].getStr
        if not initialized and message["method"].getStr != "exit":
          continue
        case message["method"].getStr:
          of "exit":
            debugLog "Exiting"
            if gotShutdown:
              quit 0
            else:
              quit 1
          of "initialized":
            debugLog "Properly initialized"
          of "textDocument/didOpen":
            message.textDocumentNotification(DidOpenTextDocumentParams, textDoc):
              let
                file = open(filestash, fmWrite)
                projectFile = getProjectFile(uriToPath(fileuri))
              debugLog "New document opened for URI: ", fileuri, " saving to ", filestash
              openFiles[fileuri] = (
                #nimsuggest: initNimsuggest(uriToPath(fileuri)),
                projectFile: projectFile,
                fingerTable: @[]
              )

              if projectFile notin projectFiles:
                debugLog "Initialising project with ", projectFile, ":", nimpath
                projectFiles[projectFile] = (nimsuggest: initNimsuggest(projectFile, nimpath), openFiles: initOrderedSet[string](), dirtyFiles: initHashSet[string]())
              projectFiles[projectFile].openFiles.incl(fileuri)
              projectFiles[projectFile].dirtyFiles.incl(filestash)

              for line in textDoc["textDocument"]["text"].getStr.splitLines:
                openFiles[fileuri].fingerTable.add line.createUTFMapping()
                file.writeLine line
              file.close()
          of "textDocument/didChange":
            message.textDocumentNotification(DidChangeTextDocumentParams, textDoc):
              let file = open(filestash, fmWrite)
              debugLog "Got document change for URI: ", fileuri, " saving to ", filestash
              openFiles[fileuri].fingerTable = @[]
              for line in textDoc["contentChanges"][0]["text"].getStr.splitLines:
                openFiles[fileuri].fingerTable.add line.createUTFMapping()
                file.writeLine line
              file.close()
              projectFiles[openFiles[fileuri].projectFile].dirtyFiles.incl(filestash)

              # Invalidate cache for this file
              invalidateCache(fileuri)

              # Notify nimsuggest about a file modification.
              discard getNimsuggest(fileuri).mod(uriToPath(fileuri), dirtyfile = filestash)
          of "textDocument/didClose":
            message.textDocumentNotification(DidCloseTextDocumentParams, textDoc):
              let projectFile = getProjectFile(uriToPath(fileuri))
              debugLog "Got document close for URI: ", fileuri, " copied to ", filestash
              projectFiles[projectFile].openFiles.excl(fileuri)
              if projectFiles[projectFile].openFiles.len == 0:
                debugLog "No more open files for project ", projectFile
                debugLog "Cleaning up dirty files"
                for dirtyfile in projectFiles[openFiles[fileuri].projectFile].dirtyFiles:
                  removeFile(dirtyfile)
                debugLog "Deleting context"
                projectFiles.del(projectFile)
              openFiles.del(fileuri)
          of "textDocument/didSave":
            message.textDocumentNotification(DidSaveTextDocumentParams, textDoc):
              if textDoc["text"].isSome:
                let file = open(filestash, fmWrite)
                debugLog "Got document save for URI: ", fileuri, " saving to ", filestash
                openFiles[fileuri].fingerTable = @[]
                for line in textDoc["text"].unsafeGet.getStr.splitLines:
                  openFiles[fileuri].fingerTable.add line.createUTFMapping()
                  file.writeLine line
                file.close()
                projectFiles[openFiles[fileuri].projectFile].dirtyFiles.incl(filestash)
              debugLog "fileuri: ", fileuri, ", project file: ", openFiles[fileuri].projectFile, ", dirtyfile: ", filestash

              let diagnosticResults = getNimsuggest(fileuri).chk(uriToPath(fileuri), dirtyfile = filestash)
              debugLog "Got diagnostics: ",
                diagnosticResults[0..<min(diagnosticResults.len, 10)],
                if diagnosticResults.len > 10: &" and {diagnosticResults.len-10} more" else: ""
              var response: seq[Diagnostic]
              for diagnostic in diagnosticResults:
                if diagnostic.line == 0:
                  continue

                if diagnostic.filePath != uriToPath(fileuri):
                  continue
                # Use helper to create diagnostic with proper tags
                response.add createDiagnosticFromSuggest(diagnostic)

              # Invoke chk on all open files.
              let projectFile = openFiles[fileuri].projectFile
              for f in projectFiles[projectFile].openFiles.items:
                let fileDiagnostics = getNimsuggest(f).chk(uriToPath(f), dirtyfile = getFileStash(f))
                debugLog "Got diagnostics: ",
                  fileDiagnostics[0..<min(fileDiagnostics.len, 10)],
                  if fileDiagnostics.len > 10: &" and {fileDiagnostics.len-10} more" else: ""

                var fileResponse: seq[Diagnostic]
                for diagnostic in fileDiagnostics:
                  if diagnostic.line == 0:
                    continue

                  if diagnostic.filePath != uriToPath(f):
                    continue
                  # Use helper to create diagnostic with proper tags
                  fileResponse.add createDiagnosticFromSuggest(diagnostic)
                let fileResp = create(PublishDiagnosticsParams, f, fileResponse).JsonNode
                await outs.notify("textDocument/publishDiagnostics", fileResp)
              let resp = create(PublishDiagnosticsParams,
                fileuri,
                response).JsonNode
              await outs.notify("textDocument/publishDiagnostics", resp)

          of "workspace/didChangeConfiguration":
            # Handle configuration changes
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, DidChangeConfigurationParams):
                debugLog "Got configuration change"
                # Configuration is handled - could be used for nimlsp settings
                # For now, just acknowledge it

          of "workspace/didChangeWatchedFiles":
            # Handle file system changes
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, DidChangeWatchedFilesParams):
                let changes = params["changes"]
                debugLog "Got file change notifications: ", changes.len
                for change in changes:
                  let uri = change["uri"].getStr
                  let changeType = change["type"].getInt
                  debugLog "File ", uri, " changed with type ", changeType
                  # FileChangeType: Created = 1, Changed = 2, Deleted = 3
                  case changeType:
                  of 1:  # Created
                    debugLog "File created: ", uri
                  of 2:  # Changed
                    debugLog "File changed: ", uri
                    # Could trigger re-indexing here
                  of 3:  # Deleted
                    debugLog "File deleted: ", uri
                    # Clean up any cached data for this file
                  else:
                    discard

          of "$/cancelRequest":
            # Handle request cancellation (LSP protocol)
            if message["params"].isSome:
              let params = message["params"].unsafeGet
              whenValid(params, CancelParams):
                debugLog "Got cancel request for id: ", params["id"]
                # We don't currently support cancellation, but acknowledge it

          else:
            warnLog "Got unknown notification message"
        continue
    except UriParseError as e:
      warnLog "Got exception parsing URI: ", e.msg
      continue
    except IOError as e:
      errorLog "Got IOError: ", e.msg
      break
    except CatchableError as e:
      warnLog "Got exception: ", e.msg
      continue

when defined(windows):
  var
    ins = newFileStream(stdin)
    outs = newFileStream(stdout)
  main(ins, outs)
else:
  var
    ins = newAsyncFile(stdin.getOsFileHandle().AsyncFD)
    outs = newAsyncFile(stdout.getOsFileHandle().AsyncFD)
  waitFor main(ins, outs)
