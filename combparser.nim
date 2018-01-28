## This module is a slightly edited version of an original by kmizu:
## https://gist.github.com/kmizu/2b10c2bf0ab3eafecc1a825b892482f3
## The idea is to make this into a more user friendly library for
## creating parsers in Nim.
import strutils
import lists
import re
import macros
when defined(parserDebug):
  import termstyle
  var debug = 0

type
  Parser*[T] = proc(input: string): Maybe[(T, string)]
  ErrorNodeKind = enum Branch, Leaf, Stem
  Error = ref object
    case kind: ErrorNodeKind
      of Branch:
        left: Error
        right: Error
        branchError: string
      of Stem:
        stem: Error
        stemError: string
      of Leaf:
        leafError: string
    input: string
  Maybe*[T] = object
    value: T
    hasValue: bool
    errors: Error
  ParseError* = object of Exception

proc Just*[T](value: T): Maybe[T] =
  result.hasValue = true
  result.value = value
  result.errors = nil

proc Just*[T, U](old: Maybe[U], value: T): Maybe[T] =
  result.hasValue = true
  result.value = value
  result.errors = old.errors

proc Nothing*[T, U](old: Maybe[U], error: string, input: string): Maybe[T] =
  result.hasValue = false
  if old.errors == nil:
    result.errors = Error(kind: Leaf, leafError: error, input: input)
  else:
    result.errors = Error(kind: Stem, stem: old.errors, stemError: error, input: input)

proc Nothing*[T, U, V](left: Maybe[U], right: Maybe[V], error: string, input: string): Maybe[T] =
  result.hasValue = false
  if left.errors == nil and right.errors == nil:
    result.errors = Error(kind: Leaf, leafError: error, input: input)
  elif left.errors == nil:
    result.errors = Error(kind: Stem, stem: right.errors, stemError: error, input: input)
  elif right.errors == nil:
    result.errors = Error(kind: Stem, stem: left.errors, stemError: error, input: input)
  else:
    result.errors = Error(kind: Branch, left: left.errors, right: right.errors, branchError: error, input: input)


proc Nothing*[T, U](old: Maybe[U]): Maybe[T] =
  result.hasValue = false
  result.errors = old.errors

proc Nothing*[T](error: string, input: string): Maybe[T] =
  result.hasValue = false
  result.errors = Error(kind: Leaf, leafError: error, input: input)

proc Something*[T, U](ret: var Maybe[T], first: Maybe[U], error: string, input: string) =
  if first.errors == nil and ret.errors == nil:
    ret.errors = nil
  elif first.errors == nil:
    ret.errors = ret.errors
  elif ret.errors == nil:
    ret.errors = first.errors
  else:
    ret.errors = Error(kind: Branch, left: first.errors, right: ret.errors, branchError: error, input: input)

macro regex*(regexStr: string): Parser[string] =
  ## Returns a parser that returns the string matched by the regex
  let pos = lineInfo(callsite())
  result = quote do:
    (proc (input: string): Maybe[(string, string)] =
      let regex = re(`regexStr`)
      let (first, last) = findBounds(input, regex)
      if first == 0:
        when defined(parserDebug):
          echo red("Matched regex " & `regexStr` & " to " & input)
        Just((input[0 .. last], input[(last + 1) .. input.len]))
      else:
        when defined(parserDebug):
          echo red("Couldn't match regex " & `regexStr` & " to " & input)
        Nothing[(string, string)](`pos` & ": Couldn't match regex \"" & `regexStr` & "\"", input)
    )

macro s*(value: string): Parser[string] =
  ## Start with parser. Returns a parser that matches if the input starts
  ## with the given string.
  let pos = lineInfo(callsite())
  result = quote do:
    (proc (input: string): Maybe[(string, string)] =
      when defined(parserDebug):
        debug += 1
        let internalDebug = debug
        echo magenta($internalDebug & ": Checking if string \"" & input & "\" starts with " & `value`)
      if input.startsWith(`value`):
        when defined(parserDebug):
          echo magenta($internalDebug & ": String \"" & input & "\" started with " & `value`)
        Just ((input[0 .. (`value`.len - 1)], input[`value`.len .. input.len]))
      else:
        when defined(parserDebug):
          echo magenta($internalDebug & ": String \"" & input & "\" didn't start with " & `value`)
        Nothing[(string, string)](`pos` & ": Starts with operation failed: input did not start with \"" & `value` & "\"", input)
    )

