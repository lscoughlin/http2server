# ast-grep MCP server for the Pascal sources.
#
# Run through .mcp.json (server name `ast-grep`):
#
#   uv run --project tools/ast-grep-mcp tools/ast-grep-mcp/main.py --config sgconfig.yml
#
# The server shells out to the `ast-grep` CLI. The wrapper resolves every
# path against the repository root (the parent of the directory that holds
# this project), so MCP clients work whatever their own working directory
# is. Every invocation passes `--custom-languages allow`: the Pascal grammar
# is a native library, and ast-grep skips it without the opt-in.
