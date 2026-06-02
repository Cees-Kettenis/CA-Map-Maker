# Agent Guidelines

This repository is an Elixir / Phoenix application.

## General Rules

- Follow standard Elixir and Phoenix conventions.
- Do not introduce breaking changes without updating tests.
- Keep code idiomatic and readable.
- Before adding a new helper, first check whether equivalent functionality already exists in `lib/sigportal/utils` or another shared module, and reuse it instead of creating a local private function.
- Do not create `defp` functions for one-off logic, trivial wrappers, or to “organize” code without a clear benefit.
- Only create a `defp` when it provides a clear improvement, such as:
  - reducing real code duplication,
  - simplifying a genuinely complex function,
  - naming a non-obvious business rule that improves readability.
- Prefer inline code over extracting a `defp` when the extracted function is used only once and does not make the calling code easier to understand.
- Do not duplicate existing helpers for common concerns such as number parsing, date formatting, string cleanup, or similar utility behavior already handled in shared modules.

## Documentation

- All public-facing functions must include `@doc` and `@spec`.
- Controllers and public endpoints must include Swagger/OpenAPI definitions.

## Quality Gates

All changes must pass the following commands so execute them:

- `mise exec -- mix test`
- `MIX_ENV=test mise exec -- mix dialyzer`
- `mise exec -- mix format`

If warnings or errors are introduced, they must be resolved before considering the work complete.

## Scope Discipline

- Prefer small, focused changes.
- Do not implement multiple unrelated features in one change.

# Forbidden style:

```
def some_fun(_), do: nil

def some_fun(value) when is_binary(value) do
  something(value)
end
```

Preferred style:

```
@doc "Explains what the function does."
@spec some_fun(term()) :: result_type()
def some_fun(value) do
  case value do
    value when is_binary(value) ->
      something(value)

    _ ->
      nil
  end
end
```

Use case/cond/with or clearly named private functions instead of hidden branching through guarded function heads.
