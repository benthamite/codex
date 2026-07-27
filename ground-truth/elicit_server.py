"""Minimal MCP server whose only tool asks the user a question.

Exists to make `mcpServer/elicitation/request` actually happen, so its
behavior can be captured before codex-app-server.el implements it. No
configured MCP server elicits input during an ordinary turn, and an
unhandled elicitation stalls the turn with nothing shown, so the method
cannot be verified without a server that provokes it.

Register it with the CLI under test, then ask Codex to call the tool:

    codex mcp add elicit-probe -- python3 <this file>
    CGT_TRACE=1 python3 capture_protocol.py "Call the ask_colour tool."

Remove it afterwards:

    codex mcp remove elicit-probe

Requires the `mcp` package.
"""
from mcp.server.fastmcp import Context, FastMCP
from pydantic import BaseModel, Field

mcp = FastMCP("elicit-probe")


class Colour(BaseModel):
    """Schema the client is asked to fill in."""

    colour: str = Field(description="Any colour name")


@mcp.tool()
async def ask_colour(ctx: Context) -> str:
    """Ask the user for a colour and report what they answered."""
    result = await ctx.elicit(message="Pick a colour", schema=Colour)
    if result.action == "accept" and result.data:
        return f"user chose {result.data.colour}"
    return f"user did not answer ({result.action})"


if __name__ == "__main__":
    mcp.run()