proc repeat*[T](body: Parser[T], atLeast: int = 1): Parser[DoublyLinkedList[T]] =
  ## Returns a parser that returns a linked list of the input parsers type.
  ## Used to accept more multiple elements matching a pattern. If there is
  ## no match this will return an empty list and all the input as it's rest
  (proc (input: string): Maybe[(DoublyLinkedList[T], string)] =
    when defined(parserDebug):
      debug += 1
      let internalDebug = debug
      echo green($internalDebug & ": Trying to repeatedly match on " & input)
    var
      list = initDoublyLinkedList[T]()
      rest = input
      count = 0
    if input.len == 0 and atLeast == 0:
      return Just((list, rest))
    while true:
      let xresult = body(rest)
      if xresult.hasValue:
        let (xvalue, xnext) = xresult.value
        list.append(xvalue)
        rest = xnext
        count += 1
      else:
        when defined(parserDebug):
          echo green($internalDebug & ": Done repeatedly matching on " & input)
        if rest == input:
          var ret: Maybe[(DoublyLinkedList[T], string)]
          if atLeast == 0:
            ret = Just[(DoublyLinkedList[T], string)](xresult, (list, rest))
          else:
            ret = Nothing[(DoublyLinkedList[T], string)](xresult, "Repeat found zero matching elements", rest)
          return ret
        else:
          if count >= atLeast:
            return Just[(DoublyLinkedList[T], string)](xresult, (list, rest))
          else:
            return Nothing[(DoublyLinkedList[T], string)]("Not enough elements matched. Expected at least " & $atLeast & " but got only " & $count, rest)
    nil
  )

proc `/`*[T](lhs, rhs: Parser[T]): Parser[T] =
  ## Or operation. Takes two parser and returns a parser that will return
  ## the first matching parser.
  (proc (input: string): Maybe[(T, string)] =
    when defined(parserDebug):
      debug += 1
      let internalDebug = debug
      echo blue($internalDebug & ": Checking if either of two parsers match on " & input)
    let lresult = lhs(input)
    if lresult.hasValue:
      when defined(parserDebug):
        echo blue($internalDebug & ": First option matched on " & input)
      lresult
    else:
      when defined(parserDebug):
        echo blue($internalDebug & ": First option failed on " & input)
      let rresult = rhs(input)
      if rresult.hasValue:
        when defined(parserDebug):
          echo blue($internalDebug & ": Second option matched on " & input)
        rresult
      else:
        when defined(parserDebug):
          echo blue($internalDebug & ": Second option failed on " & input)
        Nothing[(T, string), (T, string)](lresult, rresult, "Either operation failed: Neither option matched", input)
  )

proc `+`*[T, U](lhs: Parser[T], rhs: Parser[U]): Parser[(T, U)] =
  ## And operation. Takes two parsers and returns a new parser with the tuple
  ## of the input parsers results. This only returns if both are true.
  (proc (input: string): Maybe[((T, U), string)] =
    when defined(parserDebug):
      debug += 1
      let internalDebug = debug
      echo yellow($internalDebug & ": Checking if both of two parsers match on " & input)
    let lresult = lhs(input)
    if lresult.hasValue:
      let (lvalue, lnext) = lresult.value
      let rresult = rhs(lnext)
      if rresult.hasValue:
        let (rvalue, rnext) = rresult.value
        when defined(parserDebug):
          echo yellow($internalDebug & ": Succesfully matched both on " & input)
        var ret = Just (((lvalue, rvalue), rnext))
        ret.errors = Error(kind: Branch, left: lresult.errors, right: rresult.errors)
        return ret
      else:
        when defined(parserDebug):
          echo yellow($internalDebug & ": Unable to match second on " & input)
        return Nothing[((T, U), string)](rresult, "Both operation failed: Unable to match second of two parsers", input)
    else:
      when defined(parserDebug):
        echo yellow($internalDebug & ": Unable to match first on " & input)
      return Nothing[((T, U), string)](lresult, "Both operation failed: Unable to match first of two parsers", input)
  )

proc map*[T, U](parser: Parser[T], f: (proc(value: T): U)): Parser[U] =
  ## Takes a parser and a function to converts it's type into another type and
  ## returns a parser that outputs the second type.
  (proc (input: string): Maybe[(U, string)] =
    when defined(parserDebug):
      debug += 1
      let internalDebug = debug
      echo cyan($internalDebug & ": Mapping a parser to another with input " & input)
    let xresult = parser(input)
    if xresult.hasValue:
      let (xvalue, xnext) = xresult.value
      when defined(parserDebug):
        echo cyan($internalDebug & ": Mapping succeded with input " & input)
      return Just[(U, string)](xresult,(f(xvalue), xnext))
    else:
      when defined(parserDebug):
        echo cyan($internalDebug & ": Mapping failed with input " & input)
      return Nothing[(U, string)](xresult, "Unable to map onto bad output", input)
  )

proc flatMap*[T, U](parser: Parser[T], f: (proc(value: T): Parser[U])): Parser[U] =
  ## Similar to map this takes a parser and a function to make a conversion. The difference
  ## is that while the above takes a converter from one type to another. This takes a converter
  ## from one type to a parser of another type.
  (proc (input: string): Maybe[(U, string)] =
    when defined(parserDebug):
      debug += 1
      let internalDebug = debug
      echo cyan($internalDebug & ": Flat-mapping a  parser to another with input " & input)
    let xresult = parser(input)
    if xresult.hasValue:
      let (xvalue, xnext) = xresult.value
      when defined(parserDebug):
        echo cyan($internalDebug & ": Flat-mapping succeded with input " & input)
      var ret = f(xvalue)(xnext)
      ret.errors = xresult.errors
      return ret
    else:
      when defined(parserDebug):
        echo cyan($internalDebug & ": Flat-mapping failed with input " & input)
      let ret = Nothing[(U, string)](xresult, "Unable to flat-map onto bad output", input)
      return ret
  )

