/-
Copyright (c) 2023 Kyle Miller. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Kyle Miller
-/
import Lean

/-! `#guard_msgs` command for testing commands

This module defines a command to test that another command produces the expected messages.
See the docstring on the `#guard_msgs` command.
-/

open Lean Parser.Tactic Elab Command

namespace Std.Tactic.GuardMsgs

/-- Element that can be part of a `#guard_msgs` specification. -/
syntax guardMsgsSpecElt := &"drop"? (&"info" <|> &"warning" <|> &"error" <|> &"all")

/-- Specification for `#guard_msgs` command. -/
syntax guardMsgsSpec := "(" guardMsgsSpecElt,* ")"

/--
`#guard_msgs` captures the messages generated by another command and checks that they
match the contents of the docstring attached to the `#guard_msgs` command.

Basic example:
```lean
/--
error: unknown identifier 'x'
-/
#guard_msgs in
example : α := x
```
This checks that there is such an error and then consumes the message entirely.

By default, the command intercepts all messages, but there is a way to specify which types
of messages to consider. For example, we can select only warnings:
```lean
/--
warning: declaration uses 'sorry'
-/
#guard_msgs(warning) in
example : α := sorry
```
or only errors
```lean
#guard_msgs(error) in
example : α := sorry
```
In this last example, since the message is not intercepted there is a warning on `sorry`.
We can drop the warning completely with
```lean
#guard_msgs(error, drop warning) in
example : α := sorry
```

Syntax description:
```
#guard_msgs (drop? info|warning|error|all,*)? in cmd
```

If there is no specification, `#guard_msgs` intercepts all messages.
Otherwise, if there is one, the specification is considered in left-to-right order, and the first
that applies chooses the outcome of the message:
- `info`, `warning`, `error`: intercept a message with the given severity level.
- `all`: intercept any message (so `#guard_msgs in cmd` and `#guard_msgs (all) in cmd`
  are equivalent).
- `drop info`, `drop warning`, `drop error`: intercept a message with the given severity
  level and then drop it. These messages are not checked.
- `drop all`: intercept a message and drop it.

For example, `#guard_msgs (error, drop all) in cmd` means to check warnings and then drop
everything else.
-/
syntax (name := guardMsgsCmd)
  docComment ? "#guard_msgs" (ppSpace guardMsgsSpec)? " in" ppLine command : command

/-- Gives a string representation of a message without source position information.
Ensures the message ends with a '\n'. -/
private def messageToStringWithoutPos (msg : Message) : IO String := do
  let mut str ← msg.data.toString
  unless msg.caption == "" do
    str := msg.caption ++ ":\n" ++ str
  match msg.severity with
  | MessageSeverity.information => str := "info: " ++ str
  | MessageSeverity.warning     => str := "warning: " ++ str
  | MessageSeverity.error       => str := "error: " ++ str
  if str.isEmpty || str.back != '\n' then
    str := str ++ "\n"
  return str

/-- The decision made by a specification for a message. -/
inductive SpecResult
  /-- Capture the message and check it matches the docstring. -/
  | check
  /-- Drop the message and delete it. -/
  | drop
  /-- Do not capture the message. -/
  | passthrough

/-- Parses a `guardMsgsSpec`.
- No specification: check everything.
- With a specification: interpret the spec, and if nothing applies pass it through. -/
def parseGuardMsgsSpec (spec? : Option (TSyntax ``guardMsgsSpec)) :
    CommandElabM (Message → SpecResult) := do
  if let some spec := spec? then
    match spec with
    | `(guardMsgsSpec| ($[$elts:guardMsgsSpecElt],*)) => do
      let mut p : Message → SpecResult := fun _ => .passthrough
      let pushP (s : MessageSeverity) (drop : Bool) (p : Message → SpecResult)
          (msg : Message) : SpecResult :=
        if msg.severity == s then if drop then .drop else .check
        else p msg
      for elt in elts.reverse do
        match elt with
        | `(guardMsgsSpecElt| $[drop%$drop?]? info)    => p := pushP .information drop?.isSome p
        | `(guardMsgsSpecElt| $[drop%$drop?]? warning) => p := pushP .warning drop?.isSome p
        | `(guardMsgsSpecElt| $[drop%$drop?]? error)   => p := pushP .error drop?.isSome p
        | `(guardMsgsSpecElt| $[drop%$drop?]? all) =>
          p := fun _ => if drop?.isSome then .drop else .check
        | _ => throwErrorAt elt "Invalid #guard_msgs specification element"
      return p
    | _ => throwErrorAt spec "Invalid #guard_msgs specification"
  else
    return fun _ => .check

@[inherit_doc guardMsgsCmd, command_elab guardMsgsCmd]
def evalGuardMsgsCmd : CommandElab
  | `(command| $[$dc?:docComment]? #guard_msgs%$tk $[$spec?]? in $cmd) => do
    let expected : String := (← dc?.mapM (getDocStringText ·)).getD ""
    let specFn ← parseGuardMsgsSpec spec?
    let initMsgs ← modifyGet fun st => (st.messages, { st with messages := {} })
    elabCommand cmd
    let msgs := (← get).messages
    let mut toCheck : MessageLog := .empty
    let mut toPassthrough : MessageLog := .empty
    for msg in msgs.toList do
      match specFn msg with
      | .check       => toCheck := toCheck.add msg
      | .drop        => pure ()
      | .passthrough => toPassthrough := toPassthrough.add msg
    let res := String.intercalate "---\n" (← toCheck.toList.mapM (messageToStringWithoutPos ·))
    if expected.trim == res.trim then
      -- Passed. Only put toPassthrough messages back on the message log
      modify fun st => {st with messages := initMsgs ++ toPassthrough}
    else
      -- Failed. Put all the messages back on the message log and add an error
      modify fun st => {st with messages := initMsgs ++ msgs}
      logErrorAt tk
        m!"❌ Docstring on `#guard_msgs` does not match generated message:\n\n{res.trim}"
  | _ => throwUnsupportedSyntax
