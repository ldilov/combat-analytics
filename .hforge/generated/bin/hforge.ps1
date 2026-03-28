param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

npx @harness-forge/cli @Args