proc chainl*[T](p: Parser[T], q: Parser[(proc(a: T, b: T): T)], allowEmpty = true): Parser[T] =
  (proc(input: string): Maybe[(T, string)] =
    let
      first = p(input)
      (firstVal, rest) = first.value
    if not first.hasValue:
      return Nothing[(T, string), (T, string)](first, "Chainl operation failed: First value not matching", input)
    if rest.len == 0:
      return first
    var ret = (q + p).repeat(if allowEmpty: 0 else: 1).map(proc(values: DoublyLinkedList[((proc(a: T, b: T): T), T)]): T =
      let xs = values
      var a = firstVal
      for fb in xs:
        let (f, b) = fb
        a = f(a, b)
      a)(rest)
    Something(ret, first, "Chainl operation", input)
    return ret
  )

template chainl1*[T](p: Parser[T], q: Parser[(proc(a: T, b: T): T)]): Parser[T] =
  chainl(p, q, false)

proc getError*[T](input: Maybe[T], original: string = nil): string =
  result = ""
  if input.errors != nil:
    proc buildError(res: var string, level: int, node: Error) =
      case node.kind:
        of Leaf:
          if original != nil:
            let
              pos = original.rfind(node.input)
              startStr = original[0..<pos]
              startLine = startStr[startStr.rfind("\n")+1..<startStr.len]
              endStr = node.input[0..<(node.input.find("\n"))]
              newLine = "  ".repeat(level) & node.leafError & " on input \""
            res = res & newLine & startLine & endStr & "\"\n"
            res = res & " ".repeat(newLine.len + startLine.len) & "^\n"
          else:
            res = res & "  ".repeat(level) & node.leafError & " on input \"" & node.input[0..<(node.input.find("\n"))] & "\"\n"
        of Stem:
          res = res & "  ".repeat(level) & node.stemError & " on input \"" & node.input[0..<(node.input.find("\n"))] & "\"\n"
          buildError(res, level + 1, node.stem)
        of Branch:
          res = res & "  ".repeat(level) & node.branchError & "\n"
          buildError(res, level + 1, node.left)
          buildError(res, level + 1, node.right)

    buildError(result, 0, input.errors)

proc parse*[T](parser: Parser[T], input: string): T =
  let res = parser(input)
  if res.hasValue:
    return res.value[0]
  else:
    raise newException(ParseError, "Unable to parse:\n" & getError(res, input).indent(2) & "\n")

when isMainModule:
  proc A(): Parser[int]

  proc M(): Parser[int]

  proc P(): Parser[int]

  proc number(): Parser[int]

  proc E(): Parser[int] = A()

  proc A(): Parser[int] = M().chainl1(
    (s("+").map(proc(_: string): (proc(lhs: int, rhs: int): int) =
      (proc(lhs: int, rhs: int): int = lhs + rhs))) /
    (s("-").map(proc(_: string): (proc(lhs: int, rhs: int): int) =
      (proc(lhs: int, rhs: int): int = lhs - rhs)))
  )

  proc M(): Parser[int] = P().chainl(
    (s("*").map(proc(_: string): (proc(lhs: int, rhs: int): int) =
      (proc(lhs: int, rhs: int): int = lhs * rhs))) /
    (s("/").map(proc(_: string): (proc(lhs: int, rhs: int): int) =
      (proc(lhs: int, rhs: int): int = lhs div rhs)))
  )

  proc P(): Parser[int] =
    regex(r"\s*\(\s*").flatMap(proc(_: string): Parser[int] =
      E().flatMap(proc(e: int): Parser[int] =
        regex(r"\s*\)\s*").map(proc(_: string): int =
          e))) / number()

  proc number(): Parser[int] = regex(r"\s*[0-9]+\s*").map(proc(n: string): int =
    parseInt(n.strip()))

  var res: Maybe[(int, string)]
  res = E()("( 1 + 2 )  *   ( 3 + 4 )  Hello world")
  if res.hasValue:
    echo res
  else:
    echo res.getError
  echo "-----------------------------------------"
  res = E()("( 1 + 2 )  *   ( 3 + 4 )")
  if res.hasValue:
    echo res
  else:
    echo res.getError
  echo "-----------------------------------------"
  res = E()("( 1 + 2 ) \n * \n ( 3 + 4 ")
  if res.hasValue:
    echo res
  else:
    echo res.getError("( 1 + 2 ) \n * \n ( 3 + 4 ")
  echo "-----------------------------------------"
  res = E()("1 +")
  if res.hasValue:
    echo res
  else:
    echo res.getError
  echo "-----------------------------------------"
  echo parse(E(), "1 + 5")
  echo "-----------------------------------------"
  echo parse(E(), "1 + ")
