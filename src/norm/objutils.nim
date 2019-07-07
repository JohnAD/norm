import strutils, macros

import pragmas


type
  PragmaKind* = enum
    ## There are two kinds of pragmas: flags and key-value pairs:

    pkFlag, pkKval

  PragmaRepr* = object
    ##[ A container for pragma definition components.

    For flag pragmas, only the pragma name is stored. For key-value pragmas,
    name and value are stored.
    ]##

    name*: string
    case kind*: PragmaKind
    of pkFlag: discard
    of pkKval: value*: NimNode

  SignatureRepr* = object
    ##[ Representation of the part of an object or field definition that contains:
      - name
      - exported flag
      - pragmas

    .. code-block::
        type
        # Object signature is parsed from this part:
        # |                        |
          Example {.pr1, pr2: val2.} = object

          # Field signature is parsed from this part:
          # |                       |
            field1 {.pr3, pr4: val4.}: int
    ]##

    name*: string
    exported*: bool
    pragmas*: seq[PragmaRepr]

  FieldRepr* = object
    ## Object field representation: signature + type.

    signature*: SignatureRepr
    typ*: NimNode

  ObjRepr* = object
    ## Object representation: signature + fields.

    signature*: SignatureRepr
    fields*: seq[FieldRepr]

proc toPragmaReprs(pragmaDefs: NimNode): seq[PragmaRepr] =
  ## Convert an ``nnkPragma`` node into a sequence of ``PragmaRepr`s.

  expectKind(pragmaDefs, nnkPragma)

  for pragmaDef in pragmaDefs:
    result.add case pragmaDef.kind
      of nnkIdent: PragmaRepr(kind: pkFlag, name: $pragmaDef)
      of nnkExprColonExpr: PragmaRepr(kind: pkKval, name: $pragmaDef[0], value: pragmaDef[1])
      else: PragmaRepr()

proc toSignatureRepr(def: NimNode): SignatureRepr =
  ## Convert a signature definition into a ``SignatureRepr``.

  expectKind(def[0], {nnkIdent, nnkPostfix, nnkPragmaExpr, nnkSym})

  case def[0].kind
    of nnkIdent:
      result.name = $def[0]
    of nnkPostfix:
      result.name = $def[0][1]
      result.exported = true
    of nnkPragmaExpr:
      expectKind(def[0][0], {nnkIdent, nnkSym, nnkPostfix})
      case def[0][0].kind
      of nnkIdent:
        result.name = $def[0][0]
      of nnkSym:
        result.name = $def[0][0]
      of nnkPostfix:
        result.name = $def[0][0][1]
        result.exported = true
      else: discard
      result.pragmas = def[0][1].toPragmaReprs()
    of nnkSym:
      result.name = $def[0]
    else: discard

proc toObjRepr*(typeDef: NimNode): ObjRepr =
  ## Convert an object type definition into an ``ObjRepr``.

  runnableExamples:
    import macros

    macro inspect(body: untyped): untyped =
      expectKind(body[0], nnkTypeSection)

      let
        typeSection = body[0]
        typeDef = typeSection[0]
        objRepr = typeDef.toObjRepr()

      doAssert objRepr.signature.name == "Example"

      doAssert len(objRepr.fields) == 1
      doAssert objRepr.fields[0].signature.name == "field"
      doAssert objRepr.fields[0].signature.exported
      doAssert $objRepr.fields[0].typ == "int"

    inspect:
      type
        Example = object
          field*: int

  result.signature = toSignatureRepr(typeDef)

  expectKind(typeDef[2], nnkObjectTy)

  for fieldDef in typeDef[2][2]:
    var field = FieldRepr()
    field.signature = toSignatureRepr(fieldDef)
    field.typ = fieldDef[1]
    result.fields.add field

proc toSignatureDef(signature: SignatureRepr): NimNode =
  ## Convert a ``SignatureRepr`` into a signature definition.

  let title =
    if not signature.exported: ident signature.name
    else: newNimNode(nnkPostfix).add(ident"*", ident signature.name)

  if signature.pragmas.len == 0:
    return title
  else:
    var pragmas = newNimNode(nnkPragma)

    for prag in signature.pragmas:
      pragmas.add case prag.kind
      of pkFlag: ident prag.name
      of pkKval: newColonExpr(ident prag.name, prag.value)

    result = newNimNode(nnkPragmaExpr).add(title, pragmas)

proc toTypeDef*(obj: ObjRepr): NimNode =
  ## Convert an ``ObjRepr`` into an object type definition.

  runnableExamples:
    import macros

    macro inspect(body: untyped): untyped =
      expectKind(body[0], nnkTypeSection)

      let
        typeSection = body[0]
        typeDef = typeSection[0]

      doAssert typeDef.toObjRepr().toTypeDef() == typeDef

    inspect:
      type
        Example = object
          field*: int

  var fieldDefs = newNimNode(nnkRecList)

  for field in obj.fields:
    fieldDefs.add newIdentDefs(field.signature.toSignatureDef(), field.typ)

  result = newNimNode(nnkTypeDef).add(
    obj.signature.toSignatureDef(),
    newEmptyNode(),
    newNimNode(nnkObjectTy).add(
      newEmptyNode(),
      newEmptyNode(),
      fieldDefs
    )
  )

proc getByName*[T: ObjRepr | FieldRepr](reprs: openArray[T], name: string): T =
  ## Get an ``ObjRepr`` or ``FieldRepr`` from an openArray by its name.

  for repr in reprs:
    if repr.signature.name == name:
      return repr

  raise newException(KeyError, "Repr with name $# not found." % name)

macro dot*(obj: object, fieldName: string): untyped =
  ## Access object field value by name: ``obj["field"]`` translates to ``obj.field``.

  runnableExamples:
    type
      Example = object
        field: int

    let example = Example(field: 123)

    doAssert example.dot("field") == example.field

  newDotExpr(obj, newIdentNode(fieldName.strVal))

macro dot*(obj: var object, fieldName: string, value: untyped): untyped =
  ## Set object field value by name: ``obj["field"] = value`` translates to ``obj.field = value``.

  runnableExamples:
    type
      Example = object
        field: int

    var example = Example()

    example.dot("field") = 321

    doAssert example.dot("field") == 321

  newAssignment(newDotExpr(obj, newIdentNode(fieldName.strVal)), value)

proc fieldNames*(objRepr: ObjRepr): seq[string] =
  ## Get object representation's field names as a sequence of strings.

  runnableExamples:
    import macros

    macro inspect(body: untyped): untyped =
      expectKind(body[0], nnkTypeSection)

      let
        typeSection = body[0]
        typeDef = typeSection[0]

      doAssert typeDef.toObjRepr().fieldNames == @["a", "b", "c"]

    inspect:
      type
        Example = object
          a: int
          b: float
          c: string

  for field in objRepr.fields:
    result.add field.signature.name

proc pragmaNames*(signRepr: SignatureRepr): seq[string] =
  ## Get signature representation's pragma names as a sequence of strings.

  runnableExamples:
    import macros

    macro inspect(body: untyped): untyped =
      expectKind(body[0], nnkTypeSection)

      let
        typeSection = body[0]
        typeDef = typeSection[0]

      doAssert typeDef.toObjRepr().signature.pragmaNames == @["a", "b"]
      doAssert typeDef.toObjRepr().fields[0].signature.pragmaNames == @["d", "f"]

    inspect:
      type
        Example {.a, b: "c".} = object
          a {.d: "e", f.}: int

  for prag in signRepr.pragmas:
    result.add prag.name
